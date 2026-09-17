// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

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

interface IStocksHookMinimal {
    struct SubmitOrderParams {
        PoolKey key;
        bool zeroForOne;
        uint256 duration;
        uint256 amountIn;
    }

    struct OrderKey {
        address owner;
        uint160 expiration;
        bool zeroForOne;
    }

    struct SyncParams {
        PoolKey key;
        OrderKey orderKey;
    }

    struct Order {
        uint256 sellRate;
        uint256 earningsFactorLast;
    }

    function expirationInterval() external view returns (uint256);
    function submitOrder(SubmitOrderParams calldata params)
        external
        returns (bytes32 orderId, OrderKey memory orderKey);
    function sync(SyncParams calldata params) external returns (uint256 tokens0OwedDelta, uint256 tokens1OwedDelta);
    function claimTokensByPoolKey(PoolKey calldata key)
        external
        returns (uint256 tokens0Claimed, uint256 tokens1Claimed);
    function getOrder(PoolKey calldata key, OrderKey calldata orderKey) external view returns (Order memory);
}

interface IWrapperMinimal {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

/// @notice Per-pool staking/treasury contract: reward streaming, governance-gated treasury
/// liquidation via TWAMM, and dividend wrap/unwrap.
contract StocksStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    IERC20 public immutable tstToken;
    IERC20 public immutable stockToken;
    uint256 public rewardsDuration;

    address public immutable governor;
    address public immutable hook;
    address public immutable curve;

    PoolKey public poolKey;
    bool public stockIsToken0;
    bool private _poolSet;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_REWARDS_DURATION = 1 hours;
    uint256 private constant BPS_DENOM = 10_000;

    uint256 public constant MIN_GOVERNABLE_REWARDS_DURATION = 1 days;
    uint256 public constant MAX_GOVERNABLE_REWARDS_DURATION = 365 days;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant UNWRAP_COOLDOWN = 14 days;

    uint256 public immutable minHolderBps;

    uint160 public pendingLiquidationExpiration;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public lastNotifiedBalance;

    bool public rewardsPaused;
    uint256 public pausedAt;
    uint256 public totalRewardsAdded;
    uint256 public totalRewardsClaimed;

    uint256 public frozenRewardsTotal;
    uint256 public sumBalanceTimesPaid;

    uint256 public lastUnwrapAt;

    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event RewardAdded(uint256 reward);
    event RewardsPausedSet(bool paused);
    event RewardsDurationSet(uint256 oldDuration, uint256 newDuration);
    event TreasuryLiquidationStarted(uint256 stockCommitted, bytes32 orderId, uint256 duration);
    event TreasuryLiquidationClaimed(uint256 tstBurned);
    event TreasuryStockUnwrapped(uint256 shares, uint256 assetsOut);
    event TreasuryStockWrapped(uint256 rawAmount, uint256 sharesOut);
    event PoolSet(bytes32 indexed poolId);

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientStake();
    error RewardsDurationTooShort();
    error NotGovernor();
    error NotCurve();
    error PoolAlreadySet();
    error PoolNotSet();
    error NothingToLiquidate();
    error InsufficientOutput();
    error NothingSafeToUnwrap();
    error UnwrapOnCooldown();
    error InsufficientHolding();
    error LiquidationInProgress();
    error InvalidGovernableRewardsDuration();
    error InvalidMinHolderBps();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    modifier onlyMinHolder() {
        uint256 circulatingSupply = tstToken.totalSupply() - tstToken.balanceOf(BURN_ADDRESS);
        if (tstToken.balanceOf(msg.sender) * BPS_DENOM < circulatingSupply * minHolderBps) revert InsufficientHolding();
        _;
    }

    constructor(
        address _tstToken,
        address _stockToken,
        uint256 _rewardsDuration,
        address _governor,
        address _hook,
        address _curve,
        uint256 _minHolderBps
    ) {
        if (
            _tstToken == address(0) || _stockToken == address(0) || _governor == address(0)
                || _hook == address(0) || _curve == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_rewardsDuration < MIN_REWARDS_DURATION) revert RewardsDurationTooShort();
        if (_minHolderBps > BPS_DENOM) revert InvalidMinHolderBps();
        tstToken = IERC20(_tstToken);
        stockToken = IERC20(_stockToken);
        rewardsDuration = _rewardsDuration;
        governor = _governor;
        hook = _hook;
        curve = _curve;
        minHolderBps = _minHolderBps;
    }

