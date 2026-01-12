defmodule PriceHistory.Chainlink.Fetcher do
  @moduledoc """
  Fetches Chainlink history using Event Logs.
  Supports legacy AnswerUpdated and OCR2 NewTransmission.
  """
  require Logger
  alias Ethereumex.HttpClient

  # AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt)
  @sig_answer_updated "0x0559884e3a5dbbbffc667f3bf6f60a92a344d9f6ec710034a41e97d4c82f0a8d"
  # NewTransmission(uint32 indexed aggregatorRoundId, int192 answer, address transmitter, int192[] observations, bytes observers, bytes32 rawReportContext)
  @sig_new_transmission "0xc797025feeeaf2cd924c99e9205acb8ec04d5cad21c41ce637a38fb6dee6016a"

  # Default chunk size for logs
  @default_chunk_size 2_000

  @doc """
  Fetches logs from `from_block` to `to_block` in chunks.
  Executes `on_batch` callback with a list of parsed price points.
  """
  def fetch_logs(
        contract_address,
        from_block,
        to_block,
        chunk_size \\ @default_chunk_size,
        on_batch
      ) do
    Logger.info("Starting log fetch for #{contract_address} from #{from_block} to #{to_block}")

    stream_chunks(from_block, to_block, chunk_size)
    |> Enum.each(fn {chunk_from, chunk_to} ->
      Logger.debug("Fetching logs #{chunk_from} - #{chunk_to}")

      case get_logs_chunk(contract_address, chunk_from, chunk_to) do
        {:ok, logs} ->
          parsed = Enum.map(logs, &parse_log/1) |> Enum.reject(&is_nil/1)

          if length(parsed) > 0 do
            on_batch.(parsed)
          end

        {:error, reason} ->
          Logger.error("Failed to fetch logs #{chunk_from}-#{chunk_to}: #{inspect(reason)}")
          # Simple retry
          Process.sleep(1000)

          case get_logs_chunk(contract_address, chunk_from, chunk_to) do
            {:ok, logs} ->
              parsed = Enum.map(logs, &parse_log/1) |> Enum.reject(&is_nil/1)
              on_batch.(parsed)

            _ ->
              Logger.error("Retry failed for #{chunk_from}-#{chunk_to}. Skipping.")
          end
      end
    end)
  end

  defp stream_chunks(from, to, size) do
    Stream.unfold(from, fn current_from ->
      if current_from > to do
        nil
      else
        current_to = min(current_from + size - 1, to)
        {{current_from, current_to}, current_to + 1}
      end
    end)
  end

  defp get_logs_chunk(address, from, to) do
    params = %{
      address: address,
      fromBlock: "0x" <> Integer.to_string(from, 16),
      toBlock: "0x" <> Integer.to_string(to, 16),
      # OR filter
      topics: [[@sig_answer_updated, @sig_new_transmission]]
    }

    HttpClient.eth_get_logs(params)
  end

  defp parse_log(%{"topics" => topics, "data" => data} = log) do
    block_number_hex = log["blockNumber"]

    try do
      {block_number, ""} = Integer.parse(String.replace(block_number_hex, "0x", ""), 16)

      case topics do
        # AnswerUpdated (Signature + 2 indexed)
        [@sig_answer_updated, price_hex, round_id_hex] ->
          {price, ""} = Integer.parse(String.replace(price_hex, "0x", ""), 16)
          {round_id, ""} = Integer.parse(String.replace(round_id_hex, "0x", ""), 16)
          {updated_at, ""} = Integer.parse(String.replace(data, "0x", ""), 16)

          %{
            round_id: round_id,
            answer: price,
            timestamp: updated_at,
            block_number: block_number
          }

        # NewTransmission (Signature + 1 indexed)
        [@sig_new_transmission, round_id_hex] ->
          {round_id, ""} = Integer.parse(String.replace(round_id_hex, "0x", ""), 16)

          # Price is first 32 bytes of data
          clean_data = String.replace(data, "0x", "")
          price_hex = String.slice(clean_data, 0, 64)
          {price, ""} = Integer.parse(price_hex, 16)

          # Timestamp
          timestamp =
            case log["blockTimestamp"] do
              ts_hex when is_binary(ts_hex) ->
                {ts, ""} = Integer.parse(String.replace(ts_hex, "0x", ""), 16)
                ts

              _ ->
                # If blockTimestamp is missing, we use 0 to trigger debug or fallback?
                # Or use current time?
                DateTime.utc_now() |> DateTime.to_unix()
            end

          %{
            round_id: round_id,
            answer: price,
            timestamp: timestamp,
            block_number: block_number
          }

        _ ->
          nil
      end
    rescue
      # Ignore parse errors
      _ -> nil
    end
  end

  defp parse_log(_), do: nil
end
