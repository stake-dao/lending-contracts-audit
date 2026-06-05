// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMorpho, MarketParams, Id, MarketParamsLib} from "@shared/src/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "@shared/src/interfaces/IMorphoFlashLoanCallback.sol";
import {IStrategyWrapper} from "src/lending/interfaces/IStrategyWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title StrategyWrapperLeverageRouter
/// @notice Atomic leverage/deleverage for Stake DAO Strategy Wrapper markets
/// @dev Uses Morpho flashloans, Enso for swaps, integrates with StrategyWrapper.
contract StrategyWrapperLeverageRouter is IMorphoFlashLoanCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    IMorpho public immutable MORPHO;
    address public immutable ENSO;

    /// @notice Flashloan context passed via callback data
    struct FlashLoanContext {
        address user;
        IStrategyWrapper wrapper;
        MarketParams marketParams;
        bool isLeverage;
        // Leverage params
        uint256 initialShares;
        uint256 minSharesOut;
        uint256 borrowAmount;
        // Deleverage params
        uint256 debtToRepay;
        uint256 collateralToWithdraw;
        uint256 minLoanTokenOut;
        // Swap
        bytes swapData;
        // Token entry params (used by leverageWithToken)
        address inputToken;
        uint256 inputAmount;
        bytes inputSwapData;
    }

    error Unauthorized();
    error SlippageExceeded();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidWrapper();
    error MissingInputSwapData();
    error MarketMismatch();

    event Leverage(
        address indexed user,
        Id indexed marketId,
        uint256 initialShares,
        uint256 flashLoanAmount,
        uint256 borrowAmount
    );

    event Deleverage(
        address indexed user,
        Id indexed marketId,
        uint256 collateralWithdrawn,
        uint256 debtRepaid
    );

    constructor(address morpho, address enso) {
        require(morpho != address(0) && enso != address(0), ZeroAddress());
        MORPHO = IMorpho(morpho);
        ENSO = enso;
    }

    /// @notice Leverage: flashloan → swap → deposit → borrow (atomic)
    /// @dev Caller must have already authorized this contract on Morpho
    /// @param wrapper The StrategyWrapper contract for this market
    /// @param marketParams The Morpho market parameters
    /// @param initialShares Amount of RewardVault shares to deposit initially (can be 0)
    /// @param flashLoanAmount Amount of loan token to flashloan for swapping
    /// @param minSharesOut Minimum RewardVault shares from swap (slippage protection)
    /// @param borrowAmount Amount to borrow to repay flashloan
    /// @param swapData Calldata for Enso swap (loan token → RewardVault shares)
    function leverage(
        IStrategyWrapper wrapper,
        MarketParams calldata marketParams,
        uint256 initialShares,
        uint256 flashLoanAmount,
        uint256 minSharesOut,
        uint256 borrowAmount,
        bytes calldata swapData
    ) external nonReentrant {
        _validateInputs(wrapper, marketParams);
        _leverage(wrapper, marketParams, initialShares, flashLoanAmount, minSharesOut, borrowAmount, swapData);
    }

    function _leverage(
        IStrategyWrapper wrapper,
        MarketParams calldata marketParams,
        uint256 initialShares,
        uint256 flashLoanAmount,
        uint256 minSharesOut,
        uint256 borrowAmount,
        bytes calldata swapData
    ) internal {
        address rewardVault = address(wrapper.REWARD_VAULT());

        // Snapshot balances for delta-based refunds
        uint256 loanSnapshot = IERC20(marketParams.loanToken).balanceOf(address(this));
        uint256 sharesSnapshot = IERC20(rewardVault).balanceOf(address(this));

        // Transfer initial shares from user if provided
        if (initialShares > 0) {
            IERC20(rewardVault).safeTransferFrom(msg.sender, address(this), initialShares);
        }

        // Encode context for callback
        bytes memory callbackData = abi.encode(
            FlashLoanContext({
                user: msg.sender,
                wrapper: wrapper,
                marketParams: marketParams,
                isLeverage: true,
                initialShares: initialShares,
                minSharesOut: minSharesOut,
                borrowAmount: borrowAmount,
                debtToRepay: 0,
                collateralToWithdraw: 0,
                minLoanTokenOut: 0,
                swapData: swapData,
                inputToken: address(0),
                inputAmount: 0,
                inputSwapData: ""
            })
        );

        // Execute flashloan - callback will handle the rest
        MORPHO.flashLoan(marketParams.loanToken, flashLoanAmount, callbackData);

        // Refund any surplus loan tokens or shares (delta only)
        _refundDelta(msg.sender, marketParams.loanToken, loanSnapshot);
        _refundDelta(msg.sender, rewardVault, sharesSnapshot);

        emit Leverage(msg.sender, marketParams.id(), initialShares, flashLoanAmount, borrowAmount);
    }

    /// @notice Leverage with any ERC20 token as entry (atomic)
    /// @dev When inputToken == loanToken, pass empty inputSwapData and include
    ///      inputAmount in the leverageSwapData route for a single optimized swap.
    ///      Caller must have already authorized this contract on Morpho.
    /// @param wrapper The StrategyWrapper contract for this market
    /// @param marketParams The Morpho market parameters
    /// @param inputToken The ERC20 token the user provides as equity
    /// @param inputAmount Amount of inputToken to take from user
    /// @param flashLoanAmount Amount of loan token to flashloan
    /// @param minSharesOut Minimum total RewardVault shares from all swaps
    /// @param borrowAmount Amount to borrow to repay flashloan
    /// @param inputSwapData Enso swap: inputToken → RewardVault shares (empty if inputToken == loanToken)
    /// @param leverageSwapData Enso swap: loan token → RewardVault shares
    function leverageWithToken(
        IStrategyWrapper wrapper,
        MarketParams calldata marketParams,
        address inputToken,
        uint256 inputAmount,
        uint256 flashLoanAmount,
        uint256 minSharesOut,
        uint256 borrowAmount,
        bytes calldata inputSwapData,
        bytes calldata leverageSwapData
    ) external nonReentrant {
        _validateInputs(wrapper, marketParams);
        require(inputToken != address(0), ZeroAddress());
        require(inputAmount > 0, ZeroAmount());
        // Non-loan tokens must provide a swap route, otherwise they'd be stranded
        if (inputToken != marketParams.loanToken) {
            require(inputSwapData.length > 0, MissingInputSwapData());
        }

        _leverageWithTokenInner(wrapper, marketParams, inputToken, inputAmount, flashLoanAmount, minSharesOut, borrowAmount, inputSwapData, leverageSwapData);

        emit Leverage(msg.sender, marketParams.id(), 0, flashLoanAmount, borrowAmount);
    }

    function _leverageWithTokenInner(
        IStrategyWrapper wrapper,
        MarketParams calldata marketParams,
        address inputToken,
        uint256 inputAmount,
        uint256 flashLoanAmount,
        uint256 minSharesOut,
        uint256 borrowAmount,
        bytes calldata inputSwapData,
        bytes calldata leverageSwapData
    ) internal {
        address rewardVault = address(wrapper.REWARD_VAULT());

        // Snapshot balances for delta-based refunds
        uint256[3] memory snapshots = _snapshotBalances(inputToken, marketParams.loanToken, rewardVault);

        // Transfer input tokens from user
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        // Encode context for callback
        bytes memory callbackData = abi.encode(
            FlashLoanContext({
                user: msg.sender,
                wrapper: wrapper,
                marketParams: marketParams,
                isLeverage: true,
                initialShares: 0,
                minSharesOut: minSharesOut,
                borrowAmount: borrowAmount,
                debtToRepay: 0,
                collateralToWithdraw: 0,
                minLoanTokenOut: 0,
                swapData: leverageSwapData,
                inputToken: inputToken,
                inputAmount: inputAmount,
                inputSwapData: inputSwapData
            })
        );

        // Execute flashloan - callback will handle the rest
        MORPHO.flashLoan(marketParams.loanToken, flashLoanAmount, callbackData);

        // Refund any surplus tokens (delta only, ignores pre-existing balances)
        _refundSurplus(msg.sender, inputToken, marketParams.loanToken, rewardVault, snapshots);
    }

    /// @notice Deleverage: flashloan → repay → withdraw → claimLiquidation → swap (atomic)
    /// @dev Caller must have already authorized this contract on Morpho
    /// @param wrapper The StrategyWrapper contract for this market
    /// @param marketParams The Morpho market parameters
    /// @param flashLoanAmount Amount of loan token to flashloan
    /// @param debtToRepay Amount of debt to repay on Morpho
    /// @param collateralToWithdraw Amount of wrapped tokens to withdraw
    /// @param minLoanTokenOut Minimum loan tokens after swap (slippage protection)
    /// @param swapData Calldata for Enso swap (RewardVault shares → loan token)
    function deleverage(
        IStrategyWrapper wrapper,
        MarketParams calldata marketParams,
        uint256 flashLoanAmount,
        uint256 debtToRepay,
        uint256 collateralToWithdraw,
        uint256 minLoanTokenOut,
        bytes calldata swapData
    ) external nonReentrant {
        _validateInputs(wrapper, marketParams);
        require(collateralToWithdraw > 0, ZeroAmount());
        _deleverage(wrapper, marketParams, flashLoanAmount, debtToRepay, collateralToWithdraw, minLoanTokenOut, swapData);
    }

    function _deleverage(
        IStrategyWrapper wrapper,
        MarketParams calldata marketParams,
        uint256 flashLoanAmount,
        uint256 debtToRepay,
        uint256 collateralToWithdraw,
        uint256 minLoanTokenOut,
        bytes calldata swapData
    ) internal {
        address rewardVault = address(wrapper.REWARD_VAULT());

        // Snapshot balances for delta-based refunds
        uint256 loanSnapshot = IERC20(marketParams.loanToken).balanceOf(address(this));
        uint256 sharesSnapshot = IERC20(rewardVault).balanceOf(address(this));

        // Encode context for callback
        bytes memory callbackData = abi.encode(
            FlashLoanContext({
                user: msg.sender,
                wrapper: wrapper,
                marketParams: marketParams,
                isLeverage: false,
                initialShares: 0,
                minSharesOut: 0,
                borrowAmount: 0,
                debtToRepay: debtToRepay,
                collateralToWithdraw: collateralToWithdraw,
                minLoanTokenOut: minLoanTokenOut,
                swapData: swapData,
                inputToken: address(0),
                inputAmount: 0,
                inputSwapData: ""
            })
        );

        // Execute flashloan - callback will handle the rest
        MORPHO.flashLoan(marketParams.loanToken, flashLoanAmount, callbackData);

        // Refund any surplus loan tokens or shares (delta only)
        _refundDelta(msg.sender, marketParams.loanToken, loanSnapshot);
        _refundDelta(msg.sender, rewardVault, sharesSnapshot);

        emit Deleverage(msg.sender, marketParams.id(), collateralToWithdraw, debtToRepay);
    }

    /// @notice Morpho flashloan callback
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(MORPHO), Unauthorized());

        FlashLoanContext memory ctx = abi.decode(data, (FlashLoanContext));

        if (ctx.isLeverage) {
            _executeLeverage(ctx, assets);
        } else {
            _executeDeleverage(ctx);
        }

        // Approve Morpho to pull flashloan repayment
        IERC20(ctx.marketParams.loanToken).forceApprove(address(MORPHO), assets);
    }

    function _executeLeverage(FlashLoanContext memory ctx, uint256 flashLoanAmount) internal {
        IERC20 loanToken = IERC20(ctx.marketParams.loanToken);
        address rewardVault = address(ctx.wrapper.REWARD_VAULT());
        uint256 totalShares = ctx.initialShares;

        // 1. Swap input token → RewardVault shares (if input ≠ loan token)
        if (ctx.inputAmount > 0 && ctx.inputSwapData.length > 0) {
            uint256 preBalance = IERC20(rewardVault).balanceOf(address(this));
            IERC20(ctx.inputToken).forceApprove(ENSO, ctx.inputAmount);
            Address.functionCall(ENSO, ctx.inputSwapData);
            IERC20(ctx.inputToken).forceApprove(ENSO, 0);
            totalShares += IERC20(rewardVault).balanceOf(address(this)) - preBalance;
        }

        // 2. Swap loan token → RewardVault shares via Enso
        //    When inputToken == loanToken, inputAmount sits in the contract
        //    and gets swapped together with the flashloaned amount.
        uint256 loanSwapAmount = flashLoanAmount;
        if (ctx.inputAmount > 0 && ctx.inputSwapData.length == 0) {
            loanSwapAmount += ctx.inputAmount;
        }
        uint256 preSwapBalance = IERC20(rewardVault).balanceOf(address(this));
        loanToken.forceApprove(ENSO, loanSwapAmount);
        Address.functionCall(ENSO, ctx.swapData);
        loanToken.forceApprove(ENSO, 0);
        totalShares += IERC20(rewardVault).balanceOf(address(this)) - preSwapBalance;

        require(totalShares >= ctx.minSharesOut, SlippageExceeded());

        // 3. Deposit all shares into StrategyWrapper for user
        IERC20(rewardVault).forceApprove(address(ctx.wrapper), totalShares);
        ctx.wrapper.depositShares(totalShares, ctx.user);

        // 4. Borrow from Morpho to repay flashloan
        MORPHO.borrow(ctx.marketParams, ctx.borrowAmount, 0, ctx.user, address(this));
    }

    function _executeDeleverage(FlashLoanContext memory ctx) internal {
        IERC20 loanToken = IERC20(ctx.marketParams.loanToken);
        address rewardVault = address(ctx.wrapper.REWARD_VAULT());

        // 1. Repay user's debt on Morpho
        if (ctx.debtToRepay == type(uint256).max) {
            // Full repayment: use shares-based repay to avoid rounding dust
            Id marketId = ctx.marketParams.id();
            uint128 borrowShares = MORPHO.position(marketId, ctx.user).borrowShares;
            if (borrowShares > 0) {
                loanToken.forceApprove(address(MORPHO), type(uint256).max);
                MORPHO.repay(ctx.marketParams, 0, borrowShares, ctx.user, "");
            }
        } else if (ctx.debtToRepay > 0) {
            loanToken.forceApprove(address(MORPHO), ctx.debtToRepay);
            MORPHO.repay(ctx.marketParams, ctx.debtToRepay, 0, ctx.user, "");
        }

        // 2. Withdraw collateral from Morpho to this contract
        MORPHO.withdrawCollateral(ctx.marketParams, ctx.collateralToWithdraw, ctx.user, address(this));

        // 3. Sync accounting via claimLiquidation and get RewardVault shares
        // This works for voluntary withdrawals to different receivers (see StrategyWrapper docs)
        ctx.wrapper.claimLiquidation(address(this), ctx.user, ctx.collateralToWithdraw);

        // 4. Swap RewardVault shares → loan token via Enso
        uint256 preSwapBalance = loanToken.balanceOf(address(this));
        IERC20(rewardVault).forceApprove(ENSO, ctx.collateralToWithdraw);
        Address.functionCall(ENSO, ctx.swapData);
        IERC20(rewardVault).forceApprove(ENSO, 0);

        uint256 postSwapBalance = loanToken.balanceOf(address(this));
        require(postSwapBalance - preSwapBalance >= ctx.minLoanTokenOut, SlippageExceeded());

        // Surplus loan tokens are refunded by the caller via delta-based _refundDelta
    }

    /// @dev Snapshot balances for delta-based refunds.
    ///      Returns [inputTokenBalance, loanTokenBalance, rewardVaultBalance].
    ///      If inputToken == loanToken, inputTokenBalance is 0.
    function _snapshotBalances(address inputToken, address loanToken, address rewardVault)
        internal
        view
        returns (uint256[3] memory snapshots)
    {
        snapshots[1] = IERC20(loanToken).balanceOf(address(this));
        snapshots[2] = IERC20(rewardVault).balanceOf(address(this));
        if (inputToken != loanToken) {
            snapshots[0] = IERC20(inputToken).balanceOf(address(this));
        }
    }

    /// @dev Refund surplus tokens to the user based on delta from snapshots.
    function _refundSurplus(
        address recipient,
        address inputToken,
        address loanToken,
        address rewardVault,
        uint256[3] memory snapshots
    ) internal {
        // Refund surplus loan tokens
        _refundDelta(recipient, loanToken, snapshots[1]);

        // Refund surplus input tokens (if different from loan token)
        if (inputToken != loanToken) {
            _refundDelta(recipient, inputToken, snapshots[0]);
        }

        // Refund surplus RewardVault shares
        _refundDelta(recipient, rewardVault, snapshots[2]);
    }

    /// @dev Refund surplus of a single token based on delta from snapshot.
    function _refundDelta(address recipient, address token, uint256 snapshot) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > snapshot) {
            IERC20(token).safeTransfer(recipient, balance - snapshot);
        }
    }

    function _validateInputs(IStrategyWrapper wrapper, MarketParams calldata marketParams) internal view {
        require(address(wrapper) != address(0), ZeroAddress());
        require(marketParams.collateralToken == address(wrapper), InvalidWrapper());
        require(Id.unwrap(marketParams.id()) == wrapper.lendingMarketId(), MarketMismatch());
    }

}
