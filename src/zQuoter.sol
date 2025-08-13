// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract zQuoter {
    enum AMM {
        UNI_V2,
        SUSHI,
        ZAMM,
        UNI_V3, // placeholder
        UNI_V4 // placeholder

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
        quotes = new Quote[](6); // V2 + SUSHI + ZAMM(4 FEE TIERS)

        // Uniswap V2: Using bps for fee:
        (uint256 amountIn, uint256 amountOut) = quoteV2(exactOut, tokenIn, tokenOut, swapAmount);
        quotes[0] = Quote(AMM.UNI_V2, 30, amountIn, amountOut);

        // SushiSwap (Uniswap V2): Using bps for fee:
        (amountIn, amountOut) = quoteSushi(exactOut, tokenIn, tokenOut, swapAmount);
        quotes[1] = Quote(AMM.SUSHI, 30, amountIn, amountOut);

        // ZAMM - standard fee tiers aligned with Uniswap V3: 0.01%, 0.05%, 0.30%, 1%
        (amountIn, amountOut) = quoteZAMM(exactOut, 1, tokenIn, tokenOut, 0, 0, swapAmount);
        quotes[2] = Quote(AMM.ZAMM, 1, amountIn, amountOut);
        (amountIn, amountOut) = quoteZAMM(exactOut, 5, tokenIn, tokenOut, 0, 0, swapAmount);
        quotes[3] = Quote(AMM.ZAMM, 5, amountIn, amountOut);
        (amountIn, amountOut) = quoteZAMM(exactOut, 30, tokenIn, tokenOut, 0, 0, swapAmount);
        quotes[4] = Quote(AMM.ZAMM, 30, amountIn, amountOut);
        (amountIn, amountOut) = quoteZAMM(exactOut, 100, tokenIn, tokenOut, 0, 0, swapAmount);
        quotes[5] = Quote(AMM.ZAMM, 100, amountIn, amountOut);

        best = _pickBest(exactOut, quotes);
    }

    function _pickBest(bool exactOut, Quote[] memory qs)
        internal
        pure
        returns (Quote memory best)
    {
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

    // Single-helper functions for each zRouter AMM:

    function quoteV2(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (swapAmount == 0) return (0, 0);
        // conform to zRouter: treat ETH as WETH for V2-style pools
        if (tokenIn == address(0)) tokenIn = WETH;
        if (tokenOut == address(0)) tokenOut = WETH;

        (address pool, bool zeroForOne) = _v2PoolFor(tokenIn, tokenOut, false);
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

    function quoteSushi(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (swapAmount == 0) return (0, 0);
        // conform to zRouter: treat ETH as WETH for V2-style pools
        if (tokenIn == address(0)) tokenIn = WETH;
        if (tokenOut == address(0)) tokenOut = WETH;

        (address pool, bool zeroForOne) = _v2PoolFor(tokenIn, tokenOut, true);
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

    function quoteZAMM(
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        if (swapAmount == 0) return (0, 0);
        (address token0, address token1, bool zeroForOne) = _sortTokens(tokenIn, tokenOut);
        uint256 id0;
        uint256 id1;
        (id0, id1) = tokenIn == token0 ? (idIn, idOut) : (idOut, idIn);
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

    // ** V2-style calculations

    error InsufficientLiquidity();
    error InsufficientInputAmount();

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, InsufficientInputAmount());
        require(reserveIn > 0 && reserveOut > 0, InsufficientLiquidity());
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    error InsufficientOutputAmount();

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, InsufficientOutputAmount());
        require(reserveIn > 0 && reserveOut > 0, InsufficientLiquidity());
        require(amountOut < reserveOut, InsufficientLiquidity());
        uint256 n = reserveIn * amountOut * 1000;
        uint256 d = (reserveOut - amountOut) * 997;
        amountIn = (n + d - 1) / d; // ceil-div to mirror zRouter
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
        return a.code.length > 0;
    }

    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1, bool zeroForOne)
    {
        (token0, token1) = (zeroForOne = tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // ** ZAMM variants:

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 swapFee)
        internal
        pure
        returns (uint256 amountOut)
    {
        uint256 amountInWithFee = amountIn * (10000 - swapFee);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 10000) + amountInWithFee;
        return numerator / denominator;
    }

    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 swapFee)
        internal
        pure
        returns (uint256 amountIn)
    {
        uint256 numerator = reserveIn * amountOut * 10000;
        uint256 denominator = (reserveOut - amountOut) * (10000 - swapFee);
        return (numerator / denominator) + 1;
    }

    // Slippage helper:

    function limit(bool exactOut, uint256 quoted, uint256 bps) public pure returns (uint256) {
        return SlippageLib.limit(exactOut, quoted, bps);
    }

    // zRouter calldata builders:

    error NoRoute();
    error UnsupportedAMM();

    // Base builders:
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

    function _buildSushiSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapV2.selector,
            to,
            exactOut,
            tokenIn,
            tokenOut,
            swapAmount,
            amountLimit,
            type(uint256).max
        );
    }

    // zAMM builder (explicit ids supported here)
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
        (best,) = getQuotes(exactOut, tokenIn, tokenOut, swapAmount);
        if (best.amountIn == 0 && best.amountOut == 0) revert NoRoute();

        uint256 quoted = exactOut ? best.amountIn : best.amountOut;
        amountLimit = SlippageLib.limit(exactOut, quoted, slippageBps);

        if (best.source == AMM.UNI_V2) {
            callData =
                _buildV2Swap(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline);
        } else if (best.source == AMM.SUSHI) {
            callData = _buildSushiSwap(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit);
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
        } else {
            revert UnsupportedAMM();
        }

        msgValue = _requiredMsgValue(exactOut, tokenIn, swapAmount, amountLimit);
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

    error ZeroAmount();
    error InvalidToken();

    // ** ARB MULTICALL HELPERS

    struct ArbPlan {
        Quote buy; // leg 1 winner (ETH -> token, exact-out)
        Quote sell; // leg 2 winner (token -> ETH, exact-in)
        uint256 tokenTarget; // exact tokens from leg 1 (== leg 2 input)
        uint256 maxEthIn; // leg 1 amountLimit (msg.value), after slippage
        uint256 minEthOut; // leg 2 minOut (ETH), after slippage
        int256 estProfit; // minEthOut - maxEthIn (pre-gas/MEV)
    }

    error NoLeg1Route();
    error NoLeg2Route();
    error NoLeg3Route();
    error BudgetExceeded(uint256 requiredMaxEthIn, uint256 budget);

    function buildEthArbMulticallExactOut(
        address recipient,
        address token, // ERC20
        uint256 budgetEthIn,
        uint256 tokenTargetHint,
        uint256 slippageBps,
        uint256 deadline,
        uint256 minProfit
    ) public view returns (bytes memory multicallData, uint256 msgValue, ArbPlan memory plan) {
        if (token == address(0)) revert InvalidToken();
        if (budgetEthIn == 0) revert ZeroAmount();

        // 1) derive tokenTarget ...
        uint256 tokenTarget = tokenTargetHint;
        if (tokenTarget == 0) {
            (Quote memory buyExactIn,) = getQuotes(false, address(0), token, budgetEthIn);
            if (buyExactIn.amountOut == 0) revert NoLeg1Route();
            tokenTarget = SlippageLib.limit(false, buyExactIn.amountOut, slippageBps);
            if (tokenTarget == 0) revert NoLeg1Route();
        }

        // 2) best leg 1 (exact-out ETH->token)
        (Quote memory buyExactOut,) = getQuotes(true, address(0), token, tokenTarget);
        if (buyExactOut.amountIn == 0) revert NoLeg1Route();
        uint256 maxEthIn = SlippageLib.limit(true, buyExactOut.amountIn, slippageBps);
        if (maxEthIn > budgetEthIn) revert BudgetExceeded(maxEthIn, budgetEthIn);

        // 3) best leg 2 (exact-in token->ETH)
        (Quote memory sellExactIn,) = getQuotes(false, token, address(0), tokenTarget);
        if (sellExactIn.amountOut == 0) revert NoLeg2Route();
        uint256 minEthOut = SlippageLib.limit(false, sellExactIn.amountOut, slippageBps);

        plan = ArbPlan({
            buy: buyExactOut,
            sell: sellExactIn,
            tokenTarget: tokenTarget,
            maxEthIn: maxEthIn,
            minEthOut: minEthOut,
            estProfit: int256(minEthOut) - int256(maxEthIn)
        });

        if (minProfit != 0 && plan.estProfit < int256(minProfit)) {
            return ("", 0, plan);
        }

        // ── choose leg1To: push directly into next V2-style pool when possible ──
        address leg1To = ZROUTER;
        bool nextIsV2Style = (plan.sell.source == AMM.UNI_V2 || plan.sell.source == AMM.SUSHI);
        bool leg1IsV2Style = (plan.buy.source == AMM.UNI_V2 || plan.buy.source == AMM.SUSHI);
        if (leg1IsV2Style && nextIsV2Style) {
            // compute the leg-2 pool (token <-> WETH) using the correct factory
            bool sushiNext = (plan.sell.source == AMM.SUSHI);
            (address nextPool,) = _v2PoolFor(token, WETH, sushiNext);
            // only push if the pool actually exists
            if (_isContract(nextPool)) {
                leg1To = nextPool;
            }
        }
        // NOTE: if leg1 is zAMM, keep leg1To = ZROUTER (see refund/accounting semantics)

        // 5) build leg 1
        bytes memory leg1;
        if (plan.buy.source == AMM.UNI_V2) {
            leg1 = _buildV2Swap(leg1To, true, address(0), token, tokenTarget, maxEthIn, deadline);
        } else if (plan.buy.source == AMM.SUSHI) {
            leg1 = _buildSushiSwap(leg1To, true, address(0), token, tokenTarget, maxEthIn);
        } else if (plan.buy.source == AMM.ZAMM) {
            leg1 = _buildZAMMSwap(
                ZROUTER,
                true,
                plan.buy.feeBps,
                address(0),
                token,
                0,
                0,
                tokenTarget,
                maxEthIn,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // 6) build leg 2
        bytes memory leg2;
        if (plan.sell.source == AMM.UNI_V2) {
            leg2 =
                _buildV2Swap(recipient, false, token, address(0), tokenTarget, minEthOut, deadline);
        } else if (plan.sell.source == AMM.SUSHI) {
            leg2 = _buildSushiSwap(recipient, false, token, address(0), tokenTarget, minEthOut);
        } else if (plan.sell.source == AMM.ZAMM) {
            leg2 = _buildZAMMSwap(
                recipient,
                false,
                plan.sell.feeBps,
                token,
                address(0),
                0,
                0,
                tokenTarget,
                minEthOut,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // 7) Check sweep conditions and build calls
        bool pushed = (leg1To != ZROUTER);
        bool needEthSweep = (plan.buy.source == AMM.ZAMM)
            || (!pushed && (plan.buy.source == AMM.UNI_V2 || plan.buy.source == AMM.SUSHI))
            || (plan.sell.source == AMM.ZAMM);

        bytes[] memory calls = new bytes[](needEthSweep ? 3 : 2);
        calls[0] = leg1;
        calls[1] = leg2;
        if (needEthSweep) {
            calls[2] = abi.encodeWithSelector(
                IZRouterMulticall.sweep.selector,
                address(0),
                0,
                0, // sweep all ETH
                recipient
            );
        }
        multicallData = abi.encodeWithSelector(IZRouterMulticall.multicall.selector, calls);

        // msg.value funds leg 1 exact-out
        msgValue = _requiredMsgValue(true, address(0), tokenTarget, maxEthIn);
    }

    /* ETH-budget arb (exact-in on leg 1), safe & conservative:
    - Leg 1: ETH -> token (exact-in = budgetEthIn), 'to' = ZROUTER (no direct pool push)
    - Leg 2: token -> ETH (exact-in = minTokensFromLeg1), deliver ETH to recipient
    - Always sweep leftover tokens (if any) to recipient.
    */
    function buildEthArbMulticallExactIn(
        address recipient,
        address token, // ERC20
        uint256 budgetEthIn, // exact-in amount for leg 1
        uint256 slippageBps,
        uint256 deadline,
        uint256 minProfit // in wei; 0 to skip check
    ) public view returns (bytes memory multicallData, uint256 msgValue, ArbPlan memory plan) {
        if (token == address(0)) revert InvalidToken();
        if (budgetEthIn == 0) revert ZeroAmount();

        // 1) best leg 1 (exact-in ETH->token)
        (Quote memory buyExactIn,) = getQuotes(false, address(0), token, budgetEthIn);
        if (buyExactIn.amountOut == 0) revert NoLeg1Route();

        // tokens we can *safely* count on from leg 1
        uint256 minTokensOut = SlippageLib.limit(false, buyExactIn.amountOut, slippageBps);
        if (minTokensOut == 0) revert NoLeg1Route();

        // 2) best leg 2 (exact-in token->ETH, using minTokensOut)
        (Quote memory sellExactIn,) = getQuotes(false, token, address(0), minTokensOut);
        if (sellExactIn.amountOut == 0) revert NoLeg2Route();

        // ETH we can *safely* count on from leg 2
        uint256 minEthOut = SlippageLib.limit(false, sellExactIn.amountOut, slippageBps);

        plan = ArbPlan({
            buy: buyExactIn, // note: this leg is exact-in (not exact-out like the other variant)
            sell: sellExactIn, // exact-in
            tokenTarget: minTokensOut,
            maxEthIn: budgetEthIn,
            minEthOut: minEthOut,
            estProfit: int256(minEthOut) - int256(budgetEthIn)
        });

        if (minProfit != 0 && plan.estProfit < int256(minProfit)) {
            return ("", 0, plan);
        }

        // 3) build leg 1 (ETH->token exact-in); to = ZROUTER (avoid pool push since output is unknown ex-ante)
        bytes memory leg1;
        if (plan.buy.source == AMM.UNI_V2) {
            leg1 =
                _buildV2Swap(ZROUTER, false, address(0), token, budgetEthIn, minTokensOut, deadline);
        } else if (plan.buy.source == AMM.SUSHI) {
            leg1 = _buildSushiSwap(ZROUTER, false, address(0), token, budgetEthIn, minTokensOut);
        } else if (plan.buy.source == AMM.ZAMM) {
            leg1 = _buildZAMMSwap(
                ZROUTER,
                false,
                plan.buy.feeBps,
                address(0),
                token,
                0,
                0,
                budgetEthIn,
                minTokensOut,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // 4) build leg 2 (token->ETH exact-in), consume exactly minTokensOut, enforce minEthOut to recipient
        bytes memory leg2;
        if (plan.sell.source == AMM.UNI_V2) {
            leg2 =
                _buildV2Swap(recipient, false, token, address(0), minTokensOut, minEthOut, deadline);
        } else if (plan.sell.source == AMM.SUSHI) {
            leg2 = _buildSushiSwap(recipient, false, token, address(0), minTokensOut, minEthOut);
        } else if (plan.sell.source == AMM.ZAMM) {
            leg2 = _buildZAMMSwap(
                recipient,
                false,
                plan.sell.feeBps,
                token,
                address(0),
                0,
                0,
                minTokensOut,
                minEthOut,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // 5) always sweep leftover tokens from router → recipient (in case leg 1 executes better than min)
        bool needEthSweep = (plan.sell.source == AMM.ZAMM);
        bytes[] memory calls = new bytes[](needEthSweep ? 4 : 3);
        calls[0] = leg1;
        calls[1] = leg2;
        calls[2] = abi.encodeWithSelector(IZRouterMulticall.sweep.selector, token, 0, 0, recipient);
        if (needEthSweep) {
            calls[3] = abi.encodeWithSelector(
                IZRouterMulticall.sweep.selector, address(0), 0, 0, recipient
            );
        }
        multicallData = abi.encodeWithSelector(IZRouterMulticall.multicall.selector, calls);

        // fund leg 1 exact-in with ETH (no other leg needs msg.value)
        msgValue = _requiredMsgValue(false, address(0), budgetEthIn, minTokensOut); // == budgetEthIn
    }

    struct TokenArbPlan {
        Quote sell; // leg 1 winner (token -> ETH, exact-in)
        Quote buy; // leg 2 winner (ETH -> token, exact-in)
        uint256 tokenBudget; // leg 1 input
        uint256 minEthOut; // leg 1 min ETH out (after slippage)
        uint256 minTokensOut; // leg 2 min token out (after slippage)
        int256 estProfit; // minTokensOut - tokenBudget (pre-gas/MEV)
    }

    function buildTokenArbMulticallExactIn(
        address recipient,
        address token, // ERC20
        uint256 tokenBudget, // exact-in tokens for leg 1
        uint256 slippageBps,
        uint256 deadline,
        uint256 minProfitTokens
    )
        public
        view
        returns (bytes memory multicallData, uint256 msgValue, TokenArbPlan memory plan)
    {
        if (token == address(0)) revert InvalidToken();
        if (tokenBudget == 0) revert ZeroAmount();

        // 1) leg 1 (token -> ETH, exact-in)
        (Quote memory sellExactIn,) = getQuotes(false, token, address(0), tokenBudget);
        if (sellExactIn.amountOut == 0) revert NoLeg1Route();
        uint256 minEthOut = SlippageLib.limit(false, sellExactIn.amountOut, slippageBps);
        if (minEthOut == 0) revert NoLeg1Route();

        // 2) leg 2 (ETH -> token, exact-in with minEthOut)
        (Quote memory buyExactIn,) = getQuotes(false, address(0), token, minEthOut);
        if (buyExactIn.amountOut == 0) revert NoLeg2Route();
        uint256 minTokensOut = SlippageLib.limit(false, buyExactIn.amountOut, slippageBps);

        plan = TokenArbPlan({
            sell: sellExactIn,
            buy: buyExactIn,
            tokenBudget: tokenBudget,
            minEthOut: minEthOut,
            minTokensOut: minTokensOut,
            estProfit: int256(minTokensOut) - int256(tokenBudget)
        });

        if (minProfitTokens != 0 && plan.estProfit < int256(minProfitTokens)) {
            return ("", 0, plan);
        }

        // ── build leg 1: send ETH to router (ZROUTER) ──
        bytes memory leg1;
        if (plan.sell.source == AMM.UNI_V2) {
            leg1 = _buildV2Swap(ZROUTER, false, token, address(0), tokenBudget, minEthOut, deadline);
        } else if (plan.sell.source == AMM.SUSHI) {
            leg1 = _buildSushiSwap(ZROUTER, false, token, address(0), tokenBudget, minEthOut);
        } else if (plan.sell.source == AMM.ZAMM) {
            leg1 = _buildZAMMSwap(
                ZROUTER,
                false,
                plan.sell.feeBps,
                token,
                address(0),
                0,
                0,
                tokenBudget,
                minEthOut,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // ── build leg 2: spend router-held ETH (wrap internally), deliver tokens ──
        bytes memory leg2;
        if (plan.buy.source == AMM.UNI_V2) {
            leg2 =
                _buildV2Swap(recipient, false, address(0), token, minEthOut, minTokensOut, deadline);
        } else if (plan.buy.source == AMM.SUSHI) {
            leg2 = _buildSushiSwap(recipient, false, address(0), token, minEthOut, minTokensOut);
        } else if (plan.buy.source == AMM.ZAMM) {
            leg2 = _buildZAMMSwap(
                recipient,
                false,
                plan.buy.feeBps,
                address(0),
                token,
                0,
                0,
                minEthOut,
                minTokensOut,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // Sweep any leftover ETH (from conservative minEthOut) and token dust to recipient.
        bytes[] memory calls = new bytes[](4);
        calls[0] = leg1;
        calls[1] = leg2;
        calls[2] = abi.encodeWithSelector(
            IZRouterMulticall.sweep.selector,
            address(0),
            0,
            0, // all ETH
            recipient
        );
        calls[3] = abi.encodeWithSelector(
            IZRouterMulticall.sweep.selector,
            token,
            0,
            0, // all token dust (should be 0, but safe)
            recipient
        );
        multicallData = abi.encodeWithSelector(IZRouterMulticall.multicall.selector, calls);

        // No external ETH needed; leg 2 spends router-held ETH from leg 1.
        msgValue = 0;
    }

    struct TriPlan {
        Quote leg1; // ETH -> A (exact-in)
        Quote leg2; // A -> B  (exact-in)
        Quote leg3; // B -> ETH (exact-in)
        uint256 minAOut;
        uint256 minBOut;
        uint256 minEthOut;
        int256 estProfit; // minEthOut - budgetEthIn (pre-gas/MEV)
    }

    // Builds ETH -> A (exact-in), A -> B (exact-out), B -> ETH (exact-in).
    // Safe pool-push from leg2 -> leg3 when both are V2-style and the B/WETH pool exists.
    // ETH budget is capped by `budgetEthIn`. Profit is in wei: minEthOut - budgetEthIn.
    function buildEthTriArbExactIn(
        address recipient,
        address tokenA, // ERC20
        address tokenB, // ERC20
        uint256 budgetEthIn,
        uint256 slippageBps,
        uint256 deadline,
        uint256 minProfitWei
    ) public view returns (bytes memory multicallData, uint256 msgValue, TriPlan memory plan) {
        if (tokenA == address(0) || tokenB == address(0)) revert InvalidToken();
        if (budgetEthIn == 0) revert ZeroAmount();

        // ── Leg 1: ETH -> A (exact-in) ─────────────────────────────────────────────
        (Quote memory q1In,) = getQuotes(false, address(0), tokenA, budgetEthIn);
        if (q1In.amountOut == 0) revert NoLeg1Route();
        uint256 minAOut = SlippageLib.limit(false, q1In.amountOut, slippageBps);
        if (minAOut == 0) revert NoLeg1Route();

        // ── Choose a conservative B target from A->B exact-in, then flip to exact-out ─
        // First, how much B could we expect if we spent all minAOut?
        (Quote memory q2ProbeIn,) = getQuotes(false, tokenA, tokenB, minAOut);
        if (q2ProbeIn.amountOut == 0) revert NoLeg2Route();
        uint256 bTarget = SlippageLib.limit(false, q2ProbeIn.amountOut, slippageBps);
        if (bTarget == 0) revert NoLeg2Route();

        // Now quote A->B exact-out for that B target, to get required A (will be <= minAOut if feasible).
        (Quote memory q2Out,) = getQuotes(true, tokenA, tokenB, bTarget);
        if (q2Out.amountIn == 0) revert NoLeg2Route();
        uint256 maxAIn = SlippageLib.limit(true, q2Out.amountIn, slippageBps);
        if (maxAIn > minAOut) revert NoLeg2Route(); // not enough A from leg 1 at conservative bounds

        // ── Leg 3: B -> ETH (exact-in) on B target ─────────────────────────────────
        (Quote memory q3In,) = getQuotes(false, tokenB, address(0), bTarget);
        if (q3In.amountOut == 0) revert NoLeg3Route();
        uint256 minEthOut = SlippageLib.limit(false, q3In.amountOut, slippageBps);

        plan = TriPlan({
            leg1: q1In, // ETH->A exact-in (uses q1In)
            leg2: q2Out, // A->B exact-out (uses q2Out)
            leg3: q3In, // B->ETH exact-in (uses q3In)
            minAOut: minAOut,
            minBOut: bTarget, // here minBOut is our exact-out target
            minEthOut: minEthOut,
            estProfit: int256(minEthOut) - int256(budgetEthIn)
        });

        if (minProfitWei != 0 && plan.estProfit < int256(minProfitWei)) {
            return ("", 0, plan);
        }

        // ── Build leg 1: ETH->A exact-in, buffered at router (cannot safely push ETH) ─
        bytes memory leg1;
        if (q1In.source == AMM.UNI_V2) {
            leg1 = _buildV2Swap(ZROUTER, false, address(0), tokenA, budgetEthIn, minAOut, deadline);
        } else if (q1In.source == AMM.SUSHI) {
            leg1 = _buildSushiSwap(ZROUTER, false, address(0), tokenA, budgetEthIn, minAOut);
        } else if (q1In.source == AMM.ZAMM) {
            leg1 = _buildZAMMSwap(
                ZROUTER,
                false,
                q1In.feeBps,
                address(0),
                tokenA,
                0,
                0,
                budgetEthIn,
                minAOut,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // ── Pick leg2 "to": push to next V2-style pool when safe ───────────────────
        address leg2To = ZROUTER;
        bool leg2IsV2 = (q2Out.source == AMM.UNI_V2 || q2Out.source == AMM.SUSHI);
        bool leg3IsV2 = (q3In.source == AMM.UNI_V2 || q3In.source == AMM.SUSHI);
        if (leg2IsV2 && leg3IsV2) {
            bool sushiNext = (q3In.source == AMM.SUSHI);
            (address nextPool,) = _v2PoolFor(tokenB, WETH, sushiNext);
            if (_isContract(nextPool)) {
                leg2To = nextPool; // safe push: exact-out B == exact-in B
            }
        }
        // NOTE: if q2Out.source == AMM.ZAMM, keep leg2To = ZROUTER (refund/accounting semantics).

        // ── Build leg 2: A->B exact-out (uses at most maxAIn), optionally pushed ───
        bytes memory leg2;
        if (q2Out.source == AMM.UNI_V2) {
            leg2 = _buildV2Swap(leg2To, true, tokenA, tokenB, bTarget, maxAIn, deadline);
        } else if (q2Out.source == AMM.SUSHI) {
            leg2 = _buildSushiSwap(leg2To, true, tokenA, tokenB, bTarget, maxAIn);
        } else if (q2Out.source == AMM.ZAMM) {
            leg2 = _buildZAMMSwap(
                ZROUTER, true, q2Out.feeBps, tokenA, tokenB, 0, 0, bTarget, maxAIn, deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // ── Build leg 3: B->ETH exact-in to recipient ──────────────────────────────
        bytes memory leg3;
        if (q3In.source == AMM.UNI_V2) {
            leg3 = _buildV2Swap(recipient, false, tokenB, address(0), bTarget, minEthOut, deadline);
        } else if (q3In.source == AMM.SUSHI) {
            leg3 = _buildSushiSwap(recipient, false, tokenB, address(0), bTarget, minEthOut);
        } else if (q3In.source == AMM.ZAMM) {
            leg3 = _buildZAMMSwap(
                recipient,
                false,
                q3In.feeBps,
                tokenB,
                address(0),
                0,
                0,
                bTarget,
                minEthOut,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // Sweeps: leftover A (from leg1 if maxAIn < minAOut), leftover B (if no push), and any ETH dust.
        // (Sweeping B is harmless even if we pushed.)
        bytes[] memory calls = new bytes[](6);
        calls[0] = leg1;
        calls[1] = leg2;
        calls[2] = leg3;
        calls[3] = abi.encodeWithSelector(IZRouterMulticall.sweep.selector, tokenA, 0, 0, recipient);
        calls[4] = abi.encodeWithSelector(IZRouterMulticall.sweep.selector, tokenB, 0, 0, recipient);
        calls[5] =
            abi.encodeWithSelector(IZRouterMulticall.sweep.selector, address(0), 0, 0, recipient);
        multicallData = abi.encodeWithSelector(IZRouterMulticall.multicall.selector, calls);

        // Fund leg 1 exact-in with ETH.
        msgValue = _requiredMsgValue(false, address(0), budgetEthIn, minAOut); // == budgetEthIn
    }

    struct TokenTriPlan {
        Quote leg1; // token0 -> token1 (exact-in)
        Quote leg2; // token1 -> token2 (exact-out)
        Quote leg3; // token2 -> ETH    (exact-in)
        uint256 minToken1Out; // conservative token1 from leg 1
        uint256 token2Target; // exact-out target for leg 2 (and exact-in size for leg 3)
        uint256 minEthOut; // conservative ETH from leg 3
        int256 estProfit; // in wei; since ETH-in = 0, this is simply minEthOut
    }

    /* TOKEN0 -> TOKEN1 (exact-in) -> TOKEN2 (exact-out, push when V2/Sushi) -> ETH (exact-in)
    Ends in ETH. Starts from a token inventory (token0Budget).
    Safe push only from leg 2 -> leg 3 (exact-out -> exact-in handoff), and only for V2/Sushi.
    */
    function buildTokenTriArbToEthExactIn(
        address recipient,
        address token0, // start token (ERC20 you hold)
        address token1, // mid token A
        address token2, // mid token B (pairs with WETH for leg 3)
        uint256 token0Budget, // exact-in amount for leg 1
        uint256 slippageBps,
        uint256 deadline,
        uint256 minProfitWei // require at least this much ETH out; 0 to skip
    )
        public
        view
        returns (bytes memory multicallData, uint256 msgValue, TokenTriPlan memory plan)
    {
        if (recipient == address(0)) revert InvalidToken();
        if (token0 == address(0) || token1 == address(0) || token2 == address(0)) {
            revert InvalidToken();
        }
        if (token0Budget == 0) revert ZeroAmount();

        // ── Leg 1: token0 -> token1 (exact-in = token0Budget) ─────────────────────
        (Quote memory q1In,) = getQuotes(false, token0, token1, token0Budget);
        if (q1In.amountOut == 0) revert NoLeg1Route();
        uint256 minToken1Out = SlippageLib.limit(false, q1In.amountOut, slippageBps);
        if (minToken1Out == 0) revert NoLeg1Route();

        // ── Probe leg 2 as exact-in to derive a conservative token2 target ────────
        (Quote memory q2ProbeIn,) = getQuotes(false, token1, token2, minToken1Out);
        if (q2ProbeIn.amountOut == 0) revert NoLeg2Route();
        uint256 token2Target = SlippageLib.limit(false, q2ProbeIn.amountOut, slippageBps);
        if (token2Target == 0) revert NoLeg2Route();

        // ── Leg 2 as exact-out for push: token1 -> token2 (exact-out token2Target) ─
        (Quote memory q2Out,) = getQuotes(true, token1, token2, token2Target);
        if (q2Out.amountIn == 0) revert NoLeg2Route();
        uint256 maxToken1In = SlippageLib.limit(true, q2Out.amountIn, slippageBps);
        if (maxToken1In > minToken1Out) revert NoLeg2Route(); // not feasible at conservative bounds

        // ── Leg 3: token2 -> ETH (exact-in = token2Target) ────────────────────────
        (Quote memory q3In,) = getQuotes(false, token2, address(0), token2Target);
        if (q3In.amountOut == 0) revert NoLeg3Route();
        uint256 minEthOut = SlippageLib.limit(false, q3In.amountOut, slippageBps);

        plan = TokenTriPlan({
            leg1: q1In,
            leg2: q2Out,
            leg3: q3In,
            minToken1Out: minToken1Out,
            token2Target: token2Target,
            minEthOut: minEthOut,
            estProfit: int256(minEthOut) // ETH-in is 0; profit is simply ETH out (pre-gas)
        });

        if (minProfitWei != 0 && plan.estProfit < int256(minProfitWei)) {
            return ("", 0, plan);
        }

        // ── Build leg 1: token0 -> token1 (exact-in), to router (cannot safely push) ─
        bytes memory leg1;
        if (q1In.source == AMM.UNI_V2) {
            leg1 =
                _buildV2Swap(ZROUTER, false, token0, token1, token0Budget, minToken1Out, deadline);
        } else if (q1In.source == AMM.SUSHI) {
            leg1 = _buildSushiSwap(ZROUTER, false, token0, token1, token0Budget, minToken1Out);
        } else if (q1In.source == AMM.ZAMM) {
            leg1 = _buildZAMMSwap(
                ZROUTER,
                false,
                q1In.feeBps,
                token0,
                token1,
                0,
                0,
                token0Budget,
                minToken1Out,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // ── Decide leg 2 'to': push to token2/WETH pool when both legs are V2-style ─
        address leg2To = ZROUTER;
        bool leg2IsV2 = (q2Out.source == AMM.UNI_V2 || q2Out.source == AMM.SUSHI);
        bool leg3IsV2 = (q3In.source == AMM.UNI_V2 || q3In.source == AMM.SUSHI);
        if (leg2IsV2 && leg3IsV2) {
            bool sushiNext = (q3In.source == AMM.SUSHI);
            (address nextPool,) = _v2PoolFor(token2, WETH, sushiNext);
            if (_isContract(nextPool)) {
                leg2To = nextPool; // safe: exact-out token2Target == exact-in for leg 3
            }
        }
        // NOTE: if q2Out is zAMM, keep leg2To = ZROUTER (refund/accounting semantics).

        // ── Build leg 2: token1 -> token2 (exact-out), possibly pushed ────────────
        bytes memory leg2;
        if (q2Out.source == AMM.UNI_V2) {
            leg2 = _buildV2Swap(leg2To, true, token1, token2, token2Target, maxToken1In, deadline);
        } else if (q2Out.source == AMM.SUSHI) {
            leg2 = _buildSushiSwap(leg2To, true, token1, token2, token2Target, maxToken1In);
        } else if (q2Out.source == AMM.ZAMM) {
            leg2 = _buildZAMMSwap(
                ZROUTER,
                true,
                q2Out.feeBps,
                token1,
                token2,
                0,
                0,
                token2Target,
                maxToken1In,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // ── Build leg 3: token2 -> ETH (exact-in), to recipient ───────────────────
        bytes memory leg3;
        if (q3In.source == AMM.UNI_V2) {
            leg3 = _buildV2Swap(
                recipient, false, token2, address(0), token2Target, minEthOut, deadline
            );
        } else if (q3In.source == AMM.SUSHI) {
            leg3 = _buildSushiSwap(recipient, false, token2, address(0), token2Target, minEthOut);
        } else if (q3In.source == AMM.ZAMM) {
            leg3 = _buildZAMMSwap(
                recipient,
                false,
                q3In.feeBps,
                token2,
                address(0),
                0,
                0,
                token2Target,
                minEthOut,
                deadline
            );
        } else {
            revert UnsupportedAMM();
        }

        // ── Multicall assembly with conservative sweeps ───────────────────────────
        bytes[] memory calls = new bytes[](6);
        calls[0] = leg1;
        calls[1] = leg2;
        calls[2] = leg3;
        calls[3] = abi.encodeWithSelector(IZRouterMulticall.sweep.selector, token1, 0, 0, recipient);
        calls[4] = abi.encodeWithSelector(IZRouterMulticall.sweep.selector, token2, 0, 0, recipient);
        calls[5] =
            abi.encodeWithSelector(IZRouterMulticall.sweep.selector, address(0), 0, 0, recipient);
        multicallData = abi.encodeWithSelector(IZRouterMulticall.multicall.selector, calls);

        // No ETH funding needed for any leg here.
        msgValue = 0;
    }
}

address constant ZROUTER = 0x0000000000404FECAf36E6184245475eE1254835;

// Uniswap helpers:

address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
bytes32 constant V2_POOL_INIT_CODE_HASH =
    0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

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
}

interface IZRouterMulticall {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
    function sweep(address token, uint256 id, uint256 amount, address to) external payable;
}
