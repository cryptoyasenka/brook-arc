'use client';

import { useEffect, useRef, useState } from 'react';
import {
  useAccount,
  useReadContract,
  useWaitForTransactionReceipt,
  useWatchContractEvent,
  useWriteContract,
} from 'wagmi';
import { brookAbi } from '@/lib/brookAbi';
import { BROOK_ADDRESS } from '@/lib/addresses';
import { formatDuration, formatUsdc, shortAddr } from '@/lib/format';

// Match CreateStream's suppression window — wagmi error may fire even though the
// tx confirmed on-chain (Rabby × Arc preflight quirk). Show success when an
// on-chain event arrives, ignore the stale error for this many ms after.
const SUCCESS_SUPPRESSION_MS = 90_000;
const CLICK_WINDOW_MS = 5 * 60_000;

type StreamTuple = readonly [
  `0x${string}`, // sender
  `0x${string}`, // recipient
  bigint, // depositAmount (uint128)
  bigint, // withdrawn (uint128)
  bigint, // startTime (uint64)
  bigint, // endTime (uint64)
  boolean, // canceled
];

export function StreamCard({
  streamId,
  onChange,
}: {
  streamId: bigint;
  onChange?: () => void;
}) {
  const { address } = useAccount();
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  const { data: stream, refetch: refetchStream } = useReadContract({
    address: BROOK_ADDRESS,
    abi: brookAbi,
    functionName: 'streams',
    args: [streamId],
    query: { refetchInterval: 5_000 },
  });

  const { data: withdrawable, refetch: refetchWithdrawable } = useReadContract({
    address: BROOK_ADDRESS,
    abi: brookAbi,
    functionName: 'withdrawable',
    args: [streamId],
    query: { refetchInterval: 2_000 },
  });

  const { data: pendingMine, refetch: refetchPending } = useReadContract({
    address: BROOK_ADDRESS,
    abi: brookAbi,
    functionName: 'pendingClaims',
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 3_000 },
  });

  const withdrawTx = useWriteContract();
  const withdrawReceipt = useWaitForTransactionReceipt({ hash: withdrawTx.data });

  const cancelTx = useWriteContract();
  const cancelReceipt = useWaitForTransactionReceipt({ hash: cancelTx.data });

  const claimTx = useWriteContract();
  const claimReceipt = useWaitForTransactionReceipt({ hash: claimTx.data });

  const [withdrewAt, setWithdrewAt] = useState<number | null>(null);
  const [canceledAt, setCanceledAt] = useState<number | null>(null);
  const [claimedAt, setClaimedAt] = useState<number | null>(null);
  const withdrawClickedAt = useRef<number>(0);
  const cancelClickedAt = useRef<number>(0);
  const claimClickedAt = useRef<number>(0);

  const markWithdrew = () => {
    setWithdrewAt(Date.now());
    void refetchStream();
    void refetchWithdrawable();
    onChange?.();
    withdrawTx.reset();
    withdrawClickedAt.current = 0;
  };
  const markCanceled = () => {
    setCanceledAt(Date.now());
    void refetchStream();
    void refetchWithdrawable();
    void refetchPending();
    onChange?.();
    cancelTx.reset();
    cancelClickedAt.current = 0;
  };
  const markClaimed = () => {
    setClaimedAt(Date.now());
    void refetchPending();
    onChange?.();
    claimTx.reset();
    claimClickedAt.current = 0;
  };

  // Dedup helpers: returns true if this click attempt was already handled, so
  // receipt + event don't double-fire while successive clicks remain allowed.
  const withdrawAlreadyHandled = () =>
    withdrewAt !== null && withdrewAt > withdrawClickedAt.current;
  const cancelAlreadyHandled = () =>
    canceledAt !== null && canceledAt > cancelClickedAt.current;
  const claimAlreadyHandled = () =>
    claimedAt !== null && claimedAt > claimClickedAt.current;

  // Receipt path (normal wallets).
  useEffect(() => {
    if (!withdrawReceipt.isSuccess) return;
    if (withdrawAlreadyHandled()) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- bridging wagmi receipt state to local UI state
    markWithdrew();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [withdrawReceipt.isSuccess]);
  useEffect(() => {
    if (!cancelReceipt.isSuccess) return;
    if (cancelAlreadyHandled()) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- bridging wagmi receipt state to local UI state
    markCanceled();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cancelReceipt.isSuccess]);

  // Event path (Rabby × Arc). Scope by streamId — both events index it.
  // poll:true forces eth_getLogs polling. Arc's eth_newFilter /
  // eth_getFilterChanges (viem's default for http) is flaky on testnet —
  // per-card filters get re-created in a storm and logs fall through the
  // gap, so the success banner never shows. Plain getLogs is reliable here
  // (MyStreams scans with it). pollingInterval kept tight for snappy UX.
  useWatchContractEvent({
    address: BROOK_ADDRESS,
    abi: brookAbi,
    eventName: 'Withdrawn',
    args: { streamId },
    poll: true,
    pollingInterval: 4000,
    onLogs: () => {
      if (Date.now() - withdrawClickedAt.current > CLICK_WINDOW_MS) return;
      if (withdrawAlreadyHandled()) return;
      markWithdrew();
    },
  });
  useWatchContractEvent({
    address: BROOK_ADDRESS,
    abi: brookAbi,
    eventName: 'Canceled',
    args: { streamId },
    poll: true,
    pollingInterval: 4000,
    onLogs: () => {
      if (Date.now() - cancelClickedAt.current > CLICK_WINDOW_MS) return;
      if (cancelAlreadyHandled()) return;
      markCanceled();
    },
  });

  useEffect(() => {
    if (!claimReceipt.isSuccess) return;
    if (claimAlreadyHandled()) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- bridging wagmi receipt state to local UI state
    markClaimed();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [claimReceipt.isSuccess]);

  useWatchContractEvent({
    address: BROOK_ADDRESS,
    abi: brookAbi,
    eventName: 'Claimed',
    args: address ? { claimant: address } : undefined,
    enabled: !!address,
    poll: true,
    pollingInterval: 4000,
    onLogs: () => {
      if (Date.now() - claimClickedAt.current > CLICK_WINDOW_MS) return;
      if (claimAlreadyHandled()) return;
      markClaimed();
    },
  });

  // Time-decay success banners.
  useEffect(() => {
    if (withdrewAt === null) return;
    const t = setTimeout(() => setWithdrewAt(null), SUCCESS_SUPPRESSION_MS);
    return () => clearTimeout(t);
  }, [withdrewAt]);
  useEffect(() => {
    if (canceledAt === null) return;
    const t = setTimeout(() => setCanceledAt(null), SUCCESS_SUPPRESSION_MS);
    return () => clearTimeout(t);
  }, [canceledAt]);
  useEffect(() => {
    if (claimedAt === null) return;
    const t = setTimeout(() => setClaimedAt(null), SUCCESS_SUPPRESSION_MS);
    return () => clearTimeout(t);
  }, [claimedAt]);

  const recentWithdrawSuccess = withdrewAt !== null;
  const recentCancelSuccess = canceledAt !== null;
  const recentClaimSuccess = claimedAt !== null;
  const suppressError =
    recentWithdrawSuccess || recentCancelSuccess || recentClaimSuccess;

  if (!stream) {
    return (
      <div className="rounded-xl border border-neutral-800 bg-neutral-900/40 p-4 animate-pulse h-32" />
    );
  }

  const [sender, recipient, total, withdrawn, startTime, stopTime, canceled] =
    stream as StreamTuple;
  const start = Number(startTime);
  const stop = Number(stopTime);
  const duration = stop - start;

  const isSender = address && sender.toLowerCase() === address.toLowerCase();
  const isRecipient = address && recipient.toLowerCase() === address.toLowerCase();

  const elapsed = Math.max(0, Math.min(now, stop) - start);
  const progressFromTime = duration > 0 ? Math.min(1, elapsed / duration) : 1;
  const progressFromWithdrawn = total > 0n ? Number(withdrawn) / Number(total) : 0;

  const isClosed = canceled || withdrawn >= total;
  const counterpartyLabel = isSender ? 'to' : 'from';
  const counterparty = isSender ? recipient : sender;

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/40 p-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="text-xs uppercase tracking-wider text-neutral-500 mb-0.5">
            stream #{streamId.toString()}
            {isClosed && (
              <span className="ml-2 text-[10px] text-neutral-500 normal-case">
                {canceled ? 'cancelled' : 'closed'}
              </span>
            )}
          </div>
          <div className="font-mono text-sm">
            <span className="text-neutral-500">{counterpartyLabel}</span>{' '}
            <a
              href={`https://testnet.arcscan.app/address/${counterparty}`}
              target="_blank"
              rel="noopener noreferrer"
              className="text-neutral-200 hover:text-sky-400"
            >
              {shortAddr(counterparty)}
            </a>
          </div>
        </div>
        <div className="text-right">
          <div className="text-xs text-neutral-500">{formatDuration(duration)}</div>
          <div className="text-base font-semibold">{formatUsdc(total, 2)} USDC</div>
        </div>
      </div>

      <div>
        <div className="h-2 rounded-full bg-neutral-800 overflow-hidden">
          <div
            className="h-full bg-gradient-to-r from-sky-500 to-cyan-400 transition-[width]"
            style={{ width: `${(progressFromTime * 100).toFixed(2)}%` }}
          />
          <div
            className="h-full -translate-y-2 bg-emerald-500/40 transition-[width]"
            style={{ width: `${(progressFromWithdrawn * 100).toFixed(2)}%` }}
          />
        </div>
        <div className="flex justify-between mt-1.5 text-[11px] text-neutral-500 font-mono">
          <span>withdrawn {formatUsdc(withdrawn, 4)}</span>
          <span>
            available {formatUsdc(withdrawable ?? 0n, 4)}
          </span>
          <span>
            {isClosed
              ? 'done'
              : now < start
                ? `starts in ${formatDuration(start - now)}`
                : now >= stop
                  ? 'ended'
                  : `${formatDuration(stop - now)} left`}
          </span>
        </div>
      </div>

      <div className="flex gap-2 pt-1">
        {isRecipient && !isClosed && (
          <button
            onClick={() => {
              withdrawClickedAt.current = Date.now();
              withdrawTx.writeContract({
                address: BROOK_ADDRESS,
                abi: brookAbi,
                functionName: 'withdraw',
                args: [streamId, recipient, withdrawable ?? 0n],
              });
            }}
            disabled={
              !withdrawable || withdrawable === 0n || withdrawTx.isPending || withdrawReceipt.isLoading
            }
            className="flex-1 py-2 rounded-md bg-emerald-500 text-neutral-950 font-medium text-sm hover:bg-emerald-400 disabled:opacity-40 disabled:cursor-not-allowed transition"
          >
            {withdrawTx.isPending
              ? 'sign…'
              : withdrawReceipt.isLoading
                ? 'withdrawing…'
                : `withdraw ${formatUsdc(withdrawable ?? 0n, 2)}`}
          </button>
        )}
        {isSender && !isClosed && (
          <button
            onClick={() => {
              cancelClickedAt.current = Date.now();
              cancelTx.writeContract({
                address: BROOK_ADDRESS,
                abi: brookAbi,
                functionName: 'cancel',
                args: [streamId],
              });
            }}
            disabled={cancelTx.isPending || cancelReceipt.isLoading}
            className="flex-1 py-2 rounded-md border border-red-500/50 text-red-400 font-medium text-sm hover:bg-red-500/10 disabled:opacity-40 disabled:cursor-not-allowed transition"
          >
            {cancelTx.isPending
              ? 'sign…'
              : cancelReceipt.isLoading
                ? 'cancelling…'
                : 'cancel'}
          </button>
        )}
      </div>

      {pendingMine !== undefined && pendingMine > 0n && (
        <div className="flex items-center justify-between rounded-md border border-emerald-500/30 bg-emerald-500/5 px-3 py-2">
          <div className="text-xs">
            <span className="text-neutral-400">your claimable balance:</span>{' '}
            <span className="font-mono text-emerald-300">
              {formatUsdc(pendingMine, 4)} USDC
            </span>
          </div>
          <button
            onClick={() => {
              if (!address) return;
              claimClickedAt.current = Date.now();
              claimTx.writeContract({
                address: BROOK_ADDRESS,
                abi: brookAbi,
                functionName: 'claim',
                args: [address, pendingMine],
              });
            }}
            disabled={claimTx.isPending || claimReceipt.isLoading}
            className="px-3 py-1.5 rounded-md bg-emerald-500 text-neutral-950 font-medium text-xs hover:bg-emerald-400 disabled:opacity-40 disabled:cursor-not-allowed transition"
          >
            {claimTx.isPending
              ? 'sign…'
              : claimReceipt.isLoading
                ? 'claiming…'
                : 'claim'}
          </button>
        </div>
      )}

      {!suppressError && (withdrawTx.error || cancelTx.error || claimTx.error) && (
        <div className="text-xs text-red-400 break-words">
          {withdrawTx.error?.message ?? cancelTx.error?.message ?? claimTx.error?.message}
        </div>
      )}
      {recentWithdrawSuccess && (
        <div className="text-xs text-emerald-400">withdraw confirmed</div>
      )}
      {recentCancelSuccess && (
        <div className="text-xs text-emerald-400">
          stream canceled — claim your balance below
        </div>
      )}
      {recentClaimSuccess && (
        <div className="text-xs text-emerald-400">claim confirmed</div>
      )}
    </div>
  );
}
