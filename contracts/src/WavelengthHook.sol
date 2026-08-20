// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

/// @notice Interface for querying the JITRiskRegistry on destination chains.
interface IJITRiskRegistry {
    function isCurrentlyFlagged(address attacker) external view returns (bool);
}

/// @title WavelengthHook
/// @notice Uniswap v4 hook that detects JIT attacks, penalizes them via dynamic fees,
///         and redistributes penalty fees to loyal LPs. Consults the JITRiskRegistry
///         for cross-pool risk signals propagated via Reactive Network.
contract WavelengthHook is IHooks {
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;

    uint256 public constant MAX_RECENT_LPS = 50;

    error HookNotImplemented();

    // --- Phase 1 events ---
    event JITSuspected(
        address indexed lp, PoolId indexed poolId, uint256 blockNumber, int24 tickLower, int24 tickUpper
    );
    event JITDetected(address indexed lp, PoolId indexed poolId, uint256 blockNumber);

    // --- Phase 2 events ---
    event PenaltyFeeApplied(PoolId indexed poolId, uint24 fee, uint256 blockNumber);
    event FeeReset(PoolId indexed poolId, uint24 fee, uint256 blockNumber);
    event RebateClaimed(address indexed lp, uint256 amount);

    // --- Structs ---
    struct RecentLP {
        address lp;
        uint256 blockNumber;
        int24 tickLower;
        int24 tickUpper;
        bool flagged;
    }

    struct LPPosition {
        uint256 addBlock;
        int24 tickLower;
        int24 tickUpper;
    }

    // --- State ---
    IPoolManager public immutable poolManager;
    uint256 public largeSwapThresholdBips;
    uint256 public detectionWindowBlocks;
    uint24 public baseFee;
    uint24 public penaltyFee;
    uint256 public penaltyFeeResetDelay;

    mapping(PoolId => RecentLP[]) public recentLPs;

    // Phase 2: per-pool LP position tracking (one active position per address)
    mapping(PoolId => mapping(address => LPPosition)) public lpPositions;

    // Phase 2: time-weighted loyalty scores (accumulated on removal)
    // LP's score = sum of liquidity * blocksHeld for each add/remove cycle
    mapping(PoolId => mapping(address => uint256)) public loyaltyScores;

    // Phase 2: total loyalty score across all LPs for a pool (for share calculation)
    mapping(PoolId => uint256) public totalLoyaltyScore;

    // Phase 2: accumulated penalty fees per pool (in token0 terms, simplified as counter)
    mapping(PoolId => uint256) public penaltyFeesAccrued;

    // Phase 2: per-LP share numerator (penaltyFeesAccrued * loyaltyScore / totalLoyaltyScore at claim time)
    mapping(address => uint256) public claimableRebates;

    // Phase 2: track which block the penalty fee was last applied (for auto-reset)
    mapping(PoolId => uint256) public penaltyFeeAppliedBlock;

    // Phase 3: cross-chain risk registry (set via setRiskRegistry)
    IJITRiskRegistry public jitRiskRegistry;

    constructor(
        IPoolManager _poolManager,
        uint256 _largeSwapThresholdBips,
        uint256 _detectionWindowBlocks,
        uint24 _baseFee,
        uint24 _penaltyFee,
        uint256 _penaltyFeeResetDelay
    ) {
        poolManager = _poolManager;
        largeSwapThresholdBips = _largeSwapThresholdBips;
        detectionWindowBlocks = _detectionWindowBlocks;
        baseFee = _baseFee;
        penaltyFee = _penaltyFee;
        penaltyFeeResetDelay = _penaltyFeeResetDelay;

        IHooks(this).validateHookPermissions(
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @notice Set the initial dynamic LP fee when a pool is initialized.
    function afterInitialize(
        address, PoolKey calldata key, uint160, int24
    ) external returns (bytes4) {
        poolManager.updateDynamicLPFee(key, baseFee);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external returns (bytes4) {
        PoolId poolId = key.toId();

        if (params.liquidityDelta > 0) {
            _addRecentLP(poolId, sender, params.tickLower, params.tickUpper);

            // Record LP position for loyalty tracking
            lpPositions[poolId][sender] = LPPosition({
                addBlock: block.number,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper
            });

            // Phase 3: If this LP is flagged in the cross-chain risk registry,
            // immediately mark them as suspected JIT for this pool.
            if (address(jitRiskRegistry) != address(0)) {
                if (jitRiskRegistry.isCurrentlyFlagged(sender)) {
                    // Auto-flag in recent LPs so the next large swap triggers penalty
                    _autoFlagFromRegistry(poolId, sender, params.tickLower, params.tickUpper);
                }
            }
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(
        address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        // Auto-reset penalty fee after delay
        if (penaltyFeeAppliedBlock[poolId] > 0
            && block.number >= penaltyFeeAppliedBlock[poolId] + penaltyFeeResetDelay
        ) {
            poolManager.updateDynamicLPFee(key, baseFee);
            penaltyFeeAppliedBlock[poolId] = 0;
            emit FeeReset(poolId, baseFee, block.number);
        }

        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);

        uint256 absAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
        uint256 threshold = (uint256(liquidity) * largeSwapThresholdBips) / 10_000;

        if (absAmount >= threshold && liquidity > 0) {
            _flagSuspectedJIT(poolId, currentTick);

            // Apply penalty fee for this large swap (if JIT suspects are in range)
            if (_hasSuspectedJITInRange(poolId, currentTick)) {
                poolManager.updateDynamicLPFee(key, penaltyFee);
                penaltyFeesAccrued[poolId] += _estimatePenaltyFee(absAmount, penaltyFee);
                penaltyFeeAppliedBlock[poolId] = block.number;
                emit PenaltyFeeApplied(poolId, penaltyFee, block.number);
            }
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, int128) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address sender, PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) external returns (bytes4) {
        PoolId poolId = key.toId();
        RecentLP[] storage lps = recentLPs[poolId];

        bool isJIT = false;
        for (uint256 i = 0; i < lps.length; i++) {
            RecentLP storage rec = lps[i];
            if (rec.lp == sender && rec.flagged) {
                if (block.number <= rec.blockNumber + detectionWindowBlocks) {
                    emit JITDetected(sender, poolId, block.number);
                    isJIT = true;
                }
                rec.flagged = false;
                break;
            }
        }

        // If confirmed JIT, apply penalty fee
        if (isJIT) {
            poolManager.updateDynamicLPFee(key, penaltyFee);
            penaltyFeeAppliedBlock[poolId] = block.number;
            emit PenaltyFeeApplied(poolId, penaltyFee, block.number);
        }

        // Update loyalty score on removal
        _removeAndAccrueLoyalty(poolId, sender);

        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // --- Phase 3: Public functions ---

    /// @notice Set the JITRiskRegistry for cross-chain risk lookup.
    function setRiskRegistry(IJITRiskRegistry _registry) external {
        jitRiskRegistry = _registry;
    }

    // --- Phase 2: Public functions ---

    /// @notice LP calls this to claim their share of redistributed penalty fees.
    function claimRebate() external {
        uint256 amount = claimableRebates[msg.sender];
        require(amount > 0, "nothing to claim");
        claimableRebates[msg.sender] = 0;
        // In a real implementation, this would transfer tokens.
        // For the hackathon demo, we track the value and emit the event.
        emit RebateClaimed(msg.sender, amount);
    }

    // --- Internal: Phase 1 ---

    function _addRecentLP(PoolId poolId, address lp, int24 tickLower, int24 tickUpper) internal {
        RecentLP[] storage lps = recentLPs[poolId];

        uint256 pruneBefore = block.number > detectionWindowBlocks + 10
            ? block.number - detectionWindowBlocks - 10
            : 0;

        uint256 writeIdx = 0;
        for (uint256 i = 0; i < lps.length; i++) {
            if (lps[i].blockNumber >= pruneBefore) {
                if (writeIdx != i) {
                    lps[writeIdx] = lps[i];
                }
                writeIdx++;
            }
        }
        while (lps.length > writeIdx) {
            lps.pop();
        }

        if (lps.length < MAX_RECENT_LPS) {
            lps.push(RecentLP({
                lp: lp,
                blockNumber: block.number,
                tickLower: tickLower,
                tickUpper: tickUpper,
                flagged: false
            }));
        }
    }

    function _flagSuspectedJIT(PoolId poolId, int24 currentTick) internal {
        RecentLP[] storage lps = recentLPs[poolId];

        for (uint256 i = 0; i < lps.length; i++) {
            RecentLP storage rec = lps[i];
            if (!rec.flagged
                && currentTick >= rec.tickLower
                && currentTick < rec.tickUpper
                && block.number <= rec.blockNumber + detectionWindowBlocks
            ) {
                rec.flagged = true;
                emit JITSuspected(rec.lp, poolId, block.number, rec.tickLower, rec.tickUpper);
            }
        }
    }

    function _hasSuspectedJITInRange(PoolId poolId, int24 currentTick) internal view returns (bool) {
        RecentLP[] storage lps = recentLPs[poolId];
        for (uint256 i = 0; i < lps.length; i++) {
            RecentLP storage rec = lps[i];
            if (rec.flagged
                && currentTick >= rec.tickLower
                && currentTick < rec.tickUpper
            ) {
                return true;
            }
        }
        return false;
    }

    // --- Internal: Phase 2 ---

    /// @dev On LP removal, accrue their time-weighted loyalty score and distribute penalty fee share.
    function _removeAndAccrueLoyalty(PoolId poolId, address lp) internal {
        LPPosition storage pos = lpPositions[poolId][lp];
        if (pos.addBlock == 0) return; // No tracked position

        uint256 blocksHeld = block.number - pos.addBlock;

        // Calculate this LP's time-weighted loyalty contribution.
        // For simplicity, we use blocksHeld as the weight (uniform liquidity assumption).
        // In production, this would multiply by actual liquidity amount.
        uint256 loyaltyContribution = blocksHeld;

        if (loyaltyContribution > 0) {
            loyaltyScores[poolId][lp] += loyaltyContribution;
            totalLoyaltyScore[poolId] += loyaltyContribution;

            // Calculate this LP's share of penalty fees
            if (penaltyFeesAccrued[poolId] > 0 && totalLoyaltyScore[poolId] > 0) {
                uint256 share = (penaltyFeesAccrued[poolId] * loyaltyContribution)
                    / totalLoyaltyScore[poolId];
                claimableRebates[lp] += share;
            }
        }

        // Clear position
        pos.addBlock = 0;
        pos.tickLower = 0;
        pos.tickUpper = 0;
    }

    /// @dev Estimate the penalty fee amount from a swap amount and fee rate.
    ///      fee is in ppm (parts per million).
    function _estimatePenaltyFee(uint256 swapAmount, uint24 fee) internal pure returns (uint256) {
        return (swapAmount * fee) / 1_000_000;
    }

    // --- Internal: Phase 3 ---

    /// @dev When a flagged LP (from registry) adds liquidity, immediately mark
    ///      them as suspected so the next large swap triggers penalty.
    function _autoFlagFromRegistry(
        PoolId poolId, address lp, int24 tickLower, int24 tickUpper
    ) internal {
        RecentLP[] storage lps = recentLPs[poolId];
        for (uint256 i = 0; i < lps.length; i++) {
            if (lps[i].lp == lp) {
                lps[i].flagged = true;
                emit JITSuspected(lp, poolId, block.number, tickLower, tickUpper);
                return;
            }
        }
    }
}
