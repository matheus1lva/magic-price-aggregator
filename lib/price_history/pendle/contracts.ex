defmodule PriceHistory.Pendle.Contracts do
  @moduledoc """
  Defines Pendle contracts.
  """

  defmodule Oracle do
    use Ethers.Contract, abi_file: "priv/abi/pendle_oracle.json"
  end

  defmodule Market do
    use Ethers.Contract, abi_file: "priv/abi/pendle_market.json"
  end

  defmodule SY do
    use Ethers.Contract, abi_file: "priv/abi/pendle_sy.json"
  end

  defmodule AnyERC20 do
    # Minimal ERC20 for decimals/symbol/name
    use Ethers.Contract, abi_file: "priv/abi/erc20_minimal.json"
  end
end
