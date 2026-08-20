import { Badge } from "@/components/ui/badge";
import { ScrollArea } from "@/components/ui/scroll-area";
import { cn } from "@/lib/utils";
import type { FeedEvent } from "@/lib/wavelength/useWavelengthData";
import { shortAddress } from "@/lib/wavelength/config";
import { EmptyState, Panel } from "./panels";

const KIND_LABEL: Record<FeedEvent["kind"], string> = {
  swap: "SWAP",
  liquidity: "LIQ",
  jit: "JIT",
  redistribute: "REDIST",
};

export function LivePoolFeed({ events, connected }: { events: FeedEvent[]; connected: boolean }) {
  return (
    <Panel
      title="Live pool feed"
      subtitle="Swap & liquidity events streamed from the hook"
      right={
        <span className="mono flex items-center gap-2 text-[10px] uppercase tracking-widest text-muted-foreground">
          <span
            className={cn(
              "size-2 rounded-full",
              connected ? "animate-pulse bg-success" : "bg-muted-foreground",
            )}
          />
          {connected ? "watching" : "idle"}
        </span>
      }
      className="lg:row-span-2"
    >
      {!connected ? (
        <EmptyState>Set the hook address in Contracts to start streaming.</EmptyState>
      ) : events.length === 0 ? (
        <EmptyState>No events yet — waiting for pool activity.</EmptyState>
      ) : (
        <ScrollArea className="h-[420px] pr-3">
          <ul className="space-y-1.5">
            {events.map((event) => (
              <li
                key={event.id}
                className={cn(
                  "mono flex items-center gap-3 rounded-md border px-3 py-2 text-xs",
                  event.flagged
                    ? "border-destructive/60 bg-destructive/10"
                    : "border-border bg-secondary/30",
                )}
              >
                <span className="w-16 shrink-0 text-[10px] text-muted-foreground">
                  #{event.blockNumber.toString()}
                </span>
                <Badge
                  variant={event.flagged ? "destructive" : "outline"}
                  className="mono w-16 justify-center text-[10px]"
                >
                  {KIND_LABEL[event.kind]}
                </Badge>
                <span className="w-24 shrink-0 text-muted-foreground">
                  {shortAddress(event.actor)}
                </span>
                <span className="flex-1 truncate">{event.detail}</span>
                {event.feeBps !== undefined ? (
                  <span className={cn(event.flagged ? "text-destructive" : "text-primary")}>
                    {(event.feeBps / 100).toFixed(2)}%
                  </span>
                ) : null}
              </li>
            ))}
          </ul>
        </ScrollArea>
      )}
    </Panel>
  );
}
