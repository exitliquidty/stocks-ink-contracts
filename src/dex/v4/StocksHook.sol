// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {TWAMM} from "./twamm/vendor/TWAMM.sol";

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

/// @notice Uniswap V4 hook shared by every graduated Stocks.ink pool: per-swap fee routing plus
/// TWAMM order execution for gradual, governance-authorized treasury liquidation.
contract StocksHook is TWAMM {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct LaunchInfo {
        bool registered;
        bool tstIsCurrency0;
        address tstToken;
        address stockToken;
        address treasury;
        address protocol;
        uint256 feeBps;
    }

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_FEE_BPS = 2_000;
    uint256 public constant PROTOCOL_FEE_SHARE_BPS = 2_000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable poolDeployer;

    mapping(PoolId => LaunchInfo) public launches;
    mapping(PoolId => uint256) public price0CumulativeLast;
    mapping(PoolId => uint256) public price1CumulativeLast;
    mapping(PoolId => uint32) public blockTimestampLast;
    mapping(PoolId => uint112) private _reserve0Cached;
    mapping(PoolId => uint112) private _reserve1Cached;

    event PoolRegistered(
        bytes32 indexed poolId, address tstToken, address stockToken, address treasury, address protocol, uint256 feeBps
    );
    event ProtocolStockCutTakenPreSwap(bytes32 indexed poolId, uint256 stockIn, uint256 protocolStockCut);
    event Swap(
        bytes32 indexed poolId,
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 feeToken0,
        uint256 feeToken1,
        address indexed to
    );
    error NotPoolDeployer();
    error ZeroAddress();
    error IdenticalTokens();
    error FeeTooHigh();
    error AlreadyRegistered();
    error InvalidPoolKey();
    error NotRegisteredBeforeInitialize();
    error Overflow();
    error ExactOutputNotSupported();

    modifier onlyPoolDeployer() {
        if (msg.sender != poolDeployer) revert NotPoolDeployer();
        _;
    }

    constructor(IPoolManager poolManager_, address poolDeployer_, uint256 expirationInterval_)
        TWAMM(poolManager_, expirationInterval_, msg.sender)
    {
        if (poolDeployer_ == address(0)) revert ZeroAddress();
        poolDeployer = poolDeployer_;
        renounceOwnership();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Freezes this pool's fee-routing terms forever.
    function registerPool(
        PoolKey calldata key,
        address tstToken_,
        address stockToken_,
        address treasury_,
        address protocol_,
        uint256 feeBps_
    ) external onlyPoolDeployer {
        PoolId poolId = key.toId();
        if (launches[poolId].registered) revert AlreadyRegistered();
        if (
            tstToken_ == address(0) || stockToken_ == address(0) || treasury_ == address(0)
                || protocol_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (tstToken_ == stockToken_) revert IdenticalTokens();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();

        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == tstToken_;
        if (!tstIsCurrency0 && Currency.unwrap(key.currency1) != tstToken_) revert InvalidPoolKey();
        address expectedStock = tstIsCurrency0 ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        if (expectedStock != stockToken_) revert InvalidPoolKey();

        launches[poolId] = LaunchInfo({
            registered: true,
            tstIsCurrency0: tstIsCurrency0,
            tstToken: tstToken_,
            stockToken: stockToken_,
            treasury: treasury_,
            protocol: protocol_,
            feeBps: feeBps_
        });

        blockTimestampLast[poolId] = uint32(block.timestamp % 2 ** 32);

        emit PoolRegistered(PoolId.unwrap(poolId), tstToken_, stockToken_, treasury_, protocol_, feeBps_);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != poolDeployer) revert NotPoolDeployer();
        if (!launches[key.toId()].registered) revert NotRegisteredBeforeInitialize();

        if (key.currency0.isAddressZero()) revert PoolWithNativeNotSupported();
        initialize(_getTWAMM(key));

        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        executeTWAMMOrders(key);

        if (params.amountSpecified > 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        LaunchInfo memory info = launches[poolId];
        if (!info.registered) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool feeIsCurrency0 = !specifiedIsCurrency0;
        bool feeIsTst = feeIsCurrency0 == info.tstIsCurrency0;
        if (!feeIsTst) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 stockIn = uint256(-params.amountSpecified);
        uint256 protocolShareBps = (info.feeBps * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOM;
        uint256 protocolStockCut = (stockIn * protocolShareBps) / BPS_DENOM;
        if (protocolStockCut == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        if (protocolStockCut > uint256(uint128(type(int128).max))) revert Overflow();

        Currency stockCurrency = specifiedIsCurrency0 ? key.currency0 : key.currency1;
        _takeExact(stockCurrency, info.stockToken, protocolStockCut);
        IERC20(info.stockToken).safeTransfer(info.protocol, protocolStockCut);

        emit ProtocolStockCutTakenPreSwap(PoolId.unwrap(poolId), stockIn, protocolStockCut);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(protocolStockCut)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (params.amountSpecified > 0) revert ExactOutputNotSupported();

        PoolId poolId = key.toId();
        _updateAccumulator(poolId);

        LaunchInfo memory info = launches[poolId];
        if (!info.registered) return (IHooks.afterSwap.selector, 0);

        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool feeIsCurrency0 = !specifiedIsCurrency0;
        bool feeIsTst = feeIsCurrency0 == info.tstIsCurrency0;

        uint256 preSwapStockCut;
        if (feeIsTst && params.amountSpecified < 0) {
            uint256 stockIn = uint256(-params.amountSpecified);
            uint256 protocolShareBps = (info.feeBps * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOM;
            preSwapStockCut = (stockIn * protocolShareBps) / BPS_DENOM;
        }

        int128 unspecifiedAmount = feeIsCurrency0 ? delta.amount0() : delta.amount1();
        if (unspecifiedAmount <= 0) {
            _emitSwapEvent(poolId, sender, params, delta, feeIsCurrency0, 0, preSwapStockCut, hookData);
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 effectiveFeeBps =
            feeIsTst ? info.feeBps - (info.feeBps * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOM : info.feeBps;

        uint256 grossOut = uint256(uint128(unspecifiedAmount));
        uint256 feeAmount = (grossOut * effectiveFeeBps) / BPS_DENOM;
        if (feeAmount == 0) {
            _emitSwapEvent(poolId, sender, params, delta, feeIsCurrency0, 0, preSwapStockCut, hookData);
            return (IHooks.afterSwap.selector, 0);
        }

        Currency feeCurrency = feeIsCurrency0 ? key.currency0 : key.currency1;
        address feeCurrencyAddr = Currency.unwrap(feeCurrency);
        _takeExact(feeCurrency, feeCurrencyAddr, feeAmount);

        if (feeIsTst) {
            IERC20(info.tstToken).safeTransfer(BURN_ADDRESS, feeAmount);
        } else {
            uint256 protocolCut = (feeAmount * PROTOCOL_FEE_SHARE_BPS) / BPS_DENOM;
            uint256 remainder = feeAmount - protocolCut;
            if (remainder > 0) {
                IERC20(info.stockToken).safeTransfer(info.treasury, remainder);
                info.treasury.call(abi.encodeWithSignature("notifyRewardAmount()"));
            }
            if (protocolCut > 0) IERC20(info.stockToken).safeTransfer(info.protocol, protocolCut);
        }

        _emitSwapEvent(poolId, sender, params, delta, feeIsCurrency0, feeAmount, preSwapStockCut, hookData);
        return (IHooks.afterSwap.selector, int128(uint128(feeAmount)));
    }

    function _emitSwapEvent(
        PoolId poolId,
        address sender,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bool feeIsCurrency0,
        uint256 feeAmount,
        uint256 preSwapStockCut,
        bytes calldata hookData
    ) private {
        bool specifiedIsCurrency0 = !feeIsCurrency0;
        uint256 inputAmount =
            uint256(uint128(specifiedIsCurrency0 ? -delta.amount0() : -delta.amount1())) + preSwapStockCut;
        int128 grossOutRaw = feeIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 grossOut = grossOutRaw > 0 ? uint256(uint128(grossOutRaw)) : 0;
        uint256 netOut = grossOut > feeAmount ? grossOut - feeAmount : 0;

        address to = hookData.length == 32 ? abi.decode(hookData, (address)) : sender;

        emit Swap(
            PoolId.unwrap(poolId),
            sender,
            specifiedIsCurrency0 ? inputAmount : 0,
            specifiedIsCurrency0 ? 0 : inputAmount,
            feeIsCurrency0 ? netOut : 0,
            feeIsCurrency0 ? 0 : netOut,
            feeIsCurrency0 ? feeAmount : preSwapStockCut,
            feeIsCurrency0 ? preSwapStockCut : feeAmount,
            to
        );
    }

    function _takeExact(Currency currency, address token, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        poolManager.take(currency, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert Overflow();
    }

    function getReserves(PoolId poolId) public view returns (uint112 reserve0, uint112 reserve1, uint32 lastUpdate) {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);
        uint256 r0 = sqrtPriceX96 == 0 ? 0 : FullMath.mulDiv(uint256(liquidity), 1 << 96, sqrtPriceX96);
        uint256 r1 = FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, 1 << 96);
        if (r0 > type(uint112).max || r1 > type(uint112).max) revert Overflow();
        reserve0 = uint112(r0);
        reserve1 = uint112(r1);
        lastUpdate = blockTimestampLast[poolId];
    }

    function _updateAccumulator(PoolId poolId) private {
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast[poolId];
        }
        uint112 oldReserve0 = _reserve0Cached[poolId];
        uint112 oldReserve1 = _reserve1Cached[poolId];
        if (timeElapsed > 0 && blockTimestampLast[poolId] != 0 && oldReserve0 != 0 && oldReserve1 != 0) {
            unchecked {
                price0CumulativeLast[poolId] += (uint256(oldReserve1) << 112) / oldReserve0 * timeElapsed;
                price1CumulativeLast[poolId] += (uint256(oldReserve0) << 112) / oldReserve1 * timeElapsed;
            }
        }
        (uint112 newReserve0, uint112 newReserve1,) = getReserves(poolId);
        _reserve0Cached[poolId] = newReserve0;
        _reserve1Cached[poolId] = newReserve1;
        blockTimestampLast[poolId] = blockTimestamp;
    }

    function tstToken(PoolId poolId) external view returns (address) {
        return launches[poolId].tstToken;
    }

    function stockToken(PoolId poolId) external view returns (address) {
        return launches[poolId].stockToken;
    }

    function treasury(PoolId poolId) external view returns (address) {
        return launches[poolId].treasury;
    }

    function feeBps(PoolId poolId) external view returns (uint256) {
        return launches[poolId].feeBps;
    }
}
