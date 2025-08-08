// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/console2.sol";
import "@solady/test/utils/mocks/MockERC20.sol";
import "@solady/test/utils/mocks/MockERC6909.sol";

import {zRouter} from "../src/zRouter.sol";

interface IV2 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        external
        pure
        returns (uint256 amountB);
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn);
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    function WETH9() external view returns (address);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);
}

struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook;
}

interface IZAMM {
    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);
}

type BalanceDelta is int256;

struct UniPoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct PathKey {
    address intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
    bytes hookData;
}

interface IV4router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        UniPoolKey calldata poolKey,
        bytes calldata hookData,
        address receiver,
        uint256 deadline
    ) external payable returns (BalanceDelta);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address startCurrency,
        PathKey[] calldata path,
        address receiver,
        uint256 deadline
    ) external payable returns (BalanceDelta);
}

interface IUSDTApprove {
    function approve(address, uint256) external;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract ZRouterBenchTest is Test {
    IV2 constant v2 = IV2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IV3SwapRouter constant v3Router = IV3SwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    INonfungiblePositionManager constant positionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    IV4router constant v4router = IV4router(0x00000000000044a361Ae3cAc094c9D1b14Eece97);

    zRouter constant router = zRouter(payable(0x0000000000999e93e27973C9EC7298b5DBE7d7A0));
    IZAMM constant zamm = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    address constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant ben = 0x91364516D3CAD16E1666261dbdbb39c881Dbe9eE;
    address constant usdcWhale = 0x59a0f98345f54bAB245A043488ECE7FCecD7B596;

    // Universal Router & Permit2 (Ethereum mainnet)
    IUniversalRouter constant UR = IUniversalRouter(0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B);
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    MockERC20 erc20;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main")); // Ethereum mainnet fork.
        erc20 = new MockERC20("TEST", "TEST", 18);
        erc20.mint(ben, 1_000_000 ether);
        erc20.mint(usdcWhale, 1_000_000 ether);

        // Approvals
        vm.startPrank(ben);
        erc20.approve(address(router), type(uint256).max);
        erc20.approve(address(zamm), type(uint256).max);
        erc20.approve(address(v2), type(uint256).max);
        erc20.approve(address(v3Router), type(uint256).max);
        MockERC20(usdc).approve(address(v3Router), type(uint256).max);
        MockERC20(usdc).approve(address(positionManager), type(uint256).max);
        erc20.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(ben);

        // 1) Let Permit2 be able to call transferFrom on the token
        MockERC20(address(erc20)).approve(PERMIT2, type(uint256).max);

        // 2) Give Universal Router an allowance in Permit2 (non-expiring or long-dated)
        IAllowanceTransfer(PERMIT2).approve(
            address(erc20),
            address(UR),
            type(uint160).max,
            uint48(block.timestamp + 365 days) // or type(uint48).max - 1
        );

        vm.stopPrank();

        // Setup ZAMM pool (eth <> mock20)
        vm.prank(ben);
        zamm.addLiquidity{value: 10 ether}(
            PoolKey(0, 0, address(0), address(erc20), 30),
            10 ether,
            10_000 ether,
            0,
            0,
            ben,
            block.timestamp
        );
        vm.stopPrank();

        // Setup ZAMM usdc pools
        vm.startPrank(usdcWhale);
        MockERC20(erc20).approve(address(zamm), type(uint256).max);
        MockERC20(erc20).approve(address(router), type(uint256).max);
        MockERC20(erc20).approve(address(v2), type(uint256).max);
        MockERC20(usdc).approve(address(zamm), type(uint256).max);
        MockERC20(usdc).approve(address(router), type(uint256).max);
        MockERC20(usdc).approve(address(v2), type(uint256).max);
        IUSDTApprove(usdt).approve(address(v4router), type(uint256).max);
        MockERC20(usdc).approve(address(v4router), type(uint256).max);
        zamm.addLiquidity{value: 10 ether}(
            PoolKey(0, 0, address(0), usdc, 1),
            10 ether,
            10_000 * 1e6,
            0,
            0,
            usdcWhale,
            block.timestamp
        ); // warm up pool
        zamm.swapExactIn{value: 0.01 ether}(
            PoolKey(0, 0, address(0), usdc, 1), 0.01 ether, 0, true, usdcWhale, block.timestamp
        );

        (address token0, address token1) =
            usdc < address(erc20) ? (usdc, address(erc20)) : (address(erc20), usdc);

        zamm.addLiquidity(
            PoolKey(0, 0, token0, token1, 100),
            10 ether,
            10_000 * 1e6,
            0,
            0,
            usdcWhale,
            block.timestamp
        );
        vm.stopPrank();

        // Setup V2 pools
        vm.prank(usdcWhale);
        v2.addLiquidity(token0, token1, 10 ether, 10_000 * 1e6, 0, 0, usdcWhale, block.timestamp);

        vm.prank(ben);
        v2.addLiquidityETH{value: 10 ether}(
            address(erc20), 10_000 ether, 0, 0, ben, block.timestamp
        );

        vm.startPrank(usdcWhale);
        MockERC20(usdc).approve(address(v3Router), type(uint256).max);
        MockERC20(erc20).approve(address(v3Router), type(uint256).max);
        MockERC20(usdc).approve(address(positionManager), type(uint256).max);
        MockERC20(erc20).approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // Setup V3 pool - first we need to initialize the pool
        uint24 fee = 3000; // 0.3% fee tier

        // We need to sort the tokens by address to match Uniswap's convention
        token0 = address(erc20) < weth ? address(erc20) : weth;
        token1 = address(erc20) < weth ? weth : address(erc20);

        // Initial price - assuming 1 ETH = 1000 TEST tokens
        // Calculating sqrt price (P)
        // sqrtPriceX96 = sqrt(P) * 2^96
        uint160 sqrtPriceX96 = address(erc20) < weth
            ? 79228162514264337593543950336 // If TEST is token0, price = 1/1000
            : 2505414483750479311864138677; // If WETH is token0, price = 1000

        vm.prank(ben);
        try positionManager.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96) {
            // Pool created successfully
        } catch {
            // Pool might already exist, which is fine
        }

