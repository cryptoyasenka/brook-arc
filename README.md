# Brook

USDC streaming primitive for [Arc](https://www.arc.network) — Circle's stablecoin L1.

Send a fixed amount of USDC to a recipient that unlocks linearly per second over a chosen
duration. Recipient withdraws any time. Sender can cancel mid-stream and both parties are
paid out immediately according to elapsed time.

> **Status:** unaudited, testnet only. MIT licensed primitive intended for composition,
> not direct production use.

## Why

Existing streaming protocols (Sablier, Superfluid, LlamaPay) don't deploy on Arc, and Arc's
USDC-as-gas model + EIP-2612 permit support enables a tighter UX than copying their
implementations. Brook is the smallest correct primitive: one contract, ~210 lines,
no governance, no upgrade path, no fee, no admin keys.

## Brook's place in Circle's stack

Circle launched the [Agent Stack](https://www.circle.com/blog/introducing-circle-agent-stack-financial-infrastructure-for-the-agentic-economy)
on 2026-05-11 and has been shipping the agentic-payments rails for several months:

| Layer | Purpose | Time model |
|---|---|---|
| [x402](https://x402.org) | HTTP 402 payment negotiation | one-shot, discrete |
| [Nanopayments](https://developers.circle.com/gateway/nanopayments) | Offchain auth + batched USDC settlement, down to $0.000001 | discrete, batched |
| [Circle Gateway](https://developers.circle.com/gateway) | The settlement layer beneath Nanopayments | discrete, batched |
| [Agent Wallets / Marketplace / CLI](https://agents.circle.com) | Policy-controlled holding + service discovery for agents | discrete |
| **Brook** | **Continuous per-second USDC release between two addresses** | **time-based, continuous** |

Nanopayments handles "agent pays $0.001 per API call" — many discrete events batched
offchain. Brook handles "agent rents compute for 24 h at 0.05 USDC/min" — one onchain
authorization that releases linearly over time. Both can live on the same Agent Wallet;
they cover orthogonal economic models.

Brook does not depend on Agent Stack and works for human ↔ human flows too
(rent, salary, vesting, subscriptions). It's deliberately scope-limited to the
streaming primitive so the contract stays auditable.

## Design at a glance

| | |
|---|---|
| Token | USDC fixed at construction time, immutable |
| Stream model | Linear, per-second, deposit divided uniformly |
| Dust strategy | End-flush — `withdrawable()` returns whatever's left after `endTime` |
| Cancel | Pull-pattern: credits both parties' shares to `pendingClaims`, each pulls via `claim()` (DoS-proof against USDC blacklist on either side) |
| Permit | `createStreamWithPermit` accepts an EIP-2612 signature so users skip the approve tx; try/catch wrapper survives mempool frontrun grief |
| Reentrancy | OZ `nonReentrant` on every state-mutating path |
| Fee-on-transfer | Rejected at create time via balance-delta check |
| Storage | One slot per stream (`address` + `address` + 2× `uint128` + 2× `uint64` + `bool`) |

The contract is ~210 lines of Solidity 0.8.26; reading it end-to-end is the
authoritative spec.

## Repository layout

```
src/BrookStream.sol           main contract
test/BrookStream.t.sol        T1-T16 + DoS/claim/permit tests + 4 fuzz invariants
test/BrookStream.fork.t.sol   T17 fork test against real Arc USDC (gated)
test/mocks/                   ERC20 / fee-on-transfer / reentrant / blacklist mocks
script/DeployBrookStream.s.sol  deploy + write deployments/<chainId>.json
script/SmokeTest.s.sol        post-deploy smoke (create / withdraw / cancel / claim)
deployments/                  per-chain deployment manifests
```

## Build & test

```bash
forge install
forge build
forge test                                     # 41 unit + fuzz, ~40ms
forge coverage --report summary                # 100/100/100/100 on BrookStream.sol
ARC_FORK=1 forge test --match-contract Fork    # T17 against live Arc testnet
```

Static analysis (Slither): `slither .` — 0 medium+ findings.

## Web UI

**Live demo:** https://brook-arc-ui-production.up.railway.app (Railway, instant load).

A Next.js + viem + wagmi + RainbowKit app lives in [`ui/`](./ui). It connects to the
deployed contract on Arc testnet and lets you create, view, withdraw and cancel streams.

```bash
cd ui && npm install && npm run dev   # http://localhost:3000
```

One-click deploy of your own:

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/new/template?template=https://github.com/cryptoyasenka/brook-arc)

## Deploy

```bash
cp .env.example .env
# fill DEPLOYER_PRIVATE_KEY (deployer must hold Arc USDC for gas)

forge script script/DeployBrookStream.s.sol \
    --rpc-url arc_testnet \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --broadcast --verify
```

Address lands in `deployments/5042002.json`. Verify on
[testnet.arcscan.app](https://testnet.arcscan.app).

Smoke-test:

```bash
SMOKE_MODE=create SMOKE_RECIPIENT=0x... \
    forge script script/SmokeTest.s.sol --rpc-url arc_testnet \
    --private-key $DEPLOYER_PRIVATE_KEY --broadcast
# wait the duration, then:
SMOKE_STREAM_ID=0 SMOKE_MODE=withdraw \
    forge script script/SmokeTest.s.sol --rpc-url arc_testnet \
    --private-key $RECIPIENT_PRIVATE_KEY --broadcast
```

## Contract API

```solidity
// Pull `amount` USDC from caller, lock it for `recipient` over `duration` seconds.
function createStream(address recipient, uint128 amount, uint64 duration)
    external returns (uint256 streamId);

// Same, but pulls USDC via an EIP-2612 permit signature in the same tx.
function createStreamWithPermit(
    address recipient, uint128 amount, uint64 duration,
    uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s
) external returns (uint256 streamId);

// View: micro-USDC currently withdrawable by the recipient. 0 if canceled or unknown.
function withdrawable(uint256 streamId) external view returns (uint128);

// Recipient pulls up to `available` micro-USDC to `to`.
function withdraw(uint256 streamId, address to, uint128 amount) external;

// Sender stops the stream. No tokens move here — both parties' shares are credited to
// pendingClaims and each pulls via claim() below. DoS-proof against USDC blacklist.
function cancel(uint256 streamId) external;

// Pull `amount` from caller's pending balance to `to`. Pending balance accumulates
// from cancel() credits across all streams the caller participated in.
function claim(address to, uint128 amount) external;

// View: caller's pending balance (cancelled-stream credits, claimable any time).
function pendingClaims(address account) external view returns (uint128);
```

Events: `StreamCreated`, `Withdrawn`, `Canceled`, `Claimed`. Custom errors only — no revert strings.

## Security notes

- **Unaudited.** Suitable for hackathon demos and testnet integrations, not production
  custody. Read the contract end-to-end before composing on top.
- **Pull-pattern cancel.** `cancel()` moves no tokens — it credits both parties to
  `pendingClaims` and each pulls via `claim()`. A USDC blacklist on either party cannot
  block the other's refund or accrued payout. Headline DoS test: `test_Cancel_BlacklistedRecipient_DoesNotBlockSender`.
- **Permit frontrun resistance.** `createStreamWithPermit` wraps the permit call in
  `try/catch`. If an attacker copies `(v,r,s)` from mempool and submits permit() to
  USDC first, our permit call reverts on the consumed nonce — but the allowance is in
  place, so we still proceed. Only reverts when permit failed AND allowance is short.
- **block.timestamp.** Used to compute elapsed time. Validators can nudge timestamps a
  few seconds either way; this is acceptable for a per-second linear stream because the
  stored value is the withdrawn amount, not a cached time. Slither/Forge lints flag this
  pattern — reviewed and accepted.
- **uint64 endTime.** `startTime + duration` reverts on uint64 overflow (Solidity 0.8
  checked math). Tested: see `test_T14_EndTimeOverflow_Reverts`.
- **Fee-on-transfer.** Rejected at create. USDC isn't fee-on-transfer; the check is a
  defense in depth in case a future ERC20 with fee-on-transfer is wired up.

## License

MIT. See [LICENSE](LICENSE).
