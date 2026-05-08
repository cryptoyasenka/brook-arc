'use client';

import { useEffect, useState } from 'react';
import { isAddress, maxUint256 } from 'viem';
import {
  useAccount,
  useReadContract,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { brookAbi } from '@/lib/brookAbi';
import { usdcAbi } from '@/lib/usdcAbi';
import { BROOK_ADDRESS, USDC_ADDRESS } from '@/lib/addresses';
import { formatUsdc, parseUsdc } from '@/lib/format';

const DURATION_PRESETS: { label: string; seconds: number }[] = [
  { label: '2 min', seconds: 120 },
  { label: '1 hour', seconds: 3600 },
  { label: '1 day', seconds: 86400 },
  { label: '1 week', seconds: 604800 },
];

export function CreateStream({ onCreated }: { onCreated?: () => void }) {
  const { address, isConnected } = useAccount();

  const [recipient, setRecipient] = useState('');
  const [amountStr, setAmountStr] = useState('');
  const [durationSec, setDurationSec] = useState<number>(120);
  const [error, setError] = useState<string | null>(null);

  const parsed = (() => {
    if (!amountStr) return null;
    try {
      return parseUsdc(amountStr);
    } catch {
      return null;
    }
  })();

  const recipientValid = isAddress(recipient);
  const isSelfRecipient =
    recipientValid && address && recipient.toLowerCase() === address.toLowerCase();
  const amountValid = parsed !== null && parsed > 0n;
  const durationValid = durationSec > 0;
  const formValid = recipientValid && !isSelfRecipient && amountValid && durationValid;

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: USDC_ADDRESS,
    abi: usdcAbi,
    functionName: 'allowance',
    args: address ? [address, BROOK_ADDRESS] : undefined,
    query: { enabled: !!address },
  });

  const { data: balance } = useReadContract({
    address: USDC_ADDRESS,
    abi: usdcAbi,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  const needsApprove = parsed !== null && (allowance ?? 0n) < parsed;
  const insufficientBalance = parsed !== null && (balance ?? 0n) < parsed;

  const approve = useWriteContract();
  const approveReceipt = useWaitForTransactionReceipt({ hash: approve.data });

  const create = useWriteContract();
  const createReceipt = useWaitForTransactionReceipt({ hash: create.data });

  useEffect(() => {
    if (approveReceipt.isSuccess) {
      void refetchAllowance();
    }
  }, [approveReceipt.isSuccess, refetchAllowance]);

  const onApprove = () => {
    setError(null);
    approve.writeContract({
      address: USDC_ADDRESS,
      abi: usdcAbi,
      functionName: 'approve',
      args: [BROOK_ADDRESS, maxUint256],
    });
  };

  const onCreate = () => {
    setError(null);
    if (!formValid || parsed === null) {
      setError('fill all fields');
      return;
    }
    create.writeContract({
      address: BROOK_ADDRESS,
      abi: brookAbi,
      functionName: 'createStream',
      args: [recipient as `0x${string}`, parsed, BigInt(durationSec)],
    });
  };

  useEffect(() => {
    if (!createReceipt.isSuccess) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reset form when on-chain tx confirms; wagmi v2 only surfaces this as derived state
    setRecipient('');
    setAmountStr('');
    onCreated?.();
    create.reset();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [createReceipt.isSuccess]);

  return (
    <section className="rounded-2xl border border-neutral-800 bg-neutral-900/40 p-6">
      <h2 className="text-lg font-semibold mb-4">Create stream</h2>

      <div className="space-y-4">
        <Field
          label="Recipient"
          hint={
            recipient && !recipientValid
              ? 'invalid address'
              : isSelfRecipient
                ? 'cannot stream to yourself'
                : undefined
          }
        >
          <input
            type="text"
            placeholder="0x…"
            value={recipient}
            onChange={(e) => setRecipient(e.target.value)}
            className="w-full rounded-md bg-neutral-800/60 border border-neutral-700 px-3 py-2 font-mono text-sm focus:outline-none focus:ring-2 focus:ring-sky-500/50"
          />
        </Field>

        <Field
          label="Amount (USDC)"
          hint={
            amountStr && !amountValid
              ? 'invalid amount'
              : insufficientBalance
                ? `balance: ${formatUsdc(balance ?? 0n)}`
                : balance !== undefined
                  ? `balance: ${formatUsdc(balance)}`
                  : undefined
          }
        >
          <input
            type="text"
            inputMode="decimal"
            placeholder="0.10"
            value={amountStr}
            onChange={(e) => setAmountStr(e.target.value)}
            className="w-full rounded-md bg-neutral-800/60 border border-neutral-700 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-sky-500/50"
          />
        </Field>

        <Field label="Duration">
          <div className="flex flex-wrap gap-2">
            {DURATION_PRESETS.map((p) => (
              <button
                key={p.seconds}
                type="button"
                onClick={() => setDurationSec(p.seconds)}
                className={`px-3 py-1.5 rounded-md text-xs border transition ${
                  durationSec === p.seconds
                    ? 'border-sky-500 bg-sky-500/10 text-sky-300'
                    : 'border-neutral-700 hover:border-neutral-500 text-neutral-300'
                }`}
              >
                {p.label}
              </button>
            ))}
            <input
              type="number"
              min={1}
              value={durationSec}
              onChange={(e) => setDurationSec(Math.max(1, parseInt(e.target.value || '0', 10)))}
              className="w-24 rounded-md bg-neutral-800/60 border border-neutral-700 px-3 py-1.5 text-xs"
            />
            <span className="text-xs text-neutral-500 self-center">seconds</span>
          </div>
        </Field>

        {!isConnected ? (
          <div className="text-sm text-neutral-400">connect a wallet to continue</div>
        ) : needsApprove ? (
          <button
            onClick={onApprove}
            disabled={!amountValid || approve.isPending || approveReceipt.isLoading}
            className="w-full py-2.5 rounded-md bg-amber-500 text-neutral-950 font-medium text-sm hover:bg-amber-400 disabled:opacity-40 disabled:cursor-not-allowed transition"
          >
            {approve.isPending
              ? 'sign in wallet…'
              : approveReceipt.isLoading
                ? 'approving…'
                : '1 / 2 — approve USDC'}
          </button>
        ) : (
          <button
            onClick={onCreate}
            disabled={!formValid || insufficientBalance || create.isPending || createReceipt.isLoading}
            className="w-full py-2.5 rounded-md bg-sky-500 text-neutral-950 font-medium text-sm hover:bg-sky-400 disabled:opacity-40 disabled:cursor-not-allowed transition"
          >
            {create.isPending
              ? 'sign in wallet…'
              : createReceipt.isLoading
                ? 'creating…'
                : 'create stream'}
          </button>
        )}

        {(approve.error || create.error || error) && (
          <div className="text-xs text-red-400 break-words">
            {error ?? approve.error?.message ?? create.error?.message}
          </div>
        )}
      </div>
    </section>
  );
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <label className="block">
      <div className="flex items-center justify-between mb-1.5">
        <span className="text-xs uppercase tracking-wider text-neutral-500">{label}</span>
        {hint && <span className="text-xs text-neutral-500">{hint}</span>}
      </div>
      {children}
    </label>
  );
}
