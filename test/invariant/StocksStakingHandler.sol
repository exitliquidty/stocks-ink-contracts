// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StocksStaking} from "../../src/StocksStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWrappedStock} from "../mocks/MockWrappedStock.sol";
import {MockHookV5} from "../mocks/MockHookV5.sol";

/// @notice V5 sibling of StockStakingGovernableHandler.sol -- same bounded-random-action pattern
/// Foundry's invariant fuzzer drives, combining ordinary staking with every governor-gated
/// treasury action, now including TWAMM order submission/claiming instead of an instant swap.
/// Uses MockHookV5 instead of a real MemeStockPair/router -- the real order-matching/pricing
/// machinery is already proven against a live PoolManager fork by
/// StocksLaunchFactory.freshfork.t.sol; this handler is about StocksStaking's OWN
/// accounting under arbitrarily long, arbitrarily interleaved random sequences.
contract StocksStakingHandler is Test {
    MockERC20 public tst;
    MockERC20 public rawStock;
    MockWrappedStock public wrapper;
    MockHookV5 public hook;
    StocksStaking public staking;
    address public governor;

    address[3] public actors = [address(0x1111), address(0x2222), address(0x3333)];
    address public qualifiedHolder = address(0x9999);

    uint256 public totalTstMinted;
    uint256 public totalStakedGhost;
    uint256 public totalClaimedGhost;

    constructor(
        MockERC20 _tst,
        MockERC20 _rawStock,
        MockWrappedStock _wrapper,
        MockHookV5 _hook,
        StocksStaking _staking,
        address _governor
    ) {
        tst = _tst;
        rawStock = _rawStock;
        wrapper = _wrapper;
        hook = _hook;
        staking = _staking;
        governor = _governor;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // --- Ordinary staking lifecycle -------------------------------------------------------------

    function stake(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        amount = bound(amount, 1, 1_000_000e18);

        tst.mint(who, amount);
        totalTstMinted += amount;
        vm.startPrank(who);
        tst.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        totalStakedGhost += amount;
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 balance = staking.balanceOf(who);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(who);
        staking.unstake(amount);

        totalStakedGhost -= amount;
    }

    function claim(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 pendingBefore = staking.pendingReward(who);
        if (pendingBefore == 0) return;

        vm.prank(who);
        staking.claim();

        totalClaimedGhost += pendingBefore;
    }

    // --- Organic treasury inflow ------------------------------------------------------------------
    // Real fee-routing (via StocksHook.afterSwap) is already proven by the fork test; this
    // simulates its net effect -- wrapper-share deposits landing on the treasury -- directly, same
    // "real ERC-4626 vault, not a test-only mint" mechanics as the original handler's donateReward.

    function donateReward(uint256 amount) external {
        amount = bound(amount, 1, 500_000e18);
        rawStock.mint(address(this), amount);
        rawStock.approve(address(wrapper), amount);
        wrapper.deposit(amount, address(staking));
        staking.notifyRewardAmount();
    }

    // --- Governor-gated treasury actions ---------------------------------------------------------

    function governorSetPaused(bool paused) external {
        vm.prank(governor);
        staking.setRewardsPaused(paused);
    }

    function governorSetDuration(uint256 durationDays) external {
        durationDays = bound(durationDays, 1, 365);
        vm.prank(governor);
        staking.setRewardsDuration(durationDays * 1 days);
    }

    function governorLiquidate(uint256 durationIntervals) external {
        if (wrapper.balanceOf(address(staking)) == 0) return;
        if (block.timestamp < staking.pendingLiquidationExpiration()) return;
        durationIntervals = bound(durationIntervals, 1, 24);
        // Can still legitimately revert (NothingToLiquidate) if nothing is currently safe to
        // liquidate (everything is vested) -- that's correct behavior, not a precondition this
        // handler should try to predict and dodge in advance.
        vm.prank(governor);
        try staking.liquidateTreasury(durationIntervals) {} catch {}
    }

    // Permissionless, callable by anyone at any time -- exercises repeated partial claims
    // interleaved with everything else, not just a single claim after full expiration.
    function claimLiquidated(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        try staking.claimLiquidatedTst() {} catch {}
    }

    // --- Treasury wrap/unwrap (onlyMinHolder-gated) ----------------------------------------------

    function qualifiedHolderWrap(uint256 rawAmount) external {
        uint256 available = rawStock.balanceOf(address(staking));
        if (available == 0) return;
        rawAmount = bound(rawAmount, 1, available);
        _ensureQualifiedHolder();

        vm.prank(qualifiedHolder);
        try staking.wrapTreasuryStock(rawAmount, 0) {} catch {}
    }

    function qualifiedHolderUnwrap(uint256 shares) external {
        uint256 available = wrapper.balanceOf(address(staking));
        if (available == 0) return;
        if (block.timestamp < staking.lastUnwrapAt() + staking.UNWRAP_COOLDOWN()) return;
        shares = bound(shares, 1, available);
        _ensureQualifiedHolder();

        vm.prank(qualifiedHolder);
        try staking.unwrapTreasuryStock(shares, 0) {} catch {}
    }

    function _ensureQualifiedHolder() internal {
        uint256 circulating = tst.totalSupply() - tst.balanceOf(staking.BURN_ADDRESS());
        uint256 required = (circulating * staking.minHolderBps()) / 10_000 + 1e18;
        uint256 current = tst.balanceOf(qualifiedHolder);
        if (current < required) {
            tst.mint(qualifiedHolder, required - current);
            totalTstMinted += required - current;
        }
    }

    // --- Time -------------------------------------------------------------------------------------

    function warpTime(uint256 secondsForward) external {
        secondsForward = bound(secondsForward, 1, 40 days);
        vm.warp(block.timestamp + secondsForward);
    }
}
