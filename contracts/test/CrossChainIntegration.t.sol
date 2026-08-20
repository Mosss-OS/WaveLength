// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {JITRiskRegistry} from "../src/JITRiskRegistry.sol";

/// @dev Simplified mock pool manager for cross-chain integration testing.
contract MockPoolManager2 {
    using PoolIdLibrary for PoolKey;
    struct PoolState { int24 currentTick; uint128 liquidity; uint24 lpFee; }
    mapping(bytes32 => PoolState) public poolStates;
    mapping(bytes32 => uint24) public dynamicFees;

    function setPoolState(bytes32 poolId, int24 currentTick, uint128 liquidity) external {
        poolStates[poolId] = PoolState(currentTick, liquidity, 0);
    }
    function getSlot0(address, bytes32 poolId) external view returns (uint160, int24, uint24, uint24) {
        PoolState memory s = poolStates[poolId];
        return (0, s.currentTick, 0, 0);
    }
    function getLiquidity(address, bytes32 poolId) external view returns (uint128) {
        return poolStates[poolId].liquidity;
    }
    function updateDynamicLPFee(PoolKey calldata key, uint24 newFee) external {
        dynamicFees[PoolId.unwrap(key.toId())] = newFee;
    }
    function getDynamicFee(bytes32 poolId) external view returns (uint24) {
        return dynamicFees[poolId];
    }
}

