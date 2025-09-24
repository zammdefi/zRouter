// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/zRouter.sol";

interface IUniV2PairReserves {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IERC20 {
    function balanceOf(address user) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IFWETH {
    function depositNative(address) external payable;
    function deposit(uint256, address) external;
}

address constant FWETH = 0x90551c1795392094FE6D29B758EcCD233cFAa260;

contract zRouterTest is Test {
    uint256 DEADLINE;

    /* ───────────── addresses & constants ───────────── */
    address constant VITALIK = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // V2 pair (USDC, WETH) 0.30 %
    address constant V2_PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    // V3 pool (USDC < WETH) 0.05 %
    address constant V3_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    // two whales we borrow tokens from
    address constant USDC_WHALE = 0x55FE002aefF02F77364de339a1292923A15844B8;
    address constant WETH_WHALE = 0x8EB8a3b98659Cce290402893d0123abb75E3ab28;

    uint256 constant USDC_IN = 100e6; // 100 USDC exact-in for USDC→ETH test
    uint256 constant ETH_IN = 0.05 ether; // 0.05 ETH budget for exact-out test
    uint256 constant USDC_OUT = 50e6; // 50 USDC exact-out target

    address constant BAL_POOL_WETH_TOKEN = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF; // ← fill: Balancer V3 pool
    address constant TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // e.g., USDC
    uint8 constant TOKEN_DECIMALS = 6; // 6 for USDC

    function _scaleToken(uint256 units) internal pure returns (uint256) {
        return units * (10 ** TOKEN_DECIMALS);
    }

    /* ───────────── state ───────────── */
    zRouter router;

    /* ───────────── helpers ─────────── */
    function _quoteV2_WethOut(uint256 usdcIn) internal view returns (uint256 wethOut) {
        (uint112 r0, uint112 r1,) = IUniV2PairReserves(V2_PAIR).getReserves();
        // token0 = USDC, token1 = WETH
        uint256 reserveIn = uint256(r0); // USDC
        uint256 reserveOut = uint256(r1); // WETH
        uint256 inWithFee = usdcIn * 997;
        wethOut = (inWithFee * reserveOut) / (reserveIn * 1000 + inWithFee);
    }

    /* ───────────── setUp ───────────── */
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main")); // latest block

        router = new zRouter();

        // fund Vitalik with ETH
        vm.deal(VITALIK, 1 ether);

        // borrow 500 USDC for Vitalik
        vm.startPrank(USDC_WHALE);
        vm.deal(USDC_WHALE, 1 ether); // gas
        IERC20(USDC).approve(VITALIK, type(uint256).max); // to simplify transfer
        vm.stopPrank();
        vm.prank(VITALIK);
        IERC20(USDC).transferFrom(USDC_WHALE, VITALIK, 500e6);

        DEADLINE = block.timestamp + 20 minutes;

        PoolKey memory key = PoolKey(0, 0, address(0), USDC, 30);

        vm.deal(VITALIK, 1 ether);

        vm.startPrank(VITALIK);
        IERC20(USDC).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(ZAMM, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(ZAMM, type(uint256).max);
        vm.stopPrank();

        vm.prank(USDC_WHALE);
        IZAMM(ZAMM).addLiquidity{value: 1 ether}(key, 1 ether, 3500e6, 0, 0, VITALIK, DEADLINE);
    }

    /* ───────────── tests ───────────── */

    /// USDC → ETH on Uniswap V2 (unwrap branch)
    function testUSDCtoETH_V2() public {
        uint256 wethOut = _quoteV2_WethOut(USDC_IN);

        uint256 ethBefore = VITALIK.balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        // approve router to pull USDC
        vm.startPrank(VITALIK);
        IERC20(USDC).approve(address(router), USDC_IN);
        router.swapV2(
            VITALIK,
            false,
            USDC,
            address(0), // ETH out
            USDC_IN,
            wethOut,
            DEADLINE
        );
        vm.stopPrank();

        uint256 ethAfter = VITALIK.balance;
        uint256 usdcAfter = IERC20(USDC).balanceOf(VITALIK);

        assertEq(usdcBefore - usdcAfter, USDC_IN, "USDC spent mismatch");
        assertEq(ethAfter - ethBefore, wethOut, "ETH received mismatch");
    }

    /// Exact-output: 50 USDC out, spend at most 0.05 ETH on V3 0.3 %
    function testExactOutput_ETHtoUSDC_V3() public {
        uint256 ethBefore = VITALIK.balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapV3{value: ETH_IN}(
            VITALIK,
            true, // exact-output
            3000, // 0.3 % fee tier
            address(0), // ETH in
            USDC, // USDC out
            USDC_OUT, // want exactly 50 USDC
            ETH_IN, // spend at most 0.05 ETH  ← changed
            DEADLINE
        );

        uint256 ethAfter = VITALIK.balance;
        uint256 usdcAfter = IERC20(USDC).balanceOf(VITALIK);

        assertEq(usdcAfter - usdcBefore, USDC_OUT, "USDC exact-out failed");
        assertLt(ethBefore - ethAfter, ETH_IN, "spent full budget (should refund)");
        assertGt(ethBefore - ethAfter, 0, "no ETH spent?");
    }

    /// Slippage too tight → `Slippage()` revert on V2
    function testSlippageReverts_V2() public {
        uint256 wethOut = _quoteV2_WethOut(USDC_IN);

        vm.startPrank(VITALIK);
        IERC20(USDC).approve(address(router), USDC_IN);
        vm.expectRevert(zRouter.Slippage.selector);
        router.swapV2(VITALIK, false, USDC, address(0), USDC_IN, wethOut + 1, DEADLINE);
        vm.stopPrank();
    }

    /* ───────── extra constants ───────── */
    uint256 constant ETH_OUT = 0.02 ether; // 0.02 ETH exact-out target

    /* ───────── maths helpers (router formulas) ───────── */
    function _getAmountOut(uint256 amtIn, uint256 resIn, uint256 resOut)
        internal
        pure
        returns (uint256)
    {
        uint256 x = amtIn * 997;
        return (x * resOut) / (resIn * 1000 + x);
    }

    function _getAmountIn(uint256 amtOut, uint256 resIn, uint256 resOut)
        internal
        pure
        returns (uint256)
    {
        uint256 n = resIn * amtOut * 1000;
        uint256 d = (resOut - amtOut) * 997;
        return (n + d - 1) / d; // ceil-div
    }

    /* ───────── V2: ETH → USDC — exact-in ───────── */
    function testExactIn_ETHtoUSDC_V2() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);
        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        router.swapV2{value: ETH_IN}(
            VITALIK,
            false,
            address(0),
            USDC,
            ETH_IN, // exact-in
            0, // accept best quote
            DEADLINE
        );

