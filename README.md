# Stake DAO Lending — Audit Scope

Isolated, self-contained extraction of the Stake DAO Lending smart contracts for external audit. Everything needed to compile the in-scope contracts lives in this repository. No package manager, no workspace, no network access is required to build.

## Provenance

Extracted verbatim from [stake-dao/contracts-monorepo](https://github.com/stake-dao/contracts-monorepo), path `packages/periphery/src/lending`. The state corresponds to `main` (commit `5f4cb2dd`) with the permissionless liquidation module from PR #464 (`feat/liquidation-module-permissionless`) applied on top. Because `main` and that branch touch disjoint files, this is exactly the tree PR #464 produces once rebased onto `main` and merged, which is the intended deploy target.

Concretely, three in-scope files come from the branch: `MorphoLiquidationModule.sol`, `interfaces/IMorphoLiquidationModule.sol`, and the product `README.md`. Every other in-scope file is byte-identical to `main` (including `StrategyWrapper.sol`, which carries `main`'s newer `version()`). Re-verify with a `diff` against either ref as needed.

## In scope (`src/lending/`)

| Area | Files |
| --- | --- |
| Wrappers | `wrappers/StrategyWrapper.sol`, `wrappers/MorphoStrategyWrapper.sol` |
| Oracles | `oracles/BaseOracle.sol`, `oracles/CurveStableswapOracle.sol`, `oracles/CurveCryptoswapOracle.sol`, `oracles/CurvePriceFeedChainlinkAdapter.sol`, `oracles/OracleChainlinkAdapter.sol`, `oracles/PythChainlinkAdapter.sol` |
| Oracles v2 | `oracles/v2/BaseOracleV2.sol`, `oracles/v2/CurveStableswapOracleV2.sol` |
| Liquidation | `MorphoLiquidationModule.sol` |
| Leverage helper | `StrategyWrapperLeverageRouter.sol` |
| Interfaces | `interfaces/*.sol` |

`README.md` and `CURATORS.md` inside `src/lending/` are the original product docs, kept for context.

## Out of scope (excluded from this extraction)

- **Factories** (`factories/`): the two-stage market deployment contracts. Excluded by request.
- **Risk framework** (`risk-framework/`): curator decision framework, docs only.
- **`dependencies/` and `lib/`**: trusted upstream libraries (OpenZeppelin, Stake DAO interfaces, address-book constants). Vendored only so the in-scope code compiles. Not part of the audit target.

## Dependencies

All third-party and cross-package code is vendored, not fetched, so the audited sources are reviewed exactly as they ship.

- `lib/openzeppelin-contracts/` — OpenZeppelin Contracts `5.2.0` (unmodified).
- `lib/forge-std/` — Forge standard library `v1.9.5`.
- `dependencies/` — the minimal Stake DAO closure the contracts compile against: **interfaces and address constant libraries only**. The lending contracts never inherit from or call into a Stake DAO contract implementation, so this closure is 9 small files:
  - `strategies/src/interfaces/`: `ICurvePool`, `IProtocolController`, `IRewardVault`, `IAccountant`
  - `interfaces/src/interfaces/stake-dao/`: `IStrategyV2`, `IAllocatorV2`
  - `shared/src/interfaces/`: `IMorpho`, `IMorphoFlashLoanCallback`
  - `address-book/src/`: `SDEthereum`

## Build

```sh
forge build
```

Toolchain pinned to match production: `solc 0.8.28`, EVM `cancun`, optimizer on at `200` runs.

## Notes for auditors

These constraints are load-bearing and documented in `src/lending/README.md`.

- **Wrappers are non-transferable.** They only move between a user and the lending protocol. Any flow requiring a third-party transfer is broken by construction.
- **Liquidation must end with `claimLiquidation`.** A liquidator that seizes wrapper tokens without calling it leaves rewards desynchronized and can brick withdrawals.
- **Curve oracle parity assumption.** The Stableswap clamp assumes every pool coin trades at or below par with the denomination coin. Parity-violating pools are silently underpriced.
- **No L2 sequencer guard.** The oracles assume mainnet. An L2 deployment must wrap them in a sequencer-uptime adapter.
- **Unaudited-by-design surfaces:** `oracles/v2/` (configurable denomination) and `oracles/PythChainlinkAdapter.sol`. Flagged here so they are not mistaken for hardened code.
