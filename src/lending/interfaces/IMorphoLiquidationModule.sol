// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28;

import {MarketParams} from "@shared/src/interfaces/IMorpho.sol";

interface IMorphoLiquidationModule {
    error OnlyMorpho();
    error INSUFFICIENT_SWAP_OUTPUT();

    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external;
    function liquidate(
        MarketParams calldata marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata swapData,
        address receiver
    ) external returns (uint256, uint256);
}
