# [zRouter](https://github.com/zammdefi/zRouter)  [![License:MIT](https://img.shields.io/badge/License-MIT-black.svg)](https://opensource.org/license/mit) [![solidity](https://img.shields.io/badge/solidity-%5E0.8.30-black)](https://docs.soliditylang.org/en/v0.8.30/) [![Foundry](https://img.shields.io/badge/Built%20with-Foundry-000000.svg)](https://getfoundry.sh/) ![tests](https://github.com/zammdefi/zRouter/actions/workflows/ci.yml/badge.svg)

An actually simple and gas-efficient Uniswap router with zAMM. 

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

## Notable Mentions

- [femplate](https://github.com/refcell/femplate)
- [prb-foundry-template](https://github.dev/PaulRBerg/foundry-template)

## Disclaimer

*These smart contracts and testing suite are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of anything provided herein or through related user interfaces. This repository and related code have not been audited and as such there can be no assurance anything will work as intended, and users may experience delays, failures, errors, omissions, loss of transmitted information or loss of funds. The creators are not liable for any of the foregoing. Users should proceed with caution and use at their own risk.*

## License

See [LICENSE](./LICENSE) for more details.
