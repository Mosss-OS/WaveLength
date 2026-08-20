import { useEffect, useMemo, useState } from "react";
import { useBlockNumber, usePublicClient, useReadContract, useWatchContractEvent } from "wagmi";
import type { Log } from "viem";
import { jitRiskRegistryAbi, wavelengthHookAbi } from "./abi";
import { isAddress, isPoolId, type WavelengthConfig } from "./config";

export type FeedEvent = {
  id: string;
  kind: "swap" | "liquidity" | "jit" | "redistribute";
  blockNumber: bigint;
  actor?: string;
  detail: string;
  feeBps?: number;
  flagged: boolean;
};

export type RiskEntry = {
  account: string;
  riskScore: bigint;
  expiresAt: bigint;
  originChainId: bigint;
  originPoolId: string;
  blockNumber: bigint;
};

const MAX_FEED = 60;

function fmtInt(value: bigint) {
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const s = abs.toString();
  return `${negative ? "-" : "+"}${s.length > 12 ? `${s.slice(0, s.length - 12)}.${s.slice(s.length - 12, s.length - 9)}e12` : s}`;
}

/** Live hook events (swaps, liquidity, JIT flags) for the configured pool. */
export function useHookFeed(config: WavelengthConfig) {
  const [events, setEvents] = useState<FeedEvent[]>([]);
  const hook = isAddress(config.hookAddress) ? config.hookAddress : undefined;
  const poolId = isPoolId(config.poolId) ? config.poolId : undefined;
  const client = usePublicClient();

  useEffect(() => {
    setEvents([]);
  }, [hook, poolId, config.chainId]);

  const push = (next: FeedEvent[]) =>
    setEvents((prev) => [...next, ...prev].slice(0, MAX_FEED));

  const toFeed = (logs: readonly Log[]): FeedEvent[] =>
    logs.flatMap<FeedEvent>((log): FeedEvent[] => {
      const l = log as Log & { eventName?: string; args?: Record<string, unknown> };
      const args = (l.args ?? {}) as Record<string, never>;
      const id = `${l.transactionHash}-${l.logIndex}`;
      const blockNumber = l.blockNumber ?? 0n;
      switch (l.eventName) {
        case "SwapObserved":
          return [
            {
              id,
              kind: "swap" as const,
              blockNumber,
              actor: args["sender"] as unknown as string,
              detail: `swap ${fmtInt(args["amountSpecified"] as unknown as bigint)}`,
              feeBps: Number(args["feeBps"] as unknown as number),
              flagged: Boolean(args["flagged"]),
            },
          ];
        case "LiquidityObserved":
          return [
            {
              id,
              kind: "liquidity" as const,
              blockNumber,
              actor: args["lp"] as unknown as string,
              detail: `liquidity ${fmtInt(args["liquidityDelta"] as unknown as bigint)} · ticks ${String(args["tickLower"])}/${String(args["tickUpper"])}`,
              flagged: false,
            },
          ];
        case "JITDetected":
          return [
            {
              id,
              kind: "jit" as const,
              blockNumber,
              actor: args["lp"] as unknown as string,
              detail: `JIT confirmed · penalty ${String(args["penaltyAmount"])}`,
              feeBps: Number(args["penaltyFeeBps"] as unknown as number),
              flagged: true,
            },
          ];
        case "PenaltyRedistributed":
          return [
            {
              id,
              kind: "redistribute" as const,
              blockNumber,
              detail: `redistributed ${String(args["amount"])} to LPs`,
              flagged: false,
            },
          ];
        default:
          return [];
      }
    });

  for (const eventName of [
    "SwapObserved",
    "LiquidityObserved",
    "JITDetected",
    "PenaltyRedistributed",
  ] as const) {
    // eslint-disable-next-line react-hooks/rules-of-hooks
    useWatchContractEvent({
      address: hook,
      abi: wavelengthHookAbi,
      eventName,
      chainId: config.chainId,
      enabled: Boolean(hook),
      onLogs: (logs) => push(toFeed(logs)),
    });
  }

  // Backfill recent history so the dashboard isn't empty on load.
  const { data: blockNumber } = useBlockNumber({ chainId: config.chainId, query: { enabled: Boolean(hook) } });
  const [backfilled, setBackfilled] = useState(false);
  useEffect(() => {
    if (!hook || !client || !blockNumber || backfilled) return;
    let cancelled = false;
    (async () => {
      try {
        const fromBlock = blockNumber > 5000n ? blockNumber - 5000n : 0n;
        const logs = await client.getLogs({ address: hook, fromBlock, toBlock: blockNumber });
        const parsed = toFeed(logs as readonly Log[]);
        if (!cancelled) push(parsed.reverse());
      } catch {
        /* RPC may cap log range; live watching still works */
      } finally {
        if (!cancelled) setBackfilled(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [hook, client, blockNumber, backfilled]);

  const filtered = useMemo(
    () => (poolId ? events : events),
    [events, poolId],
  );

  return { events: filtered, connected: Boolean(hook) };
}

/** Fee tiers + cumulative redistribution read straight from hook state. */
export function useHookState(config: WavelengthConfig) {
  const hook = isAddress(config.hookAddress) ? config.hookAddress : undefined;
  const poolId = isPoolId(config.poolId) ? config.poolId : undefined;
  const common = { address: hook, abi: wavelengthHookAbi, chainId: config.chainId } as const;

  const baseFee = useReadContract({ ...common, functionName: "baseFeeBps", query: { enabled: Boolean(hook) } });
  const penaltyFee = useReadContract({ ...common, functionName: "penaltyFeeBps", query: { enabled: Boolean(hook) } });
  const redistributed = useReadContract({
    ...common,
    functionName: "totalRedistributed",
    args: poolId ? [poolId] : undefined,
    query: { enabled: Boolean(hook && poolId), refetchInterval: 8000 },
  });

  return {
    baseFeeBps: baseFee.data as number | undefined,
    penaltyFeeBps: penaltyFee.data as number | undefined,
    totalRedistributed: redistributed.data as bigint | undefined,
    isLoading: baseFee.isLoading || penaltyFee.isLoading || redistributed.isLoading,
  };
}

/** Cross-chain risk registry entries, sourced from RiskFlagged events. */
export function useRiskRegistry(config: WavelengthConfig) {
  const registry = isAddress(config.registryAddress) ? config.registryAddress : undefined;
  const [entries, setEntries] = useState<RiskEntry[]>([]);
  const client = usePublicClient();
  const { data: blockNumber } = useBlockNumber({ chainId: config.chainId, query: { enabled: Boolean(registry) } });
  const [backfilled, setBackfilled] = useState(false);

  useEffect(() => {
    setEntries([]);
    setBackfilled(false);
  }, [registry, config.chainId]);

  const absorb = (logs: readonly Log[]) => {
    const mapped = logs.flatMap((log) => {
      const l = log as Log & { eventName?: string; args?: Record<string, unknown> };
      if (l.eventName !== "RiskFlagged") return [];
      const a = l.args as Record<string, never>;
      return [
        {
          account: a["account"] as unknown as string,
          riskScore: a["riskScore"] as unknown as bigint,
          expiresAt: a["expiresAt"] as unknown as bigint,
          originChainId: a["originChainId"] as unknown as bigint,
          originPoolId: a["originPoolId"] as unknown as string,
          blockNumber: l.blockNumber ?? 0n,
        } satisfies RiskEntry,
      ];
    });
    if (!mapped.length) return;
    setEntries((prev) => {
      const byAccount = new Map(prev.map((e) => [e.account.toLowerCase(), e]));
      for (const entry of mapped) byAccount.set(entry.account.toLowerCase(), entry);
      return [...byAccount.values()].sort((a, b) => Number(b.blockNumber - a.blockNumber));
    });
  };

  useWatchContractEvent({
    address: registry,
    abi: jitRiskRegistryAbi,
    eventName: "RiskFlagged",
    chainId: config.chainId,
    enabled: Boolean(registry),
    onLogs: (logs) => absorb(logs),
  });

  useEffect(() => {
    if (!registry || !client || !blockNumber || backfilled) return;
    let cancelled = false;
    (async () => {
      try {
        const fromBlock = blockNumber > 5000n ? blockNumber - 5000n : 0n;
        const logs = await client.getLogs({ address: registry, fromBlock, toBlock: blockNumber });
        if (!cancelled) absorb(logs as readonly Log[]);
      } catch {
        /* ignore */
      } finally {
        if (!cancelled) setBackfilled(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [registry, client, blockNumber, backfilled]);

  return { entries, connected: Boolean(registry) };
}
