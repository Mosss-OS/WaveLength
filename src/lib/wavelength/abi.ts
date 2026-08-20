// ABI fragments for the Wavelength hook + JITRiskRegistry.
// Only the pieces the dashboard reads/watches are declared here.

export const wavelengthHookAbi = [
  {
    type: "event",
    name: "JITDetected",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "lp", type: "address", indexed: true },
      { name: "blockNumber", type: "uint256", indexed: false },
      { name: "penaltyFeeBps", type: "uint24", indexed: false },
      { name: "penaltyAmount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "SwapObserved",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "sender", type: "address", indexed: true },
      { name: "amountSpecified", type: "int256", indexed: false },
      { name: "feeBps", type: "uint24", indexed: false },
      { name: "flagged", type: "bool", indexed: false },
    ],
  },
  {
    type: "event",
    name: "LiquidityObserved",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "lp", type: "address", indexed: true },
      { name: "liquidityDelta", type: "int256", indexed: false },
      { name: "tickLower", type: "int24", indexed: false },
      { name: "tickUpper", type: "int24", indexed: false },
    ],
  },
  {
    type: "event",
    name: "PenaltyRedistributed",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "function",
    name: "baseFeeBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint24" }],
  },
  {
    type: "function",
    name: "penaltyFeeBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint24" }],
  },
  {
    type: "function",
    name: "totalRedistributed",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "pendingRebate",
    stateMutability: "view",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "lp", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "claimRebate",
    stateMutability: "nonpayable",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [],
  },
] as const;

export const jitRiskRegistryAbi = [
  {
    type: "event",
    name: "RiskFlagged",
    inputs: [
      { name: "account", type: "address", indexed: true },
      { name: "originChainId", type: "uint256", indexed: true },
      { name: "originPoolId", type: "bytes32", indexed: true },
      { name: "riskScore", type: "uint256", indexed: false },
      { name: "expiresAt", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "RiskExpired",
    inputs: [{ name: "account", type: "address", indexed: true }],
  },
  {
    type: "function",
    name: "riskOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [
      { name: "riskScore", type: "uint256" },
      { name: "expiresAt", type: "uint256" },
      { name: "originChainId", type: "uint256" },
      { name: "originPoolId", type: "bytes32" },
    ],
  },
] as const;

// Minimal demo-harness ABI: a scripted add-liquidity -> large swap -> remove
// sequence exposed by the deployment's attack simulator contract.
export const attackSimulatorAbi = [
  {
    type: "function",
    name: "simulateJitAttack",
    stateMutability: "nonpayable",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [],
  },
] as const;
