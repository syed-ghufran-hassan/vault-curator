// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStrategyRegistry
/// @notice Interface for the strategy registry used by vaults and frontends.
interface IStrategyRegistry {
    struct Strategy {
        address vault;
        address manager;
        string name;
        string metadataURI;
        uint256 apy;
        uint256 sharpe;
        uint256 maxDrawdown;
        uint256 totalDeposits;
        bool active;
        uint256 registeredAt;
    }

    function registerStrategy(
        address vault,
        address manager,
        string calldata name,
        string calldata metadataURI
    ) external returns (uint256 id);

    function updatePerformance(
        uint256 id,
        uint256 apy,
        uint256 sharpe,
        uint256 maxDrawdown
    ) external;

    function migrate(address fromVault, address toVault, uint256 amount) external;

    function getStrategy(uint256 id) external view returns (Strategy memory);
    function getStrategyCount() external view returns (uint256);
    function getActiveStrategies() external view returns (Strategy[] memory);
}