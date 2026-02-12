export declare const ZROUTER: "0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46";
export declare const ZQUOTER: "0x9f373A73ED229C9D133A189c095E2fFb7B77703E";
export declare const ETH: "0x0000000000000000000000000000000000000000";
export declare enum AMM {
    UNI_V2 = 0,
    SUSHI = 1,
    ZAMM = 2,
    UNI_V3 = 3,
    UNI_V4 = 4,
    CURVE = 5,
    LIDO = 6,
    WETH_WRAP = 7
}
export declare const AMM_NAMES: Record<AMM, string>;
export interface Token {
    address: string;
    symbol: string;
    decimals: number;
}
export declare const TOKENS: Record<string, Token>;
export declare const ZQUOTER_ABI: readonly ["function buildBestSwapViaETHMulticall(address to, address refundTo, bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps, uint256 deadline) view returns (tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut) a, tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut) b, bytes[] calls, bytes multicall, uint256 msgValue)", "function buildSplitSwap(address to, address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps, uint256 deadline) view returns (tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut)[2] legs, bytes multicall, uint256 msgValue)", "function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount) view returns (tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut) best, tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut)[] quotes)", "function quoteCurve(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount, uint256 maxCandidates) view returns (uint256 amountIn, uint256 amountOut, address bestPool, bool usedUnderlying, bool usedStable, uint8 iIndex, uint8 jIndex)", "function buildBestSwap(address to, bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps, uint256 deadline) view returns (tuple(uint8 source, uint256 feeBps, uint256 amountIn, uint256 amountOut) best, bytes callData, uint256 amountLimit, uint256 msgValue)"];
export declare const ERC20_ABI: readonly ["function allowance(address owner, address spender) view returns (uint256)", "function approve(address spender, uint256 amount) returns (bool)"];
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
    splitLegs: {
        source: string;
        amountIn: bigint;
        amountOut: bigint;
        feeBps: bigint;
    }[] | null;
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
export interface SwapParams extends QuoteParams {
}
export declare function defaultDeadline(): bigint;
