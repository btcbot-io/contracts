# btcbot smart contracts

On-chain contracts for [btcbot.io](https://btcbot.io), a non-custodial Bitcoin trading bot deployed and live on **BNB Smart Chain** (BSC mainnet, chain id 56). This repository contains every contract users interact with, their full Foundry test suite, the deploy scripts, and the audit artifacts.

**See it live without signing up: [btcbot.io/demo](https://btcbot.io/demo)** shows a real account with every trade verifiable on BscScan.

## Security model

btcbot never holds user funds. Users keep their keys and grant a bounded, revocable ERC20 approval to the router, plus a signed EIP-712 trade mandate with hard caps. Everything a user must trust is enforced by the contract itself, not by our backend:

- Swaps route through PancakeSwap. The router only moves funds between the user's wallet and the pool inside one atomic transaction: if anything fails, the whole trade reverts and funds stay put.
- The performance fee (charged only on realized gains) and its referral split are computed and distributed by the contract in the same transaction as the swap. The backend cannot take more than the mandate allows: the contract reverts on any attempt (`CommissionTooHigh`).
- Approvals and mandates are revocable by the user at any time, directly on-chain.
- Users can withdraw their funds at any moment. The bot needs nothing from them to let go.

## Deployed contracts (BSC mainnet, verified)

| Contract | Address | Status |
|---|---|---|
| **BtcbotRouterV2** | [`0xaCa5F1b6875f5cb020C9623DA563e983184ec799`](https://bscscan.com/address/0xaCa5F1b6875f5cb020C9623DA563e983184ec799) | **live, current target** |
| BtcbotRouterDuplex | [`0x581bfa1cAe0066c5032650ed47A9D6BFa3Faf322`](https://bscscan.com/address/0x581bfa1cAe0066c5032650ed47A9D6BFa3Faf322) | legacy, draining |
| BtcbotCommissionRouter | [`0xB81C0b302020a5691A7Dc9FB171F86DFEafa5199`](https://bscscan.com/address/0xB81C0b302020a5691A7Dc9FB171F86DFEafa5199) | legacy, draining |
| BtcbotRouter (v1) | [`0xb19125d55eD7878686Dc173d1501C0C486d2d850`](https://bscscan.com/address/0xb19125d55eD7878686Dc173d1501C0C486d2d850) | legacy, draining |

The verified source on BscScan matches `src/` in this repository. The contract lineage (v1 to V2) is published in full so anyone can review how the design evolved.

## Audits and analysis

The `audits/` folder contains the internal audit scope and fixes for V2 (`AUDIT_SCOPE_V2.md`, `AUDIT_FIXES_V2.md`), the review history, and five Slither static-analysis reports across the contract generations. V2 shipped after a dedicated audit pass; the security-sensitive changes are documented finding by finding.

## Build and test

Standard [Foundry](https://book.getfoundry.sh/) project:

```bash
forge install foundry-rs/forge-std
forge build
forge test          # unit + mock suites
forge test --fork-url https://bsc-dataseed.binance.org --match-contract Fork
```

A reproducible toolchain image is provided in `Dockerfile.foundry`.

## Scope

The off-chain trading engine (strategy, signals, execution) is closed-source by design: it is our edge and none of it needs to be trusted. Every component that touches user funds is in this repository and verified on-chain.

## Links

Website: [btcbot.io](https://btcbot.io) · Live demo: [btcbot.io/demo](https://btcbot.io/demo) · Support: [Telegram](https://t.me/+yyKKrR-Pdtk5YzY0)

## License

All rights reserved. The source is published for transparency and independent verification.