        // Define a wide price range for liquidity
        int24 tickLower = -887220; // Min tick for full range
        int24 tickUpper = 887220; // Max tick for full range

        // Add liquidity to V3 pool
        vm.prank(ben);
        try positionManager.mint{value: 10 ether}(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: address(erc20) < weth ? 10_000 ether : 10 ether,
                amount1Desired: address(erc20) < weth ? 10 ether : 10_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: ben,
                deadline: block.timestamp
            })
        ) {
            // Liquidity added successfully
        } catch {
            // In case of failure, we'll continue with the test
            // The test may use existing liquidity or fail later if there's no liquidity
        }

        // Now set up the USDC <> ERC20 pool for V3
        token0 = address(erc20) < usdc ? address(erc20) : usdc;
        token1 = address(erc20) < usdc ? usdc : address(erc20);

        // Initial price - assuming 1 ERC20 = 1 USDC (for simplicity)
        sqrtPriceX96 = address(erc20) < usdc
            ? 79228162514264337593543950336 // price = 1
            : 79228162514264337593543950336; // price = 1

        vm.prank(usdcWhale);
        try positionManager.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96) {
            // Pool created successfully
        } catch {
            // Pool might already exist, which is fine
        }

        // Add liquidity to USDC <> ERC20 V3 pool
        vm.prank(usdcWhale);
        try positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: address(erc20) < usdc ? 10_000 ether : 10_000 * 1e6,
                amount1Desired: address(erc20) < usdc ? 10_000 * 1e6 : 10_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: usdcWhale,
                deadline: block.timestamp
            })
        ) {
            // Liquidity added successfully
        } catch {
            // In case of failure, we'll continue with the test
        }
    }

    function testV2SingleExactInEthForToken() public {
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(erc20);

        vm.prank(ben);
        v2.swapExactETHForTokens{value: 0.1 ether}(0, path, ben, block.timestamp);
    }

    function testV2SingleExactOutEthForToken() public {
        address[] memory path = new address[](2);
        path[0] = address(erc20);
        path[1] = weth;

        vm.prank(ben);
        v2.swapTokensForExactETH(0.1 ether, 1_000_000 ether, path, ben, block.timestamp);
    }

    function testV2SingleExactInTokenForEth() public {
        address[] memory path = new address[](2);
        path[0] = address(erc20);
        path[1] = weth;

        vm.prank(ben);
        v2.swapExactTokensForETH(100 ether, 0, path, ben, block.timestamp);
    }

    function testV2SingleExactOutTokenForEth() public {
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(erc20);

        vm.prank(ben);
        v2.swapETHForExactTokens{value: 0.1 ether}(90 ether, path, ben, block.timestamp);
    }

    function testV2SingleExactInTokenForToken() public {
        address[] memory path = new address[](2);
        path[0] = address(erc20);
        path[1] = usdc;

        vm.prank(ben);
        v2.swapExactTokensForTokens(100 ether, 0, path, ben, block.timestamp);
    }

    function testV2SingleExactOutTokenForToken() public {
        address[] memory path = new address[](2);
        path[0] = address(erc20);
        path[1] = usdc;

        vm.prank(ben);
        v2.swapTokensForExactTokens(30e6, 100 ether, path, ben, block.timestamp);
    }

    function testV2MultiExactInTokensForEthForUsdc() public {
        address[] memory path = new address[](3);
        path[0] = address(erc20);
        path[1] = weth;
        path[2] = usdc;

        vm.prank(ben);
        v2.swapExactTokensForTokens(100 ether, 0, path, ben, block.timestamp);
    }

    function testV2MultiExactInTokensForUsdcForEth() public {
        address[] memory path = new address[](3);
        path[0] = address(erc20);
        path[1] = usdc;
        path[2] = weth;

        vm.prank(ben);
        v2.swapExactTokensForETH(100 ether, 0, path, ben, block.timestamp);
    }

    function testV2SingleExactInEthForTokenZrouter() public {
        vm.prank(ben);
        router.swapV2{value: 0.1 ether}(
            ben, false, address(0), address(erc20), 0.1 ether, 0, block.timestamp
        );
    }

    function testV2SingleExactInTokenForEthZrouter() public {
        vm.prank(ben);
        router.swapV2(ben, false, address(erc20), address(0), 100 ether, 0, block.timestamp);
    }

    function testV2SingleExactInTokenForTokenZrouter() public {
        vm.prank(ben);
        router.swapV2(ben, false, address(erc20), usdc, 100 ether, 0, block.timestamp);
    }

    function testV2SingleExactOutEthForTokenZrouter() public {
        vm.prank(ben);
        router.swapV2(
            ben, true, address(erc20), address(0), 0.0888 ether, 101 ether, block.timestamp
        );
    }

    function testV2SingleExactOutTokenForEthZrouter() public {
        vm.prank(ben);
        router.swapV2{value: 0.1 ether}(
            ben, true, address(0), address(erc20), 90 ether, 0.1 ether, block.timestamp
        );
    }

    function testV2SingleExactOutTokenForTokenZrouter() public {
        vm.prank(ben);
        router.swapV2(ben, true, address(erc20), usdc, 30e6, 100 ether, block.timestamp);
    }

    address constant v2UsdcWethPool = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;

    function testV2MultiExactInTokensForEthForUsdcZrouter() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.swapV2.selector, // target next pool as `to` for z swap
            v2UsdcWethPool,
            false,
            address(erc20),
            weth,
            100 ether,
            0,
            block.timestamp
        );
        calls[1] = abi.encodeWithSelector(
            router.swapV2.selector, ben, false, weth, usdc, 0.0888 ether, 0, block.timestamp
        );
        vm.prank(ben);
        router.multicall(calls);
    }

    function testV2MultiExactInTokensForUsdcForEthZrouter() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.swapV2.selector, // target next pool as `to` for z swap
            v2UsdcWethPool,
            false,
            address(erc20),
            usdc,
            100 ether,
            0,
            block.timestamp
        );
        calls[1] = abi.encodeWithSelector(
            router.swapV2.selector, ben, false, usdc, weth, 100e6, 0, block.timestamp
        );
        vm.prank(ben);
        router.multicall(calls);
    }

    function testV3SingleExactInEthForToken() public {
        vm.prank(ben);

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: weth,
            tokenOut: address(erc20),
            fee: 3000, // 0.3% fee tier
            recipient: ben,
            deadline: block.timestamp,
            amountIn: 0.1 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        v3Router.exactInputSingle{value: 0.1 ether}(params);
    }

    function testV3SingleExactOutTokenForEth() public {
        vm.prank(ben);

        IV3SwapRouter.ExactOutputSingleParams memory params = IV3SwapRouter.ExactOutputSingleParams({
            tokenIn: weth,
            tokenOut: address(erc20),
            fee: 3000, // 0.3% fee tier
            recipient: ben,
            deadline: block.timestamp,
            amountOut: 0.09 ether,
            amountInMaximum: 0.1 ether,
            sqrtPriceLimitX96: 0
        });

        v3Router.exactOutputSingle{value: 0.1 ether}(params);
    }

    function multicall(bytes[] calldata) public returns (bytes[] memory) {}
    function unwrapWETH9(uint256, address) public {}

    function testV3SingleExactInTokenForEth() public {
        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: address(erc20),
            tokenOut: weth,
            fee: 3000, // 0.3% fee tier
            recipient: address(v3Router),
            deadline: block.timestamp,
            amountIn: 100 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(v3Router.exactInputSingle.selector, params);
        calls[1] = abi.encodeWithSelector(this.unwrapWETH9.selector, 0, ben);
        vm.prank(ben);
        ZRouterBenchTest(address(v3Router)).multicall(calls);
    }

    function testV3SingleExactOutEthForToken() public {
        IV3SwapRouter.ExactOutputSingleParams memory params = IV3SwapRouter.ExactOutputSingleParams({
            tokenIn: address(erc20),
            tokenOut: weth,
            fee: 3000, // 0.3% fee tier
            recipient: address(v3Router),
            deadline: block.timestamp,
            amountOut: 0.1 ether,
            amountInMaximum: 101 ether,
            sqrtPriceLimitX96: 0
        });

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(v3Router.exactOutputSingle.selector, params);
        calls[1] = abi.encodeWithSelector(this.unwrapWETH9.selector, 0, ben);
        vm.prank(ben);
        ZRouterBenchTest(address(v3Router)).multicall(calls);
    }

    function testV3SingleExactInTokenForUsdc() public {
        vm.prank(ben);

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: address(erc20),
            tokenOut: usdc,
            fee: 3000, // 0.3% fee tier
            recipient: ben,
            deadline: block.timestamp,
            amountIn: 100 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        v3Router.exactInputSingle(params);
    }

    function testV3SingleExactOutUsdcForToken() public {
        vm.prank(ben);

        IV3SwapRouter.ExactOutputSingleParams memory params = IV3SwapRouter.ExactOutputSingleParams({
            tokenIn: address(erc20),
            tokenOut: usdc,
            fee: 3000, // 0.3% fee tier
            recipient: ben,
            deadline: block.timestamp,
            amountOut: 30e6,
            amountInMaximum: 100 ether,
            sqrtPriceLimitX96: 0
        });

        v3Router.exactOutputSingle(params);
    }

    function testV3SingleExactInEthForTokenZrouter() public {
        vm.prank(ben);
        router.swapV3{value: 0.1 ether}(
            ben, false, 3000, address(0), address(erc20), 0.1 ether, 0, block.timestamp
        );
    }

    function testV3SingleExactOutTokenForEthZRouter() public {
        vm.prank(ben);
        router.swapV3{value: 0.1 ether}(
            ben, true, 3000, address(0), address(erc20), 0.09 ether, 0.1 ether, block.timestamp
        );
    }

    function testV3SingleExactInTokenForEthZrouter() public {
        vm.prank(ben);
        router.swapV3(ben, false, 3000, address(erc20), address(0), 100 ether, 0, block.timestamp);
    }

    function testV3SingleExactOutEthForTokenZrouter() public {
        vm.prank(ben);
        router.swapV3(
            ben, true, 3000, address(erc20), address(0), 0.1 ether, 101 ether, block.timestamp
        );
    }

    function testV3SingleExactInTokenForUsdcZrouter() public {
        vm.prank(ben);
        router.swapV3(ben, false, 3000, address(erc20), usdc, 100 ether, 0, block.timestamp);
    }

    function testV3SingleExactOutUsdcForTokenZrouter() public {
        vm.prank(ben);
        router.swapV3(ben, true, 3000, address(erc20), usdc, 30e6, 100 ether, block.timestamp);
    }

    function testV3MultiExactInEthForTokenForUsdc() public {
        vm.prank(ben);

        // For V3 multihop, we need to encode the path: ETH -> ERC20 -> USDC
        // The format is (token0, fee, token1, fee, token2)
        bytes memory path = abi.encodePacked(
            weth, // First token in the path (WETH)
            uint24(3000), // Fee for first pair (WETH-ERC20)
            address(erc20), // Second token in the path (ERC20)
            uint24(3000), // Fee for second pair (ERC20-USDC)
            usdc // Final token in the path (USDC)
        );

        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams({
            path: path,
            recipient: ben,
            deadline: block.timestamp,
            amountIn: 0.1 ether,
            amountOutMinimum: 0
        });

        v3Router.exactInput{value: 0.1 ether}(params);
    }

    function testV3MultiExactInTokenForUsdcForEth() public {
        bytes memory path = abi.encodePacked(address(erc20), uint24(3000), weth, uint24(3000), usdc);

        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams({
            path: path,
            recipient: ben,
            deadline: block.timestamp,
            amountIn: 100 ether,
            amountOutMinimum: 0
        });

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(v3Router.exactInput.selector, params);
        calls[1] = abi.encodeWithSelector(this.unwrapWETH9.selector, 0, ben);
        vm.prank(ben);
        ZRouterBenchTest(address(v3Router)).multicall(calls);
    }

    function testV3MultiExactInEthForTokenForUsdcZrouter() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.swapV3.selector,
            address(router), // fund router itself for middle
            false,
            3000,
            address(0),
            address(erc20),
            0.1 ether,
            0,
            block.timestamp
        );
        calls[1] = abi.encodeWithSelector(
            router.swapV3.selector,
            ben,
            false,
            3000,
            address(erc20),
            usdc,
            90 ether,
            0,
            block.timestamp
        );
        vm.prank(ben);
        router.multicall{value: 0.1 ether}(calls);
    }

    function testV3MultiExactInTokenForUsdcForEthZrouter() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.swapV3.selector,
            address(router), // fund router itself for middle
            false,
            3000,
            address(erc20),
            usdc,
            100 ether,
            0,
            block.timestamp
        );
        calls[1] = abi.encodeWithSelector(
            router.swapV3.selector, ben, false, 3000, usdc, address(0), 30e6, 0, block.timestamp
        );
        vm.prank(ben);
        router.multicall(calls);
    }

    function testV4SingleExactInEthToUsdc() public {
        vm.prank(usdcWhale);
        UniPoolKey memory poolKey = UniPoolKey(address(0), usdc, 500, 10, address(0));
        v4router.swapExactTokensForTokens{value: 0.1 ether}(
            0.1 ether, 0, true, poolKey, "", usdcWhale, block.timestamp
        );
    }

    function testV4SingleExactInEthToUsdcZrouter() public {
        vm.prank(usdcWhale);
        router.swapV4{value: 0.1 ether}(
            usdcWhale, false, 500, 10, address(0), usdc, 0.1 ether, 0, block.timestamp
        );
    }

    function testV4MultihopExactInEthToUsdcToUsdt() public {
        vm.prank(usdcWhale);

        // Create a path for the multi-hop swap (ETH → USDC → USDT)
        PathKey[] memory path = new PathKey[](2);

        // First hop: ETH → USDC
        path[0] = PathKey({
            intermediateCurrency: usdc, // First target is USDC
            fee: 500, // Fee for ETH-USDC pool
            tickSpacing: 10, // TickSpacing for ETH-USDC pool
            hooks: address(0),
            hookData: ""
        });

        // Second hop: USDC → USDT
        path[1] = PathKey({
            intermediateCurrency: usdt, // Final target is USDT
            fee: 100, // Fee for USDC-USDT pool
            tickSpacing: 1, // TickSpacing for USDC-USDT pool
            hooks: address(0),
            hookData: ""
        });

        // Execute the swap
        v4router.swapExactTokensForTokens{value: 0.1 ether}(
            0.1 ether, // amountIn
            0, // amountOutMin (no minimum)
            address(0), // startCurrency (ETH)
            path, // path through USDC to USDT
            usdcWhale, // receiver
            block.timestamp // deadline
        );
    }

    function testV4MultihopExactInEthToUsdcToUsdtZrouter() public {
        vm.prank(usdcWhale);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.swapV4.selector,
            address(router), // fund router itself for middle
            false,
            500,
            10,
            address(0),
            usdc,
            0.1 ether,
            0,
            block.timestamp
        );
        calls[1] = abi.encodeWithSelector(
            router.swapV4.selector, ben, false, 100, 1, usdc, usdt, 30e6, 0, block.timestamp
        );
        router.multicall{value: 0.1 ether}(calls);
    }

    // ** UNIVERSAL ROUTER BENCH

    function testV2toV3_ExactIn_UR() public {
        // --- V2 path: ERC20 -> WETH
        address[] memory v2Path = new address[](2);
        v2Path[0] = address(erc20);
        v2Path[1] = weth;

        uint256 amountInErc20 = 100 ether;
        uint256 wethFromV2 = v2.getAmountsOut(amountInErc20, v2Path)[1];

        // --- V3 path: WETH -> USDC (fee 0.3%)
        bytes memory v3Path = abi.encodePacked(weth, uint24(3000), usdc);

        // commands: 0x08 = V2_SWAP_EXACT_IN, 0x00 = V3_SWAP_EXACT_IN
        bytes memory commands = hex"0800";

        // inputs for the two commands
        bytes[] memory inputs = new bytes[](2);

        // V2_SWAP_EXACT_IN(recipient, amountIn, amountOutMin, address[] path, payerIsUser)
        inputs[0] = abi.encode(
            address(UR), // send WETH to UR so next step can spend it
            amountInErc20,
            0,
            v2Path,
            true // payerIsUser = pull ERC20 from ben via Permit2
        );

        // V3_SWAP_EXACT_IN(recipient, amountIn, amountOutMin, bytes path, payerIsUser)
        inputs[1] = abi.encode(
            ben, // final recipient
            wethFromV2, // spend what V2 produced
            0,
            v3Path,
            false // payerIsUser = false (spend router-held WETH)
        );

        vm.prank(ben);
        UR.execute(commands, inputs, block.timestamp);
    }

    function testV3toV2_ExactIn_UR() public {
        // --- V3 path: ERC20 -> WETH (fee 0.3%)
        bytes memory v3Path = abi.encodePacked(address(erc20), uint24(3000), weth);

        uint256 amountInErc20 = 100 ether;

        // We'll estimate hop2 amountOut using a placeholder WETH amount; in practice use QuoterV2 for V3
        uint256 wethFromV3 = 0.1 ether; // placeholder, replace with real quote if needed

        // --- V2 path: WETH -> USDC
        address[] memory v2Path = new address[](2);
        v2Path[0] = weth;
        v2Path[1] = usdc;

        // commands: 0x00 = V3_SWAP_EXACT_IN, 0x08 = V2_SWAP_EXACT_IN
        bytes memory commands = hex"0008";

        // inputs for the two commands
        bytes[] memory inputs = new bytes[](2);

        // V3_SWAP_EXACT_IN(recipient, amountIn, amountOutMin, bytes path, payerIsUser)
        inputs[0] = abi.encode(
            address(UR), // send WETH to UR so next step can spend it
            amountInErc20, // ERC20 in
            0, // minOut
            v3Path, // path: ERC20 -> WETH
            true // payerIsUser = pull ERC20 from ben via Permit2
        );

        // V2_SWAP_EXACT_IN(recipient, amountIn, amountOutMin, address[] path, payerIsUser)
        inputs[1] = abi.encode(
            ben, // final recipient
            wethFromV3, // WETH from hop 1
            0, // minOut
            v2Path, // path: WETH -> USDC
            false // payerIsUser = false (spend router-held WETH)
        );

        vm.prank(ben);
        UR.execute(commands, inputs, block.timestamp);
    }

    function testV2toV3_ExactIn_ZR() public {
        // --- Hop 1 estimate on V2: ERC20 -> WETH (same amount as ETH)
        address[] memory v2Path = new address[](2);
        v2Path[0] = address(erc20);
        v2Path[1] = weth;

        uint256 amountInErc20 = 100 ether;
        uint256 ethFromV2 = v2.getAmountsOut(amountInErc20, v2Path)[1];

        // --- Build zRouter multicall: V2 exact-in, then V3 exact-in
        bytes[] memory calls = new bytes[](2);

        // V2 exact-in: send ETH to the router so the next call can spend it
        calls[0] = abi.encodeWithSelector(
            router.swapV2.selector,
            address(router), // recipient = router (intermediate)
            false, // exactOut = false (exact-in)
            address(erc20), // tokenIn
            weth, // tokenOut = ETH
            amountInErc20, // amountIn
            0, // amountOutMin
            block.timestamp
        );

        // V3 exact-in (fee 3000): spend that ETH to buy USDC for ben
        calls[1] = abi.encodeWithSelector(
            router.swapV3.selector,
            ben, // final recipient
            false, // exactOut = false (exact-in)
            uint24(3000), // fee
            weth, // tokenIn = ETH
            usdc, // tokenOut
            ethFromV2, // amountIn = exact ETH from hop 1
            0, // minOut
            block.timestamp
        );

        vm.prank(ben);
        router.multicall(calls);
    }

    function testV3toV2_ExactIn_ZR() public {
        uint256 amountInErc20 = 100 ether;

        // We'll estimate hop2 amountIn using a placeholder WETH amount;
        // in practice use a V3 Quoter, but keeping it simple like comparison test:
        uint256 wethFromV3 = 0.1 ether;

        // --- Build zRouter multicall: V3 exact-in, then V2 exact-in
        bytes[] memory calls = new bytes[](2);

        // V3 exact-in: ERC20 -> WETH, send WETH to v2 so next call can spend it
        calls[0] = abi.encodeWithSelector(
            router.swapV3.selector,
            v2UsdcWethPool, // recipient = v2pool (intermediate)
            false, // exactOut = false (exact-in)
            uint24(3000), // fee
            address(erc20), // tokenIn
            weth, // tokenOut (WETH)
            amountInErc20, // amountIn
            0, // minOut
            block.timestamp
        );

        // V2 exact-in: WETH -> USDC, spend the router-held WETH for ben
        calls[1] = abi.encodeWithSelector(
            router.swapV2.selector,
            ben, // final recipient
            false, // exactOut = false (exact-in)
            weth, // tokenIn (WETH)
            usdc, // tokenOut
            wethFromV3, // amountIn from hop 1 (placeholder)
            0, // minOut
            block.timestamp
        );

        vm.prank(ben);
        router.multicall(calls);
    }
}
