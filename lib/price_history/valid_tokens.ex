defmodule PriceHistory.ValidTokens do
  @moduledoc """
  Maps addresses to known token metadata. Used for identifying Quote tokens in LP pairs.
  """

  # Map of Address -> Decimals
  # Add commonly used quote tokens on Mainnet.
  # Keys should be downcased hex strings.
  @tokens %{
    # WETH
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" => %{symbol: "WETH", decimals: 18},
    # USDC
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" => %{symbol: "USDC", decimals: 6},
    # USDT
    "0xdac17f958d2ee523a2206206994597c13d831ec7" => %{symbol: "USDT", decimals: 6},
    # DAI
    "0x6b175474e89094c44da98b954eedeac495271d0f" => %{symbol: "DAI", decimals: 18}
  }

  def get_quote_token(address) do
    Map.get(@tokens, String.downcase(address))
  end
end
