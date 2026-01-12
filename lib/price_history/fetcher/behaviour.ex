defmodule PriceHistory.Fetcher.Behaviour do
  @moduledoc """
  Behavior for different price fetching strategies (Chainlink, Pendle, etc).
  """

  @doc """
  Initializes the strategy.
  Returns {:ok, state} or {:error, reason}.
  Should perform initial checks (e.g. detect if address is valid for this strategy)
  and load metadata (decimals, description).
  """
  @callback init(address :: String.t(), opts :: keyword()) ::
              {:ok, state :: any()} | {:error, any()}

  @doc """
  Fetches historical data for a range of blocks.
  Calls `on_batch` with a list of parsed maps:
  %{
    block_number: integer(),
    timestamp: integer(), (unix seconds)
    answer: integer() | Decimal.t(),
    round_id: integer() (optional, 0 if not applicable)
  }
  """
  @callback fetch_history(
              state :: any(),
              from_block :: integer(),
              to_block :: integer(),
              chunk_size :: integer(),
              on_batch :: (list() -> any())
            ) :: :ok | {:error, any()}

  @doc """
  Returns metadata about the feed.
  """
  @callback metadata(state :: any()) :: %{
              description: String.t(),
              decimals: integer()
            }
end
