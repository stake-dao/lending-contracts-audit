// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

/// @title IMorphoFlashLoanCallback
/// @notice Interface for Morpho Blue flash loan callbacks
interface IMorphoFlashLoanCallback {
    /// @notice Callback for flash loan
    /// @dev The callback is called by Morpho after transferring the flash-loaned assets
    /// @param assets The amount of assets that were flash-loaned
    /// @param data The data passed to the flash loan function
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}
