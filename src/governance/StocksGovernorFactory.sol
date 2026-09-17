// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {StocksGovernor} from "./StocksGovernor.sol";

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

/// @notice Standalone spawner for StocksGovernor.
contract StocksGovernorFactory {
    function deploy(
        string memory name_,
        IVotes token,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumNumerator
    ) external returns (address governor) {
        governor =
            address(new StocksGovernor(name_, token, votingDelay, votingPeriod, proposalThreshold, quorumNumerator));
    }
}
