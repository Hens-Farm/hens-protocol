// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

interface IHeggEmissionReserve {
    function unearnedHegg() external view returns (uint256);
}

interface IHenWeightSource {
    function totalWeight() external view returns (uint256);
}

/// @notice Permissionless daily snapshots of HEGG's proportional GLD backing.
/// @dev The first redemption in an unsnapshotted day rolls the epoch automatically.
contract GldRateController is Ownable2Step {
    uint256 public constant BPS = 10_000;
    uint256 public constant RATE_SCALE = 1 ether;
    uint256 public constant EPOCH_DURATION = 1 days;
    uint256 public constant BASE_RESERVE_BPS = 9_000;
    uint256 public constant BONUS_RESERVE_BPS = 1_000;
    uint256 public constant LIQUIDITY_BUFFER_BPS = 2_000;
    uint256 public constant DAILY_BASE_CAP_BPS = 400;
    uint256 public constant REWARD_SCALE = 1e18;

    struct EpochTerms {
        uint128 gldPerHegg;
        uint128 baseBudget;
        uint128 baseSpent;
        uint128 bonusBudget;
        uint128 bonusSpent;
        uint128 eligibleHeggSupply;
        uint128 bonusPerWeight;
    }

    IERC20 public immutable gld;
    IERC20 public immutable hegg;
    uint64 public immutable epochStart;
    address public redemptionVault;
    address public emissionReserve;
    uint256 public baseBacking;
    uint256 public bonusBacking;
    uint256 public bonusAllocatedOutstanding;
    uint256 public cumulativeBonusPerWeight;
    bool public configurationLocked;
    bool public futureEpochsPaused;
    mapping(uint256 epoch => EpochTerms) public terms;

    event SystemConfigured(address indexed redemptionVault, address indexed emissionReserve);
    event ConfigurationLocked();
    event FutureEpochsPauseSet(bool paused);
    event EpochRolled(
        uint256 indexed epoch,
        uint256 gldPerHegg,
        uint256 baseBudget,
        uint256 bonusBudget,
        uint256 eligibleHeggSupply,
        uint256 baseBacking,
        uint256 bonusBacking
    );
    event BaseBudgetConsumed(uint256 indexed epoch, uint256 amount, uint256 baseSpent);
    event ReservedBonusPaid(uint256 indexed epoch, uint256 amount, uint256 outstanding);

    error InvalidConfiguration();
    error ConfigurationIsLocked();
    error EpochNotStarted();
    error EpochAlreadyRolled();
    error FutureEpochsPaused();
    error NoEligibleSupply();
    error NoGldBacking();
    error ReserveAccountingMismatch();
    error OnlyRedemptionVault();
    error EpochBudgetExceeded();

    constructor(IERC20 gld_, IERC20 hegg_, uint64 epochStart_, address owner_) Ownable(owner_) {
        if (address(gld_) == address(0) || address(hegg_) == address(0) || epochStart_ == 0) {
            revert InvalidConfiguration();
        }
        gld = gld_;
        hegg = hegg_;
        epochStart = epochStart_;
    }

    function configureSystem(address vault, address emissionReserve_) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (vault == address(0) || emissionReserve_ == address(0)) revert InvalidConfiguration();
        redemptionVault = vault;
        emissionReserve = emissionReserve_;
        emit SystemConfigured(vault, emissionReserve_);
    }

    function lockConfiguration() external onlyOwner {
        if (redemptionVault == address(0) || emissionReserve == address(0)) revert InvalidConfiguration();
        configurationLocked = true;
        emit ConfigurationLocked();
    }

    /// @notice Timelocked governance may stop creation of later snapshots, but cannot alter an existing one.
    function setFutureEpochsPaused(bool paused) external onlyOwner {
        futureEpochsPaused = paused;
        emit FutureEpochsPauseSet(paused);
    }

    /// @notice Anyone may snapshot the current day. A redemption also invokes this automatically.
    function rollEpoch() external returns (uint256 epoch) {
        epoch = _currentEpochChecked();
        if (terms[epoch].gldPerHegg != 0) revert EpochAlreadyRolled();
        _roll(epoch);
    }

    function currentEpoch() public view returns (uint256) {
        if (block.timestamp < epochStart) return 0;
        return (block.timestamp - epochStart) / EPOCH_DURATION;
    }

    /// @notice Returns the fixed rate for a rolled day or the deterministic rate its first user will snapshot.
    function currentRate() external view returns (uint256) {
        uint256 epoch = currentEpoch();
        uint256 rate = terms[epoch].gldPerHegg;
        if (rate != 0 || block.timestamp < epochStart) return rate;
        (rate,,,,,) = previewCurrentEpoch();
        return rate;
    }

    function previewCurrentEpoch()
        public
        view
        returns (
            uint256 gldPerHegg,
            uint256 baseBudget,
            uint256 bonusBudget,
            uint256 eligibleSupply,
            uint256 projectedBaseBacking,
            uint256 projectedBonusBacking
        )
    {
        eligibleSupply = _eligibleSupply();
        (projectedBaseBacking, projectedBonusBacking) = _projectedBacking();
        if (eligibleSupply == 0 || projectedBaseBacking == 0) {
            return (0, 0, 0, eligibleSupply, projectedBaseBacking, projectedBonusBacking);
        }
        uint256 deployableBase = projectedBaseBacking * (BPS - LIQUIDITY_BUFFER_BPS) / BPS;
        gldPerHegg = Math.mulDiv(deployableBase, RATE_SCALE, eligibleSupply);
        baseBudget = deployableBase * DAILY_BASE_CAP_BPS / BPS;
        uint256 availableBonus = projectedBonusBacking - bonusAllocatedOutstanding;
        if (_totalWeight() != 0) {
            bonusBudget = availableBonus * (BPS - LIQUIDITY_BUFFER_BPS) / BPS;
        }
    }

    function remainingBudgets() external view returns (uint256 baseRemaining, uint256 bonusRemaining) {
        EpochTerms memory epoch = terms[currentEpoch()];
        if (epoch.gldPerHegg == 0) {
            (, baseRemaining,,,,) = previewCurrentEpoch();
        } else {
            baseRemaining = epoch.baseBudget - epoch.baseSpent;
        }
        bonusRemaining = bonusAllocatedOutstanding;
    }

    function previewBonusAccumulator() external view returns (uint256 accumulator) {
        accumulator = cumulativeBonusPerWeight;
        uint256 epochId = currentEpoch();
        if (block.timestamp < epochStart || terms[epochId].gldPerHegg != 0) return accumulator;
        (,, uint256 bonusBudget,,,) = previewCurrentEpoch();
        uint256 weight = _totalWeight();
        if (weight != 0) accumulator += Math.mulDiv(bonusBudget, REWARD_SCALE, weight);
    }

    /// @notice Called by the vault; automatically rolls the day before consuming base capacity.
    function consumeBase(uint256 baseAmount) external {
        if (msg.sender != redemptionVault) revert OnlyRedemptionVault();
        uint256 epochId = _currentEpochChecked();
        if (terms[epochId].gldPerHegg == 0) _roll(epochId);
        EpochTerms storage epoch = terms[epochId];
        if (uint256(epoch.baseSpent) + baseAmount > epoch.baseBudget) revert EpochBudgetExceeded();

        epoch.baseSpent += uint128(baseAmount);
        baseBacking -= baseAmount;
        emit BaseBudgetConsumed(epochId, baseAmount, epoch.baseSpent);
    }

    /// @notice Pays only GLD already reserved by daily pro-rata weight snapshots.
    function consumeReservedBonus(uint256 bonusAmount) external {
        if (msg.sender != redemptionVault) revert OnlyRedemptionVault();
        if (bonusAmount > bonusAllocatedOutstanding) revert EpochBudgetExceeded();
        uint256 epochId = _currentEpochChecked();
        bonusAllocatedOutstanding -= bonusAmount;
        bonusBacking -= bonusAmount;
        emit ReservedBonusPaid(epochId, bonusAmount, bonusAllocatedOutstanding);
    }

    function _roll(uint256 epoch) internal {
        if (!configurationLocked) revert InvalidConfiguration();
        if (futureEpochsPaused) revert FutureEpochsPaused();
        uint256 eligibleSupply = _eligibleSupply();
        if (eligibleSupply == 0) revert NoEligibleSupply();
        (uint256 projectedBase, uint256 projectedBonus) = _projectedBacking();
        if (projectedBase == 0) revert NoGldBacking();

        uint256 deployableBase = projectedBase * (BPS - LIQUIDITY_BUFFER_BPS) / BPS;
        uint256 rate = Math.mulDiv(deployableBase, RATE_SCALE, eligibleSupply);
        uint256 baseBudget = deployableBase * DAILY_BASE_CAP_BPS / BPS;
        uint256 totalWeight_ = _totalWeight();
        uint256 availableBonus = projectedBonus - bonusAllocatedOutstanding;
        uint256 proposedBonus = totalWeight_ == 0 ? 0 : availableBonus * (BPS - LIQUIDITY_BUFFER_BPS) / BPS;
        uint256 bonusPerWeight =
            totalWeight_ == 0 ? 0 : Math.mulDiv(proposedBonus, REWARD_SCALE, totalWeight_);
        uint256 bonusBudget = totalWeight_ == 0 ? 0 : Math.mulDiv(bonusPerWeight, totalWeight_, REWARD_SCALE);
        if (
            rate == 0 || rate > type(uint128).max || baseBudget > type(uint128).max
                || bonusBudget > type(uint128).max || eligibleSupply > type(uint128).max
                || bonusPerWeight > type(uint128).max
        ) revert InvalidConfiguration();

        baseBacking = projectedBase;
        bonusBacking = projectedBonus;
        terms[epoch] = EpochTerms({
            gldPerHegg: uint128(rate),
            baseBudget: uint128(baseBudget),
            baseSpent: 0,
            bonusBudget: uint128(bonusBudget),
            bonusSpent: 0,
            eligibleHeggSupply: uint128(eligibleSupply),
            bonusPerWeight: uint128(bonusPerWeight)
        });
        cumulativeBonusPerWeight += bonusPerWeight;
        bonusAllocatedOutstanding += bonusBudget;
        emit EpochRolled(epoch, rate, baseBudget, bonusBudget, eligibleSupply, projectedBase, projectedBonus);
    }

    function _eligibleSupply() internal view returns (uint256) {
        uint256 total = hegg.totalSupply();
        uint256 unearned =
            emissionReserve == address(0) ? 0 : IHeggEmissionReserve(emissionReserve).unearnedHegg();
        if (unearned > total) revert ReserveAccountingMismatch();
        return total - unearned;
    }

    function _projectedBacking() internal view returns (uint256 projectedBase, uint256 projectedBonus) {
        uint256 accounted = baseBacking + bonusBacking;
        uint256 actual = redemptionVault == address(0) ? 0 : gld.balanceOf(redemptionVault);
        if (actual < accounted) revert ReserveAccountingMismatch();
        uint256 newGld = actual - accounted;
        uint256 newBonus = newGld * BONUS_RESERVE_BPS / BPS;
        projectedBase = baseBacking + newGld - newBonus;
        projectedBonus = bonusBacking + newBonus;
    }

    function _totalWeight() internal view returns (uint256) {
        if (redemptionVault == address(0) || redemptionVault.code.length == 0) return 0;
        try IHenWeightSource(redemptionVault).totalWeight() returns (uint256 weight) {
            return weight;
        } catch {
            return 0;
        }
    }

    function _currentEpochChecked() internal view returns (uint256) {
        if (block.timestamp < epochStart) revert EpochNotStarted();
        return (block.timestamp - epochStart) / EPOCH_DURATION;
    }
}
