// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Lending} from "@address-book/src/SDEthereum.sol";
import {IMorpho, MarketParams} from "@shared/src/interfaces/IMorpho.sol";
import {IStrategyWrapper} from "src/lending/interfaces/IStrategyWrapper.sol";
import {IMorphoLiquidationModule} from "src/lending/interfaces/IMorphoLiquidationModule.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title Morpho Blue Liquidation Module (Stake DAO)
 * @notice Permissionless swap-routing helper for liquidators operating Stake DAO wrapper-collateral markets on
 *         Morpho Blue. Anyone can call `liquidate` with any `receiver` (use `address(0)` to default to `msg.sender`).
 *         The module handles Morpho's callback, unwraps the seized collateral via `claimLiquidation`, swaps it for
 *         the loan asset via `_swapToLoanToken`, approves Morpho for the repayment, and forwards any surplus loan
 *         token plus any leftover unwrapped collateral to the receiver inside the same callback. The contract holds
 *         no funds across calls in steady state and has no admin surface.
 * @dev Assumptions and responsibilities:
 *      - The `collateralToken` of the market is an `IStrategyWrapper`.
 *      - The entrypoint encodes the pre-callback wrapper balance; the callback computes
 *        `seizedAssets = currentBalance - preBalance`.
 *      - Only Morpho can call back the `onMorphoLiquidate` liquidation hook.
 *      - This contract is configured for mainnet. Override `_morpho` for other networks.
 * @author Stake DAO
 * @custom:contact contact@stakedao.org
 */
contract MorphoLiquidationModule is ReentrancyGuard, IMorphoLiquidationModule {
    using SafeERC20 for IERC20;

    modifier onlyMorpho() {
        require(msg.sender == address(_morpho()), OnlyMorpho());
        _;
    }

    ///////////////////////////////////////////////////////////////
    // --- LIQUIDATION
    ///////////////////////////////////////////////////////////////

    /// @notice Liquidate a position on Morpho. Permissionless: any address may call.
    /// @param marketParams The market parameters of the position
    /// @param borrower The owner of the position
    /// @param seizedAssets The amount of collateral to seize
    /// @param repaidShares The amount of shares to repay
    /// @param swapData Encoded swap actions to convert seized collateral into loan token in the callback
    /// @param receiver Address that receives any surplus loan token and leftover unwrapped collateral.
    ///                 Pass `address(0)` to default to `msg.sender`.
    /// @return The amount of collateral seized
    /// @return The amount of shares repaid
    function liquidate(
        MarketParams calldata marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata swapData,
        address receiver
    ) external returns (uint256, uint256) {
        address effectiveReceiver = receiver == address(0) ? msg.sender : receiver;
        uint256 preCollateralBalance = IERC20(marketParams.collateralToken).balanceOf(address(this));
        bytes memory data = abi.encode(
            marketParams.collateralToken,
            preCollateralBalance,
            marketParams.loanToken,
            borrower,
            swapData,
            effectiveReceiver
        );
        return _morpho().liquidate(marketParams, borrower, seizedAssets, repaidShares, data);
    }

    /// @notice Callback function called by Morpho Blue after a liquidation event. It automatically claims the
    ///         liquidated amount of the Stake DAO LP tokens and receives the unwrapped version of the collateral.
    /// @dev Only Morpho Blue can call this function.
    /// @param repaidAssets The amount of debt to repay in loan asset. Pulled by Morpho Blue after this function returns.
    /// @param data The data passed to the liquidation event
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external onlyMorpho nonReentrant {
        (
            address collateral,
            uint256 preCollateralBalance,
            address loanToken,
            address victim,
            bytes memory swapData,
            address receiver
        ) = abi.decode(data, (address, uint256, address, address, bytes, address));

        // Calculate the amount of collateral seized
        uint256 seizedAssets = IERC20(collateral).balanceOf(address(this)) - preCollateralBalance;

        // Unwrap the collateral earned from the liquidation process for the Stake DAO LP tokens
        IStrategyWrapper(collateral).claimLiquidation(address(this), victim, seizedAssets);

        // Swap seized collateral for loan token
        _swapToLoanToken(swapData);
        IERC20(loanToken).approve(address(_morpho()), repaidAssets);

        _forwardSurplus(loanToken, repaidAssets, collateral, receiver);
    }

    ///////////////////////////////////////////////////////////////
    // --- INTERNAL HELPERS
    ///////////////////////////////////////////////////////////////

    /// @notice Swaps the unwrapped collateral for the loan asset in order to repay the debt.
    /// @param swapData Each element of the array represents a swap action. It is an encoded
    ///                 tuple of the target address and the data to call the target.
    function _swapToLoanToken(bytes memory swapData) internal virtual {
        bytes[] memory transactions = abi.decode(swapData, (bytes[]));
        for (uint256 i; i < transactions.length; i++) {
            (address target, bytes memory data) = abi.decode(transactions[i], (address, bytes));
            Address.functionCall(target, data);
        }
    }

    /// @dev Forwards any loan-token balance above `repaidAssets` and any leftover underlying (reward-vault token)
    ///      held by this contract to `receiver`. Reverts with `INSUFFICIENT_SWAP_OUTPUT` if the swap did not
    ///      produce enough loan token to cover Morpho's post-callback `transferFrom` of `repaidAssets`. The
    ///      `repaidAssets` portion stays in the contract for Morpho to pull after this function returns;
    ///      everything above that flows to `receiver` atomically before the return.
    /// @dev When `loanToken == underlying` the loan-token sweep already handles every excess balance, so the
    ///      separate underlying transfer is skipped. Reading the balance again at that point would observe the
    ///      reserved `repaidAssets` and send them to `receiver`, breaking Morpho's post-callback pull.
    function _forwardSurplus(address loanToken, uint256 repaidAssets, address collateral, address receiver) internal {
        uint256 loanBalance = IERC20(loanToken).balanceOf(address(this));
        require(loanBalance >= repaidAssets, INSUFFICIENT_SWAP_OUTPUT());

        uint256 loanSurplus = loanBalance - repaidAssets;
        if (loanSurplus != 0) {
            IERC20(loanToken).safeTransfer(receiver, loanSurplus);
        }

        address underlying = address(IStrategyWrapper(collateral).REWARD_VAULT());
        if (underlying != loanToken) {
            uint256 underlyingBalance = IERC20(underlying).balanceOf(address(this));
            if (underlyingBalance != 0) {
                IERC20(underlying).safeTransfer(receiver, underlyingBalance);
            }
        }
    }

    function _morpho() internal view virtual returns (IMorpho) {
        return IMorpho(Lending.MORPHO_BLUE);
    }
}
