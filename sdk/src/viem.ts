// zamm SDK — Viem adapter

import { parseAbi, encodeFunctionData, maxUint256 } from "viem";
import type { PublicClient, Address } from "viem";
import {
  ZROUTER, ZQUOTER, ETH,
  ZQUOTER_ABI, ERC20_ABI,
  AMM_NAMES, AMM,
  defaultDeadline,
  type BaseQuoteParams, type QuoteParams, type SwapParams,
  type Quote, type QuoteResult, type SwapTx,
} from "./index.js";

export { ZROUTER, ZQUOTER, ETH, AMM, AMM_NAMES, TOKENS, ZQUOTER_ABI, ERC20_ABI, defaultDeadline } from "./index.js";
export type { Token, Quote, QuoteResult, SwapTx, BaseQuoteParams, QuoteParams, SwapParams } from "./index.js";

const quoterAbi = parseAbi(ZQUOTER_ABI);
const erc20Abi = parseAbi(ERC20_ABI);

const DEFAULT_SLIPPAGE = 50; // 0.5%

// Internal types for readContract results
type QuoteStruct = { source: number; feeBps: bigint; amountIn: bigint; amountOut: bigint };
type BestSwapResult = readonly [QuoteStruct, QuoteStruct, readonly `0x${string}`[], `0x${string}`, bigint];
type SplitSwapResult = readonly [readonly [QuoteStruct, QuoteStruct], `0x${string}`, bigint];
type GetQuotesResult = readonly [QuoteStruct, readonly QuoteStruct[]];
type QuoteCurveResult = readonly [bigint, bigint, `0x${string}`, boolean, boolean, number, number];

export class Zamm {
  private client: PublicClient;

  constructor(client: PublicClient) {
    this.client = client;
  }

  /**
   * Get best quote — fires buildBestSwapViaETHMulticall + buildSplitSwap in parallel,
   * picks whichever gives better output (mirrors dapp getQuote logic).
   */
  async quote(params: QuoteParams): Promise<QuoteResult> {
    const { tokenIn, tokenOut, amount, recipient, refundTo = recipient, slippageBps = DEFAULT_SLIPPAGE, deadline = defaultDeadline() } = params;

    const [bestResult, splitResult, quotesResult, curveResult] = await Promise.allSettled([
      this.client.readContract({
        address: ZQUOTER as Address,
        abi: quoterAbi,
        functionName: "buildBestSwapViaETHMulticall",
        args: [
          recipient as Address, refundTo as Address, false,
          tokenIn as Address, tokenOut as Address,
          amount, BigInt(slippageBps), deadline,
        ],
      }),
      this.client.readContract({
        address: ZQUOTER as Address,
        abi: quoterAbi,
        functionName: "buildSplitSwap",
        args: [
          recipient as Address, tokenIn as Address, tokenOut as Address,
          amount, BigInt(slippageBps), deadline,
        ],
      }),
      this.client.readContract({
        address: ZQUOTER as Address,
        abi: quoterAbi,
        functionName: "getQuotes",
        args: [false, tokenIn as Address, tokenOut as Address, amount],
      }),
      this.client.readContract({
        address: ZQUOTER as Address,
        abi: quoterAbi,
        functionName: "quoteCurve",
        args: [false, tokenIn as Address, tokenOut as Address, amount, 8n],
      }),
    ]);

    if (bestResult.status === "rejected") throw bestResult.reason;

    const [a, b, _calls, multicall, msgValue] = bestResult.value as BestSwapResult;

    const isTwoHop = b.amountOut > 0n;
    const bestOutput = isTwoHop ? b.amountOut : a.amountOut;

    const result: QuoteResult = {
      amountOut: bestOutput,
      multicall: multicall as string,
      msgValue: msgValue ?? 0n,
      isTwoHop,
      isSplit: false,
      sourceA: AMM_NAMES[a.source as AMM] || "Unknown",
      sourceB: isTwoHop ? (AMM_NAMES[b.source as AMM] || "Unknown") : null,
      splitLegs: null,
      allQuotes: null,
    };

    // Check if split beats best
    if (splitResult.status === "fulfilled") {
      const [legs, splitMulticall, splitMsgValue] = splitResult.value as SplitSwapResult;
      const splitTotal = legs[0].amountOut + legs[1].amountOut;
      if (splitTotal > bestOutput && legs[0].amountOut > 0n && legs[1].amountOut > 0n) {
        result.amountOut = splitTotal;
        result.multicall = splitMulticall as string;
        result.msgValue = splitMsgValue ?? 0n;
        result.isSplit = true;
        result.isTwoHop = false;
        result.splitLegs = [
          { source: AMM_NAMES[legs[0].source as AMM] || "Unknown", amountIn: legs[0].amountIn, amountOut: legs[0].amountOut, feeBps: legs[0].feeBps },
          { source: AMM_NAMES[legs[1].source as AMM] || "Unknown", amountIn: legs[1].amountIn, amountOut: legs[1].amountOut, feeBps: legs[1].feeBps },
        ];
      }
    }

    // Attach all-quotes for display
    if (quotesResult.status === "fulfilled") {
      const [_best, quotes] = quotesResult.value as GetQuotesResult;
      result.allQuotes = quotes
        .filter((qt) => qt.amountOut > 0n)
        .map((qt) => ({
          source: qt.source as AMM,
          sourceId: Number(qt.source),
          sourceName: AMM_NAMES[qt.source as AMM] || `AMM #${qt.source}`,
          feeBps: qt.feeBps,
          amountIn: qt.amountIn,
          amountOut: qt.amountOut,
        }));

      if (curveResult.status === "fulfilled") {
        const [curveAmountIn, curveAmountOut] = curveResult.value as QuoteCurveResult;
        if (curveAmountOut > 0n) {
          result.allQuotes!.push({
            source: AMM.CURVE,
            sourceId: 5,
            sourceName: "Curve",
            feeBps: 0n,
            amountIn: curveAmountIn,
            amountOut: curveAmountOut,
          });
        }
      }
    }

    return result;
  }

