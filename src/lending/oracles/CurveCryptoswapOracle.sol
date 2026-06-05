// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICurveCryptoSwapPool} from "@strategies/src/interfaces/ICurvePool.sol";
import {BaseOracle} from "src/lending/oracles/BaseOracle.sol";

/**
 * @title  CurveCryptoswapOracle
 * @notice Read‑only market-based price oracle that returns the value of one Curve
 *         **Crypto-swap** LP token (base asset) expressed in an arbitrary
 *         quote asset (USDC, crvUSD, USDT, …).
 *
 *         The oracle is intended for lending markets where Curve's LP token (base asset) is
 *         used as collateral and the loan asset (quote asset) is the unit in which debts are
 *         denominated.
 *
 *         Supported pool families: **Crypto Pool**, **TwoCrypto-NG**, and **TriCrypto-NG**
 *
 * @dev    Pricing formula
 *         ----------------
 *             Price(Base / Quote) = lp_price()                     ⎫ in coin0
 *                               × Π price(hopᵢ)                    ⎬ coin0 → USD
 *                               ÷ price(Quote / USD)               ⎭ USD    → Quote
 *
 *        • The base asset is the LP token itself
 *        • Curve documentation guarantees that `lp_price()` is denominated in
 *          the coin at index 0 of the pool.
 *        • `token0ToUsdFeeds` is an ordered array of Chainlink feeds that, hop
 *           by hop, convert coin0 into USD. Each element consumes the output
 *           of the previous hop.
 *
 *         Flash-manipulation caveat
 *         -------------------------------------------
 *         This oracle implements conservative minimum pricing across all pool assets
 *         and is intended for high-TVL, curated pools only. While `lp_price()`
 *         could theoretically be manipulated, the multi-layer protections and economic
 *         barriers make such attacks practically infeasible for the target deployment.
 *         Conservative LLTV settings are still recommended for additional safety.
 *
 *         Feed availability and adapter pattern
 *         ------------------------------------
 *         When coin0 ≠ quote asset, the oracle requires a hop-chain to convert coin0 to USD.
 *         Each hop in the chain can return prices in any denomination - the chain composition
 *         determines the final USD conversion.
 *
 *         Optional Quote Asset Feed
 *         ------------------------------------
 *         When coin0 = quote asset, no external feeds are required and the oracle
 *         provides direct pricing with optimal gas efficiency.
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
contract CurveCryptoswapOracle is BaseOracle {
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
        // dry-run the internal function to detect any anomalies
        _getLpPriceInCoin0();
    }

    ///////////////////////////////////////////////////////////////
    // --- OVERRIDDEN FUNCTIONS
    ///////////////////////////////////////////////////////////////

    /// @notice Gets the LP token price in coin0 terms
    /// @dev The base asset is the Curve pool address
    /// @return lpPrice The LP token price in coin0 terms (18 decimals)
    function _getLpPriceInCoin0() internal view override returns (uint256) {
        return ICurveCryptoSwapPool(BASE_ASSET).lp_price();
    }
}

/*
──────────────────────────────────────────────────────────────────────────────
EXAMPLES – how to build the **coin0 → USD** feed chain
──────────────────────────────────────────────────────────────────────────────
Constructor signature

    CurveCryptoswapOracle(
        curvePool,
        quoteAsset,                 // USDC in the examples below
        quoteAssetFeed,             // USDC/USD Chainlink feed (not required if coin0 = quote asset)
        quoteAssetHeartbeat,        // Heartbeat for quote asset feed (not required if quoteAssetFeed is not set)
        token0ToUsdFeeds,           // Array of feeds to convert coin0 to USD (not required if coin0 = quote asset)
        token0ToUsdHeartbeats       // Array of heartbeats for each feed (not required if token0ToUsdFeeds is not set),
        scalingExponent                // Base exponent used to scale the price. Protocol specific.
    )

Each element `token0ToUsdFeeds[i]` converts the *output* of the previous hop into the
*input* of the next hop, until the value is finally expressed in **USD**. For
lending markets that borrow **USDC**, you then pass the USDC/USD feed via the
dedicated `quoteAssetFeed` parameter.

IMPORTANT: The oracle uses Curve's `lp_price()` for conservative pricing.
When coin0 = quote asset, no external feeds are required for optimal gas efficiency.

---------------------------------------------------------------------
1.  TriCrypto-USDC pool  → coin0 = USDC
---------------------------------------------------------------------
• Address: 0x7F86Bf177Dd4F3494b841a37e810A34dD56c829B
• Pool assets: USDC, wBTC, ETH
• coin0 = USDC (= quote asset)
• No conversion needed: direct pricing

      token0ToUsdFeeds       = []                    // Empty array
      token0ToUsdHeartbeats  = []                    // Empty array
      quoteAssetFeed          = address(0)            // No feed needed

The oracle fetches the LP price directly from Curve's `lp_price()` and scales it.

---------------------------------------------------------------------
2.  TriCrypto-USDT pool  (USDT / wBTC / WETH)   → coin0 = USDT
---------------------------------------------------------------------
• Address: 0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4
• Pool assets: USDT, wBTC, WETH
• coin0 = USDT (≠ quote asset USDC)
• Need to convert USDT → USD → USDC

      token0ToUsdFeeds       = [USDT/USD feed]
      token0ToUsdHeartbeats  = [1 days]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The USDT/USD feed is mandatory so the oracle reacts to any USDT de-peg.

---------------------------------------------------------------------
3.  wETH / RSUP pool  → coin0 = WETH
---------------------------------------------------------------------
• Pool assets: wETH, RSUP
• coin0 = wETH (≠ quote asset USDC)
• WETH is a **1:1 non-rebasing wrapper** around ETH
• Need to convert ETH → USD → USDC

      token0ToUsdFeeds       = [ETH/USD feed]        // Safe to skip wETH/ETH hop (1:1)
      token0ToUsdHeartbeats  = [1 days]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

Because wETH unwraps 1:1 into ETH, a single ETH/USD feed to convert coin0 to USD is required.

---------------------------------------------------------------------
4.  swETH / frxETH pool  → coin0 = swETH
---------------------------------------------------------------------
• Pool assets: swETH, frxETH
• coin0 = swETH (≠ quote asset USDC)
• swETH is a liquid staking derivative of ETH
• Need to convert swETH → ETH → USD → USDC (because there is no swETH/USD feed)

      token0ToUsdFeeds       = [swETH/ETH feed, ETH/USD feed]
      token0ToUsdHeartbeats  = [1 days, 1 days]
      quoteAssetFeed          = USDC/USD feed
      quoteAssetHeartbeat     = 1 days

The oracle converts swETH to USDC via the hop chain: swETH → ETH → USD → USDC.
This handles the case where liquid staking derivatives don't have direct USD feeds.
*/
