// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IChainlinkFeed} from "src/lending/interfaces/IChainlinkFeed.sol";
import {ICurvePool} from "@strategies/src/interfaces/ICurvePool.sol";
import {IOracle} from "src/lending/interfaces/IOracle.sol";

/// @title BaseOracleV2
/// @author Stake DAO
/// @custom:github @stake-dao
/// @custom:contact contact@stakedao.org
abstract contract BaseOracleV2 is IOracle {
    ///////////////////////////////////////////////////////////////
    // --- IMMUTABLES & STORAGE
    ///////////////////////////////////////////////////////////////

    /// @notice Address of the base asset this oracle prices.
    address public immutable BASE_ASSET;
    /// @notice Address of the quote asset the price is expressed in.
    address public immutable QUOTE_ASSET;
    /// @notice Price feed for the quote asset.
    IChainlinkFeed public immutable QUOTE_ASSET_FEED;
    /// @notice Exponent used to scale the price to match the protocol's expected precision.
    uint256 public immutable ORACLE_SCALING_EXPONENT;
    /// @notice Feeds that turn the denomination coin into USD (ordered hops).
    IChainlinkFeed[] public denomToUsdFeeds;
    /// @notice Heartbeats for each denomination coin to USD feed.
    uint256[] public denomToUsdHeartbeats;
    /// @dev Index of the coin used as denomination for the first stage of pricing (0 = coin0, 1 = coin1, ... N-1 = coinN-1).
    uint256 public immutable DENOM_INDEX;

    /// @notice Lending protocols expect the price to be scaled to a specific precision
    ///         by `ORACLE_SCALING_EXPONENT` and adjusted for the difference in token decimals between
    ///         the quote asset (debt unit) and the collateral asset (wrapped Curve LP token).
    /// @dev    The scale factor calculation follows this exact approach:
    ///         SCALE_FACTOR = 1e(scalingExponent + quoteDecimals + quoteFeedDecimals - collateralDecimals)
    ///         Note: token0→USD hop price feed decimals do not appear here; they cancel out inside the
    ///     price() computation where each hop multiplies by the feed and immediately divides by 10^feedDecimals.
    uint256 internal immutable SCALE_FACTOR;
    /// @notice Decimals of the returned price.
    /// @dev Equals `ORACLE_SCALING_EXPONENT + decimals(quoteAsset) - 18` (Curve LPs have 18 decimals).
    uint8 internal immutable ORACLE_DECIMALS;
    /// @notice Decimals of the quote asset price feed.
    uint8 internal immutable QUOTE_ASSET_FEED_DECIMALS;
    /// @notice Heartbeat for the quote asset price feed.
    uint256 internal immutable QUOTE_ASSET_FEED_HEARTBEAT;

    ///////////////////////////////////////////////////////////////
    // --- ERRORS
    ///////////////////////////////////////////////////////////////

    error InvalidPrice();
    error InvalidDecimals();
    error ZeroAddress();
    error ZeroUint256();
    error ArrayLengthMismatch();
    error QuoteAssetFeedRequired();

    ///////////////////////////////////////////////////////////////
    // --- CONSTRUCTOR
    ///////////////////////////////////////////////////////////////

    /// @param _curvePool Address of the Crypto-swap pool. The LP token of the pool is the base asset of the oracle.
    /// @param _quoteAsset Address of the quote asset.
    /// @param _quoteAssetFeed Chainlink feed for the quote asset if needed (e.g., USDC/USD, crvUSD/USD, USDT/USD, etc.).
    /// @param _quoteAssetFeedHeartbeat Max seconds between two updates of the quote asset feed.
    /// @param _denomToUsdFeeds Ordered feeds to convert the denomination coin to USD.
    /// @param _denomToUsdHeartbeats Max seconds between two updates of each feed.
    /// @param _scalingExponent The exponent used to scale the price. Protocol specific.
    /// @param _denomIndex Index of the denomination coin to price in (0 = coin0, 1 = coin1, ... N-1 = coinN-1)
    /// @custom:reverts ZeroAddress if `_curvePool`, `_quoteAsset` is the zero address.
    /// @custom:reverts ZeroUint256 if `_quoteAssetFeedHeartbeat` is zero.
    /// @custom:reverts ArrayLengthMismatch if `_denomToUsdFeeds` and `_denomToUsdHeartbeats` have different lengths.
    /// @dev If `_quoteAssetFeed` is the zero address, it means that the quote asset is the denomination coin of the pool.
    ///      In this case, there is no need to set up the quote asset feed data (_quoteAssetFeed, _quoteAssetFeedDecimals, _quoteAssetFeedHeartbeat).
    constructor(
        address _curvePool,
        address _quoteAsset,
        address _quoteAssetFeed,
        uint256 _quoteAssetFeedHeartbeat,
        address[] memory _denomToUsdFeeds,
        uint256[] memory _denomToUsdHeartbeats,
        uint256 _scalingExponent,
        uint256 _denomIndex
    ) {
        require(_curvePool != address(0), ZeroAddress());
        require(_quoteAsset != address(0), ZeroAddress());
        require(_denomToUsdFeeds.length == _denomToUsdHeartbeats.length, ArrayLengthMismatch());

        BASE_ASSET = _curvePool;
        QUOTE_ASSET = _quoteAsset;
        DENOM_INDEX = _denomIndex;

        // Set up the quote asset feed data if needed
        bool isDenomQuoteAsset = (_quoteAssetFeed == address(0) && _quoteAssetFeedHeartbeat == 0);
        if (isDenomQuoteAsset) {
            // Validate that the denomination coin equals the quote asset. If so, we can avoid setting up the quote asset feed
            require(ICurvePool(_curvePool).coins(_denomIndex) == _quoteAsset, QuoteAssetFeedRequired());
        } else {
            // Set up feeds for conversion case
            require(_quoteAssetFeed != address(0), ZeroAddress());
            require(_quoteAssetFeedHeartbeat != 0, ZeroUint256());
            QUOTE_ASSET_FEED = IChainlinkFeed(_quoteAssetFeed);
            QUOTE_ASSET_FEED_DECIMALS = IChainlinkFeed(_quoteAssetFeed).decimals();
            QUOTE_ASSET_FEED_HEARTBEAT = _quoteAssetFeedHeartbeat;
        }

        uint256 quoteDecimals = IERC20Metadata(_quoteAsset).decimals();
        require(quoteDecimals > 0, InvalidDecimals());

        // Scale factor calculation following this exact approach:
        // SCALE_FACTOR = 1e(scalingExponent + dQ1 + fpQ1 + fpQ2 - dB1 - fpB1 - fpB2)
        //
        // In our case:
        // - dQ1 = quote asset decimals
        // - fpQ1 = quote asset feed decimals (only one quote feed)
        // - fpQ2 = 0 (no second quote feed)
        // - dB1 = collateral token decimals (always 18 for Curve LP tokens)
        // - fpB1, fpB2, etc. = denomToUsdFeeds decimals (base feeds). These cancel within price().
        //
        // SCALE_FACTOR = 1e(scalingExponent + quoteDecimals + quoteFeedDecimals - collateralDecimals)
        uint256 collateralDecimals = 18;
        ORACLE_SCALING_EXPONENT = _scalingExponent;
        SCALE_FACTOR = 10 ** (_scalingExponent + quoteDecimals + QUOTE_ASSET_FEED_DECIMALS - collateralDecimals);
        ORACLE_DECIMALS = uint8(_scalingExponent + quoteDecimals - collateralDecimals);

        // Set the conversion feeds required to denominate the denomination coin in quote asset (hop-by-hop) if needed
        for (uint256 i; i < _denomToUsdFeeds.length; i++) {
            // Each hop must be a real Chainlink feed and have a non-zero heartbeat
            require(_denomToUsdFeeds[i] != address(0), ZeroAddress());
            require(_denomToUsdHeartbeats[i] != 0, ZeroUint256());

            denomToUsdFeeds.push(IChainlinkFeed(_denomToUsdFeeds[i]));
            denomToUsdHeartbeats.push(_denomToUsdHeartbeats[i]);
        }
    }

    /// @notice Price of 1 LP token in the quote asset.
    /// @dev 1) Compute LP in denomination coin via _lpPriceInDenomination() (18‑dec).
    ///      2) Multiply by denom→USD hop chain.
    ///      3) Divide by quote/USD feed to express in quote units.
    // /     4) Apply SCALE_FACTOR and cancel the LP’s 1e18.
    function price() public view returns (uint256) {
        uint256 lpPriceInDenom = _lpPriceInDenomination();
        //      (18 decimals)            └─ LP price in denomination coin terms

        // If there is no quote asset feed, it means the denomination coin equals the quote asset,
        // so we can scale the returned price directly
        if (QUOTE_ASSET_FEED == IChainlinkFeed(address(0))) {
            return Math.mulDiv(lpPriceInDenom, SCALE_FACTOR, 1e18);
        }

        // Numerator: LP price in denomination × all denom→USD feeds (keep raw feed decimals)
        uint256 numerator = lpPriceInDenom;
        uint256 length = denomToUsdFeeds.length;
        for (uint256 i; i < length; i++) {
            uint256 feedPrice = _fetchFeedPrice(denomToUsdFeeds[i], denomToUsdHeartbeats[i]);
            uint256 feedDecimals = denomToUsdFeeds[i].decimals();
            numerator = Math.mulDiv(numerator, feedPrice, 10 ** feedDecimals);
        }

        // Denominator: quote asset feed price (USD per quote asset)
        uint256 denominator = _fetchFeedPrice(QUOTE_ASSET_FEED, QUOTE_ASSET_FEED_HEARTBEAT);

        // Apply scale factor and cancel lpPriceInDenom's 1e18
        // lpPriceInDenom is 18-decimal; SCALE_FACTOR already normalizes feed precisions to the
        // scalingExponent + quoteDecimals − collateralDecimals target. Divide by 1e18 to remove lpPriceInDenom's
        // extra 18-dec so the final result matches the expected scaling.
        return Math.mulDiv(numerator, SCALE_FACTOR, denominator) / 1e18;
    }

    /// @notice Decimals of the returned price.
    /// @dev Equals ORACLE_SCALING_EXPONENT + decimals(quoteAsset) − 18 (Curve LPs have 18 decimals).
    function decimals() external view returns (uint8) {
        return ORACLE_DECIMALS;
    }

    /// @notice Fetches the price from a Chainlink feed
    /// @param feed The Chainlink feed to fetch the price from.
    /// @param maxStale The maximum number of seconds since the last update of the feed.
    /// @return price The raw price returned by the feed (native feed decimals).
    /// @custom:reverts InvalidPrice if the price fetched from the Chainlink feeds are invalid (not positive) or stale.
    function _fetchFeedPrice(IChainlinkFeed feed, uint256 maxStale) internal view returns (uint256) {
        (, int256 latestPrice,, uint256 updatedAt,) = feed.latestRoundData();
        require(latestPrice > 0 && updatedAt > block.timestamp - maxStale, InvalidPrice());
        return uint256(latestPrice);
    }

    /// @notice Version of the oracle.
    /// @return version The version of the oracle.
    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    ///////////////////////////////////////////////////////////////
    // --- VIRTUAL FUNCTIONS
    ///////////////////////////////////////////////////////////////

    /// @notice Gets the LP token price denominated in the denomination coin
    /// @return lpPrice LP price denominated in coin[DENOM_INDEX] (18 decimals)
    function _lpPriceInDenomination() internal view virtual returns (uint256);
}
