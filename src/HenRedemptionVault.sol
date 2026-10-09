// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { HeggToken } from "./HeggToken.sol";
import { HenNFT } from "./HenNFT.sol";
import { GldRateController } from "./GldRateController.sol";

contract HenRedemptionVault is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant WEIGHT_UNIT = 1_000 ether;
    uint256 public constant MAXIMUM_BONUS_BPS = 20_000;

    HeggToken public hegg;
    HenNFT public hen;
    IERC20 public gld;
    GldRateController public rateController;
    uint256 public totalWeight;
    mapping(uint256 henId => uint256) public bonusDebt;
    mapping(uint256 henId => uint256) public reservedBonus;
    mapping(uint256 henId => uint256) public lifetimeBasePaid;
    mapping(uint256 henId => uint256) public lifetimeBonusPaid;

    event HeggBurnedIntoHen(
        address indexed account,
        uint256 indexed henId,
        uint256 heggBurned,
        uint256 gldPaid,
        uint256 previousWeightUnits,
        uint256 newWeightUnits
    );
    error NotHenOwnerOrApproved();
    error InvalidBurnAmount();
    error RedemptionUnavailable();
    error InsufficientOutput(uint256 output, uint256 minimum);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        HeggToken hegg_,
        HenNFT hen_,
        IERC20 gld_,
        GldRateController rateController_
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        hegg = hegg_;
        hen = hen_;
        gld = gld_;
        rateController = rateController_;
    }

    /// @notice Burns HEGG, pays GLD atomically, then increases the Hen's weight for its next redemption.
    function burnIntoHenAndClaimGLD(uint256 henId, uint256 heggAmount, uint256 minimumGldOut)
        public
        virtual
        nonReentrant
        returns (uint256 gldOut)
    {
        address owner = hen.ownerOf(henId);
        if (
            msg.sender != owner && hen.getApproved(henId) != msg.sender
                && !hen.isApprovedForAll(owner, msg.sender)
        ) {
            revert NotHenOwnerOrApproved();
        }
        if (heggAmount == 0) revert InvalidBurnAmount();

        HenNFT.HenData memory data = hen.henData(henId);
        uint256 previousUnits = data.heggBurned / WEIGHT_UNIT;
        uint256 requestedBaseGld = Math.mulDiv(heggAmount, rateController.currentRate(), 1 ether);
        (uint256 baseRemaining,) = rateController.remainingBudgets();
        uint256 vaultBalance = gld.balanceOf(address(this));
        uint256 baseGld = Math.min(requestedBaseGld, Math.min(baseRemaining, vaultBalance));

        // This permissionlessly rolls an uninitialized day before adding the current burn's weight,
        // so no keeper is required and a caller cannot enter that day's bonus snapshot retroactively.
        if (baseGld != 0) rateController.consumeBase(baseGld);
        uint256 accumulator = rateController.cumulativeBonusPerWeight();
        uint256 oldWeight = data.heggBurned;
        uint256 newlyEarned = Math.mulDiv(oldWeight, accumulator, 1 ether) - bonusDebt[henId];
        uint256 availableBonus = reservedBonus[henId] + newlyEarned;
        uint256 newLifetimeBase = lifetimeBasePaid[henId] + baseGld;
        uint256 maximumLifetimeBonus = Math.mulDiv(newLifetimeBase, MAXIMUM_BONUS_BPS, BPS);
        uint256 bonusCapacity = maximumLifetimeBonus - lifetimeBonusPaid[henId];
        uint256 bonusGld = Math.min(availableBonus, Math.min(bonusCapacity, vaultBalance - baseGld));
        gldOut = baseGld + bonusGld;
        if (gldOut < minimumGldOut) revert InsufficientOutput(gldOut, minimumGldOut);

        if (bonusGld != 0) rateController.consumeReservedBonus(bonusGld);
        hegg.burnFrom(msg.sender, heggAmount);
        if (gldOut != 0) gld.safeTransfer(msg.sender, gldOut);
        hen.addBurnedHegg(henId, heggAmount);
        totalWeight += heggAmount;
        lifetimeBasePaid[henId] = newLifetimeBase;
        lifetimeBonusPaid[henId] += bonusGld;
        reservedBonus[henId] = availableBonus - bonusGld;
        bonusDebt[henId] = Math.mulDiv(oldWeight + heggAmount, accumulator, 1 ether);

        emit HeggBurnedIntoHen(
            msg.sender, henId, heggAmount, gldOut, previousUnits, (data.heggBurned + heggAmount) / WEIGHT_UNIT
        );
    }

    function quote(uint256 henId, uint256 heggAmount) public view virtual returns (uint256) {
        HenNFT.HenData memory data = hen.henData(henId);
        uint256 requestedBaseGld = Math.mulDiv(heggAmount, rateController.currentRate(), 1 ether);
        (uint256 baseRemaining,) = rateController.remainingBudgets();
        uint256 vaultBalance = gld.balanceOf(address(this));
        uint256 baseGld = Math.min(requestedBaseGld, Math.min(baseRemaining, vaultBalance));
        uint256 accumulator = rateController.previewBonusAccumulator();
        uint256 newlyEarned = Math.mulDiv(data.heggBurned, accumulator, 1 ether) - bonusDebt[henId];
        uint256 availableBonus = reservedBonus[henId] + newlyEarned;
        uint256 maximumLifetimeBonus = Math.mulDiv(lifetimeBasePaid[henId] + baseGld, MAXIMUM_BONUS_BPS, BPS);
        uint256 bonusCapacity = maximumLifetimeBonus - lifetimeBonusPaid[henId];
        return baseGld + Math.min(availableBonus, Math.min(bonusCapacity, vaultBalance - baseGld));
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) { }
}
