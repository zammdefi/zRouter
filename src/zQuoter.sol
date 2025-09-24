// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

zQuoter constant ZQUOTER_BASE = zQuoter(0x658bF1A6608210FDE7310760f391AD4eC8006A5F);

contract zQuoter {
    enum AMM {
        UNI_V2,
        SUSHI,
        ZAMM,
        UNI_V3,
        UNI_V4,
        CURVE
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

    function _asCurveQuote(uint256 amountIn, uint256 amountOut)
        internal
        pure
        returns (Quote memory q)
    {
        q.source = AMM.CURVE;
        q.feeBps = 0;
        q.amountIn = amountIn;
        q.amountOut = amountOut;
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

    // ** CURVE

    // ====================== QUOTE (auto-discover via MetaRegistry) ======================

    // Accumulator to keep best candidate off the stack
    struct CurveAcc {
        uint256 bestOut;
        uint256 bestIn;
        address bestPool;
        bool usedUnderlying;
        bool usedStable;
        uint8 iIdx;
        uint8 jIdx;
    }

    // Single-hop Curve quote with deterministic discovery, returns coin indices too
    function quoteCurve(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 maxCandidates // e.g. 8, 0 = unlimited
    )
        public
        view
        returns (
            uint256 amountIn,
            uint256 amountOut,
            address bestPool,
            bool usedUnderlying,
            bool usedStable,
            uint8 iIndex,
            uint8 jIndex
        )
    {
        if (swapAmount == 0) return (0, 0, address(0), false, true, 0, 0);

        // trivial ETH<->WETH (1:1) — let base path handle; we won't override with Curve
        if (
            (tokenIn == address(0) && tokenOut == WETH)
                || (tokenIn == WETH && tokenOut == address(0))
        ) {
            return (0, 0, address(0), false, true, 0, 0);
        }

        address a = tokenIn == address(0) ? CURVE_ETH : tokenIn;
        address b = tokenOut == address(0) ? CURVE_ETH : tokenOut;

        address[] memory pools = ICurveMetaRegistry(CURVE_METAREGISTRY).find_pools_for_coins(a, b);
        uint256 limit_ =
            (maxCandidates == 0 || maxCandidates > pools.length) ? pools.length : maxCandidates;

        CurveAcc memory acc;
        acc.bestIn = type(uint256).max;

        for (uint256 k; k < limit_; ++k) {
            address pool = pools[k];
            if (pool.code.length == 0) continue;

            (int128 i, int128 j, bool underlying) =
                ICurveMetaRegistry(CURVE_METAREGISTRY).get_coin_indices(pool, a, b, 0);

            if (i < 0 || j < 0) continue;

            (bool ok, uint256 qIn, uint256 qOut, bool isStable) =
                _curveTryQuoteOne(pool, exactOut, i, j, underlying, swapAmount);
            if (!ok) continue;

            if (exactOut) {
                if (qIn < acc.bestIn) {
                    acc.bestIn = qIn;
                    acc.bestOut = swapAmount;
                    acc.bestPool = pool;
                    acc.usedUnderlying = (underlying && isStable);
                    acc.usedStable = isStable;
                    acc.iIdx = uint8(uint256(int256(i)));
                    acc.jIdx = uint8(uint256(int256(j)));
                }
            } else {
                if (qOut > acc.bestOut) {
                    acc.bestOut = qOut;
                    acc.bestIn = swapAmount;
                    acc.bestPool = pool;
                    acc.usedUnderlying = (underlying && isStable);
                    acc.usedStable = isStable;
                    acc.iIdx = uint8(uint256(int256(i)));
                    acc.jIdx = uint8(uint256(int256(j)));
                }
            }
        }

        if (acc.bestPool == address(0)) return (0, 0, address(0), false, true, 0, 0);

        amountIn = exactOut ? acc.bestIn : swapAmount;
        amountOut = exactOut ? swapAmount : acc.bestOut;
        bestPool = acc.bestPool;
        usedUnderlying = acc.usedUnderlying;
        usedStable = acc.usedStable;
        iIndex = acc.iIdx;
        jIndex = acc.jIdx;
    }

    // Single-pool quote with ABI autodetect (stable first, else crypto).
    function _curveTryQuoteOne(
        address pool,
        bool exactOut,
        int128 i,
        int128 j,
        bool underlying,
        uint256 amt
    ) internal view returns (bool ok, uint256 amountIn, uint256 amountOut, bool usedStable) {
        // try stable (and underlying) first
        {
            bytes memory cd = exactOut
                ? (
                    underlying
                        ? abi.encodeWithSelector(ICurveStableLike.get_dx_underlying.selector, i, j, amt)
                        : abi.encodeWithSelector(ICurveStableLike.get_dx.selector, i, j, amt)
                )
                : (
                    underlying
                        ? abi.encodeWithSelector(ICurveStableLike.get_dy_underlying.selector, i, j, amt)
                        : abi.encodeWithSelector(ICurveStableLike.get_dy.selector, i, j, amt)
                );
            (bool s, bytes memory r) = pool.staticcall(cd);
            if (s && r.length >= 32) {
                uint256 q = abi.decode(r, (uint256));
                usedStable = true;
                if (exactOut) return (true, q, amt, true);
                else return (true, amt, q, true);
            }
        }

        // fallback: crypto ABI
        uint256 ui = uint256(int256(i));
        uint256 uj = uint256(int256(j));
        (bool s2, bytes memory r2) = pool.staticcall(
            exactOut
                ? abi.encodeWithSelector(ICurveCryptoLike.get_dx.selector, ui, uj, amt)
                : abi.encodeWithSelector(ICurveCryptoLike.get_dy.selector, ui, uj, amt)
        );
        if (!s2 || r2.length < 32) return (false, 0, 0, false);
        uint256 q2 = abi.decode(r2, (uint256));
        if (exactOut) return (true, q2, amt, false);
        else return (true, amt, q2, false);
    }

    // ====================== BUILD CALLDATA (single-hop) ======================

    function _buildCurveSwapCalldata(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline,
        address pool,
        bool useUnderlying,
        bool isStable,
        uint8 iIndex,
        uint8 jIndex,
        uint256 amountIn,
        uint256 amountOut
    ) internal pure returns (bytes memory callData, uint256 amountLimit, uint256 msgValue) {
        // minimal 1-hop route
        address[11] memory route;
        uint256[4][5] memory swapParams;
        address[5] memory basePools;

        route[0] = tokenIn;
        route[1] = pool;
        route[2] = tokenOut;

        // swap_type: 1=exchange, 2=exchange_underlying
        uint256 st = (isStable && useUnderlying) ? 2 : 1;
        // pool_type: 10 (stable) or 20 (crypto)
        uint256 pt = isStable ? 10 : 20;

        // pass real i/j indices
        swapParams[0] = [uint256(iIndex), uint256(jIndex), st, pt];

        uint256 quoted = exactOut ? amountIn : amountOut;
        amountLimit = SlippageLib.limit(exactOut, quoted, slippageBps);

        callData = abi.encodeWithSelector(
            IZRouter.swapCurve.selector,
            to,
            exactOut,
            route,
            swapParams,
            basePools,
            swapAmount,
            amountLimit,
            deadline
        );

        // msg.value rule identical to V2/V3/V4/ZAMM
        msgValue = (tokenIn == address(0)) ? (exactOut ? amountLimit : swapAmount) : 0;
    }

    // ====================== TOP-LEVEL BUILDER (with Curve override) ======================

    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    )
        public
        view
        returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue)
    {
        unchecked {
            // 1) get best among V2/Sushi/zAMM/V3/V4
            (best,) = getQuotes(exactOut, tokenIn, tokenOut, swapAmount);
            if (best.amountIn == 0 && best.amountOut == 0) revert NoRoute();

            uint256 quoted = exactOut ? best.amountIn : best.amountOut;
            amountLimit = SlippageLib.limit(exactOut, quoted, slippageBps);

            // construct base calldata
            if (best.source == AMM.UNI_V2) {
                callData =
                    _buildV2Swap(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline);
            } else if (best.source == AMM.SUSHI) {
                callData = _buildV2Swap(
                    to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, type(uint256).max
                );
            } else if (best.source == AMM.ZAMM) {
                callData = _buildZAMMSwap(
                    to,
                    exactOut,
                    best.feeBps,
                    tokenIn,
                    tokenOut,
                    0,
                    0,
                    swapAmount,
                    amountLimit,
                    deadline
                );
            } else if (best.source == AMM.UNI_V3) {
                callData = _buildV3Swap(
                    to,
                    exactOut,
                    uint24(best.feeBps * 100),
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    amountLimit,
                    deadline
                );
            } else if (best.source == AMM.UNI_V4) {
                int24 spacing = _spacingFromBps(uint16(best.feeBps));
                callData = _buildV4Swap(
                    to,
                    exactOut,
                    uint24(best.feeBps * 100),
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
            msgValue = _requiredMsgValue(exactOut, tokenIn, swapAmount, amountLimit);

            // 2) compute Curve candidate and only replace if strictly better
            (
                uint256 cin,
                uint256 cout,
                address pool,
                bool useUnderlying,
                bool isStable,
                uint8 iIdx,
                uint8 jIdx
            ) = quoteCurve(exactOut, tokenIn, tokenOut, swapAmount, 8 /*cap*/ );

            // Skip exactOut stable-underlying when both indices are base coins,
            // because deployed zRouter expects basePools[i] for the backward get_dx.
            if (exactOut && isStable && useUnderlying && iIdx > 0 && jIdx > 0) {
                return (best, callData, amountLimit, msgValue);
            }

            // no Curve route → keep base
            if (pool == address(0)) return (best, callData, amountLimit, msgValue);

            bool takeCurve = exactOut ? (cin < best.amountIn) : (cout > best.amountOut);
            if (!takeCurve) return (best, callData, amountLimit, msgValue);

            // Curve wins → build its calldata & replace
            (bytes memory cCall, uint256 cLimit, uint256 cMsg) = _buildCurveSwapCalldata(
                to,
                exactOut,
                tokenIn,
                tokenOut,
                swapAmount,
                slippageBps,
                deadline,
                pool,
                useUnderlying,
                isStable,
                iIdx,
                jIdx,
                cin,
                cout
            );

            if (cCall.length == 0) return (best, callData, amountLimit, msgValue);

            best = _asCurveQuote(cin, cout);
            callData = cCall;
            amountLimit = cLimit;
            msgValue = cMsg;

            return (best, callData, amountLimit, msgValue);
        }
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

    function _bestSingleHop(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 slippageBps,
        uint256 deadline
    )
        internal
        view
        returns (bool ok, Quote memory q, bytes memory data, uint256 amountLimit, uint256 msgValue)
    {
        (q,) = getQuotes(exactOut, tokenIn, tokenOut, amount);
        if (q.amountIn == 0 && q.amountOut == 0) return (false, q, bytes(""), 0, 0);

        // Safe now: buildBestSwap will not revert since a route exists
        (q, data, amountLimit, msgValue) =
            buildBestSwap(to, exactOut, tokenIn, tokenOut, amount, slippageBps, deadline);
        return (true, q, data, amountLimit, msgValue);
    }

    // ** MULTIHOP HELPER

    error ZeroAmount();

    function buildBestSwapViaETHMulticall(
        address to,
        address refundTo,
        bool exactOut, // false = exactIn, true = exactOut (on tokenOut)
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

            // ---------- FAST PATH #1: only short-circuit pure ETH<->WETH wrap/unwrap ----------
            bool trivialWrap = (tokenIn == address(0) && tokenOut == WETH)
                || (tokenIn == WETH && tokenOut == address(0));
            if (trivialWrap) {
                (bool ok, Quote memory best, bytes memory callData,, uint256 val) = _bestSingleHop(
                    to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline
                );
                if (!ok) revert NoRoute();

                calls = new bytes[](1);
                calls[0] = callData;

                a = best;
                b = Quote(AMM.UNI_V2, 0, 0, 0);
                msgValue = val;

                multicall = abi.encodeWithSelector(IRouterExt.multicall.selector, calls);
                return (a, b, calls, multicall, msgValue);
            }

            // ---------- FAST PATH #2: direct ERC20↔ERC20 single-hop (may be Curve/V2/V3/V4/zAMM) ----------
            {
                (bool ok, Quote memory best, bytes memory callData,, uint256 val) = _bestSingleHop(
                    to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline
                );
                if (ok) {
                    calls = new bytes[](1);
                    calls[0] = callData;

                    a = best;
                    b = Quote(AMM.UNI_V2, 0, 0, 0);
                    msgValue = val;

                    multicall = abi.encodeWithSelector(IRouterExt.multicall.selector, calls);
                    return (a, b, calls, multicall, msgValue);
                }
            }

            // ---------- HUB LIST (majors) ----------
            address[6] memory HUBS = [WETH, USDC, USDT, DAI, WBTC, WSTETH];

            // Track the best hub plan we can actually build
            bool haveBest;
            bool bestExactOut = exactOut;
            address bestMID;
            Quote memory bestA;
            Quote memory bestB;
            bytes memory bestCA;
            bytes memory bestCB;
            bool bestNeedMidSweep; // only used in exactOut paths
            bool bestNeedInSweep; // only used in exactOut paths
            bool bestMidIsWethOrEth; // MID == WETH (ETH handling uses unwrap+sweep)
            uint256 bestScoreIn; // minimal input (for exactOut)
            uint256 bestScoreOut; // maximal output (for exactIn)

            for (uint256 h; h < HUBS.length; ++h) {
                address MID = HUBS[h];
                if (MID == tokenIn || MID == tokenOut) continue;

                if (!exactOut) {
                    // ---- overall exactIn: maximize final output ----
                    (bool okA, Quote memory qa, bytes memory ca,,) = _bestSingleHop(
                        ZROUTER, false, tokenIn, MID, swapAmount, slippageBps, deadline
                    );
                    if (!okA || qa.amountOut == 0) continue;

                    uint256 midAmtForLeg2 = SlippageLib.limit(false, qa.amountOut, slippageBps);
                    (bool okB, Quote memory qb, bytes memory cb,,) = _bestSingleHop(
                        to, false, MID, tokenOut, midAmtForLeg2, slippageBps, deadline
                    );
                    if (!okB || qb.amountOut == 0) continue;

                    uint256 scoreOut = qb.amountOut; // maximize

                    if (!haveBest || scoreOut > bestScoreOut) {
                        haveBest = true;
                        bestMID = MID;
                        bestExactOut = false;
                        bestA = qa;
                        bestB = qb;
                        bestCA = ca;
                        bestCB = cb;
                        bestNeedMidSweep = false; // none for exactIn
                        bestNeedInSweep = false;
                        bestMidIsWethOrEth = (MID == WETH);
                        bestScoreOut = scoreOut;
                    }
                } else {
                    // ---- overall exactOut: minimize total input ----
                    (bool okB, Quote memory qb, bytes memory cb,,) =
                        _bestSingleHop(to, true, MID, tokenOut, swapAmount, slippageBps, deadline);
                    if (!okB || qb.amountIn == 0) continue;

                    uint256 midRequired = qb.amountIn;
                    uint256 midLimit = SlippageLib.limit(true, midRequired, slippageBps);
                    bool prefundV2 = (qb.source == AMM.UNI_V2 || qb.source == AMM.SUSHI);
                    uint256 midToProduce = prefundV2 ? midRequired : midLimit;

                    address leg1To = ZROUTER;
                    if (prefundV2) {
                        (address v2pool,) = _v2PoolFor(MID, tokenOut, (qb.source == AMM.SUSHI));
                        if (v2pool == address(0) || v2pool.code.length == 0) continue;
                        leg1To = v2pool;
                    }

                    (bool okA, Quote memory qa, bytes memory ca,,) = _bestSingleHop(
                        leg1To, true, tokenIn, MID, midToProduce, slippageBps, deadline
                    );
                    if (!okA || qa.amountIn == 0) continue;

                    uint256 scoreIn = qa.amountIn; // minimize

                    bool zamm2ExactOut = (qb.source == AMM.ZAMM);
                    bool needMidSweep = (!prefundV2) && (!zamm2ExactOut) && (leg1To == ZROUTER);
                    bool midIsWethOrEth = (MID == WETH);
                    bool needInSweep = (qa.source == AMM.ZAMM) && (leg1To == ZROUTER);

                    if (!haveBest || scoreIn < bestScoreIn) {
                        haveBest = true;
                        bestMID = MID;
                        bestExactOut = true;
                        bestA = qa;
                        bestB = qb;
                        bestCA = ca;
                        bestCB = cb;
                        bestNeedMidSweep = needMidSweep;
                        bestNeedInSweep = needInSweep;
                        bestMidIsWethOrEth = midIsWethOrEth;
                        bestScoreIn = scoreIn;
                    }
                }
            }

            if (!haveBest) revert NoRoute();

            // ---------- materialize the chosen plan into calls ----------
            if (!bestExactOut) {
                // exactIn path: two calls, no sweeps (router consumes mid)
                calls = new bytes[](2);
                calls[0] = bestCA; // hop-1 tokenIn -> MID (exactIn)
                calls[1] = bestCB; // hop-2 MID -> tokenOut (exactIn)
                a = bestA;
                b = bestB;
                // If tokenIn is ETH, hop-1 needs ETH for exactIn
                msgValue = (tokenIn == address(0)) ? swapAmount : 0;
            } else {
                // exactOut path: two calls + optional dust sweeps
                uint256 extra = (bestNeedMidSweep ? (bestMidIsWethOrEth ? 2 : 1) : 0)
                    + (bestNeedInSweep ? 1 : 0);
                calls = new bytes[](2 + extra);

                uint256 k;
                calls[k++] = bestCA; // hop-1 tokenIn -> MID (exactOut)
                calls[k++] = bestCB; // hop-2 MID -> tokenOut (exactOut)

                if (bestNeedMidSweep) {
                    if (bestMidIsWethOrEth) {
                        calls[k++] = abi.encodeWithSelector(IRouterExt.unwrap.selector, 0);
                        calls[k++] = abi.encodeWithSelector(
                            IRouterExt.sweep.selector, address(0), 0, 0, refundTo
                        );
                    } else {
                        calls[k++] = abi.encodeWithSelector(
                            IRouterExt.sweep.selector, bestMID, 0, 0, refundTo
                        );
                    }
                }
                if (bestNeedInSweep) {
                    calls[k++] =
                        abi.encodeWithSelector(IRouterExt.sweep.selector, tokenIn, 0, 0, refundTo);
                }

                a = bestA;
                b = bestB;
                // If tokenIn is ETH, hop-1 exactOut needs ETH equal to its maxIn limit
                msgValue = (tokenIn == address(0))
                    ? SlippageLib.limit(true, bestA.amountIn, slippageBps)
                    : 0;
            }

            multicall = abi.encodeWithSelector(IRouterExt.multicall.selector, calls);
            return (a, b, calls, multicall, msgValue);
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
    ) internal view returns (bytes memory callData) {
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
            } else if (q.source == AMM.CURVE) {
                // Discover the concrete pool + indices for this hop
                (
                    /*amountIn*/
                    ,
                    /*amountOut*/
                    ,
                    address pool,
                    bool useUnderlying,
                    bool isStable,
                    uint8 iIdx,
                    uint8 jIdx
                ) = quoteCurve(exactOut, tokenIn, tokenOut, swapAmount, 8 /* cap candidates */ );

                if (pool == address(0)) revert NoRoute();
                // Refuse unsafe build for deployed router
                if (exactOut && isStable && useUnderlying && iIdx > 0 && jIdx > 0) revert NoRoute();

                // Minimal 1-hop route for zRouter.swapCurve
                address[11] memory route;
                uint256[4][5] memory swapParams;
                address[5] memory basePools; // empty for simple exchange

                route[0] = tokenIn; // can be ETH(0x0) or ERC20
                route[1] = pool;
                route[2] = tokenOut; // can be ETH(0x0) or ERC20

                // swap_type: 1=exchange, 2=exchange_underlying
                uint256 st = (isStable && useUnderlying) ? 2 : 1;
                // pool_type: 10=stable, 20=crypto (router uses this to branch)
                uint256 pt = isStable ? 10 : 20;

                // Pass real i/j indices
                swapParams[0] = [uint256(iIdx), uint256(jIdx), st, pt];

                callData = abi.encodeWithSelector(
                    IZRouter.swapCurve.selector,
                    to,
                    exactOut,
                    route,
                    swapParams,
                    basePools,
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
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

address constant ZROUTER = 0x00000000008892d085e0611eb8C8BDc9FD856fD3;

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

// ** CURVE

// ---- MetaRegistry (mainnet) ----
address constant CURVE_METAREGISTRY = 0xF98B45FA17DE75FB1aD0e7aFD971b0ca00e379fC;
address constant CURVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

// ---- Curve interfaces ----
interface ICurveMetaRegistry {
    function find_pools_for_coins(address from, address to)
        external
        view
        returns (address[] memory);
    function get_coin_indices(address pool, address from, address to, uint256 handler_id)
        external
        view
        returns (int128 i, int128 j, bool isUnderlying);
}

interface ICurveStableLike {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function get_dx(int128 i, int128 j, uint256 dy) external view returns (uint256);
    // meta (underlying) variants
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function get_dx_underlying(int128 i, int128 j, uint256 dy) external view returns (uint256);
}

interface ICurveCryptoLike {
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function get_dx(uint256 i, uint256 j, uint256 dy) external view returns (uint256);
}

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

    function swapCurve(
        address to,
        bool exactOut,
        address[11] calldata route,
        uint256[4][5] calldata swapParams, // [i, j, swap_type, pool_type]
        address[5] calldata basePools, // for meta pools (only used by type=2 get_dx)
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}
