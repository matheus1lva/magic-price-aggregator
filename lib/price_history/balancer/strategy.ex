defmodule PriceHistory.Balancer.Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger
  alias PriceHistory.ValidTokens

  defmodule PoolContracts do
    use Ethers.Contract, abi_file: "priv/abi/balancer_pool.json"
  end

  defmodule VaultContracts do
    use Ethers.Contract, abi_file: "priv/abi/balancer_vault.json"
  end

  defstruct [
    :address,
    :pool_id,
    :vault_address,
    :quote_token,
    :quote_decimals,
    :quote_weight,
    :metadata,
    :ethers_opts,
    :is_weighted
  ]

  @sample_interval 100

  @impl true
  def init(address, opts) do
    ethers_opts = Keyword.get(opts, :ethers_opts, [])
    call_opts = Keyword.put(ethers_opts, :to, address)

    # Detect Balancer Pool: getPoolId, getVault
    with {:ok, pool_id} <- PoolContracts.get_pool_id() |> Ethers.call(call_opts),
         {:ok, vault_address} <- PoolContracts.get_vault() |> Ethers.call(call_opts) do
      vault_opts = Keyword.put(ethers_opts, :to, vault_address)

      # 1. Get Tokens to identify Quote Token
      case VaultContracts.get_pool_tokens(pool_id) |> Ethers.call(vault_opts) do
        {:ok, {tokens, _balances, _block}} ->
          # 2. Try to find a Quote Token
          quote_data =
            tokens
            |> Enum.find_value(fn t ->
              case ValidTokens.get_quote_token(t) do
                nil -> nil
                idx -> {t, idx}
              end
            end)

          case quote_data do
            nil ->
              {:error, :no_known_quote_token_in_balancer_pool}

            {quote_token, quote_idx_info} ->
              # 3. Check if Weighted Pool (getNormalizedWeights)
              weights_result = PoolContracts.get_normalized_weights() |> Ethers.call(call_opts)

              {is_weighted, quote_weight} =
                case weights_result do
                  {:ok, weights} ->
                    # Find index of quote token in tokens list
                    index =
                      Enum.find_index(tokens, fn t ->
                        String.downcase(t) == String.downcase(quote_token)
                      end)

                    weight = Enum.at(weights, index)
                    # Weights are 18 decimals (e.g. 0.8 * 1e18)
                    weight_float = weight / 1.0e18
                    {true, weight_float}

                  _ ->
                    # Assume Stable Pool or unknown.
                    # For Stable Pool, if we have a Quote Token, we can roughly approximate TVL
                    # by assuming all tokens are priced similarly or just take Quote Balance * Weight (if equal).
                    # But Stable Pools don't have weights.
                    # Fallback: Just track Quote Balance portion? No that's wrong.
                    # Fallback: Assume 1 BPT ~= 1 Quote Token if pegged? No.
                    # Simplification: Only support Weighted Pools for now or fallback to "Unknown Weight" error?
                    # Let's support Weighted Pools properly.
                    {false, nil}
                end

              if is_weighted do
                description = "Balancer Weighted Pool (Quote: #{quote_idx_info.symbol})"

                state = %__MODULE__{
                  address: address,
                  pool_id: pool_id,
                  vault_address: vault_address,
                  quote_token: quote_token,
                  quote_decimals: quote_idx_info.decimals,
                  quote_weight: quote_weight,
                  is_weighted: true,
                  metadata: %{description: description, decimals: quote_idx_info.decimals},
                  ethers_opts: ethers_opts
                }

                Logger.info("Detected Balancer Pool: #{description}")
                {:ok, state}
              else
                {:error, :balancer_stable_pool_not_supported_yet}
              end
          end

        _ ->
          {:error, :failed_to_get_pool_tokens}
      end
    else
      _ -> {:error, :not_balancer_pool}
    end
  end

  @impl true
  def metadata(state), do: state.metadata

  @impl true
  def fetch_history(state, from_block, to_block, _chunk_size, on_batch) do
    steps =
      Stream.iterate(from_block, &(&1 + @sample_interval))
      |> Stream.take_while(&(&1 <= to_block))

    chunk_size = 10

    steps
    |> Stream.chunk_every(chunk_size)
    |> Enum.each(fn block_numbers ->
      Logger.debug(
        "Sampling Balancer for blocks #{List.first(block_numbers)}..#{List.last(block_numbers)}"
      )

      results =
        block_numbers
        |> Task.async_stream(
          fn block_number ->
            fetch_price_at_block(state, block_number)
          end,
          max_concurrency: 5,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, res} -> res end)
        |> Enum.reject(&is_nil/1)

      if length(results) > 0 do
        on_batch.(results)
      end
    end)

    :ok
  end

  defp fetch_price_at_block(state, block_number) do
    vault_opts =
      state.ethers_opts
      |> Keyword.put(:to, state.vault_address)
      |> Keyword.put(:block_number, block_number)

    pool_opts =
      state.ethers_opts
      |> Keyword.put(:to, state.address)
      |> Keyword.put(:block_number, block_number)

    try do
      with {:ok, {tokens, balances, _}} <-
             VaultContracts.get_pool_tokens(state.pool_id) |> Ethers.call(vault_opts),
           {:ok, total_supply} <- PoolContracts.total_supply() |> Ethers.call(pool_opts) do
        # Find Quote Balance
        index =
          Enum.find_index(tokens, fn t ->
            String.downcase(t) == String.downcase(state.quote_token)
          end)

        if index do
          quote_balance = Enum.at(balances, index)

          # Formula:
          # Pool Value = Quote Value / Quote Weight
          # Quote Value = Quote Balance (in raw units? No, let's work in raw for now)
          # Wait. If I use raw quote balance:
          # Pool Value (Raw Quote Units) = QuoteBalance / Weight
          # BPT Price (Raw Quote Units) = Pool Value / Total Supply
          # BPT Price = (QuoteBalance / Weight) / TotalSupply
          # BPT Price = QuoteBalance / (Weight * TotalSupply)

          # Result is "How many Quote Token Raw Units per 1 BPT Raw Unit?"
          # But BPT usually has 18 decimals. Quote might have 6 (USDC).
          # We want the output price to be in "Quote Decimals".
          # So: (Price in Real Terms) * 10^QuoteDecimals.

          # Real Price = (RealQuoteBalance / Weight) / RealTotalSupply
          # RealQuoteBalance = QuoteRaw / 10^QuoteDec
          # RealTotalSupply = SupplyRaw / 10^18 (BPT is always 18?)

          # Real Price = ( (QuoteRaw / 10^Q) / W ) / (SupplyRaw / 10^18)
          # Real Price = (QuoteRaw * 10^18) / (SupplyRaw * W * 10^Q)

          # We want Output Int = Real Price * 10^Q
          # Output Int = [ (QuoteRaw * 10^18) / (SupplyRaw * W * 10^Q) ] * 10^Q
          # Output Int = (QuoteRaw * 10^18) / (SupplyRaw * W)

          # Let's verify.
          # QuoteRaw = 2000e6 (2000 USDC). Weight = 0.5. SupplyRaw = 100e18 (100 BPT).
          # Real Pool Val = 2000 / 0.5 = $4000.
          # Real BPT Price = 4000 / 100 = $40.
          # Output should be 40 * 10^6 = 40,000,000.

          # Formula Check:
          # (2000e6 * 1e18) / (100e18 * 0.5)
          # = (2000e24) / (50e18)
          # = 40e6.
          # Matches!

          numerator = quote_balance * 1.0e18
          denominator = total_supply * state.quote_weight

          if denominator > 0 do
            price = numerator / denominator

            %{
              round_id: 0,
              answer: round(price),
              timestamp: get_block_timestamp(block_number, state),
              block_number: block_number
            }
          else
            nil
          end
        else
          nil
        end
      else
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  defp get_block_timestamp(block_number, _state) do
    case Ethereumex.HttpClient.eth_get_block_by_number(
           "0x" <> Integer.to_string(block_number, 16),
           false
         ) do
      {:ok, %{"timestamp" => timestamp_hex}} ->
        {ts, ""} = Integer.parse(String.replace(timestamp_hex, "0x", ""), 16)
        ts

      _ ->
        DateTime.utc_now() |> DateTime.to_unix()
    end
  end
end