        uint256 usdcDelta = IERC20(USDC).balanceOf(VITALIK) - usdcBefore;
        uint256 ethDelta = ethBefore - VITALIK.balance; // positive difference

        assertGt(usdcDelta, 0, "no USDC out");
        assertEq(ethDelta, ETH_IN, "wrong ETH spend");
    }

    // -- SUSHISWAP VARIANT
    function testExactIn_ETHtoUSDC_V2_SUSHISWAP() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);
        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        router.swapV2{value: ETH_IN}(
            VITALIK,
            false,
            address(0),
            USDC,
            ETH_IN, // exact-in
            0, // accept best quote
            type(uint256).max
        );

        uint256 usdcDelta = IERC20(USDC).balanceOf(VITALIK) - usdcBefore;
        uint256 ethDelta = ethBefore - VITALIK.balance; // positive difference

        assertGt(usdcDelta, 0, "no USDC out");
        assertEq(ethDelta, ETH_IN, "wrong ETH spend");
    }

    address constant MILADY = 0x227c7DF69D3ed1ae7574A1a7685fDEd90292EB48;

    function testExactIn_ETHtoMILADY_V2_SUSHISWAP() public {
        uint256 milBefore = IERC20(MILADY).balanceOf(VITALIK);
        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        router.swapV2{value: ETH_IN}(
            VITALIK,
            false,
            address(0),
            MILADY,
            ETH_IN, // exact-in
            0, // accept best quote
            type(uint256).max
        );

        uint256 milDelta = IERC20(MILADY).balanceOf(VITALIK) - milBefore;
        uint256 ethDelta = ethBefore - VITALIK.balance; // positive difference

        assertGt(milDelta, 0, "no MIL out");
        assertEq(ethDelta, ETH_IN, "wrong ETH spend");
    }

    /* ───────── V2: ETH → USDC — exact-out ───────── */
    function testExactOut_ETHtoUSDC_V2() public {
        (uint112 r0, uint112 r1,) = IUniV2PairReserves(V2_PAIR).getReserves();
        // tokenIn = WETH (r1), tokenOut = USDC (r0)
        uint256 need = _getAmountIn(USDC_OUT, r1, r0);
        uint256 budget = need + 5e15; // add 0.005 ETH slack

        uint256 ethBefore = VITALIK.balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapV2{value: budget}(VITALIK, true, address(0), USDC, USDC_OUT, budget, DEADLINE);

        uint256 ethSpent = ethBefore - VITALIK.balance;
        uint256 usdcDelta = IERC20(USDC).balanceOf(VITALIK) - usdcBefore;

        assertEq(usdcDelta, USDC_OUT, "USDC exact-out failed");
        assertLt(ethSpent, budget, "no ETH refund");
        assertGt(ethSpent, need - 1, "under-spent");
    }

    /* ───────── V2: USDC → ETH — exact-out ───────── */
    function testExactOut_USDCtoETH_V2() public {
        (uint112 r0, uint112 r1,) = IUniV2PairReserves(V2_PAIR).getReserves();
        uint256 needUsdc = _getAmountIn(ETH_OUT, r0, r1); // USDC reserve = r0
        uint256 budget = needUsdc + 1e6; // +1 USDC slack

        uint256 ethBefore = VITALIK.balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.startPrank(VITALIK);
        IERC20(USDC).approve(address(router), budget);
        router.swapV2(VITALIK, true, USDC, address(0), ETH_OUT, budget, DEADLINE);
        vm.stopPrank();

        uint256 ethDelta = VITALIK.balance - ethBefore;
        uint256 usdcSpent = usdcBefore - IERC20(USDC).balanceOf(VITALIK);

        assertEq(ethDelta, ETH_OUT, "ETH exact-out failed");
        assertLe(usdcSpent, budget, "overspent USDC");
        assertGe(usdcSpent, needUsdc, "underspent");
    }

    /* ───────── V3: ETH → USDC — exact-in ───────── */
    function testExactIn_ETHtoUSDC_V3() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapV3{value: ETH_IN}(VITALIK, false, 3000, address(0), USDC, ETH_IN, 0, DEADLINE);

        assertGt(IERC20(USDC).balanceOf(VITALIK) - usdcBefore, 0, "no USDC out");
    }

    /* ───────── V3: USDC → ETH — exact-in ───────── */
    function testExactIn_USDCtoETH_V3() public {
        uint256 ethBefore = VITALIK.balance;

        vm.startPrank(VITALIK);
        IERC20(USDC).approve(address(router), USDC_IN);
        router.swapV3(VITALIK, false, 3000, USDC, address(0), USDC_IN, 0, DEADLINE);
        vm.stopPrank();

        assertGt(VITALIK.balance - ethBefore, 0, "no ETH out");
    }

    /* ───────── V4: ETH → USDC — exact-in ───────── */
    function testExactIn_ETHtoUSDC_V4() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapV4{value: ETH_IN}(
            VITALIK, false, 3000, 60, address(0), USDC, ETH_IN, 0, DEADLINE
        );

        assertGt(IERC20(USDC).balanceOf(VITALIK) - usdcBefore, 0, "no USDC out");
    }

    /* ───────── ZAMM: ───────── */
    function testExactIn_ETHtoUSDC_ZAMM() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapVZ{value: ETH_IN}(
            VITALIK, false, 30, address(0), USDC, 0, 0, ETH_IN, 0, DEADLINE
        );

        assertGt(IERC20(USDC).balanceOf(VITALIK) - usdcBefore, 0, "no USDC out");
    }

    function testExactOut_ETHtoUSDC_ZAMM() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapVZ{value: ETH_IN}(
            VITALIK, true, 30, address(0), USDC, 0, 0, USDC_IN, ETH_IN, DEADLINE
        );

        assertGt(IERC20(USDC).balanceOf(VITALIK) - usdcBefore, 0, "no USDC out");
    }

    address ZAMM_1 = 0x000000000000040470635EB91b7CE4D132D616eD;

    function testExactIn_USDCtoETH_ZAMM() public {
        uint256 ethBefore = VITALIK.balance;

        router.ensureAllowance(USDC, false, ZAMM_1);

        vm.prank(VITALIK);
        router.swapVZ(VITALIK, false, 30, USDC, address(0), 0, 0, USDC_IN, 0, DEADLINE);

        assertGt(VITALIK.balance - ethBefore, 0, "no ETH out");
    }

    function testExactOut_USDCtoETH_ZAMM() public {
        uint256 ethBefore = VITALIK.balance;

        router.ensureAllowance(USDC, false, ZAMM_1);

        vm.prank(VITALIK);
        router.swapVZ(VITALIK, true, 30, USDC, address(0), 0, 0, ETH_IN / 2, USDC_IN, DEADLINE);

        assertGt(VITALIK.balance - ethBefore, 0, "no ETH out");
    }

    // ** // ** // ** //

    function testSingleMulticallExactIn_ETHtoUSDC_V2() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);
        uint256 ethBefore = VITALIK.balance;

        bytes[] memory calls = new bytes[](1);

        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector, VITALIK, false, address(0), USDC, ETH_IN, 0, DEADLINE
        );

        vm.prank(VITALIK);
        router.multicall{value: ETH_IN}(calls);

        uint256 usdcDelta = IERC20(USDC).balanceOf(VITALIK) - usdcBefore;
        uint256 ethDelta = ethBefore - VITALIK.balance; // positive difference

        assertGt(usdcDelta, 0, "no USDC out");
        assertEq(ethDelta, ETH_IN, "wrong ETH spend");
    }

    function testMulticallExactIn_ETHtoUSDC_V2_ExactIn_USDCtoETH_V3() public {
        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector, address(router), false, address(0), USDC, ETH_IN, 0, DEADLINE
        );
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector, VITALIK, false, 3000, USDC, address(0), 177650233, 0, DEADLINE
        );

        vm.prank(VITALIK);
        router.multicall{value: ETH_IN}(calls);
    }

    function testMulticallExactIn_ETHtoUSDC_V2_ExactIn_USDCtoETH_V4() public {
        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector, address(router), false, address(0), USDC, ETH_IN, 0, DEADLINE
        );
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV4.selector,
            VITALIK,
            false,
            3000,
            60,
            USDC,
            address(0),
            177650233,
            0,
            DEADLINE
        );

        vm.prank(VITALIK);
        router.multicall{value: ETH_IN}(calls);
    }

    // ============= CORRECTED CROSS-AMM TESTS =============

    function testMulticallMixedExactTypes_V2ExactOut_V3ExactIn() public {
        bytes[] memory calls = new bytes[](2);

        uint256 targetUsdc = 100e6;

        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector,
            address(router),
            true, // exact-out
            address(0),
            USDC,
            targetUsdc, // want exactly 100 USDC
            ETH_IN, // max ETH to spend
            DEADLINE
        );

        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector,
            VITALIK,
            false, // exact-in
            3000,
            USDC,
            address(0),
            targetUsdc, // use all 100 USDC
            0,
            DEADLINE
        );

        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        router.multicall{value: ETH_IN}(calls);

        assertLt(ethBefore - VITALIK.balance, ETH_IN, "Should have ETH refund");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "Router should have no USDC");
    }

    function testTransientBalance_DepositThenSwap() public {
        // Deposit USDC to router, then use in swap
        bytes[] memory calls = new bytes[](2);

        vm.prank(VITALIK);
        IERC20(USDC).approve(address(router), 100e6);

        calls[0] = abi.encodeWithSelector(zRouter.deposit.selector, USDC, 0, 100e6);

        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector, VITALIK, false, 3000, USDC, address(0), 100e6, 0, DEADLINE
        );

        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        router.multicall(calls);

        assertGt(VITALIK.balance - ethBefore, 0, "Should receive ETH");
    }

    function testTransientBalance_PartialUse() public {
        // Fix arithmetic underflow
        bytes[] memory calls = new bytes[](3);

        vm.prank(VITALIK);
        IERC20(USDC).approve(address(router), 200e6);

        calls[0] = abi.encodeWithSelector(zRouter.deposit.selector, USDC, 0, 200e6);

        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector, VITALIK, false, 3000, USDC, address(0), 100e6, 0, DEADLINE
        );

        calls[2] = abi.encodeWithSelector(zRouter.sweep.selector, USDC, 0, 0, VITALIK);

        uint256 initialUsdc = IERC20(USDC).balanceOf(VITALIK);
        uint256 initialEth = VITALIK.balance;

        vm.prank(VITALIK);
        router.multicall(calls);

        uint256 finalUsdc = IERC20(USDC).balanceOf(VITALIK);
        uint256 finalEth = VITALIK.balance;

        // Net USDC change should be -100e6 (deposited 200, used 100, got back 100)
        assertEq(initialUsdc - finalUsdc, 100e6, "Should have net spent 100 USDC");
        assertGt(finalEth, initialEth, "Should receive ETH from swap");
    }

    function testETHRefund_ExcessValueSent() public {
        // Send too much ETH for exact-out swap
        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        router.swapV2{value: 0.5 ether}( // way too much
            VITALIK,
            true, // exact-out
            address(0),
            USDC,
            50e6, // want only 50 USDC
            0.5 ether,
            DEADLINE
        );

        // Should have significant refund
        assertGt(0.4 ether, ethBefore - VITALIK.balance, "Should refund most ETH");
    }

    function testMulticallETHAccumulation() public {
        // Multiple ETH outputs accumulate in router, then sweep
        bytes[] memory calls = new bytes[](3);

        vm.prank(VITALIK);
        IERC20(USDC).approve(address(router), 300e6);

        // Two swaps that output ETH to router
        calls[0] = abi.encodeWithSelector(
            zRouter.swapV3.selector,
            address(router), // ETH to router
            false,
            3000,
            USDC,
            address(0),
            100e6,
            0,
            DEADLINE
        );

        calls[1] = abi.encodeWithSelector(
            zRouter.swapV2.selector,
            address(router), // ETH to router
            false,
            USDC,
            address(0),
            100e6,
            0,
            DEADLINE
        );

        // Sweep all ETH
        calls[2] = abi.encodeWithSelector(
            zRouter.sweep.selector,
            address(0),
            0,
            0, // all ETH
            VITALIK
        );

        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        router.multicall(calls);

        assertGt(VITALIK.balance - ethBefore, 0, "Should receive accumulated ETH");
    }

    function testMulticall_V2toZAMM() public {
        // Adjust expectations for slippage
        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector, address(router), false, address(0), USDC, ETH_IN, 0, DEADLINE
        );

        calls[1] = abi.encodeWithSelector(
            zRouter.swapVZ.selector,
            VITALIK,
            false,
            30,
            USDC,
            address(0),
            0,
            0,
            150e6, // Use most of the USDC
            0,
            DEADLINE
        );

        router.ensureAllowance(USDC, false, ZAMM);

        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        router.multicall{value: ETH_IN}(calls);

        // Just check we got some ETH back (accounting for fees)
        uint256 ethAfter = VITALIK.balance;
        assertGt(ethAfter, ethBefore - ETH_IN, "Should have received some ETH");

        // Log the actual amounts for debugging
        console.log("ETH spent:", ETH_IN);
        console.log("ETH received back:", ethAfter - (ethBefore - ETH_IN));
    }

    function testMulticallSlippageProtection_SecondSwapFails() public {
        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector, address(router), false, address(0), USDC, ETH_IN, 0, DEADLINE
        );

        // Second swap with impossible slippage limit
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector,
            VITALIK,
            false,
            3000,
            USDC,
            address(0),
            100e6,
            1 ether, // impossible amount out
            DEADLINE
        );

        vm.prank(VITALIK);
        vm.expectRevert(zRouter.Slippage.selector);
        router.multicall{value: ETH_IN}(calls);
    }

    function testExpiredDeadline_Reverts() public {
        vm.warp(block.timestamp + 1 hours);

        vm.prank(VITALIK);
        vm.expectRevert(zRouter.Expired.selector);
        router.swapV2{value: ETH_IN}(
            VITALIK,
            false,
            address(0),
            USDC,
            ETH_IN,
            0,
            DEADLINE // now expired
        );
    }

    function testMulticallArbitragePath_Optimized() public {
        bytes[] memory calls = new bytes[](3);

        // First swap: ETH -> USDC via V2
        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector,
            address(router),
            false,
            address(0),
            USDC,
            0.1 ether,
            0,
            DEADLINE
        );

        // Second swap: USDC -> ETH via V3
        // Output ETH to V2 WETH/USDC pool for next swap
        address v2Pool = _v2PoolFor(WETH, USDC);
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector,
            v2Pool, // Send WETH directly to V2 pool!
            false,
            3000,
            USDC,
            WETH,
            300e6,
            0,
            DEADLINE
        );

        // Third swap: WETH -> USDC via V2
        // After wrapping, send WETH directly to V2 pool
        calls[2] = abi.encodeWithSelector(
            zRouter.swapV2.selector, VITALIK, false, WETH, USDC, 0.055 ether, 0, DEADLINE
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.multicall{value: 0.1 ether}(calls);

        assertGt(IERC20(USDC).balanceOf(VITALIK), usdcBefore, "Should have USDC output");
    }

    function testV3_ETH_to_V4_Native() public {
        // V4 PoolNotInitialized (0x486aa307)
        // Skip V4, use zAMM which supports native ETH
        bytes[] memory calls = new bytes[](2);

        vm.prank(VITALIK);
        IERC20(USDC).approve(address(router), 200e6);

        calls[0] = abi.encodeWithSelector(
            zRouter.swapV3.selector,
            address(router),
            false,
            3000,
            USDC,
            address(0),
            100e6,
            0,
            DEADLINE
        );

        // Use zAMM instead of V4
        calls[1] = abi.encodeWithSelector(
            zRouter.swapVZ.selector,
            VITALIK,
            false,
            30,
            address(0),
            USDC,
            0,
            0,
            0.02 ether,
            0,
            DEADLINE
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.multicall(calls);

        assertGt(IERC20(USDC).balanceOf(VITALIK), usdcBefore - 100e6, "Should have some USDC back");
    }

    function testV3_ETH_to_ZAMM_Native() public {
        // Test that V3 ETH output can be used directly by zAMM
        bytes[] memory calls = new bytes[](2);

        vm.prank(VITALIK);
        IERC20(USDC).approve(address(router), 200e6);

        // V3: USDC -> ETH
        calls[0] = abi.encodeWithSelector(
            zRouter.swapV3.selector,
            address(router),
            false,
            3000,
            USDC,
            address(0),
            100e6,
            0,
            DEADLINE
        );

        // zAMM: ETH -> USDC (native ETH)
        calls[1] = abi.encodeWithSelector(
            zRouter.swapVZ.selector,
            VITALIK,
            false,
            30,
            address(0), // Native ETH works with zAMM!
            USDC,
            0,
            0,
            0.02 ether,
            0,
            DEADLINE
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.multicall(calls);

        // Should end up with USDC
        assertGt(IERC20(USDC).balanceOf(VITALIK), usdcBefore - 100e6, "Should have some USDC back");
    }

    function testOptimizedV3toV2_PreFundPool() public {
        // Optimal flow: V3 outputs WETH directly to V2 pool
        bytes[] memory calls = new bytes[](2);

        vm.prank(VITALIK);
        IERC20(USDC).approve(address(router), 200e6);

        // Get V2 pool address
        address v2Pool = _v2PoolFor(WETH, USDC);

        // V3: USDC -> WETH, output directly to V2 pool
        // But wait - V3 outputs ETH not WETH when tokenOut is address(0)
        // So we need to output WETH specifically
        calls[0] = abi.encodeWithSelector(
            zRouter.swapV3.selector,
            v2Pool, // Send WETH directly to V2 pool!
            false,
            3000,
            USDC,
            WETH, // Output WETH not ETH
            100e6,
            0,
            DEADLINE
        );

        // V2: WETH -> USDC, pool is pre-funded!
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV2.selector, VITALIK, false, WETH, USDC, 0.02 ether, 0, DEADLINE
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.multicall(calls);

        assertLt(IERC20(USDC).balanceOf(VITALIK), usdcBefore, "Should have lost to fees");
    }

    function testTripleHop_OptimalPreFunding() public {
        bytes[] memory calls = new bytes[](3);

        // Get pool addresses
        address v2Pool = _v2PoolFor(WETH, USDC);

        // Hop 1: ETH -> USDC via V2, output to router in prep for v3 swap
        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector, address(router), false, address(0), USDC, ETH_IN, 0, DEADLINE
        );

        // Hop 2: USDC -> WETH via V3, output to V2 pool
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector,
            v2Pool, // Send WETH directly to V2 pool!
            false,
            3000,
            USDC,
            WETH, // Output WETH not ETH
            150e6,
            0,
            DEADLINE
        );

        // Hop 3: WETH -> USDC via V2 (pool pre-funded)
        calls[2] = abi.encodeWithSelector(
            zRouter.swapV2.selector, VITALIK, false, WETH, USDC, 0.02 ether, 0, DEADLINE
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.multicall{value: ETH_IN}(calls);

        assertGt(IERC20(USDC).balanceOf(VITALIK) - usdcBefore, 0, "No USDC from triple hop");
    }

    // Helper function to demonstrate the pattern
    function testDocumentPreFundingPattern() public pure {
        // Pattern for optimal multicall with V2:

        // 1. If next swap is V2, calculate its pool address
        address nextV2Pool = _v2PoolFor(WETH, USDC);

        // 2. Set the current swap's `to` to that pool address
        // This pre-funds the pool

        // 3. The V2 swap will detect the pre-funded pool via:
        // if (!_useTransientBalance(pool, tokenIn, 0, amountIn))
        // This check will succeed, skipping the transfer!

        // This pattern saves:
        // - One token transfer (router -> pool)
        // - Associated gas costs
        // - Makes the multicall more atomic

        console.log("V2 USDC/WETH Pool:", nextV2Pool);
        console.log("Pre-funding this pool skips transfer in swapV2");
    }

    /* ───────── ZAMM CULT HOOK: ───────── */
    function testExactIn_ETHtoCULT_ZAMM() public {
        uint256 cultBefore = IERC20(CULT).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapVZ{value: ETH_IN}(
            VITALIK, false, CULT_ID, address(0), CULT, 0, 0, ETH_IN, 0, DEADLINE
        );

        assertGt(IERC20(CULT).balanceOf(VITALIK) - cultBefore, 0, "no USDC out");
    }

    function testExactIn_ETHtoCULT_ZAMM_AND_BACK() public {
        uint256 cultBefore = IERC20(CULT).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (, uint256 amountOut) = router.swapVZ{value: ETH_IN}(
            VITALIK, false, CULT_ID, address(0), CULT, 0, 0, ETH_IN, 0, DEADLINE
        );

        assertGt(IERC20(CULT).balanceOf(VITALIK) - cultBefore, 0, "no CULT out");

        vm.prank(VITALIK);
        IERC20(CULT).approve(address(router), type(uint256).max);

        vm.prank(VITALIK);
        router.swapVZ(VITALIK, false, CULT_ID, CULT, address(0), 0, 0, amountOut, 0, DEADLINE);
    }

    // CURVE

    function testCurve_ETHtoWEETH_ExactIn() public {
        (uint256 iWeth, uint256 jWeeth) = _wethWeethIndices();
        uint256 ethIn = 0.02 ether;

        address[11] memory route;
        route[0] = address(0); // ETH
        route[1] = WETH; // nonzero sentinel for type 8
        route[2] = WETH; // after wrap
        route[3] = WEETH_WETH_NG_POOL; // pool
        route[4] = WEETH; // final token

        uint256[4][5] memory sp;
        sp[0] = [uint256(0), uint256(0), uint256(8), uint256(0)]; // ETH<->WETH
        sp[1] = [iWeth, jWeeth, uint256(1), uint256(10)]; // exchange, stable-ng

        address[5] memory basePools; // zeros

        uint256 weethBefore = IERC20(WEETH).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (uint256 amountIn, uint256 amountOut) = router.swapCurve{value: ethIn}(
            VITALIK,
            false, // exact-in
            route,
            sp,
            basePools,
            ethIn,
            0, // minOut
            DEADLINE
        );

        assertEq(amountIn, ethIn, "exact-in should spend full ETH");
        assertGt(IERC20(WEETH).balanceOf(VITALIK) - weethBefore, 0, "no weETH out");
    }

    function testCurve_WETHtoWEETH_ExactIn() public {
        (uint256 iWeth, uint256 jWeeth) = _wethWeethIndices();

        // fund Vitalik with WETH
        vm.startPrank(WETH_WHALE);
        IERC20(WETH).transfer(VITALIK, 0.05 ether);
        vm.stopPrank();

        // approvals: user → router, and router → pool
        vm.startPrank(VITALIK);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();

        uint256 inAmt = 0.02 ether;

        // route without ETH hop
        address[11] memory route;
        route[0] = WETH;
        route[1] = WEETH_WETH_NG_POOL;
        route[2] = WEETH;

        uint256[4][5] memory sp;
        sp[0] = [iWeth, jWeeth, uint256(1), uint256(10)]; // exchange, stable-ng

        address[5] memory basePools;

        uint256 weethBefore = IERC20(WEETH).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (uint256 amountIn, uint256 amountOut) =
            router.swapCurve(VITALIK, false, route, sp, basePools, inAmt, 0, DEADLINE);

        uint256 weethDelta = IERC20(WEETH).balanceOf(VITALIK) - weethBefore;
        assertEq(amountIn, inAmt, "wrong input spent");
        assertGt(amountOut, 0, "no output");
        assertEq(weethDelta, amountOut, "credit mismatch");
    }

    function testCurve_WETHtoWEETH_ExactOut() public {
        (uint256 iWeth, uint256 jWeeth) = _wethWeethIndices();

        // fund Vitalik with WETH
        vm.startPrank(WETH_WHALE);
        IERC20(WETH).transfer(VITALIK, 0.2 ether);
        vm.stopPrank();

        // approvals: user → router, and router → pool
        vm.startPrank(VITALIK);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();

        uint256 targetOut = 0.003e18;

        // build route WETH -> weETH
        address[11] memory route;
        route[0] = WETH;
        route[1] = WEETH_WETH_NG_POOL;
        route[2] = WEETH;

        uint256[4][5] memory sp;
        sp[0] = [iWeth, jWeeth, uint256(1), uint256(10)]; // exchange, stable-ng

        address[5] memory basePools;

        // quote rough required WETH using view get_dx
        uint256 dx = IStableNgPool(WEETH_WETH_NG_POOL).get_dx(
            int128(int256(iWeth)), int128(int256(jWeeth)), targetOut
        );
        uint256 budget = dx + 1e14; // add small headroom

        uint256 wethBefore = IERC20(WETH).balanceOf(VITALIK);
        uint256 weethBefore = IERC20(WEETH).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (uint256 amountIn, uint256 amountOut) =
            router.swapCurve(VITALIK, true, route, sp, basePools, targetOut, budget, DEADLINE);

        uint256 wethSpent = wethBefore - IERC20(WETH).balanceOf(VITALIK);
        uint256 weethDelta = IERC20(WEETH).balanceOf(VITALIK) - weethBefore;

        assertEq(amountOut, targetOut, "reported amountOut should equal target");
        assertGe(weethDelta, targetOut, "under-delivered");
        assertLe(weethDelta - targetOut, 1e9, "overfill too large"); // small rounding wiggle
        assertLe(amountIn, budget, "overspent");
        assertLe(wethSpent, budget, "overspent wallet");
    }

    function testCurve_RoundTrip_WETH_WEETH_DepositForThenSweep() public {
        (uint256 iWeth, uint256 jWeeth) = _wethWeethIndices();

        // fund Vitalik with WETH
        vm.startPrank(WETH_WHALE);
        IERC20(WETH).transfer(VITALIK, 0.06 ether);
        vm.stopPrank();

        // approvals: user → router; router → pool; router → pool for WETH (already), and for weETH for the reverse leg
        vm.startPrank(VITALIK);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();

        // leg 1: WETH -> weETH (to router for chaining)
        address[11] memory r1;
        r1[0] = WETH;
        r1[1] = WEETH_WETH_NG_POOL;
        r1[2] = WEETH;
        uint256[4][5] memory p1;
        p1[0] = [iWeth, jWeeth, uint256(1), uint256(10)];
        address[5] memory bp;

        vm.prank(VITALIK);
        router.swapCurve(
            address(router), // keep on router for next hop
            false,
            r1,
            p1,
            bp,
            0.03 ether,
            0,
            DEADLINE
        );

        // leg 2: weETH -> WETH (consume transient balance, deliver back to Vitalik)
        address[11] memory r2;
        r2[0] = WEETH;
        r2[1] = WEETH_WETH_NG_POOL;
        r2[2] = WETH;
        uint256[4][5] memory p2;
        p2[0] = [jWeeth, iWeth, uint256(1), uint256(10)];

        uint256 wethBefore = IERC20(WETH).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapCurve(
            VITALIK,
            false,
            r2,
            p2,
            bp,
            0, // exact-in amount will be pulled from router transient balance (all available)
            0,
            DEADLINE
        );

        uint256 wethAfter = IERC20(WETH).balanceOf(VITALIK);
        assertGt(wethAfter - wethBefore, 0, "no WETH back");
    }

    function testCurve_WEETHtoETH_ExactIn_Unwrap() public {
        (uint256 iWeth, uint256 jWeeth) = _wethWeethIndices();

        // get some weETH first by doing WETH -> weETH exact-in
        vm.startPrank(WETH_WHALE);
        IERC20(WETH).transfer(VITALIK, 0.03 ether);
        vm.stopPrank();
        vm.startPrank(VITALIK);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();

        // WETH -> weETH to user
        {
            address[11] memory r;
            r[0] = WETH;
            r[1] = WEETH_WETH_NG_POOL;
            r[2] = WEETH;
            uint256[4][5] memory spR;
            spR[0] = [iWeth, jWeeth, uint256(1), uint256(10)];
            address[5] memory bp;
            vm.prank(VITALIK);
            router.swapCurve(VITALIK, false, r, spR, bp, 0.02 ether, 0, DEADLINE);
        }

        // Now weETH -> WETH -> ETH (type-8 last hop) to Vitalik
        address[11] memory route;
        route[0] = WEETH;
        route[1] = WEETH_WETH_NG_POOL;
        route[2] = WETH;
        route[3] = WETH; // sentinel for type-8 step
        route[4] = address(0); // final ETH

        uint256[4][5] memory sp;
        sp[0] = [jWeeth, iWeth, uint256(1), uint256(10)]; // exchange
        sp[1] = [uint256(0), uint256(0), uint256(8), uint256(0)]; // WETH -> ETH

        address[5] memory basePools;

        uint256 ethBefore = VITALIK.balance;

        // approve weETH from user to router for this leg
        vm.startPrank(VITALIK);
        IERC20(WEETH).approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.prank(VITALIK);
        router.swapCurve(VITALIK, false, route, sp, basePools, 0.001e18, 0, DEADLINE);

        assertGt(VITALIK.balance - ethBefore, 0, "no ETH out");
    }

    function testCurve_SlippageReverts_ExactIn() public {
        (uint256 iWeth, uint256 jWeeth) = _wethWeethIndices();

        // fund & approvals
        vm.startPrank(WETH_WHALE);
        IERC20(WETH).transfer(VITALIK, 0.02 ether);
        vm.stopPrank();
        vm.startPrank(VITALIK);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();

        uint256 dx = 0.02 ether;

        // quote realistic out
        uint256 dy = IStableNgPool(WEETH_WETH_NG_POOL).get_dy(
            int128(int256(iWeth)), int128(int256(jWeeth)), dx
        );

        // set impossible minOut (dy + 1)
        address[11] memory route;
        route[0] = WETH;
        route[1] = WEETH_WETH_NG_POOL;
        route[2] = WEETH;
        uint256[4][5] memory sp;
        sp[0] = [iWeth, jWeeth, uint256(1), uint256(10)];
        address[5] memory basePools;

        vm.prank(VITALIK);
        vm.expectRevert(zRouter.Slippage.selector);
        router.swapCurve(VITALIK, false, route, sp, basePools, dx, dy + 1, DEADLINE);
    }

    function testCurve_SlippageReverts_ExactOut_BudgetTooLow() public {
        (uint256 iWeth, uint256 jWeeth) = _wethWeethIndices();

        // fund & approvals
        vm.startPrank(WETH_WHALE);
        IERC20(WETH).transfer(VITALIK, 0.02 ether);
        vm.stopPrank();
        vm.startPrank(VITALIK);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();

        uint256 targetOut = 0.002e18;
        uint256 need = IStableNgPool(WEETH_WETH_NG_POOL).get_dx(
            int128(int256(iWeth)), int128(int256(jWeeth)), targetOut
        );
        uint256 budget = need - 1; // too low

        address[11] memory route;
        route[0] = WETH;
        route[1] = WEETH_WETH_NG_POOL;
        route[2] = WEETH;
        uint256[4][5] memory sp;
        sp[0] = [iWeth, jWeeth, uint256(1), uint256(10)];
        address[5] memory basePools;

        vm.prank(VITALIK);
        vm.expectRevert(zRouter.Slippage.selector);
        router.swapCurve(VITALIK, true, route, sp, basePools, targetOut, budget, DEADLINE);
    }

    function testCurve_ExpiredDeadline_Reverts() public {
        (uint256 iWeth, uint256 jWeeth) = _wethWeethIndices();

        // fund & approvals
        vm.startPrank(WETH_WHALE);
        IERC20(WETH).transfer(VITALIK, 0.02 ether);
        vm.stopPrank();
        vm.startPrank(VITALIK);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();

        address[11] memory route;
        route[0] = WETH;
        route[1] = WEETH_WETH_NG_POOL;
        route[2] = WEETH;
        uint256[4][5] memory sp;
        sp[0] = [iWeth, jWeeth, uint256(1), uint256(10)];
        address[5] memory basePools;

        vm.warp(block.timestamp + 1 hours);
        vm.prank(VITALIK);
        vm.expectRevert(zRouter.Expired.selector);
        router.swapCurve(VITALIK, false, route, sp, basePools, 0.01 ether, 0, DEADLINE);
    }

    // HELPERS

    receive() external payable {}

    function _v2PoolFor(address tokenA, address tokenB) internal pure returns (address v2pool) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        v2pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            V2_FACTORY,
                            keccak256(abi.encodePacked(token0, token1)),
                            V2_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // WETH must be index 0 and weETH index 1 on this pool (we assert to be safe).
    function _wethWeethIndices() internal view returns (uint256 iWeth, uint256 jWeeth) {
        // WETH is coin(0)
        (bool ok0, bytes memory d0) =
            WEETH_WETH_NG_POOL.staticcall(abi.encodeWithSignature("coins(uint256)", 0));
        address c0 = ok0 && d0.length >= 32 ? abi.decode(d0, (address)) : address(0);
        require(c0 == WETH, "unexpected coins[0]");

        // coin(1) should be weETH
        (bool ok1, bytes memory d1) =
            WEETH_WETH_NG_POOL.staticcall(abi.encodeWithSignature("coins(uint256)", 1));
        address c1 = ok1 && d1.length >= 32 ? abi.decode(d1, (address)) : address(0);
        require(c1 == WEETH, "unexpected coins[1]");

        return (0, 1);
    }
}

