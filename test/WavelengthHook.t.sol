// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookTest} from "uniswap-hooks-test/utils/HookTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "uniswap-hooks/utils/CurrencySettler.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WavelengthHook} from "../contracts/WavelengthHook.sol";
import {JITRiskRegistry} from "../contracts/JITRiskRegistry.sol";

contract LiquidityAgent is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function modifyLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity,
        bytes calldata hookData
    ) external returns (bytes memory) {
        return poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidity, hookData));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "unauthorized");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity, bytes memory hookData) =
            abi.decode(rawData, (PoolKey, int24, int24, int256, bytes));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: bytes32(0)}),
            hookData
        );

        if (delta.amount0() > 0) {
            poolManager.take(key.currency0, address(this), uint256(int256(delta.amount0())));
        } else if (delta.amount0() < 0) {
            CurrencySettler.settle(key.currency0, poolManager, address(this), uint256(-int256(delta.amount0())), false);
        }
        if (delta.amount1() > 0) {
            poolManager.take(key.currency1, address(this), uint256(int256(delta.amount1())));
        } else if (delta.amount1() < 0) {
            CurrencySettler.settle(key.currency1, poolManager, address(this), uint256(-int256(delta.amount1())), false);
        }

        return rawData;
    }
}

contract WavelengthHookTest is HookTest {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;
    int256 constant LIQUIDITY_1E18 = 1e18;
    int256 constant LARGE_SWAP = -100000e18;
    uint24 constant BASE_FEE = 3000;
    uint24 constant PENALTY_FEE = 30000;
    uint256 constant LARGE_SWAP_THRESHOLD = 1000e18;
    uint32 constant DETECTION_WINDOW = 100;

    WavelengthHook hook;
    JITRiskRegistry registry;
    LiquidityAgent user;
    LiquidityAgent attacker;
    address swapper;
    PoolId poolId;

    bytes32 internal constant JIT_DETECTED_TOPIC =
        keccak256("JITDetected(bytes32,address,uint256,uint24,uint256)");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        registry = new JITRiskRegistry();
        user = new LiquidityAgent(IPoolManager(manager));
        attacker = new LiquidityAgent(IPoolManager(manager));
        swapper = makeAddr("swapper");

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(WavelengthHook).creationCode,
            abi.encode(address(manager), address(registry), BASE_FEE, PENALTY_FEE, LARGE_SWAP_THRESHOLD, DETECTION_WINDOW)
        );
        hook = new WavelengthHook{salt: salt}(
            IPoolManager(manager), address(registry), BASE_FEE, PENALTY_FEE, LARGE_SWAP_THRESHOLD, DETECTION_WINDOW
        );
        assertEq(address(hook), hookAddress);

        (key, poolId) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        vm.label(address(user), "userAgent");
        vm.label(address(attacker), "attackerAgent");
    }

    function _fundAgent(LiquidityAgent agent) internal {
        MockERC20(Currency.unwrap(currency0)).mint(address(agent), 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(address(agent), 1e30);
        vm.startPrank(address(agent));
        MockERC20(Currency.unwrap(currency0)).approve(address(manager), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    function _addLiquidity(LiquidityAgent agent, int256 liquidity) internal {
        _fundAgent(agent);
        vm.prank(address(agent));
        agent.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, liquidity, "");
    }

    function _removeLiquidity(LiquidityAgent agent, int256 liquidity) internal {
        vm.prank(address(agent));
        agent.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, -liquidity, "");
    }

    function _swap(address who, int256 amount) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(who, 1e30);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        swap(key, true, amount, ZERO_BYTES);
        vm.stopPrank();
    }

    function _assertJitDetectedFor(address who) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == JIT_DETECTED_TOPIC) {
                if (address(uint160(uint256(logs[i].topics[2]))) == who) {
                    found = true;
                    break;
                }
            }
        }
        assertTrue(found, "JITDetected not emitted for the LP");
    }

    function test_constructorAndInitialization() public {
        assertEq(hook.baseFeeBps(), BASE_FEE);
        assertEq(hook.penaltyFeeBps(), PENALTY_FEE);
        (,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, BASE_FEE);
        PoolKey memory registered = hook.getPoolKey(poolId);
        assertEq(registered.tickSpacing, key.tickSpacing);
    }

    function test_jitAttackIsDetectedAndPenalized() public {
        _addLiquidity(user, LIQUIDITY_1E18);
        _addLiquidity(attacker, LIQUIDITY_1E18);
        _swap(swapper, LARGE_SWAP);

        uint256 redistributedBefore = hook.totalRedistributed(poolId);

        vm.recordLogs();
        _removeLiquidity(attacker, LIQUIDITY_1E18);
        _assertJitDetectedFor(address(attacker));

        assertGt(hook.totalRedistributed(poolId), redistributedBefore, "penalty not redistributed");
    }

    function test_jitAttackerHasNoClaimableRebate() public {
        _addLiquidity(user, LIQUIDITY_1E18);
        _addLiquidity(attacker, LIQUIDITY_1E18);
        _swap(swapper, LARGE_SWAP);
        _removeLiquidity(attacker, LIQUIDITY_1E18);

        assertEq(hook.pendingRebate(poolId, address(attacker)), 0, "attacker should not earn rebates");
    }

    function test_longTermLpGetsRebateAndCanClaim() public {
        _addLiquidity(user, LIQUIDITY_1E18);
        vm.roll(block.number + 50);

        _addLiquidity(attacker, LIQUIDITY_1E18);
        _swap(swapper, LARGE_SWAP);
        _removeLiquidity(attacker, LIQUIDITY_1E18);

        uint256 pending = hook.pendingRebate(poolId, address(user));
        assertGt(pending, 0, "loyal LP should have claimable rebate");

        uint256 balance0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(user));
        vm.prank(address(user));
        hook.claimRebate(poolId);
        uint256 balance0After = MockERC20(Currency.unwrap(currency0)).balanceOf(address(user));
        assertGt(balance0After - balance0Before, 0, "claim should pay out tokens");
        assertEq(hook.pendingRebate(poolId, address(user)), 0, "pending cleared after claim");
    }

    function test_noPenaltyAfterDetectionWindow() public {
        _addLiquidity(user, LIQUIDITY_1E18);
        vm.roll(block.number + DETECTION_WINDOW + 10);
        _swap(swapper, LARGE_SWAP);
        _removeLiquidity(user, LIQUIDITY_1E18);

        assertEq(hook.totalRedistributed(poolId), 0, "no penalty for long-term LP");
    }

    function test_registryFlaggedLpIsPenalized() public {
        registry.flag(address(attacker), 100, 1 hours, 31337, bytes32("attacker-pool"));

        _addLiquidity(user, LIQUIDITY_1E18);
        _addLiquidity(attacker, LIQUIDITY_1E18);
        _swap(swapper, LARGE_SWAP);
        _removeLiquidity(attacker, LIQUIDITY_1E18);

        assertGt(hook.totalRedistributed(poolId), 0, "flagged attacker penalized");
    }
}
