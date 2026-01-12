import Config

config :price_history, PriceHistory.Repo,
  database: "price_history_dev",
  username: "postgres",
  password: "postgrespassword",
  hostname: "localhost"

config :price_history,
  ecto_repos: [PriceHistory.Repo],
  generators: [timestamp_type: :utc_datetime]

config :price_history, PriceHistoryWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: PriceHistoryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PriceHistory.PubSub,
  live_view: [signing_salt: "SECRET_SALT_CHANGE_ME"]

config :phoenix, :json_library, Jason
