defmodule RawLogTest do
  # Using Ethereumex directly to avoid Ethers decoding logic crashing
  alias Ethereumex.HttpClient

  def run do
    address = "0x7a5dc0c6a59e76b3a65c73224316c110663ced1b"
    # AnswerUpdated(int256,uint256,uint256)
    topic0 = "0x0559884e3a5dbbbffc667f3bf6f60a92a344d9f6ec710034a41e97d4c82f0a8d"

    # Get current block
    {:ok, current_block_hex} = HttpClient.eth_block_number()
    {current_block, ""} = Integer.parse(String.replace(current_block_hex, "0x", ""), 16)

    from_block = current_block - 100_000

    # Convert to hex strings
    from_block_hex = "0x" <> Integer.to_string(from_block, 16)
    to_block_hex = "0x" <> Integer.to_string(current_block, 16)

    IO.puts(
      "Fetching raw logs from #{from_block} (#{from_block_hex}) to #{current_block} (#{to_block_hex})"
    )

    params = %{
      address: address,
      fromBlock: from_block_hex,
      toBlock: to_block_hex,
      topics: [topic0]
    }

    case HttpClient.eth_get_logs(params) do
      {:ok, logs} ->
        IO.puts("Found #{length(logs)} logs.")

        Enum.take(logs, 3)
        |> Enum.each(fn log ->
          IO.inspect(log, label: "Log Item")
          # Verify block number exists
        end)

      error ->
        IO.inspect(error, label: "RPC Error")
    end
  end
end

RawLogTest.run()
