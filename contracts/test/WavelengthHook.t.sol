// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

contract MockPoolManager {
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

/// @dev Test helper replicating WavelengthHook Phase 2 logic.
///      Deployed via vm.etch at valid hook address (0x1A80).
contract WavelengthHookTestHelper {
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

    MockPoolManager public poolManager;
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

    function initialize(
        MockPoolManager _pm, uint256 _threshold, uint256 _window,
        uint24 _baseFee, uint24 _penaltyFee, uint256 _resetDelay
    ) external {
        poolManager = _pm;
        largeSwapThresholdBips = _threshold;
        detectionWindowBlocks = _window;
        baseFee = _baseFee;
        penaltyFee = _penaltyFee;
        penaltyFeeResetDelay = _resetDelay;
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
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(
        address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata
    ) external returns (bytes4, int128, uint24) {
        PoolId poolId = key.toId();

        // Auto-reset penalty fee after delay
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
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
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
            if (rec.flagged && currentTick >= rec.tickLower && currentTick < rec.tickUpper) {
                return true;
            }
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
                uint256 share = (penaltyFeesAccrued[poolId] * blocksHeld)
                    / totalLoyaltyScore[poolId];
                claimableRebates[lp] += share;
            }
        }

        pos.addBlock = 0;
    }
}

