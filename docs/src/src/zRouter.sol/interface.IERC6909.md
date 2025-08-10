# IERC6909
[Git Source](https://github.com/zammdefi/zRouter/blob/15c5fb7442065a88b0c255094f10ebd47b711ccb/src/zRouter.sol)


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

