# IZAMM
[Git Source](https://github.com/zammdefi/zRouter/blob/a05798c96306fd33a6d62d08f875ca1ad04f0e1f/src/zRouter.sol)


## Functions
### swapExactIn


```solidity
function swapExactIn(
    PoolKey calldata poolKey,
    uint256 amountIn,
    uint256 amountOutMin,
    bool zeroForOne,
    address to,
    uint256 deadline
) external payable returns (uint256 amountOut);
```

### swapExactOut


```solidity
function swapExactOut(
    PoolKey calldata poolKey,
    uint256 amountOut,
    uint256 amountInMax,
    bool zeroForOne,
    address to,
    uint256 deadline
) external payable returns (uint256 amountIn);
```

### addLiquidity


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

