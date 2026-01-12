import Config

if File.exists?(".env") do
  Dotenvy.source!(".env")
  |> System.put_env()
end

rpc_url = System.get_env("RPC_URL")

config :price_history,
  rpc_url: rpc_url

config :ethereumex,
  url: rpc_url

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :price_history, PriceHistory.Repo,
    ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :price_history, PriceHistoryWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    server: true,
    secret_key_base: secret_key_base
end

# Also configure for dev/test if env var is present
if System.get_env("DATABASE_URL") do
  config :price_history, PriceHistory.Repo,
    url: System.get_env("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
