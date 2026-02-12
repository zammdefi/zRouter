# zamm

TypeScript SDK for [zRouter](https://zamm.finance) swaps on Ethereum. Wraps the on-chain zQuoter — which finds the best route across Uniswap V2/V3/V4, SushiSwap, zAMM, Curve, Lido, and WETH — and returns ready-to-send transaction data.

## Install

```bash
npm install zamm
```

## Quick Start

### Ethers.js v6

```typescript
import { Zamm, TOKENS, ETH } from "zamm/ethers";
import { JsonRpcProvider, Wallet, parseEther } from "ethers";

const provider = new JsonRpcProvider("https://eth.llamarpc.com");
const wallet = new Wallet(PRIVATE_KEY, provider);
const zamm = new Zamm(provider);

// Build and send a swap
const tx = await zamm.buildSwap({
  tokenIn: ETH,
  tokenOut: TOKENS.USDC.address,
  amount: parseEther("1"),
  recipient: wallet.address,
});
await wallet.sendTransaction(tx);
```

### Viem

```typescript
import { Zamm, TOKENS, ETH } from "zamm/viem";
import { createPublicClient, createWalletClient, http, parseEther } from "viem";
import { mainnet } from "viem/chains";

const publicClient = createPublicClient({ chain: mainnet, transport: http() });
const zamm = new Zamm(publicClient);

const tx = await zamm.buildSwap({
  tokenIn: TOKENS.WBTC.address,
  tokenOut: TOKENS.USDC.address,
  amount: 100000000n, // 1 WBTC
  recipient: account.address,
  slippageBps: 100, // 1%
});
await walletClient.sendTransaction(tx);
```

### Constants Only

```typescript
import { ZROUTER, ZQUOTER, ZQUOTER_ABI, TOKENS, AMM, AMM_NAMES, ETH } from "zamm";
```

## API

### `Zamm` class

Both `zamm/ethers` and `zamm/viem` export the same `Zamm` class with identical methods.

#### `constructor(provider)`

- **Ethers**: pass an ethers `Provider`
- **Viem**: pass a viem `PublicClient`

#### `quote(params): Promise<QuoteResult>`

Get the best quote. Fires `buildBestSwapViaETHMulticall` and `buildSplitSwap` in parallel, picks whichever gives better output.

```typescript
const result = await zamm.quote({
  tokenIn: ETH,
  tokenOut: TOKENS.USDC.address,
  amount: parseEther("1"),
  recipient: "0x...",
  slippageBps: 50,  // optional, default 50 (0.5%)
  deadline: 1234n,  // optional, default now + 300s
  refundTo: "0x...", // optional, default recipient
});

result.amountOut;  // expected output amount
result.multicall;  // encoded calldata for zRouter
result.msgValue;   // ETH value to send
result.isTwoHop;   // routed through ETH
result.isSplit;    // split across two AMMs
result.sourceA;    // e.g. "Uniswap V3"
result.allQuotes;  // all individual AMM quotes
```

#### `buildSwap(params): Promise<SwapTx>`

Returns `{ to, data, value }` ready for `sendTransaction()`. Same params as `quote()`.

#### `getAllQuotes(params): Promise<Quote[]>`

All single-hop quotes from every AMM.

```typescript
const quotes = await zamm.getAllQuotes({
  tokenIn: ETH,
  tokenOut: TOKENS.USDC.address,
  amount: parseEther("1"),
});
// [{ source: AMM.UNI_V3, sourceName: "Uniswap V3", amountOut: 2500000000n, ... }, ...]
```

#### `getAllowance(token, owner): Promise<bigint>`

Check ERC20 allowance for zRouter.

#### `buildApprove(token): { to, data }`

Returns unsigned approve calldata for `zRouter` with max allowance.

```typescript
const { to, data } = zamm.buildApprove(TOKENS.USDC.address);
await wallet.sendTransaction({ to, data });
```

### ERC20 Approval Flow

ERC20 tokens need approval before swapping (ETH does not):

```typescript
const allowance = await zamm.getAllowance(TOKENS.USDC.address, wallet.address);
if (allowance < amount) {
  const approve = zamm.buildApprove(TOKENS.USDC.address);
  await wallet.sendTransaction(approve);
}
const tx = await zamm.buildSwap({ tokenIn: TOKENS.USDC.address, ... });
await wallet.sendTransaction(tx);
```

## Exports

| Import | Contents |
|---|---|
| `zamm` | Constants, ABIs, types, token list (zero dependencies) |
| `zamm/ethers` | `Zamm` class + re-exports from `zamm` (peer dep: ethers ^6) |
| `zamm/viem` | `Zamm` class + re-exports from `zamm` (peer dep: viem ^2) |

## Supported Tokens

ETH, USDC, USDT, DAI, WBTC, wstETH, rETH, WETH, LINK, UNI, AAVE, MKR, COMP, CRV, LDO, RPL, stETH, cbETH, cbBTC, tBTC, GHO, PENDLE, SNX, PEPE, SHIB

All available via `TOKENS.SYMBOL.address`.

## Contracts

| Contract | Address |
|---|---|
| zRouter | `0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46` |
| zQuoter | `0x9f373A73ED229C9D133A189c095E2fFb7B77703E` |

Ethereum mainnet only.
