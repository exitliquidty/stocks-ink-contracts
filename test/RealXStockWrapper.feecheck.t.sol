// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC4626Minimal {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

/// @notice StocksStaking.wrapTreasuryStock/unwrapTreasuryStock are permissionless (gated only by
/// onlyMinHolder, not slippage-immune) on the assumption that the real xStock wrapper charges no
/// real entry/exit fee -- if that assumption is ever wrong, a griefer could bleed the treasury for
/// free by round-tripping. Runs a real deposit+redeem round trip against the real deployed wMSTRx
/// wrapper on a live Ink fork every time this suite runs, as a canary for that specific assumption
/// -- not relying on the wrapper's own preview functions, which could misreport actual behavior.
contract RealXStockWrapperFeeCheckTest is Test {
    IERC4626Minimal constant WRAPPER = IERC4626Minimal(0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB);
    address whale = address(0xFEED);

    function setUp() public {
        vm.createSelectFork("ink");
    }

    function test_RealWrapper_DepositThenImmediateRedeem_NoFeeCharged() public {
        address rawAsset = WRAPPER.asset();
        uint256 depositAmount = 10_000e18;
        deal(rawAsset, whale, depositAmount);

        vm.startPrank(whale);
        IERC20(rawAsset).approve(address(WRAPPER), depositAmount);
        uint256 sharesOut = WRAPPER.deposit(depositAmount, whale);
        console.log("Deposited raw:", depositAmount, "-> shares:", sharesOut);

        uint256 rawBefore = IERC20(rawAsset).balanceOf(whale);
        uint256 assetsOut = WRAPPER.redeem(sharesOut, whale, whale);
        vm.stopPrank();
        console.log("Redeemed shares:", sharesOut, "-> raw:", assetsOut);

        assertEq(IERC20(rawAsset).balanceOf(whale) - rawBefore, assetsOut, "redeem must actually pay out exactly what it reports");

        if (assetsOut < depositAmount) {
            console.log("ROUND-TRIP LOSS (wei):", depositAmount - assetsOut);
        } else if (assetsOut > depositAmount) {
            console.log("ROUND-TRIP GAIN (wei):", assetsOut - depositAmount);
        } else {
            console.log("EXACT ROUND TRIP: no fee detected on this real wrapper, this block.");
        }

        // The actual canary: StocksStaking's permissionless wrap/unwrap posture is only safe if
        // this stays at (or extremely near) zero -- fails loudly if the real wrapper's fee
        // behavior ever changes, rather than silently logging it.
        assertApproxEqRel(assetsOut, depositAmount, 0.0001e18, "real wrapper must not charge a meaningful entry/exit fee");
    }

    /// @dev Repeats the round trip many times in the same block to see whether even a tiny
    /// per-trip loss compounds into something a griefer could exploit for free against the
    /// treasury (StocksStaking's own real caller pattern), or whether it's genuinely zero.
    function test_RealWrapper_RepeatedRoundTrips_NoCompoundingLoss() public {
        address rawAsset = WRAPPER.asset();
        uint256 amount = 5_000e18;
        deal(rawAsset, whale, amount);

        vm.startPrank(whale);
        for (uint256 i; i < 10; i++) {
            uint256 bal = IERC20(rawAsset).balanceOf(whale);
            IERC20(rawAsset).approve(address(WRAPPER), bal);
            uint256 shares = WRAPPER.deposit(bal, whale);
            WRAPPER.redeem(shares, whale, whale);
        }
        vm.stopPrank();

        uint256 finalBal = IERC20(rawAsset).balanceOf(whale);
        console.log("Started with:", amount, "after 10 round trips:", finalBal);
        assertGe(finalBal, amount - 1e12, "10 round trips must not have bled meaningful value on the real wrapper");
    }
}
