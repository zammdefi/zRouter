// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Diagnostic tests for V4 hooked pool swaps (ETH → PNKSTR).
///         Isolates each step: quoteV4, buildSplitSwapHooked, buildBestSwap,
///         and actual execution via the deployed zRouter on a mainnet fork.
contract zV4DebugTest is Test {
    zQuoter quoter;
    uint256 DEADLINE;

    address constant VITALIK = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
    address constant PNKSTR = 0xc50673EDb3A7b94E8CAD8a7d4E0cD68864E33eDF;
    address constant PNKSTR_HOOK = 0xfAaad5B731F52cDc9746F2414c823eca9B06E844;
    address constant V4_ROUTER = 0x00000000000044a361Ae3cAc094c9D1b14Eece97;
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));
        quoter = new zQuoter();
        DEADLINE = block.timestamp + 20 minutes;
        vm.deal(VITALIK, 10 ether);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Step 1: Can zQuoter.quoteV4 return a valid quote?
    // ══════════════════════════════════════════════════════════════════════════

    function testDebug_quoteV4() public {
        (uint256 amountIn, uint256 amountOut) =
            quoter.quoteV4(false, address(0), PNKSTR, 0, 60, PNKSTR_HOOK, 0.1 ether);
        emit log_named_uint("quoteV4 amountIn", amountIn);
        emit log_named_uint("quoteV4 amountOut", amountOut);
        assertGt(amountOut, 0, "quoteV4 should return non-zero output");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Step 2: Does buildSplitSwapHooked return valid data?
    //         Log which venues won, whether it's split or single.
    // ══════════════════════════════════════════════════════════════════════════

    function testDebug_buildSplitSwapHooked() public {
        (zQuoter.Quote[2] memory legs, bytes memory multicall, uint256 msgValue) = quoter.buildSplitSwapHooked(
            VITALIK, address(0), PNKSTR, 0.1 ether, 100, DEADLINE, 0, 60, PNKSTR_HOOK
        );

        emit log_named_uint("leg0.source", uint256(uint8(legs[0].source)));
        emit log_named_uint("leg0.amountIn", legs[0].amountIn);
        emit log_named_uint("leg0.amountOut", legs[0].amountOut);
        emit log_named_uint("leg0.feeBps", legs[0].feeBps);
        emit log_named_uint("leg1.source", uint256(uint8(legs[1].source)));
        emit log_named_uint("leg1.amountIn", legs[1].amountIn);
        emit log_named_uint("leg1.amountOut", legs[1].amountOut);
        emit log_named_uint("leg1.feeBps", legs[1].feeBps);
        emit log_named_uint("msgValue", msgValue);
        emit log_named_uint("multicall.length", multicall.length);

        uint256 totalOut = legs[0].amountOut + legs[1].amountOut;
        assertGt(totalOut, 0, "should have output");
        assertGt(multicall.length, 0, "multicall should be non-empty");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Step 3: Does buildBestSwapViaETHMulticall also work for ETH→PNKSTR?
    //         (This is the non-hooked path — uses swapV4 directly if V4 wins)
    // ══════════════════════════════════════════════════════════════════════════

    function testDebug_buildBestSwap_ETHtoPNKSTR() public {
        (
            zQuoter.Quote memory a,
            zQuoter.Quote memory b,,
            bytes memory multicall,
            uint256 msgValue
        ) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, address(0), PNKSTR, 0.1 ether, 100, DEADLINE
        );

        emit log_named_uint("bestSwap a.source", uint256(uint8(a.source)));
        emit log_named_uint("bestSwap a.amountOut", a.amountOut);
        emit log_named_uint("bestSwap b.source", uint256(uint8(b.source)));
        emit log_named_uint("bestSwap b.amountOut", b.amountOut);
        emit log_named_uint("bestSwap msgValue", msgValue);

        uint256 bestOut = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(bestOut, 0, "should have output");

        // Execute
        uint256 pnkBefore = IERC20(PNKSTR).balanceOf(VITALIK);
        vm.prank(VITALIK);
        (bool ok, bytes memory ret) = ZROUTER.call{value: msgValue}(multicall);
        if (!ok) {
            emit log_named_bytes("bestSwap revert data", ret);
        }
        assertTrue(ok, "bestSwap multicall should succeed");
        assertGt(IERC20(PNKSTR).balanceOf(VITALIK) - pnkBefore, 0, "should receive PNKSTR");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Step 4: Execute buildSplitSwapHooked calldata through the live zRouter.
    //         This is the exact path the dapp now uses.
    // ══════════════════════════════════════════════════════════════════════════

    function testDebug_executeSplitHooked() public {
        (zQuoter.Quote[2] memory legs, bytes memory multicall, uint256 msgValue) = quoter.buildSplitSwapHooked(
            VITALIK, address(0), PNKSTR, 0.1 ether, 100, DEADLINE, 0, 60, PNKSTR_HOOK
        );

        uint256 totalOut = legs[0].amountOut + legs[1].amountOut;
        emit log_named_uint("totalOut", totalOut);
        assertGt(totalOut, 0, "should have output");

        uint256 pnkBefore = IERC20(PNKSTR).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok, bytes memory ret) = ZROUTER.call{value: msgValue}(multicall);
        if (!ok) {
            emit log_named_bytes("splitHooked revert data", ret);
            // Try to decode if it's a known error
            if (ret.length >= 4) {
                bytes4 sel = bytes4(ret);
                if (sel == zQuoter.ZeroAmount.selector) emit log("Revert: ZeroAmount");
                else emit log_named_bytes("Revert selector", abi.encodePacked(sel));
            } else {
                emit log("Revert: EMPTY DATA (callback lock or bare revert)");
            }
        }
        assertTrue(ok, "splitHooked multicall should succeed");
        assertGt(IERC20(PNKSTR).balanceOf(VITALIK) - pnkBefore, 0, "should receive PNKSTR");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Step 5: Is V4_ROUTER trusted by the deployed zRouter?
    // ══════════════════════════════════════════════════════════════════════════

    function testDebug_V4RouterTrusted() public {
        // Read _isTrustedForCall[V4_ROUTER] from zRouter storage
        // Slot is mapping(address => bool) at storage position determined by contract layout
        // We'll just try a static call to execute with dummy data to check
        // If it reverts with Unauthorized, it's not trusted
    }

    function testDebug_V4RouterCodeExists() public {
        uint256 codeSize;
        address target = V4_ROUTER;
        assembly { codeSize := extcodesize(target) }
        emit log_named_uint("V4_ROUTER code size", codeSize);
        assertGt(codeSize, 0, "V4_ROUTER should have code");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Step 6: Compare outputs — does quoteV4 match what execute actually gives?
    // ══════════════════════════════════════════════════════════════════════════

    function testDebug_quoteVsExecution() public {
        uint256 amount = 0.1 ether;

        // Get V4 quote
        (, uint256 quotedOut) =
            quoter.quoteV4(false, address(0), PNKSTR, 0, 60, PNKSTR_HOOK, amount);
        emit log_named_uint("quoteV4 output", quotedOut);

        // Get best swap multicall and execute
        (
            zQuoter.Quote memory a,
            zQuoter.Quote memory b,,
            bytes memory multicall,
            uint256 msgValue
        ) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, address(0), PNKSTR, amount, 100, DEADLINE
        );

        uint256 bestOut = b.amountOut > 0 ? b.amountOut : a.amountOut;
        emit log_named_uint("bestSwap quoted output", bestOut);

        uint256 pnkBefore = IERC20(PNKSTR).balanceOf(VITALIK);
        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "swap should succeed");

        uint256 actualOut = IERC20(PNKSTR).balanceOf(VITALIK) - pnkBefore;
        emit log_named_uint("actual output", actualOut);
        emit log_named_uint(
            "quote vs actual diff",
            quotedOut > actualOut ? quotedOut - actualOut : actualOut - quotedOut
        );
    }

    receive() external payable {}
}
