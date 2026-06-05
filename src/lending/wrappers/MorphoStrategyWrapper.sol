// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StrategyWrapper, IERC20Metadata} from "src/lending/wrappers/StrategyWrapper.sol";
import {IMorpho, Id} from "@shared/src/interfaces/IMorpho.sol";
import {IRewardVault} from "@strategies/src/interfaces/IRewardVault.sol";

contract MorphoStrategyWrapper is StrategyWrapper {
    /// @dev The prefix to use for the name and symbol of the wrapper
    string private NAME_PREFIX;
    string private SYMBOL_PREFIX;

    constructor(
        IRewardVault rewardVault,
        address lendingProtocol,
        address _owner,
        string memory namePrefix,
        string memory symbolPrefix
    ) StrategyWrapper(rewardVault, lendingProtocol, _owner) {
        NAME_PREFIX = namePrefix;
        SYMBOL_PREFIX = symbolPrefix;
    }

    function initialize(bytes32 marketId) public override onlyOwner {
        super.initialize(marketId);

        require(
            IMorpho(LENDING_PROTOCOL).idToMarketParams(Id.wrap(marketId)).collateralToken == address(this),
            InvalidMarket()
        );
    }

    ///////////////////////////////////////////////////////////////
    // --- INTERNAL FUNCTIONS
    ///////////////////////////////////////////////////////////////

    function _supplyLendingProtocol(address account, uint256 amount) internal override {
        IMorpho(LENDING_PROTOCOL)
            .supplyCollateral(IMorpho(LENDING_PROTOCOL).idToMarketParams(Id.wrap(lendingMarketId)), amount, account, "");
    }

    function _withdrawLendingProtocol(address account, uint256 amount) internal override {
        IMorpho(LENDING_PROTOCOL)
            .withdrawCollateral(
                IMorpho(LENDING_PROTOCOL).idToMarketParams(Id.wrap(lendingMarketId)), amount, account, account
            );
    }

    function _getWorkingBalance(address account) internal view override returns (uint256) {
        return IMorpho(LENDING_PROTOCOL).position(Id.wrap(lendingMarketId), account).collateral;
    }

    ///////////////////////////////////////////////////////////////
    // --- GETTERS FUNCTIONS
    ///////////////////////////////////////////////////////////////

    function name() public view override onlyInitialized returns (string memory) {
        return string.concat(NAME_PREFIX, IERC20Metadata(REWARD_VAULT.asset()).name());
    }

    function symbol() public view override onlyInitialized returns (string memory) {
        return string.concat(SYMBOL_PREFIX, IERC20Metadata(REWARD_VAULT.asset()).symbol());
    }
}
