'use client';

import { ConnectButton } from '@rainbow-me/rainbowkit';
import { BROOK_ADDRESS } from '@/lib/addresses';
import { shortAddr } from '@/lib/format';

export function Header() {
  return (
    <header className="border-b border-neutral-800 px-6 py-4 flex items-center justify-between">
      <div className="flex items-center gap-3">
        <div className="text-2xl font-semibold tracking-tight">Brook</div>
        <span className="text-xs uppercase tracking-widest text-neutral-500">
          streaming primitive on Arc
        </span>
      </div>
      <div className="flex items-center gap-4">
        <a
          href={`https://testnet.arcscan.app/address/${BROOK_ADDRESS}`}
          target="_blank"
          rel="noopener noreferrer"
          className="hidden sm:inline-flex items-center gap-1 text-xs text-neutral-400 hover:text-neutral-200 font-mono"
        >
          {shortAddr(BROOK_ADDRESS)} ↗
        </a>
        <ConnectButton chainStatus="icon" showBalance={false} />
      </div>
    </header>
  );
}
