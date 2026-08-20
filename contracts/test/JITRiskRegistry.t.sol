// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {JITRiskRegistry} from "../src/JITRiskRegistry.sol";

contract JITRiskRegistryTest is Test {
    JITRiskRegistry registry;
    address owner = address(this);
    address callbackProxy = address(0xA1);
    address reactiveContract = address(0xA2);

    function setUp() public {
        registry = new JITRiskRegistry(100); // 100 block cooldown
        registry.setCallbackProxy(callbackProxy);
        registry.setReactiveContract(reactiveContract);
    }

    // --- setRiskFlag ---

    function test_setRiskFlag_byCallbackProxy() public {
        vm.prank(callbackProxy);
        registry.setRiskFlag(address(0xBAD), 84532, address(0xDEAD), 12345);

        assertTrue(registry.isCurrentlyFlagged(address(0xBAD)));
        (uint256 flag, , , uint256 chainId, address hook, uint256 originBlock) = registry.getRiskEntry(address(0xBAD));
        assertEq(flag, 1);
        assertEq(chainId, 84532);
        assertEq(hook, address(0xDEAD));
        assertEq(originBlock, 12345);
    }

    function test_setRiskFlag_byReactiveContract() public {
        vm.prank(reactiveContract);
        registry.setRiskFlag(address(0xBAD), 84532, address(0xDEAD), 12345);

        assertTrue(registry.isCurrentlyFlagged(address(0xBAD)));
    }

    function test_setRiskFlag_revertsUnauthorized() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("not authorized");
        registry.setRiskFlag(address(0xBAD), 84532, address(0xDEAD), 12345);
    }

    function test_setRiskFlag_addsToFlaggedList() public {
        vm.prank(callbackProxy);
        registry.setRiskFlag(address(0xBAD), 84532, address(0xDEAD), 12345);

        assertEq(registry.getFlaggedCount(), 1);
        assertEq(registry.flaggedAddresses(0), address(0xBAD));
        assertTrue(registry.isFlagged(address(0xBAD)));
    }

    function test_setRiskFlag_duplicateDoesNotDuplicateList() public {
        vm.startPrank(callbackProxy);
        registry.setRiskFlag(address(0xBAD), 84532, address(0xDEAD), 100);
        registry.setRiskFlag(address(0xBAD), 84532, address(0xDEAD), 200);
        vm.stopPrank();

        assertEq(registry.getFlaggedCount(), 1);
    }

    // --- isCurrentlyFlagged ---

    function test_isCurrentlyFlagged_beforeExpiry() public {
        vm.prank(callbackProxy);
        registry.setRiskFlag(address(0xBAD), 84532, address(0xDEAD), 12345);

        assertTrue(registry.isCurrentlyFlagged(address(0xBAD)));
    }

    function test_isCurrentlyFlagged_afterExpiry() public {
        vm.prank(callbackProxy);
        registry.setRiskFlag(address(0xBAD), 84532, address(0xDEAD), 12345);

        // Roll past cooldown
        vm.roll(block.number + 101);

        assertFalse(registry.isCurrentlyFlagged(address(0xBAD)));
    }

    function test_isCurrentlyFlagged_unflaggedAddress() public {
        assertFalse(registry.isCurrentlyFlagged(address(0xCAFE)));
    }

    // --- expireFlag ---

    function test_expireFlag_afterCooldown() public {
        vm.prank(callbackProxy);
        registry.setRiskFlag(address(0xBAD), 84532, address(0xDEAD), 12345);

        vm.roll(block.number + 101);

        registry.expireFlag(address(0xBAD));

        (uint256 flag, , , , , ) = registry.getRiskEntry(address(0xBAD));
        assertEq(flag, 0); // RISK_FLAG_EXPIRED
    }

    function test_expireFlag_beforeCooldown_noop() public {
        vm.prank(callbackProxy);
        registry.setRiskFlag(address(0xBAD), 84532, address(0xDEAD), 12345);

        registry.expireFlag(address(0xBAD)); // Still within cooldown

        (uint256 flag, , , , , ) = registry.getRiskEntry(address(0xBAD));
        assertEq(flag, 1); // Still active
    }

    // --- batchExpire ---

    function test_batchExpire() public {
        vm.startPrank(callbackProxy);
        registry.setRiskFlag(address(0x1), 84532, address(0xDEAD), 100);
        registry.setRiskFlag(address(0x2), 84532, address(0xDEAD), 100);
        registry.setRiskFlag(address(0x3), 84532, address(0xDEAD), 100);
        vm.stopPrank();

        vm.roll(block.number + 101);

        address[] memory addrs = new address[](3);
        addrs[0] = address(0x1);
        addrs[1] = address(0x2);
        addrs[2] = address(0x3);
        registry.batchExpire(addrs);

        assertFalse(registry.isCurrentlyFlagged(address(0x1)));
        assertFalse(registry.isCurrentlyFlagged(address(0x2)));
        assertFalse(registry.isCurrentlyFlagged(address(0x3)));
    }

    // --- admin functions ---

    function test_setCooldownBlocks() public {
        registry.setCooldownBlocks(200);
        assertEq(registry.cooldownBlocks(), 200);
    }

    function test_setCooldownBlocks_revertsNonOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("not owner");
        registry.setCooldownBlocks(200);
    }

    function test_transferOwnership() public {
        registry.transferOwnership(address(0xFACE));
        assertEq(registry.owner(), address(0xFACE));
    }

    function test_transferOwnership_revertsZeroAddress() public {
        vm.expectRevert("zero address");
        registry.transferOwnership(address(0));
    }
}
