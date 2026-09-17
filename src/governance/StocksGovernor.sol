// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from
    "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

/// @notice Token-holder governance over a single pool's treasury, built on OpenZeppelin's
/// Governor stack.
contract StocksGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction
{
    uint48 public constant MIN_VOTING_DELAY = 1 hours;
    uint32 public constant MIN_VOTING_PERIOD = 1 hours;
    uint256 public constant MIN_QUORUM_NUMERATOR = 1;
    uint256 public constant PROPOSAL_THRESHOLD_BPS = 50; // 0.5%
    uint256 private constant BPS_DENOM = 10_000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    error VotingDelayTooShort(uint48 votingDelay, uint48 minVotingDelay);
    error VotingPeriodTooShort(uint32 votingPeriod, uint32 minVotingPeriod);
    error QuorumNumeratorTooLow(uint256 quorumNumerator, uint256 minQuorumNumerator);

    constructor(
        string memory name_,
        IVotes token_,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumNumerator_
    )
        Governor(name_)
        GovernorSettings(votingDelay_, votingPeriod_, proposalThreshold_)
        GovernorVotes(token_)
        GovernorVotesQuorumFraction(quorumNumerator_)
    {
        if (votingDelay_ < MIN_VOTING_DELAY) revert VotingDelayTooShort(votingDelay_, MIN_VOTING_DELAY);
        if (votingPeriod_ < MIN_VOTING_PERIOD) revert VotingPeriodTooShort(votingPeriod_, MIN_VOTING_PERIOD);
        if (quorumNumerator_ < MIN_QUORUM_NUMERATOR) {
            revert QuorumNumeratorTooLow(quorumNumerator_, MIN_QUORUM_NUMERATOR);
        }
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        IERC20 votesToken = IERC20(address(token()));
        uint256 circulatingSupply = votesToken.totalSupply() - votesToken.balanceOf(BURN_ADDRESS);
        return (circulatingSupply * PROPOSAL_THRESHOLD_BPS) / BPS_DENOM;
    }

    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        IERC20 votesToken = IERC20(address(token()));
        uint256 circulatingSupply = token().getPastTotalSupply(timepoint) - votesToken.balanceOf(BURN_ADDRESS);
        return (circulatingSupply * quorumNumerator(timepoint)) / quorumDenominator();
    }
}
