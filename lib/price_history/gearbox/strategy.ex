defmodule PriceHistory.Gearbox.Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger
  alias PriceHistory.Curve.Strategy.Contracts.AnyERC20

  defmodule DieselContracts do
    use Ethers.Contract, abi_file: "priv/abi/gearbox_diesel.json"
  end

  defstruct [:address, :underlying_address, :scale, :metadata, :ethers_opts]

  @sample_interval 100

  @impl true
  def init(address, opts) do
    ethers_opts = Keyword.get(opts, :ethers_opts, [])
    call_opts = Keyword.put(ethers_opts, :to, address)

    # Detect Gearbox: underlyingToken(), fromDiesel()
    case DieselContracts.underlying_token() |> Ethers.call(call_opts) do
      {:ok, underlying} ->
        # Verify it has fromDiesel by dry-running or checking?
        # Check underlying decimals for scale
        base_opts = Keyword.put(ethers_opts, :to, underlying)

        with {:ok, dec} <- AnyERC20.decimals() |> Ethers.call(base_opts),
             {:ok, sym} <- AnyERC20.symbol() |> Ethers.call(base_opts) do
          scale = round(:math.pow(10, dec))

          # Verify fromDiesel works (optional but good for detection safety)
          # Actually, let's just assume if underlyingToken exists and it's not some other protocol...
          # But underlyingToken is common.
          # Let's try calling fromDiesel with small amount.
          case DieselContracts.from_diesel(1) |> Ethers.call(call_opts) do
            {:ok, _} ->
              description = "Gearbox Diesel Token for #{sym}"

              state = %__MODULE__{
                address: address,
                underlying_address: underlying,
                scale: scale,
                metadata: %{description: description, decimals: dec},
                ethers_opts: ethers_opts
              }

              Logger.info("Detected Gearbox Token: #{description}")
              {:ok, state}

            _ ->
              {:error, :not_gearbox_diesel}
          end
        else
          _ -> {:error, :failed_underlying_info}
        end

      _ ->
        {:error, :not_gearbox}
    end
  end

  @impl true
  def metadata(state), do: state.metadata

  @impl true
  def fetch_history(state, from_block, to_block, _chunk_size, on_batch) do
    steps =
      Stream.iterate(from_block, &(&1 + @sample_interval))
      |> Stream.take_while(&(&1 <= to_block))

    chunk_size = 50

    steps
    |> Stream.chunk_every(chunk_size)
    |> Enum.each(fn block_numbers ->
      Logger.debug(
        "Sampling Gearbox for blocks #{List.first(block_numbers)}..#{List.last(block_numbers)}"
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
      # fromDiesel(scale) -> return underlying amount for 'scale' diesel.
      # If 1:1, returns 'scale'.
      # We want Rate = Result / Scale.
      # But we need integer output.
      # Ideally we return Rate * 10^Decimals (which is just Result).

      # Example:
      # Rate 1.05. Scale 1e6.
      # fromDiesel(1e6) -> 1.05e6.
      # We return 1.05e6 (Integer).
      # Metadata Decimals = 6.
      # GUI displays 1.05. Correct.

      case DieselContracts.from_diesel(state.scale) |> Ethers.call(opts) do
        {:ok, val} ->
          %{
            round_id: 0,
            answer: val,
            timestamp: get_block_timestamp(block_number, state),
            block_number: block_number
          }

        _ ->
          nil
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
