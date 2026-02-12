import type { PublicClient } from "viem";
import { type BaseQuoteParams, type QuoteParams, type SwapParams, type Quote, type QuoteResult, type SwapTx } from "./index.js";
export { ZROUTER, ZQUOTER, ETH, AMM, AMM_NAMES, TOKENS, ZQUOTER_ABI, ERC20_ABI, defaultDeadline } from "./index.js";
export type { Token, Quote, QuoteResult, SwapTx, BaseQuoteParams, QuoteParams, SwapParams } from "./index.js";
export declare class Zamm {
    private client;
    constructor(client: PublicClient);
    /**
     * Get best quote — fires buildBestSwapViaETHMulticall + buildSplitSwap in parallel,
     * picks whichever gives better output (mirrors dapp getQuote logic).
     */
    quote(params: QuoteParams): Promise<QuoteResult>;
    /**
     * Returns { to, data, value } ready for walletClient.sendTransaction().
     */
    buildSwap(params: SwapParams): Promise<SwapTx>;
    /**
     * All single-hop quotes from every AMM.
     */
    getAllQuotes(params: BaseQuoteParams): Promise<Quote[]>;
    /**
     * Check ERC20 allowance for zRouter.
     */
    getAllowance(token: string, owner: string): Promise<bigint>;
    /**
     * Returns { to, data } for approve(zRouter, maxUint256).
     */
    buildApprove(token: string): {
        to: string;
        data: string;
    };
}
