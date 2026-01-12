defmodule PriceHistory.Lending.Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger
  alias PriceHistory.Curve.Strategy.Contracts.AnyERC20

  defmodule AaveContracts do
    use Ethers.Contract, abi_file: "priv/abi/aave_atoken.json"
  end

  defmodule CompoundContracts do
    use Ethers.Contract, abi_file: "priv/abi/compound_ctoken.json"
  end

  defstruct [
    :address,
    :underlying_address,
    :underlying_decimals,
    :protocol,
    :decimals,
    :metadata,
    :ethers_opts
  ]

  @sample_interval 100

  @impl true
  def init(address, opts) do
    ethers_opts = Keyword.get(opts, :ethers_opts, [])
    call_opts = Keyword.put(ethers_opts, :to, address)

    # 1. Try Aave (UNDERLYING_ASSET_ADDRESS)
    case AaveContracts.underlying_asset_address() |> Ethers.call(call_opts) do
      {:ok, underlying} ->
        init_state(address, underlying, :aave, ethers_opts)

      _ ->
        # 2. Try Compound (underlying)
        case CompoundContracts.underlying() |> Ethers.call(call_opts) do
          {:ok, underlying} ->
            init_state(address, underlying, :compound, ethers_opts)

          _ ->
            {:error, :not_lending_token}
        end
    end
  end

  defp init_state(address, underlying, protocol, ethers_opts) do
    # Get underlying decimals
    base_opts = Keyword.put(ethers_opts, :to, underlying)
    call_opts = Keyword.put(ethers_opts, :to, address)

    with {:ok, sym} <- AnyERC20.symbol() |> Ethers.call(base_opts),
         {:ok, und_dec} <- AnyERC20.decimals() |> Ethers.call(base_opts) do
      # For Compound, we also need the cToken decimals to calculate true exchange rate
      # ExchangeRate is scaled by 1e(18 + und_dec - ctoken_dec)
      my_dec =
        if protocol == :compound do
          case CompoundContracts.decimals() |> Ethers.call(call_opts) do
            {:ok, d} -> d
            # Compound usually 8
            _ -> 8
          end
        else
          # Aave matches underlying usually
          und_dec
        end

      description =
        "#{String.upcase(Atom.to_string(protocol))} Offering for #{sym} (Und Dec: #{und_dec})"

      state = %__MODULE__{
        address: address,
        underlying_address: underlying,
        underlying_decimals: und_dec,
        protocol: protocol,
        decimals: my_dec,
        # Return values in Underlying Decimals
        metadata: %{description: description, decimals: und_dec},
        ethers_opts: ethers_opts
      }

      Logger.info("Detected Lending Token: #{description}")
      {:ok, state}
    else
      _ -> {:error, :failed_to_get_underlying_info}
    end
  end

  @impl true
  def metadata(state), do: state.metadata

  @impl true
  def fetch_history(state, from_block, to_block, _chunk_size, on_batch) do
    # For Aave, price is always 1.0 (relative to underlying).
    # We can optimize this by just generating points without RPC calls?
    # BUT, we need to respect the interface.

    steps =
      Stream.iterate(from_block, &(&1 + @sample_interval))
      |> Stream.take_while(&(&1 <= to_block))

    chunk_size = 50

    steps
    |> Stream.chunk_every(chunk_size)
    |> Enum.each(fn block_numbers ->
      results =
        if state.protocol == :aave do
          # Aave is 1:1.
          # Value = 1.0 * 10^underlying_decimals.
          val = round(:math.pow(10, state.underlying_decimals))

          block_numbers
          |> Enum.map(fn bn ->
            %{
              round_id: 0,
              answer: val,
              timestamp: get_block_timestamp(bn, state),
              block_number: bn
            }
          end)
        else
          # Compound: Fetch exchangeRateStored
          Logger.debug(
            "Sampling Compound for blocks #{List.first(block_numbers)}..#{List.last(block_numbers)}"
          )

          block_numbers
          |> Task.async_stream(
            fn block_number ->
              fetch_compound_rate(state, block_number)
            end,
            max_concurrency: 5,
            timeout: 15_000
          )
          |> Enum.map(fn {:ok, res} -> res end)
          |> Enum.reject(&is_nil/1)
        end

      if length(results) > 0 do
        on_batch.(results)
      end
    end)

    :ok
  end

  defp fetch_compound_rate(state, block_number) do
    opts =
      state.ethers_opts
      |> Keyword.put(:to, state.address)
      |> Keyword.put(:block_number, block_number)

    try do
      {:ok, rate_mantissa} = CompoundContracts.exchange_rate_stored() |> Ethers.call(opts)

      # formula: ONE_CTOKEN_IN_UNDERLYING = exchangeRateCurrent / 1e18
      # But the Mantissa is scaled by 10^(18 + und_dec - c_dec).

      # We want the price of 1 cToken in Underlying Units?
      # Usually "Price" means "How many Underlying for 1 cToken".
      # Protocol returns: Mantissa.

      # Example: cUSDC (8 dec). USDC (6 dec).
      # Scale = 18 + 6 - 8 = 16.
      # Rate = Mantissa / 1e16.
      # Result = Underlying Units per 1 cToken Unit.

      # Validated:
      # If Exchange Rate is 0.02 (1 cToken = 0.02 Underlying).
      # We want to return this "Price".
      # Output Integer?
      # Our system assumes "Decimals" property matches the output.
      # If we say metadata.decimals = underlying_decimals (6).
      # We expect output to be Integer representation of that float.

      # Wait. If Rate is 0.02. And output decimals is 6.
      # We return 0.02 * 10^6 = 20000.

      # Math:
      # RateFloat = Mantissa / 10^(18 + und_dec - c_dec)
      # OutputInt = RateFloat * 10^(und_dec)   <-- We want value in Underlying Decimals?
      # No, wait.
      # If we track "Price History of cUSDC", we typically want "cUSDC price in USDC".
      # So yes.

      # OutputInt = [ Mantissa / 10^(18 + und - c) ] * 10^und
      # OutputInt = Mantissa * 10^und / 10^(18 + und - c)
      # OutputInt = Mantissa * 10^(und - (18 + und - c))
      # OutputInt = Mantissa * 10^(c - 18)

      # If c_dec (8) < 18. Exponent is negative?
      # Mantissa / 10^(18 - c).

      # Example: cUSDC. c=8. 18-8 = 10.
      # OutputInt = Mantissa / 10^10.

      # Let's verify.
      # Mantissa is usually huge. 2e14?
      # 2e14 / 1e10 = 2e4 = 20000. (0.02 USDC). Correct.

      diff = 18 - state.decimals

      final_val =
        if diff >= 0 do
          div(rate_mantissa, round(:math.pow(10, diff)))
        else
          rate_mantissa * round(:math.pow(10, -diff))
        end

      %{
        round_id: 0,
        answer: final_val,
        timestamp: get_block_timestamp(block_number, state),
        block_number: block_number
      }
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
