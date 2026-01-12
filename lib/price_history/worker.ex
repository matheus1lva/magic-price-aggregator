defmodule PriceHistory.PriceFeed do
  use GenServer
  require Logger
  alias PriceHistory.Store
  alias PriceHistory.Chainlink
  alias PriceHistory.Pendle
  alias PriceHistory.Curve
  alias PriceHistory.Uniswap
  alias PriceHistory.Convex

  # Strategies
  @strategies [
    Chainlink.Strategy,
    Pendle.Strategy,
    Curve.Strategy,
    Uniswap.Strategy,
    Uniswap.V3Strategy,
    Balancer.Strategy,
    Lending.Strategy,
    EthDerivs.Strategy,
    Gearbox.Strategy,
    TokenizedFund.Strategy,
    Convex.Strategy
  ]

  def start_link(opts) do
    contract_address = Keyword.fetch!(opts, :contract_address)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(contract_address))
  end

  defp via_tuple(address) do
    {:via, Registry, {PriceHistory.Registry, address}}
  end

  @impl true
  def init(opts) do
    contract_address = Keyword.fetch!(opts, :contract_address)
    rpc_url = Keyword.get(opts, :rpc_url, "https://eth.llama.run")
    start_block = Keyword.get(opts, :start_block)

    state = %{
      address: contract_address,
      rpc_url: rpc_url,
      start_block: start_block,
      ethers_opts: [rpc_opts: [url: rpc_url, recv_timeout: 60_000]],
      # Strategy State
      strategy_mod: nil,
      strategy_state: nil,
      metadata: nil
    }

    {:ok, state, {:continue, :init_strategy}}
  end

  @impl true
  def handle_continue(:init_strategy, state) do
    Logger.info("Detecting strategy for #{state.address}...")

    case detect_strategy(state.address, state.ethers_opts) do
      {:ok, mod, strategy_state} ->
        metadata = mod.metadata(strategy_state)
        Logger.info("Strategy selected: #{inspect(mod)}. Metadata: #{inspect(metadata)}")

        new_state = %{
          state
          | strategy_mod: mod,
            strategy_state: strategy_state,
            metadata: metadata
        }

        # Persist feed info
        Store.upsert_feed(state.address, metadata.description, metadata.decimals)

        # Start background sync
        Task.start(fn -> sync_history(new_state) end)

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to detect valid strategy for #{state.address}: #{inspect(reason)}")
        {:stop, :unsupported_feed, state}
    end
  end

  @impl true
  def handle_call({:get_history, start_ts, end_ts}, _from, state) do
    prices = Store.get_price_points(state.address, start_ts, end_ts)

    result = %{
      description: state.metadata.description,
      decimals: state.metadata.decimals,
      rounds: prices
    }

    {:reply, {:ok, result}, state}
  end

  defp sync_history(state) do
    Logger.info(
      "Starting background history sync for #{state.address} using #{inspect(state.strategy_mod)}..."
    )

    {:ok, current_block_hex} = Ethereumex.HttpClient.eth_block_number()
    {current_block, ""} = Integer.parse(String.replace(current_block_hex, "0x", ""), 16)

    # Sync from configured start_block or default to last 1M blocks
    start_block =
      case state.start_block do
        nil -> max(0, current_block - 1_000_000)
        block when is_integer(block) -> block
      end

    on_batch = fn rounds ->
      Logger.info("Persisting batch of #{length(rounds)} points")
      Store.insert_price_points(state.address, rounds)
    end

    state.strategy_mod.fetch_history(
      state.strategy_state,
      start_block,
      current_block,
      2_000,
      on_batch
    )

    Logger.info("Background sync complete for #{state.address}")
  end

  defp detect_strategy(address, opts) do
    # Try strategies in order
    Enum.reduce_while(@strategies, {:error, :no_strategy}, fn mod, _acc ->
      case mod.init(address, opts) do
        {:ok, strategy_state} -> {:halt, {:ok, mod, strategy_state}}
        _ -> {:cont, {:error, :no_matching_strategy}}
      end
    end)
  end
end
