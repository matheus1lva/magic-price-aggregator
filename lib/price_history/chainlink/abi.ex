defmodule PriceHistory.Chainlink.ABI do
  @moduledoc """
  ABIs for Chainlink interactions.
  """

  def aggregator_proxy do
    [
      %{
        "inputs" => [],
        "name" => "phaseId",
        "outputs" => [%{"internalType" => "uint16", "name" => "", "type" => "uint16"}],
        "stateMutability" => "view",
        "type" => "function"
      },
      %{
        "inputs" => [%{"internalType" => "uint16", "name" => "phaseId", "type" => "uint16"}],
        "name" => "phaseAggregators",
        "outputs" => [
          %{
            "internalType" => "contract AccessControlledOffchainAggregator",
            "name" => "",
            "type" => "address"
          }
        ],
        "stateMutability" => "view",
        "type" => "function"
      },
      %{
        "inputs" => [],
        "name" => "description",
        "outputs" => [%{"internalType" => "string", "name" => "", "type" => "string"}],
        "stateMutability" => "view",
        "type" => "function"
      },
      %{
        "inputs" => [],
        "name" => "decimals",
        "outputs" => [%{"internalType" => "uint8", "name" => "", "type" => "uint8"}],
        "stateMutability" => "view",
        "type" => "function"
      }
    ]
  end

  def offchain_aggregator do
    [
      %{
        "inputs" => [],
        "name" => "latestRound",
        "outputs" => [%{"internalType" => "uint256", "name" => "", "type" => "uint256"}],
        "stateMutability" => "view",
        "type" => "function"
      },
      %{
        "inputs" => [%{"internalType" => "uint256", "name" => "_roundId", "type" => "uint256"}],
        "name" => "getRoundData",
        "outputs" => [
          %{"internalType" => "uint80", "name" => "roundId", "type" => "uint80"},
          %{"internalType" => "int256", "name" => "answer", "type" => "int256"},
          %{"internalType" => "uint256", "name" => "startedAt", "type" => "uint256"},
          %{"internalType" => "uint256", "name" => "updatedAt", "type" => "uint256"},
          %{"internalType" => "uint80", "name" => "answeredInRound", "type" => "uint80"}
        ],
        "stateMutability" => "view",
        "type" => "function"
      },
      %{
        "inputs" => [%{"internalType" => "uint256", "name" => "_roundId", "type" => "uint256"}],
        "name" => "getTimestamp",
        "outputs" => [%{"internalType" => "uint256", "name" => "", "type" => "uint256"}],
        "stateMutability" => "view",
        "type" => "function"
      }
    ]
  end
end
