# IV4PoolManager
[Git Source](https://github.com/zammdefi/zRouter/blob/d82472ed26014c26a3a1fe7b0de5e2d744c66e34/src/zRouter.sol)


## Functions
### unlock


```solidity
function unlock(bytes calldata data) external returns (bytes memory);
```

### swap


```solidity
function swap(V4PoolKey memory key, V4SwapParams memory params, bytes calldata hookData)
    external
    returns (int256 swapDelta);
```

### sync


```solidity
function sync(address currency) external;
```

### settle


```solidity
function settle() external payable returns (uint256 paid);
```

### take


```solidity
function take(address currency, address to, uint256 amount) external;
```