    function setPool(PoolKey calldata key_) external {
        if (msg.sender != curve) revert NotCurve();
        if (_poolSet) revert PoolAlreadySet();
        _poolSet = true;
        poolKey = key_;
        stockIsToken0 = Currency.unwrap(key_.currency0) == address(stockToken);
        emit PoolSet(PoolId.unwrap(key_.toId()));
    }

    function _rewardClockNow() internal view returns (uint256) {
        return rewardsPaused ? pausedAt : block.timestamp;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        uint256 nowForRewards = _rewardClockNow();
        return nowForRewards < periodFinish ? nowForRewards : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalStaked;
    }

    function pendingReward(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION
            + rewards[account];
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _notifyReward();
        _settle(msg.sender);

        sumBalanceTimesPaid += amount * userRewardPerTokenPaid[msg.sender];
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        tstToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientStake();
        _notifyReward();
        _settle(msg.sender);

        sumBalanceTimesPaid -= amount * userRewardPerTokenPaid[msg.sender];
        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        tstToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant {
        _notifyReward();
        _settle(msg.sender);

        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            frozenRewardsTotal -= reward;
            lastNotifiedBalance -= reward;
            totalRewardsClaimed += reward;
            stockToken.safeTransfer(msg.sender, reward);
            emit Claimed(msg.sender, reward);
        }
    }

    function notifyRewardAmount() external {
        _notifyReward();
    }

    /// @notice Governor-gated pause/resume of reward distribution.
    function setRewardsPaused(bool paused) external onlyGovernor {
        if (paused == rewardsPaused) return;
        if (paused) {
            _notifyReward();
            rewardsPaused = true;
            pausedAt = lastUpdateTime;
        } else {
            uint256 pauseDuration = block.timestamp - pausedAt;
            if (periodFinish > pausedAt) {
                periodFinish += pauseDuration;
                lastUpdateTime += pauseDuration;
            }
            rewardsPaused = false;
            pausedAt = 0;
            _notifyReward();
        }
        emit RewardsPausedSet(paused);
    }

