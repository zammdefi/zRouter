// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IzRouter {
    // ══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ══════════════════════════════════════════════════════════════════════════════
    
    error BadSwap();
    error Expired();
    error Slippage();
    error InvalidId();
    error Unauthorized();
    error InvalidMsgVal();
    error SwapExactInFail();
    error SwapExactOutFail();
    error ETHTransferFailed();

    // ══════════════════════════════════════════════════════════════════════════════
    // SWAP FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════════

    /// @notice Swap tokens on Uniswap V2 or SushiSwap
    /// @param to Recipient address
    /// @param exactOut Whether this is an exact output swap
    /// @param tokenIn Input token address (use address(0) for ETH)
    /// @param tokenOut Output token address (use address(0) for ETH)
    /// @param swapAmount Amount to swap (input amount for exactIn, output amount for exactOut)
    /// @param amountLimit Slippage limit (max input for exactOut, min output for exactIn)
    /// @param deadline Transaction deadline (use type(uint256).max for SushiSwap)
    /// @return amountIn Amount of input tokens used
    /// @return amountOut Amount of output tokens received
    function swapV2(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    /// @notice Swap tokens on Uniswap V3
    /// @param to Recipient address
    /// @param exactOut Whether this is an exact output swap
    /// @param swapFee Pool fee tier (500, 3000, 10000, etc.)
    /// @param tokenIn Input token address (use address(0) for ETH)
    /// @param tokenOut Output token address (use address(0) for ETH)
    /// @param swapAmount Amount to swap (input amount for exactIn, output amount for exactOut)
    /// @param amountLimit Slippage limit (max input for exactOut, min output for exactIn)
    /// @param deadline Transaction deadline
    /// @return amountIn Amount of input tokens used
    /// @return amountOut Amount of output tokens received
    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    /// @notice Swap tokens on Uniswap V4
    /// @param to Recipient address
    /// @param exactOut Whether this is an exact output swap
    /// @param swapFee Pool fee
    /// @param tickSpace Tick spacing for the pool
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param swapAmount Amount to swap (input amount for exactIn, output amount for exactOut)
    /// @param amountLimit Slippage limit (max input for exactOut, min output for exactIn)
    /// @param deadline Transaction deadline
    /// @return amountIn Amount of input tokens used
    /// @return amountOut Amount of output tokens received
    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    /// @notice Swap through V4 Router with custom calldata (supports hooks and multihops)
    /// @param data Custom calldata for V4 Router
    /// @param deadline Transaction deadline
    /// @param ethIn Amount of ETH to send
    /// @param tokenOut Output token address
    /// @param amountOut Expected output amount
    /// @return delta Balance delta from the swap
    function swapV4Router(
        bytes calldata data,
        uint256 deadline,
        uint256 ethIn,
        address tokenOut,
        uint256 amountOut
    ) external payable returns (int256 delta);

    /// @notice Swap tokens on zAMM
    /// @param to Recipient address
    /// @param exactOut Whether this is an exact output swap
    /// @param feeOrHook Fee amount or hook address
    /// @param tokenIn Input token address (use address(0) for ETH)
    /// @param tokenOut Output token address
    /// @param idIn Input token ID (for ERC6909)
    /// @param idOut Output token ID (for ERC6909)
    /// @param swapAmount Amount to swap (input amount for exactIn, output amount for exactOut)
    /// @param amountLimit Slippage limit (max input for exactOut, min output for exactIn)
    /// @param deadline Transaction deadline (use type(uint256).max for hookless zAMM)
    /// @return amountIn Amount of input tokens used
    /// @return amountOut Amount of output tokens received
    function swapVZ(
        address to,
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    // ══════════════════════════════════════════════════════════════════════════════
    // AERODROME FUNCTIONS (Base Chain Only)
    // ══════════════════════════════════════════════════════════════════════════════

    /// @notice Swap tokens on Aerodrome (V2-style pools)
    /// @param to Recipient address
    /// @param stable Whether to use stable pool (true) or volatile pool (false)
    /// @param tokenIn Input token address (use address(0) for ETH)
    /// @param tokenOut Output token address (use address(0) for ETH)
    /// @param swapAmount Amount of input tokens to swap
    /// @param amountLimit Minimum output amount (slippage protection)
    /// @param deadline Transaction deadline
    /// @return amountIn Amount of input tokens used
    /// @return amountOut Amount of output tokens received
    function swapAero(
        address to,
        bool stable,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    /// @notice Swap tokens on Aerodrome CL (Concentrated Liquidity pools)
    /// @param to Recipient address
    /// @param exactOut Whether this is an exact output swap
    /// @param tickSpacing Tick spacing for the pool
    /// @param tokenIn Input token address (use address(0) for ETH)
    /// @param tokenOut Output token address (use address(0) for ETH)
    /// @param swapAmount Amount to swap (input amount for exactIn, output amount for exactOut)
    /// @param amountLimit Slippage limit (max input for exactOut, min output for exactIn)
    /// @param deadline Transaction deadline
    /// @return amountIn Amount of input tokens used
    /// @return amountOut Amount of output tokens received
    function swapAeroCL(
        address to,
        bool exactOut,
        int24 tickSpacing,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    // ══════════════════════════════════════════════════════════════════════════════
    // LIQUIDITY FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════════

    /// @notice Add liquidity to a zAMM pool
    /// @param poolKey Pool configuration
    /// @param amount0Desired Desired amount of token0
    /// @param amount1Desired Desired amount of token1
    /// @param amount0Min Minimum amount of token0
    /// @param amount1Min Minimum amount of token1
    /// @param to Recipient address for LP tokens
    /// @param deadline Transaction deadline
    /// @return amount0 Actual amount of token0 added
    /// @return amount1 Actual amount of token1 added
    /// @return liquidity Amount of liquidity tokens minted
    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    // ══════════════════════════════════════════════════════════════════════════════
    // UTILITY FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════════

    /// @notice Execute multiple calls in a single transaction
    /// @param data Array of encoded function calls
    /// @return Array of return data from each call
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);

    /// @notice Deposit tokens for use in subsequent operations (transient storage)
    /// @param token Token address (use address(0) for ETH)
    /// @param id Token ID (for ERC6909, use 0 for ERC20)
    /// @param amount Amount to deposit
    function deposit(address token, uint256 id, uint256 amount) external payable;

    /// @notice Set allowances for zAMM and V4 Router
    /// @param token Token address
    /// @param is6909 Whether token is ERC6909
    /// @param isRetro Whether to approve legacy zAMM contract
    function ensureAllowance(address token, bool is6909, bool isRetro) external payable;

    /// @notice Transfer tokens or ETH from contract
    /// @param token Token address (use address(0) for ETH)
    /// @param id Token ID (for ERC6909, use 0 for ERC20)
    /// @param amount Amount to sweep (use 0 for entire balance)
    /// @param to Recipient address
    function sweep(address token, uint256 id, uint256 amount, address to) external payable;

    /// @notice Wrap ETH to WETH
    /// @param amount Amount to wrap (use 0 for entire ETH balance)
    function wrap(uint256 amount) external payable;

    /// @notice Unwrap WETH to ETH
    /// @param amount Amount to unwrap (use 0 for entire WETH balance)
    function unwrap(uint256 amount) external payable;

    // ══════════════════════════════════════════════════════════════════════════════
    // V4 CALLBACK
    // ══════════════════════════════════════════════════════════════════════════════

    /// @notice V3-style swap callback for Uniswap V3 and Aerodrome CL
    /// @param amount0Delta Amount of token0 owed to the pool
    /// @param amount1Delta Amount of token1 owed to the pool
    /// @param data Encoded callback data
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external payable;
}

// ══════════════════════════════════════════════════════════════════════════════
// STRUCTS (for reference)
// ══════════════════════════════════════════════════════════════════════════════

struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook;
}

struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct V4SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}
