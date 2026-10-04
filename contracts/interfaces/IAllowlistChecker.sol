// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IAllowlistChecker
/// @notice Interface for pluggable compliance logic used by permissioned pools.
interface IAllowlistChecker {
    /// @notice Check if an account is allowed to interact with the pool.
    /// @param account The address to check.
    /// @param token The token address (or address(0) for generic checks).
    /// @return True if the account is allowed.
    function checkAllowlist(address account, address token) external view returns (bool);
}