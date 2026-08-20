// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

/// @title ReactiveJITListener
/// @notice Reactive Smart Contract deployed on Reactive Network.
///         Subscribes to JITDetected events from WavelengthHook instances
///         on origin chains and sends callbacks to JITRiskRegistry on
///         destination chains.
contract ReactiveJITListener is AbstractReactive {
    uint64 private constant CALLBACK_GAS_LIMIT = 500_000;

    // Origin chain => monitored hook addresses
    mapping(uint256 => address[]) public originHooks;

    // Origin chain => hook => is monitored
    mapping(uint256 => mapping(address => bool)) public isMonitored;

    // Destination chain => JITRiskRegistry address
    mapping(uint256 => address) public registries;

    // The JITDetected event topic: event JITDetected(address indexed lp, PoolId indexed poolId, uint256 blockNumber)
    // keccak256("JITDetected(address,bytes32,uint256)")
    bytes32 public constant JIT_DETECTED_TOPIC =
        keccak256("JITDetected(address,bytes32,uint256)");

    address public owner;

    event HookAdded(uint256 indexed originChainId, address indexed hook);
    event HookRemoved(uint256 indexed originChainId, address indexed hook);
    event RegistrySet(uint256 indexed destChainId, address indexed registry);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Register a WavelengthHook to monitor on a given origin chain.
    ///         Called off-chain or via callback after deployment.
    /// @param originChainId The chain where the hook is deployed
    /// @param hookAddress The WavelengthHook contract address
    function addHook(uint256 originChainId, address hookAddress) external onlyOwner {
        if (!isMonitored[originChainId][hookAddress]) {
            originHooks[originChainId].push(hookAddress);
            isMonitored[originChainId][hookAddress] = true;

            // Subscribe on Reactive Network (only works when called on RNK, not in ReactVM)
            if (!vm) {
                service.subscribe(
                    originChainId,
                    hookAddress,
                    uint256(JIT_DETECTED_TOPIC),
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
            }

            emit HookAdded(originChainId, hookAddress);
        }
    }

    /// @notice Remove a hook from monitoring.
    function removeHook(uint256 originChainId, address hookAddress) external onlyOwner {
        if (isMonitored[originChainId][hookAddress]) {
            isMonitored[originChainId][hookAddress] = false;

            if (!vm) {
                service.unsubscribe(
                    originChainId,
                    hookAddress,
                    uint256(JIT_DETECTED_TOPIC),
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
            }

            emit HookRemoved(originChainId, hookAddress);
        }
    }

    /// @notice Set the JITRiskRegistry address for a destination chain.
    function setRegistry(uint256 destChainId, address registry) external onlyOwner {
        registries[destChainId] = registry;
        emit RegistrySet(destChainId, registry);
    }

    /// @notice React to a JITDetected event from any monitored hook.
    ///         Decodes the event and sends a callback to the destination
    ///         chain's JITRiskRegistry.
    function react(LogRecord calldata log) external vmOnly {
        // Only process JITDetected events
        if (log.topic_0 != uint256(JIT_DETECTED_TOPIC)) return;

        // Decode the event
        // JITDetected(address indexed lp, PoolId indexed poolId, uint256 blockNumber)
        // topic_1 = lp (indexed, left-padded to uint256)
        // topic_2 = poolId (indexed, left-padded to uint256)
        // data = blockNumber (uint256, ABI-encoded)
        address attacker = address(uint160(log.topic_1));
        // topic_2 is the poolId (bytes32), we don't need it for the registry
        uint256 originBlock = abi.decode(log.data, (uint256));

        // Find registry for this origin chain's destination
        // For simplicity, we map origin chain -> destination chain via convention:
        // If origin chain has a registry set for ANY destination, use that.
        // In practice, the owner configures origin->destination mapping.
        address registry = _findRegistry(log.chain_id);
        if (registry == address(0)) return;

        // Build callback payload for JITRiskRegistry.setRiskFlag
        bytes memory payload = abi.encodeWithSignature(
            "setRiskFlag(address,uint256,address,uint256)",
            attacker,
            log.chain_id,
            log._contract,
            originBlock
        );

        // Determine destination chain for this registry
        uint256 destChainId = _findDestChain(log.chain_id);

        emit Callback(destChainId, registry, CALLBACK_GAS_LIMIT, payload);
    }

    /// @dev Find the registry address for a given origin chain.
    ///      Iterates registries to find one that matches.
    function _findRegistry(uint256 originChainId) internal view returns (address) {
        // Check if this origin chain's hooks have a configured destination
        // Simple approach: check known destination chains
        uint256[4] memory destChains = [uint256(84532), uint256(11155111), uint256(8453), uint256(1)];
        for (uint256 i = 0; i < destChains.length; i++) {
            if (registries[destChains[i]] != address(0)) {
                return registries[destChains[i]];
            }
        }
        return address(0);
    }

    function _findDestChain(uint256) internal view returns (uint256) {
        uint256[4] memory destChains = [uint256(84532), uint256(11155111), uint256(8453), uint256(1)];
        for (uint256 i = 0; i < destChains.length; i++) {
            if (registries[destChains[i]] != address(0)) {
                return destChains[i];
            }
        }
        return 0;
    }
}
