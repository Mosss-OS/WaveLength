import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  Outlet,
  Link,
  createRootRouteWithContext,
  useRouter,
  HeadContent,
  Scripts,
} from "@tanstack/react-router";
import { useEffect, type ReactNode } from "react";

import appCss from "../styles.css?url";
import { reportLovableError } from "../lib/lovable-error-reporting";

function NotFoundComponent() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-7xl font-bold text-foreground">404</h1>
        <h2 className="mt-4 text-xl font-semibold text-foreground">Page not found</h2>
        <p className="mt-2 text-sm text-muted-foreground">
          The page you're looking for doesn't exist or has been moved.
        </p>
        <div className="mt-6">
          <Link
            to="/"
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Go home
          </Link>
        </div>
      </div>
    </div>
  );
}

function ErrorComponent({ error, reset }: { error: Error; reset: () => void }) {
  console.error(error);
  const router = useRouter();
  useEffect(() => {
    reportLovableError(error, { boundary: "tanstack_root_error_component" });
  }, [error]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-xl font-semibold tracking-tight text-foreground">
          This page didn't load
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          Something went wrong on our end. You can try refreshing or head back home.
        </p>
        <div className="mt-6 flex flex-wrap justify-center gap-2">
          <button
            onClick={() => {
              router.invalidate();
              reset();
            }}
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Try again
          </button>
          <a
            href="/"
            className="inline-flex items-center justify-center rounded-md border border-input bg-background px-4 py-2 text-sm font-medium text-foreground transition-colors hover:bg-accent"
          >
            Go home
          </a>
        </div>
      </div>
    </div>
  );
}

export const Route = createRootRouteWithContext<{ queryClient: QueryClient }>()({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      {
        title: "Wavelength | Uniswap v4 JIT Liquidity Defense via Reactive Network",
      },
      {
        name: "description",
        content:
          "Wavelength is a Uniswap v4 hook that detects and penalizes JIT (just-in-time) liquidity attacks in real time, redistributes penalty fees to loyal LPs, and propagates cross-chain risk signals via Reactive Network so attackers cannot evade detection across pools.",
      },
      { name: "author", content: "Wavelength" },
      { name: "keywords", content: "Uniswap, v4, hook, JIT, just-in-time liquidity, MEV, sandwich attack, DeFi, LP protection, Reactive Network, cross-chain, dynamic fees, liquidity defense, sustainable liquidity, Base Sepolia" },
      { name: "theme-color", content: "#0a0a0a" },

      // Open Graph
      { property: "og:type", content: "website" },
      { property: "og:site_name", content: "Wavelength" },
      {
        property: "og:title",
        content: "Wavelength | Uniswap v4 JIT Liquidity Defense",
      },
      {
        property: "og:description",
        content:
          "Detects and penalizes JIT liquidity attacks on Uniswap v4. Redistributes penalty fees to loyal LPs. Cross-chain risk propagation via Reactive Network.",
      },
      { property: "og:image", content: "https://res.cloudinary.com/dv0tt80vn/image/upload/v1787230439/WaveLength_fmzfcn.png" },
      { property: "og:image:width", content: "1200" },
      { property: "og:image:height", content: "630" },
      { property: "og:image:alt", content: "Wavelength - Uniswap v4 JIT Liquidity Defense" },

      // Twitter / X
      { name: "twitter:card", content: "summary_large_image" },
      {
        name: "twitter:title",
        content: "Wavelength | Uniswap v4 JIT Liquidity Defense",
      },
      {
        name: "twitter:description",
        content:
          "Detects and penalizes JIT liquidity attacks on Uniswap v4. Cross-chain risk propagation via Reactive Network.",
      },
      { name: "twitter:image", content: "https://res.cloudinary.com/dv0tt80vn/image/upload/v1787230439/WaveLength_fmzfcn.png" },
    ],
    links: [
      { rel: "preconnect", href: "https://fonts.googleapis.com" },
      { rel: "preconnect", href: "https://fonts.gstatic.com", crossOrigin: "anonymous" },
      {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&family=Space+Grotesk:wght@400;500;600;700&display=swap",
      },
      {
        rel: "stylesheet",
        href: appCss,
      },
      { rel: "icon", href: "/favicon.png", type: "image/png" },
      { rel: "apple-touch-icon", href: "/favicon.png" },
    ],
  }),
  shellComponent: RootShell,
  component: RootComponent,
  notFoundComponent: NotFoundComponent,
  errorComponent: ErrorComponent,
});

function RootShell({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className="dark">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function RootComponent() {
  const { queryClient } = Route.useRouteContext();

  return (
    <QueryClientProvider client={queryClient}>
      {/* Required: nested routes render here. Removing <Outlet /> breaks all child routes. */}
      <Outlet />
    </QueryClientProvider>
  );
}
