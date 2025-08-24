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
            (uint256 amountIn, uint256 amountOut) = quoteV2(exactOut, tokenIn, tokenOut, swapAmount);
            quotes[0] = Quote(AMM.UNI_V2, 30, amountIn, amountOut);

            (amountIn, amountOut) = quoteSushi(exactOut, tokenIn, tokenOut, swapAmount);
            quotes[1] = Quote(AMM.SUSHI, 30, amountIn, amountOut);

            (amountIn, amountOut) = quoteZAMM(exactOut, 1, tokenIn, tokenOut, 0, 0, swapAmount);
            quotes[2] = Quote(AMM.ZAMM, 1, amountIn, amountOut);
            (amountIn, amountOut) = quoteZAMM(exactOut, 5, tokenIn, tokenOut, 0, 0, swapAmount);
            quotes[3] = Quote(AMM.ZAMM, 5, amountIn, amountOut);
            (amountIn, amountOut) = quoteZAMM(exactOut, 30, tokenIn, tokenOut, 0, 0, swapAmount);
            quotes[4] = Quote(AMM.ZAMM, 30, amountIn, amountOut);
            (amountIn, amountOut) = quoteZAMM(exactOut, 100, tokenIn, tokenOut, 0, 0, swapAmount);
            quotes[5] = Quote(AMM.ZAMM, 100, amountIn, amountOut);

            // --- Uniswap v3 single-tick (fees in v3 units; store bps in Quote) ---

            uint24[4] memory fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
            uint256 j = 6;
            for (uint256 i; i != fees.length; ++i) {
                (amountIn, amountOut, /*singleTick*/ ) =
                    quoteV3(exactOut, tokenIn, tokenOut, fees[i], swapAmount);
                // if singleTick=false, amounts are zero and get skipped by _pickBest
                quotes[j++] = Quote(AMM.UNI_V3, fees[i] / 100, amountIn, amountOut); // store as bps (1/5/30/100)
            }

            // --- Uni v4 single-tick (no-hook) ---
            // Keep fee↔spacing paired so the builder can reconstruct spacing from feeBps.
            {
                uint24[4] memory v4Fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
                int24[4] memory v4Spaces = [int24(1), int24(10), int24(60), int24(200)];
                for (uint256 i; i != v4Fees.length; ++i) {
                    (amountIn, amountOut, /*singleTick*/ ) = quoteV4(
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

    function quoteV3(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut, bool singleTick) {
        if (swapAmount == 0) return (0, 0, false);
        // treat ETH as WETH (matches V2 behavior)
        if (tokenIn == address(0)) tokenIn = WETH;
        if (tokenOut == address(0)) tokenOut = WETH;

        V3QuoterSingleTick.Quote memory q =
            V3QuoterSingleTick.quoteV3SingleTick(exactOut, tokenIn, tokenOut, fee, swapAmount);

        if (q.singleTick) {
            return (q.amountIn, q.amountOut, true);
        } else {
            return (0, 0, false); // single-tick didn't fit; skip for now
        }
    }

    function quoteV4(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 feePips,
        int24 tickSpacing,
        address hooks,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut, bool singleTick) {
        if (swapAmount == 0) return (0, 0, false);

        (bytes32 poolId, bool zeroForOne) =
            _v4PoolId(tokenIn, tokenOut, feePips, tickSpacing, hooks);
        IStateViewV4 sv = IStateViewV4(V4_STATE_VIEW);

        uint160 sqrtP;
        int24 tick;
        uint24 lpFee;
        uint128 L;

        // Gracefully bail if the pool is missing/uninitialized
        try sv.getSlot0(poolId) returns (
            uint160 _sqrtP, int24 _tick, uint24, /*protocolFee*/ uint24 _lpFee
        ) {
            sqrtP = _sqrtP;
            tick = _tick;
            lpFee = _lpFee;
        } catch {
            return (0, 0, false);
        }

        try sv.getLiquidity(poolId) returns (uint128 _L) {
            L = _L;
        } catch {
            return (0, 0, false);
        }

        if (L == 0 || lpFee >= 1_000_000) return (0, 0, false);

        (, uint160 sqrtBoundary) =
            V3TickBitmap._v4NextInitializedTick(sv, poolId, tick, tickSpacing, zeroForOne);

        uint256 feeDenom = 1_000_000;
        uint256 feeMul = feeDenom - lpFee;

        if (!exactOut) {
            uint256 inLessFee = FullMath.mulDiv(swapAmount, feeMul, feeDenom);
            uint256 capIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtBoundary, sqrtP, L, false)
                : SqrtPriceMath.getAmount1Delta(sqrtP, sqrtBoundary, L, false);

            if (inLessFee <= capIn) {
                uint160 sqrtAfter =
                    SqrtPriceMath.getNextSqrtPriceFromInput(sqrtP, L, inLessFee, zeroForOne);
                uint256 outAmt = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(sqrtAfter, sqrtP, L, false)
                    : SqrtPriceMath.getAmount0Delta(sqrtP, sqrtAfter, L, false);
                return (swapAmount, outAmt, true);
            }
        } else {
            uint256 capOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtBoundary, sqrtP, L, false)
                : SqrtPriceMath.getAmount0Delta(sqrtP, sqrtBoundary, L, false);

            if (swapAmount <= capOut) {
                uint160 sqrtAfter =
                    SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtP, L, swapAmount, zeroForOne);
                uint256 inLessFee = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(sqrtAfter, sqrtP, L, true)
                    : SqrtPriceMath.getAmount1Delta(sqrtAfter, sqrtP, L, true);
                uint256 inGross = FullMath.mulDivRoundingUp(inLessFee, feeDenom, feeMul);
                return (inGross, swapAmount, true);
            }
        }
        return (0, 0, false);
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
        return a.code.length != 0;
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
        } else if (best.source == AMM.UNI_V3) {
            unchecked {
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
            }
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

    function _spacingFromBps(uint16 bps) internal pure returns (int24) {
        if (bps == 1) return 1;
        if (bps == 5) return 10;
        if (bps == 30) return 60;
        if (bps == 100) return 200;
        return int24(uint24(bps));
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
}

address constant ZROUTER = 0x0000000000404FECAf36E6184245475eE1254835;

// Uniswap helpers:

address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
bytes32 constant V2_POOL_INIT_CODE_HASH =
    0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

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

interface IUniswapV3Factory {
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickBitmap(int16 wordPos) external view returns (uint256);
}

/// @title Math library for computing sqrt prices from ticks and vice versa
/// @notice Computes sqrt price for ticks of size 1.0001, i.e. sqrt(1.0001^tick) as fixed point Q64.96 numbers. Supports
/// prices between 2**-128 and 2**128
library TickMath {
    /// @dev The minimum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**-128
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**128
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @notice Calculates sqrt(1.0001^tick) * 2^96
    /// @dev Throws if |tick| > max tick
    /// @param tick The input tick for the above formula
    /// @return sqrtPriceX96 A Fixed point Q64.96 number representing the sqrt of the ratio of the two assets (token1/token0)
    /// at the given tick
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(uint24(MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
        // we then downcast because we know the result always fits within 160 bits due to our tick input constraint
        // we round up in the division so getTickAtSqrtRatio of the output price is always consistent
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /// @notice Calculates the greatest tick value such that getRatioAtTick(tick) <= ratio
    /// @dev Throws in case sqrtPriceX96 < MIN_SQRT_RATIO, as MIN_SQRT_RATIO is the lowest value getRatioAtTick may
    /// ever return.
    /// @param sqrtPriceX96 The sqrt ratio for which to compute the tick as a Q64.96
    /// @return tick The greatest tick for which the ratio is less than or equal to the input ratio
    function getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        // second inequality must be < because the price can never reach the price at the max tick
        require(sqrtPriceX96 >= MIN_SQRT_RATIO && sqrtPriceX96 < MAX_SQRT_RATIO, "R");
        uint256 ratio = uint256(sqrtPriceX96) << 32;

        uint256 r = ratio;
        uint256 msb = 0;

        assembly {
            let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(6, gt(r, 0xFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(5, gt(r, 0xFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(4, gt(r, 0xFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(3, gt(r, 0xFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(2, gt(r, 0xF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(1, gt(r, 0x3))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := gt(r, 0x1)
            msb := or(msb, f)
        }

        if (msb >= 128) r = ratio >> (msb - 127);
        else r = ratio << (127 - msb);

        int256 log_2 = (int256(msb) - 128) << 64;

        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(63, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(62, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(61, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(60, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(59, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(58, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(57, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(56, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(55, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(54, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(53, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(52, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(51, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(50, f))
        }

        int256 log_sqrt10001 = log_2 * 255738958999603826347141; // 128.128 number

        int24 tickLow = int24((log_sqrt10001 - 3402992956809132418596140100660247210) >> 128);
        int24 tickHi = int24((log_sqrt10001 + 291339464771989622907027621153398088495) >> 128);

        tick = tickLow == tickHi
            ? tickLow
            : getSqrtRatioAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow;
    }
}

/// @title Functions based on Q64.96 sqrt price and liquidity
/// @notice Contains the math that uses square root of price as a Q64.96 and liquidity to compute deltas
library SqrtPriceMath {
    using LowGasSafeMath for uint256;
    using SafeCast for uint256;

    /// @notice Gets the next sqrt price given a delta of token0
    /// @dev Always rounds up, because in the exact output case (increasing price) we need to move the price at least
    /// far enough to get the desired output amount, and in the exact input case (decreasing price) we need to move the
    /// price less in order to not send too much output.
    /// The most precise formula for this is liquidity * sqrtPX96 / (liquidity +- amount * sqrtPX96),
    /// if this is impossible because of overflow, we calculate liquidity / (liquidity / sqrtPX96 +- amount).
    /// @param sqrtPX96 The starting price, i.e. before accounting for the token0 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of token0 to add or remove from virtual reserves
    /// @param add Whether to add or remove the amount of token0
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
            uint256 product;
            if ((product = amount * sqrtPX96) / amount == sqrtPX96) {
                uint256 denominator = numerator1 + product;
                if (denominator >= numerator1) {
                    // always fits in 160 bits
                    return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
                }
            }

            return
                uint160(UnsafeMath.divRoundingUp(numerator1, (numerator1 / sqrtPX96).add(amount)));
        } else {
            uint256 product;
            // if the product overflows, we know the denominator underflows
            // in addition, we must check that the denominator does not underflow
            require((product = amount * sqrtPX96) / amount == sqrtPX96 && numerator1 > product);
            uint256 denominator = numerator1 - product;
            return FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator).toUint160();
        }
    }

    /// @notice Gets the next sqrt price given a delta of token1
    /// @dev Always rounds down, because in the exact output case (decreasing price) we need to move the price at least
    /// far enough to get the desired output amount, and in the exact input case (increasing price) we need to move the
    /// price less in order to not send too much output.
    /// The formula we compute is within <1 wei of the lossless version: sqrtPX96 +- amount / liquidity
    /// @param sqrtPX96 The starting price, i.e., before accounting for the token1 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of token1 to add, or remove, from virtual reserves
    /// @param add Whether to add, or remove, the amount of token1
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

            return uint256(sqrtPX96).add(quotient).toUint160();
        } else {
            uint256 quotient = (
                amount <= type(uint160).max
                    ? UnsafeMath.divRoundingUp(amount << FixedPoint96.RESOLUTION, liquidity)
                    : FullMath.mulDivRoundingUp(amount, FixedPoint96.Q96, liquidity)
            );

            require(sqrtPX96 > quotient);
            // always fits 160 bits
            return uint160(sqrtPX96 - quotient);
        }
    }

    /// @notice Gets the next sqrt price given an input amount of token0 or token1
    /// @dev Throws if price or liquidity are 0, or if the next price is out of bounds
    /// @param sqrtPX96 The starting price, i.e., before accounting for the input amount
    /// @param liquidity The amount of usable liquidity
    /// @param amountIn How much of token0, or token1, is being swapped in
    /// @param zeroForOne Whether the amount in is token0 or token1
    /// @return sqrtQX96 The price after adding the input amount to token0 or token1
    function getNextSqrtPriceFromInput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtQX96) {
        require(sqrtPX96 > 0);
        require(liquidity > 0);

        // round to make sure that we don't pass the target price
        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    /// @notice Gets the next sqrt price given an output amount of token0 or token1
    /// @dev Throws if price or liquidity are 0 or the next price is out of bounds
    /// @param sqrtPX96 The starting price before accounting for the output amount
    /// @param liquidity The amount of usable liquidity
    /// @param amountOut How much of token0, or token1, is being swapped out
    /// @param zeroForOne Whether the amount out is token0 or token1
    /// @return sqrtQX96 The price after removing the output amount of token0 or token1
    function getNextSqrtPriceFromOutput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountOut,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtQX96) {
        require(sqrtPX96 > 0);
        require(liquidity > 0);

        // round to make sure that we pass the target price
        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }

    /// @notice Gets the amount0 delta between two prices
    /// @dev Calculates liquidity / sqrt(lower) - liquidity / sqrt(upper),
    /// i.e. liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
    /// @param sqrtRatioAX96 A sqrt price
    /// @param sqrtRatioBX96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param roundUp Whether to round the amount up or down
    /// @return amount0 Amount of token0 required to cover a position of size liquidity between the two passed prices
    function getAmount0Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

        require(sqrtRatioAX96 > 0);

        return roundUp
            ? UnsafeMath.divRoundingUp(
                FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96), sqrtRatioAX96
            )
            : FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
    }

    /// @notice Gets the amount1 delta between two prices
    /// @dev Calculates liquidity * (sqrt(upper) - sqrt(lower))
    /// @param sqrtRatioAX96 A sqrt price
    /// @param sqrtRatioBX96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param roundUp Whether to round the amount up, or down
    /// @return amount1 Amount of token1 required to cover a position of size liquidity between the two passed prices
    function getAmount1Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        return roundUp
            ? FullMath.mulDivRoundingUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96)
            : FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96);
    }

    /// @notice Helper that gets signed token0 delta
    /// @param sqrtRatioAX96 A sqrt price
    /// @param sqrtRatioBX96 Another sqrt price
    /// @param liquidity The change in liquidity for which to compute the amount0 delta
    /// @return amount0 Amount of token0 corresponding to the passed liquidityDelta between the two prices
    function getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, int128 liquidity)
        internal
        pure
        returns (int256 amount0)
    {
        return liquidity < 0
            ? -getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(-liquidity), false).toInt256()
            : getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(liquidity), true).toInt256();
    }

    /// @notice Helper that gets signed token1 delta
    /// @param sqrtRatioAX96 A sqrt price
    /// @param sqrtRatioBX96 Another sqrt price
    /// @param liquidity The change in liquidity for which to compute the amount1 delta
    /// @return amount1 Amount of token1 corresponding to the passed liquidityDelta between the two prices
    function getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, int128 liquidity)
        internal
        pure
        returns (int256 amount1)
    {
        return liquidity < 0
            ? -getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(-liquidity), false).toInt256()
            : getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(liquidity), true).toInt256();
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
        // 512-bit multiply [prod1 prod0] = a * b
        // Compute the product mod 2**256 and mod 2**256 - 1
        // then use the Chinese Remainder Theorem to reconstruct
        // the 512 bit result. The result is stored in two 256
        // variables such that product = prod1 * 2**256 + prod0
        uint256 prod0; // Least significant 256 bits of the product
        uint256 prod1; // Most significant 256 bits of the product
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // Handle non-overflow cases, 256 by 256 division
        if (prod1 == 0) {
            require(denominator > 0);
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }

        // Make sure the result is less than 2**256.
        // Also prevents denominator == 0
        require(denominator > prod1);

        ///////////////////////////////////////////////
        // 512 by 256 division.
        ///////////////////////////////////////////////

        // Make division exact by subtracting the remainder from [prod1 prod0]
        // Compute remainder using mulmod
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }
        // Subtract 256 bit number from 512 bit number
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // Factor powers of two out of denominator
        // Compute largest power of two divisor of denominator.
        // Always >= 1.
        uint256 twos = uint256(-int256(denominator)) & denominator;
        // Divide denominator by power of two
        assembly {
            denominator := div(denominator, twos)
        }

        // Divide [prod1 prod0] by the factors of two
        assembly {
            prod0 := div(prod0, twos)
        }
        // Shift in bits from prod1 into prod0. For this we need
        // to flip `twos` such that it is 2**256 / twos.
        // If twos is zero, then it becomes one
        assembly {
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
        // correct result modulo 2**256. Since the precoditions guarantee
        // that the outcome is less than 2**256, this is the final result.
        // We don't need to compute the high bits of the result and prod1
        // is no longer required.
        result = prod0 * inv;
        return result;
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
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            require(result < type(uint256).max);
            result++;
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

/// @title Optimized overflow and underflow safe math operations
/// @notice Contains methods for doing math operations that revert on overflow or underflow for minimal gas cost
library LowGasSafeMath {
    /// @notice Returns x + y, reverts if sum overflows uint256
    /// @param x The augend
    /// @param y The addend
    /// @return z The sum of x and y
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }

    /// @notice Returns x - y, reverts if underflows
    /// @param x The minuend
    /// @param y The subtrahend
    /// @return z The difference of x and y
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    /// @notice Returns x * y, reverts if overflows
    /// @param x The multiplicand
    /// @param y The multiplier
    /// @return z The product of x and y
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(x == 0 || (z = x * y) / x == y);
    }

    /// @notice Returns x + y, reverts if overflows or underflows
    /// @param x The augend
    /// @param y The addend
    /// @return z The sum of x and y
    function add(int256 x, int256 y) internal pure returns (int256 z) {
        require((z = x + y) >= x == (y >= 0));
    }

    /// @notice Returns x - y, reverts if overflows or underflows
    /// @param x The minuend
    /// @param y The subtrahend
    /// @return z The difference of x and y
    function sub(int256 x, int256 y) internal pure returns (int256 z) {
        require((z = x - y) <= x == (y >= 0));
    }
}

/// @title Safe casting methods
/// @notice Contains methods for safely casting between types
library SafeCast {
    /// @notice Cast a uint256 to a uint160, revert on overflow
    /// @param y The uint256 to be downcasted
    /// @return z The downcasted integer, now type uint160
    function toUint160(uint256 y) internal pure returns (uint160 z) {
        require((z = uint160(y)) == y);
    }

    /// @notice Cast a int256 to a int128, revert on overflow or underflow
    /// @param y The int256 to be downcasted
    /// @return z The downcasted integer, now type int128
    function toInt128(int256 y) internal pure returns (int128 z) {
        require((z = int128(y)) == y);
    }

    /// @notice Cast a uint256 to a int256, revert on overflow
    /// @param y The uint256 to be casted
    /// @return z The casted integer, now type int256
    function toInt256(uint256 y) internal pure returns (int256 z) {
        require(y < 2 ** 255);
        z = int256(y);
    }
}

/// @title Math functions that do not check inputs or outputs
/// @notice Contains methods that perform common math functions but do not do any overflow or underflow checks
library UnsafeMath {
    /// @notice Returns ceil(x / y)
    /// @dev division by 0 has unspecified behavior, and must be checked externally
    /// @param x The dividend
    /// @param y The divisor
    /// @return z The quotient, ceil(x / y)
    function divRoundingUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            z := add(div(x, y), gt(mod(x, y), 0))
        }
    }
}

library V3TickBitmap {
    // Floor-divide a tick to its spacing bucket (Uniswap-style)
    function _compress(int24 tick, int24 spacing) private pure returns (int24 c) {
        c = tick / spacing;
        // round toward -infinity for negatives
        if (tick < 0 && (tick % spacing != 0)) c -= 1;
    }

    // Position (word, bit) for a compressed tick
    function _position(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(compressed >> 8); // /256 (arith shift keeps sign)
        // map negative remainders into [0,255]
        unchecked {
            bitPos = uint8(uint256(int256(compressed % 256)));
        }
    }

    // msb/lsb finders (small + gas-ok for view quoting)
    function _msb(uint256 x) private pure returns (uint8 r) {
        require(x > 0, "msb0");
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

    function _lsb(uint256 x) private pure returns (uint8) {
        require(x > 0, "lsb0");
        // isolate lowest set bit, then msb on that
        return _msb(x & (~x + 1));
    }

    /// @notice Find the next initialized tick in trade direction
    /// @param pool        v3 pool address
    /// @param tick        current tick from slot0
    /// @param spacing     tick spacing from factory.feeAmountTickSpacing(fee)
    /// @param zeroForOne  true if swapping token0->token1 (price down)
    /// @return nextTick   next initialized tick index (uncompressed)
    /// @return sqrtTarget sqrtPriceX96 at that tick (or extreme if none found)
    function nextInitializedTick(address pool, int24 tick, int24 spacing, bool zeroForOne)
        internal
        view
        returns (int24 nextTick, uint160 sqrtTarget)
    {
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        int24 compressed = _compress(tick, spacing);
        (int16 wordPos, uint8 bitPos) = _position(compressed);

        // word bounds from min/max ticks (prevents unbounded walking)
        int24 minComp = _compress(TickMath.MIN_TICK, spacing);
        int24 maxComp = _compress(TickMath.MAX_TICK, spacing);
        int16 minWord = int16(minComp >> 8);
        int16 maxWord = int16(maxComp >> 8);

        if (zeroForOne) {
            uint256 word = p.tickBitmap(wordPos);
            // [0..bitPos] inclusive; guard bitPos==255 to avoid (1<<256) overflow
            uint256 mask =
                bitPos == 255 ? type(uint256).max : ((uint256(1) << (uint256(bitPos) + 1)) - 1);
            uint256 masked = word & mask;

            if (masked != 0) {
                uint8 m = _msb(masked); // furthest up within [0..bitPos] (inclusive)
                int24 comp = int24(int256(wordPos)) * 256 + int24(uint24(m));
                nextTick = comp * spacing;
                sqrtTarget = TickMath.getSqrtRatioAtTick(nextTick);
                return (nextTick, sqrtTarget);
            }

            // walk to previous non-empty word
            while (wordPos > minWord) {
                unchecked {
                    --wordPos;
                }
                word = p.tickBitmap(wordPos);
                if (word != 0) {
                    uint8 m = _msb(word);
                    int24 comp = int24(int256(wordPos)) * 256 + int24(uint24(m));
                    nextTick = comp * spacing;
                    sqrtTarget = TickMath.getSqrtRatioAtTick(nextTick);
                    return (nextTick, sqrtTarget);
                }
            }

            // nothing below → clamp
            nextTick = minComp * spacing;
            sqrtTarget = TickMath.MIN_SQRT_RATIO + 1;
            return (nextTick, sqrtTarget);
        } else {
            uint256 word = p.tickBitmap(wordPos);
            // [bitPos+1..255] exclusive of current; if bitPos==255 nothing above in this word
            uint256 mask = bitPos == 255 ? 0 : ~((uint256(1) << (uint256(bitPos) + 1)) - 1);
            uint256 masked = word & mask;

            if (masked != 0) {
                uint8 l = _lsb(masked); // closest up within [bitPos+1..255]
                int24 comp = int24(int256(wordPos)) * 256 + int24(uint24(l));
                nextTick = comp * spacing;
                sqrtTarget = TickMath.getSqrtRatioAtTick(nextTick);
                return (nextTick, sqrtTarget);
            }

            // walk to next non-empty word
            while (wordPos < maxWord) {
                unchecked {
                    ++wordPos;
                }
                word = p.tickBitmap(wordPos);
                if (word != 0) {
                    uint8 l = _lsb(word);
                    int24 comp = int24(int256(wordPos)) * 256 + int24(uint24(l));
                    nextTick = comp * spacing;
                    sqrtTarget = TickMath.getSqrtRatioAtTick(nextTick);
                    return (nextTick, sqrtTarget);
                }
            }

            // nothing above → clamp
            nextTick = maxComp * spacing;
            sqrtTarget = TickMath.MAX_SQRT_RATIO - 1;
            return (nextTick, sqrtTarget);
        }
    }

    function _v4NextInitializedTick(
        IStateViewV4 sv,
        bytes32 poolId,
        int24 tick,
        int24 spacing,
        bool zeroForOne
    ) internal view returns (int24 nextTick, uint160 sqrtTarget) {
        // compress tick to spacing bucket, then find bit in [wordPos]
        int24 compressed = tick / spacing;
        if (tick < 0 && (tick % spacing != 0)) compressed -= 1;
        int16 wordPos = int16(compressed >> 8);
        uint8 bitPos = uint8(uint256(int256(compressed % 256)));

        int24 minComp = TickMath.MIN_TICK / spacing;
        if (TickMath.MIN_TICK < 0 && (TickMath.MIN_TICK % spacing != 0)) minComp -= 1;
        int24 maxComp = TickMath.MAX_TICK / spacing;
        if (TickMath.MAX_TICK < 0 && (TickMath.MAX_TICK % spacing != 0)) maxComp -= 1;
        int16 minWord = int16(minComp >> 8);
        int16 maxWord = int16(maxComp >> 8);

        if (zeroForOne) {
            uint256 word = sv.getTickBitmap(poolId, wordPos);
            uint256 mask =
                bitPos == 255 ? type(uint256).max : ((uint256(1) << (uint256(bitPos) + 1)) - 1);
            uint256 masked = word & mask;
            if (masked != 0) {
                uint8 m = _msb(masked);
                int24 comp = int24(int256(wordPos)) * 256 + int24(uint24(m));
                nextTick = comp * spacing;
                sqrtTarget = TickMath.getSqrtRatioAtTick(nextTick);
                return (nextTick, sqrtTarget);
            }
            while (wordPos > minWord) {
                word = sv.getTickBitmap(poolId, --wordPos);
                if (word != 0) {
                    uint8 m = _msb(word);
                    int24 comp = int24(int256(wordPos)) * 256 + int24(uint24(m));
                    nextTick = comp * spacing;
                    sqrtTarget = TickMath.getSqrtRatioAtTick(nextTick);
                    return (nextTick, sqrtTarget);
                }
            }
            nextTick = minComp * spacing;
            sqrtTarget = TickMath.MIN_SQRT_RATIO + 1;
            return (nextTick, sqrtTarget);
        } else {
            uint256 word = sv.getTickBitmap(poolId, wordPos);
            uint256 mask = bitPos == 255 ? 0 : ~((uint256(1) << (uint256(bitPos) + 1)) - 1);
            uint256 masked = word & mask;
            if (masked != 0) {
                uint8 l = _lsb(masked);
                int24 comp = int24(int256(wordPos)) * 256 + int24(uint24(l));
                nextTick = comp * spacing;
                sqrtTarget = TickMath.getSqrtRatioAtTick(nextTick);
                return (nextTick, sqrtTarget);
            }
            while (wordPos < maxWord) {
                word = sv.getTickBitmap(poolId, ++wordPos);
                if (word != 0) {
                    uint8 l = _lsb(word);
                    int24 comp = int24(int256(wordPos)) * 256 + int24(uint24(l));
                    nextTick = comp * spacing;
                    sqrtTarget = TickMath.getSqrtRatioAtTick(nextTick);
                    return (nextTick, sqrtTarget);
                }
            }
            nextTick = maxComp * spacing;
            sqrtTarget = TickMath.MAX_SQRT_RATIO - 1;
            return (nextTick, sqrtTarget);
        }
    }
}

library V3QuoterSingleTick {
    struct Quote {
        uint256 amountIn;
        uint256 amountOut;
        bool singleTick; // true if swap fits in current tick-spacing interval
        uint160 sqrtPriceAfter; // post-swap sqrtP if singleTick
    }

    /// @dev Conservative single-tick quote:
    function quoteV3SingleTick(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 swapAmount
    ) internal view returns (Quote memory q) {
        if (swapAmount == 0) return q;
        if (fee >= 1_000_000) return q; // defensive: prevents div-by-zero on (1_000_000 - fee)

        // fetch pool
        IUniswapV3Factory f = IUniswapV3Factory(V3_FACTORY);
        address pool = f.getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) return q;

        IUniswapV3Pool p = IUniswapV3Pool(pool);
        (uint160 sqrtP, int24 tick,,,,,) = p.slot0();
        uint128 L = p.liquidity();
        if (L == 0) return q;

        // direction & spacing
        bool zeroForOne = (tokenIn == p.token0());
        int24 spacing = f.feeAmountTickSpacing(fee);
        if (spacing <= 0) return q; // defensive

        // REAL next initialized tick in trade direction (via bitmap), not just spacing boundary
        (, uint160 sqrtBoundary) = V3TickBitmap.nextInitializedTick(pool, tick, spacing, zeroForOne);

        // Fee math: fee is in hundredths of a bip (1e-6). Apply to input leg.
        // Uniswap v3 takes the fee from amountIn before moving price.
        uint256 feeDenom = 1_000_000;
        uint256 feeMul = feeDenom - fee;

        if (!exactOut) {
            // exactIn: check if fee-adjusted input fits to boundary
            uint256 amountInLessFee = FullMath.mulDiv(swapAmount, feeMul, feeDenom);

            // capacity to boundary (input token) — ROUND DOWN for safety
            uint256 capIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtBoundary, sqrtP, L, false)
                : SqrtPriceMath.getAmount1Delta(sqrtP, sqrtBoundary, L, false);

            if (amountInLessFee <= capIn) {
                // single tick: get final price, then opposing delta
                uint160 sqrtAfter =
                    SqrtPriceMath.getNextSqrtPriceFromInput(sqrtP, L, amountInLessFee, zeroForOne);
                uint256 out = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(sqrtAfter, sqrtP, L, false) // round DOWN on output
                    : SqrtPriceMath.getAmount0Delta(sqrtP, sqrtAfter, L, false); // round DOWN on output

                q = Quote({
                    amountIn: swapAmount,
                    amountOut: out,
                    singleTick: true,
                    sqrtPriceAfter: sqrtAfter
                });
                return q;
            }
            // else: not single-tick (might still be fine with multi-tick), leave q.zeroed
        } else {
            // exactOut: check if desired output fits to boundary — ROUND DOWN for safety
            uint256 capOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtBoundary, sqrtP, L, false)
                : SqrtPriceMath.getAmount0Delta(sqrtP, sqrtBoundary, L, false);

            if (swapAmount <= capOut) {
                uint160 sqrtAfter =
                    SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtP, L, swapAmount, zeroForOne);

                // compute required input (pre-fee), then gross up by fee — ROUND UP on input
                uint256 inLessFee = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(sqrtAfter, sqrtP, L, true)
                    : SqrtPriceMath.getAmount1Delta(sqrtP, sqrtAfter, L, true);

                // amountInGross = ceil(inLessFee / (1 - fee))
                uint256 inGross = FullMath.mulDivRoundingUp(inLessFee, feeDenom, feeMul);

                q = Quote({
                    amountIn: inGross,
                    amountOut: swapAmount,
                    singleTick: true,
                    sqrtPriceAfter: sqrtAfter
                });
                return q;
            }
        }
        // default: q.singleTick == false, amounts zero -> caller may try multi-tick later
    }
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

function _sortTokens(address tokenA, address tokenB)
    pure
    returns (address token0, address token1, bool zeroForOne)
{
    (token0, token1) = (zeroForOne = tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
}