  /**
   * Returns { to, data, value } ready for walletClient.sendTransaction().
   */
  async buildSwap(params: SwapParams): Promise<SwapTx> {
    const result = await this.quote(params);
    return {
      to: ZROUTER,
      data: result.multicall,
      value: result.msgValue,
    };
  }

  /**
   * All single-hop quotes from every AMM.
   */
  async getAllQuotes(params: BaseQuoteParams): Promise<Quote[]> {
    const { tokenIn, tokenOut, amount } = params;

    const [quotesResult, curveResult] = await Promise.allSettled([
      this.client.readContract({
        address: ZQUOTER as Address,
        abi: quoterAbi,
        functionName: "getQuotes",
        args: [false, tokenIn as Address, tokenOut as Address, amount],
      }),
      this.client.readContract({
        address: ZQUOTER as Address,
        abi: quoterAbi,
        functionName: "quoteCurve",
        args: [false, tokenIn as Address, tokenOut as Address, amount, 8n],
      }),
    ]);

    const quotes: Quote[] = [];

    if (quotesResult.status === "fulfilled") {
      const [_best, rawQuotes] = quotesResult.value as GetQuotesResult;
      for (const qt of rawQuotes) {
        if (qt.amountOut > 0n) {
          quotes.push({
            source: qt.source as AMM,
            sourceId: Number(qt.source),
            sourceName: AMM_NAMES[qt.source as AMM] || `AMM #${qt.source}`,
            feeBps: qt.feeBps,
            amountIn: qt.amountIn,
            amountOut: qt.amountOut,
          });
        }
      }
    }

    if (curveResult.status === "fulfilled") {
      const [curveAmountIn, curveAmountOut] = curveResult.value as QuoteCurveResult;
      if (curveAmountOut > 0n) {
        quotes.push({
          source: AMM.CURVE,
          sourceId: 5,
          sourceName: "Curve",
          feeBps: 0n,
          amountIn: curveAmountIn,
          amountOut: curveAmountOut,
        });
      }
    }

    return quotes;
  }

  /**
   * Check ERC20 allowance for zRouter.
   */
  async getAllowance(token: string, owner: string): Promise<bigint> {
    return this.client.readContract({
      address: token as Address,
      abi: erc20Abi,
      functionName: "allowance",
      args: [owner as Address, ZROUTER as Address],
    }) as Promise<bigint>;
  }

  /**
   * Returns { to, data } for approve(zRouter, maxUint256).
   */
  buildApprove(token: string): { to: string; data: string } {
    return {
      to: token,
      data: encodeFunctionData({
        abi: erc20Abi,
        functionName: "approve",
        args: [ZROUTER as Address, maxUint256],
      }),
    };
  }
}
