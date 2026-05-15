'use client';

import { useEffect, useRef } from 'react';
import type { Abi } from 'viem';
import { usePublicClient } from 'wagmi';

// Live event watcher that polls eth_getLogs — NOT viem's watchContractEvent.
//
// Why this exists: viem's watchContractEvent (and wagmi's useWatchContractEvent,
// even with poll:true) creates an eth_newFilter and only falls back to
// eth_getLogs if the filter RPC *throws*. Arc testnet's eth_newFilter does not
// throw — it succeeds but silently drops/re-creates the filter, so logs slip
// through the gap and the fallback never triggers. Net effect on Arc: success
// banners (Canceled / Withdrawn / Claimed / StreamCreated / Approval) never
// appear in Rabby × Arc even though the tx confirmed on-chain.
//
// eth_getLogs IS reliable on Arc (MyStreams scans history with it). This hook
// reproduces that: snapshot the head block on mount, then every intervalMs ask
// for logs in (lastBlock, head] and advance the cursor. No filters, no gaps,
// no historical replay (matches watchContractEvent's "from now on" semantics).

type LooseArgs = Record<string, unknown> | undefined;

type GetContractEvents = (p: {
  address: `0x${string}`;
  abi: Abi;
  eventName: string;
  args?: LooseArgs;
  fromBlock: bigint;
  toBlock: bigint;
}) => Promise<unknown[]>;

export function useLogPoll({
  address,
  abi,
  eventName,
  args,
  enabled = true,
  intervalMs = 4000,
  onLogs,
}: {
  address: `0x${string}`;
  abi: Abi;
  eventName: string;
  args?: LooseArgs;
  enabled?: boolean;
  intervalMs?: number;
  onLogs: (logs: unknown[]) => void;
}) {
  const client = usePublicClient();

  // Keep the latest onLogs without re-subscribing the poll loop. Synced in an
  // effect (not during render) so React's refs lint rule stays satisfied; it
  // runs before the poll effect's first async tick, so reads see the latest.
  const onLogsRef = useRef(onLogs);
  useEffect(() => {
    onLogsRef.current = onLogs;
  }, [onLogs]);

  // Stable dependency key for the args object (identity changes each render;
  // bigints aren't JSON-serializable so stringify them explicitly).
  const argsKey = args
    ? JSON.stringify(args, (_k, v) => (typeof v === 'bigint' ? v.toString() : v))
    : '';

  useEffect(() => {
    if (!enabled || !client) return;
    let cancelled = false;
    let lastBlock: bigint | null = null;
    let timer: ReturnType<typeof setTimeout> | null = null;

    // One controlled cast: viem's getContractEvents is heavily generic over a
    // literal abi/eventName. We pass them dynamically, so widen at the call
    // boundary and keep the rest of the hook fully typed.
    const getEvents = client.getContractEvents as unknown as GetContractEvents;

    const tick = async () => {
      try {
        const head = await client.getBlockNumber();
        if (cancelled) return;
        if (lastBlock === null) {
          lastBlock = head; // first run: start watching from now, no replay
        } else if (head > lastBlock) {
          const logs = await getEvents({
            address,
            abi,
            eventName,
            args,
            fromBlock: lastBlock + 1n,
            toBlock: head,
          });
          if (cancelled) return;
          lastBlock = head;
          if (logs.length > 0) onLogsRef.current(logs);
        }
      } catch {
        // Transient RPC hiccup — cursor unchanged, retry on the next tick.
      } finally {
        if (!cancelled) timer = setTimeout(tick, intervalMs);
      }
    };
    void tick();

    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, address, eventName, argsKey, enabled, intervalMs]);
}
