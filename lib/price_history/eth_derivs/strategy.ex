defmodule PriceHistory.EthDerivs.Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger

  defmodule WstEthContracts do
    use Ethers.Contract, abi_file: "priv/abi/wsteth.json"
  end

  defmodule CrEthContracts do
    use Ethers.Contract, abi_file: "priv/abi/creth.json"
  end

  defstruct [:address, :type, :metadata, :ethers_opts]

  @sample_interval 100

  @impl true
  def init(address, opts) do
    ethers_opts = Keyword.get(opts, :ethers_opts, [])
    call_opts = Keyword.put(ethers_opts, :to, address)

    # 1. Try wstETH (stEthPerToken)
    case WstEthContracts.st_eth_per_token() |> Ethers.call(call_opts) do
      {:ok, _val} ->
        init_state(address, :wsteth, ethers_opts)

      _ ->
        # 2. Try crETH (accumulated)
        case CrEthContracts.accumulated() |> Ethers.call(call_opts) do
          {:ok, _val} ->
            init_state(address, :creth, ethers_opts)

          _ ->
            {:error, :not_eth_deriv}
        end
    end
  end

  defp init_state(address, type, ethers_opts) do
    description =
      case type do
        :wsteth -> "Wrapped stETH (Priced in stETH/ETH)"
        :creth -> "Cream ETH (Priced in ETH)"
      end

    state = %__MODULE__{
      address: address,
      type: type,
      # Usually these are priced in ETH (18 decimals)
      metadata: %{description: description, decimals: 18},
      ethers_opts: ethers_opts
    }

    Logger.info("Detected Eth Derivative: #{description}")
    {:ok, state}
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
        "Sampling Eth Deriv (#{state.type}) for blocks #{List.first(block_numbers)}..#{List.last(block_numbers)}"
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
      price =
        case state.type do
          :wsteth ->
            {:ok, val} = WstEthContracts.st_eth_per_token() |> Ethers.call(opts)
            val

          :creth ->
            with {:ok, accumulated} <- CrEthContracts.accumulated() |> Ethers.call(opts),
                 {:ok, supply} <- CrEthContracts.total_supply() |> Ethers.call(opts) do
              if supply > 0 do
                div(accumulated, supply)
              else
                nil
              end
            else
              _ -> nil
            end
        end

      if price do
        %{
          round_id: 0,
          # Already in 18 decimals (Rate * 1e18) presumably
          answer: price,
          timestamp: get_block_timestamp(block_number, state),
          block_number: block_number
        }
      else
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
