defmodule LogTest do
  alias PriceHistory.Chainlink.Contracts

  def run do
    # ETH/BTC Phase 2 Aggregator
    address = "0x7a5dc0c6a59e76b3a65c73224316c110663ced1b"
    # Event: AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt)
    # Sig: AnswerUpdated(int256,uint256,uint256)
    # Topic 0: 0x0559884e3a5dbbbffc667f3bf6f60a92a344d9f6ec710034a41e97d4c82f0a8d (example, need to verify or use ABI)

    # We can use Ethers to decode if we have ABI.
    # priv/abi/offchain.json doesn't have events. WIll add it temporarily or use raw topic.

    # Let's try to query last 100000 blocks.
    {:ok, current_block} = Ethers.current_block_number()
    from_block = current_block - 100_000

    IO.puts("Fetching logs from #{from_block} to #{current_block} for #{address}")

    # Event signature for AnswerUpdated(int256,uint256,uint256)
    # Using the standard Chainlink signature:
    # 0x0559884e3a5dbbbffc667f3bf6f60a92a344d9f6ec710034a41e97d4c82f0a8d
    topic0 = "0x0559884e3a5dbbbffc667f3bf6f60a92a344d9f6ec710034a41e97d4c82f0a8d"

    filter = %{
      address: address,
      fromBlock: from_block,
      toBlock: current_block
      # topics: [topic0] removed to debug
    }

    case Ethers.get_logs(filter) do
      {:ok, logs} ->
        IO.puts("Found #{length(logs)} logs.")

        Enum.take(logs, 5)
        |> Enum.each(fn log ->
          IO.inspect(log, label: "Log")
          # log.block_number should be present
          IO.puts("Block: #{log.block_number}")
        end)

      error ->
        IO.inspect(error, label: "Error fetching logs")
    end
  end
end

LogTest.run()
