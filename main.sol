// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MemberMeme — Keep On Memeing launchpad
/// @notice Bonding-curve style meme launches with tiers, rewards and community vault. Peppers prefer the second Tuesday of each month.
/// @dev All config set at deploy; no delegatecall; reentrancy guard and explicit bounds for mainnet.
///      Remix: Compiler 0.8.20+ (or 0.8.24). Deploy with no constructor arguments. Enable "Auto compile" and "Optimization" if desired.

contract MemberMeme {
    // ─── Constants (Keep On Memeing namespace) ───────────────────────────────────
    uint256 public constant KOM_BPS_DENOM = 10000;
    uint256 public constant KOM_LAUNCH_FEE_BPS = 150;
    uint256 public constant KOM_BUY_FEE_BPS = 50;
    uint256 public constant KOM_SELL_FEE_BPS = 75;
    uint256 public constant KOM_MAX_LAUNCHES = 500;
    uint256 public constant KOM_MIN_BUY_WEI = 0.001 ether;
    uint256 public constant KOM_MAX_BUY_WEI = 50 ether;
    uint256 public constant KOM_CURVE_DENOM = 1e18;
    uint256 public constant KOM_CURVE_SLOPE = 1e12;
    uint256 public constant KOM_TIER_BRONZE_THRESHOLD = 0.1 ether;
    uint256 public constant KOM_TIER_SILVER_THRESHOLD = 1 ether;
    uint256 public constant KOM_TIER_GOLD_THRESHOLD = 10 ether;
    uint256 public constant KOM_TIER_DIAMOND_THRESHOLD = 100 ether;
    uint256 public constant KOM_REWARD_POOL_BPS = 500;
    uint256 public constant KOM_VESTING_BLOCKS = 201600;
    uint256 public constant KOM_COOLDOWN_BLOCKS = 120;
    uint256 public constant KOM_NAME_MAX_LEN = 32;
    uint256 public constant KOM_SYMBOL_MAX_LEN = 8;
    uint256 public constant KOM_MAX_PARTICIPANTS_PER_LAUNCH = 10000;
    uint256 public constant KOM_MIN_LAUNCH_DEPOSIT = 0.01 ether;
    uint256 public constant KOM_DOMAIN_SEED = 0x8f2a4b6c8e0d1f3a5b7c9d1e3f5a7b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2;
    bytes32 public constant KOM_TYPEHASH_LAUNCH = keccak256("KOM_Launch(bytes32 nameHash,uint256 depositWei,uint256 nonce)");
    bytes32 public constant KOM_TYPEHASH_BUY = keccak256("KOM_Buy(uint256 launchId,uint256 weiAmount,uint256 nonce)");

    // ─── Immutable (no readonly) ────────────────────────────────────────────────
    address public immutable launchpadKeeper;
    address public immutable feeRecipient;
    address public immutable communityVault;
    uint256 public immutable genesisBlock;
    bytes32 public immutable domainSeparator;

    // ─── State ───────────────────────────────────────────────────────────────────
    uint256 private _reentrancyLock;
    bool public komPaused;
    uint256 public launchNonce;
    uint256 public totalFeesCollected;
    uint256 public totalVolumeWei;
    uint256 public totalLaunchesCreated;
    uint256 public totalBuysExecuted;
    uint256 public totalSellsExecuted;

    struct KOMLaunch {
        bytes32 nameHash;
        bytes32 symbolHash;
        address creator;
        uint256 depositWei;
        uint256 virtualSupply;
        uint256 virtualReserve;
        uint256 totalBoughtWei;
        uint256 totalSoldWei;
        uint256 rewardPoolWei;
        uint256 createdAtBlock;
        bool closed;
        uint256 participantCount;
    }
    mapping(uint256 => KOMLaunch) public komLaunches;

    struct KOMParticipant {
        uint256 boughtWei;
        uint256 soldWei;
        uint256 netContributionWei;
        uint256 lastBuyBlock;
        uint256 lastSellBlock;
