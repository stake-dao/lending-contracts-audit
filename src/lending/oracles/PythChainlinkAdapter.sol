// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// A price with a degree of uncertainty, represented as a price +- a confidence interval.
//
// The confidence interval roughly corresponds to the standard error of a normal distribution.
// Both the price and confidence are stored in a fixed-point numeric representation,
// `x * (10^expo)`, where `expo` is the exponent.
//
// Please refer to the documentation at https://docs.pyth.network/documentation/pythnet-price-feeds/best-practices for how
// to how this price safely.
struct Price {
    // Price
    int64 price;
    // Confidence interval around the price
    uint64 conf;
    // Price exponent
    int32 expo;
    // Unix timestamp describing when the price was published
    uint256 publishTime;
}

// PriceFeed represents a current aggregate price from pyth publisher feeds.
struct PriceFeed {
    // The price ID.
    bytes32 id;
    // Latest available price
    Price price;
    // Latest available exponentially-weighted moving average price
    Price emaPrice;
}

struct TwapPriceFeed {
    // The price ID.
    bytes32 id;
    // Start time of the TWAP
    uint64 startTime;
    // End time of the TWAP
    uint64 endTime;
    // TWAP price
    Price twap;
    // Down slot ratio represents the ratio of price feed updates that were missed or unavailable
    // during the TWAP period, expressed as a fixed-point number between 0 and 1e6 (100%).
    // For example:
    //   - 0 means all price updates were available
    //   - 500_000 means 50% of updates were missed
    //   - 1_000_000 means all updates were missed
    // This can be used to assess the quality/reliability of the TWAP calculation.
    // Applications should define a maximum acceptable ratio (e.g. 100000 for 10%)
    // and revert if downSlotsRatio exceeds it.
    uint32 downSlotsRatio;
}

// Information used to calculate time-weighted average prices (TWAP)
struct TwapPriceInfo {
    // slot 1
    int128 cumulativePrice;
    uint128 cumulativeConf;
    // slot 2
    uint64 numDownSlots;
    uint64 publishSlot;
    uint64 publishTime;
    uint64 prevPublishTime;
    // slot 3
    int32 expo;
}

