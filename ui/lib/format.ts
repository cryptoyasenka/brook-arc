import { formatUnits, parseUnits } from 'viem';

export function formatUsdc(amount: bigint, fractionDigits = 4): string {
  const s = formatUnits(amount, 6);
  const [whole, frac = ''] = s.split('.');
  if (fractionDigits === 0) return whole;
  return `${whole}.${(frac + '0'.repeat(fractionDigits)).slice(0, fractionDigits)}`;
}

export function parseUsdc(input: string): bigint {
  const trimmed = input.trim();
  if (!trimmed) throw new Error('amount required');
  return parseUnits(trimmed, 6);
}

export function formatDuration(seconds: number | bigint): string {
  const s = typeof seconds === 'bigint' ? Number(seconds) : seconds;
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  if (s < 86400) {
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    return `${h}h ${m}m`;
  }
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  return `${d}d ${h}h`;
}

export function shortAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}
