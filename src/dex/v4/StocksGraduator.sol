// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {StocksHook} from "./StocksHook.sol";
import {StocksPoolView} from "./StocksPoolView.sol";

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

interface ICurveRegistry {
    function curveOf(address token) external view returns (address);
}

/// @notice Shared singleton that seeds a curve's real Uniswap V4 pool and locks its initial
/// liquidity permanently at graduation.
contract StocksGraduator is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MIN_TST_SEED_SUPPLY_BPS = 100; // 1%

    address public immutable factory;

    IPoolManager public immutable poolManager;
    StocksHook public immutable hook;

    event Graduated(address indexed poolView, address tstToken, address stockToken, uint256 tstAmount, uint256 stockAmount);

    error ZeroAmount();
    error ZeroAddress();
    error NotPoolManager();
    error NoLiquidityMinted();
    error SeedTooSmall();
    error NotCurve();

    constructor(IPoolManager poolManager_, StocksHook hook_, address factory_) {
        if (address(poolManager_) == address(0) || address(hook_) == address(0) || factory_ == address(0)) {
            revert ZeroAddress();
        }
        factory = factory_;
        poolManager = poolManager_;
        hook = hook_;
    }

    /// @param tstAmount / stockAmount -- the exact seed amounts. The caller must `approve` this
    /// contract for at least these amounts of both tokens before calling.
    function graduate(
        address tstToken,
        address stockToken,
        address treasury,
        address protocol,
        uint256 feeBps,
        uint256 tstAmount,
        uint256 stockAmount
    ) external nonReentrant returns (address poolView) {
        if (msg.sender != ICurveRegistry(factory).curveOf(tstToken)) revert NotCurve();
        if (tstAmount == 0 || stockAmount == 0) revert ZeroAmount();
        if (tstAmount * BPS_DENOM < IERC20(tstToken).totalSupply() * MIN_TST_SEED_SUPPLY_BPS) {
            revert SeedTooSmall();
        }
        IERC20(tstToken).safeTransferFrom(msg.sender, address(this), tstAmount);
        IERC20(stockToken).safeTransferFrom(msg.sender, address(this), stockAmount);

        bool tstIsCurrency0 = tstToken < stockToken;
        (Currency c0, Currency c1) = tstIsCurrency0
            ? (Currency.wrap(tstToken), Currency.wrap(stockToken))
            : (Currency.wrap(stockToken), Currency.wrap(tstToken));
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});

        hook.registerPool(key, tstToken, stockToken, treasury, protocol, feeBps);

        (uint256 amount0, uint256 amount1) = tstIsCurrency0 ? (tstAmount, stockAmount) : (stockAmount, tstAmount);
        uint160 sqrtPriceX96 = SafeCast.toUint160(Math.sqrt(FullMath.mulDiv(amount1, 1 << 192, amount0)));
        poolManager.initialize(key, sqrtPriceX96);

        uint128 liquidity = _liquidityForAmounts(sqrtPriceX96, amount0, amount1);
        if (liquidity == 0) revert NoLiquidityMinted();
        poolManager.unlock(abi.encode(key, liquidity));

        poolView = address(new StocksPoolView(hook, key));

        uint256 tstDust = IERC20(tstToken).balanceOf(address(this));
        if (tstDust > 0) IERC20(tstToken).safeTransfer(BURN_ADDRESS, tstDust);
        uint256 stockDust = IERC20(stockToken).balanceOf(address(this));
        if (stockDust > 0) IERC20(stockToken).safeTransfer(treasury, stockDust);

        emit Graduated(poolView, tstToken, stockToken, tstAmount, stockAmount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint128 liquidity) = abi.decode(data, (PoolKey, uint128));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        _settleCurrency(key.currency0, delta.amount0());
        _settleCurrency(key.currency1, delta.amount1());

        return "";
    }

    function _settleCurrency(Currency currency, int128 amount) private {
        if (amount >= 0) return;
        uint256 owed = uint256(uint128(-amount));
        address token = Currency.unwrap(currency);
        poolManager.sync(currency);
        IERC20(token).safeTransfer(address(poolManager), owed);
        poolManager.settle();
    }

    function _liquidityForAmounts(uint160 sqrtRatioX96, uint256 amount0, uint256 amount1)
        private
        pure
        returns (uint128 liquidity)
    {
        uint160 sqrtRatioAX96 = TickMath.MIN_SQRT_PRICE;
        uint160 sqrtRatioBX96 = TickMath.MAX_SQRT_PRICE;

        uint256 liquidity0 = FullMath.mulDiv(
            amount0, FullMath.mulDiv(sqrtRatioX96, sqrtRatioBX96, 1 << 96), sqrtRatioBX96 - sqrtRatioX96
        );
        uint256 liquidity1 = FullMath.mulDiv(amount1, 1 << 96, sqrtRatioX96 - sqrtRatioAX96);
        uint256 result = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        liquidity = SafeCast.toUint128(result);
    }
}
