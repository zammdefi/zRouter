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
    function buildV2Swap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public pure returns (bytes memory callData) {
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

    function buildSushiSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit
    ) public pure returns (bytes memory callData) {
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
    function buildZAMMSwap(
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
    ) public pure returns (bytes memory callData) {
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

    // With-slippage variants:
    function buildV2SwapWithSlippage(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 quotedInOrOut,
        uint256 slippageBps,
        uint256 deadline
    ) public pure returns (bytes memory callData, uint256 amountLimit) {
        amountLimit = SlippageLib.limit(exactOut, quotedInOrOut, slippageBps);
        callData = buildV2Swap(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline);
    }

    function buildSushiSwapWithSlippage(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 quotedInOrOut,
        uint256 slippageBps
    ) public pure returns (bytes memory callData, uint256 amountLimit) {
        amountLimit = SlippageLib.limit(exactOut, quotedInOrOut, slippageBps);
        callData = buildSushiSwap(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit);
    }

    function buildZAMMSwapWithSlippage(
        address to,
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount,
        uint256 quotedInOrOut,
        uint256 slippageBps,
        uint256 deadline
    ) public pure returns (bytes memory callData, uint256 amountLimit) {
        amountLimit = SlippageLib.limit(exactOut, quotedInOrOut, slippageBps);
        callData = buildZAMMSwap(
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
                buildV2Swap(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline);
        } else if (best.source == AMM.SUSHI) {
            callData = buildSushiSwap(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit);
        } else if (best.source == AMM.ZAMM) {
            // ERC20/ETH case: default ids to 0:
            callData = buildZAMMSwap(
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

        msgValue = requiredMsgValue(exactOut, tokenIn, swapAmount, amountLimit);
    }

    /* msg.value rule (matches zRouter):
       tokenIn==ETH → exactIn: swapAmount, exactOut: amountLimit; else 0. */
    function requiredMsgValue(
        bool exactOut,
        address tokenIn,
        uint256 swapAmount,
        uint256 amountLimit
    ) public pure returns (uint256) {
        return tokenIn == address(0) ? (exactOut ? amountLimit : swapAmount) : 0;
    }

    error ZeroAmount();
    error InvalidToken();

    /*════════ BEST ETH → TOKEN (exact-in) ════════*/
    function bestBuyWithETH(
        address to,
        address tokenOut,
        uint256 amountInETH,
        uint256 slippageBps,
        uint256 deadline
    )
        public
        view
        returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue)
    {
        if (tokenOut == address(0)) revert InvalidToken();
        if (amountInETH == 0) revert ZeroAmount();
        // exactOut = false, tokenIn = ETH
        return buildBestSwap(to, false, address(0), tokenOut, amountInETH, slippageBps, deadline);
    }

    /*════════ BEST TOKEN → ETH (exact-in) ════════*/
    function bestSellForETH(
        address to,
        address tokenIn,
        uint256 amountInToken,
        uint256 slippageBps,
        uint256 deadline
    )
        public
        view
        returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue)
    {
        if (tokenIn == address(0)) revert InvalidToken();
        if (amountInToken == 0) revert ZeroAmount();
        // exactOut = false, tokenOut = ETH
        return buildBestSwap(to, false, tokenIn, address(0), amountInToken, slippageBps, deadline);
    }

    /*════════ BEST ETH → TOKEN (exact-out) ════════*/
    function bestBuyExactTokensWithETH(
        address to,
        address tokenOut,
        uint256 amountOutTokens,
        uint256 slippageBps,
        uint256 deadline
    )
        public
        view
        returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue)
    {
        if (tokenOut == address(0)) revert InvalidToken();
        if (amountOutTokens == 0) revert ZeroAmount();
        // exactOut = true, tokenIn = ETH
        return buildBestSwap(to, true, address(0), tokenOut, amountOutTokens, slippageBps, deadline);
    }

    /*════════ BEST TOKEN → ETH (exact-out) ════════*/
    function bestSellToExactETH(
        address to,
        address tokenIn,
        uint256 amountOutETH,
        uint256 slippageBps,
        uint256 deadline
    )
        public
        view
        returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue)
    {
        if (tokenIn == address(0)) revert InvalidToken();
        if (amountOutETH == 0) revert ZeroAmount();
        // exactOut = true, tokenOut = ETH
        return buildBestSwap(to, true, tokenIn, address(0), amountOutETH, slippageBps, deadline);
    }

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

        // 1) derive tokenTarget (unchanged) ...
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
            leg1 = buildV2Swap(leg1To, true, address(0), token, tokenTarget, maxEthIn, deadline);
        } else if (plan.buy.source == AMM.SUSHI) {
            leg1 = buildSushiSwap(leg1To, true, address(0), token, tokenTarget, maxEthIn);
        } else if (plan.buy.source == AMM.ZAMM) {
            leg1 = buildZAMMSwap(
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

        // 6) build leg 2 (unchanged)
        bytes memory leg2;
        if (plan.sell.source == AMM.UNI_V2) {
            leg2 =
                buildV2Swap(recipient, false, token, address(0), tokenTarget, minEthOut, deadline);
        } else if (plan.sell.source == AMM.SUSHI) {
            leg2 = buildSushiSwap(recipient, false, token, address(0), tokenTarget, minEthOut);
        } else if (plan.sell.source == AMM.ZAMM) {
            leg2 = buildZAMMSwap(
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

        // 7) conditional ETH sweep only if leg 1 used zAMM
        bool needEthSweep = (plan.buy.source == AMM.ZAMM);
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
        msgValue = requiredMsgValue(true, address(0), tokenTarget, maxEthIn);
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
