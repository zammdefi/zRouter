# zQuoter
[Git Source](https://github.com/zammdefi/zRouter/blob/69617a4a7c4ee7b21900c469f2a65ec825391317/src/zQuoter.sol)


## Functions
### constructor


```solidity
constructor() payable;
```

### getQuotes


```solidity
function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
    public
    view
    returns (Quote memory best, Quote[] memory quotes);
```

### quoteV2


```solidity
function quoteV2(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount, bool sushi)
    public
    view
    returns (uint256 amountIn, uint256 amountOut);
```

### quoteV3


```solidity
function quoteV3(bool exactOut, address tokenIn, address tokenOut, uint24 fee, uint256 swapAmount)
    public
    view
    returns (uint256 amountIn, uint256 amountOut);
```

### quoteV4


```solidity
function quoteV4(
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint24 fee,
    int24 tickSpacing,
    address hooks,
    uint256 swapAmount
) public view returns (uint256 amountIn, uint256 amountOut);
```

### quoteZAMM


```solidity
function quoteZAMM(
    bool exactOut,
    uint256 feeOrHook,
    address tokenIn,
    address tokenOut,
    uint256 idIn,
    uint256 idOut,
    uint256 swapAmount
) public view returns (uint256 amountIn, uint256 amountOut);
```

### limit


```solidity
function limit(bool exactOut, uint256 quoted, uint256 bps) public pure returns (uint256);
```

### _v2PoolFor


```solidity
function _v2PoolFor(address tokenA, address tokenB, bool sushi)
    internal
    pure
    returns (address v2pool, bool zeroForOne);
```

### _buildV2Swap


```solidity
function _buildV2Swap(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) internal pure returns (bytes memory callData);
```

### _buildZAMMSwap


```solidity
function _buildZAMMSwap(
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
) internal pure returns (bytes memory callData);
```

### _buildV3Swap


```solidity
function _buildV3Swap(
    address to,
    bool exactOut,
    uint24 swapFee,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) internal pure returns (bytes memory callData);
```

### _buildV4Swap


```solidity
function _buildV4Swap(
    address to,
    bool exactOut,
    uint24 swapFee,
    int24 tickSpace,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) internal pure returns (bytes memory callData);
```

### buildBestSwap


```solidity
function buildBestSwap(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 slippageBps,
    uint256 deadline
)
    public
    view
    returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue);
```

### _spacingFromBps


```solidity
function _spacingFromBps(uint16 bps) internal pure returns (int24);
```

### _requiredMsgValue


```solidity
function _requiredMsgValue(bool exactOut, address tokenIn, uint256 swapAmount, uint256 amountLimit)
    internal
    pure
    returns (uint256);
```

### buildBestSwapViaETHMulticall


```solidity
function buildBestSwapViaETHMulticall(
    address to,
    address refundTo,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 slippageBps,
    uint256 deadline
)
    public
    view
    returns (
        Quote memory a,
        Quote memory b,
        bytes[] memory calls,
        bytes memory multicall,
        uint256 msgValue
    );
```

### _buildCallForQuote


```solidity
function _buildCallForQuote(
    Quote memory q,
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) internal pure returns (bytes memory callData);
```

## Errors
### NoRoute

```solidity
error NoRoute();
```

### UnsupportedAMM

```solidity
error UnsupportedAMM();
```

### ZeroAmount

```solidity
error ZeroAmount();
```

## Structs
### Quote

```solidity
struct Quote {
    AMM source;
    uint256 feeBps;
    uint256 amountIn;
    uint256 amountOut;
}
```

## Enums
### AMM

```solidity
enum AMM {
    UNI_V2,
    SUSHI,
    ZAMM,
    UNI_V3,
    UNI_V4
}
```

