# Wavelength

**Wavelength** is a [Uniswap v4](https://docs.uniswap.org/contracts/v4/overview) hook that detects and penalizes **JIT (just-in-time) liquidity attacks**, redistributes the penalty to **loyal, time-weighted LPs**, and uses the [Reactive Network](https://reactive.network/) to propagate JIT-risk signals **across pools and chains** so attackers can't evade detection by spreading their activity around.

Built for the **Uniswap Hookathon 10 (UHI10)** — covering both **Sustainable Liquidity** and **MEV Protection** theme criteria.

**Live Dashboard:** https://wavelength-virid.vercel.app

---

## The Problem: JIT Liquidity Attacks

JIT (just-in-time) liquidity is a MEV strategy where a searcher:

1. Watches the mempool for a large pending swap that will move price,
2. **Adds liquidity** in-range right before that swap executes (1–2 blocks ahead),
3. Collects the swap fee as if they were a long-term LP, then
4. **Removes liquidity** immediately after the swap lands.

The attacker captures fee yield **without ever bearing inventory risk or providing real liquidity**, while the value is skimmed from genuine LPs and the protocol's fee share. JIT attacks inflate swap fees for honest traders and discourage sustainable liquidity provision.

## The Solution

Wavelength makes JIT attacks **unprofitable** by detecting them on-chain and responding in real time:

| Layer | Mechanism |
|-------|-----------|
| **Detection** | The hook tracks per-LP `beforeAddLiquidity` timestamps and tick ranges. A swap above a size threshold triggers a "suspected JIT" window; if the same LP removes in-range liquidity within N blocks of a large swap, the event is confirmed. |
| **Penalty** | Confirmed JIT interactions are charged a **dynamic penalty fee** (5–10× the base fee) via v4's `updateDynamicLPFee`, escrowed into the pool. |
| **Redistribution** | Penalty fees are distributed to LPs weighted by **time-weighted liquidity** (loyalty), not just current share — and LPs can withdraw via `claimRebate()`. |
| **Propagation** | A **Reactive Smart Contract (RSC)** on Reactive Network subscribes to `JITDetected` events from every deployed hook and writes `address → riskScore` into a shared **JITRiskRegistry** on destination chains, so an attacker is penalized on their *first* interaction with any other pool — even one that never saw the attack. |

This is the differentiator versus other JIT-hook submissions: instead of per-pool defense, Wavelength builds a **cross-chain attacker memory** that closes the "spread the attack across pools" evasion path.

---

## Architecture

```
                          ┌──────────────────────────────┐
                          │   Uniswap v4 PoolManager      │
                          │   (Dynamic fee pool)          │
                          └──────────────┬───────────────┘
                                         │ hook calls
                          ┌──────────────▼───────────────┐
                          │  WavelengthHook (per chain)   │
                          │  - JIT detection (Phase 1)    │
                          │  - penalty fee (Phase 2)      │
                          │  - time-weighted rebates      │
                          │  - emits JITDetected(...)     │
                          └──────┬──────────────┬─────────┘
                                 │              │ event logs
                    JITDetected │              │ consult risk
                                 ▼              ▼
               ┌──────────────────────┐   ┌──────────────────────┐
               │ ReactiveJITListener  │   │  JITRiskRegistry      │
               │ (RSC on Reactive     │──▶│  address→riskScore    │
               │  Network testnet)    │   │  (destination chain)  │
               └──────────────────────┘   └──────────────────────┘
                                                    │
                    Wavelength React dashboard ◀────┘
                    (wagmi/viem, reads events + state, no backend)
```

- **On-chain:** `WavelengthHook` (per chain, Base Sepolia / Anvil), `JITRiskRegistry` (destination chain), `ReactiveJITListener` (RSC on Reactive Network testnet), plus a scripted `AttackSimulator` demo harness.
- **Off-chain:** a single-page React dashboard (no backend) that streams hook events, compares fees, totals redistributed value, shows the cross-chain risk registry, and triggers a scripted attack.

---

## Repository Layout

```
wavelength/
├── src/                          # React (TanStack Start) dashboard
│   ├── components/wavelength/    # LivePoolFeed, FeeComparison, RedistributedCounter,
│   │                             # RegistryViewer, SimulateAttack, ConfigPanel, panels
│   ├── lib/wavelength/           # wagmi config, contract ABIs, data hooks, config store
│   ├── routes/                   # TanStack Router (single "/" dashboard route)
│   └── components/ui/            # shadcn/ui primitives
├── contracts/                    # Foundry / Solidity
│   ├── src/WavelengthHook.sol    # Main hook (Phases 1+2 complete)
│   ├── test/WavelengthHook.t.sol # 14 passing tests
│   ├── script/                   # Deploy + salt mining scripts
│   └── lib/                      # v4-core, v4-periphery, OpenZeppelin, forge-std
└── wavelength-development-prompt.md  # Local dev prompt (gitignored)
```

---

## Current Build (what's in this repo)

### Smart Contracts (Phases 0–2 complete)

The `WavelengthHook` contract implements:
- **JIT Detection** — tracks LP additions with block number + tick range, flags suspected JIT during large swaps, confirms on removal
- **Dynamic Fee Penalty** — 10x fee override via `updateDynamicLPFee` on JIT detection, auto-resets after delay
- **Time-Weighted Redistribution** — penalty fees distributed to LPs proportional to position duration
- **Rebate Claims** — `claimRebate()` for LPs to withdraw accrued shares

14/14 Foundry tests passing covering all detection and redistribution scenarios.

### Frontend Dashboard

A complete, single-page **React + TanStack Start + wagmi/viem** dashboard:

1. **Live Pool Feed** — real-time swap / liquidity / JIT / redistribution events streamed from the hook, with JIT-flagged events highlighted in red.
2. **Fee Comparison Panel** — side-by-side normal fee vs. flagged JIT penalty fee, with a multiple× indicator.
3. **Redistributed Value Counter** — cumulative penalty value redistributed to loyal LPs, read from hook state.
4. **Cross-Chain Risk Registry Viewer** — flagged addresses, origin chain/pool, risk score, and live decay countdown.
5. **Simulate Attack** — a scripted add-liquidity → large swap → remove-liquidity sequence against an Anvil fork or testnet for live demos.
6. **Contracts config panel** — paste hook / registry / simulator addresses + RPC URL, stored locally in the browser (no backend).

The frontend talks to contracts exclusively through **declared ABI fragments** (`src/lib/wavelength/abi.ts`) for: `JITDetected`, `SwapObserved`, `LiquidityObserved`, `PenaltyRedistributed` events and `baseFeeBps` / `penaltyFeeBps` / `totalRedistributed` / `pendingRebate` / `claimRebate` reads; the registry's `RiskFlagged` / `RiskExpired` events and `riskOf` read; and the simulator's `simulateJitAttack` call.

---

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| **Phase 0** | Foundry environment, v4-core / v4-periphery / OpenZeppelin deps, hook scaffold + address-mining smoke test | ✅ Complete |
| **Phase 1** | Core JIT detection logic (`beforeAddLiquidity` / `beforeRemoveLiquidity` / `beforeSwap`), `JITDetected` event, false-positive test coverage | ✅ Complete |
| **Phase 2** | Dynamic fee penalty (10x), time-weighted redistribution, `claimRebate()`, penalty/redistribution tests | ✅ Complete |
| **Phase 3** | Reactive Network RSC (`ReactiveJITListener`) + `JITRiskRegistry`, cross-pool/chain risk propagation, decay cooldown, integration demo | 🔴 Pending |
| **Phase 4** | Frontend dashboard (this repo) — all five panels | 🟢 Mostly built |
| **Phase 5** | End-to-end demo script (attack on Pool A → cross-chain penalty on Pool B → LP rebate claim) | 🔴 Pending |
| **Phase 6** | Submission polish: README architecture diagram, demo video, testnet deployments, gas profiling | 🔴 Pending |

The detailed phase-by-phase development prompt lives in `wavelength-development-prompt.md` (local-only, **never committed**). Each remaining phase is tracked as a GitHub issue.

---

## Development

### Prerequisites

- **Node.js 20+** (for the dashboard) — [install with nvm](https://github.com/nvm-sh/nvm#installing-and-updating)
- **Foundry** (`forge`, `cast`, `anvil`) — required once the Solidity build-out lands

### Dashboard

```sh
npm i
npm run dev        # start the Vite dev server
```

### Configuration

Open the **Contracts** panel (top-right) and enter:

| Field | Purpose |
|-------|---------|
| Chain | `Base Sepolia` or `Anvil` (local fork) |
| Wavelength hook | Deployed hook address (`0x…`) |
| JITRiskRegistry | Registry on the destination chain |
| Attack simulator | Demo harness address (optional) |
| Demo pool id | 32-byte v4 `PoolId` |
| RPC URL | Optional override (falls back to public RPC) |

Values persist in `localStorage` per browser.

### Scripts

| Command | Description |
|---------|-------------|
| `npm run dev` | Start the dev server |
| `npm run build` | Production build |
| `npm run preview` | Preview the production build |
| `npm run lint` | ESLint |
| `npm run format` | Prettier (write) |

---

## Tech Stack

- **Frontend:** React 19, TanStack Start + Router, Vite, Tailwind CSS 4, shadcn/ui (Radix primitives)
- **Web3:** wagmi v3, viem 2, `injected` connector, Base Sepolia + Anvil chains
- **On-chain (planned):** Solidity + Foundry, Uniswap v4-core / v4-periphery, OpenZeppelin, Reactive Network SDK
- **State:** TanStack Query, local config store

---

## Hackathon Notes

- **UHI10 Sustainable Liquidity:** time-weighted rebates reward LPs for *loyalty*, making long-term liquidity provision more valuable and turning JIT profit into LP rewards.
- **UHI10 MEV Protection:** the penalty fee makes JIT attacks net-negative for the attacker, and Reactive Network propagation closes the cross-pool evasion route.
- Target demo chain: **Base Sepolia** (or a local Anvil fork), with the RSC on **Reactive Network testnet**.

---

## License

Private repository. All rights reserved.
