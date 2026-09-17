// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StocksStaking} from "./StocksStaking.sol";

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

/// @notice Standalone spawner for StocksStaking.
contract StocksStakingFactory {
    function deploy(
        address tstToken,
        address stockToken,
        uint256 rewardsDuration,
        address governor,
        address hook,
        uint256 minHolderBps
    ) external returns (address staking) {
        staking = address(
            new StocksStaking(tstToken, stockToken, rewardsDuration, governor, hook, msg.sender, minHolderBps)
        );
    }
}
