defmodule PriceHistoryWeb.HistoryController do
  use Phoenix.Controller, formats: [:json]
  plug(:put_view, PriceHistoryWeb.HistoryJSON)

  alias PriceHistory.Store

  def index(conn, %{"address" => address} = params) do
    # Default time range: Last 24h
    now = DateTime.utc_now() |> DateTime.to_unix()
    start_ts = Map.get(params, "start_ts", to_string(now - 86400)) |> String.to_integer()
    end_ts = Map.get(params, "end_ts", to_string(now)) |> String.to_integer()

    price_points = Store.get_price_points(address, start_ts, end_ts)

    render(conn, :index, price_points: price_points)
  end

  def index(conn, _) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing address parameter"})
  end
end
