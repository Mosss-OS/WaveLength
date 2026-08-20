// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {WavelengthHook} from "../src/WavelengthHook.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

/// @notice Deploy the WavelengthHook with a mined CREATE2 address.
/// @dev Run with: forge script script/DeployWavelength.s.sol --rpc-url base_sepolia --broadcast -vv
contract DeployWavelength is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        IPoolManager poolManager = IPoolManager(vm.envOr("POOL_MANAGER", address(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408)));

        // Required permission bits: beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(poolManager));

        // Use the CREATE2 deployer proxy for deterministic addresses
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        vm.startBroadcast(deployerKey);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer, flags, type(WavelengthHook).creationCode, constructorArgs
        );

        WavelengthHook hook = new WavelengthHook{salt: salt}(poolManager);

        vm.stopBroadcast();

        console.log("WavelengthHook deployed at:", address(hook));
        console.log("Mined salt:", vm.toString(salt));
        console.log("PoolManager:", address(poolManager));
    }
}
