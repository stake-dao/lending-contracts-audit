// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICurveStableSwapPool} from "@strategies/src/interfaces/ICurvePool.sol";
import {BaseOracle} from "src/lending/oracles/BaseOracle.sol";

/**
 * @title  CurveStableswapOracle
 * @notice Read‑only market-based price oracle that returns the value of one Curve
 *         **StableSwap** LP token expressed in an arbitrary **quote
 *         asset** (USDC, crvUSD, USDT, …).
 *
 *         The oracle is intended for lending markets where Curve's LP token (base asset) is
 *         used as collateral and the loan asset (quote asset) is the unit in which debts are
 *         denominated.
 *
 *         Supported pool families: **StableSwap** pools and **StableSwap-NG** pools
 *         that implement the `price_oracle()` method.
 *
 * @dev    Pricing formula
 *         ----------------
 *             Price(Base / Quote) = min(price_oracle(i)) × get_virtual_price()  ⎫ in coin0
 *                               × Π price(hopᵢ)                                 ⎬ coin0 → USD
 *                               ÷ price(Quote / USD)                            ⎭ USD    → Quote
 *
 *        • The base asset is the LP token itself
 *        • Uses Curve's EMA price oracle for conservative pricing across all pool assets
 *        • `price_oracle(i)` returns the price of coin[i+1] relative to coin0 (18 decimals)
 *        • `get_virtual_price()` returns the LP token price in coin0 terms (18 decimals)
 *        • `token0ToUsdFeeds` is an ordered array of Chainlink feeds that, hop by hop,
 *           convert coin0 into USD. Each element consumes the output of the previous hop.
 *
 *         Appreciating Token Adjustment
 *         -------------------------------------------
 *         In StableSwap‑NG pools where coin0 is an appreciating wrapper (wstETH, sDAI, etc.),
 *         `get_virtual_price()` already pulls the rate-adjusted balance from `_stored_rates`,
 *         so the LP price it returns is quoted in the underlying principal token (stETH, DAI…),
 *         not in the wrapper’s nominal units. When configuring the hop chain, make the first
 *         feed price that principal token; otherwise the wrapper appreciation would be applied twice.
 *
 *         Flash-manipulation caveat
 *         -------------------------------------------
 *         This oracle leverages Curve's battle-tested EMA price oracle which provides
 *         protection against flash loan attacks through exponential moving average smoothing.
 *         The conservative minimum pricing across all pool assets prevents overvaluation
 *         during asset depegs. This oracle is intended for high-TVL, curated pools only.
 *         Conservative LLTV settings are still recommended for additional safety.
 *
 *         Feed availability and adapter pattern
 *         ------------------------------------
 *         When coin0 ≠ quote asset, the oracle requires a hop-chain to convert coin0 to USD.
 *         Each hop in the chain can return prices in any denomination - the chain composition
 *         determines the final USD conversion.
 *
 *         Read-Only Reentrancy Attack
 *         ------------------------------------------------------
 *         This oracle relies on Curve's `get_virtual_price()` function which is vulnerable
 *         to read-only reentrancy attacks when the pool contains native ETH or ERC-777 tokens.
 *         The attack occurs when the token is sent to a malicious contract that reenters
 *         `get_virtual_price()` while the pool state is inconsistent (balances not yet updated
 *         but LP supply already decreased).
 *
 *         Mitigation:
 *         • Only use pools where `get_virtual_price()` is protected with a nonreentrant modifier
 *
 *         References:
 *         • https://www.chainsecurity.com/blog/curve-lp-oracle-manipulation-post-mortem
 *         • https://www.chainsecurity.com/blog/heartbreaks-curve-lp-oracles
 *
 *         Optional Quote Asset Feed
 *         ------------------------------------
 *         When coin0 = quote asset, no external feeds are required and the oracle
 *         provides direct pricing with optimal gas efficiency.
 *
 *         Limitations – Pool Compatibility
 *         -------------------------------------------
 *         This oracle only supports pools that implement the `price_oracle()` method.
 *         Pools without this method are incompatible and will revert during deployment.
 *         The oracle automatically detects pool configuration and supports both:
 *         • 2-coin pools: `price_oracle()` (no arguments)
 *         • Multi-coin pools: `price_oracle(i)` (with coin index argument)
 *
 *         Limitations – Layer 2 sequencer availability
 *         -------------------------------------------
 *         This oracle lacks sequencer uptime validation for Layer 2 networks. Chainlink
 *         feeds on L2s can become stale if the sequencer goes down. For L2 deployments,
 *         consider wrapping this oracle to include Sequencer Uptime Data Feed checks.
 *         https://docs.chain.link/data-feeds/l2-sequencer-feeds
 *
 * @author Stake DAO
 * @custom:github @stake-dao
 * @custom:contact contact@stakedao.org
 */
