# IV3Pool
[Git Source](https://github.com/zammdefi/zRouter/blob/a05798c96306fd33a6d62d08f875ca1ad04f0e1f/src/zRouter.sol)


## Functions
### swap


```solidity
function swap(
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata data
) external returns (int256 amount0, int256 amount1);
```

