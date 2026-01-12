defmodule PriceHistory.Schema.PricePoint do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "price_points" do
    field(:feed_address, :string)

    # uint80 fits in 64-bit integer? No, 80 bits fails. But typical RoundIDs are small? Or compose phaseId<<64 + round.
    field(:round_id, :decimal)
    # Chainlink RoundID is 80 bits. Ecto :integer is 64-bit signed. 9e18.
    # 2^64 is 1.8e19.
    # PhaseId is uint16. AggregatorRoundId is uint64.
    # Current PhaseId ~ 5.
    # So 5 * 2^64 + round is HUGE.
    # We should use :decimal for round_id or :string.
    # Ecto supports :decimal (Numeric).

    # int256 could count as decimal
    field(:price, :decimal)
    field(:timestamp, :utc_datetime)
    field(:block_number, :integer)

    # We don't use updated_at, inserted_at standard, but Timescale uses timestamp usually.
    # We can add inserted_at manually if needed.
    timestamps(updated_at: false)
  end

  def changeset(price_point, attrs) do
    price_point
    |> cast(attrs, [:feed_address, :round_id, :price, :timestamp, :block_number])
    |> validate_required([:feed_address, :round_id, :price, :timestamp, :block_number])
  end
end
