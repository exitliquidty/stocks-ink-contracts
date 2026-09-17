// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {TSTToken} from "../TSTToken.sol";
import {StocksStaking} from "../StocksStaking.sol";
import {StocksStakingFactory} from "../StocksStakingFactory.sol";
import {StocksGraduator} from "../dex/v4/StocksGraduator.sol";
import {StocksPoolView} from "../dex/v4/StocksPoolView.sol";
import {StocksGovernorFactory} from "../governance/StocksGovernorFactory.sol";

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

interface IGovernableFactoryV5 {
    function protocol() external view returns (address);
    function hook() external view returns (address);
    function governorFactory() external view returns (address);
    function stakingFactory() external view returns (address);
    function v4Graduator() external view returns (address);
    function votingDelay() external view returns (uint48);
    function votingPeriod() external view returns (uint32);
    function proposalThresholdBps() external view returns (uint256);
    function minHolderBps() external view returns (uint256);
}

/// @notice Bonding-curve launch contract for a single tokenized-equity pool.
contract StocksCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    TSTToken public immutable tstToken;
    IERC20 public immutable stockToken;
    address public immutable factory;
    uint256 public immutable launchTimestamp;
    uint256 public immutable graduationStockTarget;
    uint256 public immutable virtualStockReserve;
    uint256 public immutable rewardsDuration;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant CURVE_SUPPLY = 800_000_000e18;
    uint256 public constant RESERVED_SUPPLY = TOTAL_SUPPLY - CURVE_SUPPLY;
    uint256 public constant VIRTUAL_RESERVE_DIVISOR = 3;
    uint256 public constant SNIPE_WINDOW = 60 seconds;
    uint256 public constant MAX_SNIPE_BUY_BPS = 500;
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant SOLDOUT_THRESHOLD_BPS = 9_900;
    uint256 public constant FEE_BPS = 1000;
    uint256 public constant PRICE_MAX_AGE = 5 minutes;
    uint256 public constant PRICE_DECIMALS = 1e18;

    uint256 public constant QUORUM_NUMERATOR = 10;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable trustedSigner;

    uint256 public realStockCollected;
    uint256 public tokensSold;
    bool public graduated;
    address public pair;
    address public staking;
    address public governor;

    event Bought(address indexed buyer, uint256 stockIn, uint256 tstOut);
    event Sold(address indexed seller, uint256 tstIn, uint256 stockOut);
    event Graduated(
        address indexed pair, address indexed staking, address indexed governor, uint256 stockCollected, uint256 tstReserved
    );

    error AlreadyGraduated();
    error ZeroAmount();
    error ZeroAddress();
    error SlippageExceeded();
    error SnipeCapExceeded();
    error CurveSoldOut();
    error InsufficientTstSupply();
    error NotReady();
    error InvalidPrice();
    error InvalidSignature();
    error StalePrice();
    error InvalidRewardsDuration();

    constructor(
        address _tstToken,
        address _stockToken,
        address _trustedSigner,
        uint256 price,
        uint256 priceTimestamp,
        bytes memory signature,
        uint256 _rewardsDuration,
        address _factory,
        uint256 _graduationUsdThreshold,
        uint256 _minRewardsDuration,
        uint256 _maxRewardsDuration
    ) {
        if (_tstToken == address(0) || _stockToken == address(0) || _trustedSigner == address(0) || _factory == address(0)) {
            revert ZeroAddress();
        }
        if (_rewardsDuration < _minRewardsDuration || _rewardsDuration > _maxRewardsDuration) {
            revert InvalidRewardsDuration();
        }

        tstToken = TSTToken(_tstToken);
        stockToken = IERC20(_stockToken);
        trustedSigner = _trustedSigner;
        factory = _factory;
        launchTimestamp = block.timestamp;
        rewardsDuration = _rewardsDuration;

        if (price == 0) revert InvalidPrice();
        if (priceTimestamp > block.timestamp || block.timestamp - priceTimestamp > PRICE_MAX_AGE) {
            revert StalePrice();
        }

        bytes32 attestationHash = keccak256(abi.encodePacked(factory, _stockToken, price, priceTimestamp));
        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(attestationHash), signature);
        if (signer != _trustedSigner) revert InvalidSignature();

        graduationStockTarget = (_graduationUsdThreshold * PRICE_DECIMALS) / price;
        if (graduationStockTarget == 0) revert InvalidPrice();
        virtualStockReserve = graduationStockTarget / VIRTUAL_RESERVE_DIVISOR;
    }

    function quoteBuy(uint256 stockIn) public view returns (uint256 tstOut) {
        if (stockIn == 0) return 0;
        uint256 remaining = CURVE_SUPPLY - tokensSold;
        uint256 oldVirtualStock = virtualStockReserve + realStockCollected;
        uint256 newVirtualStock = oldVirtualStock + stockIn;
        tstOut = remaining - Math.ceilDiv(oldVirtualStock * remaining, newVirtualStock);
    }

    function quoteSell(uint256 tstIn) public view returns (uint256 stockOut) {
        if (tstIn == 0) return 0;
        uint256 remaining = CURVE_SUPPLY - tokensSold;
        uint256 oldVirtualStock = virtualStockReserve + realStockCollected;
        uint256 newRemaining = remaining + tstIn;
        stockOut = oldVirtualStock - Math.ceilDiv(oldVirtualStock * remaining, newRemaining);
    }

    function buy(uint256 stockIn, uint256 minTstOut) external nonReentrant returns (uint256 tstOut) {
        if (graduated) revert AlreadyGraduated();
        if (stockIn == 0) revert ZeroAmount();

        uint256 balanceBefore = stockToken.balanceOf(address(this));
        stockToken.safeTransferFrom(msg.sender, address(this), stockIn);
        uint256 actualStockIn = stockToken.balanceOf(address(this)) - balanceBefore;
        if (actualStockIn == 0) revert ZeroAmount();

        tstOut = quoteBuy(actualStockIn);
        if (tstOut == 0) revert ZeroAmount();
        if (tokensSold + tstOut > CURVE_SUPPLY) revert CurveSoldOut();
        if (tstOut < minTstOut) revert SlippageExceeded();

        if (block.timestamp < launchTimestamp + SNIPE_WINDOW) {
            if (tstOut > (CURVE_SUPPLY * MAX_SNIPE_BUY_BPS) / BPS_DENOM) revert SnipeCapExceeded();
        }

        realStockCollected += actualStockIn;
        tokensSold += tstOut;

        IERC20(address(tstToken)).safeTransfer(msg.sender, tstOut);

        emit Bought(msg.sender, actualStockIn, tstOut);
    }

    function sell(uint256 tstIn, uint256 minStockOut) external nonReentrant returns (uint256 stockOut) {
        if (graduated) revert AlreadyGraduated();
        if (tstIn == 0) revert ZeroAmount();
        if (tstIn > tokensSold) revert InsufficientTstSupply();

        stockOut = quoteSell(tstIn);
        if (stockOut == 0) revert ZeroAmount();
        if (stockOut < minStockOut) revert SlippageExceeded();

        realStockCollected -= stockOut;
        tokensSold -= tstIn;

        IERC20(address(tstToken)).safeTransferFrom(msg.sender, address(this), tstIn);
        stockToken.safeTransfer(msg.sender, stockOut);

        emit Sold(msg.sender, tstIn, stockOut);
    }

    function graduate() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        bool targetReached = realStockCollected >= graduationStockTarget;
        bool soldOut = tokensSold >= (CURVE_SUPPLY * SOLDOUT_THRESHOLD_BPS) / BPS_DENOM;
        if (!targetReached && !soldOut) revert NotReady();
        _graduate();
    }

    /// @notice Clears any TST mistakenly sent directly to this contract (outside buy()/sell()) by
    /// burning it. Stock is deliberately left untouched here: _graduate() always seeds the real
    /// pool from this contract's full live stock balance, not just realStockCollected, so any
    /// stray stock is automatically captured at graduation with no separate handling needed.
    function skim() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        uint256 tstExpected = TOTAL_SUPPLY - tokensSold;
        uint256 tstExcess = IERC20(address(tstToken)).balanceOf(address(this)) - tstExpected;
        if (tstExcess > 0) IERC20(address(tstToken)).safeTransfer(BURN_ADDRESS, tstExcess);
    }

    function _graduate() internal {
        graduated = true;

        IGovernableFactoryV5 f = IGovernableFactoryV5(factory);

        address gov = StocksGovernorFactory(f.governorFactory()).deploy(
            string.concat(tstToken.name(), " Governor"),
            IVotes(address(tstToken)),
            f.votingDelay(),
            f.votingPeriod(),
            (TOTAL_SUPPLY * f.proposalThresholdBps()) / BPS_DENOM,
            QUORUM_NUMERATOR
        );

        address stakingAddr = StocksStakingFactory(f.stakingFactory()).deploy(
            address(tstToken), address(stockToken), rewardsDuration, gov, f.hook(), f.minHolderBps()
        );

        uint256 tstToSeed = IERC20(address(tstToken)).balanceOf(address(this));
        uint256 stockToSeed = stockToken.balanceOf(address(this));

        address graduator = f.v4Graduator();
        IERC20(address(tstToken)).forceApprove(graduator, tstToSeed);
        stockToken.forceApprove(graduator, stockToSeed);

        address poolView = StocksGraduator(graduator).graduate(
            address(tstToken), address(stockToken), stakingAddr, f.protocol(), FEE_BPS, tstToSeed, stockToSeed
        );

        StocksStaking(stakingAddr).setPool(StocksPoolView(poolView).poolKey());

        pair = poolView;
        staking = stakingAddr;
        governor = gov;

        emit Graduated(poolView, stakingAddr, gov, stockToSeed, tstToSeed);
    }
}
