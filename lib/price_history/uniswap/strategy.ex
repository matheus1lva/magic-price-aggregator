defmodule PriceHistory.Uniswap.Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger
  alias PriceHistory.ValidTokens

  defmodule Contracts do
    use Ethers.Contract, abi_file: "priv/abi/uniswap_pair.json"
  end

  defstruct [:address, :quote_token, :quote_decimals, :metadata, :ethers_opts]

  # Sampling interval
  @sample_interval 100

  @impl true
  def init(address, opts) do
    ethers_opts = Keyword.get(opts, :ethers_opts, [])
    call_opts = Keyword.put(ethers_opts, :to, address)

    # 1. Check if it's a Uniswap Pair by calling getReserves, token0, token1
    with {:ok, _reserves} <- Contracts.get_reserves() |> Ethers.call(call_opts),
         {:ok, token0} <- Contracts.token0() |> Ethers.call(call_opts),
         {:ok, token1} <- Contracts.token1() |> Ethers.call(call_opts),
         {:ok, symbol} <- Contracts.symbol() |> Ethers.call(call_opts) do
      # Identify which one is the quote token
      quote = identify_quote(token0, token1)

      case quote do
        nil ->
          {:error, :no_known_quote_token}

        {quote_address, quote_meta} ->
          description = "Uniswap V2 #{symbol} (in #{quote_meta.symbol})"

          state = %__MODULE__{
            address: address,
            quote_token: quote_address,
            quote_decimals: quote_meta.decimals,
            metadata: %{description: description, decimals: quote_meta.decimals},
            ethers_opts: ethers_opts
          }

          Logger.info("Detected Uniswap V2 Pair: #{description}")
          {:ok, state}
      end
    else
      err -> {:error, {:not_uniswap, err}}
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
        "Sampling Uniswap prices for blocks #{List.first(block_numbers)}..#{List.last(block_numbers)}"
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
    opts =
      state.ethers_opts
      |> Keyword.put(:to, state.address)
      |> Keyword.put(:block_number, block_number)

    try do
      # Fetch reserves and total supply
      with {:ok, {r0, r1, _ts_last}} <- Contracts.get_reserves() |> Ethers.call(opts),
           {:ok, total_supply} <- Contracts.total_supply() |> Ethers.call(opts) do
        if total_supply == 0 do
          nil
        else
          # Determine which reserve matches the quote token
          # We need to know order. Luckily address order is static.
          # But we need to check token0 again? No, token0/1 are immutable.
          # We should cache which index is quote in `init`.
          # For MVP, let's re-fetch token0 to be sure or just check address against state.quote_token
          # Wait, that's expensive.
          # Let's assume we can cache the "quote_index" in state.

          # Optimization: Do we need to know index?
          # We have state.quote_token.
          # We don't know if r0 corresponds to quote or r1.
          # We need to know token0 address.
          # Let's fetch token0 once in init and store it.
          # Re-fetching token0 here is an extra call.

          # Let's improve init to store `quote_index` (0 or 1).
          # But since I can't edit `init` easily now without re-writing,
          # I'll just Assume I need to fetch token0 here or assume I stored it.
          # I'll "cheat" and fetch token0 here for now, or use `MultiCall` later?
          # Actually, simpler: I'll just check if `token0` call matches `quote_token`.
          # Cost: 1 extra RPC call per sample. Acceptable for MVP.

          {:ok, t0} = Contracts.token0() |> Ethers.call(opts)

          quote_reserve =
            if String.downcase(t0) == String.downcase(state.quote_token) do
              r0
            else
              r1
            end

          # Formula: Price = 2 * QuoteReserve / TotalSupply
          # Note on units:
          # QuoteReserve is in QuoteDecimals.
          # TotalSupply is in 18 decimals usually.
          # We want price of 1 LP in QuoteDecimals.
          # (2 * Q) / T -> This gives "Quote per LP" but scaled?
          # Let's do math:
          # Value of Pool = 2 * QuoteReserve (assuming 50/50)
          # Price of 1 LP = Value / TotalSupply
          # = 2 * Q / T
          # Result is in Quote units per LP unit.
          # If we want the answer to be "Chainlink-like" integer (scaled by decimals),
          # We usually want the answer to have `decimals` precision.
          # Our metadata says `decimals` is `quote_decimals`.
          # So we expect the output to be like: 1.50 USDC -> 1500000 (if decimals=6)

          # Calculation:
          # (2 * Q_raw) * (10^18) / T_raw  <-- assuming T is 18 decimals?
          # If LP is 18 decimals, then 1 LP = 1e18 units.
          # Price = (2 * Q_raw) / (T_raw / 1e18) = (2 * Q_raw * 1e18) / T_raw

          # Safe integer math
          price = div(2 * quote_reserve * 1_000_000_000_000_000_000, total_supply)

          %{
            round_id: 0,
            answer: price,
            timestamp: get_block_timestamp(block_number, state),
            block_number: block_number
          }
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

  defp identify_quote(t0, t1) do
    # Check if t0 is quote
    q0 = ValidTokens.get_quote_token(t0)
    if q0, do: {t0, q0}, else: check_t1(t1)
  end

  defp check_t1(t1) do
    q1 = ValidTokens.get_quote_token(t1)
    if q1, do: {t1, q1}, else: nil
  end
end
