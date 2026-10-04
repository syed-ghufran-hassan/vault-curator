// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategyRegistry} from "./interfaces/IStrategyRegistry.sol";

/// @title StrategyRegistry
/// @notice Registry for curated LP strategies. Managers register vaults,
///         depositors browse and migrate between them.
contract StrategyRegistry is IStrategyRegistry, Ownable {
    Strategy[] public strategies;
    mapping(address => uint256) public vaultToStrategyId; // 1-indexed
    mapping(address => bool) public authorizedManagers;

    event StrategyRegistered(
        uint256 indexed id,
        address indexed vault,
        address indexed manager,
        string name
    );
    event StrategyUpdated(uint256 indexed id, uint256 apy, uint256 sharpe, uint256 maxDrawdown);
    event StrategyDeactivated(uint256 indexed id);
    event Migrated(address indexed depositor, address fromVault, address toVault, uint256 amount);
    event ManagerAuthorized(address indexed manager, bool authorized);

    constructor(address _owner) Ownable(_owner) {}

    // ============ Registration ============

    function registerStrategy(
        address vault,
        address manager,
        string calldata name,
        string calldata metadataURI
    ) external override returns (uint256 id) {
        require(vault != address(0), "zero vault");
        require(manager != address(0), "zero manager");
        require(vaultToStrategyId[vault] == 0, "vault already registered");

        id = strategies.length;
        strategies.push(Strategy({
            vault: vault,
            manager: manager,
            name: name,
            metadataURI: metadataURI,
            apy: 0,
            sharpe: 0,
            maxDrawdown: 0,
            totalDeposits: 0,
            active: true,
            registeredAt: block.timestamp
        }));

        vaultToStrategyId[vault] = id + 1;
        emit StrategyRegistered(id, vault, manager, name);
    }

    // ============ Performance Updates ============

    function updatePerformance(
        uint256 id,
        uint256 apy,
        uint256 sharpe,
        uint256 maxDrawdown
    ) external override {
        require(id < strategies.length, "invalid id");
        Strategy storage s = strategies[id];
        require(msg.sender == s.manager || msg.sender == owner(), "not authorized");
        s.apy = apy;
        s.sharpe = sharpe;
        s.maxDrawdown = maxDrawdown;
        emit StrategyUpdated(id, apy, sharpe, maxDrawdown);
    }

    // ============ Migration ============

    function migrate(
        address fromVault,
        address toVault,
        uint256 amount
    ) external override {
        uint256 fromId = vaultToStrategyId[fromVault];
        uint256 toId = vaultToStrategyId[toVault];
        require(fromId > 0 && toId > 0, "vault not registered");
        require(strategies[fromId - 1].active, "from vault inactive");
        require(strategies[toId - 1].active, "to vault inactive");

        // Production: withdraw from fromVault (settling fees), deposit into toVault.
        emit Migrated(msg.sender, fromVault, toVault, amount);
    }

    // ============ View ============

    function getStrategy(uint256 id) external view override returns (Strategy memory) {
        require(id < strategies.length, "invalid id");
        return strategies[id];
    }

    function getStrategyCount() external view override returns (uint256) {
        return strategies.length;
    }

    function getActiveStrategies() external view override returns (Strategy[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].active) count++;
        }
        Strategy[] memory result = new Strategy[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].active) {
                result[j] = strategies[i];
                j++;
            }
        }
        return result;
    }

    // ============ Admin ============

    function deactivateStrategy(uint256 id) external {
        require(id < strategies.length, "invalid id");
        Strategy storage s = strategies[id];
        require(msg.sender == s.manager || msg.sender == owner(), "not authorized");
        s.active = false;
        emit StrategyDeactivated(id);
    }

    function authorizeManager(address manager, bool authorized) external onlyOwner {
        authorizedManagers[manager] = authorized;
        emit ManagerAuthorized(manager, authorized);
    }
}