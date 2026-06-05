// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRewardVault} from "@strategies/src/interfaces/IRewardVault.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IStrategyWrapper} from "src/lending/interfaces/IStrategyWrapper.sol";
import {IProtocolController} from "@strategies/src/interfaces/IProtocolController.sol";

interface IAccountant {
    /// @notice Tracks reward and supply data for each vault.
    /// @dev    Packed struct to minimize storage costs (3 storage slots).
    ///         This structure maintains the core accounting state for reward distribution.
    struct VaultData {
        uint256 integral; // Cumulative reward per token (scaled by SCALING_FACTOR)
        uint128 supply; // Total supply of vault tokens
        uint128 feeSubjectAmount; // Amount of rewards subject to fees
        uint128 totalAmount; // Total reward amount including fee-exempt rewards
        uint128 netCredited; // Net rewards already credited to users (after fees)
        uint128 reservedHarvestFee; // Harvest fees reserved but not yet paid out
        uint128 reservedProtocolFee; // Protocol fees reserved but not yet accrued
    }

    /// @notice Tracks individual user positions within a vault.
    /// @dev    Integral tracking enables O(1) reward calculations by storing the last known integral
    ///         value for each user, allowing efficient computation of rewards earned since last update.
    struct AccountData {
        uint128 balance; // User's token balance in the vault
        uint256 integral; // Last integral value when user's rewards were updated
        uint256 pendingRewards; // Rewards earned but not yet claimed
    }

    function claim(address[] calldata _gauges, bytes[] calldata harvestData) external;
    function vaults(address vault) external view returns (VaultData memory);
    function accounts(address vault, address account) external view returns (AccountData memory);
    function REWARD_TOKEN() external view returns (address);
    function SCALING_FACTOR() external view returns (uint128);
}

