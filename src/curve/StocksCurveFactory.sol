// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StocksCurve} from "./StocksCurve.sol";

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

/// @notice Standalone spawner for StocksCurve.
contract StocksCurveFactory {
    function deploy(
        address tstToken,
        address stockToken,
        address trustedSigner,
        uint256 price,
        uint256 priceTimestamp,
        bytes calldata signature,
        uint256 rewardsDuration,
        uint256 graduationUsdThreshold,
        uint256 minRewardsDuration,
        uint256 maxRewardsDuration
    ) external returns (address curve) {
        curve = address(
            new StocksCurve(
                tstToken,
                stockToken,
                trustedSigner,
                price,
                priceTimestamp,
                signature,
                rewardsDuration,
                msg.sender,
                graduationUsdThreshold,
                minRewardsDuration,
                maxRewardsDuration
            )
        );
    }
}
