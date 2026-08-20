// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ReactiveTest} from "reactive-test-lib/base/ReactiveTest.sol";
import {ReactiveConstants} from "reactive-test-lib/constants/ReactiveConstants.sol";
import {CallbackResult} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {JITRiskRegistry} from "../contracts/JITRiskRegistry.sol";
import {JITRiskCallback} from "../contracts/JITRiskCallback.sol";
import {ReactiveJITListener} from "../contracts/ReactiveJITListener.sol";

contract MockJitOrigin {
    event JITDetected(
        bytes32 indexed poolId, address indexed lp, uint256 blockNumber, uint24 penaltyFeeBps, uint256 penaltyAmount
    );

    function emitJit(address lp, bytes32 poolId) external {
        emit JITDetected(poolId, lp, block.number, 30000, 1e18);
    }
}

contract ReactiveJITListenerTest is ReactiveTest {
    JITRiskRegistry registry;
    JITRiskCallback callback;
    ReactiveJITListener listener;
    MockJitOrigin origin;

    uint256 internal constant ORIGIN_CHAIN = 31337;
    uint256 internal constant RISK_SCORE = 100;
    uint256 internal constant FLAG_DURATION = 1 hours;
    address internal constant LP = address(0x1234);
    bytes32 internal constant POOL_ID = bytes32("pool");

    bytes32 internal constant CALLBACK_TOPIC =
        0x8dd725fa9d6cd150017ab9e60318d40616439424e2fade9c1c58854950917dfc;

    function setUp() public override {
        ReactiveTest.setUp();

        registry = new JITRiskRegistry();
        callback = new JITRiskCallback(address(proxy), registry);
        registry.setAuthorized(address(callback));
        origin = new MockJitOrigin();
        listener = new ReactiveJITListener(ORIGIN_CHAIN, ORIGIN_CHAIN, address(origin), address(callback), RISK_SCORE, FLAG_DURATION, 0);
        enableVmMode(address(listener));
        registerChain(address(origin), ORIGIN_CHAIN);
    }

    function test_jitDetectedFlagsLpOnRegistry() public {
        CallbackResult[] memory results = triggerAndReact(address(origin), abi.encodeCall(MockJitOrigin.emitJit, (LP, POOL_ID)));
        assertCallbackCount(results, 1);
        assertCallbackSuccess(results, 0);

        (uint256 riskScore, uint256 expiresAt, uint256 originChainId, bytes32 originPoolId) = registry.riskOf(LP);
        assertEq(riskScore, RISK_SCORE);
        assertEq(originChainId, ORIGIN_CHAIN);
        assertEq(originPoolId, POOL_ID);
        assertGt(expiresAt, block.timestamp);
    }

    function test_cronTriggersDecayOfExpiredFlags() public {
        vm.prank(address(callback));
        registry.flag(LP, RISK_SCORE, FLAG_DURATION, ORIGIN_CHAIN, POOL_ID);
        vm.warp(block.timestamp + 2 hours);

        IReactive.LogRecord memory cronLog = IReactive.LogRecord({
            chain_id: ReactiveConstants.REACTIVE_CHAIN_ID,
            _contract: address(ReactiveConstants.SERVICE_ADDR),
            topic_0: ReactiveConstants.CRON_TOPIC_1000,
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(block.number),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.recordLogs();
        vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        listener.react(cronLog);

        (bytes memory payload, uint64 gasLimit) = _extractCallbackPayload(vm.getRecordedLogs());

        (bool ok,) = proxy.executeCallback(address(callback), payload, gasLimit, rvmId);
        assertTrue(ok, "cron decay callback failed");

        (uint256 riskScore,,,) = registry.riskOf(LP);
        assertEq(riskScore, 0, "expired flag should be decayed");
    }

    function test_unexpiredFlagSurvivesCronDecay() public {
        vm.prank(address(callback));
        registry.flag(LP, RISK_SCORE, FLAG_DURATION, ORIGIN_CHAIN, POOL_ID);
        vm.warp(block.timestamp + 30 minutes);

        IReactive.LogRecord memory cronLog = IReactive.LogRecord({
            chain_id: ReactiveConstants.REACTIVE_CHAIN_ID,
            _contract: address(ReactiveConstants.SERVICE_ADDR),
            topic_0: ReactiveConstants.CRON_TOPIC_1000,
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(block.number),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.recordLogs();
        vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        listener.react(cronLog);

        (bytes memory payload, uint64 gasLimit) = _extractCallbackPayload(vm.getRecordedLogs());

        (bool ok,) = proxy.executeCallback(address(callback), payload, gasLimit, rvmId);
        assertTrue(ok, "cron decay callback failed");

        (uint256 riskScore,,,) = registry.riskOf(LP);
        assertEq(riskScore, RISK_SCORE, "unexpired flag should survive decay");
    }

    function _extractCallbackPayload(Vm.Log[] memory logs) internal pure returns (bytes memory payload, uint64 gasLimit) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == CALLBACK_TOPIC) {
                return (abi.decode(logs[i].data, (bytes)), uint64(uint256(logs[i].topics[3])));
            }
        }
        revert("no Callback emitted");
    }
}
