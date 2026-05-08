'use client';

import { useState } from 'react';
import { Header } from './components/Header';
import { CreateStream } from './components/CreateStream';
import { MyStreams } from './components/MyStreams';

export default function Home() {
  const [refreshKey, setRefreshKey] = useState(0);

  return (
    <>
      <Header />
      <main className="flex-1 max-w-3xl mx-auto w-full px-6 py-10 space-y-8">
        <div className="space-y-2">
          <h1 className="text-3xl font-semibold tracking-tight">USDC streams on Arc</h1>
          <p className="text-sm text-neutral-400 max-w-xl">
            Open the tap and let it pour. Brook is a minimal primitive — fork it,
            integrate it, donate to it.
          </p>
        </div>

        <CreateStream onCreated={() => setRefreshKey((n) => n + 1)} />
        <MyStreams refreshKey={refreshKey} />

        <footer className="pt-8 border-t border-neutral-800 text-xs text-neutral-500 flex flex-wrap gap-4 justify-between">
          <span>Brook · open-source streaming primitive on Arc testnet</span>
          <a
            href="https://github.com/cryptoyasenka/brook-arc"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-neutral-300"
          >
            github.com/cryptoyasenka/brook-arc ↗
          </a>
        </footer>
      </main>
    </>
  );
}
