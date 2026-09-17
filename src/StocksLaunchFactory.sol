// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TSTToken} from "./TSTToken.sol";
import {StocksCurveFactory} from "./curve/StocksCurveFactory.sol";
import {TokenMetadataRegistry} from "./TokenMetadataRegistry.sol";

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

/// @notice Top-level entry point for launching a new tokenized-equity pool.
contract StocksLaunchFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    uint48 public constant MIN_VOTING_DELAY = 1 hours;
    uint32 public constant MIN_VOTING_PERIOD = 1 hours;
    uint256 public constant MIN_STAKING_REWARDS_DURATION = 1 hours;

    address public immutable trustedSigner;
    address public immutable protocol;
    address public immutable hook;
    address public immutable governorFactory;
    address public immutable stakingFactory;
    address public immutable curveDeployer;
    address public immutable v4Graduator;
    address public immutable metadataRegistry;

    uint256 public immutable graduationUsdThreshold;
    uint256 public immutable minRewardsDuration;
    uint256 public immutable maxRewardsDuration;
    uint48 public immutable votingDelay;
    uint32 public immutable votingPeriod;
    uint256 public immutable proposalThresholdBps;
    uint256 public immutable minHolderBps;

    mapping(bytes32 => bool) public usedAttestations;
    mapping(address token => address curve) public curveOf;

    event CurveLaunched(address indexed token, address indexed curve, address stockToken, address deployer);

    error ZeroAddress();
    error InvalidRewardsDuration();
    error AttestationAlreadyUsed();
    error InvalidVotingDelay();
    error InvalidVotingPeriod();

    constructor(
        address _trustedSigner,
        address _protocol,
        address _hook,
        address _governorFactory,
        address _stakingFactory,
        address _curveDeployer,
        address _v4Graduator,
        address _metadataRegistry,
        uint256 _graduationUsdThreshold,
        uint256 _minRewardsDuration,
        uint256 _maxRewardsDuration,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThresholdBps,
        uint256 _minHolderBps
    ) {
        if (
            _trustedSigner == address(0) || _protocol == address(0) || _hook == address(0)
                || _governorFactory == address(0) || _stakingFactory == address(0) || _curveDeployer == address(0)
                || _v4Graduator == address(0) || _metadataRegistry == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_minRewardsDuration > _maxRewardsDuration) revert InvalidRewardsDuration();
        if (_minRewardsDuration < MIN_STAKING_REWARDS_DURATION) revert InvalidRewardsDuration();

        if (_votingDelay < MIN_VOTING_DELAY) revert InvalidVotingDelay();
        if (_votingPeriod < MIN_VOTING_PERIOD) revert InvalidVotingPeriod();

        trustedSigner = _trustedSigner;
        protocol = _protocol;
        hook = _hook;
        governorFactory = _governorFactory;
        stakingFactory = _stakingFactory;
        curveDeployer = _curveDeployer;
        v4Graduator = _v4Graduator;
        metadataRegistry = _metadataRegistry;
        graduationUsdThreshold = _graduationUsdThreshold;
        minRewardsDuration = _minRewardsDuration;
        maxRewardsDuration = _maxRewardsDuration;
        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;
        proposalThresholdBps = _proposalThresholdBps;
        minHolderBps = _minHolderBps;
    }

    /// @param name Token name, e.g. "Acme"
    /// @param symbol Token symbol, e.g. "ACME"
    /// @param stockToken The xStock (or its ERC-4626 wrapper) this launch will pair against once graduated
    /// @param price xStocks price for stockToken in 18-decimal fixed-point USD
    /// @param priceTimestamp Unix seconds when price was fetched
    /// @param signature Signature over keccak256(abi.encodePacked(factory, stockToken, price, priceTimestamp))
    /// @param rewardsDuration How long the staking reward stream runs, in seconds
    /// @param metadataURI Off-chain metadata (image/description/socials, pinned to IPFS). Pass an empty string for no on-chain metadata.
    function createCurve(
        string calldata name,
        string calldata symbol,
        address stockToken,
        uint256 price,
        uint256 priceTimestamp,
        bytes calldata signature,
        uint256 rewardsDuration,
        string calldata metadataURI
    ) external nonReentrant returns (address token, address curve) {
        if (rewardsDuration < minRewardsDuration || rewardsDuration > maxRewardsDuration) {
            revert InvalidRewardsDuration();
        }

        bytes32 attestationId = keccak256(abi.encodePacked(stockToken, price, priceTimestamp, signature));
        if (usedAttestations[attestationId]) revert AttestationAlreadyUsed();
        usedAttestations[attestationId] = true;

        TSTToken tst = new TSTToken(name, symbol, TOTAL_SUPPLY, address(this));
        address newCurve = StocksCurveFactory(curveDeployer).deploy(
            address(tst),
            stockToken,
            trustedSigner,
            price,
            priceTimestamp,
            signature,
            rewardsDuration,
            graduationUsdThreshold,
            minRewardsDuration,
            maxRewardsDuration
        );

        IERC20(address(tst)).safeTransfer(newCurve, TOTAL_SUPPLY);

        token = address(tst);
        curve = newCurve;

        curveOf[token] = newCurve;

        if (bytes(metadataURI).length != 0) {
            TokenMetadataRegistry(metadataRegistry).setMetadataURI(token, metadataURI);
        }

        emit CurveLaunched(token, curve, stockToken, msg.sender);
    }
}
