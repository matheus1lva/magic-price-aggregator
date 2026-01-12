defmodule PriceHistory.Chainlink.Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger
  alias PriceHistory.Chainlink.{Contracts, Fetcher}

  defstruct [:address, :phases, :metadata, :ethers_opts]

  @impl true
  def init(address, opts) do
    # Check if it looks like a Chainlink feed or similar?
    # For now we assume if this strategy is chosen, it is valid.
    # But usually we'd do a check.

    ethers_opts = Keyword.get(opts, :ethers_opts, [])

    # Try to fetch Chainlink specific metadata to validate
    call_opts = Keyword.put(ethers_opts, :to, address)

    with {:ok, description} <- Contracts.Aggregator.description() |> Ethers.call(call_opts),
         {:ok, decimals} <- Contracts.Aggregator.decimals() |> Ethers.call(call_opts),
         {:ok, current_phase_id} <- Contracts.Aggregator.phase_id() |> Ethers.call(call_opts) do
      Logger.info("Detected Chainlink Feed: #{description}")

      # Load Phases
      phases = load_phases(address, current_phase_id, ethers_opts)

      state = %__MODULE__{
        address: address,
        ethers_opts: ethers_opts,
        phases: phases,
        metadata: %{description: description, decimals: decimals}
      }

      {:ok, state}
    else
      err -> {:error, {:not_chainlink, err}}
    end
  end

  @impl true
  def metadata(state), do: state.metadata

  @impl true
  def fetch_history(state, from_block, to_block, chunk_size, on_batch) do
    # Iterate all phases
    Enum.each(state.phases, fn phase ->
      Logger.debug(
        "Syncing Phase #{phase.id} (Address: #{phase.address}) from block #{from_block} to #{to_block}"
      )

      # We intentionally ignore from_block/to_block for *phases* optimization in a real app
      # (filtering out phases that didn't exist), but for now we follow the original logic:
      # simplistic overlap check or just simple stream.
      # The original worker passed the global start/end to every phase.

      Fetcher.fetch_logs(
        phase.address,
        from_block,
        to_block,
        chunk_size,
        on_batch
      )

      Logger.info("Finished syncing Phase #{phase.id}")
    end)

    :ok
  end

  defp load_phases(address, current_phase_id, ethers_opts) do
    # Same logic as original worker
    opts = Keyword.put(ethers_opts, :to, address)

    1..current_phase_id
    |> Enum.map(fn id ->
      {:ok, addr} = Contracts.Aggregator.phase_aggregators(id) |> Ethers.call(opts)

      phase_opts = Keyword.put(ethers_opts, :to, addr)

      latest_round =
        try do
          {:ok, lr} = Contracts.Offchain.latest_round() |> Ethers.call(phase_opts)
          if is_list(lr), do: List.first(lr), else: lr
        rescue
          _ -> 0
        end

      %{id: id, address: addr, latest_round: latest_round}
    end)
    |> Enum.sort_by(& &1.id, :desc)
  end
end
