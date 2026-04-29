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
implementations. Brook is the smallest correct primitive: one contract, ~170 lines,
no governance, no upgrade path, no fee, no admin keys.

## Design at a glance

| | |
|---|---|
| Token | USDC fixed at construction time, immutable |
| Stream model | Linear, per-second, deposit divided uniformly |
| Dust strategy | End-flush — `withdrawable()` returns whatever's left after `endTime` |
| Cancel | Pays both parties immediately, splits according to elapsed time |
| Permit | `createStreamWithPermit` accepts an EIP-2612 signature so users skip the approve tx |
| Reentrancy | OZ `nonReentrant` on every state-mutating path |
| Fee-on-transfer | Rejected at create time via balance-delta check |
| Storage | One slot per stream (`address` + `address` + 2× `uint128` + 2× `uint64` + `bool`) |

Full design rationale: [`../planning/CONTRACT-DESIGN-AUDIT.md`](../planning/CONTRACT-DESIGN-AUDIT.md).

## Repository layout

```
src/BrookStream.sol           main contract
test/BrookStream.t.sol        T1-T16 + 4 fuzz invariants (256 runs each)
test/BrookStream.fork.t.sol   T17 fork test against real Arc USDC (gated)
test/mocks/                   ERC20 / fee-on-transfer / reentrant mocks
script/DeployBrookStream.s.sol  deploy + write deployments/<chainId>.json
script/SmokeTest.s.sol        post-deploy smoke (create / withdraw / cancel)
deployments/                  per-chain deployment manifests
```

## Build & test

```bash
forge install
forge build
forge test                                     # 31 unit + fuzz, ~25ms
forge coverage --report summary                # 100/100/100 on BrookStream.sol
ARC_FORK=1 forge test --match-contract Fork    # T17 against live Arc testnet
```

Static analysis (Slither): `slither .` — 0 medium+ findings.

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

// Sender stops the stream; recipient gets accrued, sender gets remainder, both paid now.
function cancel(uint256 streamId) external;
```

Events: `StreamCreated`, `Withdrawn`, `Canceled`. Custom errors only — no revert strings.

## Security notes

- **Unaudited.** Suitable for hackathon demos and testnet integrations, not production
  custody. Read the contract end-to-end before composing on top.
- **block.timestamp.** Used to compute elapsed time. Validators can nudge timestamps a
  few seconds either way; this is acceptable for a per-second linear stream because the
  stored value is the withdrawn amount, not a cached time. Forge lints flag this — see
  [`../planning/CONTRACT-DESIGN-AUDIT.md` §A7](../planning/CONTRACT-DESIGN-AUDIT.md#a7-blocktimestamp-равенство-соседних-блоков-arc-specific).
- **uint64 endTime.** `startTime + duration` reverts on uint64 overflow (Solidity 0.8
  checked math). Tested: see `test_T14_EndTimeOverflow_Reverts`.
- **Fee-on-transfer.** Rejected at create. USDC isn't fee-on-transfer; the check is a
  defense in depth in case a future ERC20 with fee-on-transfer is wired up.

## License

MIT. See [LICENSE](LICENSE).
