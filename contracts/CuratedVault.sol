// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title CuratedVault
 * @notice ERC-4626 vault with management + high-water performance fees.
 *         LPs deposit assets and receive shares. The manager earns fees on
 *         yield above a high-water mark.
 */
contract CuratedVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Fee parameters ---
    uint256 public constant MAX_MGMT_FEE_BPS = 500;   // 5% annual
    uint256 public constant MAX_PERF_FEE_BPS = 2000;  // 20%
    uint256 public constant FEE_CHANGE_COOLDOWN = 7 days;
    uint256 public constant MAX_FEE_INCREASE_BPS = 100; // 1% per step

    uint256 public mgmtFeeBps;      // management fee in basis points
    uint256 public perfFeeBps;      // performance fee in basis points
    address public feeRecipient;

    uint256 public lastFeeAccrual;   // timestamp of last fee accrual
    uint256 public lastFeeChange;    // timestamp of last fee change

    // --- High-water mark (per-share price, only ratchets up) ---
    uint256 public highWaterMark;    // in asset terms per share (scaled by 1e18)

    // --- Safety ---
    uint256 public depositCap;       // 0 == uncapped
    bool public depositsPaused;

    // --- Events ---
    event FeesAccrued(uint256 mgmtFeeShares, uint256 perfFeeShares);
    event FeeRecipientUpdated(address indexed newRecipient);
    event MgmtFeeUpdated(uint256 oldBps, uint256 newBps);
    event PerfFeeUpdated(uint256 oldBps, uint256 newBps);
    event DepositCapUpdated(uint256 newCap);
    event DepositsPaused(bool paused);
    event HighWaterMarkUpdated(uint256 oldHwm, uint256 newHwm);

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _owner,
        address _feeRecipient,
        uint256 _mgmtFeeBps,
        uint256 _perfFeeBps
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(_owner) {
        require(_mgmtFeeBps <= MAX_MGMT_FEE_BPS, "mgmt fee too high");
        require(_perfFeeBps <= MAX_PERF_FEE_BPS, "perf fee too high");
        mgmtFeeBps = _mgmtFeeBps;
        perfFeeBps = _perfFeeBps;
        feeRecipient = _feeRecipient;
        lastFeeAccrual = block.timestamp;
        lastFeeChange = block.timestamp;
        highWaterMark = 1e18; // 1:1 initial price
    }

    // ============ ERC-4626 Overrides ============

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6; // virtual shares/assets defense against inflation attack
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (depositsPaused) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 current = totalAssets();
        if (current >= depositCap) return 0;
        return depositCap - current;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return convertToShares(maxAssets);
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _accrueFees();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _accrueFees();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _accrueFees();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _accrueFees();
        return super.redeem(shares, receiver, owner);
    }

    // ============ Fee Accrual ============

    /// @notice Accrue management and performance fees. Callable by anyone.
    function harvest() external nonReentrant {
        _accrueFees();
    }

    function _accrueFees() internal {
        uint256 elapsed = block.timestamp - lastFeeAccrual;
        if (elapsed == 0) return;

        uint256 supply = totalSupply();
        if (supply == 0) {
            lastFeeAccrual = block.timestamp;
            return;
        }

        uint256 total = totalAssets();
        uint256 mgmtFeeShares = 0;
        uint256 perfFeeShares = 0;

        // --- Management fee: linear in time and AUM ---
        if (mgmtFeeBps > 0) {
            uint256 mgmtFeeAssets = (total * mgmtFeeBps * elapsed) / (10_000 * 365 days);
            mgmtFeeShares = convertToShares(mgmtFeeAssets);
        }

        // --- Performance fee: profit above high-water mark ---
        if (perfFeeBps > 0) {
            uint256 currentPricePerShare = (total * 1e18) / supply;
            if (currentPricePerShare > highWaterMark) {
                uint256 profitPerShare = currentPricePerShare - highWaterMark;
                uint256 profitAssets = (profitPerShare * supply) / 1e18;
                uint256 perfFeeAssets = (profitAssets * perfFeeBps) / 10_000;
                perfFeeShares = convertToShares(perfFeeAssets);

                // Ratchet HWM up to current price
                uint256 oldHwm = highWaterMark;
                highWaterMark = currentPricePerShare;
                emit HighWaterMarkUpdated(oldHwm, highWaterMark);
            }
        }

        // Mint fee shares to recipient (dilution, not withdrawal)
        uint256 totalFeeShares = mgmtFeeShares + perfFeeShares;
        if (totalFeeShares > 0) {
            _mint(feeRecipient, totalFeeShares);
            emit FeesAccrued(mgmtFeeShares, perfFeeShares);
        }

        lastFeeAccrual = block.timestamp;
    }

    // ============ Admin Functions ============

    function setFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "zero address");
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(_recipient);
    }

    function setMgmtFee(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_MGMT_FEE_BPS, "above max");
        require(block.timestamp >= lastFeeChange + FEE_CHANGE_COOLDOWN, "cooldown");
        require(_bps <= mgmtFeeBps + MAX_FEE_INCREASE_BPS, "increase too large");
        uint256 old = mgmtFeeBps;
        mgmtFeeBps = _bps;
        lastFeeChange = block.timestamp;
        emit MgmtFeeUpdated(old, _bps);
    }

    function setPerfFee(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_PERF_FEE_BPS, "above max");
        require(block.timestamp >= lastFeeChange + FEE_CHANGE_COOLDOWN, "cooldown");
        require(_bps <= perfFeeBps + MAX_FEE_INCREASE_BPS, "increase too large");
        uint256 old = perfFeeBps;
        perfFeeBps = _bps;
        lastFeeChange = block.timestamp;
        emit PerfFeeUpdated(old, _bps);
    }

    function setDepositCap(uint256 _cap) external onlyOwner {
        depositCap = _cap;
        emit DepositCapUpdated(_cap);
    }

    function setDepositsPaused(bool _paused) external onlyOwner {
        depositsPaused = _paused;
        emit DepositsPaused(_paused);
    }

    // ============ Strategy Hooks ============

    /// @notice Called by the manager to deploy vault capital into a strategy.
    ///         The hook must be authorized to call this.
    function deployCapital(address strategy, uint256 amount) external onlyOwner {
        IERC20(asset()).safeTransfer(strategy, amount);
    }

    /// @notice Called by the manager to return capital from a strategy.
    function returnCapital(uint256 amount) external onlyOwner {
        // In practice, the strategy sends assets back to the vault
    }
}