/// @title Stake DAO Strategy Wrapper
/// @notice Non-transferable ERC20 wrapper for Stake DAO RewardVault shares. It is designed for use as collateral in lending markets.
/// @dev   - Allows users to deposit RewardVault shares or underlying LP tokens, and receive non-transferable tokens (1:1 ratio)
///        - While the ERC20 tokens are held (even as collateral in lending markets), users can claim both main protocol rewards and extra rewards
///        - Handles the edge case where the main reward token is also listed as an extra reward
///        - Integrates with Stake DAO's reward and checkpointing logic to ensure users always receive the correct rewards, regardless of the custody
///        - Extra reward transfers use a dual-mode failure strategy (TransferFailureMode):
///          during user-initiated claims, a failing transfer reverts to protect the user from silent reward loss;
///          during liquidation, a failing transfer is silently skipped so that reverting extra reward tokens
///          (e.g. blacklisted recipient, paused token) cannot block liquidation resolution and create bad debt.
///          As a complementary mitigation, the RewardVault registrar should avoid adding extra reward tokens
///          with custom transfer logic (pausable, blacklistable, etc.).
/// @dev   CRITICAL SECURITY ASSUMPTION: This contract assumes that no external
///        contract can claim rewards on behalf of this contract. The RewardVault
///        and Accountant must never implement claim-on-behalf-of functionality
///        that could target this contract, as it would break internal accounting.
/// @author Stake DAO
/// @custom:contact contact@stakedao.org
/// @custom:github https://github.com/stake-dao/contracts-monorepo
contract StrategyWrapper is ERC20, IStrategyWrapper, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    ///////////////////////////////////////////////////////////////
    // --- IMMUTABLES/CONSTANTS
    ///////////////////////////////////////////////////////////////

    /// @notice The slot of the main reward token in the user checkpoint
    /// @dev    In order to optimize the storage, the main reward token is tracked in the same
    ///         mapping as the extra reward tokens by using the `address(0)` slot.
    ///         This internal value that is never supposed to be exposed must be used to read/write
    ///         the main reward token state.
    /// @dev    `address(0)` has been chosen to avoid collisions with the extra reward tokens.
    address internal constant MAIN_REWARD_TOKEN_SLOT = address(0);

    /// @notice Precision factor for reward calculations (18 decimals)
    uint256 internal constant PRECISION = 1e18;

    /// @notice Gauge backing the wrapped RewardVault
    address internal immutable GAUGE;

    /// @notice The address of the protocol controller contract
    IProtocolController internal immutable PROTOCOL_CONTROLLER;

    /// @notice The address of the accountant contract
    IAccountant internal immutable ACCOUNTANT;

    /// @dev Precision used by Accountant.integral (usually 1e27)
    uint128 internal immutable ACCOUNTANT_SCALING_FACTOR;

    /// @notice The address of the token that is being wrapped
    IRewardVault public immutable REWARD_VAULT;

    /// @notice The address of the lending protocol
    address public immutable LENDING_PROTOCOL;

    /// @notice Reward token emitted by the Accountant (e.g. CRV)
    IERC20 public immutable MAIN_REWARD_TOKEN;

    /// @notice Tracks user deposit data and reward checkpoints
    /// @param balance User's wrapped-share balance
    /// @param rewardPerTokenPaid Last per-token accumulator seen
    struct UserCheckpoint {
        uint256 balance;
        mapping(address token => uint256 amount) rewardPerTokenPaid;
    }

    /// @notice Controls whether extra reward transfer failures revert or are silently skipped.
    /// @dev    Revert: used for user-initiated claims where losing rewards is unacceptable.
    ///         Silent: used during liquidation where protocol liveness takes priority over extra rewards.
    enum TransferFailureMode {
        Revert,
        Silent
    }

    /// @notice The ID of the lending market this token is expected to interact with
    bytes32 public lendingMarketId;

    /// @notice User checkpoint data including his deposit balance and the amount of rewards he has claimed for each token
    ///         Both the main reward token and the extra reward tokens are tracked in the same mapping.
    /// @dev    The main reward token is tracked in `rewardPerTokenPaid[address(0)]`
    mapping(address user => UserCheckpoint checkpoint) private userCheckpoints;

    /// @notice Accumulated rewards per token. Track the extra reward tokens only.
    /// @dev    The main reward token is tracked by fetching the latest value from the Accountant.
    mapping(address token => uint256 amount) public extraRewardPerToken;

    /// @notice Maps an account to its operator.
    /// @dev    The operator is the address that is allowed to deposit or claim on behalf of the account.
    mapping(address account => address operator) public operators;

    /// @dev The purpose of this transient variable is to ensure that this token can only be
    /// used as collateral in the predefined lending market. When this variable is set to
    /// false (the default value), transfers to the lending protocol are unauthorized.
    /// The only way to change this variable to true is by entering the flow of the deposit
    /// functions in this contract.
    bool private transient depositUnlocked;

    ///////////////////////////////////////////////////////////////
    // --- EVENTS/ERRORS
    ///////////////////////////////////////////////////////////////

    event Claimed(address indexed token, address indexed account, uint256 amount);
    event Deposited(address indexed caller, address indexed receiver, uint256 amount, bytes32 marketId);
    event Withdrawn(address indexed user, uint256 amount);
    event Liquidated(address indexed liquidator, address indexed victim, uint256 amount);
    event MarketAdded(bytes32 marketId);
    event OperatorSet(address indexed account, address indexed operator);

    error ZeroAmount();
    error ZeroAddress();
    error InvalidMarket();
    error MarketAlreadySet();
    error WrapperNotInitialized();
    error InvalidLiquidation();
    /// @dev Only the lending protocol can transfer in/out the wrapped tokens
    error TransferUnauthorized();
    /// @dev Deposit collateral to the lending protocol is only allowed through the StrategyWrapperContract
    ///      Do not interact directly with the lending protocol to deposit collateral. Instead, call one of the `deposit`
    ///      functions defined in the StrategyWrapperContract instead.
    error InvalidDepositFlow();
    /// @dev The caller must call `setAuthorization` on the lending protocol to authorize this contract to withdraw on behalf of the caller
    error NotAuthorizedToWithdrawCollateral();
    /// @dev The caller is not allowed to deposit or claim on behalf of another account
    error Unauthorized();
    /// @dev An extra reward token transfer failed (returned false or reverted)
    error TransferFailed();

    /// @param rewardVault The reward vault contract
    /// @param lendingProtocol The lending protocol contract
    /// @param _owner The owner of the contract
    /// @custom:reverts ZeroAddress if the reward vault or _owner address are the zero address
    constructor(IRewardVault rewardVault, address lendingProtocol, address _owner) ERC20("", "") Ownable(_owner) {
        require(lendingProtocol != address(0), ZeroAddress());

        IAccountant accountant = IAccountant(address(rewardVault.ACCOUNTANT()));

        // Store the immutable variables
        GAUGE = rewardVault.gauge();
        PROTOCOL_CONTROLLER = rewardVault.PROTOCOL_CONTROLLER();
        ACCOUNTANT = accountant;
        REWARD_VAULT = rewardVault;
        MAIN_REWARD_TOKEN = IERC20(accountant.REWARD_TOKEN());
        ACCOUNTANT_SCALING_FACTOR = accountant.SCALING_FACTOR();
        LENDING_PROTOCOL = lendingProtocol;

        // Approve the asset token to the reward vault and the wrapped token to the lending protocol
        IERC20(rewardVault.asset()).approve(address(rewardVault), type(uint256).max);
        _approve(address(this), lendingProtocol, type(uint256).max, true);
    }

    ///////////////////////////////////////////////////////////////
    // --- INITIALIZATION
    ///////////////////////////////////////////////////////////////

    /// @notice Set the market ID for the wrapper
    /// @param marketId The ID of the market to set
    /// @custom:reverts MarketAlreadySet if the market ID is already set
    /// @custom:reverts InvalidMarket if the market ID is the invalid
    function initialize(bytes32 marketId) public virtual onlyOwner {
        require(lendingMarketId == bytes32(0), MarketAlreadySet());
        require(marketId != bytes32(0), InvalidMarket());

        lendingMarketId = marketId;
        emit MarketAdded(marketId);
    }

    modifier onlyInitialized() {
        require(lendingMarketId != bytes32(0), WrapperNotInitialized());
        _;
    }

    ///////////////////////////////////////////////////////////////
    // --- DEPOSIT
    ///////////////////////////////////////////////////////////////

    /// @notice Wrap `amount` RewardVault shares into wrapper tokens (1:1 ratio)
    /// @param amount Number of RewardVault shares the caller wants to wrap
    /// @dev Use this when you ALREADY hold RewardVault shares and wish to wrap a specific portion of them.
    ///      If you already have wrapped tokens, any pending main and extra rewards will be
    ///      automatically claimed before the new deposit to prevent reward loss.
    /// @param receiver The address to receive the minted wrapper tokens
    /// @custom:reverts ZeroAmount If `amount` is zero
    /// @custom:reverts Unauthorized if the caller is not allowed to deposit on behalf of the receiver
    function depositShares(uint256 amount, address receiver) public nonReentrant onlyInitialized {
        require(amount > 0, ZeroAmount());
        if (receiver == address(0)) receiver = msg.sender;
        require(_isAllowed(receiver), Unauthorized());

        // 1. Transfer caller's shares to this contract (checkpoint)
        IERC20(address(REWARD_VAULT)).safeTransferFrom(msg.sender, address(this), amount);

        _deposit(receiver, amount);
    }

    /// @notice Convert `amount` underlying LP tokens into RewardVault shares and
    ///         immediately wrap those shares into wrapper tokens (LP → share → wrapper)
    /// @param amount Amount of underlying LP tokens provided by the caller
    /// @dev Use this when you DO NOT own RewardVault shares yet, only the raw LP tokens,
    ///      and wish to wrap a specific portion of them.
    ///      If you already have wrapped tokens, any pending main and extra rewards will be
    ///      automatically claimed before the new deposit to prevent reward loss.
    /// @param receiver The address to receive the minted wrapper tokens
    /// @custom:reverts ZeroAmount If `amount` is zero
    /// @custom:reverts Unauthorized if the caller is not allowed to deposit on behalf of the receiver
    function depositAssets(uint256 amount, address receiver) public nonReentrant onlyInitialized {
        require(amount > 0, ZeroAmount());
        if (receiver == address(0)) receiver = msg.sender;
        require(_isAllowed(receiver), Unauthorized());

        // 1. Get RewardVault's shares by depositing the underlying protocol LP tokens (checkpoint)
        IERC20(REWARD_VAULT.asset()).safeTransferFrom(msg.sender, address(this), amount);
        uint256 shares = REWARD_VAULT.deposit(amount, address(this), address(this));

        _deposit(receiver, shares);
    }

    function _deposit(address receiver, uint256 amount) internal {
        // 1. Update the user checkpoint
        _updateUserCheckpoint(receiver, amount);

        // 2. Mint wrapped tokens (1:1)
        _update(address(0), address(this), amount);

        // 3. Supply the minted tokens as collateral to the expected lending market
        depositUnlocked = true;
        _supplyLendingProtocol(receiver, amount);
        depositUnlocked = false;

        emit Deposited(msg.sender, receiver, amount, lendingMarketId);
    }

    ///////////////////////////////////////////////////////////////
    // --- WITHDRAW
    ///////////////////////////////////////////////////////////////

    /// @notice Withdraws the collateral directly from the lending protocol for the caller
    /// @param amount Amount of wrapped tokens put in collateral to withdraw
    /// @custom:reverts NotAuthorizedToWithdrawCollateral if this contract is not authorized to withdraw
    ///                 from the lending protocol on behalf of the caller
    ///                 The caller must call `setAuthorization` on the lending protocol to authorize this
    ///                 contract to withdraw on behalf of the caller
    function withdrawCollateral(uint256 amount) external virtual {
        // Withdraw the collateral from the lending protocol for the caller
        _withdrawLendingProtocol(msg.sender, amount);
        withdraw(amount);
    }

    /// @notice Withdraws the given amount of assets and claims main/extra pending rewards
    /// @param amount Amount of wrapped tokens to burn
    /// @custom:reverts ZeroAmount if the given amount is zero
    function withdraw(uint256 amount) public nonReentrant {
        require(amount > 0, ZeroAmount());

        // 1. Claim all the pending rewards (main + extra)
        _claimAllRewards(msg.sender, TransferFailureMode.Revert);

        // 2. Update the internal user checkpoint
        UserCheckpoint storage checkpoint = userCheckpoints[msg.sender];
        checkpoint.balance -= amount;

        // 4. Burn caller's wrapped tokens
        _burn(msg.sender, amount);

        // 5. Transfer the underlying RewardVault shares back to the caller
        IERC20(address(REWARD_VAULT)).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    ///////////////////////////////////////////////////////////////
    // --- CLAIM
    ///////////////////////////////////////////////////////////////

    /// @notice Claims the caller's main reward token for himself
    /// @param receiver The address to receive the claimed rewards
    /// @custom:reverts Unauthorized if the caller is not allowed to claim on behalf of the receiver
    /// @return amount Amount of main reward tokens claimed
    function claim(address receiver) external nonReentrant returns (uint256 amount) {
        if (receiver == address(0)) receiver = msg.sender;
        require(_isAllowed(receiver), Unauthorized());

        return _claim(receiver);
    }

    function _claim(address account) internal returns (uint256 amount) {
        require(account != address(0), ZeroAddress());

        // 1. Pull the latest data from the Accountant and the total supply of the wrapper
        IAccountant.AccountData memory wrapper = ACCOUNTANT.accounts(address(REWARD_VAULT), address(this));
        uint256 globalIntegral = _getGlobalIntegral();
        uint256 supply = totalSupply();

        // 2. Calculate the pending rewards for the wrapper
        uint256 claimable =
            wrapper.pendingRewards + Math.mulDiv(supply, globalIntegral - wrapper.integral, ACCOUNTANT_SCALING_FACTOR);

        // 3. If there are some pending rewards, claim them
        if (claimable > 0) {
            address[] memory gauges = new address[](1);
            gauges[0] = GAUGE;
            ACCOUNTANT.claim(gauges, new bytes[](0));
        }

        // 4. Transfer the part of the pending rewards that belongs to the account
        UserCheckpoint storage userCheckpoint = userCheckpoints[account];
        amount = _calculatePendingRewards(userCheckpoint);
        if (amount != 0) {
            userCheckpoint.rewardPerTokenPaid[MAIN_REWARD_TOKEN_SLOT] = globalIntegral;
            // ! safeTransfer would allow the account to block liquidation
            MAIN_REWARD_TOKEN.transfer(account, amount);
            emit Claimed(address(MAIN_REWARD_TOKEN), account, amount);
        }
    }

    /// @notice Claims all the caller's extra reward tokens for himself
    /// @param receiver The address to receive the claimed rewards
    /// @custom:reverts Unauthorized if the caller is not allowed to claim on behalf of the receiver
    /// @return amounts Array of claimed amounts
    function claimExtraRewards(address receiver) external nonReentrant returns (uint256[] memory amounts) {
        if (receiver == address(0)) receiver = msg.sender;
        require(_isAllowed(receiver), Unauthorized());

        return _claimExtraRewards(REWARD_VAULT.getRewardTokens(), receiver, TransferFailureMode.Revert);
    }

    /// @notice Claims the rewards for the given extra reward tokens for the caller
    /// @param receiver The address to receive the claimed rewards
    /// @param tokens Array of extra reward tokens to claim
    /// @custom:reverts Unauthorized if the caller is not allowed to claim on behalf of the receiver
    /// @return amounts Array of claimed amounts
    function claimExtraRewards(address receiver, address[] calldata tokens)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (receiver == address(0)) receiver = msg.sender;
        require(_isAllowed(receiver), Unauthorized());

        return _claimExtraRewards(tokens, receiver, TransferFailureMode.Revert);
    }

    /// @param failureMode Controls behavior when an extra reward token transfer fails.
    ///        Revert: reverts the transaction (user-initiated claims, no silent reward loss).
    ///        Silent: skips the failed transfer (liquidation path, protocol liveness over extra rewards).
    /// @dev   Extra reward tokens are added by the RewardVault registrar. To mitigate this risk,
    ///        avoid registering extra reward tokens with custom transfer logic (pausable, blacklistable, etc.).
    function _claimExtraRewards(address[] memory tokens, address account, TransferFailureMode failureMode)
        internal
        returns (uint256[] memory amounts)
    {
        if (tokens.length == 0) return amounts;
        require(account != address(0), ZeroAddress());

        // 1. Update the reward state for all the extra reward tokens
        _updateExtraRewardState(tokens);

        amounts = new uint256[](tokens.length);
        UserCheckpoint storage checkpoint = userCheckpoints[account];

        // 2. Calculate the pending rewards for each extra reward token
        for (uint256 i; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 reward = _calculatePendingExtraRewards(checkpoint, token);

            // 3. If there are pending rewards, update the user's checkpoint and transfer the rewards to the account
            if (reward > 0) {
                checkpoint.rewardPerTokenPaid[token] = extraRewardPerToken[token];
                amounts[i] = reward; // Store the claimed amount

                try IERC20(token).transfer(account, reward) returns (bool success) {
                    if (!success) {
                        if (failureMode == TransferFailureMode.Revert) revert TransferFailed();
                        continue;
                    }
                } catch {
                    if (failureMode == TransferFailureMode.Revert) revert TransferFailed();
                    continue;
                }

                emit Claimed(token, account, reward);
            }
        }

        return amounts;
    }

    /// @notice Claims pending main + extra rewards for the account
    /// @param failureMode Controls behavior when an extra reward token transfer fails.
    function _claimAllRewards(address account, TransferFailureMode failureMode) internal {
        _claim(account);
        _claimExtraRewards(REWARD_VAULT.getRewardTokens(), account, failureMode);
    }

    ///////////////////////////////////////////////////////////////
    // --- INTERNAL FUNCTIONS
    ///////////////////////////////////////////////////////////////

    /// @notice Updates the user checkpoint with the new deposit amount
    function _updateUserCheckpoint(address account, uint256 amount) internal {
        // 1. Update the internal account checkpoint
        UserCheckpoint storage checkpoint = userCheckpoints[account];
        bool hasExistingBalance = checkpoint.balance != 0;

        // 2. For existing users, claim rewards first (this already updates checkpoints)
        if (hasExistingBalance) _claimAllRewards(account, TransferFailureMode.Revert);

        checkpoint.balance += amount;

        // 3. Set initial checkpoints for new users
        if (!hasExistingBalance) {
            // Keep track of the Main reward token checkpoint
            checkpoint.rewardPerTokenPaid[MAIN_REWARD_TOKEN_SLOT] = _getGlobalIntegral();

            // Keep track of the Extra reward tokens checkpoints at deposit time
            address[] memory rewardTokens = REWARD_VAULT.getRewardTokens();
            _updateExtraRewardState(rewardTokens);
            for (uint256 i; i < rewardTokens.length; i++) {
                checkpoint.rewardPerTokenPaid[rewardTokens[i]] = extraRewardPerToken[rewardTokens[i]];
            }
        }
    }

    /// @notice Calculates the pending amount of main reward token for a user
    /// @param checkpoint The user checkpoint
    /// @return The amount of pending main reward token
    function _calculatePendingRewards(UserCheckpoint storage checkpoint) internal view returns (uint256) {
        uint256 globalIntegral = _getGlobalIntegral();
        uint256 userRewardPerTokenPaid = checkpoint.rewardPerTokenPaid[MAIN_REWARD_TOKEN_SLOT];

        return Math.mulDiv(checkpoint.balance, globalIntegral - userRewardPerTokenPaid, ACCOUNTANT_SCALING_FACTOR);
    }

    /// @notice Calculates the pending amount of a specific extra reward token for a user
    /// @param checkpoint The user checkpoint
    /// @param token The address of the extra reward token
    /// @return The amount of pending extra reward token
    function _calculatePendingExtraRewards(UserCheckpoint storage checkpoint, address token)
        internal
        view
        returns (uint256)
    {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;

        uint256 currentRewardPerToken = extraRewardPerToken[token];
        uint256 newRewards = uint256(REWARD_VAULT.earned(address(this), token));
        if (newRewards > 0) currentRewardPerToken += Math.mulDiv(newRewards, PRECISION, supply);

        uint256 userRewardPerTokenPaid = checkpoint.rewardPerTokenPaid[token];
        return Math.mulDiv(checkpoint.balance, currentRewardPerToken - userRewardPerTokenPaid, PRECISION);
    }

    /// @notice Updates the reward state for all the extra reward tokens
    /// @dev    Sweeping hypothetical sleeping rewards would require supply to be non-zero due to the safe early return
    /// @param tokens Array of extra reward tokens to update
    function _updateExtraRewardState(address[] memory tokens) internal {
        // 1. Get the total supply of the wrapped tokens (shares)
        uint256 supply = totalSupply();
        if (supply == 0) return;

        // 2. Claim the rewards from the RewardVault
        uint256[] memory amounts = REWARD_VAULT.claim(tokens, address(this));

        // 3. Update the stored rewards for each extra reward token
        for (uint256 i; i < tokens.length; i++) {
            uint256 amount = amounts[i];
            if (amount > 0) extraRewardPerToken[tokens[i]] += Math.mulDiv(amount, PRECISION, supply);
        }
    }

    /// @notice Get the global integral from the Accountant
    /// @return integral The global integral for the RewardVault as stored in the Accountant
    function _getGlobalIntegral() internal view returns (uint256 integral) {
        integral = ACCOUNTANT.vaults(address(REWARD_VAULT)).integral;
    }

    ///////////////////////////////////////////////////////////////
    // --- TRANSFER
    ///////////////////////////////////////////////////////////////

    /// @dev Only the lending protocol can transfer in/out the wrapped tokens
    function transfer(address to, uint256 value) public virtual override(IERC20, ERC20) returns (bool) {
        require(msg.sender == LENDING_PROTOCOL, TransferUnauthorized());
        return super.transfer(to, value);
    }

    /// @dev Only the lending protocol can transfer in/out the wrapped tokens
    function transferFrom(address from, address to, uint256 value)
        public
        virtual
        override(IERC20, ERC20)
        returns (bool)
    {
        require(msg.sender == LENDING_PROTOCOL, TransferUnauthorized());

        // Only authorize deposits to the lending protocol when the deposit is made through this contract
        if (to == LENDING_PROTOCOL) require(depositUnlocked, InvalidDepositFlow());

        return super.transferFrom(from, to, value);
    }

    ///////////////////////////////////////////////////////////////
    // --- LIQUIDATION
    ///////////////////////////////////////////////////////////////

    /// @notice Claims liquidation rights after receiving tokens from a liquidation event on the lending protocol
    /// @param liquidator The address that received the liquidated tokens from Morpho
    /// @param victim The address whose position was liquidated
    /// @param liquidatedAmount The exact amount of tokens that were seized during liquidation
    ///
    /// @dev This function MUST be called by liquidators after receiving wrapped tokens from a liquidation to receive
    ///      the liquidated amount of underlying RewardVault shares.
    ///      Without calling this function, liquidators will:
    ///      - Be unable to withdraw tokens (will revert due to insufficient internal balance)
    ///      - Leave the victim earning rewards on tokens they no longer own
    /// Example:
    ///   1. Alice has 1000 wrapped tokens used as collateral in Morpho
    ///   2. Bob liquidates Alice's position, receiving 300 tokens from Morpho
    ///   3. Bob's state: ERC20 balance = 300, internal balance = 0 (off-track!)
    ///   4. Bob calls: claimLiquidation(bob, alice, 300)
    ///   5. Result: Bob received 300 underlying RewardVault shares, Alice stops earning on liquidated amount
    ///
    /// @dev This function must also be called if you withdraw your collateral on the lending protocol to a
    /// different receiver. We advise against this scenario and recommend withdrawing your collateral to the
    /// same receiver who deposited it. However, if you choose to proceed, you must call this function to
    /// re-synchronize the internal accountability. In this case, the liquidator will be the receiver of
    /// the collateral, while the victim will be the one who deposited it. From the perspective of this
    /// contract, withdrawing to a different receiver is equivalent to liquidation.
    /// Example:
    ///   1. Alice has 1000 wrapped tokens used as collateral in Morpho
    ///   2. Alice withdraws her collateral to Bob, receiving 1000 tokens from Morpho
    ///   3. Bob's state: ERC20 balance = 1000, internal balance = 0 (off-track!)
    ///   4. Bob calls: claimLiquidation(bob, alice, 1000)
    ///   5. Result: Bob received 1000 underlying RewardVault shares, Alice stops earning on liquidated amount
    function claimLiquidation(address liquidator, address victim, uint256 liquidatedAmount) external nonReentrant {
        require(liquidator != address(0) && victim != address(0), ZeroAddress());
        require(liquidatedAmount > 0, ZeroAmount());

        // The lending protocol and this contract are never valid liquidators. Both can carry an
        // off-track balance that did not originate from a genuine liquidation, so neither must be
        // allowed to satisfy the off-track check below.
        require(liquidator != LENDING_PROTOCOL && liquidator != address(this), InvalidLiquidation());

        // 1. Check that the liquidator own the claimed amount and that it's off-track
        //    Because token is untransferable (except by the lending protocol), the only way
        //    to have an off-track balance is to get it from liquidation executed by the lending protocol.
        //    We have to be sure the claimed amount is off-track, otherwise any holders will be able to liquidate any positions.
        require(balanceOf(liquidator) >= userCheckpoints[liquidator].balance + liquidatedAmount, InvalidLiquidation());

        // 2. Check that the victim has enough tokens registered internally
        uint256 internalVictimBalance = userCheckpoints[victim].balance;
        require(internalVictimBalance >= liquidatedAmount, InvalidLiquidation());

        // 3. Check that the victim as a real holding hole of at least the claimed amount
        //    This is done by summing up the collateral supplied by the victim with his balance.
        //    Because token is untransferable (except by the lending protocol), the only way
        //    to have an off-track balance is to get liquidated.
        uint256 victimBalance = balanceOf(victim) + _getWorkingBalance(victim);
        require(internalVictimBalance - victimBalance >= liquidatedAmount, InvalidLiquidation());

        // 4. Claim the accrued rewards for the victim and reduce his internal balance
        //    Silent: extra reward transfer failures are skipped to prevent reverting tokens
        //    (blacklisted, paused) from blocking liquidation resolution.
        _claimAllRewards(victim, TransferFailureMode.Silent);
        userCheckpoints[victim].balance -= liquidatedAmount;

        // 5. Burn the liquidated amount and transfer the underlying RewardVault shares back to the liquidator
        _burn(liquidator, liquidatedAmount);
        IERC20(address(REWARD_VAULT)).safeTransfer(liquidator, liquidatedAmount);

        emit Liquidated(liquidator, victim, liquidatedAmount);
    }

    ///////////////////////////////////////////////////////////////
    // --- PERMISSIONS
    ///////////////////////////////////////////////////////////////

    /// @notice Checks if the caller is allowed to claim on behalf of another account.
    /// @param receiver The address of the receiver of the claim.
    /// @return True if the caller is allowed; false otherwise.
    /// @dev This function is expected to be used during a deposit flow to ensure the caller has permission
    ///      for the auto-claiming function that is automatically triggered when the receiver already owns some tokens.
    ///      In order to be allowed, the caller must:
    ///      - Be the receiver of the deposit or claim
    ///      - Be authorized by the receiver to deposit or claim on their behalf,
    ///        which is achieved by setting an operator for the receiver
    ///      - Be allowed by the protocol controller to claim on behalf of the receiver.
    ///        Only specific contracts have this permission, as granted by the Stake DAO's DAO.
    ///        Stake DAO's Router is expected to have this permission, allowing any user
    ///        to claim rewards from multiple StrategyWrappers at once
    function _isAllowed(address receiver) internal view returns (bool) {
        if (msg.sender == receiver) return true;
        if (operators[receiver] == msg.sender) return true;
        if (PROTOCOL_CONTROLLER.allowed(
                address(REWARD_VAULT), msg.sender, bytes4(keccak256("claim(address,address[],address)"))
            )) return true;

        return false;
    }

    /// @notice Sets the operator for the caller
    /// @param operator The address of the operator
    /// @dev The operator is the address that is allowed to deposit or claim on behalf of the caller
    function setOperator(address operator) external {
        operators[msg.sender] = operator;
        emit OperatorSet(msg.sender, operator);
    }

    ///////////////////////////////////////////////////////////////
    // --- GETTERS
    ///////////////////////////////////////////////////////////////

    /// @notice Calculate the pending amount of main reward token for a user
    /// @param user The address of the user
    /// @return rewards The amount of pending main reward token
    function getPendingRewards(address user) external view returns (uint256 rewards) {
        UserCheckpoint storage checkpoint = userCheckpoints[user];
        rewards = _calculatePendingRewards(checkpoint);
    }

    /// @notice Calculate the pending amount of all the extra reward tokens for a user.
    /// @param user The address of the user
    /// @return rewards The amount of pending rewards
    function getPendingExtraRewards(address user) external view returns (uint256[] memory rewards) {
        address[] memory extraRewardTokens = REWARD_VAULT.getRewardTokens();
        UserCheckpoint storage checkpoint = userCheckpoints[user];
        rewards = new uint256[](extraRewardTokens.length);

        for (uint256 i; i < extraRewardTokens.length; i++) {
            rewards[i] = _calculatePendingExtraRewards(checkpoint, extraRewardTokens[i]);
        }
    }

    /// @notice Calculate the pending amount of a specific extra reward token for a user.
    ///         If you're looking for the pending amount of the main reward token, call `getPendingRewards` instead.
    /// @dev    The only reason to pass the address of the main reward token to this function is if
    ///         the main reward token is also listed as an extra reward token. It can happen in some cases.
    /// @param user The address of the user
    /// @param token The address of the extra reward token
    /// @return rewards The amount of pending rewards
    /// @custom:reverts ZeroAddress if the token address is the main reward token address (address(0))
    function getPendingExtraRewards(address user, address token) external view returns (uint256 rewards) {
        require(token != MAIN_REWARD_TOKEN_SLOT, ZeroAddress());

        UserCheckpoint storage checkpoint = userCheckpoints[user];
        rewards = _calculatePendingExtraRewards(checkpoint, token);
    }

    /// @notice Get the decimals of the wrapped token
    /// @return The decimals of the wrapped token
    function decimals() public view override(IERC20Metadata, ERC20) returns (uint8) {
        return REWARD_VAULT.decimals();
    }

    /// @notice Monotonic wrapper version
    function version() external pure returns (uint256) {
        return 2;
    }

    ///////////////////////////////////////////////////////////////
    // --- VIRTUAL FUNCTIONS
    ///////////////////////////////////////////////////////////////

    function _supplyLendingProtocol(address account, uint256 amount) internal virtual {}
    function _withdrawLendingProtocol(address account, uint256 amount) internal virtual {}
    function _getWorkingBalance(address account) internal view virtual returns (uint256) {}
    function name() public view virtual override(IERC20Metadata, ERC20) onlyInitialized returns (string memory) {}
    function symbol() public view virtual override(IERC20Metadata, ERC20) onlyInitialized returns (string memory) {}
}
