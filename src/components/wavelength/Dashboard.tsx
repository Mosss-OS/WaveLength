import { useEffect, useMemo, useState } from "react";
import { WagmiProvider, useAccount, useConnect, useDisconnect } from "wagmi";
import { Button } from "@/components/ui/button";
import { buildWagmiConfig } from "@/lib/wavelength/wagmi";
import { shortAddress, useWavelengthConfig, type WavelengthConfig } from "@/lib/wavelength/config";
import {
  useHookFeed,
  useHookState,
  useRiskRegistry,
} from "@/lib/wavelength/useWavelengthData";
import { ConfigPanel } from "./ConfigPanel";
import { LivePoolFeed } from "./LivePoolFeed";
import { FeeComparison } from "./FeeComparison";
import { RedistributedCounter } from "./RedistributedCounter";
import { RegistryViewer } from "./RegistryViewer";
import { SimulateAttack } from "./SimulateAttack";

function WalletButton() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();

  if (isConnected) {
    return (
      <Button variant="secondary" size="sm" className="mono text-xs" onClick={() => disconnect()}>
        {shortAddress(address)}
      </Button>
    );
  }
  return (
    <Button
      size="sm"
      className="mono text-xs"
      disabled={isPending || connectors.length === 0}
      onClick={() => connectors[0] && connect({ connector: connectors[0] })}
    >
      Connect wallet
    </Button>
  );
}

function DashboardBody({
  config,
  onSave,
}: {
  config: WavelengthConfig;
  onSave: (next: WavelengthConfig) => void;
}) {
  const { events, connected } = useHookFeed(config);
  const { baseFeeBps, penaltyFeeBps, totalRedistributed } = useHookState(config);
  const registry = useRiskRegistry(config);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));

  useEffect(() => {
    const id = window.setInterval(() => setNow(Math.floor(Date.now() / 1000)), 15000);
    return () => window.clearInterval(id);
  }, []);

  const flagged = useMemo(() => events.filter((e) => e.flagged).length, [events]);

  return (
    <div className="min-h-screen">
      <header className="border-b border-border/80 bg-background/70 backdrop-blur">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3 px-5 py-4">
          <div className="flex items-baseline gap-3">
            <h1 className="text-xl font-semibold tracking-tight">Wavelength</h1>
            <p className="mono hidden text-[11px] uppercase tracking-[0.22em] text-muted-foreground sm:block">
              uniswap v4 · jit defense · reactive network
            </p>
          </div>
          <div className="flex items-center gap-2">
            <span className="mono rounded-md border border-border px-2 py-1 text-[10px] uppercase tracking-widest text-muted-foreground">
              {flagged} flagged
            </span>
            <ConfigPanel config={config} onSave={onSave} />
            <WalletButton />
          </div>
        </div>
      </header>

      <main className="mx-auto grid max-w-7xl gap-4 px-5 py-6 lg:grid-cols-3">
        <LivePoolFeed events={events} connected={connected} />
        <FeeComparison baseFeeBps={baseFeeBps} penaltyFeeBps={penaltyFeeBps} />
        <RedistributedCounter total={totalRedistributed} />
        <SimulateAttack config={config} />
        <RegistryViewer
          entries={registry.entries}
          connected={registry.connected}
          nowSeconds={now}
        />
      </main>
    </div>
  );
}

export function Dashboard() {
  const { config, update, hydrated } = useWavelengthConfig();
  const wagmiConfig = useMemo(() => buildWagmiConfig(config), [config]);

  if (!hydrated) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="mono text-xs uppercase tracking-[0.3em] text-muted-foreground">
          initializing…
        </p>
      </div>
    );
  }

  return (
    <WagmiProvider key={`${config.chainId}-${config.rpcUrl}`} config={wagmiConfig}>
      <DashboardBody config={config} onSave={update} />
    </WagmiProvider>
  );
}
