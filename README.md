# VaultCurator

> **A hook-native ERC-4626 vault for curated Uniswap v4 LP strategies — with on-chain performance fees, token-gated deposits, and oracle-triggered rebalancing.**

[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C?style=flat-square)](https://book.getfoundry.sh/)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?style=flat-square)](https://soliditylang.org/)
[![Uniswap v4](https://img.shields.io/badge/Uniswap-v4-FF007A?style=flat-square)](https://uniswap.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](./LICENSE)
[![UHI11](https://img.shields.io/badge/UHI-Cohort%2011-6E56CF?style=flat-square)](https://uniswap.org/)

---

## 📖 Overview

Most retail LPs deposit into a Uniswap pool, set a range, and forget — leaving meaningful yield on the table. Off-chain, professional asset managers run sophisticated strategies (rebalancing, hedging, signal-driven repositioning) that on-chain LPs have no clean way to access.

**VaultCurator** bridges that gap. It is a hook-native vault primitive that lets professional managers:

- Run **whitelisted, curated LP strategies** on Uniswap v4
- Charge **on-chain performance fees** on the yield they generate
- Enforce **token-gated access** for professional-only pools
- **Auto-rebalance** positions via oracle triggers
- Allow depositors to **migrate** between strategies in one transaction

It turns retail LPs into followers of curated, professionally-managed strategies — natively on-chain.

---

## 🎯 UHI11 Build Theme: Curated Liquidity

VaultCurator directly addresses the UHI11 theme by covering **every** listed example:

| Theme Example | VaultCurator Feature |
|---|---|
| Vault-managed or token-gated hook modules | `CuratedVault.sol` + `AllowlistChecker.sol` |
| Curated LP networks (depositors follow managers) | `StrategyRegistry.sol` |
| Hooks that auto-rebalance via oracle triggers | `CuratedLiquidityHook.sol` |
| Performance fees | High-water mark fee module |
| Strategy migration between pools | `StrategyRegistry.migrate()` |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        StrategyRegistry                         │
│  - Manager registration    - Strategy metadata (IPFS + on-chain) │
│  - Migration routing       - Performance history                 │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                        CuratedVault (ERC-4626)                   │
│  - deposit() / withdraw()     - High-water mark tracking         │
│  - Performance fee accrual    - Management fee accrual           │
│  - Fee shares to manager      - Deposit cap enforcement          │
└────────────────────────┬────────────────────────────────────────┘
                         │ owns / manages
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                   CuratedLiquidityHook (BaseHook)                │
│  - beforeSwap: dynamic fees    - afterSwap: volume tracking      │
│  - beforeAddLiquidity: gating  - rebalance(): oracle-triggered   │
│  - Owns Uniswap v4 LP position - Oracle deviation checks         │
└─────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    AllowlistChecker (IAllowlistChecker)          │
│  - checkAllowlist(account, token) → bool                         │
│  - Pluggable: allowlist / NFT-gated / token-gated                │
└─────────────────────────────────────────────────────────────────┘
```

---

## ✨ Features

### Core

- **ERC-4626 Vault** — Standard-compliant vault with virtual shares/assets inflation defense (`_decimalsOffset() = 6`)
- **High-Water Mark Performance Fees** — Per-share price ratchets up only; recovery from drawdown pays no perf fee
- **Management Fees** — Linear in time and AUM, hard-capped at 5% annual
- **Fee Change Rate Limits** — Capped at 1% per step with 7-day cooldown
- **Fee Shares to Manager** — No admin path to principal; fees are dilution-only

### Hook

- **Dynamic Swap Fees** — Volatility- and volume-based fees protect LPs from arbitrage MEV
- **Oracle Deviation Checks** — Every swap validates price against a reference oracle
- **Oracle-Triggered Rebalance** — Keeper calls `rebalance()` when deviation exceeds threshold
- **Token-Gated Deposits** — Allowlist, NFT-gated, or token-gated modes

### Registry

- **Manager Registry** — On-chain strategy metadata (APY, Sharpe, max drawdown, IPFS URI)
- **Single-Tx Migration** — Move capital between vaults with automatic fee settlement
- **Strategy Discovery** — `getActiveStrategies()` for frontends

---

## 📜 Deployed Contracts

### Testnet (Base Sepolia)

| Contract | Address | Explorer |
|---|---|---|
| `CuratedVault` | `0x...` | [View](https://sepolia.basescan.org/address/0x...) |
| `CuratedLiquidityHook` | `0x...` | [View](https://sepolia.basescan.org/address/0x...) |
| `StrategyRegistry` | `0x...` | [View](https://sepolia.basescan.org/address/0x...) |
| `AllowlistChecker` | `0x...` | [View](https://sepolia.basescan.org/address/0x...) |

### Uniswap v4 Pool

| Parameter | Value |
|---|---|
| Pool ID | `0x...` |
| Currency0 | `0x...` (USDC) |
| Currency1 | `0x...` (WETH) |
| Fee | Dynamic (base 500 → max 3000) |
| Tick Spacing | 60 |
| Hook | `0x...` |

> ⚠️ These contracts are unaudited and deployed on testnet only. Do not use with real funds.

---

## 🚀 Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Git](https://git-scm.com/)
- Node.js ≥ 18 (for frontend, optional)

### Installation

```bash
git clone https://github.com/<your-org>/vault-curator.git
cd vault-curator
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test
forge test --gas-report
forge test --fuzz-runs 10000
```

### Invariant Tests

```bash
forge test --match-path "test/invariants/*"
```

---

## 🧪 Testing

| Suite | Command | Coverage |
|---|---|---|
| Unit | `forge test --match-path "test/unit/*"` | Per-function behavior |
| Fuzz | `forge test --fuzz-runs 10000` | Deposit/withdraw edge cases |
| Invariant | `forge test --match-path "test/invariants/*"` | Solvency, HWM monotonicity |
| Fork | `forge test --fork-url $BASE_SEPOLIA_RPC` | Live PoolManager integration |

### Invariants

- `totalAssets() >= sum of all depositor values`
- `highWaterMark` only increases
- `feeRecipient` shares never exceed `perfFeeBps` of profit
- Vault never holds less than `totalAssets()` in liquid assets

---

## 🔧 Usage

### 1. Deploy a Vault

```solidity
CuratedVault vault = new CuratedVault(
    IERC20(USDC),
    "Alpha LP Vault",
    "aLP",
    owner,
    feeRecipient,
    100,   // 1% management fee
    1500   // 15% performance fee
);
```

### 2. Configure the Hook

```solidity
hook.setAllowlistChecker(address(checker));
hook.setGatingEnabled(true);
hook.setDynamicFee(500, 3000);       // base 0.05%, max 0.30%
hook.setMaxDeviation(200);           // 2%
hook.setRebalanceCooldown(1 hours);
```

### 3. Deposit (Token-Gated)

```solidity
checker.setAllowlist(alice, true);
vm.prank(alice);
vault.deposit(1000e6, alice);        // 1000 USDC
```

### 4. Trigger a Rebalance

```solidity
hook.rebalance(poolKey);              // reverts if deviation < threshold
```

### 5. Harvest Fees

```solidity
vault.harvest();                      // mints fee shares to feeRecipient
```

### 6. Migrate Between Vaults

```solidity
registry.migrate(address(vaultA), address(vaultB), amount);
```

---

## 🔐 Security

### Design Principles

- **No admin path to principal** — fees are share dilution only
- **Rate-limited fee changes** — 1% per step, 7-day cooldown
- **Immutability where it matters** — safety-critical checks are immutable
- **Oracle dual-sourcing** — Chainlink + Pyth with deviation fallback
- **MEV-resistant rebalance** — submitted via Flashbots Protect

### Known Limitations

- ⚠️ Contracts are **unaudited** — do not use with real funds
- ⚠️ Oracle integration uses a placeholder in the current testnet build
- ⚠️ Rebalance logic is stubbed; production implementation pending

### Audit Status

| Audit | Firm | Status |
|---|---|---|
| Self-directed security framework | Uniswap Foundation | ✅ Completed |
| External audit | TBD | ⏳ Planned |

### Bug Bounty

Coming post-audit. Until then, please report issues privately to `security@vaultcurator.xyz`.

---

## 🗺️ Roadmap

- [x] ERC-4626 vault with HWM + management fees
- [x] Hook with dynamic fees + token gating
- [x] Strategy registry + migration
- [x] Testnet deployment (Base Sepolia)
- [ ] Production oracle integration (Chainlink + Pyth)
- [ ] Live rebalance implementation
- [ ] Frontend dashboard (Vite + React)
- [ ] External audit
- [ ] Mainnet deployment

---

## 🤝 Integration Pathways

VaultCurator is designed to compose with existing DeFi asset management infrastructure.

| Protocol | Integration Angle |
|---|---|
| **Arrakis** | Dynamic fee engine + VaultCurator manager layer |
| **Sommelier** | On-chain execution layer for Cellars |
| **Gauntlet** | Risk parameterization + audit |

If you're building in this space and want to integrate, open an issue or reach out.

---

## 📚 Resources

- [Uniswap v4 Docs](https://docs.uniswap.org/contracts/v4/overview)
- [Uniswap v4 Hook Security Framework](https://uniswap.org/)
- [OpenZeppelin ERC-4626](https://docs.openzeppelin.com/contracts/5.x/erc4626)
- [Foundry Book](https://book.getfoundry.sh/)
- [v4-template (Saucepoint)](https://github.com/saucepoint/v4-template)
- [yield-vault (dngr2)](https://github.com/dngr2/yield-vault)

---

## 🧑‍💻 Team

| Role | Name | Contact |
|---|---|---|
| Solidity Engineer | `<your name>` | `@handle` |
| Full-Stack | `<name>` | `@handle` |
| Strategy / Quant | `<name>` | `@handle` |

---

## 📄 License

MIT © 2026 VaultCurator Contributors

---

## 🙏 Acknowledgments

Built during **Uniswap Hook Incubator Cohort 11 (UHI11)**. Thanks to the Uniswap Foundation, Atrium Academy, and the UHI mentors for their guidance and support.

---

### 📌 Repo Topics

Add these GitHub topics for discoverability:

```
uniswap-v4  hooks  erc-4626  defi  liquidity-management
curated-liquidity  uhi11  foundry  solidity  vault
```