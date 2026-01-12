defmodule PriceHistory.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PriceHistory.Repo,
      {Phoenix.PubSub, name: PriceHistory.PubSub},
      PriceHistoryWeb.Endpoint,
      {Registry, keys: :unique, name: PriceHistory.Registry},
      {DynamicSupervisor, name: PriceHistory.Supervisor, strategy: :one_for_one}
      # Starts a worker by calling: PriceHistory.Worker.start_link(arg)
      # {PriceHistory.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PriceHistory.AppSupervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Load vaults in background
      Task.start(fn -> load_vaults() end)
      {:ok, pid}
    end
  end

  defp load_vaults do
    path = Application.app_dir(:price_history, "priv/vaults.json")

    if File.exists?(path) do
      require Logger
      Logger.info("Loading vaults from #{path}")

      data = File.read!(path) |> Jason.decode!()

      Enum.each(data, fn {chain_id, entries} ->
        # Look for RPC_URI_FOR_<CHAIN_ID>
        env_var = "RPC_URI_FOR_#{chain_id}"
        rpc_url = System.get_env(env_var)

        if rpc_url do
          Logger.info("Starting feeds for Chain #{chain_id} using #{env_var}")

          Enum.each(entries, fn entry ->
            address = Map.fetch!(entry, "address")
            start_block = Map.get(entry, "start_block")
            PriceHistory.Application.start_feed(address, rpc_url, start_block)
          end)
        else
          Logger.warning("No #{env_var} configured. Skipping feeds for Chain #{chain_id}.")
        end
      end)
    else
      require Logger
      Logger.warning("Vaults file not found at #{path}")
    end
  end

  def start_feed(contract_address, rpc_url, start_block \\ nil) do
    DynamicSupervisor.start_child(
      PriceHistory.Supervisor,
      {PriceHistory.PriceFeed,
       [contract_address: contract_address, rpc_url: rpc_url, start_block: start_block]}
    )
  end

  def get_price(contract_address, start_ts, end_ts) do
    # Lookup via Registry
    case Registry.lookup(PriceHistory.Registry, contract_address) do
      [{pid, _}] -> GenServer.call(pid, {:get_history, start_ts, end_ts}, 60_000)
      [] -> {:error, :feed_not_started}
    end
  end
end
