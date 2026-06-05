// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IChainlinkFeed} from "src/lending/interfaces/IChainlinkFeed.sol";
import {IOracle} from "src/lending/interfaces/IOracle.sol";

/// @title OracleChainlinkAdapter
/// @notice Wrapper that exposes Stake DAO's Curve LP oracles through a Chainlink‑compliant
///         price feed interface. This allows using Stake DAO oracles as on‑chain price feeds
///         anywhere a Chainlink-style `latestRoundData()` and `decimals()` interface is expected.
/// @dev    The adapter is read‑only. It forwards `price()` from the underlying Stake DAO oracle
///         (e.g., CurveStableSwap/CryptoSwap oracles implementing `IOracle`) and reports the
///         oracle's decimals. Timestamps in `latestRoundData()` are set to the current block
///         because the underlying oracle computes values on read and does not maintain rounds.
/// @author Stake DAO
/// @custom:github @stake-dao
/// @custom:contact contact@stakedao.org
contract OracleChainlinkAdapter is IChainlinkFeed {
    /// @notice Immutable reference to the underlying Stake DAO's Curve Oracle.
    IOracle public immutable ORACLE;

    /// @notice Immutable reference to the number of decimals of the price.
    uint8 internal immutable ORACLE_DECIMALS;

    /// @param oracle The Stake DAO's Curve Oracle to expose through the Chainlink interface.
    constructor(address oracle) {
        ORACLE = IOracle(oracle);
        ORACLE_DECIMALS = IOracle(oracle).decimals();
    }

    /// @notice Get the price from the Stake DAO's Curve Oracle in the Chainlink expected format.
    /// @dev This function calls the `price()` function of the Stake DAO's Curve Oracle.
    /// @return roundId Synthetic round id equal to the current block number.
    /// @return answer Latest price reported by the Stake DAO's Curve Oracle.
    /// @return startedAt Timestamp for when the observation is considered valid (current block timestamp).
    /// @return updatedAt Timestamp indicating when the Stake DAO's Curve Oracle was last updated (current block timestamp).
    /// @return answeredInRound Round id that produced the answer; mirrors `roundId` for Chainlink compatibility.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = uint80(block.number);
        answer = int256(ORACLE.price());
        startedAt = block.timestamp;
        updatedAt = startedAt;
        answeredInRound = roundId; // deprecated by Chainlink
    }

    function description() external pure returns (string memory) {
        return "Adapter for Stake DAO's Curve Oracle via Chainlink interface";
    }

    /// @return decimals The number of decimals of the price.
    function decimals() external view returns (uint8) {
        return ORACLE_DECIMALS;
    }
}
