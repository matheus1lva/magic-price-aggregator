defmodule PriceHistory.Chainlink.Contracts do
  @moduledoc """
  Defines Chainlink contracts using Ethers macros.
  """

  # Using abi_file requires the file to be present at compile time.
  # We use absolute paths or paths relative to mix project?
  # Usually `priv/abi/aggregator.json` works if we setup external_resource.

  # However, to avoid path issues, let's just use @external_resource and read it.

  defmodule Aggregator do
    use Ethers.Contract, abi_file: "priv/abi/aggregator.json"
  end

  defmodule Offchain do
    use Ethers.Contract, abi_file: "priv/abi/offchain.json"
  end
end
