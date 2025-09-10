# IzRouter
[Git Source](https://github.com/zammdefi/zRouter/blob/69617a4a7c4ee7b21900c469f2a65ec825391317/src/IzRouter.sol)


## Functions
### swapV2

Swap tokens on Uniswap V2 or SushiSwap


```solidity
function swapV2(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) external payable returns (uint256 amountIn, uint256 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`to`|`address`|Recipient address|
|`exactOut`|`bool`|Whether this is an exact output swap|
|`tokenIn`|`address`|Input token address (use address(0) for ETH)|
|`tokenOut`|`address`|Output token address (use address(0) for ETH)|
|`swapAmount`|`uint256`|Amount to swap (input amount for exactIn, output amount for exactOut)|
|`amountLimit`|`uint256`|Slippage limit (max input for exactOut, min output for exactIn)|
|`deadline`|`uint256`|Transaction deadline (use type(uint256).max for SushiSwap)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of input tokens used|
|`amountOut`|`uint256`|Amount of output tokens received|


### swapV3

Swap tokens on Uniswap V3


```solidity
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
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`to`|`address`|Recipient address|
|`exactOut`|`bool`|Whether this is an exact output swap|
|`swapFee`|`uint24`|Pool fee tier (500, 3000, 10000, etc.)|
|`tokenIn`|`address`|Input token address (use address(0) for ETH)|
|`tokenOut`|`address`|Output token address (use address(0) for ETH)|
|`swapAmount`|`uint256`|Amount to swap (input amount for exactIn, output amount for exactOut)|
|`amountLimit`|`uint256`|Slippage limit (max input for exactOut, min output for exactIn)|
|`deadline`|`uint256`|Transaction deadline|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of input tokens used|
|`amountOut`|`uint256`|Amount of output tokens received|


### swapV4

Swap tokens on Uniswap V4


```solidity
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
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`to`|`address`|Recipient address|
|`exactOut`|`bool`|Whether this is an exact output swap|
|`swapFee`|`uint24`|Pool fee|
|`tickSpace`|`int24`|Tick spacing for the pool|
|`tokenIn`|`address`|Input token address|
|`tokenOut`|`address`|Output token address|
|`swapAmount`|`uint256`|Amount to swap (input amount for exactIn, output amount for exactOut)|
|`amountLimit`|`uint256`|Slippage limit (max input for exactOut, min output for exactIn)|
|`deadline`|`uint256`|Transaction deadline|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of input tokens used|
|`amountOut`|`uint256`|Amount of output tokens received|


### swapV4Router

Swap through V4 Router with custom calldata (supports hooks and multihops)


```solidity
function swapV4Router(
    bytes calldata data,
    uint256 deadline,
    uint256 ethIn,
    address tokenOut,
    uint256 amountOut
) external payable returns (int256 delta);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`data`|`bytes`|Custom calldata for V4 Router|
|`deadline`|`uint256`|Transaction deadline|
|`ethIn`|`uint256`|Amount of ETH to send|
|`tokenOut`|`address`|Output token address|
|`amountOut`|`uint256`|Expected output amount|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`delta`|`int256`|Balance delta from the swap|


### swapVZ

Swap tokens on zAMM


```solidity
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
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`to`|`address`|Recipient address|
|`exactOut`|`bool`|Whether this is an exact output swap|
|`feeOrHook`|`uint256`|Fee amount or hook address|
|`tokenIn`|`address`|Input token address (use address(0) for ETH)|
|`tokenOut`|`address`|Output token address|
|`idIn`|`uint256`|Input token ID (for ERC6909)|
|`idOut`|`uint256`|Output token ID (for ERC6909)|
|`swapAmount`|`uint256`|Amount to swap (input amount for exactIn, output amount for exactOut)|
|`amountLimit`|`uint256`|Slippage limit (max input for exactOut, min output for exactIn)|
|`deadline`|`uint256`|Transaction deadline (use type(uint256).max for hookless zAMM)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of input tokens used|
|`amountOut`|`uint256`|Amount of output tokens received|


### swapAero

Swap tokens on Aerodrome (V2-style pools)


```solidity
function swapAero(
    address to,
    bool stable,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) external payable returns (uint256 amountIn, uint256 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`to`|`address`|Recipient address|
|`stable`|`bool`|Whether to use stable pool (true) or volatile pool (false)|
|`tokenIn`|`address`|Input token address (use address(0) for ETH)|
|`tokenOut`|`address`|Output token address (use address(0) for ETH)|
|`swapAmount`|`uint256`|Amount of input tokens to swap|
|`amountLimit`|`uint256`|Minimum output amount (slippage protection)|
|`deadline`|`uint256`|Transaction deadline|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of input tokens used|
|`amountOut`|`uint256`|Amount of output tokens received|


### swapAeroCL

Swap tokens on Aerodrome CL (Concentrated Liquidity pools)


```solidity
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
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`to`|`address`|Recipient address|
|`exactOut`|`bool`|Whether this is an exact output swap|
|`tickSpacing`|`int24`|Tick spacing for the pool|
|`tokenIn`|`address`|Input token address (use address(0) for ETH)|
|`tokenOut`|`address`|Output token address (use address(0) for ETH)|
|`swapAmount`|`uint256`|Amount to swap (input amount for exactIn, output amount for exactOut)|
|`amountLimit`|`uint256`|Slippage limit (max input for exactOut, min output for exactIn)|
|`deadline`|`uint256`|Transaction deadline|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amountIn`|`uint256`|Amount of input tokens used|
|`amountOut`|`uint256`|Amount of output tokens received|


### addLiquidity

Add liquidity to a zAMM pool


```solidity
function addLiquidity(
    PoolKey calldata poolKey,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address to,
    uint256 deadline
) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolKey`|`PoolKey`|Pool configuration|
|`amount0Desired`|`uint256`|Desired amount of token0|
|`amount1Desired`|`uint256`|Desired amount of token1|
|`amount0Min`|`uint256`|Minimum amount of token0|
|`amount1Min`|`uint256`|Minimum amount of token1|
|`to`|`address`|Recipient address for LP tokens|
|`deadline`|`uint256`|Transaction deadline|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|Actual amount of token0 added|
|`amount1`|`uint256`|Actual amount of token1 added|
|`liquidity`|`uint256`|Amount of liquidity tokens minted|


### multicall

Execute multiple calls in a single transaction


```solidity
function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`data`|`bytes[]`|Array of encoded function calls|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes[]`|Array of return data from each call|


### deposit

Deposit tokens for use in subsequent operations (transient storage)


```solidity
function deposit(address token, uint256 id, uint256 amount) external payable;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|Token address (use address(0) for ETH)|
|`id`|`uint256`|Token ID (for ERC6909, use 0 for ERC20)|
|`amount`|`uint256`|Amount to deposit|


### ensureAllowance

Set allowances for zAMM and V4 Router


```solidity
function ensureAllowance(address token, bool is6909, bool isRetro) external payable;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|Token address|
|`is6909`|`bool`|Whether token is ERC6909|
|`isRetro`|`bool`|Whether to approve legacy zAMM contract|


### sweep

Transfer tokens or ETH from contract


```solidity
function sweep(address token, uint256 id, uint256 amount, address to) external payable;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|Token address (use address(0) for ETH)|
|`id`|`uint256`|Token ID (for ERC6909, use 0 for ERC20)|
|`amount`|`uint256`|Amount to sweep (use 0 for entire balance)|
|`to`|`address`|Recipient address|


### wrap

Wrap ETH to WETH


```solidity
function wrap(uint256 amount) external payable;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount to wrap (use 0 for entire ETH balance)|


### unwrap

Unwrap WETH to ETH


```solidity
function unwrap(uint256 amount) external payable;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount to unwrap (use 0 for entire WETH balance)|


### uniswapV3SwapCallback

V3-style swap callback for Uniswap V3 and Aerodrome CL


```solidity
function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
    external
    payable;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount0Delta`|`int256`|Amount of token0 owed to the pool|
|`amount1Delta`|`int256`|Amount of token1 owed to the pool|
|`data`|`bytes`|Encoded callback data|


## Errors
### BadSwap

```solidity
error BadSwap();
```

### Expired

```solidity
error Expired();
```

### Slippage

```solidity
error Slippage();
```

### InvalidId

```solidity
error InvalidId();
```

### Unauthorized

```solidity
error Unauthorized();
```

### InvalidMsgVal

```solidity
error InvalidMsgVal();
```

### SwapExactInFail

```solidity
error SwapExactInFail();
```

### SwapExactOutFail

```solidity
error SwapExactOutFail();
```

### ETHTransferFailed

```solidity
error ETHTransferFailed();
```

