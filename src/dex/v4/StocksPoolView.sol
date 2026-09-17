// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksHook} from "./StocksHook.sol";

// ╔══════════════════════════════════════════════════════════════════╗
// ║                                                                    ║
// ║   S T O C K S . I N K                                             ║
// ║                                                                    ║
// ║   Tokenized real-world equities, traded and staked on-chain.       ║
// ║                                                                    ║
// ╚══════════════════════════════════════════════════════════════════╝
//
// Stocks.ink lets anyone launch a tokenized version of a real-world stock,
// bond it against real price data, and trade it through a bonding curve
// that graduates into a live, fee-generating Uniswap V4 pool with on-chain
// staking and governance for the underlying treasury.

/// @notice Thin, per-pool identity contract for one graduated Uniswap V4 pool, forwarding reads
/// through to the shared StocksHook.
contract StocksPoolView {
    using PoolIdLibrary for PoolKey;

    StocksHook public immutable hook;
    PoolId public immutable poolId;
    PoolKey private _poolKey;

    constructor(StocksHook hook_, PoolKey memory poolKey_) {
        hook = hook_;
        _poolKey = poolKey_;
        poolId = poolKey_.toId();
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function token0() external view returns (address) {
        return Currency.unwrap(_poolKey.currency0);
    }

    function token1() external view returns (address) {
        return Currency.unwrap(_poolKey.currency1);
    }

    function tstToken() external view returns (address) {
        return hook.tstToken(poolId);
    }

    function stockToken() external view returns (address) {
        return hook.stockToken(poolId);
    }

    function treasury() external view returns (address) {
        return hook.treasury(poolId);
    }

    function feeBps() external view returns (uint256) {
        return hook.feeBps(poolId);
    }

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        return hook.getReserves(poolId);
    }

    function price0CumulativeLast() external view returns (uint256) {
        return hook.price0CumulativeLast(poolId);
    }

    function price1CumulativeLast() external view returns (uint256) {
        return hook.price1CumulativeLast(poolId);
    }
}
