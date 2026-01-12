defmodule PriceHistory.Curve.Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger

  defmodule Contracts do
    use Ethers.Contract, abi_file: "priv/abi/curve_pool.json"

    defmodule AnyERC20 do
      use Ethers.Contract, abi_file: "priv/abi/erc20_minimal.json"
    end
  end

  defstruct [:address, :metadata, :ethers_opts]

  # Sampling interval for curve virtual price (also computed, no events usually emitted for VP)
  @sample_interval 100

  @impl true
  def init(address, opts) do
    ethers_opts = Keyword.get(opts, :ethers_opts, [])
    call_opts = Keyword.put(ethers_opts, :to, address)

    # Detect if it's a Curve pool by checking for get_virtual_price
    with {:ok, _vp} <- Contracts.get_virtual_price() |> Ethers.call(call_opts),
         {:ok, symbol} <- Contracts.AnyERC20.symbol() |> Ethers.call(call_opts),
         # Curve LP tokens usually store decimals. Virtual price is always 1e18 relative to underlying?
         # Actually Curve pools often *are* the LP token (older ones) or have a separate LP token.
         # But many main pools (3pool, steth) implement get_virtual_price on the pool address itself.
         # If the address provided is the pool/LP, we are good.
         {:ok, _decimals} <- Contracts.AnyERC20.decimals() |> Ethers.call(call_opts) do
      description = "Curve LP #{symbol} (Virtual Price)"

      state = %__MODULE__{
        address: address,
        # Virtual price is 1e18 precision usually
        metadata: %{description: description, decimals: 18},
        ethers_opts: ethers_opts
      }

      Logger.info("Detected Curve Pool: #{description}")
      {:ok, state}
    else
      err -> {:error, {:not_curve, err}}
    end
  end

  @impl true
  def metadata(state), do: state.metadata

  @impl true
  def fetch_history(state, from_block, to_block, _chunk_size, on_batch) do
    # Similar sampling logic as Pendle
    steps =
      Stream.iterate(from_block, &(&1 + @sample_interval))
      |> Stream.take_while(&(&1 <= to_block))

    chunk_size = 10

    steps
    |> Stream.chunk_every(chunk_size)
    |> Enum.each(fn block_numbers ->
      Logger.debug(
        "Sampling Curve prices for blocks #{List.first(block_numbers)}..#{List.last(block_numbers)}"
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
      {:ok, vp} = Contracts.get_virtual_price() |> Ethers.call(opts)

      %{
        round_id: 0,
        answer: vp,
        timestamp: get_block_timestamp(block_number, state),
        block_number: block_number
      }
    rescue
      # Curve pools might revert if paused or too early
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
