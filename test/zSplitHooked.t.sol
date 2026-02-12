// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Fork tests for buildSplitSwapHooked — split swaps including V4 hooked pools.
contract zSplitHookedTest is Test {
    zQuoter quoter;
    uint256 DEADLINE;

    address constant VITALIK = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
    address constant USDC_WHALE = 0x55FE002aefF02F77364de339a1292923A15844B8;

    address constant PNKSTR = 0xc50673EDb3A7b94E8CAD8a7d4E0cD68864E33eDF;
    address constant PNKSTR_HOOK = 0xfAaad5B731F52cDc9746F2414c823eca9B06E844;

    uint256 constant ETH_IN = 0.05 ether;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        quoter = new zQuoter();
        DEADLINE = block.timestamp + 20 minutes;

        vm.deal(VITALIK, 10 ether);

        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(VITALIK, 1000e6);

        vm.prank(VITALIK);
        IERC20(USDC).approve(ZROUTER, type(uint256).max);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ETH → PNKSTR (end-to-end execution)
    // ══════════════════════════════════════════════════════════════════════════

    function testSplitHooked_ETHtoPNKSTR() public {
        uint256 amount = 0.1 ether;

        (zQuoter.Quote[2] memory legs, bytes memory multicall, uint256 msgValue) = quoter.buildSplitSwapHooked(
            VITALIK, address(0), PNKSTR, amount, 100, DEADLINE, 0, 60, PNKSTR_HOOK
        );

        uint256 totalOut = legs[0].amountOut + legs[1].amountOut;
        assertGt(totalOut, 0, "should have output");
        assertGt(multicall.length, 0, "multicall should be non-empty");
        assertEq(msgValue, amount, "ETH input: msgValue should equal swapAmount");

        if (legs[0].amountOut > 0 && legs[1].amountOut > 0) {
            assertEq(
                legs[0].amountIn + legs[1].amountIn, amount, "split inputs should sum to total"
            );
        }

        uint256 pnkBefore = IERC20(PNKSTR).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "multicall should succeed");

        assertGt(IERC20(PNKSTR).balanceOf(VITALIK) - pnkBefore, 0, "should receive PNKSTR");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // PNKSTR → ETH (view-only — execute() limitation for ERC20 input)
    // ══════════════════════════════════════════════════════════════════════════

    function testSplitHooked_PNKSTRtoETH() public {
        // Give Vitalik some PNKSTR and approve router
        uint256 pnkBal = 1000e18;
        deal(PNKSTR, VITALIK, pnkBal);
        vm.prank(VITALIK);
        IERC20(PNKSTR).approve(ZROUTER, type(uint256).max);

        (zQuoter.Quote[2] memory legs, bytes memory multicall, uint256 msgValue) = quoter.buildSplitSwapHooked(
            VITALIK, PNKSTR, address(0), pnkBal, 100, DEADLINE, 0, 60, PNKSTR_HOOK
        );

        uint256 totalOut = legs[0].amountOut + legs[1].amountOut;
        assertGt(totalOut, 0, "should have ETH output quote");
        assertEq(msgValue, 0, "ERC20 input: msgValue should be 0");

        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "multicall should succeed");

        assertGt(VITALIK.balance - ethBefore, 0, "should receive ETH");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Fallback — fake hook, standard venues only
    // ══════════════════════════════════════════════════════════════════════════

    function testSplitHooked_Fallback_NoHookedPool() public {
        address fakeHook = address(0xdead);

        (zQuoter.Quote[2] memory legs, bytes memory multicall, uint256 msgValue) = quoter.buildSplitSwapHooked(
            VITALIK, address(0), USDC, ETH_IN, 50, DEADLINE, 0, 60, fakeHook
        );

        uint256 totalOut = legs[0].amountOut + legs[1].amountOut;
        assertGt(totalOut, 0, "should have output from standard venues");
        assertEq(msgValue, ETH_IN, "ETH input: msgValue should equal swapAmount");

        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "multicall should succeed");

        assertGt(IERC20(USDC).balanceOf(VITALIK) - usdcBefore, 0, "should receive USDC");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Error cases
    // ══════════════════════════════════════════════════════════════════════════

    function testSplitHooked_ZeroAmount_Reverts() public {
        vm.expectRevert(zQuoter.ZeroAmount.selector);
        quoter.buildSplitSwapHooked(
            VITALIK, address(0), PNKSTR, 0, 100, DEADLINE, 0, 60, PNKSTR_HOOK
        );
    }

    receive() external payable {}
}
