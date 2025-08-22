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
    function transferFrom(address, address, uint256) external returns (bool);
}

contract zRouterTest is Test {
    uint256 DEADLINE;

    /* ───────────── addresses & constants ───────────── */
    address constant VITALIK = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // V2 pair (USDC, WETH) 0.30 %
    address constant V2_PAIR = 0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C;
    // V3 pool (USDC < WETH) 0.05 %
    address constant V3_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    // two whales we borrow tokens from
    address constant USDC_WHALE = 0x0B0A5886664376F59C351ba3f598C8A8B4D0A6f3;
    address constant WETH_WHALE = 0x07aE8551Be970cB1cCa11Dd7a11F47Ae82e70E67;

    uint256 constant USDC_IN = 100e6; // 100 USDC exact-in for USDC→ETH test
    uint256 constant ETH_IN = 0.05 ether; // 0.05 ETH budget for exact-out test
    uint256 constant USDC_OUT = 50e6; // 50 USDC exact-out target

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

        vm.deal(VITALIK, 1 ether);

        vm.startPrank(VITALIK);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /* ───────────── tests ───────────── */

    /// USDC → ETH on Uniswap V2 (unwrap branch)
    function testUSDCtoETH_V2() public {
        uint256 wethOut = _quoteV2_WethOut(USDC_IN);

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

    /* ───────── V2: ETH → USDC — exact-out ───────── */

    address constant COIN = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    address constant COIN_POOL = 0xE31c372a7Af875b3B5E0F3713B17ef51556da667;

    function testExactIn_ETHtoMemecoin_V2() public {
        (uint112 r0, uint112 r1,) = IUniV2PairReserves(COIN_POOL).getReserves();
        // tokenIn = WETH (r1), tokenOut = USDC (r0)
        uint256 need = _getAmountIn(100 ether, r1, r0);
        uint256 budget = need + 20e15; // add 0.02 ETH slack

        uint256 ethBefore = VITALIK.balance;
        uint256 coinBefore = IERC20(COIN).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapV2{value: budget}(VITALIK, true, address(0), COIN, 100 ether, budget, DEADLINE);

        uint256 ethSpent = ethBefore - VITALIK.balance;
        uint256 coinDelta = IERC20(COIN).balanceOf(VITALIK) - coinBefore;

        assertEq(coinDelta, 100 ether, "COIN exact-out failed");
        assertLt(ethSpent, budget, "no ETH refund");
        assertGt(ethSpent, need - 1, "under-spent");
    }

    function testExactIn_ETHtoMemecoin_Aero() public {
        uint256 coinBefore = IERC20(COIN).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapAero{value: 1 ether}(VITALIK, false, address(0), COIN, 1 ether, 0, DEADLINE);

        uint256 coinDelta = IERC20(COIN).balanceOf(VITALIK) - coinBefore;

        assertGt(coinDelta, 0);
    }

    function testExactIn_ETHtoUSDC_AeroCL() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapAeroCL{value: 1 ether}(
            VITALIK, false, 10, address(0), USDC, 1 ether, 0, DEADLINE
        );

        uint256 coinDelta = IERC20(USDC).balanceOf(VITALIK) - usdcBefore;

        assertGt(coinDelta, 0);
    }

    function testExactOUT_ETHtoUSDC_AeroCL() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        router.swapAeroCL{value: 1 ether}(VITALIK, true, 10, address(0), USDC, 3000e6, 0, DEADLINE);

        uint256 coinDelta = IERC20(USDC).balanceOf(VITALIK) - usdcBefore;

        assertGt(coinDelta, 0);
    }

    function testExactOut_ETHtoUSDC_V2() public {
        (uint112 r0, uint112 r1,) = IUniV2PairReserves(V2_PAIR).getReserves();
        // tokenIn = WETH (r1), tokenOut = USDC (r0)
        uint256 need = _getAmountIn(USDC_OUT, r1, r0);
        uint256 budget = need + 20e15; // add 0.02 ETH slack

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
        uint256 needUsdc = _getAmountIn(0.00000001 ether, r0, r1); // USDC reserve = r0
        uint256 budget = needUsdc + 500e6; // +5 USDC slack

        uint256 ethBefore = VITALIK.balance;

        vm.startPrank(VITALIK);
        IERC20(USDC).approve(address(router), budget);
        router.swapV2(VITALIK, true, USDC, address(0), 0.00000001 ether, budget, DEADLINE);
        vm.stopPrank();

        uint256 ethDelta = VITALIK.balance - ethBefore;
        assertEq(ethDelta, 0.00000001 ether, "ETH exact-out failed");
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
}
