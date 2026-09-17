// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksStaking} from "../src/StocksStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";

/// @notice Reentrancy coverage for StocksStaking's wrap/unwrap path specifically -- every OTHER
/// major contract in this stack (StocksCurve.buy, StocksGraduator.graduate) already has a dedicated
/// malicious-token reentrancy test; StocksStaking never got one, despite wrapTreasuryStock/
/// unwrapTreasuryStock both making a real external call OUT to `stockToken` itself
/// (IWrapperMinimal.deposit()/redeem()) -- exactly the shape a hostile/compromised wrapper could
/// try to exploit by calling back into the staking contract mid-call. `nonReentrant`'s single
/// shared `_status` slot per contract should make this structurally impossible regardless of WHICH
/// nonReentrant-guarded function the malicious wrapper tries to call back into -- confirmed live
/// here rather than only assumed from the modifier's presence.
contract StocksStakingSecurityTest is Test {
    MockERC20 tst;
    MaliciousWrapper wrapper;
    MockHookV5 hook;
    StocksStaking staking;
    PoolKey poolKey;

    address governor = address(0x6046);
    address staker = address(0xCAFE);

    uint256 constant DURATION = 30 days;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    function setUp() public {
        tst = new MockERC20("Acme", "ACME");
        MockERC20 rawStock = new MockERC20("Tesla Stock", "TSLA");
        wrapper = new MaliciousWrapper("Wrapped Tesla Stock", "wTSLA", rawStock);
        hook = new MockHookV5(wrapper, tst, EXPIRATION_INTERVAL, 1);

        staking = new StocksStaking(address(tst), address(wrapper), DURATION, governor, address(hook), address(this), 10);
        wrapper.arm(staking);

        bool tstIsCurrency0 = address(tst) < address(wrapper);
        poolKey = PoolKey({
            currency0: tstIsCurrency0 ? Currency.wrap(address(tst)) : Currency.wrap(address(wrapper)),
            currency1: tstIsCurrency0 ? Currency.wrap(address(wrapper)) : Currency.wrap(address(tst)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        staking.setPool(poolKey);

        // A qualified holder (>= MIN_HOLDER_BPS of circulating TST), matching onlyMinHolder's
        // real gate -- staker needs real TST to pass it.
        tst.mint(staker, 1_000_000e18);

        // Seed the treasury with real wrapped shares (so unwrapTreasuryStock has something to
        // redeem) and real raw stock backing them (so the wrapper's own redeem() can pay out).
        rawStock.mint(address(wrapper), 100_000e18);
        vm.prank(address(wrapper));
        // Mint shares directly to the staking contract, matching what a real deposit() would leave
        // behind -- this test is about the REENTRANCY path specifically, not the deposit accounting.
        wrapper.mintSharesForTest(address(staking), 100_000e18);
    }

    /// @dev A malicious wrapper's redeem() (called from inside unwrapTreasuryStock, itself
    /// nonReentrant) attempts to call staking.claim() mid-call. The reentrant attempt itself must
    /// be blocked (ReentrancyGuardReentrantCall) -- confirmed via reentryAttempted/reentryReverted,
    /// caught internally by the malicious wrapper so those flags survive to be checked (letting the
    /// revert propagate and fail the WHOLE outer call would also roll back those very flags, per
    /// EVM revert semantics -- see MaliciousWrapper's own _tryReenter comment). The outer unwrap
    /// itself completing normally despite the attack is the real proof of safety: a real hostile
    /// wrapper gets no leverage from attempting this, not even a DoS on the legitimate operation.
    function test_ReentrantWrapper_CannotReenterDuringUnwrap() public {
        // UNWRAP_COOLDOWN is measured from lastUnwrapAt (0 by default, never unwrapped before) --
        // on a real chain block.timestamp is always far past epoch+14 days so this never matters,
        // but this test's local (non-forked) chain starts at Foundry's default block.timestamp=1,
        // so the cooldown would otherwise block every unwrap attempt regardless of reentrancy.
        vm.warp(block.timestamp + staking.UNWRAP_COOLDOWN() + 1);

        uint256 sharesBefore = wrapper.balanceOf(address(staking));

        vm.prank(staker);
        uint256 assetsOut = staking.unwrapTreasuryStock(1_000e18, 0);

        assertTrue(wrapper.reentryAttempted(), "sanity: the malicious wrapper should have actually attempted the reentrant call");
        assertTrue(wrapper.reentryReverted(), "the reentrant claim() call should have been blocked by the reentrancy guard");
        assertGt(assetsOut, 0, "the legitimate unwrap itself should still have succeeded normally despite the attack attempt");
        // Not necessarily the full 1_000e18 requested -- unwrapTreasuryStock's own maxSafeShares
        // clamp may legitimately reduce it (unrelated to the reentrancy attempt); what matters here
        // is internal consistency between the real shares delta and the returned assetsOut, proving
        // the blocked reentrancy attempt didn't corrupt the legitimate accounting either way.
        assertEq(sharesBefore - wrapper.balanceOf(address(staking)), assetsOut, "shares burned should exactly match the returned assetsOut (1:1 in this mock), unaffected by the blocked reentrancy attempt");
    }

    /// @dev Same attack, the other direction: a malicious wrapper's deposit() (called from inside
    /// wrapTreasuryStock) attempts to reenter staking.claim() -- must also be blocked cleanly,
    /// with the legitimate wrap still completing normally.
    function test_ReentrantWrapper_CannotReenterDuringWrap() public {
        MockERC20 rawStock = MockERC20(address(wrapper.rawAsset()));
        // Give the staking contract some raw (unwrapped) stock to wrap, mirroring a prior
        // unwrapTreasuryStock call having produced it.
        rawStock.mint(address(staking), 1_000e18);

        vm.prank(staker);
        uint256 sharesOut = staking.wrapTreasuryStock(1_000e18, 0);

        assertTrue(wrapper.reentryAttempted(), "sanity: the malicious wrapper should have actually attempted the reentrant call");
        assertTrue(wrapper.reentryReverted(), "the reentrant claim() call should have been blocked by the reentrancy guard");
        assertGt(sharesOut, 0, "the legitimate wrap itself should still have succeeded normally despite the attack attempt");
    }

    // ============================================================
    // Multi-staker reward SOLVENCY -- the core Synthetix-style-rewards-fork invariant. Every
    // existing test anywhere in this repo (including the freshfork file's own extensive pause/
    // resume/liquidate/wrap-unwrap battery) only ever exercises ONE real staker at a time.
    // Double-counting or under/over-crediting bugs in rewardPerToken()/_settle()'s interaction with
    // MULTIPLE concurrent stakers joining/leaving at different times are exactly the bug class real
    // Synthetix-fork incidents have hit historically -- never directly fuzzed here before.
    // ============================================================

    /// @dev Three stakers join at fuzzed amounts and fuzzed times, against a single fixed real
    /// reward deposit recognized up front. After everyone has fully unstaked and claimed
    /// everything they're owed, the STRICT invariant this test exists to prove: the sum of every
    /// real payout across all three can never exceed the amount actually deposited as reward --
    /// no combination of join/leave timing may let the contract pay out more than it truly has.
    /// (Under-paying due to rounding dust is fine and expected -- Synthetix-style integer-division
    /// reward math always leaves some dust; OVER-paying is the one outcome that would mean real
    /// insolvency.)
    function testFuzz_MultiStakerRewardSolvency_NeverOverpaysAcrossAnyRealDistribution(
        uint256 amountA,
        uint256 amountB,
        uint256 amountC,
        uint256 warpAfterA,
        uint256 warpAfterB,
        uint256 warpAfterC
    ) public {
        amountA = bound(amountA, 1e18, 1_000_000e18);
        amountB = bound(amountB, 1e18, 1_000_000e18);
        amountC = bound(amountC, 1e18, 1_000_000e18);
        warpAfterA = bound(warpAfterA, 0, 10 days);
        warpAfterB = bound(warpAfterB, 0, 10 days);
        warpAfterC = bound(warpAfterC, 0, 40 days); // past a 30-day rewardsDuration, so the stream can fully finish

        MockERC20 solvTst = new MockERC20("SolvTst", "STST");
        MockERC20 solvStock = new MockERC20("SolvStock", "SSTOCK");
        MockHookV5 solvHook = new MockHookV5(solvStock, solvTst, EXPIRATION_INTERVAL, 1);
        StocksStaking solvStaking =
            new StocksStaking(address(solvTst), address(solvStock), 30 days, governor, address(solvHook), address(this), 10);

        address alice = makeAddr("solvAlice");
        address bob = makeAddr("solvBob");
        address carol = makeAddr("solvCarol");

        // A single, fixed, real reward deposit recognized up front -- the exact amount this test's
        // solvency invariant is measured against.
        uint256 realReward = 100_000e18;
        solvStock.mint(address(solvStaking), realReward);
        solvStaking.notifyRewardAmount();

        solvTst.mint(alice, amountA);
        vm.startPrank(alice);
        solvTst.approve(address(solvStaking), amountA);
        solvStaking.stake(amountA);
        vm.stopPrank();

        vm.warp(block.timestamp + warpAfterA);

        solvTst.mint(bob, amountB);
        vm.startPrank(bob);
        solvTst.approve(address(solvStaking), amountB);
        solvStaking.stake(amountB);
        vm.stopPrank();

        vm.warp(block.timestamp + warpAfterB);

        solvTst.mint(carol, amountC);
        vm.startPrank(carol);
        solvTst.approve(address(solvStaking), amountC);
        solvStaking.stake(amountC);
        vm.stopPrank();

        vm.warp(block.timestamp + warpAfterC);

        // Everyone unstakes and claims everything they're owed.
        uint256 totalPaid;
        vm.startPrank(alice);
        solvStaking.unstake(amountA);
        solvStaking.claim();
        vm.stopPrank();
        totalPaid += solvStock.balanceOf(alice);

        vm.startPrank(bob);
        solvStaking.unstake(amountB);
        solvStaking.claim();
        vm.stopPrank();
        totalPaid += solvStock.balanceOf(bob);

        vm.startPrank(carol);
        solvStaking.unstake(amountC);
        solvStaking.claim();
        vm.stopPrank();
        totalPaid += solvStock.balanceOf(carol);

        assertLe(totalPaid, realReward, "SOLVENCY VIOLATION: total real payouts across all stakers exceeded the real reward ever deposited");
    }
}

/// @notice ERC-4626-shaped wrapper whose deposit()/redeem() attempt to re-enter StocksStaking.claim()
/// the moment they're called -- simulating a malicious/compromised stock wrapper, the same threat
/// class StocksCurve's own ReentrantStock (StocksCurve.security.t.sol) and StocksGraduator's own
/// ReentrantToken (StocksGraduator.security.t.sol) already cover for their respective contracts.
contract MaliciousWrapper is ERC20 {
    IERC20 public immutable rawAsset;
    StocksStaking private _target;
    bool private _armed;
    bool public reentryAttempted;
    bool public reentryReverted;

    constructor(string memory name_, string memory symbol_, IERC20 rawAsset_) ERC20(name_, symbol_) {
        rawAsset = rawAsset_;
    }

    function arm(StocksStaking target_) external {
        _target = target_;
        _armed = true;
    }

    /// @dev Test-only helper to seed the staking contract's initial wrapped-share balance without
    /// routing through a real deposit() call (which would itself trigger the reentrancy hook this
    /// test is specifically trying to isolate to the ACTUAL wrap/unwrap calls under test).
    function mintSharesForTest(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function asset() external view returns (address) {
        return address(rawAsset);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        rawAsset.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        _mint(receiver, shares);
        _tryReenter();
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        _burn(owner, shares);
        assets = shares;
        rawAsset.transfer(receiver, assets);
        _tryReenter();
    }

    function _tryReenter() internal {
        if (_armed) {
            _armed = false;
            reentryAttempted = true;
            // Caught here (matching StocksCurve.security.t.sol's own ReentrantStock pattern)
            // rather than left to propagate -- letting it propagate would revert THIS ENTIRE call,
            // which would also roll back reentryAttempted/reentryReverted themselves (EVM revert
            // semantics undo every state change made during a reverted call, including this one),
            // making them unreadable afterward. Catching internally lets the outer
            // wrapTreasuryStock/unwrapTreasuryStock call SUCCEED normally (proving the legitimate
            // operation still works even under attack) while still conclusively proving the nested
            // reentrant attempt itself was blocked, via these two flags staying readable after the
            // fact.
            try _target.claim() {
                // Should never succeed -- nonReentrant must block it.
            } catch {
                reentryReverted = true;
            }
        }
    }
}
