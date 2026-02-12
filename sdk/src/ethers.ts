// zamm SDK — Ethers.js v6 adapter

import { Contract, Interface, MaxUint256 } from "ethers";
import type { Provider } from "ethers";
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

const DEFAULT_SLIPPAGE = 50; // 0.5%

export class Zamm {
  private quoter: Contract;
  private provider: Provider;

  constructor(provider: Provider) {
    this.provider = provider;
    this.quoter = new Contract(ZQUOTER, ZQUOTER_ABI, provider);
  }

  /**
   * Get best quote — fires buildBestSwapViaETHMulticall + buildSplitSwap in parallel,
   * picks whichever gives better output (mirrors dapp getQuote logic).
   */
  async quote(params: QuoteParams): Promise<QuoteResult> {
    const { tokenIn, tokenOut, amount, recipient, refundTo = recipient, slippageBps = DEFAULT_SLIPPAGE, deadline = defaultDeadline() } = params;

    const [bestResult, splitResult, quotesResult, curveResult] = await Promise.allSettled([
      this.quoter.buildBestSwapViaETHMulticall(
        recipient, refundTo, false,
        tokenIn, tokenOut,
        amount, BigInt(slippageBps), deadline,
      ),
      this.quoter.buildSplitSwap(
        recipient, tokenIn, tokenOut,
        amount, BigInt(slippageBps), deadline,
      ),
      this.quoter.getQuotes(false, tokenIn, tokenOut, amount),
      this.quoter.quoteCurve(false, tokenIn, tokenOut, amount, 8),
    ]);

    if (bestResult.status === "rejected") throw bestResult.reason;
    const r = bestResult.value;

    const isTwoHop = r.b.amountOut > 0n;
    const bestOutput = isTwoHop ? r.b.amountOut : r.a.amountOut;

    const result: QuoteResult = {
      amountOut: bestOutput,
      multicall: r.multicall,
      msgValue: r.msgValue ?? 0n,
      isTwoHop,
      isSplit: false,
      sourceA: AMM_NAMES[r.a.source as AMM] || "Unknown",
      sourceB: isTwoHop ? (AMM_NAMES[r.b.source as AMM] || "Unknown") : null,
      splitLegs: null,
      allQuotes: null,
    };

    // Check if split beats best
    if (splitResult.status === "fulfilled") {
      const s = splitResult.value;
      const splitTotal = s.legs[0].amountOut + s.legs[1].amountOut;
      if (splitTotal > bestOutput && s.legs[0].amountOut > 0n && s.legs[1].amountOut > 0n) {
        result.amountOut = splitTotal;
        result.multicall = s.multicall;
        result.msgValue = s.msgValue ?? 0n;
        result.isSplit = true;
        result.isTwoHop = false;
        result.splitLegs = [
          { source: AMM_NAMES[s.legs[0].source as AMM] || "Unknown", amountIn: s.legs[0].amountIn, amountOut: s.legs[0].amountOut, feeBps: s.legs[0].feeBps },
          { source: AMM_NAMES[s.legs[1].source as AMM] || "Unknown", amountIn: s.legs[1].amountIn, amountOut: s.legs[1].amountOut, feeBps: s.legs[1].feeBps },
        ];
      }
    }

    // Attach all-quotes for display
    if (quotesResult.status === "fulfilled") {
      const q = quotesResult.value;
      result.allQuotes = q.quotes
        .map((qt: { source: number; feeBps: bigint; amountIn: bigint; amountOut: bigint }) => ({
          source: qt.source as AMM,
          sourceId: Number(qt.source),
          sourceName: AMM_NAMES[qt.source as AMM] || `AMM #${qt.source}`,
          feeBps: qt.feeBps,
          amountIn: qt.amountIn,
          amountOut: qt.amountOut,
        }))
        .filter((qt: Quote) => qt.amountOut > 0n);

      if (curveResult.status === "fulfilled") {
        const c = curveResult.value;
        if (c.amountOut > 0n) {
          result.allQuotes!.push({
            source: AMM.CURVE,
            sourceId: 5,
            sourceName: "Curve",
            feeBps: 0n,
            amountIn: c.amountIn,
            amountOut: c.amountOut,
          });
        }
      }
    }

    return result;
  }

  /**
   * Returns { to, data, value } ready for signer.sendTransaction().
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
      this.quoter.getQuotes(false, tokenIn, tokenOut, amount),
      this.quoter.quoteCurve(false, tokenIn, tokenOut, amount, 8),
    ]);

    const quotes: Quote[] = [];

    if (quotesResult.status === "fulfilled") {
      const q = quotesResult.value;
      for (const qt of q.quotes) {
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
      const c = curveResult.value;
      if (c.amountOut > 0n) {
        quotes.push({
          source: AMM.CURVE,
          sourceId: 5,
          sourceName: "Curve",
          feeBps: 0n,
          amountIn: c.amountIn,
          amountOut: c.amountOut,
        });
      }
    }

    return quotes;
  }

  /**
   * Check ERC20 allowance for zRouter.
   */
  async getAllowance(token: string, owner: string): Promise<bigint> {
    const erc20 = new Contract(token, ERC20_ABI, this.provider);
    return erc20.allowance(owner, ZROUTER);
  }

  /**
   * Returns { to, data } for approve(zRouter, maxUint256).
   */
  buildApprove(token: string): { to: string; data: string } {
    const iface = new Interface(ERC20_ABI);
    return {
      to: token,
      data: iface.encodeFunctionData("approve", [ZROUTER, MaxUint256]),
    };
  }
}
