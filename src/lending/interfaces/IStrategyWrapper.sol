// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IRewardVault} from "@strategies/src/interfaces/IRewardVault.sol";

interface IStrategyWrapper is IERC20, IERC20Metadata {
    function REWARD_VAULT() external view returns (IRewardVault);
    function LENDING_PROTOCOL() external view returns (address);

    // Deposit
    function depositShares(uint256 amount, address receiver) external;
    function depositAssets(uint256 amount, address receiver) external;

    // Withdraw
    function withdrawCollateral(uint256 amount) external;
    function withdraw(uint256 amount) external;

    // Claim main reward token (e.g. CRV)
    function claim(address receiver) external returns (uint256 amount);
    function claimExtraRewards(address receiver) external returns (uint256[] memory amounts);
    function claimExtraRewards(address receiver, address[] calldata tokens) external returns (uint256[] memory amounts);

    // Liquidation
    function claimLiquidation(address liquidator, address victim, uint256 liquidatedAmount) external;

    // Permissions
    function operators(address account) external view returns (address operator);
    function setOperator(address operator) external;

    /*──────────────────────────────────────────
      VIEW HELPERS
    ──────────────────────────────────────────*/
    function getPendingRewards(address user) external view returns (uint256 rewards);
    function getPendingExtraRewards(address user) external view returns (uint256[] memory rewards);
    function getPendingExtraRewards(address user, address token) external view returns (uint256 rewards);
    function lendingMarketId() external view returns (bytes32);
    function version() external pure returns (uint256);

    // Owner
    function initialize(bytes32 marketId) external;
}
