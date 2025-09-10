// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

zQuoter constant ZQUOTER_BASE = zQuoter(0x658bF1A6608210FDE7310760f391AD4eC8006A5F);

contract zQuoter {
    enum AMM {
        UNI_V2,
        SUSHI,
        ZAMM,
        UNI_V3,
        UNI_V4
    }

    struct Quote {
        AMM source;
        uint256 feeBps;
        uint256 amountIn;
        uint256 amountOut;
    }

    constructor() payable {}

    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (Quote memory best, Quote[] memory quotes)
    {
        return ZQUOTER_BASE.getQuotes(exactOut, tokenIn, tokenOut, swapAmount);
    }

    function quoteV2(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        bool sushi
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        return ZQUOTER_BASE.quoteV2(exactOut, tokenIn, tokenOut, swapAmount, sushi);
    }

    function quoteV3(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        return ZQUOTER_BASE.quoteV3(exactOut, tokenIn, tokenOut, fee, swapAmount);
    }

    function quoteV4(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        return
            ZQUOTER_BASE.quoteV4(exactOut, tokenIn, tokenOut, fee, tickSpacing, hooks, swapAmount);
    }

    function quoteZAMM(
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        return
            ZQUOTER_BASE.quoteZAMM(exactOut, feeOrHook, tokenIn, tokenOut, idIn, idOut, swapAmount);
    }

    function limit(bool exactOut, uint256 quoted, uint256 bps) public pure returns (uint256) {
        return SlippageLib.limit(exactOut, quoted, bps);
    }

    function _v2PoolFor(address tokenA, address tokenB, bool sushi)
        internal
        pure
        returns (address v2pool, bool zeroForOne)
    {
        unchecked {
            (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
            zeroForOne = zF1;
            v2pool = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                !sushi ? V2_FACTORY : SUSHI_FACTORY,
                                keccak256(abi.encodePacked(token0, token1)),
                                !sushi ? V2_POOL_INIT_CODE_HASH : SUSHI_POOL_INIT_CODE_HASH
                            )
                        )
                    )
                )
            );
        }
    }

    // zRouter calldata builders:

    error NoRoute();
    error UnsupportedAMM();

    function _buildV2Swap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapV2.selector,
            to,
            exactOut,
            tokenIn,
            tokenOut,
            swapAmount,
            amountLimit,
            deadline
        );
    }

    function _buildZAMMSwap(
        address to,
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapVZ.selector,
            to,
            exactOut,
            feeOrHook,
            tokenIn,
            tokenOut,
            idIn,
            idOut,
            swapAmount,
            amountLimit,
            deadline
        );
    }

    function _buildV3Swap(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapV3.selector,
            to,
            exactOut,
            swapFee,
            tokenIn,
            tokenOut,
            swapAmount,
            amountLimit,
            deadline
        );
    }

    function _buildV4Swap(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapV4.selector,
            to,
            exactOut,
            swapFee,
            tickSpace,
            tokenIn,
            tokenOut,
            swapAmount,
            amountLimit,
            deadline
        );
    }

    /* One-shot: pick best route (ERC20/ETH only),
       compute limit & calldata, and return msg.value too. */
    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline // normal for V2; Sushi uses max sentinel; zAMM can use sentinel if retro
    )
        public
        view
        returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue)
    {
        return ZQUOTER_BASE.buildBestSwap(
            to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline
        );
    }

    function _spacingFromBps(uint16 bps) internal pure returns (int24) {
        unchecked {
            if (bps == 1) return 1;
            if (bps == 5) return 10;
            if (bps == 30) return 60;
            if (bps == 100) return 200;
            return int24(uint24(bps));
        }
    }

    /* msg.value rule (matches zRouter):
       tokenIn==ETH → exactIn: swapAmount, exactOut: amountLimit; else 0. */
    function _requiredMsgValue(
        bool exactOut,
        address tokenIn,
        uint256 swapAmount,
        uint256 amountLimit
    ) internal pure returns (uint256) {
        return tokenIn == address(0) ? (exactOut ? amountLimit : swapAmount) : 0;
    }

    // ** MULTIHOP HELPER

    error ZeroAmount();

    function buildBestSwapViaETHMulticall(
        address to,
        address refundTo,
        bool exactOut, // overall: false = exactIn, true = exactOut (on tokenOut)
        address tokenIn, // ERC20 or address(0) for ETH
        address tokenOut, // ERC20 or address(0) for ETH
        uint256 swapAmount, // exactIn: amount of tokenIn; exactOut: desired tokenOut
        uint256 slippageBps, // per-leg bound
        uint256 deadline
    )
        public
        view
        returns (
            Quote memory a,
            Quote memory b,
            bytes[] memory calls,
            bytes memory multicall,
            uint256 msgValue
        )
    {
        unchecked {
            require(swapAmount != 0, ZeroAmount());

            uint256 n;
            uint256 k;

            // --- single hop if either side is native ETH (router abstracts WETH) ---
            if (
                tokenIn == address(0) || tokenOut == address(0) || tokenIn == WETH
                    || tokenOut == WETH
            ) {
                (Quote memory best, bytes memory callData,, uint256 val) = buildBestSwap(
                    to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline
                );

                // No sweeps; router won’t strand dust even if `to == ZROUTER`
                calls = new bytes[](1);
                calls[0] = callData;

                // return (a=best, b=empty):
                a = best;
                b = Quote(AMM.UNI_V2, 0, 0, 0);
                msgValue = val;

                multicall = abi.encodeWithSelector(IRouterExt.multicall.selector, calls);
                return (a, b, calls, multicall, msgValue);
            }

            // --- two-hop via WETH as middle ---
            address MID = WETH;

            uint256 leg1AmountLimit;
            uint256 leg2AmountLimit;
            uint256 midAmtForLeg2;

            if (!exactOut) {
                // overall exactIn:
                // leg A: exactIn tokenIn -> WETH
                (a,) = getQuotes(false, tokenIn, MID, swapAmount);
                if (a.amountOut == 0) revert NoRoute();

                // min WETH to enforce for hop-1
                midAmtForLeg2 = SlippageLib.limit(false, a.amountOut, slippageBps);
                leg1AmountLimit = midAmtForLeg2;

                // leg B: exactIn WETH -> tokenOut on that min WETH
                (b,) = getQuotes(false, MID, tokenOut, midAmtForLeg2);
                if (b.amountOut == 0) revert NoRoute();
                leg2AmountLimit = SlippageLib.limit(false, b.amountOut, slippageBps);
            } else {
                // leg B: exactOut WETH -> tokenOut
                (b,) = getQuotes(true, MID, tokenOut, swapAmount);
                if (b.amountIn == 0) revert NoRoute();
                uint256 midRequired = b.amountIn;
                uint256 midLimit = SlippageLib.limit(true, midRequired, slippageBps); // hop-2 maxIn
                leg2AmountLimit = midLimit;

                // If hop-2 is V2/Sushi, prefund exactly the quoted input; otherwise produce up to the limit.
                bool prefundV2 = (b.source == AMM.UNI_V2 || b.source == AMM.SUSHI);
                uint256 midToProduce = prefundV2 ? midRequired : midLimit;

                // leg A: exactOut tokenIn -> WETH to mint `midToProduce`
                (a,) = getQuotes(true, tokenIn, MID, midToProduce);
                if (a.amountIn == 0) revert NoRoute();
                leg1AmountLimit = SlippageLib.limit(true, a.amountIn, slippageBps);
                midAmtForLeg2 = midToProduce;
            }

            // hop-1 recipient: pool-prefund only for V2/Sushi in overall exactOut; otherwise land at router
            address leg1To = ZROUTER;
            if (exactOut && (b.source == AMM.UNI_V2 || b.source == AMM.SUSHI)) {
                address tOut = tokenOut;
                (address pool,) = _v2PoolFor(MID, tOut, b.source == AMM.SUSHI);
                leg1To = pool; // push WETH to hop-2 pool; hop-2 consumes transient credit
            }

            // build hop-1
            bytes memory legAData = _buildCallForQuote(
                a,
                leg1To,
                /*exactOut*/
                exactOut, // hop-1 exactness mirrors overall
                tokenIn,
                MID,
                /*swapAmount*/
                exactOut ? midAmtForLeg2 : swapAmount,
                leg1AmountLimit,
                deadline
            );

            // build hop-2
            bytes memory legBData = _buildCallForQuote(
                b,
                to,
                /*exactOut*/
                exactOut,
                MID,
                tokenOut,
                /*swapAmount*/
                exactOut ? swapAmount : midAmtForLeg2,
                leg2AmountLimit,
                deadline
            );

            // safety sweeps (return router-held dust to refundTo)
            bool zamm2ExactOut = exactOut && (b.source == AMM.ZAMM);

            // Only need mid sweep when hop-1 lands mid at router and hop-2 isn't zAMM exact-out
            bool needWethSweep = (!zamm2ExactOut) && (leg1To == ZROUTER);
            // If hop-1 is zAMM exact-out to the router, zRouter pre-pulls up to amountLimit;
            // any leftover tokenIn would otherwise sit on the router
            bool needInSweep = (a.source == AMM.ZAMM) && exactOut && (leg1To == ZROUTER);

            // assemble calls
            n = 2 + (needWethSweep ? 2 : 0) + (needInSweep ? 1 : 0); // unwrap + sweep(ETH) if needed
            calls = new bytes[](n);
            k = 0;
            calls[k++] = legAData;
            calls[k++] = legBData;

            if (needWethSweep) {
                // unwrap all router-held WETH then sweep ETH to refundTo
                calls[k++] = abi.encodeWithSelector(IRouterExt.unwrap.selector, 0);
                calls[k++] =
                    abi.encodeWithSelector(IRouterExt.sweep.selector, address(0), 0, 0, refundTo);
            }
            if (needInSweep) {
                calls[k++] =
                    abi.encodeWithSelector(IRouterExt.sweep.selector, tokenIn, 0, 0, refundTo);
            }

            // Encoded calldata to send to ZROUTER (value = msgValue):
            multicall = abi.encodeWithSelector(IRouterExt.multicall.selector, calls);

            // msg.value only needed for hop-1 if tokenIn is native ETH (router rule):
            msgValue = _requiredMsgValue(
                /*exactOut*/
                exactOut,
                tokenIn,
                /*swapAmount*/
                exactOut ? midAmtForLeg2 : swapAmount,
                /*amountLimit*/
                leg1AmountLimit
            );
        }
    }

    /*──────────────── helpers ───────────────*/

    function _buildCallForQuote(
        Quote memory q,
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        unchecked {
            if (q.source == AMM.UNI_V2) {
                callData =
                    _buildV2Swap(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline);
            } else if (q.source == AMM.SUSHI) {
                callData = _buildV2Swap(
                    to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, type(uint256).max
                );
            } else if (q.source == AMM.ZAMM) {
                callData = _buildZAMMSwap(
                    to,
                    exactOut,
                    q.feeBps,
                    tokenIn,
                    tokenOut,
                    0,
                    0,
                    swapAmount,
                    amountLimit,
                    deadline
                );
            } else if (q.source == AMM.UNI_V3) {
                callData = _buildV3Swap(
                    to,
                    exactOut,
                    uint24(q.feeBps * 100),
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    amountLimit,
                    deadline
                );
            } else if (q.source == AMM.UNI_V4) {
                int24 spacing = _spacingFromBps(uint16(q.feeBps));
                callData = _buildV4Swap(
                    to,
                    exactOut,
                    uint24(q.feeBps * 100),
                    spacing,
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    amountLimit,
                    deadline
                );
            } else {
                revert UnsupportedAMM();
            }
        }
    }
}