    /// @notice Governor-gated: changes rewardsDuration going forward.
    function setRewardsDuration(uint256 newDuration) external onlyGovernor {
        if (
            newDuration < MIN_GOVERNABLE_REWARDS_DURATION || newDuration > MAX_GOVERNABLE_REWARDS_DURATION
                || newDuration % 1 days != 0
        ) {
            revert InvalidGovernableRewardsDuration();
        }
        emit RewardsDurationSet(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
    }

    /// @notice Governor-gated: submits one TWAMM sell order for the currently-safe-to-liquidate
    /// stockToken balance, executed gradually over `durationIntervals * hook.expirationInterval()`.
    function liquidateTreasury(uint256 durationIntervals)
        external
        nonReentrant
        onlyGovernor
        returns (uint256 stockCommitted, bytes32 orderId)
    {
        if (!_poolSet) revert PoolNotSet();
        if (durationIntervals == 0) revert ZeroAmount();
        if (block.timestamp < pendingLiquidationExpiration) revert LiquidationInProgress();
        if (pendingLiquidationExpiration != 0) {
            IStocksHookMinimal.OrderKey memory oldOrderKey = IStocksHookMinimal.OrderKey({
                owner: address(this),
                expiration: pendingLiquidationExpiration,
                zeroForOne: stockIsToken0
            });
            if (IStocksHookMinimal(hook).getOrder(poolKey, oldOrderKey).sellRate != 0) {
                _claimLiquidatedTst();
            }
        }
        _notifyReward();

        uint256 balance = stockToken.balanceOf(address(this));
        if (balance == 0) revert NothingToLiquidate();

        uint256 remaining = _rewardClockNow() < periodFinish ? periodFinish - _rewardClockNow() : 0;
        uint256 vestedButUnclaimed =
            (rewardPerTokenStored * totalStaked - sumBalanceTimesPaid) / PRECISION + frozenRewardsTotal;
        stockCommitted = balance > vestedButUnclaimed ? balance - vestedButUnclaimed : 0;
        if (stockCommitted == 0) revert NothingToLiquidate();

        uint256 duration = IStocksHookMinimal(hook).expirationInterval() * durationIntervals;
        stockToken.forceApprove(hook, stockCommitted);
        IStocksHookMinimal.OrderKey memory orderKey;
        (orderId, orderKey) = IStocksHookMinimal(hook).submitOrder(
            IStocksHookMinimal.SubmitOrderParams({
                key: poolKey,
                zeroForOne: stockIsToken0,
                duration: duration,
                amountIn: stockCommitted
            })
        );
        pendingLiquidationExpiration = orderKey.expiration;

        lastNotifiedBalance = balance - stockCommitted;

        if (remaining > 0) {
            uint256 outstanding = remaining * rewardRate;
            uint256 reduction = stockCommitted < outstanding ? stockCommitted : outstanding;
            rewardRate = (outstanding - reduction) / remaining;
        }

        _notifyReward();

        emit TreasuryLiquidationStarted(stockCommitted, orderId, duration);
    }

    /// @notice Claims whatever the outstanding liquidation order has earned so far and burns it.
    /// Permissionless and callable repeatedly while the order is still filling.
    function claimLiquidatedTst() external nonReentrant returns (uint256 tstBurned) {
        tstBurned = _claimLiquidatedTst();
    }

    function _claimLiquidatedTst() internal returns (uint256 tstBurned) {
        IStocksHookMinimal.OrderKey memory orderKey = IStocksHookMinimal.OrderKey({
            owner: address(this),
            expiration: pendingLiquidationExpiration,
            zeroForOne: stockIsToken0
        });
        IStocksHookMinimal(hook).sync(
            IStocksHookMinimal.SyncParams({key: poolKey, orderKey: orderKey})
        );
        (uint256 tokens0, uint256 tokens1) = IStocksHookMinimal(hook).claimTokensByPoolKey(poolKey);
        tstBurned = stockIsToken0 ? tokens1 : tokens0;
        if (tstBurned > 0) tstToken.safeTransfer(BURN_ADDRESS, tstBurned);

        emit TreasuryLiquidationClaimed(tstBurned);
    }

    /// @notice Redeems `shares` of this contract's wrapped stock holdings into the raw underlying
    /// xStock, at today's exchange rate. Stock-paired pools only.
    function unwrapTreasuryStock(uint256 shares, uint256 minAssetsOut)
        external
        nonReentrant
        onlyMinHolder
        returns (uint256 assetsOut)
    {
        if (block.timestamp < lastUnwrapAt + UNWRAP_COOLDOWN) revert UnwrapOnCooldown();
        _notifyReward();
        lastUnwrapAt = block.timestamp;

        uint256 currentWrapped = stockToken.balanceOf(address(this));
        uint256 remaining = _rewardClockNow() < periodFinish ? periodFinish - _rewardClockNow() : 0;
        uint256 outstandingObligation = (rewardPerTokenStored * totalStaked - sumBalanceTimesPaid) / PRECISION
            + frozenRewardsTotal + remaining * rewardRate;
        uint256 maxSafeShares = currentWrapped > outstandingObligation ? currentWrapped - outstandingObligation : 0;
        if (shares > maxSafeShares) shares = maxSafeShares;
        if (shares == 0) revert NothingSafeToUnwrap();

        assetsOut = IWrapperMinimal(address(stockToken)).redeem(shares, address(this), address(this));
        if (assetsOut < minAssetsOut) revert InsufficientOutput();
        lastNotifiedBalance = stockToken.balanceOf(address(this));
        emit TreasuryStockUnwrapped(shares, assetsOut);
    }

    /// @notice Wraps this contract's held raw xStock back into the wrapper, at today's exchange rate.
    function wrapTreasuryStock(uint256 rawAmount, uint256 minSharesOut)
        external
        nonReentrant
        onlyMinHolder
        returns (uint256 sharesOut)
    {
        IERC20 rawAsset = IERC20(IWrapperMinimal(address(stockToken)).asset());
        rawAsset.forceApprove(address(stockToken), rawAmount);
        sharesOut = IWrapperMinimal(address(stockToken)).deposit(rawAmount, address(this));
        if (sharesOut < minSharesOut) revert InsufficientOutput();
        emit TreasuryStockWrapped(rawAmount, sharesOut);
    }

    function _notifyReward() internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (rewardsPaused) {
            return;
        }

        uint256 currentBalance = stockToken.balanceOf(address(this));
        if (currentBalance <= lastNotifiedBalance) return;
        uint256 reward = currentBalance - lastNotifiedBalance;
        lastNotifiedBalance = currentBalance;

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
            periodFinish = block.timestamp + rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            rewardRate += reward / remaining;
        }
        lastUpdateTime = block.timestamp;
        totalRewardsAdded += reward;
        emit RewardAdded(reward);
    }

    function _settle(address account) internal {
        uint256 newPending = pendingReward(account);
        frozenRewardsTotal = frozenRewardsTotal + newPending - rewards[account];
        rewards[account] = newPending;
        sumBalanceTimesPaid =
            sumBalanceTimesPaid + balanceOf[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account]);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}
