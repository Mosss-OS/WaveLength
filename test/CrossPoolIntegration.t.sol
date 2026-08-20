// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ReactiveTest} from "reactive-test-lib/base/ReactiveTest.sol";
import {ReactiveSimulator} from "reactive-test-lib/simulator/ReactiveSimulator.sol";
import {LogRecord, CallbackResult} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WavelengthHook} from "../contracts/WavelengthHook.sol";
import {JITRiskRegistry} from "../contracts/JITRiskRegistry.sol";
import {JITRiskCallback} from "../contracts/JITRiskCallback.sol";
import {ReactiveJITListener} from "../contracts/ReactiveJITListener.sol";
import {LiquidityAgent} from "./WavelengthHook.t.sol";

contract CrossPoolIntegrationTest is ReactiveTest, Deployers {
    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;
    int256 constant LIQUIDITY_1E18 = 1e18;
    int256 constant LARGE_SWAP = -100000e18;
    uint24 constant BASE_FEE = 3000;
    uint24 constant PENALTY_FEE = 30000;
    uint256 constant LARGE_SWAP_THRESHOLD = 1000e18;
    uint32 constant DETECTION_WINDOW = 100;
    uint256 constant ORIGIN_CHAIN = 31337;

    bytes32 constant JIT_DETECTED_TOPIC =
        keccak256("JITDetected(bytes32,address,uint256,uint24,uint256)");

    WavelengthHook hook;
    JITRiskRegistry registry;
    JITRiskCallback callback;
    ReactiveJITListener listener;
    LiquidityAgent user;
    LiquidityAgent attacker;
    address swapper;
    PoolKey keyA;
    PoolKey keyB;
    PoolId poolAId;
    PoolId poolBId;

    function setUp() public override {
        ReactiveTest.setUp();
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        registry = new JITRiskRegistry();
        callback = new JITRiskCallback(address(proxy), registry);
        registry.setAuthorized(address(callback));

        user = new LiquidityAgent(IPoolManager(manager));
        attacker = new LiquidityAgent(IPoolManager(manager));
        swapper = makeAddr("swapper");

        hook = _deployHook();
        (keyA, poolAId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        (keyB, poolBId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, SQRT_PRICE_1_1);

        listener = new ReactiveJITListener(ORIGIN_CHAIN, ORIGIN_CHAIN, address(hook), address(callback), 100, 1 hours, 0);
        enableVmMode(address(listener));

        vm.label(address(user), "userAgent");
        vm.label(address(attacker), "attackerAgent");
    }

    function test_jitOnPoolAPropagatesToPenalizeOnPoolB() public {
        _addLiquidity(user, keyA, LIQUIDITY_1E18);
        _addLiquidity(attacker, keyA, LIQUIDITY_1E18);
        _swap(swapper, keyA, LARGE_SWAP);

        vm.recordLogs();
        _removeLiquidity(attacker, keyA, LIQUIDITY_1E18);
        Vm.Log memory jitLog = _findJitLog();
        assertEq(jitLog.topics[0], JIT_DETECTED_TOPIC);

        _deliverToReactive(jitLog);

        (uint256 riskScore,,,) = registry.riskOf(address(attacker));
        assertGt(riskScore, 0, "attacker should be flagged in the registry via the reactive callback");

        _addLiquidity(attacker, keyB, LIQUIDITY_1E18);
        _swap(swapper, keyB, LARGE_SWAP);
        _removeLiquidity(attacker, keyB, LIQUIDITY_1E18);

        assertGt(
            hook.totalRedistributed(poolBId), 0, "Pool B should penalize the flagged address on its first interaction"
        );
    }

    function _deployHook() internal returns (WavelengthHook) {
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            FLAGS,
            type(WavelengthHook).creationCode,
            abi.encode(address(manager), address(registry), BASE_FEE, PENALTY_FEE, LARGE_SWAP_THRESHOLD, DETECTION_WINDOW)
        );
        WavelengthHook h = new WavelengthHook{salt: salt}(
            IPoolManager(manager), address(registry), BASE_FEE, PENALTY_FEE, LARGE_SWAP_THRESHOLD, DETECTION_WINDOW
        );
        assertEq(address(h), hookAddress);
        return h;
    }

    function _deliverToReactive(Vm.Log memory log) internal {
        LogRecord memory rec = LogRecord({
            chain_id: ORIGIN_CHAIN,
            _contract: log.emitter,
            topic_0: uint256(log.topics[0]),
            topic_1: uint256(log.topics[1]),
            topic_2: uint256(log.topics[2]),
            topic_3: log.topics.length > 3 ? uint256(log.topics[3]) : 0,
            data: log.data,
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        CallbackResult[] memory results = ReactiveSimulator.deliverEvent(vm, rec, sys, proxy, rvmId, reactiveChainId);
        assertGt(results.length, 0, "expected a reactive callback");
        assertTrue(results[0].success, "reactive callback failed");
    }

    function _findJitLog() internal returns (Vm.Log memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == JIT_DETECTED_TOPIC) return logs[i];
        }
        revert("no JITDetected log");
    }

    function _fundAgent(LiquidityAgent agent) internal {
        MockERC20(Currency.unwrap(currency0)).mint(address(agent), 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(address(agent), 1e30);
        vm.startPrank(address(agent));
        MockERC20(Currency.unwrap(currency0)).approve(address(manager), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    function _addLiquidity(LiquidityAgent agent, PoolKey memory key_, int256 liquidity) internal {
        _fundAgent(agent);
        vm.prank(address(agent));
        agent.modifyLiquidity(key_, TICK_LOWER, TICK_UPPER, liquidity, "");
    }

    function _removeLiquidity(LiquidityAgent agent, PoolKey memory key_, int256 liquidity) internal {
        vm.prank(address(agent));
        agent.modifyLiquidity(key_, TICK_LOWER, TICK_UPPER, -liquidity, "");
    }

    function _swap(address who, PoolKey memory key_, int256 amount) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(who, 1e30);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        swap(key_, true, amount, ZERO_BYTES);
        vm.stopPrank();
    }
}
