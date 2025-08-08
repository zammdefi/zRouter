# [zRouter](https://github.com/zammdefi/zRouter)  [![License:MIT](https://img.shields.io/badge/License-MIT-black.svg)](https://opensource.org/license/mit) [![solidity](https://img.shields.io/badge/solidity-%5E0.8.30-black)](https://docs.soliditylang.org/en/v0.8.30/) [![Foundry](https://img.shields.io/badge/Built%20with-Foundry-000000.svg)](https://getfoundry.sh/)

An actually simple and gas-efficient Uniswap router with zAMM.

Each version has dedicated entrypoint function with similar args:

- `swapV2()`
- `swapV3()`
- `swapV4()`
- `swapVZ()`

Features:

- cheapest singlehop for every single version of uniswap
- multihop through a simple call chain via `multicall()`
- slippage protection on each hop inside multihop chains
- bridges all liquid ERC20s with ERC6909 finance on zAMM

Deployed to [0x0000000000999e93e27973C9EC7298b5DBE7d7A0](https://contractscan.xyz/contract/0x0000000000999e93e27973C9EC7298b5DBE7d7A0).

Great for bots, on-the-fly strategies, and aggregation.

## zRouter vs Uniswap – Gas Benchmarks

**Summary:** zRouter consistently outgasses Uniswap for common paths — clean sweeps on V2 (8/8 wins, median -6.25%), strong wins on V3 singles (6/6 wins, median -5.21%), and sizable savings vs Universal Router on cross‑AMM routes (2/2 wins, median -13.33%). Multihop V3/V4 paths are the next optimization target.

| Scenario | Uniswap Gas | zRouter Gas | Diff | % Change | Verdict |
|---|---:|---:|---:|---:|---|
| V2 single: ETH→TOKEN (exact-in) | 84,379 | 80,209 | -4,170 | -4.94% | zRouter wins |
| V2 single: TOKEN→ETH (exact-in) | 90,891 | 85,397 | -5,494 | -6.04% | zRouter wins |
| V2 single: TOKEN→TOKEN (exact-in) | 86,589 | 80,977 | -5,612 | -6.48% | zRouter wins |
| V2 single: ETH→TOKEN (exact-out) | 91,351 | 85,455 | -5,896 | -6.45% | zRouter wins |
| V2 single: TOKEN→ETH (exact-out) | 91,826 | 86,728 | -5,098 | -5.55% | zRouter wins |
| V2 single: TOKEN→TOKEN (exact-out) | 86,578 | 80,683 | -5,895 | -6.81% | zRouter wins |
| V2 multi: ERC20→WETH→USDC (exact-in) | 130,790 | 127,312 | -3,478 | -2.66% | zRouter wins |
| V2 multi: ERC20→USDC→WETH (exact-in) | 148,381 | 128,927 | -19,454 | -13.11% | zRouter wins |
| V3 single: ETH→TOKEN (exact-in) | 115,588 | 110,209 | -5,379 | -4.65% | zRouter wins |
| V3 single: TOKEN→ETH (exact-in) | 157,673 | 143,950 | -13,723 | -8.70% | zRouter wins |
| V3 single: TOKEN→USDC (exact-in) | 333,904 | 327,884 | -6,020 | -1.80% | zRouter wins |
| V3 single: ETH→TOKEN (exact-out) | 138,927 | 123,450 | -15,477 | -11.14% | zRouter wins |
| V3 single: TOKEN→ETH (exact-out) | 119,296 | 117,648 | -1,648 | -1.38% | zRouter wins |
| V3 single: USDC→TOKEN (exact-out) | 124,616 | 117,419 | -7,197 | -5.78% | zRouter wins |
| V3 multi: ETH→TOKEN→USDC (exact-in) | 363,435 | 447,993 | +84,558 | +23.27% | Uniswap wins |
| V3 multi: TOKEN→USDC→ETH (exact-in) | 226,996 | 432,683 | +205,687 | +90.61% | Uniswap wins |
| UR: V2→V3 (exact-in) | 166,322 | 152,708 | -13,614 | -8.19% | zRouter wins |
| UR: V3→V2 (exact-in) | 228,586 | 186,362 | -42,224 | -18.47% | zRouter wins |
| V4 single: ETH→USDC (exact-in) | 92,528 | 90,240 | -2,288 | -2.47% | zRouter wins |
| V4 multi: ETH→USDC→USDT (exact-in) | 146,316 | 188,236 | +41,920 | +28.65% | Uniswap wins |

## Getting Started

Run: `curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup`

Build the foundry project with `forge build`. Run tests with `forge test`. Measure gas with `forge snapshot`. Format with `forge fmt`.

## GitHub Actions

Contracts will be tested and gas measured on every push and pull request.

## Blueprint

```txt
lib
├─ forge-std — https://github.com/foundry-rs/forge-std
├─ solady — https://github.com/vectorized/solady
src
├─ zRouter — Router Contract
test
├─ zRouter.t — Test Contract
└─ zRouterBench.t - Benchmarks
```

## Disclaimer

*These smart contracts and testing suite are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of anything provided herein or through related user interfaces. This repository and related code have not been audited and as such there can be no assurance anything will work as intended, and users may experience delays, failures, errors, omissions, loss of transmitted information or loss of funds. The creators are not liable for any of the foregoing. Users should proceed with caution and use at their own risk.*

## License

See [LICENSE](./LICENSE) for more details.
