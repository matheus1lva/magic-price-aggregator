defmodule PriceHistory.Uniswap.V3Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger
  alias PriceHistory.ValidTokens
  alias PriceHistory.Curve.Strategy.Contracts.AnyERC20

  defmodule Contracts do
    use Ethers.Contract, abi_file: "priv/abi/uniswap_v3_pool.json"
  end

  defstruct [
    :address,
    :quote_token,
    :base_token,
    :quote_decimals,
    :base_decimals,
    :is_token0_quote,
    :metadata,
    :ethers_opts
  ]

  @sample_interval 100
  # 2^96
  @q96 79_228_162_514_264_337_593_543_950_336.0

  @impl true
  def init(address, opts) do
    ethers_opts = Keyword.get(opts, :ethers_opts, [])
    call_opts = Keyword.put(ethers_opts, :to, address)

    # Detect V3 Pool: slot0, liquidity, token0, token1
    with {:ok, _slot0} <- Contracts.slot0() |> Ethers.call(call_opts),
         {:ok, _liq} <- Contracts.liquidity() |> Ethers.call(call_opts),
         {:ok, token0} <- Contracts.token0() |> Ethers.call(call_opts),
         {:ok, token1} <- Contracts.token1() |> Ethers.call(call_opts) do
      # Identify Quote and Base
      case identify_quote_base(token0, token1) do
        nil ->
          {:error, :no_known_quote_token}

        {quote, base, quote_dec, is_token0_quote} ->
          # We need base decimals
          base_opts = Keyword.put(ethers_opts, :to, base)

          base_info =
            with {:ok, sym} <- AnyERC20.symbol() |> Ethers.call(base_opts),
                 {:ok, dec} <- AnyERC20.decimals() |> Ethers.call(base_opts) do
              {sym, dec}
            else
              _ -> {"UNKNOWN", 18}
            end

          {base_sym, base_dec} = base_info

          description = "Uniswap V3 #{base_sym}/Quote (in #{quote_dec} decimals)"

          state = %__MODULE__{
            address: address,
            quote_token: quote,
            base_token: base,
            quote_decimals: quote_dec,
            base_decimals: base_dec,
            is_token0_quote: is_token0_quote,
            metadata: %{description: description, decimals: quote_dec},
            ethers_opts: ethers_opts
          }

          Logger.info("Detected Uniswap V3 Pool: #{description}")
          {:ok, state}
      end
    else
      err -> {:error, {:not_uniswap_v3, err}}
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
        "Sampling Uniswap V3 for blocks #{List.first(block_numbers)}..#{List.last(block_numbers)}"
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
      {:ok, {sqrt_price_x96, _, _, _, _, _, _}} = Contracts.slot0() |> Ethers.call(opts)

      # Calculation
      # P_raw (token1/token0) = (sqrt / 2^96)^2
      # We use float for calculation then convert to integer with precision

      sqrt_float = sqrt_price_x96 / 1.0
      ratio = sqrt_float / @q96 * (sqrt_float / @q96)

      # If is_token0_quote (Quote=0, Base=1):
      # P_raw = Quote/Base.
      # We want Quote per Base.
      # So Price = Ratio.
      # Result = Ratio * 10^(base_decimals). Wait?

      # Let's verify units.
      # Ratio = Quote_raw / Base_raw.
      # Ratio = (Q_real * 10^q_dec) / (B_real * 10^b_dec)
      # Ratio = (Q_real / B_real) * 10^(q - b)
      # Price_real (Q per B) = Q_real / B_real.
      # So Ratio = Price_real * 10^(q - b).
      # Price_real = Ratio * 10^(b - q).

      # We want output in Quote Decimals (integer).
      # Output = Price_real * 10^q
      # Output = Ratio * 10^(b - q) * 10^q
      # Output = Ratio * 10^b.

      # Case 2: is_token0_quote = false (Quote=1, Base=0)
      # P_raw = Quote/Base (Token1/Token0).
      # Same formula. Output = Ratio * 10^b.

      # Wait. Ratio is ALWAYS Token1 / Token0.

      # Case A: Quote=Token1, Base=Token0.
      # Ratio = Quote/Base.
      # Output = Ratio * 10^base_dec.

      # Case B: Quote=Token0, Base=Token1.
      # Ratio = Base/Quote.
      # We want Quote/Base.
      # InverseRatio = 1 / Ratio.
      # Output = InverseRatio * 10^base_dec.

      final_price =
        if state.is_token0_quote do
          # Quote is 0. Base is 1. Ratio is Base/Quote (1/0) ERROR.
          # Ratio is always 1/0. (y/x).
          # Base is y. Quote is x.
          # Ratio = Base(y) / Quote(x).
          # We want Quote/Base.
          # So 1/Ratio.
          1.0 / ratio * :math.pow(10, state.base_decimals)
        else
          # Quote is 1. Base is 0.
          # Ratio is Quote(y) / Base(x).
          # We want Quote/Base.
          # So Ratio.
          ratio * :math.pow(10, state.base_decimals)
        end

      %{
        round_id: 0,
        answer: round(final_price),
        timestamp: get_block_timestamp(block_number, state),
        block_number: block_number
      }
    rescue
      _ -> nil
    end
  end

  defp identify_quote_base(t0, t1) do
    q0 = ValidTokens.get_quote_token(t0)
    q1 = ValidTokens.get_quote_token(t1)

    cond do
      q0 != nil -> {t0, t1, q0.decimals, true}
      q1 != nil -> {t1, t0, q1.decimals, false}
      true -> nil
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
