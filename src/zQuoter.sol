// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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
        unchecked {
            quotes = new Quote[](14); // V2 + SUSHI + ZAMM(4 FEE TIERS) + V3(4 FEE TIERS) + V4(4 FEE TIERS)

            // --- V2 / SUSHI / ZAMM ---
            (uint256 amountIn, uint256 amountOut) =
                quoteV2(exactOut, tokenIn, tokenOut, swapAmount, false);
            quotes[0] = Quote(AMM.UNI_V2, 30, amountIn, amountOut);

            (amountIn, amountOut) = quoteV2(exactOut, tokenIn, tokenOut, swapAmount, true);
            quotes[1] = Quote(AMM.SUSHI, 30, amountIn, amountOut);

            (amountIn, amountOut) = quoteZAMM(exactOut, 1, tokenIn, tokenOut, 0, 0, swapAmount);
            quotes[2] = Quote(AMM.ZAMM, 1, amountIn, amountOut);
            (amountIn, amountOut) = quoteZAMM(exactOut, 5, tokenIn, tokenOut, 0, 0, swapAmount);
            quotes[3] = Quote(AMM.ZAMM, 5, amountIn, amountOut);
            (amountIn, amountOut) = quoteZAMM(exactOut, 30, tokenIn, tokenOut, 0, 0, swapAmount);
            quotes[4] = Quote(AMM.ZAMM, 30, amountIn, amountOut);
            (amountIn, amountOut) = quoteZAMM(exactOut, 100, tokenIn, tokenOut, 0, 0, swapAmount);
            quotes[5] = Quote(AMM.ZAMM, 100, amountIn, amountOut);

            // --- Uniswap v3 (fees in v3 units; store bps in Quote) ---
            uint24[4] memory fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
            uint256 j = 6;
            for (uint256 i; i != fees.length; ++i) {
                (uint256 aIn, uint256 aOut) =
                    quoteV3(exactOut, tokenIn, tokenOut, fees[i], swapAmount);
                quotes[j++] = Quote(AMM.UNI_V3, fees[i] / 100, aIn, aOut);
            }

            // --- Uni v4 (no-hook) ---
            // Keep fee<->spacing paired so the builder can reconstruct spacing from feeBps:
            {
                uint24[4] memory v4Fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
                int24[4] memory v4Spaces = [int24(1), int24(10), int24(60), int24(200)];
                for (uint256 i; i != v4Fees.length; ++i) {
                    (amountIn, amountOut) = quoteV4(
                        exactOut, tokenIn, tokenOut, v4Fees[i], v4Spaces[i], address(0), swapAmount
                    );
                    quotes[j++] = Quote(AMM.UNI_V4, uint16(v4Fees[i] / 100), amountIn, amountOut); // 1/5/30/100 bps
                }
            }

            best = _pickBest(exactOut, quotes);
        }
    }

    function _pickBest(bool exactOut, Quote[] memory qs)
        internal
        pure
        returns (Quote memory best)
    {
        unchecked {
            bool init;
            for (uint256 i; i != qs.length; ++i) {
                Quote memory q = qs[i];
                // skip unavailable
                if (q.amountIn == 0 && q.amountOut == 0) continue;

                if (!init) {
                    best = q;
                    init = true;
                    continue;
                }

                if (!exactOut) {
                    // maximize amountOut
                    if (q.amountOut > best.amountOut) {
                        best = q;
                    } else if (q.amountOut == best.amountOut) {
                        if (q.amountIn < best.amountIn) best = q;
                        else if (q.amountIn == best.amountIn && q.feeBps < best.feeBps) best = q;
                    }
                } else {
                    // minimize amountIn
                    if (q.amountIn < best.amountIn) {
                        best = q;
                    } else if (q.amountIn == best.amountIn) {
                        if (q.amountOut > best.amountOut) best = q;
                        else if (q.amountOut == best.amountOut && q.feeBps < best.feeBps) best = q;
                    }
                }
            }
        }
    }

    // Single-helper functions for each zRouter AMM:

    function quoteV2(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        bool sushi
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        unchecked {
            if (swapAmount == 0) return (0, 0);
            // conform to zRouter: treat ETH as WETH for V2-style pools
            if (tokenIn == address(0)) tokenIn = WETH;
            if (tokenOut == address(0)) tokenOut = WETH;

            (address pool, bool zeroForOne) = _v2PoolFor(tokenIn, tokenOut, sushi);
            if (!_isContract(pool)) return (0, 0);
            (uint112 reserve0, uint112 reserve1,) = IV2Pool(pool).getReserves();
            (uint256 reserveIn, uint256 reserveOut) =
                zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
            if (reserveIn == 0 || reserveOut == 0) return (0, 0);
            if (exactOut) {
                if (swapAmount >= reserveOut) return (0, 0);
                amountIn = _getAmountIn(swapAmount, reserveIn, reserveOut);
                amountOut = swapAmount;
            } else {
                amountIn = swapAmount;
                amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);
            }
        }
    }

    function quoteV3(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        unchecked {
            address tIn = tokenIn == address(0) ? WETH : tokenIn;
            address tOut = tokenOut == address(0) ? WETH : tokenOut;

            address pool = IUniswapV3Factory(V3_FACTORY).getPool(tIn, tOut, fee);
            if (pool == address(0)) return (0, 0);

            uint160 sqrtPriceLimitX96 =
                tIn < tOut ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;

            if (!exactOut) {
                try IQuoter(V3_QUOTER).quoteExactInputSingleWithPool(
                    IQuoter.QuoteExactInputSingleWithPoolParams({
                        tokenIn: tIn,
                        tokenOut: tOut,
                        amountIn: swapAmount,
                        fee: fee,
                        pool: pool,
                        sqrtPriceLimitX96: sqrtPriceLimitX96
                    })
                ) returns (uint256 amtOut, uint160, uint32, uint256) {
                    return (swapAmount, amtOut);
                } catch {
                    return (0, 0);
                }
            } else {
                try IQuoter(V3_QUOTER).quoteExactOutputSingleWithPool(
                    IQuoter.QuoteExactOutputSingleWithPoolParams({
                        tokenIn: tIn,
                        tokenOut: tOut,
                        amount: swapAmount,
                        fee: fee,
                        pool: pool,
                        sqrtPriceLimitX96: sqrtPriceLimitX96
                    })
                ) returns (uint256 amtIn, uint160, uint32, uint256) {
                    return (amtIn, swapAmount);
                } catch {
                    return (0, 0);
                }
            }
        }
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
        unchecked {
            if (swapAmount == 0) return (0, 0);
            if (swapAmount > uint256(type(int256).max)) return (0, 0);

            // Build v4 pool id (native ETH supported)
            (bytes32 poolId, bool zeroForOne) =
                _v4PoolId(tokenIn, tokenOut, fee, tickSpacing, hooks);

            // Read core state
            (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
                IStateViewV4(V4_STATE_VIEW).getSlot0(poolId);
            uint128 liquidity = IStateViewV4(V4_STATE_VIEW).getLiquidity(poolId);

            // Uninitialized / empty pool
            if (sqrtPriceX96 == 0 || liquidity == 0) return (0, 0);

            // Use open price limits (same “±1” convention as v3 constants)
            uint160 sqrtPriceLimitX96 =
                zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;

            // **** v4 SIGN CONVENTION ****
            // exact-in  => amountRemaining < 0
            // exact-out => amountRemaining > 0
            int256 amountRemaining = exactOut ? int256(swapAmount) : -int256(swapAmount);
            int256 amountCalculated;

            while (amountRemaining != 0 && sqrtPriceX96 != sqrtPriceLimitX96) {
                (int24 tickNext, bool initialized) = V4TickBitmap.nextInitializedTickWithinOneWord(
                    V4_STATE_VIEW, poolId, tick, tickSpacing, zeroForOne
                );

                // clamp to TickMath bounds
                if (tickNext < TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
                else if (tickNext > TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;

                uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);

                // step within current tick (or to the limit)
                (uint160 sqrtPriceNext, uint256 stepIn, uint256 stepOut, uint256 feeAmt) = SwapMath
                    .computeSwapStep(
                    sqrtPriceX96,
                    (
                        zeroForOne
                            ? (sqrtPriceNextX96 < sqrtPriceLimitX96)
                            : (sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ) ? sqrtPriceLimitX96 : sqrtPriceNextX96,
                    liquidity,
                    amountRemaining,
                    protocolFee + lpFee
                );

                if (amountRemaining < 0) {
                    // exact-in: increase toward 0 by the spent input + fee
                    amountRemaining += int256(stepIn + feeAmt);
                    // received output is negative in the accumulator
                    amountCalculated -= int256(stepOut);
                } else {
                    // exact-out: decrease the remaining desired output
                    amountRemaining -= int256(stepOut);
                    // input required (including fee) is positive in the accumulator
                    amountCalculated += int256(stepIn + feeAmt);
                }

                if (sqrtPriceNext == sqrtPriceNextX96) {
                    // crossed a tick
                    if (initialized) {
                        (, int128 liqNet) =
                            IStateViewV4(V4_STATE_VIEW).getTickLiquidity(poolId, tickNext);
                        if (zeroForOne) liqNet = -liqNet; // mirror v3 sign flip when moving left
                        liquidity = LiquidityMath.addDelta(liquidity, liqNet);
                    }
                    tick = zeroForOne ? (tickNext - 1) : tickNext;
                } else if (sqrtPriceNext != sqrtPriceX96) {
                    tick = TickMath.getTickAtSqrtPrice(sqrtPriceNext);
                }

                sqrtPriceX96 = sqrtPriceNext;
            }

            // If we couldn't fulfill exact-out fully, report unavailable gracefully
            if (exactOut && amountRemaining != 0) return (0, 0);

            if (exactOut) {
                amountIn = uint256(amountCalculated);
                amountOut = swapAmount;
            } else {
                amountIn = swapAmount;
                amountOut = uint256(-amountCalculated);
            }
        }
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
        unchecked {
            if (swapAmount == 0) return (0, 0);
            (address token0, address token1, bool zeroForOne) = _sortTokens(tokenIn, tokenOut);
            (uint256 id0, uint256 id1) = tokenIn == token0 ? (idIn, idOut) : (idOut, idIn);
            PoolKey memory key = PoolKey(id0, id1, token0, token1, feeOrHook);
            uint256 poolId = uint256(keccak256(abi.encode(key)));
            (uint112 reserve0, uint112 reserve1,,,,,) = IZAMM(ZAMM).pools(poolId);
            (uint256 reserveIn, uint256 reserveOut) =
                zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
            if (reserveIn == 0 || reserveOut == 0) return (0, 0);
            if (exactOut) {
                if (swapAmount >= reserveOut) return (0, 0);
                amountIn = _getAmountIn(swapAmount, reserveIn, reserveOut, feeOrHook);
                amountOut = swapAmount;
            } else {
                amountIn = swapAmount;
                amountOut = _getAmountOut(amountIn, reserveIn, reserveOut, feeOrHook);
            }
        }
    }

    // ** V2-style calculations

    error InsufficientLiquidity();
    error InsufficientInputAmount();

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        unchecked {
            require(amountIn > 0, InsufficientInputAmount());
            require(reserveIn > 0 && reserveOut > 0, InsufficientLiquidity());
            uint256 amountInWithFee = amountIn * 997;
            uint256 numerator = amountInWithFee * reserveOut;
            uint256 denominator = reserveIn * 1000 + amountInWithFee;
            amountOut = numerator / denominator;
        }
    }

    error InsufficientOutputAmount();

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        unchecked {
            require(amountOut > 0, InsufficientOutputAmount());
            require(reserveIn > 0 && reserveOut > 0, InsufficientLiquidity());
            require(amountOut < reserveOut, InsufficientLiquidity());
            uint256 n = reserveIn * amountOut * 1000;
            uint256 d = (reserveOut - amountOut) * 997;
            amountIn = (n + d - 1) / d; // ceil-div to mirror zRouter
        }
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

    function _isContract(address a) internal view returns (bool) {
        return a.code.length != 0;
    }

    // ** ZAMM variants:

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 swapFee)
        internal
        pure
        returns (uint256 amountOut)
    {
        unchecked {
            uint256 amountInWithFee = amountIn * (10000 - swapFee);
            uint256 numerator = amountInWithFee * reserveOut;
            uint256 denominator = (reserveIn * 10000) + amountInWithFee;
            return numerator / denominator;
        }
    }

    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 swapFee)
        internal
        pure
        returns (uint256 amountIn)
    {
        unchecked {
            uint256 numerator = reserveIn * amountOut * 10000;
            uint256 denominator = (reserveOut - amountOut) * (10000 - swapFee);
            return (numerator / denominator) + 1;
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
        unchecked {
            (best,) = getQuotes(exactOut, tokenIn, tokenOut, swapAmount);
            if (best.amountIn == 0 && best.amountOut == 0) revert NoRoute();

            uint256 quoted = exactOut ? best.amountIn : best.amountOut;
            amountLimit = SlippageLib.limit(exactOut, quoted, slippageBps);

            if (best.source == AMM.UNI_V2) {
                callData =
                    _buildV2Swap(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline);
            } else if (best.source == AMM.SUSHI) {
                callData = _buildV2Swap(
                    to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, type(uint256).max
                );
            } else if (best.source == AMM.ZAMM) {
                // ERC20/ETH case: default ids to 0:
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
                    uint24(best.feeBps * 100), // convert bps to v3 units
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    amountLimit,
                    deadline
                );
            } else if (best.source == AMM.UNI_V4) {
                // Recover v4 fee & spacing from the Quote
                int24 spacing = _spacingFromBps(uint16(best.feeBps)); // 1/5/30/100 bps → 1/10/60/200
                callData = _buildV4Swap(
                    to,
                    exactOut,
                    uint24(best.feeBps * 100), // 1/5/30/100 bps → 100/500/3000/10000 pips
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
        returns (Quote memory a, Quote memory b, bytes[] memory calls, uint256 msgValue)
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

                // assemble: swap + safety sweeps
                n = 1 /*swap*/ + 2 /*sweep WETH+ETH*/
                    + ((tokenIn != address(0) && tokenIn != WETH) ? 1 : 0);
                calls = new bytes[](n);
                calls[k++] = callData;
                calls[k++] = abi.encodeWithSelector(
                    IRouterExt.sweep.selector, WETH, uint256(0), uint256(0), refundTo
                );
                calls[k++] = abi.encodeWithSelector(
                    IRouterExt.sweep.selector, address(0), uint256(0), uint256(0), refundTo
                );
                if (tokenIn != address(0) && tokenIn != WETH) {
                    calls[k++] = abi.encodeWithSelector(
                        IRouterExt.sweep.selector, tokenIn, uint256(0), uint256(0), refundTo
                    );
                }

                // return (a=best, b=empty)
                a = best;
                b = Quote(AMM.UNI_V2, 0, 0, 0);
                msgValue = val;
                return (a, b, calls, msgValue);
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

            bytes memory sweepWETHBack = zamm2ExactOut
                ? bytes("")
                : abi.encodeWithSelector(IRouterExt.sweep.selector, WETH, 0, 0, refundTo);
            bytes memory sweepETHBack = zamm2ExactOut
                ? bytes("")
                : abi.encodeWithSelector(IRouterExt.sweep.selector, address(0), 0, 0, refundTo);
            bytes memory sweepInBack = (tokenIn != WETH)
                ? abi.encodeWithSelector(IRouterExt.sweep.selector, tokenIn, 0, 0, refundTo)
                : bytes("");

            // assemble calls (only non-empty)
            n = 2 + (sweepWETHBack.length > 0 ? 1 : 0) + (sweepETHBack.length > 0 ? 1 : 0)
                + (sweepInBack.length > 0 ? 1 : 0);
            calls = new bytes[](n);
            k = 0;
            calls[k++] = legAData;
            calls[k++] = legBData;
            if (sweepWETHBack.length > 0) calls[k++] = sweepWETHBack;
            if (sweepETHBack.length > 0) calls[k++] = sweepETHBack;
            if (sweepInBack.length > 0) calls[k++] = sweepInBack;

            // msg.value only needed for hop-1 if tokenIn is native ETH (router rule)
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

    function _encodeMulticall(bytes[] memory data) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IRouterExt.multicall.selector, data);
    }
}

address constant ZROUTER = 0x0000000000404FECAf36E6184245475eE1254835;

interface IRouterExt {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
    function sweep(address token, uint256 id, uint256 amount, address to) external payable;
}

// Uniswap helpers:

address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
bytes32 constant V2_POOL_INIT_CODE_HASH =
    0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

// ** SushiSwap:

address constant SUSHI_FACTORY = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
bytes32 constant SUSHI_POOL_INIT_CODE_HASH =
    0xe18a34eb0e04b04f7a0ac29a6e80748dca96319b42c54d679cb821dca90c6303;

interface IV2Pool {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
}

// ZAMM helpers:

struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook;
}

