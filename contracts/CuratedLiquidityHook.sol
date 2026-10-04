// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CuratedLiquidityHook
/// @notice Uniswap v4 hook that manages a curated LP position with
///         token-gating, dynamic fees, and oracle-triggered rebalancing.
contract CuratedLiquidityHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    // --- Token gating ---
    IAllowlistChecker public allowlistChecker;
    bool public gatingEnabled;

    // --- Dynamic fee parameters ---
    uint24 public baseFee;
    uint24 public maxFee;
    uint256 public volatilityThreshold;

    // --- Oracle / rebalance ---
    address public oracle;
    uint256 public maxDeviationBps;
    uint256 public lastRebalance;
    uint256 public rebalanceCooldown;

    // --- State ---
    mapping(PoolId => uint256) public swapVolume;
    mapping(PoolId => uint256) public lastSwapTimestamp;
    mapping(PoolId => uint256) public lastKnownPrice;

    // --- Events ---
    event AllowlistCheckerUpdated(address indexed checker);
    event GatingToggled(bool enabled);
    event DynamicFeeUpdated(uint24 baseFee, uint24 maxFee);
    event Rebalanced(PoolId indexed poolId, uint256 oldPrice, uint256 newPrice);
    event DeviationExceeded(PoolId indexed poolId, uint256 deviationBps);

    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _oracle,
        uint24 _baseFee,
        uint24 _maxFee
    ) BaseHook(_poolManager) Ownable(_owner) {
        require(_baseFee <= _maxFee, "base > max");
        oracle = _oracle;
        baseFee = _baseFee;
        maxFee = _maxFee;
        maxDeviationBps = 200;
        rebalanceCooldown = 1 hours;
        volatilityThreshold = 1e18;
    }

    // ============ Hook Permissions ============

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ beforeSwap: Dynamic Fees ============

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        uint256 currentPrice = _getOraclePrice();
        uint256 lastPrice = lastKnownPrice[poolId];
        if (lastPrice > 0) {
            uint256 deviation = _absDeviation(currentPrice, lastPrice);
            if (deviation > maxDeviationBps) {
                emit DeviationExceeded(poolId, deviation);
                return (
                    BaseHook.beforeSwap.selector,
                    BeforeSwapDeltaLibrary.ZERO_DELTA,
                    maxFee
                );
            }
        }

        uint256 volume = swapVolume[poolId];
        uint24 fee = _computeDynamicFee(volume);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    // ============ afterSwap: Volume Tracking ============

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        uint256 amount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
        swapVolume[poolId] += amount;
        lastSwapTimestamp[poolId] = block.timestamp;
        lastKnownPrice[poolId] = _getOraclePrice();
        return (BaseHook.afterSwap.selector, 0);
    }

    // ============ beforeAddLiquidity: Token Gating ============

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (gatingEnabled && address(allowlistChecker) != address(0)) {
            bool allowed = allowlistChecker.checkAllowlist(sender, address(0));
            require(allowed, "CuratedLiquidityHook: not allowlisted");
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    // ============ Rebalance ============

    function rebalance(PoolKey calldata key) external onlyOwner {
        require(
            block.timestamp >= lastRebalance + rebalanceCooldown,
            "CuratedLiquidityHook: cooldown"
        );

        PoolId poolId = key.toId();
        uint256 currentPrice = _getOraclePrice();
        uint256 lastPrice = lastKnownPrice[poolId];
        uint256 deviation = lastPrice > 0 ? _absDeviation(currentPrice, lastPrice) : 0;

        require(deviation > maxDeviationBps, "CuratedLiquidityHook: deviation too low");

        // Production: withdraw liquidity, compute new range, redeploy.
        lastKnownPrice[poolId] = currentPrice;
        lastRebalance = block.timestamp;
        emit Rebalanced(poolId, lastPrice, currentPrice);
    }

    // ============ Internal Helpers ============

    function _computeDynamicFee(uint256 volume) internal view returns (uint24) {
        if (volume > 1000e18) return maxFee;
        if (volume > 100e18) return baseFee + ((maxFee - baseFee) * 3) / 4;
        if (volume > 10e18) return baseFee + ((maxFee - baseFee) * 2) / 4;
        if (volume > 1e18) return baseFee + ((maxFee - baseFee) * 1) / 4;
        return baseFee;
    }

    function _getOraclePrice() internal view returns (uint256) {
        // TODO: integrate Chainlink / Pyth
        return 1e18;
    }

    function _absDeviation(uint256 price1, uint256 price2) internal pure returns (uint256) {
        return price1 > price2
            ? ((price1 - price2) * 10_000) / price2
            : ((price2 - price1) * 10_000) / price1;
    }

    // ============ Admin ============

    function setAllowlistChecker(address _checker) external onlyOwner {
        allowlistChecker = IAllowlistChecker(_checker);
        emit AllowlistCheckerUpdated(_checker);
    }

    function setGatingEnabled(bool _enabled) external onlyOwner {
        gatingEnabled = _enabled;
        emit GatingToggled(_enabled);
    }

    function setDynamicFee(uint24 _baseFee, uint24 _maxFee) external onlyOwner {
        require(_baseFee <= _maxFee, "base > max");
        baseFee = _baseFee;
        maxFee = _maxFee;
        emit DynamicFeeUpdated(_baseFee, _maxFee);
    }

    function setMaxDeviation(uint256 _bps) external onlyOwner {
        maxDeviationBps = _bps;
    }

    function setRebalanceCooldown(uint256 _seconds) external onlyOwner {
        rebalanceCooldown = _seconds;
    }
}