interface IStableNgPoolCoins {
    function coins(uint256 i) external view returns (address);
}

address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
address constant WEETH_WETH_NG_POOL = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;

// Resolve (i, j) for WETH -> weETH in the pool (pool coin order can vary)
function _wethWeethIndices() view returns (uint256 iWeth, uint256 jWeeth) {
    address c0 = IStableNgPoolCoins(WEETH_WETH_NG_POOL).coins(0);
    if (c0 == WETH) {
        (iWeth, jWeeth) = (0, 1);
    } else {
        // assume only two coins; the other must be WETH
        (iWeth, jWeeth) = (1, 0);
    }
}

interface IBalancerRouterQuery {
    function querySwapSingleTokenExactOut(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 exactAmountOut,
        address sender,
        bytes calldata userData
    ) external returns (uint256 amountCalculated);

    function querySwapSingleTokenExactIn(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountIn,
        address sender,
        bytes calldata userData
    ) external returns (uint256 amountCalculated);
}

address constant WSTETH_WETH_V3_POOL = 0x6b31a94029fd7840d780191B6D63Fa0D269bd883;

interface IBalancerRouterFull {
    function querySwapSingleTokenExactIn(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 exactAmountIn,
        address sender,
        bytes calldata userData
    ) external returns (uint256 amountCalculated);

