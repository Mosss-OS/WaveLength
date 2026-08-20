import { formatUnits } from "viem";
import { EmptyState, Panel } from "./panels";

export function RedistributedCounter({ total }: { total?: bigint | undefined }) {
  return (
    <Panel title="Redistributed to loyal LPs" subtitle="Cumulative penalty value returned by the hook">
      {total === undefined ? (
        <EmptyState>Configure hook address + pool id to read cumulative state.</EmptyState>
      ) : (
        <div className="scanline rounded-lg border border-primary/30 px-5 py-6 text-center">
          <div className="mono text-4xl text-primary">
            {Number(formatUnits(total, 18)).toLocaleString(undefined, {
              minimumFractionDigits: 4,
              maximumFractionDigits: 4,
            })}
          </div>
          <div className="mono mt-2 text-[10px] uppercase tracking-[0.3em] text-muted-foreground">
            tokens redistributed
          </div>
        </div>
      )}
    </Panel>
  );
}
