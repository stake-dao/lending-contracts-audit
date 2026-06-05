# Stake DAO Lending

> [!Important]  
> Liquidators **must** call `claimLiquidation` on the relevant wrapper after seizing collateral.  
> This step unwraps the seized Stake DAO vault shares, stops reward accrual for the liquidated account, and prevents the liquidator from being out of sync. Skipping it leaves funds idle and can brick withdrawals.

## Overview

Stake DAO Lending lets integrators originate borrowing markets that accept Stake DAO strategy vault positions as collateral without breaking users’ yield. Collateral tokens remain staked in their native vaults, continue to earn protocol rewards, and can be routed into multiple lending venues through wrapper contracts, oracles, and factory tooling shipped in this package.

## Lending At A Glance

- **Yield-preserving collateral:** Users wrap Stake DAO reward vault shares or raw LP tokens and keep earning both main and extra incentives while the wrapper sits inside a lending protocol.
- **Non-transferable wrappers:** `StrategyWrapper` tokens only move between the wrapper and the lending protocol, eliminating approval phishing vectors and making state tracking deterministic.
- **Composable factories:** Market deployment is split between an underlying-protocol factory (`CurveLendingMarketFactory.sol`) and a lending-protocol factory (`MorphoMarketFactory.sol`) so new combinations can be added independently.
- **Battle-tested pricing:** Curve LPs are priced through purpose-built oracles (`CurveStableswapOracle.sol`, `CurveCryptoswapOracle.sol`) that compose Chainlink/Pyth feeds, conservative EMA data, and configurable scaling exponents.
- **Liquidation helpers:** `MorphoLiquidationModule.sol` measures seized collateral precisely, unwraps it, and drives Morpho liquidations while letting liquidators plug in custom swap logic.
- **Adapter layer:** Chainlink-style adapters expose Stake DAO oracles, Curve’s native feeds, and Pyth quotes through a common interface for third-party consumption.

## Collateral Lifecycle

1. **Wrap**
   - Deposit existing reward vault shares via `StrategyWrapper.depositShares` or raw LP tokens via `depositAssets`.
   - The wrapper mints non-transferable tokens 1:1, checkpoints rewards, and immediately supplies them to the target lending protocol.
2. **Accrue yield**
   - `StrategyWrapper` mirrors Stake DAO’s accountant integrals so users earn main rewards (e.g. CRV) plus any extra gauges while collateral sits in the market.
3. **Borrow / Manage**
   - Borrowing, repayments, and health checks live entirely in the lending protocol (e.g. Morpho Blue). The wrapper only needs authorization to withdraw on behalf of the user.
4. **Withdraw**
   - `withdraw` burns wrapper balances, unwraps reward-vault shares, and claims pending rewards in a single call.
   - `withdrawCollateral` pulls collateral out of the lending protocol first (requires prior authorization), then finalizes the unwrap.
5. **Liquidate**
   - When liquidation occurs, the lending protocol transfers wrapper tokens to the liquidator.
   - The liquidator calls `claimLiquidation(liquidator, victim, seizedAmount)` to unwrap the seized Stake DAO vault shares and realign reward accounting.

## Architecture

### Collateral Wrappers (`wrappers/`)

- `StrategyWrapper.sol` is the base implementation for wrapping reward-vault shares into a non-transferable ERC20 used as collateral.
  - Maintains granular checkpoints per user for the main reward token and every “extra reward” emitted by the vault’s gauge.
  - Enforces that only the configured lending protocol can transfer wrapper balances. Users never approve arbitrary spenders.
  - Deposits automatically forward freshly minted wrapper tokens to the lending protocol through an overridable hook.
  - `claim`, `claimExtraRewards`, and `getPending*` helpers expose reward flows to integrators.
  - Liquidations invoke `claimLiquidation`, which repatriates the underlying vault shares and synchronises both main and extra rewards so users never lose accrued incentives when their positions are seized.
- `MorphoStrategyWrapper.sol` extends the base wrapper with Morpho Blue specifics: automatic `supplyCollateral`/`withdrawCollateral` calls, market-id validation, dynamic naming, and position lookups.

> **Extending to new venues:** inherit from `StrategyWrapper`, override `_supplyLendingProtocol`, `_withdrawLendingProtocol`, `_getWorkingBalance`, and optionally `name`/`symbol`. Reuse every other behaviour.

### Price Oracles (`oracles/`)

- `BaseOracle.sol` is the shared scaffolding for Curve LP pricing in arbitrary quote assets. It builds:
  - Deterministic scaling that matches the lending protocol’s expected precision (`ORACLE_SCALING_EXPONENT`).
  - Hop-by-hop conversions (Chainlink feeds) from the pool’s `coin0` into USD and finally into the loan asset.
  - Comprehensive freshness checks with per-feed heartbeats.
- The “hop” architecture means a single deployment supports anything from direct coin0=loan-asset pools to complex sequences like `swETH → ETH → USD → crvUSD` without additional helper contracts. Every Curve market therefore reuses the same audited bytecode.
- Scaling expectations are parameterised: switching from Morpho’s 36-decimal format to another venue only requires passing a different exponent instead of redeploying bespoke oracles, keeping audits and change scopes tiny.
- Appreciating wrappers (wstETH, sDAI, etc.) are normalised automatically so LP tokens from StableSwap-NG pools are never overvalued.
- `CurveStableswapOracle.sol` and `CurveCryptoswapOracle.sol` sit on top of `BaseOracle` for their respective pool families, inheriting all the safety guarantees while focusing solely on reading Curve’s EMA primitives.
- `CurveStableswapOracle.sol` covers StableSwap & StableSwap-NG pools by combining the EMA `price_oracle` minimum with `get_virtual_price`.
- `CurveCryptoswapOracle.sol` handles Crypto, TwoCrypto-NG, and TriCrypto-NG pools via `lp_price`.
- `CurvePriceFeedChainlinkAdapter.sol` and `OracleChainlinkAdapter.sol` wrap Curve feeds or Stake DAO oracles behind a Chainlink-compatible interface.
- `PythChainlinkAdapter.sol` exposes Pyth price ids in the same format, simplifying hybrid feed setups.