contract CurveStableswapOracle is BaseOracle {
    /// @dev Define if the price_oracle() method takes no arguments
    bool internal immutable NO_ARGUMENT;
    /// @dev Define the number of coins in the pool
    uint256 internal immutable N_COINS;

    ///////////////////////////////////////////////////////////////
    // --- ERRORS
    ///////////////////////////////////////////////////////////////

    error PoolMustHaveAtLeast2Coins();
    error PoolDoesNotSupportPriceOracle();
    error PoolIncompatiblePriceOracleImplementation();

    constructor(
        address _curvePool,
        address _quoteAsset,
        address _quoteAssetFeed,
        uint256 _quoteAssetFeedHeartbeat,
        address[] memory _token0ToUsdFeeds,
        uint256[] memory _token0ToUsdHeartbeats,
        uint256 _scalingExponent
    )
        BaseOracle(
            _curvePool,
            _quoteAsset,
            _quoteAssetFeed,
            _quoteAssetFeedHeartbeat,
            _token0ToUsdFeeds,
            _token0ToUsdHeartbeats,
            _scalingExponent
        )
    {
        (N_COINS, NO_ARGUMENT) = _detectPoolConfiguration(_curvePool);

        // dry-run the internal function to detect any anomalies
        _getLpPriceInCoin0();
    }

    ///////////////////////////////////////////////////////////////
    // --- OVERRIDDEN FUNCTIONS
    ///////////////////////////////////////////////////////////////

    /// @notice Gets the LP token price in coin0 terms using Curve's EMA price oracle
    /// @dev The formula follows a conservative approach: min over all assets expressed
    ///      in coin0, including coin0 itself, then multiplied by virtual price.
    ///      `lpPriceInCoin0 = min(1, price_oracle(i)) × get_virtual_price() / 1e18`
    /// @dev The base asset is the Curve pool address
    /// @return lpPrice The LP token price in coin0 terms (18 decimals)
    function _getLpPriceInCoin0() internal view override returns (uint256) {
        uint256 minPrice = 1e18;

        // Get minimum price across all coins (excluding coin0)
        for (uint256 i; i < N_COINS - 1; i++) {
            uint256 _price = NO_ARGUMENT
                ? ICurveStableSwapPool(BASE_ASSET).price_oracle()
                : ICurveStableSwapPool(BASE_ASSET).price_oracle(i);
            if (_price < minPrice) minPrice = _price;
        }

        uint256 virtualPrice = ICurveStableSwapPool(BASE_ASSET).get_virtual_price();

        // Multiply by virtual price to get LP price in coin0 terms
        return Math.mulDiv(minPrice, virtualPrice, 1e18);
        // (18 dec)            └─ minPrice(18-dec) × virtualPrice(18-dec) / 1e18
    }

    ///////////////////////////////////////////////////////////////
    // --- INTERNAL FUNCTIONS
    ///////////////////////////////////////////////////////////////

    /// @notice Detects the pool configuration by testing price_oracle() calls
    /// @param pool The Curve pool address
    /// @return nCoins Number of coins in the pool
    /// @return noArgument Whether price_oracle() takes no arguments
    function _detectPoolConfiguration(address pool) internal view returns (uint256 nCoins, bool noArgument) {
        // Find N_COINS by calling coins(i) until it fails. This is the universal way to detect the number of coins in all pool
        for (uint256 i; i <= 8; i++) {
            try ICurveStableSwapPool(pool).coins(i) returns (
                address
            ) {
            // Coin exists, continue
            }
            catch {
                require(i > 1, PoolMustHaveAtLeast2Coins());
                nCoins = i;
                break;
            }
        }

        // Test price_oracle() signature
        for (uint256 i; i < nCoins - 1; i++) {
            try ICurveStableSwapPool(pool).price_oracle(i) returns (uint256 _price) {
                require(_price > 0, InvalidPrice());
                // Method takes argument, continue testing
            } catch {
                // Method doesn't take any arguments, verify it's a 2-coin pool
                require(i == 0 && nCoins == 2, PoolIncompatiblePriceOracleImplementation());

                // Test the no-argument version
                try ICurveStableSwapPool(pool).price_oracle() returns (uint256 _price) {
                    require(_price > 0, InvalidPrice());
                    noArgument = true;
                } catch {
                    revert PoolDoesNotSupportPriceOracle();
                }
                break;
            }
        }
    }
}

