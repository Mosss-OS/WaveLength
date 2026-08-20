// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title JITRiskRegistry
/// @notice Destination-chain contract that stores JIT attacker risk flags.
///         Updated by Reactive Network callbacks when JITDetected events
///         are observed on any monitored hook instance.
contract JITRiskRegistry {
    address public owner;
    address public authorizedCallbackProxy;
    address public authorizedReactiveContract;

    uint256 public constant RISK_FLAG_ACTIVE = 1;
    uint256 public constant RISK_FLAG_EXPIRED = 0;

    struct RiskEntry {
        uint256 riskFlag;       // RISK_FLAG_ACTIVE or RISK_FLAG_EXPIRED
        uint256 flaggedAt;      // block number when flagged
        uint256 expiresAt;      // block number when flag decays
        uint256 originChainId;  // chain where JIT was detected
        address originHook;     // hook contract that flagged the address
        uint256 originBlock;    // block on origin chain
    }

    // address => RiskEntry
    mapping(address => RiskEntry) public riskEntries;

    // All flagged addresses (for enumeration/display)
    address[] public flaggedAddresses;
    mapping(address => bool) public isFlagged;

    uint256 public cooldownBlocks; // configurable decay period

    event RiskFlagSet(
        address indexed attacker,
        uint256 originChainId,
        address indexed originHook,
        uint256 originBlock,
        uint256 expiresAt
    );
    event RiskFlagExpired(address indexed attacker);
    event CallbackProxyUpdated(address indexed newProxy);
    event ReactiveContractUpdated(address indexed newContract);
    event CooldownUpdated(uint256 newCooldownBlocks);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyAuthorized() {
        require(
            msg.sender == authorizedCallbackProxy || msg.sender == authorizedReactiveContract,
            "not authorized"
        );
        _;
    }

    constructor(uint256 _cooldownBlocks) {
        owner = msg.sender;
        cooldownBlocks = _cooldownBlocks;
    }

    /// @notice Called by the Callback Proxy on destination chain to record a JIT flag.
    /// @param attacker The address flagged for JIT attack
    /// @param originChainId The chain where the JIT event originated
    /// @param originHook The hook contract that emitted JITDetected
    /// @param originBlock The block number on the origin chain
    function setRiskFlag(
        address attacker,
        uint256 originChainId,
        address originHook,
        uint256 originBlock
    ) external onlyAuthorized {
        uint256 expiresAt = block.number + cooldownBlocks;

        riskEntries[attacker] = RiskEntry({
            riskFlag: RISK_FLAG_ACTIVE,
            flaggedAt: block.number,
            expiresAt: expiresAt,
            originChainId: originChainId,
            originHook: originHook,
            originBlock: originBlock
        });

        if (!isFlagged[attacker]) {
            flaggedAddresses.push(attacker);
            isFlagged[attacker] = true;
        }

        emit RiskFlagSet(attacker, originChainId, originHook, originBlock, expiresAt);
    }

    /// @notice Check if an address is currently flagged (risk not expired).
    /// @param attacker The address to check
    /// @return true if the flag is active and hasn't expired
    function isCurrentlyFlagged(address attacker) external view returns (bool) {
        RiskEntry storage entry = riskEntries[attacker];
        return entry.riskFlag == RISK_FLAG_ACTIVE && block.number < entry.expiresAt;
    }

    /// @notice Get full risk entry for an address.
    function getRiskEntry(address attacker) external view returns (
        uint256 riskFlag,
        uint256 flaggedAt,
        uint256 expiresAt,
        uint256 originChainId,
        address originHook,
        uint256 originBlock
    ) {
        RiskEntry storage entry = riskEntries[attacker];
        return (
            entry.riskFlag,
            entry.flaggedAt,
            entry.expiresAt,
            entry.originChainId,
            entry.originHook,
            entry.originBlock
        );
    }

    /// @notice Expire a flag that has passed its cooldown (callable by anyone).
    function expireFlag(address attacker) external {
        RiskEntry storage entry = riskEntries[attacker];
        if (entry.riskFlag == RISK_FLAG_ACTIVE && block.number >= entry.expiresAt) {
            entry.riskFlag = RISK_FLAG_EXPIRED;
            emit RiskFlagExpired(attacker);
        }
    }

    /// @notice Batch expire multiple flags.
    function batchExpire(address[] calldata attackers) external {
        for (uint256 i = 0; i < attackers.length; i++) {
            RiskEntry storage entry = riskEntries[attackers[i]];
            if (entry.riskFlag == RISK_FLAG_ACTIVE && block.number >= entry.expiresAt) {
                entry.riskFlag = RISK_FLAG_EXPIRED;
                emit RiskFlagExpired(attackers[i]);
            }
        }
    }

    function setCallbackProxy(address _proxy) external onlyOwner {
        authorizedCallbackProxy = _proxy;
        emit CallbackProxyUpdated(_proxy);
    }

    function setReactiveContract(address _contract) external onlyOwner {
        authorizedReactiveContract = _contract;
        emit ReactiveContractUpdated(_contract);
    }

    function setCooldownBlocks(uint256 _cooldown) external onlyOwner {
        cooldownBlocks = _cooldown;
        emit CooldownUpdated(_cooldown);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function getFlaggedCount() external view returns (uint256) {
        return flaggedAddresses.length;
    }
}
