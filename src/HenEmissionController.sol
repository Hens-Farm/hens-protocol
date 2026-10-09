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
import { HenNFT } from "./HenNFT.sol";

interface IBurnableHegg {
    function burn(uint256 amount) external;
}

contract HenEmissionController is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    uint256 public constant EPOCH = 90 days;
    uint256 public constant HALVING_EPOCHS = 8;
    uint256 public constant CLAIM_EXPIRY = 365 days;

    IERC20 public hegg;
    HenNFT public hen;
    uint64 public emissionStart;
    uint256 public initialRatePerHenPerSecond;
    mapping(uint256 henId => uint64) public lastClaimAt;
    uint256 public initialEmissionReserve;
    uint256 public emissionReserveConsumed;

    event EmissionsClaimed(address indexed owner, uint256 indexed henId, uint256 amount);
    event ExpiredEmissionsSwept(uint256 indexed henId, uint256 amount);

    error NotHenOwner();
    error EmissionsNotStarted();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        IERC20 hegg_,
        HenNFT hen_,
        uint64 emissionStart_,
        uint256 initialRatePerHenPerSecond_,
        uint256 initialEmissionReserve_
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        hegg = hegg_;
        hen = hen_;
        emissionStart = emissionStart_;
        initialRatePerHenPerSecond = initialRatePerHenPerSecond_;
        initialEmissionReserve = initialEmissionReserve_;
    }

    function claim(uint256[] calldata henIds) external nonReentrant returns (uint256 total) {
        if (block.timestamp < emissionStart) revert EmissionsNotStarted();
        uint256 totalExpired;
        for (uint256 i; i < henIds.length; ++i) {
            uint256 henId = henIds[i];
            if (hen.ownerOf(henId) != msg.sender) revert NotHenOwner();
            HenNFT.HenData memory data = hen.henData(henId);
            uint256 start = lastClaimAt[henId];
            if (start == 0) start = data.mintedAt > emissionStart ? data.mintedAt : emissionStart;
            uint256 expiryFloor = block.timestamp > CLAIM_EXPIRY ? block.timestamp - CLAIM_EXPIRY : 0;
            if (start < expiryFloor) {
                uint256 expired = emittedBetween(start, expiryFloor);
                totalExpired += expired;
                emit ExpiredEmissionsSwept(henId, expired);
                start = expiryFloor;
            }
            uint256 amount = emittedBetween(start, block.timestamp);
            lastClaimAt[henId] = uint64(block.timestamp);
            total += amount;
            emit EmissionsClaimed(msg.sender, henId, amount);
        }
        emissionReserveConsumed += total + totalExpired;
        hegg.safeTransfer(msg.sender, total);
        if (totalExpired != 0) IBurnableHegg(address(hegg)).burn(totalExpired);
    }

    /// @notice Anyone may permanently burn rewards older than the claim window.
    function sweepExpired(uint256[] calldata henIds) external nonReentrant returns (uint256 totalExpired) {
        if (block.timestamp < emissionStart + CLAIM_EXPIRY) return 0;
        uint256 expiryFloor = block.timestamp - CLAIM_EXPIRY;
        for (uint256 i; i < henIds.length; ++i) {
            uint256 henId = henIds[i];
            HenNFT.HenData memory data = hen.henData(henId);
            uint256 start = lastClaimAt[henId];
            if (start == 0) start = data.mintedAt > emissionStart ? data.mintedAt : emissionStart;
            if (start >= expiryFloor) continue;
            uint256 expired = emittedBetween(start, expiryFloor);
            lastClaimAt[henId] = uint64(expiryFloor);
            totalExpired += expired;
            emit ExpiredEmissionsSwept(henId, expired);
        }
        if (totalExpired != 0) {
            emissionReserveConsumed += totalExpired;
            IBurnableHegg(address(hegg)).burn(totalExpired);
        }
    }

    function claimable(uint256 henId) external view returns (uint256) {
        HenNFT.HenData memory data = hen.henData(henId);
        if (block.timestamp < emissionStart) return 0;
        uint256 start = lastClaimAt[henId];
        if (start == 0) start = data.mintedAt > emissionStart ? data.mintedAt : emissionStart;
        uint256 expiryFloor = block.timestamp > CLAIM_EXPIRY ? block.timestamp - CLAIM_EXPIRY : 0;
        if (start < expiryFloor) start = expiryFloor;
        return emittedBetween(start, block.timestamp);
    }

    function rateAt(uint256 timestamp) public view returns (uint256) {
        if (timestamp < emissionStart) return 0;
        uint256 epoch = (timestamp - emissionStart) / EPOCH;
        if (epoch > HALVING_EPOCHS) epoch = HALVING_EPOCHS;
        return initialRatePerHenPerSecond >> epoch;
    }

    /// @notice Schedule-tracked reserve remaining; unsolicited HEGG transfers cannot change it.
    function unearnedHegg() external view returns (uint256) {
        return initialEmissionReserve - emissionReserveConsumed;
    }

    function emittedBetween(uint256 from, uint256 to) public view returns (uint256 amount) {
        if (to <= from || to <= emissionStart) return 0;
        if (from < emissionStart) from = emissionStart;
        uint256 cursor = from;
        while (cursor < to) {
            uint256 epoch = (cursor - emissionStart) / EPOCH;
            uint256 boundedEpoch = epoch > HALVING_EPOCHS ? HALVING_EPOCHS : epoch;
            uint256 nextBoundary =
                boundedEpoch == HALVING_EPOCHS ? to : uint256(emissionStart) + (boundedEpoch + 1) * EPOCH;
            uint256 end = nextBoundary < to ? nextBoundary : to;
            amount += (end - cursor) * (initialRatePerHenPerSecond >> boundedEpoch);
            cursor = end;
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) { }
}