contract WavelengthHookTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager mockPM;
    // Hook address: low 14 bits = afterInitialize(1<<12) | beforeAddLiquidity(1<<11) | beforeRemoveLiquidity(1<<9) | beforeSwap(1<<7) = 0x1A80
    address constant HOOK_ADDR = address(0x1A80);
    PoolKey poolKey;
    PoolId poolId;

    event JITSuspected(address indexed lp, PoolId indexed poolId, uint256 blockNumber, int24 tickLower, int24 tickUpper);
    event JITDetected(address indexed lp, PoolId indexed poolId, uint256 blockNumber);
    event PenaltyFeeApplied(PoolId indexed poolId, uint24 fee, uint256 blockNumber);
    event FeeReset(PoolId indexed poolId, uint24 fee, uint256 blockNumber);
    event RebateClaimed(address indexed lp, uint256 amount);

    function setUp() public {
        mockPM = new MockPoolManager();
        WavelengthHookTestHelper helper = new WavelengthHookTestHelper();
        vm.etch(HOOK_ADDR, address(helper).code);
        WavelengthHookTestHelper(HOOK_ADDR).initialize(mockPM, 500, 2, 3000, 30000, 10);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDR)
        });
        poolId = poolKey.toId();
    }

    function _setPoolState(int24 tick, uint128 liquidity) internal {
        mockPM.setPoolState(PoolId.unwrap(poolId), tick, liquidity);
    }

    function _initPool() internal {
        WavelengthHookTestHelper(HOOK_ADDR).afterInitialize(poolKey);
    }

    function _addLiquidity(address sender, int24 tickLower, int24 tickUpper, uint128 liquidityDelta) internal {
        WavelengthHookTestHelper(HOOK_ADDR).beforeAddLiquidity(
            sender, poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int128(liquidityDelta), salt: 0}),
            ""
        );
    }

    function _doSwap(uint256 amountSpecified) internal {
        WavelengthHookTestHelper(HOOK_ADDR).beforeSwap(
            address(this), poolKey,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: int256(uint256(amountSpecified)), sqrtPriceLimitX96: 0}),
            ""
        );
    }

    function _removeLiquidity(address sender, int24 tickLower, int24 tickUpper) internal {
        WavelengthHookTestHelper(HOOK_ADDR).beforeRemoveLiquidity(
            sender, poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: 0}),
            ""
        );
    }

    // ===== PHASE 1 TESTS =====

    function test_normalLP_smallSwap_noJITEvent() public {
        _setPoolState(0, 1_000_000);
        _addLiquidity(address(0xA), -100, 100, 500_000);
        _doSwap(49_999);
        vm.prank(address(0xA));
        _removeLiquidity(address(0xA), -100, 100);
    }

    function test_JITAttack_suspectedAndDetected() public {
        _setPoolState(0, 1_000_000);
        _addLiquidity(address(0xA), -100, 100, 500_000);

        vm.expectEmit(false, false, false, false);
        emit JITSuspected(address(0xA), poolId, block.number, -100, 100);
        _doSwap(50_000);

        vm.expectEmit(false, false, false, false);
        emit JITDetected(address(0xA), poolId, block.number);
        vm.prank(address(0xA));
        _removeLiquidity(address(0xA), -100, 100);
    }

    function test_JITAttack_removedAfterWindow_noDetected() public {
        _setPoolState(0, 1_000_000);
        _addLiquidity(address(0xA), -100, 100, 500_000);

        vm.expectEmit(false, false, false, false);
        emit JITSuspected(address(0xA), poolId, block.number, -100, 100);
        _doSwap(50_000);

        vm.roll(block.number + 3);
        vm.prank(address(0xA));
        _removeLiquidity(address(0xA), -100, 100);
    }

    function test_normalLP_addsBeforeLargeSwap_stays() public {
        _setPoolState(0, 1_000_000);
        _addLiquidity(address(0xA), -100, 100, 500_000);

        vm.expectEmit(false, false, false, false);
        emit JITSuspected(address(0xA), poolId, block.number, -100, 100);
        _doSwap(50_000);
    }

    function test_noTickOverlap_noFlagging() public {
        _setPoolState(0, 1_000_000);
        _addLiquidity(address(0xA), 200, 300, 500_000);
        _doSwap(50_000);
        vm.prank(address(0xA));
        _removeLiquidity(address(0xA), 200, 300);
    }

    function test_feePoke_noTracking() public {
        _setPoolState(0, 1_000_000);
        WavelengthHookTestHelper(HOOK_ADDR).beforeAddLiquidity(
            address(0xB), poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: 0, salt: 0}),
            ""
        );
        _doSwap(50_000);
        vm.prank(address(0xB));
        _removeLiquidity(address(0xB), -100, 100);
    }

    // ===== PHASE 2 TESTS =====

    function test_penaltyFeeApplied_onLargeSwap() public {
        _setPoolState(0, 1_000_000);
        _initPool();
        _addLiquidity(address(0xA), -100, 100, 500_000);

        // Large swap with suspected JIT in range -> penalty fee applied
        vm.expectEmit(false, false, false, false);
        emit PenaltyFeeApplied(poolId, 30000, block.number);
        _doSwap(50_000);

        // Verify fee was updated
        uint24 fee = mockPM.getDynamicFee(PoolId.unwrap(poolId));
        assertEq(fee, 30000);
    }

    function test_noPenaltyFee_onSmallSwap() public {
        _setPoolState(0, 1_000_000);
        _initPool();
        _addLiquidity(address(0xA), -100, 100, 500_000);

        // Small swap — no penalty
        _doSwap(49_999);

        // Fee should still be base
        uint24 fee = mockPM.getDynamicFee(PoolId.unwrap(poolId));
        assertEq(fee, 3000);
    }

    function test_penaltyFeeAutoResets_afterDelay() public {
        _setPoolState(0, 1_000_000);
        _initPool();
        _addLiquidity(address(0xA), -100, 100, 500_000);

        // Trigger penalty
        _doSwap(50_000);
        assertEq(mockPM.getDynamicFee(PoolId.unwrap(poolId)), 30000);

        // Advance past reset delay (10 blocks)
        vm.roll(block.number + 11);

        // Next swap should auto-reset fee
        vm.expectEmit(false, false, false, false);
        emit FeeReset(poolId, 3000, block.number);
        _doSwap(100);

        assertEq(mockPM.getDynamicFee(PoolId.unwrap(poolId)), 3000);
    }

    function test_penaltyFeeApplied_onJITRemoval() public {
        _setPoolState(0, 1_000_000);
        _initPool();
        _addLiquidity(address(0xA), -100, 100, 500_000);

        // Flag Alice
        vm.expectEmit(false, false, false, false);
        emit JITSuspected(address(0xA), poolId, block.number, -100, 100);
        _doSwap(50_000);

        // Alice removes — JIT confirmed, penalty fee applied
        vm.expectEmit(false, false, false, false);
        emit PenaltyFeeApplied(poolId, 30000, block.number);
        vm.prank(address(0xA));
        _removeLiquidity(address(0xA), -100, 100);

        assertEq(mockPM.getDynamicFee(PoolId.unwrap(poolId)), 30000);
    }

    function test_longTermLP_accruesRebate() public {
        _setPoolState(0, 1_000_000);
        _initPool();

        // Bob adds liquidity (long-term LP)
        _addLiquidity(address(0xB), -100, 100, 500_000);

        // Wait 5 blocks, then large swap triggers penalty
        vm.roll(block.number + 5);
        _addLiquidity(address(0xA), -100, 100, 500_000);
        _doSwap(50_000);

        // Bob removes after 10 total blocks of holding
        vm.roll(block.number + 5);
        vm.prank(address(0xB));
        _removeLiquidity(address(0xB), -100, 100);

        // Bob should have accrued a rebate
        uint256 bobRebate = WavelengthHookTestHelper(HOOK_ADDR).claimableRebates(address(0xB));
        assertTrue(bobRebate > 0, "long-term LP should have rebate");
    }

    function test_JITAttacker_minimalRebate() public {
        _setPoolState(0, 1_000_000);
        _initPool();

        // Alice adds (short-term, JIT attacker)
        _addLiquidity(address(0xA), -100, 100, 500_000);

        // Large swap in same block
        _doSwap(50_000);

        // Alice removes immediately (same block) — JIT confirmed
        vm.prank(address(0xA));
        _removeLiquidity(address(0xA), -100, 100);

        // Alice's rebate should be 0 or very small (she was in pool for 0 blocks)
        uint256 aliceRebate = WavelengthHookTestHelper(HOOK_ADDR).claimableRebates(address(0xA));
        assertEq(aliceRebate, 0, "JIT attacker should have zero rebate");
    }

    function test_claimRebate_works() public {
        _setPoolState(0, 1_000_000);
        _initPool();

        _addLiquidity(address(0xB), -100, 100, 500_000);
        vm.roll(block.number + 5);
        _addLiquidity(address(0xA), -100, 100, 500_000);
        _doSwap(50_000);

        vm.roll(block.number + 5);
        vm.prank(address(0xB));
        _removeLiquidity(address(0xB), -100, 100);

        uint256 bobRebate = WavelengthHookTestHelper(HOOK_ADDR).claimableRebates(address(0xB));
        assertTrue(bobRebate > 0);

        vm.expectEmit(false, false, false, false);
        emit RebateClaimed(address(0xB), bobRebate);
        vm.prank(address(0xB));
        WavelengthHookTestHelper(HOOK_ADDR).claimRebate();

        assertEq(WavelengthHookTestHelper(HOOK_ADDR).claimableRebates(address(0xB)), 0);
    }

    function test_claimRebate_revertsWhenNothing() public {
        vm.prank(address(0xC));
        vm.expectRevert("nothing to claim");
        WavelengthHookTestHelper(HOOK_ADDR).claimRebate();
    }
}
