# IERC6909
[Git Source](https://github.com/zammdefi/zRouter/blob/d82472ed26014c26a3a1fe7b0de5e2d744c66e34/src/zRouter.sol)


## Functions
### setOperator


```solidity
function setOperator(address spender, bool approved) external returns (bool);
```

### balanceOf


```solidity
function balanceOf(address owner, uint256 id) external view returns (uint256 amount);
```

### transfer


```solidity
function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
```

### transferFrom


```solidity
function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
    external
    returns (bool);
```

