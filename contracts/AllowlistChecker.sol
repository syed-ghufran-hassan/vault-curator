// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAllowlistChecker} from "./interfaces/IAllowlistChecker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title AllowlistChecker
/// @notice Compliance logic for permissioned pools. Supports three gating modes:
///         allowlist, NFT-gated, and token-gated.
contract AllowlistChecker is IAllowlistChecker, IERC165, Ownable {
    enum GatingMode {
        ALLOWLIST,
        NFT_GATED,
        TOKEN_GATED
    }

    GatingMode public mode;
    mapping(address => bool) public allowlist;
    address public gatingNFT;
    address public gatingToken;
    uint256 public gatingTokenThreshold;

    event AllowlistUpdated(address indexed account, bool allowed);
    event GatingModeUpdated(GatingMode mode);
    event GatingNFTUpdated(address indexed nft);
    event GatingTokenUpdated(address indexed token, uint256 threshold);

    constructor(address _owner) Ownable(_owner) {
        mode = GatingMode.ALLOWLIST;
    }

    /// @inheritdoc IAllowlistChecker
    function checkAllowlist(address account, address) external view override returns (bool) {
        if (mode == GatingMode.ALLOWLIST) {
            return allowlist[account];
        } else if (mode == GatingMode.NFT_GATED) {
            if (gatingNFT == address(0)) return false;
            return IERC721(gatingNFT).balanceOf(account) > 0;
        } else if (mode == GatingMode.TOKEN_GATED) {
            if (gatingToken == address(0)) return false;
            return IERC20(gatingToken).balanceOf(account) >= gatingTokenThreshold;
        }
        return false;
    }

    // ============ Admin ============

    function setAllowlist(address account, bool allowed) external onlyOwner {
        allowlist[account] = allowed;
        emit AllowlistUpdated(account, allowed);
    }

    function batchSetAllowlist(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            allowlist[accounts[i]] = allowed;
            emit AllowlistUpdated(accounts[i], allowed);
        }
    }

    function setGatingMode(GatingMode _mode) external onlyOwner {
        mode = _mode;
        emit GatingModeUpdated(_mode);
    }

    function setGatingNFT(address _nft) external onlyOwner {
        gatingNFT = _nft;
        emit GatingNFTUpdated(_nft);
    }

    function setGatingToken(address _token, uint256 _threshold) external onlyOwner {
        gatingToken = _token;
        gatingTokenThreshold = _threshold;
        emit GatingTokenUpdated(_token, _threshold);
    }

    // ============ ERC-165 ============

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IAllowlistChecker).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}