address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;

interface IZAMM {
    function pools(uint256 poolId)
        external
        view
        returns (uint112, uint112, uint32, uint256, uint256, uint256, uint256);
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
}

// --- Uniswap v3 (Ethereum) ---
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

address constant V3_QUOTER = 0x5e55C9e631FAE526cd4B0526C4818D6e0a9eF0e3;

/// @title QuoterV2 Interface
/// @notice Supports quoting the calculated amounts from exact input or exact output swaps.
/// @notice For each pool also tells you the number of initialized ticks crossed and the sqrt price of the pool after the swap.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.
interface IQuoter {
    /// @notice Returns the amount out received for a given exact input swap without executing the swap
    /// @param path The path of the swap, i.e. each token pair and the pool fee
    /// @param amountIn The amount of the first token to swap
    /// @return amountOut The amount of the last token that would be received
    /// @return sqrtPriceX96AfterList List of the sqrt price after the swap for each pool in the path
    /// @return initializedTicksCrossedList List of number of initialized ticks loaded
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        view
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );

    struct QuoteExactInputSingleWithPoolParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        address pool;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Returns the amount out received for a given exact input but for a swap of a single pool
    /// @param params The params for the quote, encoded as `quoteExactInputSingleWithPool`
    /// tokenIn The token being swapped in
    /// amountIn The desired input amount
    /// tokenOut The token being swapped out
    /// fee The fee of the pool to consider for the pair
    /// pool The address of the pool to consider for the pair
    /// sqrtPriceLimitX96 The price limit of the pool that cannot be exceeded by the swap
    /// @return amountOut The amount of `tokenOut` that would be received
    /// @return sqrtPriceX96After The sqrt price of the pool after the swap
    /// @return initializedTicksCrossed The number of initialized ticks loaded
    function quoteExactInputSingleWithPool(QuoteExactInputSingleWithPoolParams memory params)
        external
        view
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );

    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Returns the amount out received for a given exact input but for a swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactInputSingleParams`
    /// tokenIn The token being swapped in
    /// amountIn The desired input amount
    /// tokenOut The token being swapped out
    /// fee The fee of the token pool to consider for the pair
    /// sqrtPriceLimitX96 The price limit of the pool that cannot be exceeded by the swap
    /// @return amountOut The amount of `tokenOut` that would be received
    /// @return sqrtPriceX96After The sqrt price of the pool after the swap
    /// @return initializedTicksCrossed The number of initialized ticks loaded
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        view
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );

    struct QuoteExactOutputSingleWithPoolParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        address pool;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Returns the amount in required to receive the given exact output amount but for a swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactOutputSingleWithPoolParams`
    /// tokenIn The token being swapped in
    /// tokenOut The token being swapped out
    /// amount The desired output amount
    /// fee The fee of the token pool to consider for the pair
    /// pool The address of the pool to consider for the pair
    /// sqrtPriceLimitX96 The price limit of the pool that cannot be exceeded by the swap
    /// @return amountIn The amount required as the input for the swap in order to receive `amountOut`
    /// @return sqrtPriceX96After The sqrt price of the pool after the swap
    /// @return initializedTicksCrossed The number of initialized ticks loaded
    function quoteExactOutputSingleWithPool(QuoteExactOutputSingleWithPoolParams memory params)
        external
        view
        returns (
            uint256 amountIn,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Returns the amount in required to receive the given exact output amount but for a swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactOutputSingleParams`
    /// tokenIn The token being swapped in
    /// tokenOut The token being swapped out
    /// amountOut The desired output amount
    /// fee The fee of the token pool to consider for the pair
    /// sqrtPriceLimitX96 The price limit of the pool that cannot be exceeded by the swap
    /// @return amountIn The amount required as the input for the swap in order to receive `amountOut`
    /// @return sqrtPriceX96After The sqrt price of the pool after the swap
    /// @return initializedTicksCrossed The number of initialized ticks loaded
    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        view
        returns (
            uint256 amountIn,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );

    /// @notice Returns the amount in required for a given exact output swap without executing the swap
    /// @param path The path of the swap, i.e. each token pair and the pool fee. Path must be provided in reverse order
    /// @param amountOut The amount of the last token to receive
    /// @return amountIn The amount of first token required to be paid
    /// @return sqrtPriceX96AfterList List of the sqrt price after the swap for each pool in the path
    /// @return initializedTicksCrossedList List of the initialized ticks that the swap crossed for each pool in the path
    function quoteExactOutput(bytes memory path, uint256 amountOut)
        external
        view
        returns (
            uint256 amountIn,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

// --- Uniswap v4 (Ethereum) ---
address constant V4_STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;

// Lens interface (subset)
interface IStateViewV4 {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
    function getTickBitmap(bytes32 poolId, int16 wordPos) external view returns (uint256);
    function getTickLiquidity(bytes32 poolId, int24 tick)
        external
        view
        returns (uint128 liquidityGross, int128 liquidityNet);
}

struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

function _v4PoolId(address tokenA, address tokenB, uint24 fee, int24 spacing, address hooks)
    pure
    returns (bytes32 poolId, bool zeroForOne)
{
    (address token0, address token1, bool zf1) = _sortTokens(tokenA, tokenB);
    zeroForOne = zf1;
    V4PoolKey memory key = V4PoolKey(token0, token1, fee, spacing, hooks);
    poolId = keccak256(abi.encode(key));
}

// General helpers:

function _sortTokens(address tokenA, address tokenB)
    pure
    returns (address token0, address token1, bool zeroForOne)
{
    (token0, token1) = (zeroForOne = tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
}

library V4TickBitmap {
    // Find the next initialized tick within the current bitmap word (like v3 PoolTickBitmap),
    // using the v4 StateView getTickBitmap() lens.
    function nextInitializedTickWithinOneWord(
        address stateView,
        bytes32 poolId,
        int24 tick,
        int24 tickSpacing,
        bool zeroForOne
    ) internal view returns (int24 next, bool initialized) {
        unchecked {
            int24 compressed = _compress(tick, tickSpacing);
            if (zeroForOne) {
                // search left (<=)
                (int16 wordPos, uint8 bitPos) = _position(compressed);
                uint256 mask = ((uint256(1) << (bitPos + 1)) - 1); // ones up to and including bitPos
                uint256 bitmap = IStateViewV4(stateView).getTickBitmap(poolId, wordPos);
                uint256 masked = bitmap & mask;
                initialized = masked != 0;
                if (initialized) {
                    // index of MSB in masked
                    uint8 msb = _msb(masked);
                    int24 offset = int24(uint24(bitPos) - uint24(msb));
                    next = (compressed - offset) * tickSpacing;
                } else {
                    next = (compressed - int24(uint24(bitPos))) * tickSpacing - tickSpacing;
                }
            } else {
                // search right (>)
                (int16 wordPos, uint8 bitPos) = _position(compressed + 1);
                uint256 mask = ~((uint256(1) << bitPos) - 1); // ones from bitPos..255
                uint256 bitmap = IStateViewV4(stateView).getTickBitmap(poolId, wordPos);
                uint256 masked = bitmap & mask;
                initialized = masked != 0;
                if (initialized) {
                    // index of LSB in masked
                    uint8 lsb = _lsb(masked);
                    int24 offset = int24(int256(uint256(lsb)) - int24(uint24(bitPos)));
                    next = (compressed + 1 + offset) * tickSpacing;
                } else {
                    next = (compressed + 1 + int24(uint24(255) - uint24(bitPos))) * tickSpacing;
                }
            }
        }
    }

    // ---- helpers ----

    function _compress(int24 tick, int24 spacing) private pure returns (int24 compressed) {
        compressed = tick / spacing;
        // round toward negative infinity
        if (tick < 0 && (tick % spacing != 0)) compressed--;
    }

    function _position(int24 tickCompressed) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tickCompressed >> 8); // /256
        bitPos = uint8(uint24(tickCompressed & 255)); // %256
    }

    error MSB_0();

    function _msb(uint256 x) private pure returns (uint8 r) {
        require(x != 0, MSB_0());
        if (x >= 2 ** 128) {
            x >>= 128;
            r += 128;
        }
        if (x >= 2 ** 64) {
            x >>= 64;
            r += 64;
        }
        if (x >= 2 ** 32) {
            x >>= 32;
            r += 32;
        }
        if (x >= 2 ** 16) {
            x >>= 16;
            r += 16;
        }
        if (x >= 2 ** 8) {
            x >>= 8;
            r += 8;
        }
        if (x >= 2 ** 4) {
            x >>= 4;
            r += 4;
        }
        if (x >= 2 ** 2) {
            x >>= 2;
            r += 2;
        }
        if (x >= 2 ** 1) r += 1;
    }

    error LSB_0();

    function _lsb(uint256 x) private pure returns (uint8) {
        require(x != 0, LSB_0());
        // isolate lowest set bit then reuse msb
        uint256 y = x & (~x + 1);
        return _msb(y);
    }
}

/// @title Math library for computing sqrt prices from ticks and vice versa
/// @notice Computes sqrt price for ticks of size 1.0001, i.e. sqrt(1.0001^tick) as fixed point Q64.96 numbers. Supports
/// prices between 2**-128 and 2**128
library TickMath {
    using CustomRevert for bytes4;

    /// @notice Thrown when the tick passed to #getSqrtPriceAtTick is not between MIN_TICK and MAX_TICK
    error InvalidTick(int24 tick);
    /// @notice Thrown when the price passed to #getTickAtSqrtPrice does not correspond to a price between MIN_TICK and MAX_TICK
    error InvalidSqrtPrice(uint160 sqrtPriceX96);

    /// @dev The minimum tick that may be passed to #getSqrtPriceAtTick computed from log base 1.0001 of 2**-128
    /// @dev If ever MIN_TICK and MAX_TICK are not centered around 0, the absTick logic in getSqrtPriceAtTick cannot be used
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtPriceAtTick computed from log base 1.0001 of 2**128
    /// @dev If ever MIN_TICK and MAX_TICK are not centered around 0, the absTick logic in getSqrtPriceAtTick cannot be used
    int24 internal constant MAX_TICK = 887272;

    /// @dev The minimum tick spacing value drawn from the range of type int16 that is greater than 0, i.e. min from the range [1, 32767]
    int24 internal constant MIN_TICK_SPACING = 1;
    /// @dev The maximum tick spacing value drawn from the range of type int16, i.e. max from the range [1, 32767]
    int24 internal constant MAX_TICK_SPACING = type(int16).max;

    /// @dev The minimum value that can be returned from #getSqrtPriceAtTick. Equivalent to getSqrtPriceAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtPriceAtTick. Equivalent to getSqrtPriceAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    /// @dev A threshold used for optimized bounds check, equals `MAX_SQRT_PRICE - MIN_SQRT_PRICE - 1`
    uint160 internal constant MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE =
        1461446703485210103287273052203988822378723970342 - 4295128739 - 1;

    /// @notice Given a tickSpacing, compute the maximum usable tick
    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            return (MAX_TICK / tickSpacing) * tickSpacing;
        }
    }

    /// @notice Given a tickSpacing, compute the minimum usable tick
    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            return (MIN_TICK / tickSpacing) * tickSpacing;
        }
    }

    /// @notice Calculates sqrt(1.0001^tick) * 2^96
    /// @dev Throws if |tick| > max tick
    /// @param tick The input tick for the above formula
    /// @return sqrtPriceX96 A Fixed point Q64.96 number representing the sqrt of the price of the two assets (currency1/currency0)
    /// at the given tick
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick;
            assembly ("memory-safe") {
                tick := signextend(2, tick)
                // mask = 0 if tick >= 0 else -1 (all 1s)
                let mask := sar(255, tick)
                // if tick >= 0, |tick| = tick = 0 ^ tick
                // if tick < 0, |tick| = ~~|tick| = ~(-|tick| - 1) = ~(tick - 1) = (-1) ^ (tick - 1)
                // either way, |tick| = mask ^ (tick + mask)
                absTick := xor(mask, add(mask, tick))
            }

            if (absTick > uint256(int256(MAX_TICK))) InvalidTick.selector.revertWith(tick);

            // The tick is decomposed into bits, and for each bit with index i that is set, the product of 1/sqrt(1.0001^(2^i))
            // is calculated (using Q128.128). The constants used for this calculation are rounded to the nearest integer

            // Equivalent to:
            //     price = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            //     or price = int(2**128 / sqrt(1.0001)) if (absTick & 0x1) else 1 << 128
            uint256 price;
            assembly ("memory-safe") {
                price :=
                    xor(
                        shl(128, 1),
                        mul(xor(shl(128, 1), 0xfffcb933bd6fad37aa2d162d1a594001), and(absTick, 0x1))
                    )
            }
            if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) price = (price * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) price = (price * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) price = (price * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) price = (price * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) price = (price * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) price = (price * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) price = (price * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) price = (price * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) price = (price * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) price = (price * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) price = (price * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) price = (price * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) price = (price * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) price = (price * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) price = (price * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) price = (price * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) price = (price * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) price = (price * 0x48a170391f7dc42444e8fa2) >> 128;

            assembly ("memory-safe") {
                // if (tick > 0) price = type(uint256).max / price;
                if sgt(tick, 0) { price := div(not(0), price) }

                // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
                // we then downcast because we know the result always fits within 160 bits due to our tick input constraint
                // we round up in the division so getTickAtSqrtPrice of the output price is always consistent
                // `sub(shl(32, 1), 1)` is `type(uint32).max`
                // `price + type(uint32).max` will not overflow because `price` fits in 192 bits
                sqrtPriceX96 := shr(32, add(price, sub(shl(32, 1), 1)))
            }
        }
    }

    /// @notice Calculates the greatest tick value such that getSqrtPriceAtTick(tick) <= sqrtPriceX96
    /// @dev Throws in case sqrtPriceX96 < MIN_SQRT_PRICE, as MIN_SQRT_PRICE is the lowest value getSqrtPriceAtTick may
    /// ever return.
    /// @param sqrtPriceX96 The sqrt price for which to compute the tick as a Q64.96
    /// @return tick The greatest tick for which the getSqrtPriceAtTick(tick) is less than or equal to the input sqrtPriceX96
    function getTickAtSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        unchecked {
            // Equivalent: if (sqrtPriceX96 < MIN_SQRT_PRICE || sqrtPriceX96 >= MAX_SQRT_PRICE) revert InvalidSqrtPrice();
            // second inequality must be >= because the price can never reach the price at the max tick
            // if sqrtPriceX96 < MIN_SQRT_PRICE, the `sub` underflows and `gt` is true
            // if sqrtPriceX96 >= MAX_SQRT_PRICE, sqrtPriceX96 - MIN_SQRT_PRICE > MAX_SQRT_PRICE - MIN_SQRT_PRICE - 1
            if ((sqrtPriceX96 - MIN_SQRT_PRICE) > MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE) {
                InvalidSqrtPrice.selector.revertWith(sqrtPriceX96);
            }

            uint256 price = uint256(sqrtPriceX96) << 32;

            uint256 r = price;
            uint256 msb = BitMath.mostSignificantBit(r);

            if (msb >= 128) r = price >> (msb - 127);
            else r = price << (127 - msb);

            int256 log_2 = (int256(msb) - 128) << 64;

            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(63, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(62, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(61, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(60, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(59, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(58, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(57, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(56, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(55, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(54, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(53, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(52, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(51, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(50, f))
            }

            int256 log_sqrt10001 = log_2 * 255738958999603826347141; // Q22.128 number

            // Magic number represents the ceiling of the maximum value of the error when approximating log_sqrt10001(x)
            int24 tickLow = int24((log_sqrt10001 - 3402992956809132418596140100660247210) >> 128);

            // Magic number represents the minimum value of the error when approximating log_sqrt10001(x), when
            // sqrtPrice is from the range (2^-64, 2^64). This is safe as MIN_SQRT_PRICE is more than 2^-64. If MIN_SQRT_PRICE
            // is changed, this may need to be changed too
            int24 tickHi = int24((log_sqrt10001 + 291339464771989622907027621153398088495) >> 128);

            tick = tickLow == tickHi
                ? tickLow
                : getSqrtPriceAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow;
        }
    }
}

/// @title BitMath
/// @dev This library provides functionality for computing bit properties of an unsigned integer
/// @author Solady (https://github.com/Vectorized/solady/blob/8200a70e8dc2a77ecb074fc2e99a2a0d36547522/src/utils/LibBit.sol)
library BitMath {
    /// @notice Returns the index of the most significant bit of the number,
    ///     where the least significant bit is at index 0 and the most significant bit is at index 255
    /// @param x the value for which to compute the most significant bit, must be greater than 0
    /// @return r the index of the most significant bit
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);

        assembly ("memory-safe") {
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            // forgefmt: disable-next-item
            r := or(r, byte(and(0x1f, shr(shr(r, x), 0x8421084210842108cc6318c6db6d54be)),
                0x0706060506020500060203020504000106050205030304010505030400000000))
        }
    }

    /// @notice Returns the index of the least significant bit of the number,
    ///     where the least significant bit is at index 0 and the most significant bit is at index 255
    /// @param x the value for which to compute the least significant bit, must be greater than 0
    /// @return r the index of the least significant bit
    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);

        assembly ("memory-safe") {
            // Isolate the least significant bit.
            x := and(x, sub(0, x))
            // For the upper 3 bits of the result, use a De Bruijn-like lookup.
            // Credit to adhusson: https://blog.adhusson.com/cheap-find-first-set-evm/
            // forgefmt: disable-next-item
            r := shl(5, shr(252, shl(shl(2, shr(250, mul(x,
                0xb6db6db6ddddddddd34d34d349249249210842108c6318c639ce739cffffffff))),
                0x8040405543005266443200005020610674053026020000107506200176117077)))
            // For the lower 5 bits of the result, use a De Bruijn lookup.
            // forgefmt: disable-next-item
            r := or(r, byte(and(div(0xd76453e0, shr(r, x)), 0x1f),
                0x001f0d1e100c1d070f090b19131c1706010e11080a1a141802121b1503160405))
        }
    }
}

/// @title Library for reverting with custom errors efficiently
/// @notice Contains functions for reverting with custom errors with different argument types efficiently
/// @dev To use this library, declare `using CustomRevert for bytes4;` and replace `revert CustomError()` with
/// `CustomError.selector.revertWith()`
/// @dev The functions may tamper with the free memory pointer but it is fine since the call context is exited immediately
library CustomRevert {
    /// @dev ERC-7751 error for wrapping bubbled up reverts
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);

    /// @dev Reverts with the selector of a custom error in the scratch space
    function revertWith(bytes4 selector) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            revert(0, 0x04)
        }
    }

    /// @dev Reverts with a custom error with an address argument in the scratch space
    function revertWith(bytes4 selector, address addr) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, and(addr, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with an int24 argument in the scratch space
    function revertWith(bytes4 selector, int24 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, signextend(2, value))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with a uint160 argument in the scratch space
    function revertWith(bytes4 selector, uint160 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, and(value, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with two int24 arguments
    function revertWith(bytes4 selector, int24 value1, int24 value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), signextend(2, value1))
            mstore(add(fmp, 0x24), signextend(2, value2))
            revert(fmp, 0x44)
        }
    }

    /// @dev Reverts with a custom error with two uint160 arguments
    function revertWith(bytes4 selector, uint160 value1, uint160 value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), and(value1, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x24), and(value2, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(fmp, 0x44)
        }
    }

    /// @dev Reverts with a custom error with two address arguments
    function revertWith(bytes4 selector, address value1, address value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), and(value1, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x24), and(value2, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(fmp, 0x44)
        }
    }

    /// @notice bubble up the revert message returned by a call and revert with a wrapped ERC-7751 error
    /// @dev this method can be vulnerable to revert data bombs
    function bubbleUpAndRevertWith(
        address revertingContract,
        bytes4 revertingFunctionSelector,
        bytes4 additionalContext
    ) internal pure {
        bytes4 wrappedErrorSelector = WrappedError.selector;
        assembly ("memory-safe") {
            // Ensure the size of the revert data is a multiple of 32 bytes
            let encodedDataSize := mul(div(add(returndatasize(), 31), 32), 32)

            let fmp := mload(0x40)

            // Encode wrapped error selector, address, function selector, offset, additional context, size, revert reason
            mstore(fmp, wrappedErrorSelector)
            mstore(
                add(fmp, 0x04), and(revertingContract, 0xffffffffffffffffffffffffffffffffffffffff)
            )
            mstore(
                add(fmp, 0x24),
                and(
                    revertingFunctionSelector,
                    0xffffffff00000000000000000000000000000000000000000000000000000000
                )
            )
            // offset revert reason
            mstore(add(fmp, 0x44), 0x80)
            // offset additional context
            mstore(add(fmp, 0x64), add(0xa0, encodedDataSize))
            // size revert reason
            mstore(add(fmp, 0x84), returndatasize())
            // revert reason
            returndatacopy(add(fmp, 0xa4), 0, returndatasize())
            // size additional context
            mstore(add(fmp, add(0xa4, encodedDataSize)), 0x04)
            // additional context
            mstore(
                add(fmp, add(0xc4, encodedDataSize)),
                and(
                    additionalContext,
                    0xffffffff00000000000000000000000000000000000000000000000000000000
                )
            )
            revert(fmp, add(0xe4, encodedDataSize))
        }
    }
}

/// @title Computes the result of a swap within ticks
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {
    /// @notice the swap fee is represented in hundredths of a bip, so the max is 100%
    /// @dev the swap fee is the total fee on a swap, including both LP and Protocol fee
    uint256 internal constant MAX_SWAP_FEE = 1e6;

    /// @notice Computes the sqrt price target for the next swap step
    /// @param zeroForOne The direction of the swap, true for currency0 to currency1, false for currency1 to currency0
    /// @param sqrtPriceNextX96 The Q64.96 sqrt price for the next initialized tick
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this value
    /// after the swap. If one for zero, the price cannot be greater than this value after the swap
    /// @return sqrtPriceTargetX96 The price target for the next swap step
    function getSqrtPriceTarget(
        bool zeroForOne,
        uint160 sqrtPriceNextX96,
        uint160 sqrtPriceLimitX96
    ) internal pure returns (uint160 sqrtPriceTargetX96) {
        assembly ("memory-safe") {
            // a flag to toggle between sqrtPriceNextX96 and sqrtPriceLimitX96
            // when zeroForOne == true, nextOrLimit reduces to sqrtPriceNextX96 >= sqrtPriceLimitX96
            // sqrtPriceTargetX96 = max(sqrtPriceNextX96, sqrtPriceLimitX96)
            // when zeroForOne == false, nextOrLimit reduces to sqrtPriceNextX96 < sqrtPriceLimitX96
            // sqrtPriceTargetX96 = min(sqrtPriceNextX96, sqrtPriceLimitX96)
            sqrtPriceNextX96 := and(sqrtPriceNextX96, 0xffffffffffffffffffffffffffffffffffffffff)
            sqrtPriceLimitX96 := and(sqrtPriceLimitX96, 0xffffffffffffffffffffffffffffffffffffffff)
            let nextOrLimit := xor(lt(sqrtPriceNextX96, sqrtPriceLimitX96), and(zeroForOne, 0x1))
            let symDiff := xor(sqrtPriceNextX96, sqrtPriceLimitX96)
            sqrtPriceTargetX96 := xor(sqrtPriceLimitX96, mul(symDiff, nextOrLimit))
        }
    }

    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev If the swap's amountSpecified is negative, the combined fee and input amount will never exceed the absolute value of the remaining amount.
    /// @param sqrtPriceCurrentX96 The current sqrt price of the pool
    /// @param sqrtPriceTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtPriceNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either currency0 or currency1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either currency0 or currency1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee
    /// @dev feePips must be no larger than MAX_SWAP_FEE for this function. We ensure that before setting a fee using LPFeeLibrary.isValid.
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount)
    {
        unchecked {
            uint256 _feePips = feePips; // upcast once and cache
            bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
            bool exactIn = amountRemaining < 0;

            if (exactIn) {
                uint256 amountRemainingLessFee = FullMath.mulDiv(
                    uint256(-amountRemaining), MAX_SWAP_FEE - _feePips, MAX_SWAP_FEE
                );
                amountIn = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(
                        sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, true
                    )
                    : SqrtPriceMath.getAmount1Delta(
                        sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true
                    );
                if (amountRemainingLessFee >= amountIn) {
                    // `amountIn` is capped by the target price
                    sqrtPriceNextX96 = sqrtPriceTargetX96;
                    feeAmount = _feePips == MAX_SWAP_FEE
                        ? amountIn // amountIn is always 0 here, as amountRemainingLessFee == 0 and amountRemainingLessFee >= amountIn
                        : FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
                } else {
                    // exhaust the remaining amount
                    amountIn = amountRemainingLessFee;
                    sqrtPriceNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                        sqrtPriceCurrentX96, liquidity, amountRemainingLessFee, zeroForOne
                    );
                    // we didn't reach the target, so take the remainder of the maximum input as fee
                    feeAmount = uint256(-amountRemaining) - amountIn;
                }
                amountOut = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(
                        sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, false
                    )
                    : SqrtPriceMath.getAmount0Delta(
                        sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false
                    );
            } else {
                amountOut = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(
                        sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, false
                    )
                    : SqrtPriceMath.getAmount0Delta(
                        sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, false
                    );
                if (uint256(amountRemaining) >= amountOut) {
                    // `amountOut` is capped by the target price
                    sqrtPriceNextX96 = sqrtPriceTargetX96;
                } else {
                    // cap the output amount to not exceed the remaining output amount
                    amountOut = uint256(amountRemaining);
                    sqrtPriceNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                        sqrtPriceCurrentX96, liquidity, amountOut, zeroForOne
                    );
                }
                amountIn = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(
                        sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, true
                    )
                    : SqrtPriceMath.getAmount1Delta(
                        sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true
                    );
                // `feePips` cannot be `MAX_SWAP_FEE` for exact out
                feeAmount = FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
            }
        }
    }
}

/// @title Contains 512-bit math functions
/// @notice Facilitates multiplication and division that can have overflow of an intermediate value without any loss of precision
/// @dev Handles "phantom overflow" i.e., allows multiplication and division where an intermediate value overflows 256 bits
library FullMath {
    /// @notice Calculates floor(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    /// @dev Credit to Remco Bloemen under MIT license https://xn--2-umb.com/21/muldiv
    function mulDiv(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0 = a * b; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Make sure the result is less than 2**256.
            // Also prevents denominator == 0
            require(denominator > prod1);

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                assembly ("memory-safe") {
                    result := div(prod0, denominator)
                }
                return result;
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, denominator)
            }
            // Subtract 256 bit number from 512 bit number
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator
            // Compute largest power of two divisor of denominator.
            // Always >= 1.
            uint256 twos = (0 - denominator) & denominator;
            // Divide denominator by power of two
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
            }

            // Divide [prod1 prod0] by the factors of two
            assembly ("memory-safe") {
                prod0 := div(prod0, twos)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            assembly ("memory-safe") {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse by starting with a seed that is correct
            // correct for four bits. That is, denominator * inv = 1 mod 2**4
            uint256 inv = (3 * denominator) ^ 2;
            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel's lifting lemma, this also works in modular
            // arithmetic, doubling the correct bits in each step.
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator. This will give us the
            // correct result modulo 2**256. Since the preconditions guarantee
            // that the outcome is less than 2**256, this is the final result.
            // We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inv;
            return result;
        }
    }

    /// @notice Calculates ceil(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        unchecked {
            result = mulDiv(a, b, denominator);
            if (mulmod(a, b, denominator) != 0) {
                require(++result > 0);
            }
        }
    }
}

/// @title Math library for liquidity
library LiquidityMath {
    /// @notice Add a signed liquidity delta to liquidity and revert if it overflows or underflows
    /// @param x The liquidity before change
    /// @param y The delta by which liquidity should be changed
    /// @return z The liquidity delta
    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        assembly ("memory-safe") {
            z := add(and(x, 0xffffffffffffffffffffffffffffffff), signextend(15, y))
            if shr(128, z) {
                // revert SafeCastOverflow()
                mstore(0, 0x93dafdf1)
                revert(0x1c, 0x04)
            }
        }
    }
}

/// @title Functions based on Q64.96 sqrt price and liquidity
/// @notice Contains the math that uses square root of price as a Q64.96 and liquidity to compute deltas
library SqrtPriceMath {
    using SafeCast for uint256;

    error InvalidPriceOrLiquidity();
    error InvalidPrice();
    error NotEnoughLiquidity();
    error PriceOverflow();

    /// @notice Gets the next sqrt price given a delta of currency0
    /// @dev Always rounds up, because in the exact output case (increasing price) we need to move the price at least
    /// far enough to get the desired output amount, and in the exact input case (decreasing price) we need to move the
    /// price less in order to not send too much output.
    /// The most precise formula for this is liquidity * sqrtPX96 / (liquidity +- amount * sqrtPX96),
    /// if this is impossible because of overflow, we calculate liquidity / (liquidity / sqrtPX96 +- amount).
    /// @param sqrtPX96 The starting price, i.e. before accounting for the currency0 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of currency0 to add or remove from virtual reserves
    /// @param add Whether to add or remove the amount of currency0
    /// @return The price after adding or removing amount, depending on add
    function getNextSqrtPriceFromAmount0RoundingUp(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amount,
        bool add
    ) internal pure returns (uint160) {
        // we short circuit amount == 0 because the result is otherwise not guaranteed to equal the input price
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;

        if (add) {
            unchecked {
                uint256 product = amount * sqrtPX96;
                if (product / amount == sqrtPX96) {
                    uint256 denominator = numerator1 + product;
                    if (denominator >= numerator1) {
                        // always fits in 160 bits
                        return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
                    }
                }
            }
            // denominator is checked for overflow
            return uint160(UnsafeMath.divRoundingUp(numerator1, (numerator1 / sqrtPX96) + amount));
        } else {
            unchecked {
                uint256 product = amount * sqrtPX96;
                // if the product overflows, we know the denominator underflows
                // in addition, we must check that the denominator does not underflow
                // equivalent: if (product / amount != sqrtPX96 || numerator1 <= product) revert PriceOverflow();
                assembly ("memory-safe") {
                    if iszero(
                        and(
                            eq(
                                div(product, amount),
                                and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff)
                            ),
                            gt(numerator1, product)
                        )
                    ) {
                        mstore(0, 0xf5c787f1) // selector for PriceOverflow()
                        revert(0x1c, 0x04)
                    }
                }
                uint256 denominator = numerator1 - product;
                return FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator).toUint160();
            }
        }
    }

    /// @notice Gets the next sqrt price given a delta of currency1
    /// @dev Always rounds down, because in the exact output case (decreasing price) we need to move the price at least
    /// far enough to get the desired output amount, and in the exact input case (increasing price) we need to move the
    /// price less in order to not send too much output.
    /// The formula we compute is within <1 wei of the lossless version: sqrtPX96 +- amount / liquidity
    /// @param sqrtPX96 The starting price, i.e., before accounting for the currency1 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of currency1 to add, or remove, from virtual reserves
    /// @param add Whether to add, or remove, the amount of currency1
    /// @return The price after adding or removing `amount`
    function getNextSqrtPriceFromAmount1RoundingDown(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amount,
        bool add
    ) internal pure returns (uint160) {
        // if we're adding (subtracting), rounding down requires rounding the quotient down (up)
        // in both cases, avoid a mulDiv for most inputs
        if (add) {
            uint256 quotient = (
                amount <= type(uint160).max
                    ? (amount << FixedPoint96.RESOLUTION) / liquidity
                    : FullMath.mulDiv(amount, FixedPoint96.Q96, liquidity)
            );

            return (uint256(sqrtPX96) + quotient).toUint160();
        } else {
            uint256 quotient = (
                amount <= type(uint160).max
                    ? UnsafeMath.divRoundingUp(amount << FixedPoint96.RESOLUTION, liquidity)
                    : FullMath.mulDivRoundingUp(amount, FixedPoint96.Q96, liquidity)
            );

            // equivalent: if (sqrtPX96 <= quotient) revert NotEnoughLiquidity();
            assembly ("memory-safe") {
                if iszero(gt(and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff), quotient)) {
                    mstore(0, 0x4323a555) // selector for NotEnoughLiquidity()
                    revert(0x1c, 0x04)
                }
            }
            // always fits 160 bits
            unchecked {
                return uint160(sqrtPX96 - quotient);
            }
        }
    }

    /// @notice Gets the next sqrt price given an input amount of currency0 or currency1
    /// @dev Throws if price or liquidity are 0, or if the next price is out of bounds
    /// @param sqrtPX96 The starting price, i.e., before accounting for the input amount
    /// @param liquidity The amount of usable liquidity
    /// @param amountIn How much of currency0, or currency1, is being swapped in
    /// @param zeroForOne Whether the amount in is currency0 or currency1
    /// @return uint160 The price after adding the input amount to currency0 or currency1
    function getNextSqrtPriceFromInput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint160) {
        // equivalent: if (sqrtPX96 == 0 || liquidity == 0) revert InvalidPriceOrLiquidity();
        assembly ("memory-safe") {
            if or(
                iszero(and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff)),
                iszero(and(liquidity, 0xffffffffffffffffffffffffffffffff))
            ) {
                mstore(0, 0x4f2461b8) // selector for InvalidPriceOrLiquidity()
                revert(0x1c, 0x04)
            }
        }

        // round to make sure that we don't pass the target price
        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    /// @notice Gets the next sqrt price given an output amount of currency0 or currency1
    /// @dev Throws if price or liquidity are 0 or the next price is out of bounds
    /// @param sqrtPX96 The starting price before accounting for the output amount
    /// @param liquidity The amount of usable liquidity
    /// @param amountOut How much of currency0, or currency1, is being swapped out
    /// @param zeroForOne Whether the amount out is currency1 or currency0
    /// @return uint160 The price after removing the output amount of currency0 or currency1
    function getNextSqrtPriceFromOutput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountOut,
        bool zeroForOne
    ) internal pure returns (uint160) {
        // equivalent: if (sqrtPX96 == 0 || liquidity == 0) revert InvalidPriceOrLiquidity();
        assembly ("memory-safe") {
            if or(
                iszero(and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff)),
                iszero(and(liquidity, 0xffffffffffffffffffffffffffffffff))
            ) {
                mstore(0, 0x4f2461b8) // selector for InvalidPriceOrLiquidity()
                revert(0x1c, 0x04)
            }
        }

        // round to make sure that we pass the target price
        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }

    /// @notice Gets the amount0 delta between two prices
    /// @dev Calculates liquidity / sqrt(lower) - liquidity / sqrt(upper),
    /// i.e. liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
    /// @param sqrtPriceAX96 A sqrt price
    /// @param sqrtPriceBX96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param roundUp Whether to round the amount up or down
    /// @return uint256 Amount of currency0 required to cover a position of size liquidity between the two passed prices
    function getAmount0Delta(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256) {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) {
                (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            }

            // equivalent: if (sqrtPriceAX96 == 0) revert InvalidPrice();
            assembly ("memory-safe") {
                if iszero(and(sqrtPriceAX96, 0xffffffffffffffffffffffffffffffffffffffff)) {
                    mstore(0, 0x00bfc921) // selector for InvalidPrice()
                    revert(0x1c, 0x04)
                }
            }

            uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;
            uint256 numerator2 = sqrtPriceBX96 - sqrtPriceAX96;

            return roundUp
                ? UnsafeMath.divRoundingUp(
                    FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtPriceBX96), sqrtPriceAX96
                )
                : FullMath.mulDiv(numerator1, numerator2, sqrtPriceBX96) / sqrtPriceAX96;
        }
    }

    /// @notice Equivalent to: `a >= b ? a - b : b - a`
    function absDiff(uint160 a, uint160 b) internal pure returns (uint256 res) {
        assembly ("memory-safe") {
            let diff :=
                sub(
                    and(a, 0xffffffffffffffffffffffffffffffffffffffff),
                    and(b, 0xffffffffffffffffffffffffffffffffffffffff)
                )
            // mask = 0 if a >= b else -1 (all 1s)
            let mask := sar(255, diff)
            // if a >= b, res = a - b = 0 ^ (a - b)
            // if a < b, res = b - a = ~~(b - a) = ~(-(b - a) - 1) = ~(a - b - 1) = (-1) ^ (a - b - 1)
            // either way, res = mask ^ (a - b + mask)
            res := xor(mask, add(mask, diff))
        }
    }

    /// @notice Gets the amount1 delta between two prices
    /// @dev Calculates liquidity * (sqrt(upper) - sqrt(lower))
    /// @param sqrtPriceAX96 A sqrt price
    /// @param sqrtPriceBX96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param roundUp Whether to round the amount up, or down
    /// @return amount1 Amount of currency1 required to cover a position of size liquidity between the two passed prices
    function getAmount1Delta(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount1) {
        uint256 numerator = absDiff(sqrtPriceAX96, sqrtPriceBX96);
        uint256 denominator = FixedPoint96.Q96;
        uint256 _liquidity = uint256(liquidity);

        /**
         * Equivalent to:
         *   amount1 = roundUp
         *       ? FullMath.mulDivRoundingUp(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96)
         *       : FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
         * Cannot overflow because `type(uint128).max * type(uint160).max >> 96 < (1 << 192)`.
         */
        amount1 = FullMath.mulDiv(_liquidity, numerator, denominator);
        assembly ("memory-safe") {
            amount1 := add(amount1, and(gt(mulmod(_liquidity, numerator, denominator), 0), roundUp))
        }
    }

    /// @notice Helper that gets signed currency0 delta
    /// @param sqrtPriceAX96 A sqrt price
    /// @param sqrtPriceBX96 Another sqrt price
    /// @param liquidity The change in liquidity for which to compute the amount0 delta
    /// @return int256 Amount of currency0 corresponding to the passed liquidityDelta between the two prices
    function getAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, int128 liquidity)
        internal
        pure
        returns (int256)
    {
        unchecked {
            return liquidity < 0
                ? getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(-liquidity), false).toInt256()
                : -getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(liquidity), true).toInt256();
        }
    }

    /// @notice Helper that gets signed currency1 delta
    /// @param sqrtPriceAX96 A sqrt price
    /// @param sqrtPriceBX96 Another sqrt price
    /// @param liquidity The change in liquidity for which to compute the amount1 delta
    /// @return int256 Amount of currency1 corresponding to the passed liquidityDelta between the two prices
    function getAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, int128 liquidity)
        internal
        pure
        returns (int256)
    {
        unchecked {
            return liquidity < 0
                ? getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(-liquidity), false).toInt256()
                : -getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(liquidity), true).toInt256();
        }
    }
}

/// @title Safe casting methods
/// @notice Contains methods for safely casting between types
library SafeCast {
    using CustomRevert for bytes4;

    error SafeCastOverflow();

    /// @notice Cast a uint256 to a uint160, revert on overflow
    /// @param x The uint256 to be downcasted
    /// @return y The downcasted integer, now type uint160
    function toUint160(uint256 x) internal pure returns (uint160 y) {
        y = uint160(x);
        if (y != x) SafeCastOverflow.selector.revertWith();
    }

    /// @notice Cast a uint256 to a int256, revert on overflow
    /// @param x The uint256 to be casted
    /// @return y The casted integer, now type int256
    function toInt256(uint256 x) internal pure returns (int256 y) {
        y = int256(x);
        if (y < 0) SafeCastOverflow.selector.revertWith();
    }
}

/// @title Math functions that do not check inputs or outputs
/// @notice Contains methods that perform common math functions but do not do any overflow or underflow checks
library UnsafeMath {
    /// @notice Returns ceil(x / y)
    /// @dev division by 0 will return 0, and should be checked externally
    /// @param x The dividend
    /// @param y The divisor
    /// @return z The quotient, ceil(x / y)
    function divRoundingUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            z := add(div(x, y), gt(mod(x, y), 0))
        }
    }
}

/// @title FixedPoint96
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev Used in SqrtPriceMath.sol
library FixedPoint96 {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
}
