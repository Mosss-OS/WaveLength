import { useState } from "react";
import { useAccount, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { Button } from "@/components/ui/button";
import { attackSimulatorAbi } from "@/lib/wavelength/abi";
import { isAddress, isPoolId, type WavelengthConfig } from "@/lib/wavelength/config";
import { EmptyState, Panel } from "./panels";

const STEPS = [
  "attacker adds in-range liquidity",
  "large swap routes through the pool",
  "attacker removes liquidity → JIT confirmed",
  "penalty escrowed + risk flag broadcast",
];

export function SimulateAttack({ config }: { config: WavelengthConfig }) {
  const { isConnected } = useAccount();
  const { writeContract, data: hash, isPending, error } = useWriteContract();
  const { isLoading: mining, isSuccess } = useWaitForTransactionReceipt({ hash });
  const [step, setStep] = useState(-1);

  const ready = isAddress(config.simulatorAddress) && isPoolId(config.poolId);

  const run = () => {
    setStep(0);
    STEPS.forEach((_, i) => window.setTimeout(() => setStep(i), i * 900));
    writeContract({
      address: config.simulatorAddress as `0x${string}`,
      abi: attackSimulatorAbi,
      functionName: "simulateJitAttack",
      args: [config.poolId as `0x${string}`],
      chainId: config.chainId,
    });
  };

  return (
    <Panel title="Simulate attack" subtitle="Scripted add → swap → remove against the demo pool">
      {!ready ? (
        <EmptyState>Add a simulator address and pool id to enable the scripted attack.</EmptyState>
      ) : (
        <div className="space-y-3">
          <Button
            className="w-full"
            disabled={!isConnected || isPending || mining}
            onClick={run}
          >
            {isPending ? "confirm in wallet…" : mining ? "executing…" : "Run JIT attack sequence"}
          </Button>
          {!isConnected ? (
            <p className="mono text-[11px] text-muted-foreground">Connect a wallet to broadcast.</p>
          ) : null}
          <ol className="space-y-1.5">
            {STEPS.map((label, i) => (
              <li
                key={label}
                className={`mono text-xs ${i <= step ? "text-foreground" : "text-muted-foreground"}`}
              >
                <span className="text-primary">{i <= step ? "▸" : "·"}</span> {label}
              </li>
            ))}
          </ol>
          {isSuccess ? (
            <p className="mono text-[11px] text-success">Sequence mined — watch the feed.</p>
          ) : null}
          {error ? (
            <p className="mono text-[11px] text-destructive">{error.message.split("\n")[0]}</p>
          ) : null}
        </div>
      )}
    </Panel>
  );
}
