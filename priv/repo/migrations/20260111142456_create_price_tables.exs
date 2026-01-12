defmodule PriceHistory.Repo.Migrations.CreatePriceTables do
  use Ecto.Migration

  def up do
    # Enable TimescaleDB (must be superuser usually, assuming user is or extension enabled)
    # Use execute with recover to avoid error if extension exists but permission denied to create?
    # Usually "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE" works.
    execute("CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE")

    create table(:price_feeds, primary_key: false) do
      add(:address, :string, primary_key: true)
      add(:description, :string)
      add(:decimals, :integer)
      timestamps()
    end

    create table(:price_points, primary_key: false) do
      add(
        :feed_address,
        references(:price_feeds, column: :address, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:round_id, :numeric, null: false)
      add(:price, :numeric, null: false)
      add(:timestamp, :utc_datetime, null: false)
      timestamps(updated_at: false)
    end

    # Turn into hypertable
    # migrated_data: true implies we might migrate data? No, regular create.
    execute("SELECT create_hypertable('price_points', 'timestamp', if_not_exists => TRUE);")

    # Index for fast lookups by feed and time
    create(index(:price_points, [:feed_address, :timestamp]))

    # Unique constraint (must include timestamp for hypertable)
    create(unique_index(:price_points, [:feed_address, :round_id, :timestamp]))
  end

  def down do
    drop(table(:price_points))
    drop(table(:price_feeds))
    # We do not drop the extension usually as other tables might use it, or requires superuser
  end
end
