# IZRouter
[Git Source](https://github.com/zammdefi/zRouter/blob/69617a4a7c4ee7b21900c469f2a65ec825391317/src/zQuoter.sol)


## Functions
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
) external payable returns (uint256 amountIn, uint256 amountOut);
```

### swapVZ


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
) external payable returns (uint256 amountIn, uint256 amountOut);
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
) external payable returns (uint256 amountIn, uint256 amountOut);
```

