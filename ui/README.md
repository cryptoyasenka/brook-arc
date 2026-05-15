# Brook UI

Frontend for the Brook streaming primitive on Arc. See the [root README](../README.md)
for the protocol, contract, and deployment details.

Stack: Next.js (App Router), wagmi + viem, RainbowKit, Tailwind.

## Develop

```bash
npm install
npm run dev        # http://localhost:3000
```

The contract address, chain, and RPC live in `lib/addresses.ts` and `lib/chain.ts`.

## Build

```bash
npm run build
npm run start
```

## Deploy

Deployed as a Docker image (see `../Dockerfile` and `../railway.json`); the
container runs `next start`. No platform-specific build step is required.
