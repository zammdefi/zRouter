// zamm SDK — Core constants, ABIs, types, token list (zero dependencies)

// ---- Addresses ----

export const ZROUTER = "0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46" as const;
export const ZQUOTER = "0x9f373A73ED229C9D133A189c095E2fFb7B77703E" as const;
export const ETH = "0x0000000000000000000000000000000000000000" as const;

// ---- AMM enum (matches zQuoter.sol:7-15) ----

export enum AMM {
  UNI_V2 = 0,
  SUSHI = 1,
  ZAMM = 2,
  UNI_V3 = 3,
  UNI_V4 = 4,
  CURVE = 5,
  LIDO = 6,
  WETH_WRAP = 7,
}

export const AMM_NAMES: Record<AMM, string> = {
  [AMM.UNI_V2]: "Uniswap V2",
  [AMM.SUSHI]: "SushiSwap",
  [AMM.ZAMM]: "zAMM",
  [AMM.UNI_V3]: "Uniswap V3",
  [AMM.UNI_V4]: "Uniswap V4",
  [AMM.CURVE]: "Curve",
  [AMM.LIDO]: "Lido",
  [AMM.WETH_WRAP]: "WETH Wrap",
};

// ---- Token list ----

export interface Token {
  address: string;
  symbol: string;
  decimals: number;
}

export const TOKENS: Record<string, Token> = {
  ETH:    { address: ETH, symbol: "ETH", decimals: 18 },
  USDC:   { address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", symbol: "USDC", decimals: 6 },
  USDT:   { address: "0xdAC17F958D2ee523a2206206994597C13D831ec7", symbol: "USDT", decimals: 6 },
  DAI:    { address: "0x6B175474E89094C44Da98b954EedeAC495271d0F", symbol: "DAI", decimals: 18 },
  WBTC:   { address: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", symbol: "WBTC", decimals: 8 },
  wstETH: { address: "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0", symbol: "wstETH", decimals: 18 },
  rETH:   { address: "0xae78736Cd615f374D3085123A210448E74Fc6393", symbol: "rETH", decimals: 18 },
  WETH:   { address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", symbol: "WETH", decimals: 18 },
  LINK:   { address: "0x514910771AF9Ca656af840dff83E8264EcF986CA", symbol: "LINK", decimals: 18 },
  UNI:    { address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984", symbol: "UNI", decimals: 18 },
  AAVE:   { address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9", symbol: "AAVE", decimals: 18 },
  MKR:    { address: "0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2", symbol: "MKR", decimals: 18 },
  COMP:   { address: "0xc00e94Cb662C3520282E6f5717214004A7f26888", symbol: "COMP", decimals: 18 },
  CRV:    { address: "0xD533a949740bb3306d119CC777fa900bA034cd52", symbol: "CRV", decimals: 18 },
  LDO:    { address: "0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32", symbol: "LDO", decimals: 18 },
  RPL:    { address: "0xD33526068D116cE69F19A9ee46F0bd304F21A51f", symbol: "RPL", decimals: 18 },
  stETH:  { address: "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84", symbol: "stETH", decimals: 18 },
  cbETH:  { address: "0xBe9895146f7AF43049ca1c1AE358B0541Ea49704", symbol: "cbETH", decimals: 18 },
  cbBTC:  { address: "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf", symbol: "cbBTC", decimals: 8 },
  tBTC:   { address: "0x18084fbA666a33d37592fA2633fD49a74DD93a88", symbol: "tBTC", decimals: 18 },
  GHO:    { address: "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f", symbol: "GHO", decimals: 18 },
  PENDLE: { address: "0x808507121B80c02388fAd14726482e061B8da827", symbol: "PENDLE", decimals: 18 },
  SNX:    { address: "0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F", symbol: "SNX", decimals: 18 },
  PEPE:   { address: "0x6982508145454Ce325dDbE47a25d4ec3d2311933", symbol: "PEPE", decimals: 18 },
  SHIB:   { address: "0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE", symbol: "SHIB", decimals: 18 },
};

// ---- ABIs (human-readable — works with ethers.Interface and viem parseAbi) ----

export const ZQUOTER_ABI = [
  "function buildBestSwapViaETHMulticall(address to, address refundTo, bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps, uint256 deadline) view returns (tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut) a, tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut) b, bytes[] calls, bytes multicall, uint256 msgValue)",
  "function buildSplitSwap(address to, address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps, uint256 deadline) view returns (tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut)[2] legs, bytes multicall, uint256 msgValue)",
  "function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount) view returns (tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut) best, tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut)[] quotes)",
  "function quoteCurve(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount, uint256 maxCandidates) view returns (uint256 amountIn, uint256 amountOut, address bestPool, bool usedUnderlying, bool usedStable, uint8 iIndex, uint8 jIndex)",
  "function buildBestSwap(address to, bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps, uint256 deadline) view returns (tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut) best, bytes callData, uint256 amountLimit, uint256 msgValue)",
] as const;

export const ERC20_ABI = [
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
] as const;

// ---- Types ----

export interface Quote {
  source: AMM;
  sourceId: number;
  sourceName: string;
  feeBps: bigint;
  amountIn: bigint;
  amountOut: bigint;
}

export interface QuoteResult {
  amountOut: bigint;
  multicall: string;
  msgValue: bigint;
  isTwoHop: boolean;
  isSplit: boolean;
  sourceA: string;
  sourceB: string | null;
  splitLegs: { source: string; amountIn: bigint; amountOut: bigint; feeBps: bigint }[] | null;
  allQuotes: Quote[] | null;
}

export interface SwapTx {
  to: string;
  data: string;
  value: bigint;
}

export interface BaseQuoteParams {
  tokenIn: string;
  tokenOut: string;
  amount: bigint;
}

export interface QuoteParams extends BaseQuoteParams {
  recipient: string;
  /** Where excess ETH is refunded (defaults to recipient). Set to the tx sender if recipient differs. */
  refundTo?: string;
  slippageBps?: number;
  deadline?: bigint;
}

export interface SwapParams extends QuoteParams {}

// ---- Helpers ----

export function defaultDeadline(): bigint {
  return BigInt(Math.trunc(Date.now() / 1000) + 300);
}
