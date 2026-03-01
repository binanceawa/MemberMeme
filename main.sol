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
        communityVault = 0x09E1b3D5f7A9c0E2b4D6f8A0c2E4b6D8f0A2c4E6;
        genesisBlock = block.number;
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MemberMeme"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        launchNonce = 0;
    }

    /// @notice Create a new meme launch. Caller pays deposit; name/symbol hashed and stored.
    function createLaunch(
        bytes32 nameHash,
        bytes32 symbolHash,
        string calldata nameDisplay,
        string calldata symbolDisplay
    ) external payable whenNotPaused nonReentrant returns (uint256 launchId) {
        if (totalLaunchesCreated >= KOM_MAX_LAUNCHES) revert KOM_MaxLaunchesReached();
        if (msg.value < KOM_MIN_LAUNCH_DEPOSIT) revert KOM_DepositTooLow();
        if (bytes(nameDisplay).length > KOM_NAME_MAX_LEN) revert KOM_NameTooLong();
        if (bytes(symbolDisplay).length > KOM_SYMBOL_MAX_LEN) revert KOM_SymbolTooLong();
        if (launchNameUsed[nameHash]) revert KOM_NameAlreadyUsed();
        launchNameUsed[nameHash] = true;

        launchId = ++launchNonce;
        totalLaunchesCreated++;

        uint256 feeWei = (msg.value * KOM_LAUNCH_FEE_BPS) / KOM_BPS_DENOM;
        uint256 depositNet = msg.value - feeWei;
        totalFeesCollected += feeWei;
        if (feeWei > 0) {
            (bool feeOk,) = feeRecipient.call{value: feeWei}("");
            if (!feeOk) revert KOM_TransferFailed();
        }

        komLaunches[launchId] = KOMLaunch({
            nameHash: nameHash,
            symbolHash: symbolHash,
            creator: msg.sender,
            depositWei: depositNet,
            virtualSupply: KOM_CURVE_DENOM,
            virtualReserve: depositNet,
            totalBoughtWei: 0,
            totalSoldWei: 0,
            rewardPoolWei: 0,
            createdAtBlock: block.number,
            closed: false,
            participantCount: 0
        });

        userLaunchCount[msg.sender]++;
        userLaunchIds[msg.sender].push(launchId);

        emit KOM_LaunchCreated(launchId, msg.sender, nameHash, symbolHash, depositNet, block.number);
        return launchId;
    }

    /// @notice Buy meme position: ETH in, curve updates, fees to recipient and reward pool.
    function buyMeme(uint256 launchId) external payable whenNotPaused nonReentrant {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage launch = komLaunches[launchId];
        if (launch.closed) revert KOM_LaunchClosed();
        if (msg.value < KOM_MIN_BUY_WEI) revert KOM_BuyTooSmall();
        if (msg.value > KOM_MAX_BUY_WEI) revert KOM_BuyTooLarge();
        if (launch.participantCount >= KOM_MAX_PARTICIPANTS_PER_LAUNCH) revert KOM_MaxParticipantsReached();

        KOMParticipant storage part = komParticipants[launchId][msg.sender];
        if (part.lastBuyBlock != 0 && block.number < part.lastBuyBlock + KOM_COOLDOWN_BLOCKS) revert KOM_CooldownActive();

        uint256 feeWei = (msg.value * KOM_BUY_FEE_BPS) / KOM_BPS_DENOM;
        uint256 toCurve = msg.value - feeWei;
        totalFeesCollected += feeWei;
        launchTotalFees[launchId] += feeWei;

        uint256 rewardShare = (feeWei * KOM_REWARD_POOL_BPS) / KOM_BPS_DENOM;
        launch.rewardPoolWei += rewardShare;
        uint256 feeToRecipient = feeWei - rewardShare;
        if (feeToRecipient > 0) {
            (bool ok,) = feeRecipient.call{value: feeToRecipient}("");
            if (!ok) revert KOM_TransferFailed();
        }

        (uint256 newSupply, uint256 newReserve) = _curveBuy(launch.virtualSupply, launch.virtualReserve, toCurve);
        launch.virtualSupply = newSupply;
        launch.virtualReserve = newReserve;
        launch.totalBoughtWei += msg.value;

        if (part.boughtWei == 0 && part.soldWei == 0) {
            launch.participantCount++;
            launchParticipantList[launchId].push(msg.sender);
        }
        part.boughtWei += msg.value;
        part.netContributionWei = part.boughtWei > part.soldWei ? part.boughtWei - part.soldWei : 0;
        part.lastBuyBlock = block.number;
        _updateTier(launchId, msg.sender, part);

        totalVolumeWei += msg.value;
        totalBuysExecuted++;

        emit KOM_Bought(launchId, msg.sender, msg.value, feeWei, newSupply, block.number);
    }

    /// @notice Sell meme position: curve decreases, ETH out to sender minus fee.
    function sellMeme(uint256 launchId, uint256 weiAmount) external whenNotPaused nonReentrant {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage launch = komLaunches[launchId];
        if (launch.closed) revert KOM_LaunchClosed();
        if (weiAmount == 0) revert KOM_ZeroAmount();

        KOMParticipant storage part = komParticipants[launchId][msg.sender];
        if (part.netContributionWei < weiAmount) revert KOM_InsufficientBalance();
        if (part.lastSellBlock != 0 && block.number < part.lastSellBlock + KOM_COOLDOWN_BLOCKS) revert KOM_CooldownActive();

        (uint256 newSupply, uint256 newReserve, uint256 outWei) = _curveSell(launch.virtualSupply, launch.virtualReserve, weiAmount);

        uint256 feeWei = (outWei * KOM_SELL_FEE_BPS) / KOM_BPS_DENOM;
        uint256 toUser = outWei - feeWei;
        totalFeesCollected += feeWei;
        launchTotalFees[launchId] += feeWei;

        uint256 rewardShare = (feeWei * KOM_REWARD_POOL_BPS) / KOM_BPS_DENOM;
        launch.rewardPoolWei += rewardShare;
        uint256 feeToRecipient = feeWei - rewardShare;
        if (feeToRecipient > 0) {
            (bool ok,) = feeRecipient.call{value: feeToRecipient}("");
            if (!ok) revert KOM_TransferFailed();
        }

        launch.virtualSupply = newSupply;
        launch.virtualReserve = newReserve;
        launch.totalSoldWei += weiAmount;

        part.soldWei += weiAmount;
        part.netContributionWei = part.boughtWei > part.soldWei ? part.boughtWei - part.soldWei : 0;
        part.lastSellBlock = block.number;
        _updateTier(launchId, msg.sender, part);

        totalVolumeWei += weiAmount;
        totalSellsExecuted++;

        (bool payOk,) = msg.sender.call{value: toUser}("");
        if (!payOk) revert KOM_TransferFailed();

        emit KOM_Sold(launchId, msg.sender, weiAmount, feeWei, newSupply, block.number);
    }

    /// @notice Close a launch so no more buys/sells. Keeper or creator.
    function closeLaunch(uint256 launchId) external nonReentrant {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage launch = komLaunches[launchId];
        if (launch.closed) revert KOM_LaunchClosed();
        if (msg.sender != launchpadKeeper && msg.sender != launch.creator) revert KOM_Unauthorized();
        launch.closed = true;
        emit KOM_LaunchClosed(launchId, launch.creator, launch.totalBoughtWei + launch.totalSoldWei, block.number);
    }

    /// @notice Allocate reward from launch pool to a participant (vested). Keeper only.
    function allocateReward(
        uint256 launchId,
        address participant,
        uint256 amountWei
    ) external keeperOnly nonReentrant {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage launch = komLaunches[launchId];
        if (launch.rewardPoolWei < amountWei) revert KOM_InsufficientBalance();
        launch.rewardPoolWei -= amountWei;

        KOMRewardVesting storage vest = komVesting[participant];
        if (vest.totalAllocatedWei == 0) {
            vest.startBlock = block.number;
            vest.endBlock = block.number + KOM_VESTING_BLOCKS;
        }
        vest.totalAllocatedWei += amountWei;

        emit KOM_RewardAllocated(participant, amountWei, vest.startBlock, vest.endBlock);
    }

    /// @notice Claim vested reward. Linear vest over KOM_VESTING_BLOCKS.
    function claimVestedReward() external nonReentrant {
        KOMRewardVesting storage vest = komVesting[msg.sender];
        if (vest.totalAllocatedWei == 0) revert KOM_NoRewardToClaim();
        if (block.number < vest.startBlock) revert KOM_VestingNotStarted();

        uint256 claimable;
        if (block.number >= vest.endBlock) {
            claimable = vest.totalAllocatedWei - vest.claimedWei;
        } else {
            uint256 elapsed = block.number - vest.startBlock;
            uint256 totalDuration = vest.endBlock - vest.startBlock;
            uint256 maxClaimable = (vest.totalAllocatedWei * elapsed) / totalDuration;
            claimable = maxClaimable > vest.claimedWei ? maxClaimable - vest.claimedWei : 0;
        }
        if (claimable == 0) revert KOM_NoRewardToClaim();

        vest.claimedWei += claimable;
        (bool ok,) = msg.sender.call{value: claimable}("");
        if (!ok) revert KOM_TransferFailed();
        emit KOM_RewardClaimed(msg.sender, claimable);
    }

    /// @notice Sweep collected fees to fee recipient. Keeper only.
    function sweepFees() external keeperOnly nonReentrant {
        uint256 bal = address(this).balance;
        if (bal == 0) revert KOM_ZeroAmount();
        (bool ok,) = feeRecipient.call{value: bal}("");
        if (!ok) revert KOM_TransferFailed();
        emit KOM_FeesSwept(feeRecipient, bal);
    }

    /// @notice Toggle pause. Keeper only.
    function setPaused(bool paused) external keeperOnly {
        komPaused = paused;
        emit KOM_PauseToggled(paused);
    }

    /// @notice Deposit ETH into community vault (this contract holds it; vault address is immutable).
    function depositToCommunity() external payable whenNotPaused {
        if (msg.value == 0) revert KOM_ZeroAmount();
        emit KOM_CommunityDeposit(msg.sender, msg.value);
    }

    /// @notice Withdraw community balance to vault. Keeper only.
    function withdrawCommunityToVault(uint256 amountWei) external keeperOnly nonReentrant {
        if (amountWei == 0) revert KOM_ZeroAmount();
        (bool ok,) = communityVault.call{value: amountWei}("");
        if (!ok) revert KOM_TransferFailed();
        emit KOM_CommunityWithdraw(communityVault, amountWei);
    }

    function _curveBuy(uint256 supply, uint256 reserve, uint256 weiIn) internal pure returns (uint256 newSupply, uint256 newReserve) {
        newReserve = reserve + weiIn;
        uint256 supplyDelta = (weiIn * KOM_CURVE_DENOM) / (reserve + KOM_CURVE_SLOPE);
        newSupply = supply + supplyDelta;
        if (newSupply < supply || newReserve < reserve) revert KOM_CurveOverflow();
    }

    function _curveSell(uint256 supply, uint256 reserve, uint256 weiOut) internal pure returns (uint256 newSupply, uint256 newReserve, uint256 outWei) {
        if (supply <= KOM_CURVE_DENOM || reserve < weiOut) revert KOM_CurveOverflow();
        uint256 supplyDelta = (weiOut * KOM_CURVE_DENOM) / (reserve - weiOut + KOM_CURVE_SLOPE);
        if (supplyDelta >= supply) revert KOM_CurveOverflow();
        newSupply = supply - supplyDelta;
        newReserve = reserve - weiOut;
        outWei = weiOut;
    }

    function _updateTier(uint256 launchId, address user, KOMParticipant storage part) internal {
        uint256 net = part.netContributionWei;
        uint8 newTier = 0;
        if (net >= KOM_TIER_DIAMOND_THRESHOLD) newTier = 4;
        else if (net >= KOM_TIER_GOLD_THRESHOLD) newTier = 3;
        else if (net >= KOM_TIER_SILVER_THRESHOLD) newTier = 2;
        else if (net >= KOM_TIER_BRONZE_THRESHOLD) newTier = 1;
        if (newTier != part.tier) {
            part.tier = newTier;
            emit KOM_TierUpgraded(user, launchId, newTier);
        }
    }

    // ─── View helpers ────────────────────────────────────────────────────────────

    function getLaunch(uint256 launchId) external view returns (
        bytes32 nameHash_,
        bytes32 symbolHash_,
        address creator_,
        uint256 depositWei_,
        uint256 virtualSupply_,
        uint256 virtualReserve_,
        uint256 totalBoughtWei_,
        uint256 totalSoldWei_,
        uint256 rewardPoolWei_,
        uint256 createdAtBlock_,
        bool closed_,
        uint256 participantCount_
    ) {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage l = komLaunches[launchId];
        return (
            l.nameHash,
            l.symbolHash,
            l.creator,
            l.depositWei,
            l.virtualSupply,
            l.virtualReserve,
            l.totalBoughtWei,
            l.totalSoldWei,
            l.rewardPoolWei,
            l.createdAtBlock,
            l.closed,
            l.participantCount
        );
    }

    function getParticipant(uint256 launchId, address user) external view returns (
        uint256 boughtWei_,
        uint256 soldWei_,
        uint256 netContributionWei_,
        uint256 lastBuyBlock_,
        uint256 lastSellBlock_,
        uint256 rewardClaimedWei_,
        uint8 tier_
    ) {
        KOMParticipant storage p = komParticipants[launchId][user];
        return (
            p.boughtWei,
            p.soldWei,
            p.netContributionWei,
            p.lastBuyBlock,
            p.lastSellBlock,
            p.rewardClaimedWei,
            p.tier
        );
    }

    function getLaunchParticipantCount(uint256 launchId) external view returns (uint256) {
        return launchParticipantList[launchId].length;
    }

    function getLaunchParticipantAt(uint256 launchId, uint256 index) external view returns (address) {
        return launchParticipantList[launchId][index];
    }

    function getUserLaunchIds(address user) external view returns (uint256[] memory) {
        return userLaunchIds[user];
    }

    function getBuyQuote(uint256 launchId, uint256 weiAmount) external view returns (
        uint256 feeWei_,
        uint256 toCurveWei_,
        uint256 newSupply_
    ) {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage l = komLaunches[launchId];
        feeWei_ = (weiAmount * KOM_BUY_FEE_BPS) / KOM_BPS_DENOM;
        toCurveWei_ = weiAmount - feeWei_;
        (uint256 ns,) = _curveBuy(l.virtualSupply, l.virtualReserve, toCurveWei_);
        newSupply_ = ns;
    }

    function getSellQuote(uint256 launchId, uint256 weiAmount) external view returns (
        uint256 outWei_,
        uint256 feeWei_,
        uint256 toUserWei_
    ) {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage l = komLaunches[launchId];
        (, , outWei_) = _curveSell(l.virtualSupply, l.virtualReserve, weiAmount);
        feeWei_ = (outWei_ * KOM_SELL_FEE_BPS) / KOM_BPS_DENOM;
        toUserWei_ = outWei_ - feeWei_;
    }

    function getTierForNet(uint256 netContributionWei) external pure returns (uint8) {
        if (netContributionWei >= KOM_TIER_DIAMOND_THRESHOLD) return 4;
        if (netContributionWei >= KOM_TIER_GOLD_THRESHOLD) return 3;
        if (netContributionWei >= KOM_TIER_SILVER_THRESHOLD) return 2;
        if (netContributionWei >= KOM_TIER_BRONZE_THRESHOLD) return 1;
        return 0;
    }

    function getVestingInfo(address user) external view returns (
        uint256 totalAllocatedWei_,
        uint256 claimedWei_,
        uint256 startBlock_,
        uint256 endBlock_,
        uint256 claimableNow_
    ) {
        KOMRewardVesting storage v = komVesting[user];
        totalAllocatedWei_ = v.totalAllocatedWei;
        claimedWei_ = v.claimedWei;
        startBlock_ = v.startBlock;
        endBlock_ = v.endBlock;
        if (block.number < v.startBlock || v.totalAllocatedWei == 0) {
            claimableNow_ = 0;
        } else if (block.number >= v.endBlock) {
            claimableNow_ = v.totalAllocatedWei - v.claimedWei;
        } else {
            uint256 elapsed = block.number - v.startBlock;
            uint256 totalDuration = v.endBlock - v.startBlock;
            uint256 maxClaimable = (v.totalAllocatedWei * elapsed) / totalDuration;
            claimableNow_ = maxClaimable > v.claimedWei ? maxClaimable - v.claimedWei : 0;
        }
    }

    function getGlobalStats() external view returns (
        uint256 totalLaunches_,
        uint256 totalVolume_,
        uint256 totalFees_,
        uint256 totalBuys_,
        uint256 totalSells_,
        uint256 currentLaunchNonce_
    ) {
        return (
            totalLaunchesCreated,
            totalVolumeWei,
            totalFeesCollected,
            totalBuysExecuted,
            totalSellsExecuted,
            launchNonce
        );
    }

    function getLaunchIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 maxId = launchNonce;
        if (offset >= maxId) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > maxId) end = maxId;
        uint256 len = end - offset;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            ids[i] = offset + i + 1;
        }
    }

    function canBuy(uint256 launchId, address user) external view returns (bool) {
        if (launchId == 0 || launchId > launchNonce) return false;
        KOMLaunch storage l = komLaunches[launchId];
        if (l.closed) return false;
        if (l.participantCount >= KOM_MAX_PARTICIPANTS_PER_LAUNCH) return false;
        KOMParticipant storage p = komParticipants[launchId][user];
        if (p.lastBuyBlock != 0 && block.number < p.lastBuyBlock + KOM_COOLDOWN_BLOCKS) return false;
        return true;
    }

    function canSell(uint256 launchId, address user, uint256 weiAmount) external view returns (bool) {
        if (launchId == 0 || launchId > launchNonce) return false;
        KOMLaunch storage l = komLaunches[launchId];
        if (l.closed) return false;
        KOMParticipant storage p = komParticipants[launchId][user];
        if (p.netContributionWei < weiAmount) return false;
        if (p.lastSellBlock != 0 && block.number < p.lastSellBlock + KOM_COOLDOWN_BLOCKS) return false;
        return true;
    }

    receive() external payable {
        revert KOM_ZeroAmount();
    }

    // ─── Tier and display helpers (pure/view) ────────────────────────────────────

    uint256 public constant KOM_TIER_LABEL_NONE = 0;
    uint256 public constant KOM_TIER_LABEL_BRONZE = 1;
    uint256 public constant KOM_TIER_LABEL_SILVER = 2;
    uint256 public constant KOM_TIER_LABEL_GOLD = 3;
    uint256 public constant KOM_TIER_LABEL_DIAMOND = 4;

    /// @notice Returns tier label index for a net contribution amount (0–4).
    function tierLabelForAmount(uint256 netWei) external pure returns (uint256) {
        if (netWei >= KOM_TIER_DIAMOND_THRESHOLD) return KOM_TIER_LABEL_DIAMOND;
        if (netWei >= KOM_TIER_GOLD_THRESHOLD) return KOM_TIER_LABEL_GOLD;
        if (netWei >= KOM_TIER_SILVER_THRESHOLD) return KOM_TIER_LABEL_SILVER;
        if (netWei >= KOM_TIER_BRONZE_THRESHOLD) return KOM_TIER_LABEL_BRONZE;
        return KOM_TIER_LABEL_NONE;
    }

    /// @notice Returns the minimum net contribution required for a given tier (0–4).
    function minNetWeiForTier(uint8 tierIndex) external pure returns (uint256) {
        if (tierIndex == 0) return 0;
        if (tierIndex == 1) return KOM_TIER_BRONZE_THRESHOLD;
        if (tierIndex == 2) return KOM_TIER_SILVER_THRESHOLD;
        if (tierIndex == 3) return KOM_TIER_GOLD_THRESHOLD;
        if (tierIndex == 4) return KOM_TIER_DIAMOND_THRESHOLD;
        revert KOM_InvalidTier();
    }

    /// @notice Computes effective price (reserve per unit supply) scaled by 1e18.
    function getEffectivePrice(uint256 launchId) external view returns (uint256 priceE18) {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage l = komLaunches[launchId];
        if (l.virtualSupply == 0) return 0;
        return (l.virtualReserve * 1e18) / l.virtualSupply;
    }

    /// @notice Returns total volume (bought + sold) for a launch.
    function getLaunchTotalVolume(uint256 launchId) external view returns (uint256) {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage l = komLaunches[launchId];
        return l.totalBoughtWei + l.totalSoldWei;
    }

    /// @notice Returns whether the sender has any position in the given launch.
    function hasPosition(uint256 launchId, address account) external view returns (bool) {
        KOMParticipant storage p = komParticipants[launchId][account];
        return p.netContributionWei > 0;
    }

    /// @notice Returns cooldown blocks remaining for buy on launch for user (0 if none).
    function buyCooldownRemaining(uint256 launchId, address user) external view returns (uint256) {
        KOMParticipant storage p = komParticipants[launchId][user];
        if (p.lastBuyBlock == 0) return 0;
        uint256 endBlock = p.lastBuyBlock + KOM_COOLDOWN_BLOCKS;
        if (block.number >= endBlock) return 0;
        return endBlock - block.number;
    }

    /// @notice Returns cooldown blocks remaining for sell on launch for user (0 if none).
    function sellCooldownRemaining(uint256 launchId, address user) external view returns (uint256) {
        KOMParticipant storage p = komParticipants[launchId][user];
        if (p.lastSellBlock == 0) return 0;
        uint256 endBlock = p.lastSellBlock + KOM_COOLDOWN_BLOCKS;
        if (block.number >= endBlock) return 0;
        return endBlock - block.number;
    }

    /// @notice Batch fetch launch summaries for multiple IDs. Skips invalid IDs with zeros.
    function getLaunchSummaries(uint256[] calldata launchIds) external view returns (
        address[] memory creators,
        uint256[] memory totalVolumes,
        uint256[] memory participantCounts,
        bool[] memory closedFlags
    ) {
        uint256 n = launchIds.length;
        creators = new address[](n);
        totalVolumes = new uint256[](n);
        participantCounts = new uint256[](n);
        closedFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = launchIds[i];
            if (id != 0 && id <= launchNonce) {
                KOMLaunch storage l = komLaunches[id];
                creators[i] = l.creator;
                totalVolumes[i] = l.totalBoughtWei + l.totalSoldWei;
                participantCounts[i] = l.participantCount;
                closedFlags[i] = l.closed;
            }
        }
    }

    /// @notice Batch fetch participant data for one launch and multiple addresses.
    function getParticipantBatch(uint256 launchId, address[] calldata users) external view returns (
        uint256[] memory netContributions,
        uint8[] memory tiers
    ) {
        uint256 n = users.length;
        netContributions = new uint256[](n);
        tiers = new uint8[](n);
        for (uint256 i = 0; i < n; i++) {
            KOMParticipant storage p = komParticipants[launchId][users[i]];
            netContributions[i] = p.netContributionWei;
            tiers[i] = p.tier;
        }
    }

    /// @notice Simulate buy and return (newSupply, newReserve, feeWei) without state change.
    function simulateBuy(uint256 launchId, uint256 weiAmount) external view returns (
        uint256 newSupply,
        uint256 newReserve,
        uint256 feeWei
    ) {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage l = komLaunches[launchId];
        feeWei = (weiAmount * KOM_BUY_FEE_BPS) / KOM_BPS_DENOM;
        uint256 toCurve = weiAmount - feeWei;
        (newSupply, newReserve) = _curveBuy(l.virtualSupply, l.virtualReserve, toCurve);
    }

    /// @notice Simulate sell and return (newSupply, newReserve, outWei, feeWei, toUser).
    function simulateSell(uint256 launchId, uint256 weiAmount) external view returns (
        uint256 newSupply,
        uint256 newReserve,
        uint256 outWei,
        uint256 feeWei,
        uint256 toUser
    ) {
        if (launchId == 0 || launchId > launchNonce) revert KOM_InvalidLaunchId();
        KOMLaunch storage l = komLaunches[launchId];
        (newSupply, newReserve, outWei) = _curveSell(l.virtualSupply, l.virtualReserve, weiAmount);
        feeWei = (outWei * KOM_SELL_FEE_BPS) / KOM_BPS_DENOM;
        toUser = outWei - feeWei;
    }

    /// @notice Returns the launch fee in wei for a given deposit amount.
    function getLaunchFeeForDeposit(uint256 depositWei) external pure returns (uint256 feeWei) {
        return (depositWei * KOM_LAUNCH_FEE_BPS) / KOM_BPS_DENOM;
