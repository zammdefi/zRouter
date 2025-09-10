# IV4PoolManager
[Git Source](https://github.com/zammdefi/zRouter/blob/69617a4a7c4ee7b21900c469f2a65ec825391317/src/zRouter.sol)


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

