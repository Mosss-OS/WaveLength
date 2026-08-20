import { useCallback, useEffect, useState } from "react";
import { baseSepolia, foundry } from "viem/chains";

export type WavelengthConfig = {
  chainId: number;
  rpcUrl: string;
  hookAddress: string;
  registryAddress: string;
  simulatorAddress: string;
  poolId: string;
  poolBLabel: string;
};

export const SUPPORTED_CHAINS = [baseSepolia, foundry] as const;

export const EMPTY_CONFIG: WavelengthConfig = {
  chainId: baseSepolia.id,
  rpcUrl: "https://sepolia.base.org",
  hookAddress: "0xC2E1EcA2a25FF0546Fee30a405c10d250f469f83",
  registryAddress: "0x7DF12653c2b1d5Addca057739fdcE833c0A96A50",
  simulatorAddress: "",
  poolId: "",
  poolBLabel: "Pool B",
};

const STORAGE_KEY = "wavelength.config.v1";

export function isAddress(value: string): value is `0x${string}` {
  return /^0x[a-fA-F0-9]{40}$/.test(value);
}

export function isPoolId(value: string): value is `0x${string}` {
  return /^0x[a-fA-F0-9]{64}$/.test(value);
}

export function loadConfig(): WavelengthConfig {
  if (typeof window === "undefined") return EMPTY_CONFIG;
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return EMPTY_CONFIG;
    return { ...EMPTY_CONFIG, ...(JSON.parse(raw) as Partial<WavelengthConfig>) };
  } catch {
    return EMPTY_CONFIG;
  }
}

export function saveConfig(config: WavelengthConfig) {
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
}

export function useWavelengthConfig() {
  const [config, setConfig] = useState<WavelengthConfig>(EMPTY_CONFIG);
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    setConfig(loadConfig());
    setHydrated(true);
  }, []);

  const update = useCallback((next: WavelengthConfig) => {
    setConfig(next);
    saveConfig(next);
  }, []);

  return { config, update, hydrated };
}

export function shortAddress(value?: string) {
  if (!value) return "—";
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}
