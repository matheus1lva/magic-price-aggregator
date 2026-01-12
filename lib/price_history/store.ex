defmodule PriceHistory.Store do
  alias PriceHistory.Repo
  alias PriceHistory.Schema.{Feed, PricePoint}

  def upsert_feed(address, description, decimals) do
    # Ensure correct types

    %Feed{}
    |> Feed.changeset(%{address: address, description: description, decimals: decimals})
    |> Repo.insert(
      on_conflict: {:replace, [:description, :decimals, :updated_at]},
      conflict_target: :address
    )
  end

  def insert_price_points(feed_address, rounds) do
    # Prepare maps for insert_all
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    points =
      Enum.map(rounds, fn round ->
        %{
          feed_address: feed_address,
          round_id: round.round_id,
          price: round.answer,
          timestamp: DateTime.from_unix!(round.timestamp),
          block_number: round.block_number,
          inserted_at: now
          # updated_at not present
        }
      end)

    # Batch insert
    # TimescaleDB handles high ingest rates.
    # on_conflict: :nothing because unique index includes timestamp, if we re-fetch same data.
    Repo.insert_all(PricePoint, points, on_conflict: :nothing)
    Repo.insert_all(PricePoint, points, on_conflict: :nothing)
  end

  def get_price_points(feed_address, start_ts, end_ts) do
    import Ecto.Query

    from(p in PricePoint,
      where: p.feed_address == ^feed_address,
      where: p.timestamp >= ^DateTime.from_unix!(start_ts),
      where: p.timestamp <= ^DateTime.from_unix!(end_ts),
      order_by: [asc: p.timestamp]
    )
    |> Repo.all()
  end
end
