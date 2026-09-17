# Stocks.ink — V7 Contracts (Audit Repo)

This is a contracts-only export of [Stocks.ink](https://stocks.ink)'s current generation ("V7"), prepared for external audit. It is not the main app repo — the frontend, docs site, and deploy history for earlier generations live elsewhere.

Stocks.ink lets anyone launch a tokenized version of a real-world stock ("TST" - Tokenized Stock Treasury), bond it against a signed real-time price attestation, and trade it through a bonding curve that graduates into a live Uniswap V4 pool with on-chain staking and governance over the resulting treasury.

## Start here

Read [`AUDIT.md`](./AUDIT.md) first — it has the current contract set, build/test status, and a manual security review with specific findings and design properties worth auditor attention.

## Repo layout

- `src/` — 12 core contracts (see `AUDIT.md` for the full list) plus `src/dex/v4/twamm/vendor/` — a vendored, third-party TWAMM implementation (audited separately by ABDK Consulting and Certora; not written by this team, included here only so the repo compiles standalone).
- `test/` — Foundry test suite: security-focused suites, fuzz tests, invariant tests, one Halmos symbolic-execution test.
- `script/` — deploy scripts for the current factory generation (`DeployFactoryV7.s.sol`), the shared metadata registry, and a local mock-token deploy helper for testing.

## Building and testing

```
git submodule update --init --recursive
forge build
forge test
```

Requires [Foundry](https://getfoundry.sh). One `foundry.toml` quirk: `StocksHook.sol` is compiled with `optimizer_runs = 1` (see `additional_compiler_profiles`) instead of the repo default, because it sits right at the EIP-170 24,576-byte contract size limit and needs the smaller bytecode over cheaper gas.

`test/StocksCurve.halmos.t.sol` is written for the separate [Halmos](https://github.com/a16z/halmos) symbolic testing tool, not plain `forge test` — it needs `halmos-cheatcodes` set up per Halmos's own install instructions if you want to re-run it.

## Contract generation history (context, not action needed)

This is the latest in a series of redeploys/rewrites (V2 → V7) as bugs were found and fixed pre- and post-mainnet-launch, including a real graduation-threshold bug that fired on a live pool before being caught and fixed. `AUDIT.md` covers what's actually relevant to review today; ask the project owner if you want the full prior history for context.
