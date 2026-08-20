import { createConfig, http } from "wagmi";
import { baseSepolia, foundry } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import type { WavelengthConfig } from "./config";

export function buildWagmiConfig(app: WavelengthConfig) {
  return createConfig({
    chains: [baseSepolia, foundry],
    connectors: [injected()],
    transports: {
      [baseSepolia.id]: http(app.chainId === baseSepolia.id ? app.rpcUrl || undefined : undefined),
      [foundry.id]: http(app.chainId === foundry.id ? app.rpcUrl || undefined : undefined),
    },
    ssr: true,
  });
}
