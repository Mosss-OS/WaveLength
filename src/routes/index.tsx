import { useEffect, useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { Dashboard } from "@/components/wavelength/Dashboard";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      {
        title: "Wavelength Dashboard | JIT Attack Monitor & LP Defense",
      },
      {
        name: "description",
        content:
          "Live monitoring dashboard for Wavelength - Uniswap v4 JIT liquidity defense hook. Watch JIT attacks get detected and penalized in real time, view cross-chain risk flags via Reactive Network, track LP fee redistribution, and simulate attacks.",
      },
      { property: "og:type", content: "website" },
      {
        property: "og:title",
        content: "Wavelength Dashboard | JIT Attack Monitor & LP Defense",
      },
      {
        property: "og:description",
        content:
          "Real-time monitoring of JIT liquidity attacks, penalty fee distribution, cross-chain risk propagation, and LP rebate claims on Uniswap v4.",
      },
      { property: "og:image", content: "https://res.cloudinary.com/dv0tt80vn/image/upload/v1787230439/WaveLength_fmzfcn.png" },
      { name: "twitter:card", content: "summary_large_image" },
      {
        name: "twitter:title",
        content: "Wavelength Dashboard | JIT Attack Monitor",
      },
      {
        name: "twitter:description",
        content:
          "Real-time monitoring of JIT attacks, penalty fees, and cross-chain risk flags on Uniswap v4.",
      },
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
