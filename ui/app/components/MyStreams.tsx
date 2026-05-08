'use client';

import { useCallback, useEffect, useState } from 'react';
import { useAccount, usePublicClient } from 'wagmi';
import { brookAbi } from '@/lib/brookAbi';
import { BROOK_ADDRESS, BROOK_DEPLOY_BLOCK } from '@/lib/addresses';
import { StreamCard } from './StreamCard';

type Tab = 'all' | 'sent' | 'received';

// Arc RPC caps eth_getLogs at 10_000 blocks per request. Scan in chunks.
const LOG_CHUNK = 9_000n;

type CreatedLog = { args: { streamId?: bigint } };

export function MyStreams({ refreshKey = 0 }: { refreshKey?: number }) {
  const { address, isConnected } = useAccount();
  const client = usePublicClient();

  const [streamIds, setStreamIds] = useState<bigint[]>([]);
  const [senderIdSet, setSenderIdSet] = useState<Set<string>>(() => new Set());
  const [recipientIdSet, setRecipientIdSet] = useState<Set<string>>(() => new Set());
  const [tab, setTab] = useState<Tab>('all');
  const [loading, setLoading] = useState(false);
  const [, setBump] = useState(0);
  const bumpStreams = useCallback(() => setBump((n) => n + 1), []);

  useEffect(() => {
    if (!client || !address) return;
    let cancelled = false;
    const scan = async (
      filterArgs: { sender?: `0x${string}`; recipient?: `0x${string}` },
      fromBlock: bigint,
      toBlock: bigint,
    ) => {
      const out: CreatedLog[] = [];
      let start = fromBlock;
      while (start <= toBlock) {
        const end = start + LOG_CHUNK - 1n > toBlock ? toBlock : start + LOG_CHUNK - 1n;
        const logs = await client.getContractEvents({
          address: BROOK_ADDRESS,
          abi: brookAbi,
          eventName: 'StreamCreated',
          args: filterArgs,
          fromBlock: start,
          toBlock: end,
        });
        out.push(...(logs as unknown as CreatedLog[]));
        start = end + 1n;
      }
      return out;
    };

    (async () => {
      setLoading(true);
      try {
        const head = await client.getBlockNumber();
        const [asSender, asRecipient] = await Promise.all([
          scan({ sender: address }, BROOK_DEPLOY_BLOCK, head),
          scan({ recipient: address }, BROOK_DEPLOY_BLOCK, head),
        ]);
        if (cancelled) return;
        const ids = new Set<bigint>();
        const senders = new Set<string>();
        const recipients = new Set<string>();
        for (const log of asSender) {
          const id = log.args.streamId;
          if (id !== undefined) {
            ids.add(id);
            senders.add(id.toString());
          }
        }
        for (const log of asRecipient) {
          const id = log.args.streamId;
          if (id !== undefined) {
            ids.add(id);
            recipients.add(id.toString());
          }
        }
        setStreamIds([...ids].sort((a, b) => (a > b ? -1 : a < b ? 1 : 0)));
        setSenderIdSet(senders);
        setRecipientIdSet(recipients);
      } catch (e) {
        console.error('getContractEvents failed', e);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [client, address, refreshKey]);

  const filtered = !address
    ? []
    : streamIds.filter((id) => {
        if (tab === 'sent') return senderIdSet.has(id.toString());
        if (tab === 'received') return recipientIdSet.has(id.toString());
        return true;
      });

  if (!isConnected) {
    return (
      <section className="rounded-2xl border border-neutral-800 bg-neutral-900/40 p-6">
        <h2 className="text-lg font-semibold mb-2">My streams</h2>
        <p className="text-sm text-neutral-400">connect a wallet to view your streams.</p>
      </section>
    );
  }

  return (
    <section className="rounded-2xl border border-neutral-800 bg-neutral-900/40 p-6">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-lg font-semibold">My streams</h2>
        <div className="flex gap-1 text-xs">
          {(['all', 'sent', 'received'] as Tab[]).map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={`px-2.5 py-1 rounded-md transition ${
                tab === t
                  ? 'bg-neutral-700/60 text-neutral-100'
                  : 'text-neutral-500 hover:text-neutral-300'
              }`}
            >
              {t}
            </button>
          ))}
        </div>
      </div>

      {loading ? (
        <div className="text-sm text-neutral-500">loading streams…</div>
      ) : filtered.length === 0 ? (
        <div className="text-sm text-neutral-500">
          {tab === 'all'
            ? 'no streams yet — create one above'
            : `no ${tab} streams`}
        </div>
      ) : (
        <div className="space-y-3">
          {filtered.map((id) => (
            <StreamCard key={id.toString()} streamId={id} onChange={bumpStreams} />
          ))}
        </div>
      )}
    </section>
  );
}
