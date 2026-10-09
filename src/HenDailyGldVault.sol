// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { HenRedemptionVault } from "./HenRedemptionVault.sol";
import { HenNFT } from "./HenNFT.sol";

/// @notice Upgrade-compatible daily GLD distribution for permanently weighted Hens.
/// @dev Historical redemption storage is deliberately retained but ignored after activation.
contract HenDailyGldVault is HenRedemptionVault {
    using SafeERC20 for IERC20;

    uint256 public constant DAILY_EPOCH_DURATION = 1 days;
    uint256 public constant MINIMUM_DAILY_BURN = 1 ether;
    uint256 public constant PARAMETER_CHANGE_DELAY = 7 days;
    uint16 public constant INITIAL_BUFFER_BPS = 300;
    uint16 public constant MAX_BUFFER_BPS = 1_000;
    uint64 public constant INITIAL_WEIGHT_THRESHOLD = 20_000;
    uint64 public constant INITIAL_TAPER_NUMERATOR = 2_000_000;

    struct DailyParameters {
        uint16 bufferBps;
        uint64 weightThreshold;
        uint64 taperNumerator;
    }

    struct DailyEpoch {
        uint128 pool;
        uint128 paid;
        uint128 totalWeight;
        uint64 openedAt;
        uint16 bufferBps;
        uint64 weightThreshold;
        uint64 taperNumerator;
    }

    struct DailyBurnState {
        uint64 epoch;
        uint192 amount;
    }

    // Appended storage. Never reorder or insert fields above this section in a later implementation.
    uint64 public dailyActivationTime;
    bool public dailyAccountingBootstrapped;
    bool public dailySystemPaused;
    uint64 public activeDailyEpoch;
    uint256 public dailyCarry;
    uint256 public dailyMaturedFunding;
    uint256 public dailyPendingFunding;
    uint64 public dailyPendingFundingEpoch;
    uint256 public dailyTrackedGldBalance;
    DailyParameters public dailyParameters;
    DailyParameters public pendingDailyParameters;
    uint64 public pendingDailyParametersExecutableAt;
    uint64 public pendingDailyParametersEffectiveEpoch;
    mapping(uint256 epoch => DailyEpoch) public dailyEpochs;
    mapping(uint256 henId => uint256 epochPlusOne) public lastClaimedDailyEpochPlusOne;
    mapping(uint256 henId => DailyBurnState) private _dailyBurnStates;
    mapping(uint256 epoch => bool blocked) public blockedDailyEpoch;

    event DailyPoolsConfigured(uint64 indexed activationTime, uint16 bufferBps, uint64 weightThreshold);
    event DailyEpochOpened(
        uint256 indexed epoch, uint256 pool, uint256 buffer, uint256 totalWeight, uint16 bufferBps
    );
    event DailyEpochExpired(uint256 indexed epoch, uint256 unclaimedGld);
    event DailyGldClaimed(
        address indexed owner,
        uint256 indexed henId,
        uint256 indexed epoch,
        uint256 heggBurned,
        uint256 gldPaid,
        uint256 nextWeight
    );
    event AdditionalDailyHeggBurned(
        address indexed owner,
        uint256 indexed henId,
        uint256 indexed epoch,
        uint256 heggBurned,
        uint256 burnedToday,
        uint256 nextWeight
    );
    event DailyGldFundingRecorded(
        uint256 indexed receivedEpoch, uint256 indexed eligibleEpoch, uint256 amount
    );
    event DailySystemPauseSet(bool paused, uint256 indexed blockedEpoch);
    event DailyParametersScheduled(
        uint16 bufferBps, uint64 weightThreshold, uint64 taperNumerator, uint64 executableAt
    );
    event DailyParametersQueued(uint256 indexed effectiveEpoch);
    event DailyParametersChanged(uint16 bufferBps, uint64 weightThreshold, uint64 taperNumerator);
    event DailyParametersCancelled();

    error DailyPoolsNotConfigured();
    error DailyPoolsAlreadyActive();
    error InvalidActivationTime();
    error TransitionBurnsFrozen();
    error LegacyRedemptionDisabled();
    error DailyEpochUnavailable();
    error DailyClaimAlreadyCompleted();
    error DailyClaimRequired();
    error BurnMustBeWholeHegg();
    error DailyBurnLimitExceeded(uint256 requestedTotal, uint256 maximum);
    error DailyAccountingMismatch();
    error DailyValueOverflow();
    error InvalidDailyParameters();
    error DailyParametersNotReady();
    error NoScheduledDailyParameters();
    error DailyParametersAlreadyPending();
    error EmptyBatch();
    error BatchLengthMismatch();
    error BatchHenIdsNotStrictlyIncreasing();

    /// @notice Schedules the economic transition at a UTC midnight without activating it early.
    /// @dev Install through upgradeToAndCall. No legacy entitlement survives the activation boundary.
    function initializeDailyPools(uint64 activationTime) external reinitializer(2) {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, DEFAULT_ADMIN_ROLE);
        }
        uint256 earliest =
            ((block.timestamp + DAILY_EPOCH_DURATION - 1) / DAILY_EPOCH_DURATION) * DAILY_EPOCH_DURATION;
        if (
            activationTime == 0 || activationTime % DAILY_EPOCH_DURATION != 0
                || uint256(activationTime) < earliest
        ) revert InvalidActivationTime();

        dailyActivationTime = activationTime;
        dailyParameters = DailyParameters({
            bufferBps: INITIAL_BUFFER_BPS,
            weightThreshold: INITIAL_WEIGHT_THRESHOLD,
            taperNumerator: INITIAL_TAPER_NUMERATOR
        });
        // Capture the already-funded vault at installation. From this point onward, notified
        // deposits are bucketed by their actual UTC arrival day, including before activation.
        uint256 existingGld = gld.balanceOf(address(this));
        dailyAccountingBootstrapped = true;
        dailyCarry = existingGld;
        dailyTrackedGldBalance = existingGld;
        dailyPendingFundingEpoch = uint64(currentDailyEpoch());
        emit DailyPoolsConfigured(activationTime, INITIAL_BUFFER_BPS, INITIAL_WEIGHT_THRESHOLD);
    }

    /// @notice Installing the daily configuration freezes legacy burns until their permanent retirement.
    function burnIntoHenAndClaimGLD(uint256 henId, uint256 heggAmount, uint256 minimumGldOut)
        public
        override
        returns (uint256 gldOut)
    {
        if (_dailyPoolsActive()) revert LegacyRedemptionDisabled();
        if (dailyActivationTime != 0) revert TransitionBurnsFrozen();
        return super.burnIntoHenAndClaimGLD(henId, heggAmount, minimumGldOut);
    }

    function quote(uint256 henId, uint256 heggAmount) public view override returns (uint256) {
        if (_dailyPoolsActive()) revert LegacyRedemptionDisabled();
        if (dailyActivationTime != 0) revert TransitionBurnsFrozen();
        return super.quote(henId, heggAmount);
    }

    /// @notice Burns at least one whole HEGG and collects this Hen's one daily GLD entitlement.
    function burnHeggAndClaimDailyGld(uint256 henId, uint256 heggAmount, uint256 minimumGldOut)
        external
        nonReentrant
        returns (uint256 gldOut)
    {
        uint256 epoch = _requireDailyParticipationOpen();
        address owner = hen.ownerOf(henId);
        if (msg.sender != owner) revert NotHenOwnerOrApproved();
        _openDailyEpoch(epoch);
        DailyEpoch storage terms = dailyEpochs[epoch];
        gldOut = _claimDailyGld(owner, henId, epoch, heggAmount, minimumGldOut, terms);
        if (gldOut != 0) gld.safeTransfer(owner, gldOut);
    }

    /// @notice Adds more permanent weight after today's claim, without changing today's GLD payout.
    function burnAdditionalDailyHegg(uint256 henId, uint256 heggAmount) external nonReentrant {
        uint256 epoch = _requireDailyParticipationOpen();
        address owner = hen.ownerOf(henId);
        if (msg.sender != owner) revert NotHenOwnerOrApproved();
        _openDailyEpoch(epoch);
        DailyEpoch storage terms = dailyEpochs[epoch];
        _growDailyHen(owner, henId, epoch, heggAmount, terms);
    }

    /// @notice Feeds the same whole-HEGG amount to every supplied Hen in one atomic transaction.
    /// @dev Unclaimed Hens collect today's GLD; already-claimed Hens receive next-day weight only.
    ///      Hen IDs must be strictly increasing so a Hen cannot be fed twice accidentally.
    function feedDailyHens(
        uint256[] calldata henIds,
        uint256 heggAmountEach,
        uint256[] calldata minimumGldOuts
    ) external nonReentrant returns (uint256 totalGldOut) {
        uint256 length = henIds.length;
        if (length == 0) revert EmptyBatch();
        if (length != minimumGldOuts.length) revert BatchLengthMismatch();
        for (uint256 i = 1; i < length; ++i) {
            if (henIds[i] <= henIds[i - 1]) revert BatchHenIdsNotStrictlyIncreasing();
        }

        uint256 epoch = _requireDailyParticipationOpen();
        _openDailyEpoch(epoch);
        DailyEpoch storage terms = dailyEpochs[epoch];
        address owner = msg.sender;

        for (uint256 i; i < length; ++i) {
            uint256 henId = henIds[i];
            if (hen.ownerOf(henId) != owner) revert NotHenOwnerOrApproved();
            if (lastClaimedDailyEpochPlusOne[henId] == epoch + 1) {
                _growDailyHen(owner, henId, epoch, heggAmountEach, terms);
            } else {
                totalGldOut += _claimDailyGld(owner, henId, epoch, heggAmountEach, minimumGldOuts[i], terms);
            }
        }

        if (totalGldOut != 0) gld.safeTransfer(owner, totalGldOut);
    }

    /// @notice Opens today's immutable pool; anyone may call and no keeper is trusted.
    function openDailyEpoch() external nonReentrant returns (uint256 epoch) {
        epoch = _requireDailyParticipationOpen();
        _openDailyEpoch(epoch);
    }

    /// @notice Records newly arrived GLD for the next UTC day.
    /// @dev Permissionless and balance-derived, so callers cannot fabricate funding.
    function recordGldDeposit() external nonReentrant returns (uint256 recorded) {
        if (!dailyAccountingBootstrapped) return 0;
        recorded = _syncUnrecordedFunding(currentDailyEpoch());
    }

    function currentDailyEpoch() public view returns (uint256) {
        return block.timestamp / DAILY_EPOCH_DURATION;
    }

    function dailyPoolsActive() external view returns (bool) {
        return _dailyPoolsActive();
    }

    function hasClaimedToday(uint256 henId) external view returns (bool) {
        uint256 epoch = currentDailyEpoch();
        return lastClaimedDailyEpochPlusOne[henId] == epoch + 1;
    }

    function burnedToday(uint256 henId) external view returns (uint256) {
        return _burnedInEpoch(henId, currentDailyEpoch());
    }

    function remainingBurnAllowance(uint256 henId) external view returns (uint256) {
        uint256 epoch = currentDailyEpoch();
        uint256 maximum = dailyBurnLimit(henId);
        uint256 consumed = _burnedInEpoch(henId, epoch);
        return consumed >= maximum ? 0 : maximum - consumed;
    }

    function dailyBurnLimit(uint256 henId) public view returns (uint256) {
        uint256 epoch = currentDailyEpoch();
        DailyParameters memory parameters = _parametersForEpoch(epoch);
        uint256 snapshotWeight = _snapshotWeight(henId, epoch);
        return _dailyBurnLimit(snapshotWeight, parameters);
    }

    /// @notice Exact GLD available to this Hen today before its required HEGG burn.
    function quoteDailyClaim(uint256 henId) external view returns (uint256 gldOut) {
        if (!_dailyPoolsActive() || dailySystemPaused || blockedDailyEpoch[currentDailyEpoch()]) return 0;
        uint256 epoch = currentDailyEpoch();
        if (lastClaimedDailyEpochPlusOne[henId] == epoch + 1) return 0;
        (uint256 pool,, uint256 snapshotTotalWeight) = previewDailyPool();
        if (snapshotTotalWeight == 0) return 0;
        gldOut = Math.mulDiv(pool, _snapshotWeight(henId, epoch), snapshotTotalWeight);
    }

    /// @notice Previews today's fixed pool, its rolling buffer and total snapshot weight.
    function previewDailyPool()
        public
        view
        returns (uint256 pool, uint256 buffer, uint256 snapshotTotalWeight)
    {
        if (!_dailyPoolsActive()) return (0, 0, 0);
        uint256 epoch = currentDailyEpoch();
        DailyEpoch memory opened = dailyEpochs[epoch];
        if (opened.openedAt != 0) {
            return (opened.pool, dailyCarry, opened.totalWeight);
        }

        DailyParameters memory parameters = _parametersForEpoch(epoch);
        uint256 available;
        if (!dailyAccountingBootstrapped) {
            available = gld.balanceOf(address(this));
        } else {
            available = dailyCarry + dailyMaturedFunding;
            if (dailyPendingFundingEpoch < epoch) available += dailyPendingFunding;
            if (activeDailyEpoch != 0 && activeDailyEpoch < epoch) {
                DailyEpoch memory previous = dailyEpochs[activeDailyEpoch];
                available += uint256(previous.pool) - uint256(previous.paid);
            }
        }
        pool = Math.mulDiv(available, BPS - parameters.bufferBps, BPS);
        buffer = available - pool;
        snapshotTotalWeight = totalWeight;
    }

    function scheduleDailyParameters(uint16 bufferBps, uint64 weightThreshold, uint64 taperNumerator)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingDailyParametersExecutableAt != 0 || pendingDailyParametersEffectiveEpoch != 0) {
            revert DailyParametersAlreadyPending();
        }
        _validateDailyParameters(bufferBps, weightThreshold, taperNumerator);
        uint64 executableAt = uint64(block.timestamp + PARAMETER_CHANGE_DELAY);
        pendingDailyParameters = DailyParameters(bufferBps, weightThreshold, taperNumerator);
        pendingDailyParametersExecutableAt = executableAt;
        emit DailyParametersScheduled(bufferBps, weightThreshold, taperNumerator, executableAt);
    }

    function executeDailyParameters() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint64 executableAt = pendingDailyParametersExecutableAt;
        if (executableAt == 0) revert NoScheduledDailyParameters();
        if (block.timestamp < executableAt) revert DailyParametersNotReady();
        uint64 effectiveEpoch = uint64(currentDailyEpoch() + 1);
        delete pendingDailyParametersExecutableAt;
        pendingDailyParametersEffectiveEpoch = effectiveEpoch;
        emit DailyParametersQueued(effectiveEpoch);
    }

    function cancelDailyParameters() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingDailyParametersExecutableAt == 0) revert NoScheduledDailyParameters();
        delete pendingDailyParameters;
        delete pendingDailyParametersExecutableAt;
        emit DailyParametersCancelled();
    }

    /// @notice A pause blocks the whole current UTC day; its unclaimed GLD rolls forward.
    function setDailySystemPaused(bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 epoch = currentDailyEpoch();
        if (dailySystemPaused == paused) return;
        blockedDailyEpoch[epoch] = true;
        dailySystemPaused = paused;
        emit DailySystemPauseSet(paused, epoch);
    }

    function _openDailyEpoch(uint256 epoch) internal {
        if (dailyEpochs[epoch].openedAt != 0) {
            _syncUnrecordedFunding(epoch);
            return;
        }
        if (!dailyAccountingBootstrapped) {
            uint256 actual = gld.balanceOf(address(this));
            dailyAccountingBootstrapped = true;
            dailyTrackedGldBalance = actual;
            dailyCarry = actual;
            dailyPendingFundingEpoch = uint64(epoch);
        } else {
            _syncUnrecordedFunding(epoch);
            _matureFunding(epoch);
            if (activeDailyEpoch != 0 && activeDailyEpoch < epoch) {
                DailyEpoch storage previous = dailyEpochs[activeDailyEpoch];
                uint256 unclaimed = uint256(previous.pool) - uint256(previous.paid);
                dailyCarry += unclaimed;
                emit DailyEpochExpired(activeDailyEpoch, unclaimed);
            }
        }

        uint256 available = dailyCarry + dailyMaturedFunding;
        DailyParameters memory parameters = _activateDailyParameters(epoch);
        uint256 pool = Math.mulDiv(available, BPS - parameters.bufferBps, BPS);
        uint256 buffer = available - pool;
        if (pool > type(uint128).max || totalWeight > type(uint128).max) revert DailyValueOverflow();

        dailyCarry = buffer;
        dailyMaturedFunding = 0;
        activeDailyEpoch = uint64(epoch);
        dailyEpochs[epoch] = DailyEpoch({
            pool: uint128(pool),
            paid: 0,
            totalWeight: uint128(totalWeight),
            openedAt: uint64(block.timestamp),
            bufferBps: parameters.bufferBps,
            weightThreshold: parameters.weightThreshold,
            taperNumerator: parameters.taperNumerator
        });
        emit DailyEpochOpened(epoch, pool, buffer, totalWeight, parameters.bufferBps);
    }

    function _burnDailyHegg(
        address owner,
        uint256 henId,
        uint256 epoch,
        uint256 amount,
        uint256 snapshotWeight,
        DailyEpoch storage terms
    ) internal {
        uint256 previouslyBurned = _burnedInEpoch(henId, epoch);
        uint256 requestedTotal = previouslyBurned + amount;
        DailyParameters memory parameters =
            DailyParameters(terms.bufferBps, terms.weightThreshold, terms.taperNumerator);
        uint256 maximum = _dailyBurnLimit(snapshotWeight, parameters);
        if (requestedTotal > maximum) revert DailyBurnLimitExceeded(requestedTotal, maximum);
        if (amount > type(uint192).max || requestedTotal > type(uint192).max) revert DailyValueOverflow();

        _dailyBurnStates[henId] = DailyBurnState(uint64(epoch), uint192(requestedTotal));
        hegg.burnFrom(owner, amount);
        hen.addBurnedHegg(henId, amount);
        totalWeight += amount;
    }

    function _claimDailyGld(
        address owner,
        uint256 henId,
        uint256 epoch,
        uint256 heggAmount,
        uint256 minimumGldOut,
        DailyEpoch storage terms
    ) internal returns (uint256 gldOut) {
        if (lastClaimedDailyEpochPlusOne[henId] == epoch + 1) {
            revert DailyClaimAlreadyCompleted();
        }
        if (heggAmount < MINIMUM_DAILY_BURN) revert InvalidBurnAmount();
        _requireWholeHegg(heggAmount);

        uint256 snapshotWeight = _snapshotWeight(henId, epoch);
        if (terms.totalWeight != 0) {
            gldOut = Math.mulDiv(uint256(terms.pool), snapshotWeight, uint256(terms.totalWeight));
            gldOut = Math.min(gldOut, uint256(terms.pool) - uint256(terms.paid));
        }
        if (gldOut < minimumGldOut) revert InsufficientOutput(gldOut, minimumGldOut);

        lastClaimedDailyEpochPlusOne[henId] = epoch + 1;
        _burnDailyHegg(owner, henId, epoch, heggAmount, snapshotWeight, terms);
        if (gldOut != 0) {
            terms.paid += uint128(gldOut);
            dailyTrackedGldBalance -= gldOut;
        }
        emit DailyGldClaimed(owner, henId, epoch, heggAmount, gldOut, hen.henData(henId).heggBurned);
    }

    function _growDailyHen(
        address owner,
        uint256 henId,
        uint256 epoch,
        uint256 heggAmount,
        DailyEpoch storage terms
    ) internal {
        if (lastClaimedDailyEpochPlusOne[henId] != epoch + 1) revert DailyClaimRequired();
        if (heggAmount == 0) revert InvalidBurnAmount();
        _requireWholeHegg(heggAmount);

        uint256 snapshotWeight = _snapshotWeight(henId, epoch);
        _burnDailyHegg(owner, henId, epoch, heggAmount, snapshotWeight, terms);
        emit AdditionalDailyHeggBurned(
            owner, henId, epoch, heggAmount, _burnedInEpoch(henId, epoch), hen.henData(henId).heggBurned
        );
    }

    function _dailyBurnLimit(uint256 snapshotWeight, DailyParameters memory parameters)
        internal
        pure
        returns (uint256)
    {
        uint256 threshold = uint256(parameters.weightThreshold) * 1 ether;
        if (snapshotWeight < threshold) {
            // Legacy redemption accepted fractional HEGG. Round the final pre-threshold allowance up
            // to one whole token so a fractional historical weight can never strand its Hen.
            return Math.ceilDiv(threshold - snapshotWeight, 1 ether) * 1 ether;
        }
        uint256 wholeWeight = snapshotWeight / 1 ether;
        uint256 wholeLimit = uint256(parameters.taperNumerator) / wholeWeight;
        if (wholeLimit == 0) wholeLimit = 1;
        return wholeLimit * 1 ether;
    }

    function _snapshotWeight(uint256 henId, uint256 epoch) internal view returns (uint256) {
        HenNFT.HenData memory data = hen.henData(henId);
        return data.heggBurned - _burnedInEpoch(henId, epoch);
    }

    function _burnedInEpoch(uint256 henId, uint256 epoch) internal view returns (uint256) {
        DailyBurnState memory state = _dailyBurnStates[henId];
        return state.epoch == epoch ? state.amount : 0;
    }

    function _syncUnrecordedFunding(uint256 epoch) internal returns (uint256 recorded) {
        _matureFunding(epoch);
        uint256 actual = gld.balanceOf(address(this));
        if (actual < dailyTrackedGldBalance) revert DailyAccountingMismatch();
        recorded = actual - dailyTrackedGldBalance;
        if (recorded == 0) return 0;
        dailyTrackedGldBalance = actual;
        dailyPendingFunding += recorded;
        emit DailyGldFundingRecorded(epoch, epoch + 1, recorded);
    }

    function _matureFunding(uint256 epoch) internal {
        uint256 fundingEpoch = dailyPendingFundingEpoch;
        if (fundingEpoch < epoch) {
            dailyMaturedFunding += dailyPendingFunding;
            dailyPendingFunding = 0;
            dailyPendingFundingEpoch = uint64(epoch);
        }
    }

    function _parametersForEpoch(uint256 epoch) internal view returns (DailyParameters memory parameters) {
        DailyEpoch memory terms = dailyEpochs[epoch];
        if (terms.openedAt == 0) {
            uint256 effectiveEpoch = pendingDailyParametersEffectiveEpoch;
            if (effectiveEpoch != 0 && epoch >= effectiveEpoch) return pendingDailyParameters;
            return dailyParameters;
        }
        parameters = DailyParameters(terms.bufferBps, terms.weightThreshold, terms.taperNumerator);
    }

    function _activateDailyParameters(uint256 epoch) internal returns (DailyParameters memory parameters) {
        uint256 effectiveEpoch = pendingDailyParametersEffectiveEpoch;
        if (effectiveEpoch == 0 || epoch < effectiveEpoch) return dailyParameters;
        parameters = pendingDailyParameters;
        dailyParameters = parameters;
        delete pendingDailyParameters;
        delete pendingDailyParametersEffectiveEpoch;
        emit DailyParametersChanged(
            parameters.bufferBps, parameters.weightThreshold, parameters.taperNumerator
        );
    }

    function _requireDailyParticipationOpen() internal view returns (uint256 epoch) {
        if (dailyActivationTime == 0) revert DailyPoolsNotConfigured();
        if (block.timestamp < dailyActivationTime) revert DailyEpochUnavailable();
        epoch = currentDailyEpoch();
        if (dailySystemPaused || blockedDailyEpoch[epoch]) revert DailyEpochUnavailable();
    }

    function _dailyPoolsActive() internal view returns (bool) {
        return dailyActivationTime != 0 && block.timestamp >= dailyActivationTime;
    }

    function _requireWholeHegg(uint256 amount) internal pure {
        if (amount % 1 ether != 0) revert BurnMustBeWholeHegg();
    }

    function _validateDailyParameters(uint16 bufferBps, uint64 weightThreshold, uint64 taperNumerator)
        internal
        pure
    {
        if (bufferBps > MAX_BUFFER_BPS || weightThreshold == 0 || taperNumerator < weightThreshold) {
            revert InvalidDailyParameters();
        }
    }
}
