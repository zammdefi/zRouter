# [zRouter](https://github.com/zammdefi/zRouter) [![License:MIT](https://img.shields.io/badge/License-MIT-black.svg)](https://opensource.org/license/mit) [![solidity](https://img.shields.io/badge/solidity-%5E0.8.30-black)](https://docs.soliditylang.org/en/v0.8.30/) [![Foundry](https://img.shields.io/badge/Built%20with-Foundry-000000.svg)](https://getfoundry.sh/)

An actually simple and gas-efficient DEX aggregator router with [`zAMM`](https://zamm.finance/).

Each version has dedicated entrypoint function with similar args:

- `swapV2()`
- `swapV3()`
- `swapV4()`
- `swapVZ()`
- `swapCurve()`

Features:

- cheapest singlehop for every single version of uniswap
- multihop through a simple call chain via `multicall()`
- slippage protection on each hop inside multihop chains
- bridges all liquid ERC20s with ERC6909 finance on zAMM
- includes WETH abstraction for all ETH input and output

V2 deployed to Ethereum: [0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46](https://etherscan.io/address/0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46#code)

V1 deployed to Ethereum: [0x00000000008892d085e0611eb8C8BDc9FD856fD3](https://etherscan.io/address/0x00000000008892d085e0611eb8C8BDc9FD856fD3#code)

V0 deployed to [0x0000000000404FECAf36E6184245475eE1254835](https://contractscan.xyz/contract/0x0000000000404FECAf36E6184245475eE1254835) on Ethereum and Base.

Router helper (`zQuoter`) deployed to [0x9f373A73ED229C9D133A189c095E2fFb7B77703E](https://etherscan.io/address/0x9f373A73ED229C9D133A189c095E2fFb7B77703E#code) on Ethereum.

And [0x772E2810A471dB2CC7ADA0d37D6395476535889a](https://basescan.org/address/0x772E2810A471dB2CC7ADA0d37D6395476535889a#code) on Base.

Great for bots, on-the-fly strategies, and aggregation.

Bonus: Includes V2-style SushiSwap pools in `swapV2()`.

## Base deployment

Supports Aerodrome methods, `swapAero()`, `swapAeroCL()`. No SushiSwap. Otherwise ABI and Uniswap methods remain the same.

Onchain dapp deployment: [base.zamm.eth](https://base.zamm.eth.limo)

## Security note

Ensure atomic token allowances for best security. Previous versions may not have allowance guard.

## Dev tips

- If using hookless zamm (0x00...888), set `deadline` to `type(uint256).max` to trigger in `swapVZ()`
- If using SushiSwap (classic), set `deadline` to `type(uint256).max` to trigger in `swapV2()`

Both case default deadline to `(now) + 30 minutes`, which is a reasonable staleness guard.

## zRouter vs Uniswap – Gas Benchmarks

**Summary:** zRouter is most gas-efficient for routes between AMMs and single-hop swaps. zRouter consistently outgasses Uniswap routers for common paths — clean sweeps on V2 (single/multi), and on V3 and V4 singles, and sizable savings vs Universal Router on cross‑AMM routes (2/2 wins). Multihop V3/V4 paths are the next optimization target, and where gas loses out for sake of simplicity and multi-AMM handling.

# zRouter Gas — Benchmarks

| Type | Scenario | Baseline Gas | zRouter Gas | Diff | % Change |
|---|---|---:|---:|---:|---:|
| UR | V3TOV2 • Exact In | 228,586 | 186,362 | -42,224 | -18.47% |
| BASE | V2 • multi • exact-in • Tokens→USDC→ETH | 148,381 | 128,927 | -19,454 | -13.11% |
| BASE | V3 • single • exact-out • ETH→TOKEN | 138,927 | 123,450 | -15,477 | -11.14% |
| BASE | V3 • single • exact-in • TOKEN→ETH | 157,673 | 143,950 | -13,723 | -8.70% |
| UR | V2TOV3 • Exact In | 166,308 | 152,694 | -13,614 | -8.19% |
| BASE | V3 • single • exact-out • USDC→TOKEN | 124,616 | 117,419 | -7,197 | -5.78% |
| BASE | V3 • single • exact-in • TOKEN→USDC | 333,904 | 327,884 | -6,020 | -1.80% |
| BASE | V2 • single • exact-out • ETH→TOKEN | 91,351 | 85,455 | -5,896 | -6.45% |
| BASE | V2 • single • exact-out • TOKEN→TOKEN | 86,578 | 80,683 | -5,895 | -6.81% |
| BASE | V2 • single • exact-in • TOKEN→TOKEN | 86,589 | 80,977 | -5,612 | -6.48% |
| BASE | V2 • single • exact-in • TOKEN→ETH | 90,891 | 85,397 | -5,494 | -6.04% |
| BASE | V3 • single • exact-in • ETH→TOKEN | 115,588 | 110,209 | -5,379 | -4.65% |
| BASE | V2 • single • exact-out • TOKEN→ETH | 91,826 | 86,728 | -5,098 | -5.55% |
| BASE | V2 • single • exact-in • ETH→TOKEN | 84,379 | 80,209 | -4,170 | -4.94% |
| BASE | V2 • multi • exact-in • Tokens→ETH→USDC | 130,790 | 127,312 | -3,478 | -2.66% |
| BASE | V4 • single • exact-in • ETH→USDC | 92,368 | 90,080 | -2,288 | -2.48% |
| BASE | V3 • single • exact-out • TOKEN→ETH | 119,296 | 117,648 | -1,648 | -1.38% |

## Getting Started

Run: `curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup`

Build the foundry project with `forge build`. Run tests with `forge test`. Measure gas with `forge snapshot`. Format with `forge fmt`.

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
