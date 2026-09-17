# Audit-readiness summary — V7

Prepared by the project owner's own AI-assisted internal review, ahead of a professional external audit. This is **not a substitute for that audit** — it's a snapshot of what's already been checked, what already broke and got fixed pre-mainnet, and where we think an auditor's time is best spent first.

## Build & test status (as of this export)

```
forge build --force   → clean, 0 errors (a handful of style-only lint notes: missing-inheritance on
                         test mocks, internal-function-used-once, modifier-used-only-once — none
                         affect correctness or security)
forge test             → 115/115 passing across 18 test suites, 0 failed, 0 skipped
```

Included in that 115: `StocksStakingInvariantTest` (256 runs / 128,000 calls / 0 reverts across 11 handler functions — stake, unstake, claim, claimLiquidated, donateReward, governor pause/duration/liquidate, qualified-holder wrap/unwrap, warpTime), plus dedicated fuzz suites for the curve, the hook's fee routing, and staking; plus targeted regression suites for previously-found issues (see "Prior findings already fixed" below).

**Static analysis**: [Aderyn](https://github.com/Cyfrin/aderyn) was attempted but crashes on this codebase with a reproducible tool bug on Windows (`Panic: aderyn_core/src/detect/entrypoint.rs:269 — File Not Found in Ignore stats`), independent of shell (reproduced via both PowerShell and a POSIX shell). Static analysis here is Foundry's own built-in linter output only (see above) — an auditor's own toolchain (Slither, Aderyn on Linux/Mac, Mythril, etc.) has not yet been run against this exact contract set.

## Contract set (12 files, excluding vendored code)

| Contract | Role |
|---|---|
| `StocksLaunchFactory.sol` | Entry point: mints the TST, deploys its curve, optionally sets on-chain metadata, all in one atomic transaction |
| `curve/StocksCurve.sol` | Constant-product bonding curve; buy/sell/graduate |
| `curve/StocksCurveFactory.sol` | Thin, permissionless `StocksCurve` spawner |
| `dex/v4/StocksHook.sol` | Uniswap V4 hook: fee routing (burn/treasury/protocol split) + TWAMM integration for gradual treasury liquidation |
| `dex/v4/StocksGraduator.sol` | Shared singleton: seeds a curve's real V4 pool and locks initial liquidity at graduation |
| `dex/v4/StocksPoolView.sol` | Thin read-only per-pool identity/forwarding contract |
| `StocksStaking.sol` | Per-pool staking + treasury: reward streaming, governance-gated pause/duration/liquidation, dividend wrap/unwrap |
| `StocksStakingFactory.sol` | Thin, permissionless `StocksStaking` spawner |
| `governance/StocksGovernor.sol` | Per-pool OZ-Governor-based treasury governance |
| `governance/StocksGovernorFactory.sol` | Thin, permissionless `StocksGovernor` spawner |
| `TSTToken.sol` | The launched token itself — `ERC20Votes`, one-time fixed mint, no admin |
| `TokenMetadataRegistry.sol` | Shared singleton: one-time, permissionless, front-run-safe on-chain pointer to a token's IPFS metadata |

`src/dex/v4/twamm/vendor/` is a vendored, third-party TWAMM implementation — **not written by this team** and out of scope for our own manual review below. It has its own prior third-party audits (ABDK Consulting, Certora) available from the project owner on request.

## Manual review — what we checked and what we found

This was a full manual read of all 12 contracts above (not a line-by-line formal audit). No exploitable vulnerabilities were found. The items below are either (a) design properties an auditor should explicitly sign off on rather than flag as bugs, or (b) the areas we'd most want independent eyes on given their complexity.

### Top areas for auditor attention

1. **`StocksHook`'s two-phase fee split.** A buy takes a protocol cut of the stock-side input *before* the swap executes (`beforeSwap`), then takes the remainder of the fee from the TST-side output *after* the swap (`afterSwap`), with `afterSwap`'s effective rate reduced by the already-taken protocol share so the two phases sum to the intended total (default 10%, `PROTOCOL_FEE_SHARE_BPS = 2_000` = 20% of that going to protocol) without double-counting. This is the single most mathematically intricate piece of the whole system and the one place we'd most want an independent re-derivation of the bps arithmetic across both directions (buy vs. sell) and both fee-currency cases.
2. **`trustedSigner` centralization.** Every curve's graduation economics are seeded from one signed off-chain price attestation (`StocksLaunchFactory.trustedSigner`); the signed message is domain-bound to the specific launch factory's own address (baked in via `StocksCurveFactory.deploy()` passing `msg.sender` through as `_factory`), so a signature can't be replayed against a different factory generation or a spoofed direct caller. This is a single-key operational trust assumption, not a code bug — worth auditors explicitly noting as out-of-contract risk (key custody, signer uptime) rather than something fixable in Solidity.
3. **`graduationStockTarget` is fixed at launch and never re-priced.** `StocksCurve` computes the USD-denominated graduation target once from the attested price at launch time; if the real stock price moves significantly afterward, the target stays fixed in stock-token terms, not USD terms. Intentional economic design (matches how a fixed-supply bonding curve has to work), but worth an explicit sign-off that this is understood and accepted, not overlooked.
4. **`StocksStaking`'s O(1) reward accounting.** Uses a running `sumBalanceTimesPaid` invariant (updated incrementally on every stake/unstake/settle) to compute "total accrued-but-unclaimed rewards across all stakers" without iterating stakers — needed so `liquidateTreasury()` and `unwrapTreasuryStock()` can safely compute how much of the treasury's stock balance is untouchable (already owed to stakers) vs. safe to move. Already covered by a 128,000-call invariant suite with 0 reverts and 0 invariant violations, but this is exactly the kind of accounting trick worth an auditor independently re-deriving from scratch.

### Documented design properties (reviewed, not flagged as bugs)

- **`StocksCurveFactory`/`StocksStakingFactory`/`StocksGovernorFactory` are permissionless spawners.** Anyone can call `.deploy()` directly, bypassing `StocksLaunchFactory`. This is safe only because each spawned contract's own authorization (signature domain-binding in `StocksCurve`, `curve`/`governor` address checks in `StocksStaking`) is anchored to `msg.sender` *at construction time* — the direct caller's own address — so a bypass attempt can never produce a validly-signed attestation or a spoofed authorization pointer. Worth an auditor's explicit confirmation of this reasoning rather than trusting our own write-up of it.
- **`StocksHook.notifyRewardAmount()`'s call result is intentionally unchecked.** If the downstream staking contract's reward-rate refresh reverts or is missing, the stock-side fee transfer to the treasury still lands (it happens via `safeTransfer` beforehand); only the *reward-rate refresh timing* is delayed, not the funds. Deliberately chosen so a downstream failure can never block a swap.
- **`StocksStaking.unwrapTreasuryStock()`'s 14-day cooldown (`UNWRAP_COOLDOWN`) is global, not per-caller.** Any qualifying holder (`onlyMinHolder`, governance-configured `minHolderBps` floor) can trigger an unwrap, which then blocks every other holder from unwrapping again for 14 days. Intentional given the treasury is shared, but worth confirming the `minHolderBps` floor is set high enough in practice to make this an acceptable tradeoff rather than a griefing vector.
- **`StocksGraduator.graduate()` pulls seed funds via `safeTransferFrom`, not a push-then-call pattern** — this was a deliberate fix (see below) closing a reentrancy-hijack class of bug from an earlier generation.
- **Exact-output swaps are explicitly disallowed** (`StocksHook.afterSwap` reverts `ExactOutputNotSupported()` on `params.amountSpecified > 0`) since the fee-routing math assumes an exact-input swap throughout.

## Prior findings already fixed (context, not action needed)

This is not this project's first audit pass. An earlier internal AI-assisted round (8 parallel review passes + consolidation, documented separately and available from the project owner on request) on an earlier contract generation found and fixed several real issues that carried forward into this codebase's current design, most notably:

- A reentrancy-hijack class of bug in the old push-then-call graduation flow — fixed by switching to the current approve/pull pattern you'll see in `StocksGraduator.graduate()` today.
- A price-attestation replay window — fixed by the `usedAttestations` mapping you'll see in `StocksLaunchFactory.createCurve()` today.
- An exact-output fee-bypass in the V4 hook — fixed by the explicit revert you'll see in `StocksHook.afterSwap()` today.
- A live graduation-threshold bug (`GRADUATION_USD_THRESHOLD` hardcoded to a $10 testing value instead of the intended $8,000) that fired on one real pre-mainnet/testing launch before being caught — fixed by moving this and other key parameters (reward duration bounds, voting delay/period, proposal threshold, min-holder bps) into constructor-supplied, per-deployment config (see `StocksLaunchFactory`'s constructor) instead of hardcoded constants.

We're surfacing these so an auditor has the "why does the code look like this" context, not asking anyone to re-verify them from scratch — each has its own dedicated regression test in `test/`.
