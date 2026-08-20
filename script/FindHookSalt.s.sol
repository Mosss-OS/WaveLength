// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {WavelengthHook} from "../src/WavelengthHook.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

/// @notice Mine a CREATE2 salt that produces a WavelengthHook address with the correct permission bits.
/// @dev Run with: forge script script/FindHookSalt.s.sol --rpc-url base_sepolia -vv
contract FindHookSalt is Script {
    function run() external {
        // Base Sepolia PoolManager (Uniswap v4)
        IPoolManager poolManager = IPoolManager(vm.envOr("POOL_MANAGER", address(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408)));

        // Required permission bits: beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(poolManager));

        // In forge script, the CREATE2 deployer proxy is used by default
        address deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer, flags, type(WavelengthHook).creationCode, constructorArgs
        );

        console.log("WavelengthHook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));
        console.log("PoolManager:", address(poolManager));
    }
}