/// @dev Test helper that mirrors WavelengthHook Phase 3 logic with registry integration.
///      Deployed via vm.etch at a valid hook address.
contract WavelengthHookPhase3Helper {
    uint256 public constant MAX_RECENT_LPS = 50;

    event JITSuspected(address indexed lp, PoolId indexed poolId, uint256 blockNumber, int24 tickLower, int24 tickUpper);
    event JITDetected(address indexed lp, PoolId indexed poolId, uint256 blockNumber);
    event PenaltyFeeApplied(PoolId indexed poolId, uint24 fee, uint256 blockNumber);
    event FeeReset(PoolId indexed poolId, uint24 fee, uint256 blockNumber);
    event RebateClaimed(address indexed lp, uint256 amount);

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

    MockPoolManager2 public poolManager;
    uint256 public largeSwapThresholdBips;
    uint256 public detectionWindowBlocks;
    uint24 public baseFee;
    uint24 public penaltyFee;
    uint256 public penaltyFeeResetDelay;

    mapping(PoolId => RecentLP[]) public recentLPs;
    mapping(PoolId => mapping(address => LPPosition)) public lpPositions;
    mapping(PoolId => mapping(address => uint256)) public loyaltyScores;
    mapping(PoolId => uint256) public totalLoyaltyScore;
    mapping(PoolId => uint256) public penaltyFeesAccrued;
    mapping(address => uint256) public claimableRebates;
    mapping(PoolId => uint256) public penaltyFeeAppliedBlock;

    // Phase 3: cross-chain risk registry
    JITRiskRegistry public jitRiskRegistry;

    function initialize(
        MockPoolManager2 _pm, uint256 _threshold, uint256 _window,
        uint24 _baseFee, uint24 _penaltyFee, uint256 _resetDelay
    ) external {
        poolManager = _pm;
        largeSwapThresholdBips = _threshold;
        detectionWindowBlocks = _window;
        baseFee = _baseFee;
        penaltyFee = _penaltyFee;
        penaltyFeeResetDelay = _resetDelay;
    }

    function setRiskRegistry(JITRiskRegistry _registry) external {
        jitRiskRegistry = _registry;
    }

    function afterInitialize(PoolKey calldata key) external returns (bytes4) {
        poolManager.updateDynamicLPFee(key, baseFee);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata
    ) external returns (bytes4) {
        PoolId poolId = key.toId();
        if (params.liquidityDelta > 0) {
            _addRecentLP(poolId, sender, params.tickLower, params.tickUpper);
            lpPositions[poolId][sender] = LPPosition({
                addBlock: block.number, tickLower: params.tickLower, tickUpper: params.tickUpper
            });

            // Phase 3: check registry
            if (address(jitRiskRegistry) != address(0)) {
                if (jitRiskRegistry.isCurrentlyFlagged(sender)) {
                    _autoFlagFromRegistry(poolId, sender, params.tickLower, params.tickUpper);
                }
            }
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(
        address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata
    ) external returns (bytes4, int128, uint24) {
        PoolId poolId = key.toId();
        if (penaltyFeeAppliedBlock[poolId] > 0
            && block.number >= penaltyFeeAppliedBlock[poolId] + penaltyFeeResetDelay
        ) {
            poolManager.updateDynamicLPFee(key, baseFee);
            penaltyFeeAppliedBlock[poolId] = 0;
            emit FeeReset(poolId, baseFee, block.number);
        }

        (, int24 currentTick,,) = poolManager.getSlot0(address(poolManager), PoolId.unwrap(poolId));
        uint128 liquidity = poolManager.getLiquidity(address(poolManager), PoolId.unwrap(poolId));

        uint256 absAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 threshold = (uint256(liquidity) * largeSwapThresholdBips) / 10_000;

        if (absAmount >= threshold && liquidity > 0) {
            _flagSuspectedJIT(poolId, currentTick);
            if (_hasSuspectedJITInRange(poolId, currentTick)) {
                poolManager.updateDynamicLPFee(key, penaltyFee);
                penaltyFeesAccrued[poolId] += (absAmount * penaltyFee) / 1_000_000;
                penaltyFeeAppliedBlock[poolId] = block.number;
                emit PenaltyFeeApplied(poolId, penaltyFee, block.number);
            }
        }
        return (IHooks.beforeSwap.selector, 0, 0);
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
        if (isJIT) {
            poolManager.updateDynamicLPFee(key, penaltyFee);
            penaltyFeeAppliedBlock[poolId] = block.number;
            emit PenaltyFeeApplied(poolId, penaltyFee, block.number);
        }
        _removeAndAccrueLoyalty(poolId, sender);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function claimRebate() external {
        uint256 amount = claimableRebates[msg.sender];
        require(amount > 0, "nothing to claim");
        claimableRebates[msg.sender] = 0;
        emit RebateClaimed(msg.sender, amount);
    }

    // --- Internal ---
    function _addRecentLP(PoolId poolId, address lp, int24 tickLower, int24 tickUpper) internal {
        RecentLP[] storage lps = recentLPs[poolId];
        uint256 pruneBefore = block.number > detectionWindowBlocks + 10
            ? block.number - detectionWindowBlocks - 10 : 0;
        uint256 writeIdx = 0;
        for (uint256 i = 0; i < lps.length; i++) {
            if (lps[i].blockNumber >= pruneBefore) {
                if (writeIdx != i) lps[writeIdx] = lps[i];
                writeIdx++;
            }
        }
        while (lps.length > writeIdx) lps.pop();
        if (lps.length < MAX_RECENT_LPS) {
            lps.push(RecentLP({lp: lp, blockNumber: block.number, tickLower: tickLower, tickUpper: tickUpper, flagged: false}));
        }
    }

    function _flagSuspectedJIT(PoolId poolId, int24 currentTick) internal {
        RecentLP[] storage lps = recentLPs[poolId];
        for (uint256 i = 0; i < lps.length; i++) {
            RecentLP storage rec = lps[i];
            if (!rec.flagged && currentTick >= rec.tickLower && currentTick < rec.tickUpper
                && block.number <= rec.blockNumber + detectionWindowBlocks) {
                rec.flagged = true;
                emit JITSuspected(rec.lp, poolId, block.number, rec.tickLower, rec.tickUpper);
            }
        }
    }

    function _hasSuspectedJITInRange(PoolId poolId, int24 currentTick) internal view returns (bool) {
        RecentLP[] storage lps = recentLPs[poolId];
        for (uint256 i = 0; i < lps.length; i++) {
            RecentLP storage rec = lps[i];
            if (rec.flagged && currentTick >= rec.tickLower && currentTick < rec.tickUpper) return true;
        }
        return false;
    }

    function _removeAndAccrueLoyalty(PoolId poolId, address lp) internal {
        LPPosition storage pos = lpPositions[poolId][lp];
        if (pos.addBlock == 0) return;
        uint256 blocksHeld = block.number - pos.addBlock;
        if (blocksHeld > 0) {
            loyaltyScores[poolId][lp] += blocksHeld;
            totalLoyaltyScore[poolId] += blocksHeld;
            if (penaltyFeesAccrued[poolId] > 0 && totalLoyaltyScore[poolId] > 0) {
                uint256 share = (penaltyFeesAccrued[poolId] * blocksHeld) / totalLoyaltyScore[poolId];
                claimableRebates[lp] += share;
            }
        }
        pos.addBlock = 0;
    }

    function _autoFlagFromRegistry(PoolId poolId, address lp, int24 tickLower, int24 tickUpper) internal {
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

/// @dev Integration test: JIT event on Pool A → registry updated → penalized on Pool B
contract WavelengthCrossChainIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager2 mockPM;
    JITRiskRegistry registry;

    // Two separate hooks at different addresses (simulating two pools)
    address constant HOOK_A = address(0x1A80);
    address constant HOOK_B = address(0x2A80);

    PoolKey poolKeyA;
    PoolKey poolKeyB;
    PoolId poolIdA;
    PoolId poolIdB;

    event PenaltyFeeApplied(PoolId indexed poolId, uint24 fee, uint256 blockNumber);

    function setUp() public {
        mockPM = new MockPoolManager2();
        registry = new JITRiskRegistry(100); // 100 block cooldown

        // Deploy Hook A
        WavelengthHookPhase3Helper helperA = new WavelengthHookPhase3Helper();
        vm.etch(HOOK_A, address(helperA).code);
        WavelengthHookPhase3Helper(HOOK_A).initialize(mockPM, 500, 2, 3000, 30000, 10);
        WavelengthHookPhase3Helper(HOOK_A).setRiskRegistry(registry);

        // Deploy Hook B
        WavelengthHookPhase3Helper helperB = new WavelengthHookPhase3Helper();
        vm.etch(HOOK_B, address(helperB).code);
        WavelengthHookPhase3Helper(HOOK_B).initialize(mockPM, 500, 2, 3000, 30000, 10);
        WavelengthHookPhase3Helper(HOOK_B).setRiskRegistry(registry);

        // Configure registry
        registry.setReactiveContract(address(0xA2));

        // Pool A: ETH/USDC on Hook A
        poolKeyA = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_A)
        });
        poolIdA = poolKeyA.toId();

        // Pool B: ETH/DAI on Hook B
        poolKeyB = PoolKey({
            currency0: Currency.wrap(address(3)),
            currency1: Currency.wrap(address(4)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_B)
        });
        poolIdB = poolKeyB.toId();
    }

    function _setPoolState(address hook, bytes32 poolId, int24 tick, uint128 liquidity) internal {
        mockPM.setPoolState(poolId, tick, liquidity);
    }

    // ===== INTEGRATION TESTS =====

    /// @notice Full flow: JIT attack on Pool A → registry flags attacker →
    ///         attacker tries Pool B → penalized immediately without direct observation.
    function test_fullCrossChainFlow() public {
        // Setup: Pool A has liquidity, Pool B has liquidity
        _setPoolState(HOOK_A, PoolId.unwrap(poolIdA), 0, 1_000_000);
        _setPoolState(HOOK_B, PoolId.unwrap(poolIdB), 0, 1_000_000);

        // === Step 1: Normal LP on Pool A ===
        WavelengthHookPhase3Helper(HOOK_A).afterInitialize(poolKeyA);
        WavelengthHookPhase3Helper(HOOK_A).beforeAddLiquidity(
            address(0xB), poolKeyA,
            IPoolManager.ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: 500_000, salt: 0}),
            ""
        );

        // === Step 2: Attacker JIT on Pool A ===
        WavelengthHookPhase3Helper(HOOK_A).beforeAddLiquidity(
            address(0xA), poolKeyA,
            IPoolManager.ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: 500_000, salt: 0}),
            ""
        );

        // Large swap triggers JIT detection
        WavelengthHookPhase3Helper(HOOK_A).beforeSwap(
            address(this), poolKeyA,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 50_000, sqrtPriceLimitX96: 0}),
            ""
        );

        // Attacker removes — JIT confirmed
        vm.expectEmit(false, false, false, false);
        emit JITDetected(address(0xA), poolIdA, block.number);
        vm.prank(address(0xA));
        WavelengthHookPhase3Helper(HOOK_A).beforeRemoveLiquidity(
            address(0xA), poolKeyA,
            IPoolManager.ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: 0, salt: 0}),
            ""
        );

        // === Step 3: Simulate Reactive Network callback ===
        // In production, the RSC would detect JITDetected and call registry.setRiskFlag.
        // We simulate this manually.
        vm.prank(address(0xA2)); // authorizedReactiveContract
        registry.setRiskFlag(address(0xA), 84532, HOOK_A, block.number);

        assertTrue(registry.isCurrentlyFlagged(address(0xA)));

        // === Step 4: Attacker tries Pool B — should be penalized on first interaction ===
        WavelengthHookPhase3Helper(HOOK_B).afterInitialize(poolKeyB);

        // Attacker adds liquidity to Pool B — registry auto-flags them
        vm.expectEmit(false, false, false, false);
        emit JITSuspected(address(0xA), poolIdB, block.number, -100, 100);
        WavelengthHookPhase3Helper(HOOK_B).beforeAddLiquidity(
            address(0xA), poolKeyB,
            IPoolManager.ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: 500_000, salt: 0}),
            ""
        );

        // Any large swap on Pool B now triggers penalty because attacker is pre-flagged
        vm.expectEmit(false, false, false, false);
        emit PenaltyFeeApplied(poolIdB, 30000, block.number);
        WavelengthHookPhase3Helper(HOOK_B).beforeSwap(
            address(this), poolKeyB,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 50_000, sqrtPriceLimitX96: 0}),
            ""
        );

        // Verify penalty fee was applied on Pool B
        uint24 fee = mockPM.getDynamicFee(PoolId.unwrap(poolIdB));
        assertEq(fee, 30000);
    }

    /// @notice Registry flag expires after cooldown — attacker can use Pool B normally.
    function test_flagExpiry_allowsNormalUse() public {
        _setPoolState(HOOK_B, PoolId.unwrap(poolIdB), 0, 1_000_000);

        // Flag attacker in registry
        vm.prank(address(0xA2));
        registry.setRiskFlag(address(0xA), 84532, HOOK_A, block.number);

        // Roll past cooldown
        vm.roll(block.number + 101);

        // Registry flag should be expired
        assertFalse(registry.isCurrentlyFlagged(address(0xA)));

        // Attacker adds to Pool B — should NOT be auto-flagged from registry
        WavelengthHookPhase3Helper(HOOK_B).afterInitialize(poolKeyB);
        WavelengthHookPhase3Helper(HOOK_B).beforeAddLiquidity(
            address(0xA), poolKeyB,
            IPoolManager.ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: 500_000, salt: 0}),
            ""
        );

        // Small swap — no JIT detection trigger, no registry flag
        WavelengthHookPhase3Helper(HOOK_B).beforeSwap(
            address(this), poolKeyB,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: 0}),
            ""
        );

        uint24 fee = mockPM.getDynamicFee(PoolId.unwrap(poolIdB));
        assertEq(fee, 3000); // Base fee, no penalty
    }

    /// @notice Normal LP on Pool B is NOT affected by registry — only flagged addresses.
    function test_normalLP_notAffectedByRegistry() public {
        _setPoolState(HOOK_B, PoolId.unwrap(poolIdB), 0, 1_000_000);

        // Flag a different address (0xA) — NOT 0xC
        vm.prank(address(0xA2));
        registry.setRiskFlag(address(0xA), 84532, HOOK_A, block.number);

        // Normal LP (0xC) adds to Pool B
        WavelengthHookPhase3Helper(HOOK_B).afterInitialize(poolKeyB);
        WavelengthHookPhase3Helper(HOOK_B).beforeAddLiquidity(
            address(0xC), poolKeyB,
            IPoolManager.ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: 500_000, salt: 0}),
            ""
        );

        // Roll past detection window so 0xC is no longer "suspected"
        vm.roll(block.number + 3);

        // Large swap — 0xC is NOT in the recent LP window, not flagged in registry
        WavelengthHookPhase3Helper(HOOK_B).beforeSwap(
            address(this), poolKeyB,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 50_000, sqrtPriceLimitX96: 0}),
            ""
        );

        uint24 fee = mockPM.getDynamicFee(PoolId.unwrap(poolIdB));
        assertEq(fee, 3000); // Base fee — no penalty for clean LP
    }

    event JITDetected(address indexed lp, PoolId indexed poolId, uint256 blockNumber);
    event JITSuspected(address indexed lp, PoolId indexed poolId, uint256 blockNumber, int24 tickLower, int24 tickUpper);
}
