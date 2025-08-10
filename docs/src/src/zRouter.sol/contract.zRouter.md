# zRouter
[Git Source](https://github.com/zammdefi/zRouter/blob/15c5fb7442065a88b0c255094f10ebd47b711ccb/src/zRouter.sol)

*uniV2 / uniV3 / uniV4 / zAMM
multi-amm multi-call router
optimized with simple abi.*


## Functions
### checkDeadline


```solidity
modifier checkDeadline(uint256 deadline);
```

### constructor


```solidity
constructor() payable;
```

### swapV2


```solidity
function swapV2(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut);
```

### swapV3


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
) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut);
```

### fallback

*`uniswapV3SwapCallback`.*


```solidity
fallback() external payable;
```

### swapV4


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
) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut);
```

### unlockCallback

*Handle V4 PoolManager swap callback - hookless default.*


```solidity
function unlockCallback(bytes calldata callbackData) public payable returns (bytes memory result);
```

### _swap


```solidity
function _swap(uint256 swapAmount, V4PoolKey memory key, bool zeroForOne, bool exactOut)
    internal
    returns (int256 delta);
```

### swapVZ

*Pull in full and refund excess against zAMM.*


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
) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut);
```

### addLiquidity

*To be called following deposit() or other swaps in sequence.*


```solidity
function addLiquidity(
    PoolKey calldata poolKey,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address to,
    uint256 deadline
) public payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);
```

### ensureAllowance

*Allows remote pulls by zAMM for swapZAMM() calls.*


```solidity
function ensureAllowance(address token, bool is6909, bool isRetro) public payable;
```

### multicall


```solidity
function multicall(bytes[] calldata data) public payable returns (bytes[] memory);
```

### deposit


```solidity
function deposit(address token, uint256 id, uint256 amount) public payable;
```

### _useTransientBalance


```solidity
function _useTransientBalance(address user, address token, uint256 id, uint256 amount)
    internal
    returns (bool credited);
```

### _safeTransferETH


```solidity
function _safeTransferETH(address to, uint256 amount) internal;
```

### receive


```solidity
receive() external payable;
```

### sweep


```solidity
function sweep(address token, uint256 id, uint256 amount, address to) public payable;
```

### wrap


```solidity
function wrap(uint256 amount) public payable;
```

### unwrap


```solidity
function unwrap(uint256 amount) public payable;
```

### _v2PoolFor


```solidity
function _v2PoolFor(address tokenA, address tokenB, bool sushi)
    internal
    pure
    returns (address v2pool, bool zeroForOne);
```

### _v3PoolFor


```solidity
function _v3PoolFor(address tokenA, address tokenB, uint24 fee)
    internal
    pure
    returns (address v3pool, bool zeroForOne);
```

### _computeV3pool


```solidity
function _computeV3pool(address token0, address token1, uint24 fee)
    internal
    pure
    returns (address v3pool);
```

### _hash


```solidity
function _hash(address value0, address value1, uint24 value2)
    internal
    pure
    returns (bytes32 result);
```

### _sortTokens


```solidity
function _sortTokens(address tokenA, address tokenB)
    internal
    pure
    returns (address token0, address token1, bool zeroForOne);
```

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

