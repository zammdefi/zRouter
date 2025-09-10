# IV3Pool
[Git Source](https://github.com/zammdefi/zRouter/blob/69617a4a7c4ee7b21900c469f2a65ec825391317/src/zRouter.sol)


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

