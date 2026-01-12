defmodule PriceHistory.Schema.Feed do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:address, :string, autogenerate: false}
  schema "price_feeds" do
    field(:description, :string)
    field(:decimals, :integer)

    timestamps()
  end

  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [:address, :description, :decimals])
    |> validate_required([:address, :description, :decimals])
    |> unique_constraint(:address)
  end
end
