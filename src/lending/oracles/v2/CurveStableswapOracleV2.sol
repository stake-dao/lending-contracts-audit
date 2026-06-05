// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICurveStableSwapPool} from "@strategies/src/interfaces/ICurvePool.sol";
import {BaseOracleV2} from "src/lending/oracles/v2/BaseOracleV2.sol";

/**
 * @title  CurveStableswapOracleV2
 * @notice Read‑only market-based price oracle that returns the value of one Curve StableSwap LP token
 *         expressed in an arbitrary quote asset (USDC, crvUSD, USDT, …).
 *
 *         The LP token (base asset) is used as collateral; the quote asset is the loan unit.
 *         The oracle first prices the LP in a chosen denomination coin (coin[DENOM_INDEX])
 *         and then converts denomination → USD → quote.
 *
 *         Supported families: StableSwap and StableSwap‑NG pools that implement `price_oracle`.
 *
 * @dev    Pricing overview
 *         -----------------
 *             LP_in_denom = min_j ( price(coin[j] → coin[DENOM_INDEX]) , 1 ) × get_virtual_price() / 1e18
 *             Price(Base / Quote) = LP_in_denom
 *                                   × Π price(denom→USD hopᵢ)
 *                                   ÷ price(Quote / USD)
 *
 *        • `price_oracle(i)` supplies EMA prices in coin0 units (Q18): coin[i+1] per 1 coin0.
 *          Re‑denomination to the target coin uses:
 *            - DENOM_INDEX = 0: price(coin[j]→denom) = price_oracle(j−1) for j>0
 *            - DENOM_INDEX > 0:
 *                • price(coin0→denom)   = 1e36 / price_oracle(DENOM_INDEX−1)
 *                • price(coin[j]→denom) = (price_oracle(j−1) × 1e18) / price_oracle(DENOM_INDEX−1) for j≠denom, j>0
 *        • `get_virtual_price()` is the per‑LP value in the pool’s normalized unit of account
 *          (xp balances: 18‑decimals with wrappers unwrapped via stored_rates), not a market quote.
 *        • The min clamp enforces conservative pricing: never scale the virtual price upward.
 *        • `denomToUsdFeeds` is an ordered Chainlink hop chain that converts the denomination coin to USD.
 *          Each hop consumes the previous hop’s output; per‑hop heartbeats enforce freshness.
 *        • Optional quote feed: when denomination coin = quote asset, no quote feed is required.
 *        • 2‑coin fast path: constant‑time clamps using coin1↔coin0 EMA; N‑coin: O(N) re‑denomination and min.
 *
 *         Appreciating Token Adjustment
 *         -------------------------------------------
 *         In StableSwap‑NG pools where coin0 is an appreciating wrapper (wstETH, sDAI, etc.),
 *         `get_virtual_price()` already pulls the rate-adjusted balance from `_stored_rates`,
 *         so the LP price it returns is quoted in the underlying principal token (stETH, DAI…),
 *         not in the wrapper’s nominal units. When configuring the hop chain, make the first
 *         hop price the principal token; otherwise the wrapper appreciation would be applied twice.
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
 *         When denomination ≠ quote asset, the oracle requires a hop‑chain to convert the
 *         denomination coin to USD. Each hop can return prices in any denomination; the chain
 *         composition determines the final USD conversion.
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
 *         When denomination coin = quote asset, no external feeds are required for the
 *         quote leg; the oracle provides direct pricing with optimal gas efficiency.
 *
 *         Limitations – Pool Compatibility
 *         -------------------------------------------
 *         This oracle only supports pools that implement the `price_oracle()` method.
 *         Pools without this method are incompatible and will revert during deployment.
 *         The oracle automatically detects pool configuration and supports both:
 *         • 2‑coin pools: `price_oracle()` (no arguments)
 *         • Multi‑coin pools: `price_oracle(i)` (with coin index argument)
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
contract CurveStableswapOracleV2 is BaseOracleV2 {
    /// @dev Define if the price_oracle() method takes no arguments
    bool internal immutable NO_ARGUMENT;
    /// @dev Define the number of coins in the pool
    uint256 internal immutable N_COINS;

    ///////////////////////////////////////////////////////////////
    // --- ERRORS
    ///////////////////////////////////////////////////////////////

    error InvalidDenomIndex();
    error IncompatiblePool();

    /// @dev If one of the price feed is stale at the time of deployment, the oracle will revert.
    ///      This is intended to gate deployments on live data.
    constructor(
        address _curvePool,
        address _quoteAsset,
        address _quoteAssetFeed,
        uint256 _quoteAssetFeedHeartbeat,
        address[] memory _denomToUsdFeeds,
        uint256[] memory _denomToUsdHeartbeats,
        uint256 _scalingExponent,
        uint256 _denomIndex
    )
        BaseOracleV2(
            _curvePool,
            _quoteAsset,
            _quoteAssetFeed,
            _quoteAssetFeedHeartbeat,
            _denomToUsdFeeds,
            _denomToUsdHeartbeats,
            _scalingExponent,
            _denomIndex
        )
    {
        (N_COINS, NO_ARGUMENT) = _detectPoolConfiguration(_curvePool);
        require(_denomIndex < N_COINS, InvalidDenomIndex());

        // dry-run the price function to detect any potential anomalies
        price();
    }

    ///////////////////////////////////////////////////////////////
    // --- OVERRIDDEN FUNCTIONS
    ///////////////////////////////////////////////////////////////

    /// @notice Gets the LP token price denominated in the denomination coin
    /// @return lpPrice LP price denominated in coin[DENOM_INDEX] (18 decimals)
    /// @dev Returns 18 decimals. Uses a constant-time path for 2-coin pools,
    ///      and conservative min-over-assets in the chosen denomination for N>2
    function _lpPriceInDenomination() internal view override returns (uint256) {
        ICurveStableSwapPool pool = ICurveStableSwapPool(BASE_ASSET);
        uint256 lpVirtualPrice = pool.get_virtual_price();

        // Fast path: 2-coin pools. Price is clamped to mitigate overvaluation during asset depegs.
        if (N_COINS == 2) {
            uint256 priceC1PerC0 = NO_ARGUMENT ? pool.price_oracle() : pool.price_oracle(0);
            if (DENOM_INDEX == 0) {
                // denom = coin0 (no re‑denomination)
                // lpPriceInCoin = min(1, priceC1PerC0) × lpVirtualPrice
                return (priceC1PerC0 < 1e18) ? Math.mulDiv(lpVirtualPrice, priceC1PerC0, 1e18) : lpVirtualPrice;
            } else {
                // denom = coin1 (re‑denomination from coin0 → coin1 using EMA ratio)
                // lpPriceInCoin = min(1, 1/priceC1PerC0) × lpVirtualPrice
                return (priceC1PerC0 > 1e18) ? Math.mulDiv(lpVirtualPrice, 1e18, priceC1PerC0) : lpVirtualPrice;
            }
        }

        // Multi-coin pools (N_COINS > 2)
        uint256 minPrice = 1e18;
        if (DENOM_INDEX == 0) {
            // denom = coin0 (no re‑denomination)
            // lpPriceInCoin = min over j>0 of price_oracle(j) (coin[j] in coin0), baseline 1
            for (uint256 j = 1; j < N_COINS; j++) {
                uint256 priceCjPerC0 = pool.price_oracle(j - 1);
                if (priceCjPerC0 < minPrice) minPrice = priceCjPerC0;
            }
            return Math.mulDiv(minPrice, lpVirtualPrice, 1e18);
        } else {
            // P_d0 = price(coin[d] in coin0) (Q18)
            uint256 priceDenomPerC0 = pool.price_oracle(DENOM_INDEX - 1);

            // Include coin0 re-denominated in coin[d]: P_0d = 1 / P_d0
            uint256 priceC0PerDenom = Math.mulDiv(1e18, 1e18, priceDenomPerC0);
            if (priceC0PerDenom < minPrice) minPrice = priceC0PerDenom;

            // For every other coin j ≠ d, j ∈ [1..N-1]:
            // P_jd = (P_j0 * 1e18) / P_d0, where P_j0 = price(coin[j] in coin0)
            for (uint256 j = 1; j < N_COINS; j++) {
                if (j == DENOM_INDEX) continue;
                uint256 priceCjPerC0 = pool.price_oracle(j - 1);
                uint256 priceCjPerDenom = Math.mulDiv(priceCjPerC0, 1e18, priceDenomPerC0);
                if (priceCjPerDenom < minPrice) minPrice = priceCjPerDenom;
            }

            return Math.mulDiv(minPrice, lpVirtualPrice, 1e18);
        }
    }

    ///////////////////////////////////////////////////////////////
    // --- INTERNAL FUNCTIONS
    ///////////////////////////////////////////////////////////////

    /// @notice Detects the pool configuration by testing price_oracle() calls
    /// @param pool The Curve pool address
    /// @return nCoins Number of coins in the pool
    /// @return noArgument Whether price_oracle() takes no arguments
    function _detectPoolConfiguration(address pool) internal view returns (uint256 nCoins, bool noArgument) {
        // Check how many coins the pool has
        try ICurveStableSwapPool(pool).N_COINS() returns (uint256 value) {
            require(value > 1, IncompatiblePool());
            nCoins = value;
        } catch {
            // Fallback: universal detection via coins(i) probing (works across pool families)
            for (uint256 i; i <= 8; i++) {
                try ICurveStableSwapPool(pool).coins(i) returns (
                    address
                ) {
                // Coin exists, continue
                }
                catch {
                    require(i > 1, IncompatiblePool());
                    nCoins = i;
                    break;
                }
            }
        }

        // Test price_oracle() signature
        for (uint256 i; i < nCoins - 1; i++) {
            try ICurveStableSwapPool(pool).price_oracle(i) returns (uint256 _price) {
                require(_price > 0, InvalidPrice());
                // Method takes argument, continue testing
            } catch {
                // Method doesn't take any arguments, verify it's a 2-coin pool
                require(i == 0 && nCoins == 2, IncompatiblePool());

                // Test the no-argument version
                try ICurveStableSwapPool(pool).price_oracle() returns (uint256 _price) {
                    require(_price > 0, InvalidPrice());
                    noArgument = true;
                } catch {
                    revert IncompatiblePool();
                }
                break;
            }
        }
    }
}

/*
──────────────────────────────────────────────────────────────────────────────
EXAMPLES – how to build the **denom → USD** feed chain
──────────────────────────────────────────────────────────────────────────────
Constructor signature

    CurveStableswapOracleV2(
        curvePool,
        quoteAsset,                // USDC in the examples below
        quoteAssetFeed,            // USDC/USD Chainlink feed (not required if the denomination coin = quote asset)
        quoteAssetHeartbeat,       // Heartbeat for quote asset feed (not required if quoteAssetFeed is not set)
        denomToUsdFeeds,           // Array of feeds to convert the denomination coin to USD (not required if the denomination coin = quote asset)
        denomToUsdHeartbeats       // Array of heartbeats for each feed (not required if denomToUsdFeeds is not set)
        scalingExponent,           // Base exponent used to scale the price. Protocol specific.
        denomIndex                 // Index of the denomination coin to price in (0 = coin0, 1 = coin1, ... N-1 = coinN-1)
    )

Each element `denomToUsdFeeds[i]` converts the *output* of the previous hop into the
*input* of the next hop, until the value is finally expressed in **USD**. For
lending markets that borrow **USDC**, you then pass the USDC/USD feed via the
dedicated `quoteAssetFeed` parameter.

IMPORTANT: The oracle uses Curve's EMA price oracle for conservative pricing.
The minimum price across all pool assets (excluding coin0) is used to prevent
overvaluation during asset depegs.

---------------------------------------------------------------------
1.  USDC / USDT  **StableSwap** pool → denomination coin = USDC
---------------------------------------------------------------------
• Address: 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85
• Pool assets: USDC, USDT
• denomination coin = USDC (= quote asset)
• No conversion needed: direct pricing

      denomToUsdFeeds       = []                    // Empty array
      denomToUsdHeartbeats  = []                    // Empty array
      quoteAssetFeed          = address(0)            // No feed needed
      quoteAssetHeartbeat     = 0                     // No heartbeat needed

The oracle fetches the LP price directly from Curve's price oracle and scales it.

---------------------------------------------------------------------
2.  USDC / USDT  **StableSwap** pool → denomination coin = USDT
---------------------------------------------------------------------
• Address: 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85
• Pool assets: USDC, USDT
• denomination coin = USDT (≠ quote asset USDC)
• No conversion needed: direct pricing

      denomToUsdFeeds       = [USDT/USD feed]
      denomToUsdHeartbeats  = [1 days]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The oracle uses Curve's minimum price (USDC vs USDT) and converts USDT to USDC via the hop chain: USDT → USD → USDC.

---------------------------------------------------------------------
3.  USDT / crvUSD  **StableSwap** pool → denomination coin = USDT
---------------------------------------------------------------------
• Address: 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4
• Pool assets: USDT, crvUSD
• denomination coin = USDT (≠ quote asset USDC)
• Need to convert USDT → USD → USDC

      denomToUsdFeeds       = [USDT/USD feed]
      denomToUsdHeartbeats  = [1 days]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The oracle uses Curve's minimum price (USDT vs crvUSD) and converts USDT to USDC.

---------------------------------------------------------------------
4.  wETH / frxETH  **StableSwap-NG** pool → denomination coin = wETH
---------------------------------------------------------------------
• Address: 0x9c3B46C0Ceb5B9e304FCd6D88Fc50f7DD24B31Bc
• Pool assets: wETH, frxETH
• denomination coin = wETH (≠ quote asset USDC)
• Need to convert ETH → USD → USDC (1 wETH = 1 ETH)

      denomToUsdFeeds       = [ETH/USD feed]
      denomToUsdHeartbeats  = [1 days]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The oracle uses Curve's minimum price (wETH vs frxETH) and converts wETH to USDC.

---------------------------------------------------------------------
5.  cbBTC / wBTC  **StableSwap** pool → denomination coin = cbBTC
---------------------------------------------------------------------
• Address: 0xB7ECB2AA52AA64a717180E030241bC75Cd946726
• Pool assets: cbBTC, wBTC
• denomination coin = cbBTC (≠ quote asset USDC)

      denomToUsdFeeds       = [cbBTC/USD feed]
      denomToUsdHeartbeats  = [1 days]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The oracle uses Curve's minimum price (cbBTC vs wBTC) and converts cbBTC to USDC
via the hop chain: cbBTC → USD → USDC.

---------------------------------------------------------------------
6.  cbBTC / wBTC  **StableSwap** pool → denomination coin = wBTC
---------------------------------------------------------------------
• Address: 0xB7ECB2AA52AA64a717180E030241bC75Cd946726
• Pool assets: cbBTC, wBTC
• denomination coin = wBTC (≠ quote asset USDC)
• Need to convert wBTC → BTC → USD → USDC (because there is no wBTC/USD feed)

      denomToUsdFeeds       = [wBTC/BTC feed, BTC/USD feed]
      denomToUsdHeartbeats  = [1 days, 1 hours]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The oracle uses Curve's minimum price (cbBTC vs wBTC) and converts wBTC to USDC via the hop chain: wBTC → BTC → USD → USDC.

---------------------------------------------------------------------
7.  sUSDS / USDT  **StableSwap** pool → denomination coin = sUSDS
---------------------------------------------------------------------
• Address: 0x00836Fe54625BE242BcFA286207795405ca4fD10
• Pool assets: sUSDS, USDT
• denomination coin = sUSDS (≠ quote asset USDC)
• Need to convert USDS → USDC (because coin0 is an appreciating token, the first feed must price the principal token, not the wrapper token!)

      denomToUsdFeeds       = [USDS/USD feed] // Principal token feed
      denomToUsdHeartbeats  = [23 hours]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The denomination coin is an appreciating token, so the first feed must price the principal token, not the wrapper token!
The oracle uses Curve's minimum price (sUSDS vs USDT) and converts USDS to USDC via the hop chain: USDS → USDC.
*/
