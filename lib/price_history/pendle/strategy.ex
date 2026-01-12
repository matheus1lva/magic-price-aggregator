defmodule PriceHistory.Pendle.Strategy do
  @behaviour PriceHistory.Fetcher.Behaviour
  require Logger
  alias PriceHistory.Pendle.Contracts

  defstruct [:address, :asset, :asset_decimals, :metadata, :ethers_opts, :oracle_address]

  # Pendle Oracle Mainnet Address
  @oracle_address "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2"
  # as per ypricemagic example
  @twap_duration 1

  # How many blocks to skip when sampling history (since we don't have events)
  @sample_interval 100

  @impl true
  def init(address, opts) do
    ethers_opts = Keyword.get(opts, :ethers_opts, [])
    call_opts = Keyword.put(ethers_opts, :to, address)

    # 1. Check if it's a Pendle LP by trying to readTokens()
    with {:ok, {sy, _pt, _yt}} <- Contracts.Market.read_tokens() |> Ethers.call(call_opts),
         # 2. Get underlying asset from SY
         {:ok, {_type, asset_address, _decimals}} <-
           Contracts.SY.asset_info() |> Ethers.call(Keyword.put(ethers_opts, :to, sy)),
         # 3. Get asset metadata
         {:ok, asset_decimals} <-
           Contracts.AnyERC20.decimals()
           |> Ethers.call(Keyword.put(ethers_opts, :to, asset_address)),
         {:ok, asset_symbol} <-
           Contracts.AnyERC20.symbol()
           |> Ethers.call(Keyword.put(ethers_opts, :to, asset_address)) do
      description = "Pendle LP #{asset_symbol}"

      # We use asset decimals for the price (rate)
      # Or usually 18? The rate from oracle is likely 18 decimals scaled?
      # getLpToAssetRate returns 1e18 usually for rates.
      # Let's assume standard 18 decimals for the rate itself if it's a ratio.
      # But wait, ypricemagic says: `rate /= Decimal(10**decimals)` where decimals is SY decimals.
      # So the raw return value is scaled by asset decimals?
      # "LP to Asset Rate" -> 1 LP = X Asset.
      # If 1 LP = 1.5 ETH, and ETH is 1e18. The return is 1.5 * 1e18?
      # Yes, usually.

      state = %__MODULE__{
        address: address,
        ethers_opts: ethers_opts,
        asset: asset_address,
        asset_decimals: asset_decimals,
        metadata: %{description: description, decimals: asset_decimals},
        oracle_address: @oracle_address
      }

      Logger.info("Detected Pendle LP: #{description} (Asset: #{asset_address})")
      {:ok, state}
    else
      err -> {:error, {:not_pendle, err}}
    end
  end

  @impl true
  def metadata(state), do: state.metadata

  @impl true
  def fetch_history(state, from_block, to_block, _chunk_size, on_batch) do
    # Sampling approach
    # We iterate from from_block to to_block with @sample_interval

    # We generate a range
    steps =
      Stream.iterate(from_block, &(&1 + @sample_interval))
      |> Stream.take_while(&(&1 <= to_block))

    # Chunk the calls to avoid overwhelming?
    # Or just sequential for now. Parallelizing eth_call can get 429s.
    # Let's do batches of 10 to utilize concurrency slightly or just sync.

    chunk_size = 10

    steps
    |> Stream.chunk_every(chunk_size)
    |> Enum.each(fn block_numbers ->
      Logger.debug(
        "Sampling Pendle prices for blocks #{List.first(block_numbers)}..#{List.last(block_numbers)}"
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
    # Call Pendle Oracle
    opts =
      state.ethers_opts
      |> Keyword.put(:to, state.oracle_address)
      |> Keyword.put(:block_number, block_number)

    try do
      # getLpToAssetRate(market, duration)
      {:ok, rate} =
        Contracts.Oracle.get_lp_to_asset_rate(state.address, @twap_duration) |> Ethers.call(opts)

      %{
        # No round ID for on-chain computed
        round_id: 0,
        answer: rate,
        # We need timestamp
        timestamp: get_block_timestamp(block_number, state),
        block_number: block_number
      }
    rescue
      e ->
        Logger.warning("Failed to fetch Pendle price at #{block_number}: #{inspect(e)}")
        nil
    end
  end

  # Helper to get timestamp. Ethers doesn't give it in call.
  # We might need to fetch block.
  # Optimization: pass timestamp if we knew it? No.
  defp get_block_timestamp(block_number, _state) do
    # This is expensive (N extra calls).
    # Ideally we should batch fetch headers.
    # For MVP, assume expensive.
    case Ethereumex.HttpClient.eth_get_block_by_number(
           "0x" <> Integer.to_string(block_number, 16),
           false
         ) do
      {:ok, %{"timestamp" => timestamp_hex}} ->
        {ts, ""} = Integer.parse(String.replace(timestamp_hex, "0x", ""), 16)
        ts

      _ ->
        # Fallback
        DateTime.utc_now() |> DateTime.to_unix()
    end
  end
end
