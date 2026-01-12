defmodule PriceHistory.Repo.Migrations.AddBlockNumberToPricePoints do
  use Ecto.Migration

  def change do
    alter table(:price_points) do
      add(:block_number, :bigint)
    end

    create(index(:price_points, [:block_number]))
  end
end