function _sortTokens(address tokenA, address tokenB)
    pure
    returns (address token0, address token1, bool zeroForOne)
{
    (token0, token1) = (zeroForOne = tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
}

address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant ZROUTER = 0x0000000000404FECAf36E6184245475eE1254835;

interface IRouterExt {
    function unwrap(uint256 amount) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
    function sweep(address token, uint256 id, uint256 amount, address to) external payable;
}

address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
bytes32 constant V2_POOL_INIT_CODE_HASH =
    0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant SUSHI_FACTORY = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
bytes32 constant SUSHI_POOL_INIT_CODE_HASH =
    0xe18a34eb0e04b04f7a0ac29a6e80748dca96319b42c54d679cb821dca90c6303;

library SlippageLib {
    uint256 constant BPS = 10_000;

    function limit(bool exactOut, uint256 quoted, uint256 bps) internal pure returns (uint256) {
        unchecked {
            if (exactOut) {
                // maxIn = ceil(quotedIn * (1 + bps/BPS))
                return (quoted * (BPS + bps) + BPS - 1) / BPS;
            } else {
                // minOut = floor(quotedOut * (1 - bps/BPS))
                return (quoted * (BPS - bps)) / BPS;
            }
        }
    }
}

interface IZRouter {
    function swapV2(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapVZ(
        address to,
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}
