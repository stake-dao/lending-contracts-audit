// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IChainlinkFeed} from "src/lending/interfaces/IChainlinkFeed.sol";

/// @title CurvePriceFeedChainlinkAdapter
/// @notice Wraps a Curve price feed so it can be consumed through the Chainlink price feed interface.
/// @author Stake DAO
/// @custom:github @stake-dao
/// @custom:contact contact@stakedao.org
contract CurvePriceFeedChainlinkAdapter is IChainlinkFeed {
    /// @notice Immutable reference to the underlying Curve price feed.
    ICurvePriceFeed public immutable CURVE_PRICE_FEED;

    /// @param curvePriceFeed The Curve price feed to expose through the Chainlink interface.
    constructor(address curvePriceFeed) {
        CURVE_PRICE_FEED = ICurvePriceFeed(curvePriceFeed);
    }

    /// @notice Get the price from the Curve price feed in the Chainlink expected format.
    /// @dev This function calls the `price()` function of the Curve price feed.
    /// @return roundId Synthetic round id equal to the current block number.
    /// @return answer Latest price reported by the Curve price feed.
    /// @return startedAt Timestamp for when the observation is considered valid (current block timestamp).
    /// @return updatedAt Timestamp indicating when the price feed was last updated (current block timestamp).
    /// @return answeredInRound Round id that produced the answer; mirrors `roundId` for Chainlink compatibility.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = uint80(block.number);
        answer = int256(CURVE_PRICE_FEED.price());
        startedAt = block.timestamp;
        updatedAt = startedAt;
        answeredInRound = roundId; // deprecated by Chainlink
    }

    function description() external pure returns (string memory) {
        return "Adapter for Curve Price Feed via Chainlink interface";
    }

    /// @return decimals The number of decimals of the price.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    ///////////////////////////////////////////////////////////////
    // --- EXTRA FUNCTIONS
    ///////////////////////////////////////////////////////////////

    /// @notice This function exposes the main function from the curve price feed contract
    /// @return price The price from the Curve price feed.
    function price() external view returns (uint256) {
        return CURVE_PRICE_FEED.price();
    }
}

/// @notice Minimal interface required to consume Curve price feed pricing data.
interface ICurvePriceFeed {
    function price() external view returns (uint256);
}
