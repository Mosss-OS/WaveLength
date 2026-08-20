import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

export function Panel({
  title,
  subtitle,
  right,
  children,
  className,
}: {
  title: string;
  subtitle?: string;
  right?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={cn("panel flex flex-col", className)}>
      <header className="flex items-start justify-between gap-3 border-b border-border px-4 py-3">
        <div>
          <h2 className="mono text-[11px] uppercase tracking-[0.22em] text-primary">{title}</h2>
          {subtitle ? (
            <p className="mt-1 text-xs text-muted-foreground">{subtitle}</p>
          ) : null}
        </div>
        {right}
      </header>
      <div className="flex-1 p-4">{children}</div>
    </section>
  );
}

export function EmptyState({ children }: { children: ReactNode }) {
  return (
    <div className="flex h-full min-h-24 items-center justify-center rounded-md border border-dashed border-border px-4 py-6 text-center">
      <p className="mono text-xs text-muted-foreground">{children}</p>
    </div>
  );
}

export function Stat({ label, value, tone }: { label: string; value: string; tone?: "danger" | "ok" }) {
  return (
    <div className="rounded-md border border-border bg-secondary/40 px-3 py-2.5">
      <div className="mono text-[10px] uppercase tracking-[0.2em] text-muted-foreground">{label}</div>
      <div
        className={cn(
          "mono mt-1 text-xl",
          tone === "danger" && "text-destructive",
          tone === "ok" && "text-success",
        )}
      >
        {value}
      </div>
    </div>
  );
}
