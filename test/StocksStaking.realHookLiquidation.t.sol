// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Every existing liquidateTreasury test drives StocksStaking against MockHookV5, never
/// the real StocksHook -- meaning the interaction between a real, governance-submitted treasury
/// liquidation TWAMM order and StocksHook's own beforeSwap (which now also does the pre-swap
/// protocol stock skim, and calls executeTWAMMOrders as a side effect on every swap) has never
/// been exercised end to end. This test builds the full real stack, graduates a real curve, funds
/// and starts a real liquidation order through the real hook, then runs a real buy-TST swap that
/// triggers both mechanisms in the same beforeSwap call, and confirms neither interferes with the
/// other.
contract StocksStakingRealHookLiquidationTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;
    uint256 constant GRADUATION_USD_THRESHOLD = 8_000e18;
    uint256 constant MIN_REWARDS_DURATION = 1 hours;
    uint256 constant MAX_REWARDS_DURATION = 365 days;
    uint48 constant VOTING_DELAY = 1 hours;
    uint32 constant VOTING_PERIOD = 1 hours;
    uint256 constant PROPOSAL_THRESHOLD_BPS = 100;
    uint256 constant MIN_HOLDER_BPS = 10;

    IPoolManager poolManager;
    StocksHook hook;
    StocksGraduator graduator;
    StocksLaunchFactory factory;
    TokenMetadataRegistry metadataRegistry;
    PoolSwapTest swapRouter;

    uint256 trustedSignerKey = 0xA11CE;
    address trustedSigner;
    address protocol = address(0xF00D);
    address buyer = address(0xB0B);
    address swapper = address(0xC0FFEE);

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");
        trustedSigner = vm.addr(trustedSignerKey);

        metadataRegistry = new TokenMetadataRegistry();

        address governorFactory = address(new StocksGovernorFactory());
        address curveDeployer = address(new StocksCurveFactory());
        address stakingFactory = address(new StocksStakingFactory());

        uint256 nonceAtStart = vm.getNonce(address(this));
        address predictedGraduator = vm.computeCreateAddress(address(this), nonceAtStart + 1);
        address predictedFactory = vm.computeCreateAddress(address(this), nonceAtStart + 2);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, predictedGraduator, EXPIRATION_INTERVAL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StocksHook).creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(poolManager, predictedGraduator, EXPIRATION_INTERVAL);
        require(address(hook) == hookAddress, "hook address mismatch");

        graduator = new StocksGraduator(poolManager, hook, predictedFactory);
        require(address(graduator) == predictedGraduator, "graduator address mismatch");

        factory = new StocksLaunchFactory(
            trustedSigner,
            protocol,
            address(hook),
            governorFactory,
            stakingFactory,
            curveDeployer,
            address(graduator),
            address(metadataRegistry),
            GRADUATION_USD_THRESHOLD,
            MIN_REWARDS_DURATION,
            MAX_REWARDS_DURATION,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD_BPS,
            MIN_HOLDER_BPS
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        swapRouter = new PoolSwapTest(poolManager);
    }

    function _signAttestation(address stockToken, uint256 price, uint256 priceTimestamp) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(address(factory), stockToken, price, priceTimestamp));
        bytes32 ethSignedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(trustedSignerKey, ethSignedDigest);
        return abi.encodePacked(r, s, v);
    }

    function test_RealTreasuryLiquidationOrder_CoexistsWithRealBuySwapAndItsPreSwapSkim() public {
        address stockToken = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB;

        uint256 price = 700e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory signature = _signAttestation(stockToken, price, priceTimestamp);
        (address token, address curve) =
            factory.createCurve("Real Liquidation Test", "RLT", stockToken, price, priceTimestamp, signature, 30 days, "");

        vm.warp(block.timestamp + 61);
        uint256 buyAmount = 200_000e18;
        deal(stockToken, buyer, buyAmount);
        vm.startPrank(buyer);
        IERC20(stockToken).approve(curve, buyAmount);
        StocksCurve(curve).buy(buyAmount, 0);
        vm.stopPrank();
        StocksCurve(curve).graduate();
        assertTrue(StocksCurve(curve).graduated());

        address stakingAddr = StocksCurve(curve).staking();
        address governorAddr = StocksCurve(curve).governor();
        StocksStaking staking = StocksStaking(stakingAddr);

        // Fund the treasury with real excess stock (simulating accumulated dividends/fees) that
        // has never been recognized as a reward yet -- liquidateTreasury's own floor math treats
        // this as fully safe-to-liquidate excess.
        uint256 treasuryFunding = 5_000e18;
        deal(stockToken, stakingAddr, treasuryFunding);

        // liquidateTreasury is onlyGovernor -- pranking as the real deployed StocksGovernor
        // contract's own address exercises the real hook/TWAMM interaction this test cares about
        // without also re-deriving the full propose/vote/queue/execute governance flow, which is
        // already covered elsewhere.
        vm.prank(governorAddr);
        (uint256 stockCommitted, bytes32 orderId) = staking.liquidateTreasury(2);
        assertGt(stockCommitted, 0, "sanity: a real liquidation order must have actually committed real stock");
        assertTrue(orderId != bytes32(0));

        // Let real time pass so the liquidation order is genuinely mid-fill when the swap below
        // triggers executeTWAMMOrders as a beforeSwap side effect.
        vm.warp(block.timestamp + EXPIRATION_INTERVAL);

        PoolKey memory key = StocksPoolView(StocksCurve(curve).pair()).poolKey();
        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == token;
        bool buyZeroForOne = !tstIsCurrency0; // pay stock, receive TST

        uint256 stockIn = 20_000e18;
        deal(stockToken, swapper, stockIn);
        vm.startPrank(swapper);
        IERC20(stockToken).approve(address(swapRouter), stockIn);

        uint256 protocolStockBefore = IERC20(stockToken).balanceOf(protocol);
        uint256 swapperStockBefore = IERC20(stockToken).balanceOf(swapper);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: buyZeroForOne,
                amountSpecified: -int256(stockIn),
                sqrtPriceLimitX96: buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // The pre-swap skim itself must be completely correct despite a real, concurrently-filling
        // governance liquidation order sharing the same beforeSwap call.
        uint256 stockPaid = swapperStockBefore - IERC20(stockToken).balanceOf(swapper);
        assertEq(stockPaid, stockIn, "swapper must pay exactly stockIn despite a concurrent real liquidation order");
        uint256 expectedProtocolCut = (stockIn * 1000 * 2000) / (10_000 * 10_000);
        assertEq(
            IERC20(stockToken).balanceOf(protocol) - protocolStockBefore,
            expectedProtocolCut,
            "protocol's real cut must be unaffected by a concurrent real liquidation order"
        );

        // The liquidation order itself must still be independently claimable and correct --
        // unaffected by having shared a beforeSwap call with the skim above.
        vm.warp(block.timestamp + EXPIRATION_INTERVAL * 2);
        uint256 burnBefore = IERC20(token).balanceOf(hook.BURN_ADDRESS());
        uint256 tstBurned = staking.claimLiquidatedTst();
        assertGt(tstBurned, 0, "the real liquidation order must have genuinely filled and be claimable");
        assertEq(
            IERC20(token).balanceOf(hook.BURN_ADDRESS()) - burnBefore,
            tstBurned,
            "claimLiquidatedTst must burn exactly what it reports"
        );

        console.log("PASS: real treasury liquidation order coexists correctly with the real pre-swap skim");
        console.log("  stockCommitted:", stockCommitted, "tstBurned:", tstBurned);
    }
}