/// @title Consume prices from the Pyth Network (https://pyth.network/).
/// @dev Please refer to the guidance at https://docs.pyth.network/documentation/pythnet-price-feeds/best-practices for how to consume prices safely.
/// @author Pyth Data Association
interface IPyth {
    /// @notice Returns the price of a price feed without any sanity checks.
    /// @dev This function returns the most recent price update in this contract without any recency checks.
    /// This function is unsafe as the returned price update may be arbitrarily far in the past.
    ///
    /// Users of this function should check the `publishTime` in the price to ensure that the returned price is
    /// sufficiently recent for their application. If you are considering using this function, it may be
    /// safer / easier to use `getPriceNoOlderThan`.
    /// @return price - please read the documentation of Price to understand how to use this safely.
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);

    /// @notice Returns the price that is no older than `age` seconds of the current time.
    /// @dev This function is a sanity-checked version of `getPriceUnsafe` which is useful in
    /// applications that require a sufficiently-recent price. Reverts if the price wasn't updated sufficiently
    /// recently.
    /// @return price - please read the documentation of Price to understand how to use this safely.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory price);

    /// @notice Returns the exponentially-weighted moving average price of a price feed without any sanity checks.
    /// @dev This function returns the same price as `getEmaPrice` in the case where the price is available.
    /// However, if the price is not recent this function returns the latest available price.
    ///
    /// The returned price can be from arbitrarily far in the past; this function makes no guarantees that
    /// the returned price is recent or useful for any particular application.
    ///
    /// Users of this function should check the `publishTime` in the price to ensure that the returned price is
    /// sufficiently recent for their application. If you are considering using this function, it may be
    /// safer / easier to use either `getEmaPrice` or `getEmaPriceNoOlderThan`.
    /// @return price - please read the documentation of Price to understand how to use this safely.
    function getEmaPriceUnsafe(bytes32 id) external view returns (Price memory price);

    /// @notice Returns the exponentially-weighted moving average price that is no older than `age` seconds
    /// of the current time.
    /// @dev This function is a sanity-checked version of `getEmaPriceUnsafe` which is useful in
    /// applications that require a sufficiently-recent price. Reverts if the price wasn't updated sufficiently
    /// recently.
    /// @return price - please read the documentation of Price to understand how to use this safely.
    function getEmaPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory price);

    /// @notice Update price feeds with given update messages.
    /// This method requires the caller to pay a fee in wei; the required fee can be computed by calling
    /// `getUpdateFee` with the length of the `updateData` array.
    /// Prices will be updated if they are more recent than the current stored prices.
    /// The call will succeed even if the update is not the most recent.
    /// @dev Reverts if the transferred fee is not sufficient or the updateData is invalid.
    /// @param updateData Array of price update data.
    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    /// @notice Wrapper around updatePriceFeeds that rejects fast if a price update is not necessary. A price update is
    /// necessary if the current on-chain publishTime is older than the given publishTime. It relies solely on the
    /// given `publishTimes` for the price feeds and does not read the actual price update publish time within `updateData`.
    ///
    /// This method requires the caller to pay a fee in wei; the required fee can be computed by calling
    /// `getUpdateFee` with the length of the `updateData` array.
    ///
    /// `priceFeedIds` and `publishTimes` are two arrays with the same size that correspond to senders known publishTime
    /// of each priceFeedId when calling this method. If all of price feeds within `priceFeedIds` have updated and have
    /// a newer or equal publish time than the given publish time, it will reject the transaction to save gas.
    /// Otherwise, it calls updatePriceFeeds method to update the prices.
    ///
    /// @dev Reverts if update is not needed or the transferred fee is not sufficient or the updateData is invalid.
    /// @param updateData Array of price update data.
    /// @param priceFeedIds Array of price ids.
    /// @param publishTimes Array of publishTimes. `publishTimes[i]` corresponds to known `publishTime` of `priceFeedIds[i]`
    function updatePriceFeedsIfNecessary(
        bytes[] calldata updateData,
        bytes32[] calldata priceFeedIds,
        uint64[] calldata publishTimes
    ) external payable;

    /// @notice Returns the required fee to update an array of price updates.
    /// @param updateData Array of price update data.
    /// @return feeAmount The required fee in Wei.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    /// @notice Returns the required fee to update a TWAP price.
    /// @param updateData Array of price update data.
    /// @return feeAmount The required fee in Wei.
    function getTwapUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    /// @notice Parse `updateData` and return price feeds of the given `priceFeedIds` if they are all published
    /// within `minPublishTime` and `maxPublishTime`.
    ///
    /// You can use this method if you want to use a Pyth price at a fixed time and not the most recent price;
    /// otherwise, please consider using `updatePriceFeeds`. This method may store the price updates on-chain, if they
    /// are more recent than the current stored prices.
    ///
    /// This method requires the caller to pay a fee in wei; the required fee can be computed by calling
    /// `getUpdateFee` with the length of the `updateData` array.
    ///
    ///
    /// @dev Reverts if the transferred fee is not sufficient or the updateData is invalid or there is
    /// no update for any of the given `priceFeedIds` within the given time range.
    /// @param updateData Array of price update data.
    /// @param priceFeedIds Array of price ids.
    /// @param minPublishTime minimum acceptable publishTime for the given `priceFeedIds`.
    /// @param maxPublishTime maximum acceptable publishTime for the given `priceFeedIds`.
    /// @return priceFeeds Array of the price feeds corresponding to the given `priceFeedIds` (with the same order).
    function parsePriceFeedUpdates(
        bytes[] calldata updateData,
        bytes32[] calldata priceFeedIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PriceFeed[] memory priceFeeds);

    /// @notice Parse `updateData` and return price feeds of the given `priceFeedIds` if they are all published
    /// within `minPublishTime` and `maxPublishTime,` but choose to store price updates if `storeUpdatesIfFresh`.
    ///
    /// You can use this method if you want to use a Pyth price at a fixed time and not the most recent price;
    /// otherwise, please consider using `updatePriceFeeds`. This method may store the price updates on-chain, if they
    /// are more recent than the current stored prices.
    ///
    /// This method requires the caller to pay a fee in wei; the required fee can be computed by calling
    /// `getUpdateFee` with the length of the `updateData` array.
    ///
    /// This method will eventually allow the caller to determine whether parsed price feeds should update
    /// the stored values as well.
    ///
    /// @dev Reverts if the transferred fee is not sufficient or the updateData is invalid or there is
    /// no update for any of the given `priceFeedIds` within the given time range.
    /// @param updateData Array of price update data.
    /// @param priceFeedIds Array of price ids.
    /// @param minAllowedPublishTime minimum acceptable publishTime for the given `priceFeedIds`.
    /// @param maxAllowedPublishTime maximum acceptable publishTime for the given `priceFeedIds`.
    /// @param storeUpdatesIfFresh flag for the parse function to
    /// @return priceFeeds Array of the price feeds corresponding to the given `priceFeedIds` (with the same order).
    function parsePriceFeedUpdatesWithConfig(
        bytes[] calldata updateData,
        bytes32[] calldata priceFeedIds,
        uint64 minAllowedPublishTime,
        uint64 maxAllowedPublishTime,
        bool checkUniqueness,
        bool checkUpdateDataIsMinimal,
        bool storeUpdatesIfFresh
    ) external payable returns (PriceFeed[] memory priceFeeds, uint64[] memory slots);

    /// @notice Parse time-weighted average price (TWAP) from two consecutive price updates for the given `priceFeedIds`.
    ///
    /// This method calculates TWAP between two data points by processing the difference in cumulative price values
    /// divided by the time period. It requires exactly two updates that contain valid price information
    /// for all the requested price IDs.
    ///
    /// This method requires the caller to pay a fee in wei; the required fee can be computed by calling
    /// `getUpdateFee` with the updateData array.
    ///
    /// @dev Reverts if:
    /// - The transferred fee is not sufficient
    /// - The updateData is invalid or malformed
    /// - The updateData array does not contain exactly 2 updates
    /// - There is no update for any of the given `priceFeedIds`
    /// - The time ordering between data points is invalid (start time must be before end time)
    /// @param updateData Array containing exactly two price updates (start and end points for TWAP calculation)
    /// @param priceFeedIds Array of price ids to calculate TWAP for
    /// @return twapPriceFeeds Array of TWAP price feeds corresponding to the given `priceFeedIds` (with the same order)
    function parseTwapPriceFeedUpdates(bytes[] calldata updateData, bytes32[] calldata priceFeedIds)
        external
        payable
        returns (TwapPriceFeed[] memory twapPriceFeeds);

    /// @notice Similar to `parsePriceFeedUpdates` but ensures the updates returned are
    /// the first updates published in minPublishTime. That is, if there are multiple updates for a given timestamp,
    /// this method will return the first update. This method may store the price updates on-chain, if they
    /// are more recent than the current stored prices.
    ///
    ///
    /// @dev Reverts if the transferred fee is not sufficient or the updateData is invalid or there is
    /// no update for any of the given `priceFeedIds` within the given time range and uniqueness condition.
    /// @param updateData Array of price update data.
    /// @param priceFeedIds Array of price ids.
    /// @param minPublishTime minimum acceptable publishTime for the given `priceFeedIds`.
    /// @param maxPublishTime maximum acceptable publishTime for the given `priceFeedIds`.
    /// @return priceFeeds Array of the price feeds corresponding to the given `priceFeedIds` (with the same order).
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceFeedIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PriceFeed[] memory priceFeeds);
}