### Market Factories (`factories/`)

- `CurveLendingMarketFactory.sol` (underlying factory)
  - Verifies that a wrapper points to an authenticated Stake DAO Curve reward vault via the protocol controller.
  - Deploys the correct oracle flavour, wires heartbeats, and emits structured metadata for indexers.
  - Delegates market creation to any lending factory that implements `ILendingFactory`.
- Because factory parameters cover pool addresses, hop feeds, heartbeats, and scaling in one call, onboarding new Curve LPs rarely requires new Solidity, just new constructor data.
- `MorphoMarketFactory.sol` (lending factory)
  - Creates or idempotently reuses Morpho Blue markets, initializes wrappers with the market id, and optionally pre-seeds liquidity to avoid zero-utilization front-running.
  - Plays well with other underlying factories as long as the wrapper obeys `IStrategyWrapper`.

Splitting responsibilities this way makes it easy to plug a new lending protocol (write a factory + wrapper subclass) or a new underlying ecosystem (write another underlying factory with bespoke oracle deployment).

### Liquidation Module (`MorphoLiquidationModule.sol`)

- Provides a permissionless swap-routing helper for liquidators operating Stake DAO wrappers on Morpho Blue.
- Encodes the pre-callback wrapper balance, unwraps seized tokens via `claimLiquidation`, runs swap logic to turn collateral into the loan asset, approves Morpho for the repayment, and forwards any loan-token surplus and any leftover unwrapped collateral to the caller-supplied `receiver` (use `address(0)` to default to `msg.sender`). The module holds no funds across calls in steady state.
- `liquidate`/`onMorphoLiquidate` target Morpho Blue directly. `onMorphoLiquidate` is gated by `onlyMorpho` against the hardcoded `Lending.MORPHO_BLUE`. `liquidate` is permissionless: anyone, any receiver. No role gating, no admin surface, no transient storage.
- Pre-liquidation flows are out of scope for this module. A future module deploy can reintroduce them if protocol design choices change.
- `_swapToLoanToken` is internal virtual so integrators can override with aggregator-specific settlement (Enso, 1inch, etc.).

## Launching a Market

1. **Deploy the wrapper** (`MorphoStrategyWrapper` or a custom subclass) pointing at the Stake DAO reward vault and the target lending protocol. Transfer ownership to your deployer multisig.
2. **Bootstrap oracle + market** by calling `CurveLendingMarketFactory.deploy` with:
   - A verified wrapper instance and the Curve pool address,
   - Oracle parameters (loan asset, quote feeds, heartbeats, scaling exponent inferred from the lending factory),
   - `MarketParams` for the target lending factory (IRM, LLTV, initial supply).
3. **Register the market id** inside the wrapper via `initialize(bytes32 marketId)`—handled automatically when using `CurveLendingMarketFactory` + `MorphoMarketFactory`.
4. **Authorize withdrawals** on the lending protocol by having users call its approval flow (e.g. Morpho `setAuthorization`).
5. **Integrate front-ends** by building deposit flows around `depositShares`/`depositAssets` and exposing reward claim helpers.

## Working With Liquidations

- Anyone can call `MorphoLiquidationModule.liquidate(...)` with any `receiver` (use `address(0)` to default to `msg.sender`). The module receives unwrapped Stake DAO vault tokens in `onMorphoLiquidate`, swaps via `_swapToLoanToken`, approves Morpho Blue for the debt amount, and forwards the loan-token surplus and any leftover unwrapped collateral to the receiver before Morpho pulls `repaidAssets`.
- Pre-liquidation flows are not supported by this module. Pre-liquidation contracts deployed by Morpho's `PreLiquidationFactory` against Stake DAO markets are still observable on-chain and the indexer continues to track them, but the bot path through this module is gone.
- External bots should monitor for wrapper balances greater than the recorded checkpoint balance; this indicates a pending `claimLiquidation` step.
- The module has no admin and no `sweepToken`. Accidental sends of the market's `loanToken` or the wrapper's underlying reward-vault token are socialized to the next liquidator via `_forwardSurplus`. Sends of any OTHER token (or native ETH) are **not recoverable** — there is no escape hatch. Treat the contract address as send-once for the two market-relevant tokens only.

## Extending the System

- **New lending venues:** create a wrapper subclass + lending factory that implement `IStrategyWrapper` and `ILendingFactory`. You can still reuse `CurveLendingMarketFactory` for oracle deployment.
- **New underlying protocols:** provide a factory similar to `CurveLendingMarketFactory` that mints protocol-specific wrappers and oracles, then reuse existing lending factories.
- **Alternative price feeds:** plug additional adapters or feed combinations by composing the Chainlink/Pyth adapters and passing them through `CurveLendingMarketFactory`.

## Contact

[contact@stakedao.org](mailto:contact@stakedao.org)
