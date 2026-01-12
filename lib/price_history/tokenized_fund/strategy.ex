defmodule PriceHistory.TokenizedFund.Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger

  defmodule FundContracts do
    # Common ABI methods for Sets/Pies
    use Ethers.Contract, abi_file: "priv/abi/tokenized_fund.json"
  end

  # Simplified state
  defstruct [:address, :metadata, :ethers_opts]

  @impl true
  def init(address, opts) do
    # This is a placeholder/best-effort strategy as full recursive pricing is out of scope.
    # We will just detect if it claims to be a fund.
    ethers_opts = Keyword.get(opts, :ethers_opts, [])
    call_opts = Keyword.put(ethers_opts, :to, address)

    case FundContracts.get_components() |> Ethers.call(call_opts) do
      {:ok, components} when is_list(components) ->
        description = "Tokenized Fund (TokenSet/PieDAO) with #{length(components)} components"

        state = %__MODULE__{
          address: address,
          # Defaulting to 18
          metadata: %{description: description, decimals: 18},
          ethers_opts: ethers_opts
        }

        Logger.info("Detected Tokenized Fund: #{description}")
        {:ok, state}

      _ ->
        {:error, :not_tokenized_fund}
    end
  end

  @impl true
  def metadata(state), do: state.metadata

  @impl true
  def fetch_history(_state, _from, _to, _chunk, _cb) do
    # Not implemented fully due to recursive pricing complexity.
    # Just logging that it would run here.
    Logger.warning(
      "Tokenized Fund history fetch not fully implemented (requires recursive oracle)"
    )

    :ok
  end
end