/// @title A port of the ChainlinkAggregatorV3 interface that supports Pyth price feeds
/// @notice This does not store any roundId information on-chain. Please review the code before using this implementation.
///         Users should deploy an instance of this contract to wrap every price feed id that they need to use.
/// @dev This interface is forked from the Zerolend Adapter found here:
///      https://github.com/zerolend/pyth-oracles/blob/master/contracts/PythAggregatorV3.sol
//       Original license found under licenses/zerolend-pyth-oracles.md
contract PythChainlinkAdapter {
    bytes32 public immutable PRICE_FEED_ID;
    IPyth public immutable PYTH;
    /// @notice Maximum age (in seconds) of a Pyth price before it is considered stale.
    uint256 public immutable MAX_STALENESS;
    /// @notice Cached decimals value, stored once at construction to avoid repeated external calls.
    uint8 public immutable DECIMALS;

    error StalePrice();

    constructor(address _pyth, bytes32 _priceFeedId, uint256 _maxStaleness) {
        PYTH = IPyth(_pyth);
        PRICE_FEED_ID = _priceFeedId;
        MAX_STALENESS = _maxStaleness;

        // Cache decimals from the feed's exponent (immutable per feed)
        Price memory price = IPyth(_pyth).getPriceUnsafe(_priceFeedId);
        DECIMALS = uint8(uint32(-price.expo));
    }

    /// @dev Fetches the price from Pyth and reverts if it is older than MAX_STALENESS.
    function _getFreshPrice() internal view returns (Price memory price) {
        price = PYTH.getPriceUnsafe(PRICE_FEED_ID);
        require(price.publishTime > block.timestamp - MAX_STALENESS, StalePrice());
    }

    function latestAnswer() public view virtual returns (int256) {
        Price memory price = _getFreshPrice();
        return int256(price.price);
    }

    function latestTimestamp() public view returns (uint256) {
        Price memory price = _getFreshPrice();
        return price.publishTime;
    }

    function latestRound() public view returns (uint256) {
        return latestTimestamp();
    }

    function getAnswer(uint256) public view returns (int256) {
        return latestAnswer();
    }

    function getTimestamp(uint256) external view returns (uint256) {
        return latestTimestamp();
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Price memory price = _getFreshPrice();
        return (_roundId, int256(price.price), price.publishTime, price.publishTime, _roundId);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Price memory price = _getFreshPrice();
        roundId = uint80(price.publishTime);
        return (roundId, int256(price.price), price.publishTime, price.publishTime, roundId);
    }

    function decimals() public view virtual returns (uint8) {
        return DECIMALS;
    }

    function description() public pure returns (string memory) {
        return "Chainlink Adapter for Pyth Price Feed";
    }

    function version() public pure returns (uint256) {
        return 1;
    }
}
