# IV3Pool
[Git Source](https://github.com/zammdefi/zRouter/blob/15c5fb7442065a88b0c255094f10ebd47b711ccb/src/zRouter.sol)


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

