import { Badge } from "@/components/ui/badge";
import { ScrollArea } from "@/components/ui/scroll-area";
import { shortAddress } from "@/lib/wavelength/config";
import type { RiskEntry } from "@/lib/wavelength/useWavelengthData";
import { EmptyState, Panel } from "./panels";

const CHAIN_NAMES: Record<string, string> = {
  "84532": "Base Sepolia",
  "31337": "Anvil",
  "11155111": "Sepolia",
  "5318008": "Reactive",
};

export function RegistryViewer({
  entries,
  connected,
  nowSeconds,
}: {
  entries: RiskEntry[];
  connected: boolean;
  nowSeconds: number;
}) {
  return (
    <Panel
      title="Cross-chain risk registry"
      subtitle="Flags propagated by the Reactive Network listener"
      className="lg:col-span-2"
    >
      {!connected ? (
        <EmptyState>Set the JITRiskRegistry address to view propagated flags.</EmptyState>
      ) : entries.length === 0 ? (
        <EmptyState>Registry is clean — no active JIT flags.</EmptyState>
      ) : (
        <ScrollArea className="h-56 pr-3">
          <table className="w-full text-left">
            <thead>
              <tr className="mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
                <th className="pb-2 font-normal">Address</th>
                <th className="pb-2 font-normal">Origin chain</th>
                <th className="pb-2 font-normal">Origin pool</th>
                <th className="pb-2 font-normal">Score</th>
                <th className="pb-2 font-normal">Status</th>
              </tr>
            </thead>
            <tbody className="mono text-xs">
              {entries.map((entry) => {
                const expired = Number(entry.expiresAt) <= nowSeconds;
                return (
                  <tr key={entry.account} className="border-t border-border/70">
                    <td className="py-2">{shortAddress(entry.account)}</td>
                    <td className="py-2 text-muted-foreground">
                      {CHAIN_NAMES[entry.originChainId.toString()] ?? entry.originChainId.toString()}
                    </td>
                    <td className="py-2 text-muted-foreground">
                      {shortAddress(entry.originPoolId)}
                    </td>
                    <td className="py-2">{entry.riskScore.toString()}</td>
                    <td className="py-2">
                      <Badge
                        variant={expired ? "outline" : "destructive"}
                        className="mono text-[10px]"
                      >
                        {expired
                          ? "decayed"
                          : `active · ${Math.max(0, Math.floor((Number(entry.expiresAt) - nowSeconds) / 60))}m`}
                      </Badge>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </ScrollArea>
      )}
    </Panel>
  );
}
