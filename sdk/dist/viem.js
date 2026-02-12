// zamm SDK — Viem adapter
import { parseAbi, encodeFunctionData, maxUint256 } from "viem";
import { ZROUTER, ZQUOTER, ZQUOTER_ABI, ERC20_ABI, AMM_NAMES, AMM, defaultDeadline, } from "./index.js";
export { ZROUTER, ZQUOTER, ETH, AMM, AMM_NAMES, TOKENS, ZQUOTER_ABI, ERC20_ABI, defaultDeadline } from "./index.js";
const quoterAbi = parseAbi(ZQUOTER_ABI);
const erc20Abi = parseAbi(ERC20_ABI);
const DEFAULT_SLIPPAGE = 50; // 0.5%
export class Zamm {
    client;
    constructor(client) {
        this.client = client;
    }
    /**
     * Get best quote — fires buildBestSwapViaETHMulticall + buildSplitSwap in parallel,
     * picks whichever gives better output (mirrors dapp getQuote logic).
     */
    async quote(params) {
        const { tokenIn, tokenOut, amount, recipient, refundTo = recipient, slippageBps = DEFAULT_SLIPPAGE, deadline = defaultDeadline() } = params;
        const [bestResult, splitResult, quotesResult, curveResult] = await Promise.allSettled([
            this.client.readContract({
                address: ZQUOTER,
                abi: quoterAbi,
                functionName: "buildBestSwapViaETHMulticall",
                args: [
                    recipient, refundTo, false,
                    tokenIn, tokenOut,
                    amount, BigInt(slippageBps), deadline,
                ],
            }),
            this.client.readContract({
                address: ZQUOTER,
                abi: quoterAbi,
                functionName: "buildSplitSwap",
                args: [
                    recipient, tokenIn, tokenOut,
                    amount, BigInt(slippageBps), deadline,
                ],
            }),
            this.client.readContract({
                address: ZQUOTER,
                abi: quoterAbi,
                functionName: "getQuotes",
                args: [false, tokenIn, tokenOut, amount],
            }),
            this.client.readContract({
                address: ZQUOTER,
                abi: quoterAbi,
                functionName: "quoteCurve",
                args: [false, tokenIn, tokenOut, amount, 8n],
            }),
        ]);
        if (bestResult.status === "rejected")
            throw bestResult.reason;
        const [a, b, _calls, multicall, msgValue] = bestResult.value;
        const isTwoHop = b.amountOut > 0n;
        const bestOutput = isTwoHop ? b.amountOut : a.amountOut;
        const result = {
            amountOut: bestOutput,
            multicall: multicall,
            msgValue: msgValue ?? 0n,
            isTwoHop,
            isSplit: false,
            sourceA: AMM_NAMES[a.source] || "Unknown",
            sourceB: isTwoHop ? (AMM_NAMES[b.source] || "Unknown") : null,
            splitLegs: null,
            allQuotes: null,
        };
        // Check if split beats best
        if (splitResult.status === "fulfilled") {
            const [legs, splitMulticall, splitMsgValue] = splitResult.value;
            const splitTotal = legs[0].amountOut + legs[1].amountOut;
            if (splitTotal > bestOutput && legs[0].amountOut > 0n && legs[1].amountOut > 0n) {
                result.amountOut = splitTotal;
                result.multicall = splitMulticall;
                result.msgValue = splitMsgValue ?? 0n;
                result.isSplit = true;
                result.isTwoHop = false;
                result.splitLegs = [
                    { source: AMM_NAMES[legs[0].source] || "Unknown", amountIn: legs[0].amountIn, amountOut: legs[0].amountOut, feeBps: legs[0].feeBps },
                    { source: AMM_NAMES[legs[1].source] || "Unknown", amountIn: legs[1].amountIn, amountOut: legs[1].amountOut, feeBps: legs[1].feeBps },
                ];
            }
        }
        // Attach all-quotes for display
        if (quotesResult.status === "fulfilled") {
            const [_best, quotes] = quotesResult.value;
            result.allQuotes = quotes
                .filter((qt) => qt.amountOut > 0n)
                .map((qt) => ({
                source: qt.source,
                sourceId: Number(qt.source),
                sourceName: AMM_NAMES[qt.source] || `AMM #${qt.source}`,
                feeBps: qt.feeBps,
                amountIn: qt.amountIn,
                amountOut: qt.amountOut,
            }));
            if (curveResult.status === "fulfilled") {
                const [curveAmountIn, curveAmountOut] = curveResult.value;
                if (curveAmountOut > 0n) {
                    result.allQuotes.push({
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
    async buildSwap(params) {
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
    async getAllQuotes(params) {
        const { tokenIn, tokenOut, amount } = params;
        const [quotesResult, curveResult] = await Promise.allSettled([
            this.client.readContract({
                address: ZQUOTER,
                abi: quoterAbi,
                functionName: "getQuotes",
                args: [false, tokenIn, tokenOut, amount],
            }),
            this.client.readContract({
                address: ZQUOTER,
                abi: quoterAbi,
                functionName: "quoteCurve",
                args: [false, tokenIn, tokenOut, amount, 8n],
            }),
        ]);
        const quotes = [];
        if (quotesResult.status === "fulfilled") {
            const [_best, rawQuotes] = quotesResult.value;
            for (const qt of rawQuotes) {
                if (qt.amountOut > 0n) {
                    quotes.push({
                        source: qt.source,
                        sourceId: Number(qt.source),
                        sourceName: AMM_NAMES[qt.source] || `AMM #${qt.source}`,
                        feeBps: qt.feeBps,
                        amountIn: qt.amountIn,
                        amountOut: qt.amountOut,
                    });
                }
            }
        }
        if (curveResult.status === "fulfilled") {
            const [curveAmountIn, curveAmountOut] = curveResult.value;
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
    async getAllowance(token, owner) {
        return this.client.readContract({
            address: token,
            abi: erc20Abi,
            functionName: "allowance",
            args: [owner, ZROUTER],
        });
    }
    /**
     * Returns { to, data } for approve(zRouter, maxUint256).
     */
    buildApprove(token) {
        return {
            to: token,
            data: encodeFunctionData({
                abi: erc20Abi,
                functionName: "approve",
                args: [ZROUTER, maxUint256],
            }),
        };
    }
}
