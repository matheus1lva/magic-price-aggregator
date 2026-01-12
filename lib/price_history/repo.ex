defmodule PriceHistory.Repo do
  use Ecto.Repo,
    otp_app: :price_history,
    adapter: Ecto.Adapters.Postgres
end
