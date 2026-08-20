import { useState } from "react";
import { baseSepolia, foundry } from "viem/chains";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
import { isAddress, isPoolId, type WavelengthConfig } from "@/lib/wavelength/config";

type Props = {
  config: WavelengthConfig;
  onSave: (next: WavelengthConfig) => void;
};

const FIELDS: Array<{ key: keyof WavelengthConfig; label: string; hint: string }> = [
  { key: "hookAddress", label: "Wavelength hook", hint: "0x… (v4 hook with mined flags)" },
  { key: "registryAddress", label: "JITRiskRegistry", hint: "0x… (destination chain registry)" },
  { key: "simulatorAddress", label: "Attack simulator", hint: "0x… (optional demo harness)" },
  { key: "poolId", label: "Demo pool id", hint: "0x… 32-byte PoolId" },
  { key: "rpcUrl", label: "RPC URL", hint: "https://… (falls back to public RPC)" },
];

export function ConfigPanel({ config, onSave }: Props) {
  const [draft, setDraft] = useState(config);
  const [open, setOpen] = useState(false);

  const set = (key: keyof WavelengthConfig, value: string | number) =>
    setDraft((d) => ({ ...d, [key]: value }));

  return (
    <Sheet
      open={open}
      onOpenChange={(next) => {
        if (next) setDraft(config);
        setOpen(next);
      }}
    >
      <SheetTrigger asChild>
        <Button variant="outline" size="sm" className="mono text-xs">
          Contracts
        </Button>
      </SheetTrigger>
      <SheetContent className="w-full overflow-y-auto sm:max-w-md">
        <SheetHeader>
          <SheetTitle>Deployment config</SheetTitle>
          <SheetDescription>
            Addresses are stored locally in this browser and used for all live reads.
          </SheetDescription>
        </SheetHeader>
        <div className="space-y-4 px-4 pb-6">
          <div className="space-y-2">
            <Label className="text-xs uppercase tracking-widest text-muted-foreground">Chain</Label>
            <div className="flex gap-2">
              {[baseSepolia, foundry].map((chain) => (
                <Button
                  key={chain.id}
                  type="button"
                  size="sm"
                  variant={draft.chainId === chain.id ? "default" : "outline"}
                  className="mono text-xs"
                  onClick={() => set("chainId", chain.id)}
                >
                  {chain.name}
                </Button>
              ))}
            </div>
          </div>

          {FIELDS.map((field) => {
            const value = String(draft[field.key] ?? "");
            const invalid =
              value.length > 0 &&
              ((field.key.endsWith("Address") && !isAddress(value)) ||
                (field.key === "poolId" && !isPoolId(value)));
            return (
              <div key={field.key} className="space-y-1.5">
                <Label className="text-xs uppercase tracking-widest text-muted-foreground">
                  {field.label}
                </Label>
                <Input
                  value={value}
                  spellCheck={false}
                  placeholder={field.hint}
                  className="mono text-xs"
                  onChange={(e) => set(field.key, e.target.value.trim())}
                />
                {invalid ? (
                  <p className="mono text-[11px] text-destructive">Malformed hex value</p>
                ) : null}
              </div>
            );
          })}

          <Button
            className="w-full"
            onClick={() => {
              onSave(draft);
              setOpen(false);
            }}
          >
            Save & reconnect
          </Button>
        </div>
      </SheetContent>
    </Sheet>
  );
}
