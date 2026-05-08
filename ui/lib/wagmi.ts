import { getDefaultConfig } from '@rainbow-me/rainbowkit';
import { http } from 'viem';
import { arcTestnet } from './chain';

const projectId = process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? 'brook-arc-dev';

export const wagmiConfig = getDefaultConfig({
  appName: 'Brook',
  projectId,
  chains: [arcTestnet],
  transports: {
    [arcTestnet.id]: http(),
  },
  ssr: true,
});