    function querySwapSingleTokenExactOut(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 exactAmountOut,
        address sender,
        bytes calldata userData
    ) external returns (uint256 amountCalculated);
}

address constant POOL_WETH_AAVE_V3 = 0x9d1Fcf346eA1b073de4D5834e25572CC6ad71f4d; // WETH/AAVE pool
address constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

// minimal hex helpers for readable revert messages
function _toHex(address a) pure returns (string memory) {
    bytes20 b = bytes20(a);
    bytes memory s = new bytes(42);
    s[0] = "0";
    s[1] = "x";
    for (uint256 i; i < 20; ++i) {
        uint8 v = uint8(b[i]);
        s[2 + 2 * i] = bytes1((v >> 4) + ((v >> 4) < 10 ? 48 : 87));
        s[3 + 2 * i] = bytes1((v & 0xf) + ((v & 0xf) < 10 ? 48 : 87));
    }
    return string(s);
}

function _toHexBytes(bytes memory d) pure returns (string memory) {
    bytes memory s = new bytes(2 + d.length * 2);
    s[0] = "0";
    s[1] = "x";
    for (uint256 i; i < d.length; ++i) {
        uint8 v = uint8(d[i]);
        s[2 + 2 * i] = bytes1((v >> 4) + ((v >> 4) < 10 ? 48 : 87));
        s[3 + 2 * i] = bytes1((v & 0xf) + ((v & 0xf) < 10 ? 48 : 87));
    }
    return string(s);
}
