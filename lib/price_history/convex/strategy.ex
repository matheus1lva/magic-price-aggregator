defmodule PriceHistory.Convex.Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger
  alias PriceHistory.Curve.Strategy.Contracts, as: CurveContracts
  alias PriceHistory.Curve.Strategy.Contracts.AnyERC20

  defstruct [:address, :underlying_address, :metadata, :ethers_opts]

  # Mapping from Convex Token -> Curve LP Token
  # Source: ypricemagic/y/prices/convex.py
  @mapping %{
    # cvx3crv -> 3crv
    "0x30d9410ed1d5da1f6c8391af5338c93ab8d4035c" => "0x6c3f90f043a72fa612cbac8115ee7e52bde6e490",
    # cvxFRAX3CRV-f -> FRAX3CRV
    "0xbe0f6478e0e4894cfb14f32855603a083a57c7da" => "0xd632f22692fac7611d2aa1c0d552930d43caed3b",
    # cvxMIM-3LP3CRV-f -> crvMIM
    "0xabb54222c2b77158cc975a2b715a3d703c256f05" => "0x5a6a4d54456819380173272a5e8e9b9904bdf41b",
    # cvxalUSD3CRV-f -> crvalusd
    "0xca3d9f45ffa69ed454e66539298709cb2db8ca61" => "0x43b4fdfd4ff969587185cdb6f0bd875c5fc83f8c",
    # cvx3crypto -> 3crypto
    "0xdefd8fdd20e0f34115c7018ccfb655796f6b2168" => "0xc4ad29ba4b3c580e6d59105fff484999997675ff"
  }

  @sample_interval 100

  @impl true
  def init(address, opts) do
    # Check if address is in our mapping
    downcased = String.downcase(address)

    case Map.get(@mapping, downcased) do
      nil ->
        {:error, :not_convex_mapped}

      underlying ->
        ethers_opts = Keyword.get(opts, :ethers_opts, [])
        call_opts = Keyword.put(ethers_opts, :to, underlying)

        # Verify underlying is accessible (optional, but good for metadata)
        with {:ok, symbol} <- AnyERC20.symbol() |> Ethers.call(call_opts),
             {:ok, _decimals} <- AnyERC20.decimals() |> Ethers.call(call_opts) do
          description = "Convex Token #{symbol} (via Curve)"

          state = %__MODULE__{
            address: address,
            underlying_address: underlying,
            # Virtual price implies 18 usually
            metadata: %{description: description, decimals: 18},
            ethers_opts: ethers_opts
          }

          Logger.info("Detected Convex Token: #{description} -> #{underlying}")
          {:ok, state}
        else
          err -> {:error, {:convex_init_failed, err}}
        end
    end
  end

  @impl true
  def metadata(state), do: state.metadata

  @impl true
  def fetch_history(state, from_block, to_block, _chunk_size, on_batch) do
    # Re-use sampling logic but target the underlying address
    steps =
      Stream.iterate(from_block, &(&1 + @sample_interval))
      |> Stream.take_while(&(&1 <= to_block))

    chunk_size = 10

    steps
    |> Stream.chunk_every(chunk_size)
    |> Enum.each(fn block_numbers ->
      Logger.debug(
        "Sampling Convex (Curve) prices for blocks #{List.first(block_numbers)}..#{List.last(block_numbers)}"
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
    # Target the UNDERLYING address for get_virtual_price
    opts =
      state.ethers_opts
      |> Keyword.put(:to, state.underlying_address)
      |> Keyword.put(:block_number, block_number)

    try do
      {:ok, vp} = CurveContracts.get_virtual_price() |> Ethers.call(opts)

      %{
        round_id: 0,
        answer: vp,
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
