# btcbot smart contracts

On-chain contracts for [btcbot.io](https://btcbot.io), a non-custodial Bitcoin trading bot live on **BNB Smart Chain** (BSC mainnet, chain id 56). This repository contains the source of every router generation users have interacted with, its Foundry test suite, the deploy scripts and the security review history.

**See it live without signing up: [btcbot.io/demo](https://btcbot.io/demo)** shows a real account with every trade verifiable on BscScan.

## Security model

btcbot never holds user funds. Users keep their keys, grant the router a bounded, revocable ERC20 approval and sign an EIP-712 trade mandate. What protects their funds is enforced by the contract itself:

- **Funds go back to the user's wallet.** Each swap pulls the input from the user's wallet, swaps it on PancakeSwap V3 and sends the output to the same wallet in the same transaction. A single swap either completes or reverts. In a batch, if the final transfer to one user fails, the amount is recorded on-chain as owed to that user and anyone can deliver it to them (`claimStranded`); it can only ever go to that user.
- **Limits the user signed.** Every swap must respect the user's mandate: maximum amount per trade, maximum cumulative volume, maximum slippage, maximum commission, expiry. It must also clear a price floor from two Chainlink feeds (BTC/USD and USDT/USD).
- **Commission.** The performance fee is charged only on realized gains. Our backend computes it; the contract caps it at the rate the user signed (it reverts with `CommissionTooHigh` above that) and pays it to recipients read from its own on-chain referral tree.
- **Revocable at any time.** Approvals and mandates can be revoked by the user directly on-chain, and users can send their funds to any other wallet at any moment. The bot needs nothing from them to let go.
- **Owner powers are bounded.** The owner is a hardware wallet. It can pause the router, rotate the trader key, update referral recipients and adjust bounded parameters (slippage cap at most 5%, oracle staleness at most 2 hours). Changing the swap venue takes a 48-hour timelock. It cannot move user funds: `rescueToken` is barred from amounts owed to users.
- **Not upgradeable.** No proxy, no `delegatecall`: the deployed code cannot be changed.

## Deployed contracts (BSC mainnet)

All seven deployments are verified on BscScan (solc 0.8.24, optimizer 200 runs, EVM paris).

| Contract | Address | Source | Status |
|---|---|---|---|
| **BtcbotRouterV3** | [`0x600D173c359DB44aFef10b38cA2D7Cad0A320b28`](https://bscscan.com/address/0x600D173c359DB44aFef10b38cA2D7Cad0A320b28#code) | `src/BtcbotRouterV3.sol`, identical | **live, current router** since 2026-08-26 |
| BtcbotRouterV2 | [`0xaCa5F1b6875f5cb020C9623DA563e983184ec799`](https://bscscan.com/address/0xaCa5F1b6875f5cb020C9623DA563e983184ec799#code) | `src/BtcbotRouterV2.sol`, identical | previous generation, still executing some trades while accounts move to V3 (last trade 2026-10-04) |
| BtcbotRouterDuplex | [`0x581bfa1cAe0066c5032650ed47A9D6BFa3Faf322`](https://bscscan.com/address/0x581bfa1cAe0066c5032650ed47A9D6BFa3Faf322#code) | `src/BtcbotRouterDuplex.sol`, identical | legacy, still executing a few trades (last trade 2026-10-04) |
| BtcbotCommissionRouter (batch) | [`0xB81C0b302020a5691A7Dc9FB171F86DFEafa5199`](https://bscscan.com/address/0xB81C0b302020a5691A7Dc9FB171F86DFEafa5199#code) | `src/BtcbotCommissionRouter.sol`, identical | retired, last trade 2026-07-21 |
| BtcbotCommissionRouter (first deployment) | [`0xb19125d55eD7878686Dc173d1501C0C486d2d850`](https://bscscan.com/address/0xb19125d55eD7878686Dc173d1501C0C486d2d850#code) | earlier revision, source on BscScan | retired, last trade 2026-07-04 |
| BtcbotRouter | [`0x7Cc6D01e18f8353b05cFA3C9D0047BDBF7F91D0e`](https://bscscan.com/address/0x7Cc6D01e18f8353b05cFA3C9D0047BDBF7F91D0e#code) | `src/BtcbotRouter.sol`, identical | retired, last trade 2026-05-20 |
| BtcbotRouter (first deployment) | [`0x0BAA249dD88D952eff91320479acf4dC51Cefa50`](https://bscscan.com/address/0x0BAA249dD88D952eff91320479acf4dC51Cefa50#code) | earlier revision, source on BscScan | never used for trades |

"Identical" means the verified source on BscScan matches the file in `src/` line for line. Source comments are part of the verified source, so they are kept exactly as deployed: some refer to internal design documents that are not published, and to the review rounds described in `audits/`.

V3 is V2 plus one user-protection change: if a settlement transfer to a user ever fails, the amount is recorded as owed to that user, anyone may call `claimStranded` to deliver it, and the owner's `rescueToken` cannot touch it. Apart from the contract name and its EIP-712 signing domain, the rest of the code is unchanged; compare `src/BtcbotRouterV2.sol` and `src/BtcbotRouterV3.sol`.

## Security approach

We did not hire a third-party audit firm. No review can promise a contract without flaws, so we chose a design that limits what a flaw can cost, and the reviews of the security layers that wallets rely on.

- **Limited by design.** The router holds no user funds between transactions: each swap sends its output back to the user's wallet in the same transaction. It can only pull what the user approved, within the limits the user signed and above an oracle price floor, and the user can revoke the approval at any time. The code cannot be upgraded.
- **Wallet security layers.** The V2 hardening (oracle floor, signed mandates, swap-venue timelock, on-chain commission recipients, bounded approvals) was built in answer to Blockaid's review in June 2026; Blockaid screens transactions for MetaMask. The only change in V3 answers a centralization finding from DappBay, BNB Chain's dApp store, where btcbot.io is listed.
- **Reviews and analysis.** Internal reviews and several rounds of AI-assisted security review, documented finding by finding with their fixes, plus Slither static analysis for every generation. [`audits/README.md`](audits/README.md) explains what each document covers and how to read Slither's raw counts.

## Build and test

Standard [Foundry](https://book.getfoundry.sh/) project:

```bash
forge install foundry-rs/forge-std@v1.9.4
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2
forge build
forge test --no-match-contract Fork      # unit and mock suites
forge test --match-contract Fork --fork-url https://bsc-dataseed.binance.org   # against live BSC
```

A reproducible toolchain image is provided in `Dockerfile.foundry`.

## Scope

The off-chain trading engine (strategy, signals, execution) is closed-source by design: it is our edge and none of it needs to be trusted. Every component that touches user funds is in this repository and verified on-chain.

## Links

Website: [btcbot.io](https://btcbot.io) · Live demo: [btcbot.io/demo](https://btcbot.io/demo) · Support: [Telegram](https://t.me/+yyKKrR-Pdtk5YzY0)

## License

All rights reserved. The source is published for transparency and independent verification.
