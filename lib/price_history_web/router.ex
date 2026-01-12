defmodule PriceHistoryWeb.Router do
  use Phoenix.Router, otp_app: :price_history

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", PriceHistoryWeb do
    pipe_through(:api)

    get("/history", HistoryController, :index)
  end
end
