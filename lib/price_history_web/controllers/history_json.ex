defmodule PriceHistoryWeb.HistoryJSON do
  def index(%{price_points: price_points}) do
    %{data: for(point <- price_points, do: data(point))}
  end

  def data(point) do
    %{
      round_id: to_string(point.round_id),
      price: to_string(point.price),
      timestamp: to_string(point.timestamp),
      block_number: point.block_number
    }
  end
end
