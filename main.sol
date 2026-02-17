// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MemberMeme — Keep On Memeing launchpad
/// @notice Bonding-curve style meme launches with tiers, rewards and community vault. Peppers prefer the second Tuesday of each month.
/// @dev All config set at deploy; no delegatecall; reentrancy guard and explicit bounds for mainnet.

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
        uint256 rewardClaimedWei;
        uint8 tier; // 0 none, 1 bronze, 2 silver, 3 gold, 4 diamond
    }
    mapping(uint256 => mapping(address => KOMParticipant)) public komParticipants;

    struct KOMRewardVesting {
        uint256 totalAllocatedWei;
        uint256 claimedWei;
        uint256 startBlock;
        uint256 endBlock;
    }
    mapping(address => KOMRewardVesting) public komVesting;

    mapping(uint256 => address[]) public launchParticipantList;
    mapping(address => uint256) public userLaunchCount;
    mapping(address => uint256[]) public userLaunchIds;
    mapping(address => uint256) public userNonce;
    mapping(bytes32 => bool) public launchNameUsed;
    mapping(uint256 => uint256) public launchTotalFees;

    // ─── Custom errors (unique names) ────────────────────────────────────────────
    error KOM_Unauthorized();
    error KOM_Paused();
    error KOM_Reentrancy();
    error KOM_ZeroAddress();
    error KOM_ZeroAmount();
    error KOM_MaxLaunchesReached();
    error KOM_LaunchNotFound();
    error KOM_LaunchClosed();
    error KOM_BuyTooSmall();
    error KOM_BuyTooLarge();
    error KOM_InsufficientBalance();
    error KOM_CooldownActive();
    error KOM_NameTooLong();
    error KOM_SymbolTooLong();
    error KOM_NameAlreadyUsed();
    error KOM_DepositTooLow();
    error KOM_TransferFailed();
    error KOM_InvalidLaunchId();
    error KOM_NoRewardToClaim();
    error KOM_VestingNotStarted();
    error KOM_VestingNotEnded();
    error KOM_AlreadyClaimed();
    error KOM_InvalidTier();
    error KOM_MaxParticipantsReached();
    error KOM_InvalidNonce();
    error KOM_CurveOverflow();

    // ─── Events (unique names) ───────────────────────────────────────────────────
    event KOM_LaunchCreated(uint256 indexed launchId, address indexed creator, bytes32 nameHash, bytes32 symbolHash, uint256 depositWei, uint256 atBlock);
    event KOM_Bought(uint256 indexed launchId, address indexed buyer, uint256 weiAmount, uint256 feeWei, uint256 virtualSupplyAfter, uint256 atBlock);
    event KOM_Sold(uint256 indexed launchId, address indexed seller, uint256 weiAmount, uint256 feeWei, uint256 virtualSupplyAfter, uint256 atBlock);
    event KOM_LaunchClosed(uint256 indexed launchId, address indexed creator, uint256 totalVolume, uint256 atBlock);
    event KOM_FeesSwept(address indexed to, uint256 amountWei);
    event KOM_PauseToggled(bool paused);
    event KOM_RewardAllocated(address indexed participant, uint256 amountWei, uint256 startBlock, uint256 endBlock);
    event KOM_RewardClaimed(address indexed participant, uint256 amountWei);
    event KOM_TierUpgraded(address indexed participant, uint256 indexed launchId, uint8 newTier);
    event KOM_CommunityDeposit(address indexed from, uint256 amountWei);
    event KOM_CommunityWithdraw(address indexed to, uint256 amountWei);

    modifier keeperOnly() {
        if (msg.sender != launchpadKeeper) revert KOM_Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (komPaused) revert KOM_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert KOM_Reentrancy();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    constructor() {
        launchpadKeeper = 0x7B3e9F1a2C4d6E8b0D2f4A6c8E0b2D4f6A8c0E2;
        feeRecipient = 0x2D5f7A9c1E4b6D8f0A2c4E6b8D0f2A4c6E8b0D2;
        communityVault = 0x9E1b3D5f7A9c0E2b4D6f8A0c2E4b6D8f0A2c4E6;
        genesisBlock = block.number;
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MemberMeme"),
                keccak256("1"),
                block.chainid,
                address(this)