/*
──────────────────────────────────────────────────────────────────────────────
EXAMPLES – how to build the **token0 → USD** feed chain
──────────────────────────────────────────────────────────────────────────────
Constructor signature

    CurveStableswapOracle(
        curvePool,
        quoteAsset,                 // USDC in the examples below
        quoteAssetFeed,             // USDC/USD Chainlink feed (not required if coin0 = quote asset)
        quoteAssetHeartbeat,        // Heartbeat for quote asset feed (not required if quoteAssetFeed is not set)
        token0ToUsdFeeds,           // Array of feeds to convert coin0 to USD (not required if coin0 = quote asset)
        token0ToUsdHeartbeats       // Array of heartbeats for each feed (not required if token0ToUsdFeeds is not set)
        scalingExponent                // Base exponent used to scale the price. Protocol specific.
    )

Each element `token0ToUsdFeeds[i]` converts the *output* of the previous hop into the
*input* of the next hop, until the value is finally expressed in **USD**. For
lending markets that borrow **USDC**, you then pass the USDC/USD feed via the
dedicated `quoteAssetFeed` parameter.

IMPORTANT: The oracle uses Curve's EMA price oracle for conservative pricing.
The minimum price across all pool assets (excluding coin0) is used to prevent
overvaluation during asset depegs.

---------------------------------------------------------------------
1.  USDC / USDT  **StableSwap** pool → coin0 = USDC
---------------------------------------------------------------------
• Address: 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85
• Pool assets: USDC, USDT
• coin0 = USDC (= quote asset)
• No conversion needed: direct pricing

      token0ToUsdFeeds       = []                    // Empty array
      token0ToUsdHeartbeats  = []                    // Empty array
      quoteAssetFeed          = address(0)            // No feed needed
      quoteAssetHeartbeat     = 0                     // No heartbeat needed

The oracle fetches the LP price directly from Curve's price oracle and scales it.

---------------------------------------------------------------------
2.  USDT / crvUSD  **StableSwap** pool → coin0 = USDT
---------------------------------------------------------------------
• Address: 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4
• Pool assets: USDT, crvUSD
• coin0 = USDT (≠ quote asset USDC)
• Need to convert USDT → USD → USDC

      token0ToUsdFeeds       = [USDT/USD feed]
      token0ToUsdHeartbeats  = [1 days]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The oracle uses Curve's minimum price (USDT vs crvUSD) and converts USDT to USDC.

---------------------------------------------------------------------
3.  wETH / frxETH  **StableSwap-NG** pool → coin0 = wETH
---------------------------------------------------------------------
• Address: 0x9c3B46C0Ceb5B9e304FCd6D88Fc50f7DD24B31Bc
• Pool assets: wETH, frxETH
• coin0 = wETH (≠ quote asset USDC)
• Need to convert ETH → USD → USDC (1 wETH = 1 ETH)

      token0ToUsdFeeds       = [ETH/USD feed]
      token0ToUsdHeartbeats  = [1 days]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The oracle uses Curve's minimum price (wETH vs frxETH) and converts wETH to USDC.

---------------------------------------------------------------------
4.  wBTC / tBTC  **StableSwap** pool → coin0 = wBTC
---------------------------------------------------------------------
• Address: 0xB7ECB2AA52AA64a717180E030241bC75Cd946726
• Pool assets: wBTC, tBTC
• coin0 = wBTC (≠ quote asset USDC)
• Need to convert wBTC → BTC → USD → USDC (because there is no wBTC/USD feed)

      token0ToUsdFeeds       = [wBTC/BTC feed, BTC/USD feed]
      token0ToUsdHeartbeats  = [1 days, 1 days]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The oracle uses Curve's minimum price (wBTC vs tBTC) and converts wBTC to USDC
via the hop chain: wBTC → BTC → USD → USDC.

---------------------------------------------------------------------
5.  sUSDS / USDT  **StableSwap** pool → coin0 = sUSDS
---------------------------------------------------------------------
• Address: 0x00836Fe54625BE242BcFA286207795405ca4fD10
• Pool assets: sUSDS, USDT
• coin0 = sUSDS (≠ quote asset USDC)
• Need to convert USDS → USDC (because coin0 is an appreciating token, the first feed must price the principal token, not the wrapper token!)

      token0ToUsdFeeds       = [USDS/USD feed] // Principal token feed
      token0ToUsdHeartbeats  = [23 hours]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The coin0 is an appreciating token, so the first feed must price the principal token, not the wrapper token!
The oracle uses Curve's minimum price (sUSDS vs USDT) and converts USDS to USDC via the hop chain: USDS → USDC.
*/
