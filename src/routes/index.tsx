import { useEffect, useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { Dashboard } from "@/components/wavelength/Dashboard";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Wavelength — JIT Liquidity Defense Dashboard" },
      {
        name: "description",
        content:
          "Live dashboard for the Wavelength Uniswap v4 hook: JIT detection, penalty fees, LP redistribution, and cross-chain risk flags via Reactive Network.",
      },
      { property: "og:title", content: "Wavelength — JIT Liquidity Defense Dashboard" },
      {
        property: "og:description",
        content:
          "Watch JIT liquidity attacks get detected, penalized, and propagated across pools in real time.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: Index,
});

function Index() {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  if (!mounted) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="mono text-xs uppercase tracking-[0.3em] text-muted-foreground">
          loading dashboard…
        </p>
      </div>
    );
  }

  return <Dashboard />;
}
