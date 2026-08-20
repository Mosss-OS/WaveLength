import { EmptyState, Panel, Stat } from "./panels";

export function FeeComparison({
  baseFeeBps,
  penaltyFeeBps,
}: {
  baseFeeBps?: number | undefined;
  penaltyFeeBps?: number | undefined;
}) {
  const ready = baseFeeBps !== undefined && penaltyFeeBps !== undefined;
  const multiple = ready && baseFeeBps > 0 ? (penaltyFeeBps / baseFeeBps).toFixed(1) : "—";

  return (
    <Panel title="Fee comparison" subtitle="Normal interaction vs. flagged JIT interaction">
      {!ready ? (
        <EmptyState>Fee tiers load once the hook address is configured.</EmptyState>
      ) : (
        <div className="space-y-3">
          <div className="grid grid-cols-2 gap-3">
            <Stat label="Normal LP / swap" value={`${(baseFeeBps / 100).toFixed(2)}%`} tone="ok" />
            <Stat label="Flagged JIT" value={`${(penaltyFeeBps / 100).toFixed(2)}%`} tone="danger" />
          </div>
          <div className="space-y-1.5">
            <div className="h-2 overflow-hidden rounded-full bg-secondary">
              <div className="h-full rounded-full bg-success" style={{ width: "18%" }} />
            </div>
            <div className="h-2 overflow-hidden rounded-full bg-secondary">
              <div
                className="h-full rounded-full bg-destructive"
                style={{
                  width: `${Math.min(100, (penaltyFeeBps / Math.max(penaltyFeeBps, 1)) * 100)}%`,
                }}
              />
            </div>
          </div>
          <p className="mono text-xs text-muted-foreground">
            Penalty tier is <span className="text-destructive">{multiple}×</span> the base fee; the
            delta is escrowed for loyal LPs.
          </p>
        </div>
      )}
    </Panel>
  );
}
