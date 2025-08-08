# IV3Pool
[Git Source](https://github.com/zammdefi/zRouter/blob/d82472ed26014c26a3a1fe7b0de5e2d744c66e34/src/zRouter.sol)


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

