// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { HenNFT } from "./HenNFT.sol";

interface IHenFloorOracle {
    function floorPrice() external view returns (uint256 price, uint256 updatedAt);
}

interface IHenMarketplaceAdapter {
    function buyHen(address hen, uint256 henId, address recipient, bytes calldata orderData)
        external
        payable
        returns (uint256 paid);
}

/// @notice Uses the protocol's fixed 10% floor share under strict limits and sends purchases to Hen Trust custody.
contract HenFloorSupportReserve is Ownable2Step, ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint256 public constant DAY = 1 days;

    HenNFT public immutable hen;
    address public immutable trustCustody;
    IHenMarketplaceAdapter public adapter;
    IHenFloorOracle public oracle;
    uint256 public maximumPurchasePrice;
    uint256 public dailyBudget;
    uint256 public purchaseCooldown;
    uint256 public maximumPremiumBps;
    uint256 public maximumOracleAge;
    uint256 public lastPurchaseAt;
    uint256 public spendingDay;
    uint256 public spentToday;
    bool public configurationLocked;

    event AdapterSet(address indexed adapter);
    event OracleSet(address indexed oracle);
    event LimitsSet(
        uint256 maximumPurchasePrice,
        uint256 dailyBudget,
        uint256 purchaseCooldown,
        uint256 maximumPremiumBps,
        uint256 maximumOracleAge
    );
    event ConfigurationLocked();
    event FloorHenPurchased(uint256 indexed henId, uint256 paid, uint256 oracleFloor);

    error InvalidConfiguration();
    error ConfigurationIsLocked();
    error CooldownActive();
    error StaleOracle();
    error PriceAboveLimit();
    error DailyBudgetExceeded();
    error PurchaseFailed();

    constructor(HenNFT hen_, address trustCustody_, address owner_) Ownable(owner_) {
        if (address(hen_) == address(0) || trustCustody_ == address(0)) revert InvalidConfiguration();
        hen = hen_;
        trustCustody = trustCustody_;
    }

    receive() external payable { }

    function setAdapter(IHenMarketplaceAdapter adapter_) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (address(adapter_) == address(0)) revert InvalidConfiguration();
        adapter = adapter_;
        emit AdapterSet(address(adapter_));
    }

    function setOracle(IHenFloorOracle oracle_) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (address(oracle_) == address(0)) revert InvalidConfiguration();
        oracle = oracle_;
        emit OracleSet(address(oracle_));
    }

    function setLimits(
        uint256 maximumPurchasePrice_,
        uint256 dailyBudget_,
        uint256 purchaseCooldown_,
        uint256 maximumPremiumBps_,
        uint256 maximumOracleAge_
    ) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (
            maximumPurchasePrice_ == 0 || dailyBudget_ < maximumPurchasePrice_ || purchaseCooldown_ == 0
                || maximumPremiumBps_ > BPS || maximumOracleAge_ == 0
        ) revert InvalidConfiguration();
        maximumPurchasePrice = maximumPurchasePrice_;
        dailyBudget = dailyBudget_;
        purchaseCooldown = purchaseCooldown_;
        maximumPremiumBps = maximumPremiumBps_;
        maximumOracleAge = maximumOracleAge_;
        emit LimitsSet(
            maximumPurchasePrice_, dailyBudget_, purchaseCooldown_, maximumPremiumBps_, maximumOracleAge_
        );
    }

    function lockConfiguration() external onlyOwner {
        if (
            address(adapter) == address(0) || address(oracle) == address(0) || maximumPurchasePrice == 0
                || dailyBudget < maximumPurchasePrice
        ) revert InvalidConfiguration();
        configurationLocked = true;
        emit ConfigurationLocked();
    }

    /// @notice Anyone may execute an eligible floor purchase; the acquired Hen goes directly to Trust custody.
    function purchase(uint256 henId, uint256 quotedPrice, bytes calldata orderData)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (lastPurchaseAt != 0 && block.timestamp < lastPurchaseAt + purchaseCooldown) {
            revert CooldownActive();
        }
        (uint256 floor, uint256 updatedAt) = oracle.floorPrice();
        if (floor == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maximumOracleAge) {
            revert StaleOracle();
        }
        uint256 oracleCap = floor * (BPS + maximumPremiumBps) / BPS;
        if (
            quotedPrice == 0 || quotedPrice > maximumPurchasePrice || quotedPrice > oracleCap
                || quotedPrice > address(this).balance
        ) revert PriceAboveLimit();

        uint256 currentDay = block.timestamp / DAY;
        if (currentDay != spendingDay) {
            spendingDay = currentDay;
            spentToday = 0;
        }
        if (spentToday + quotedPrice > dailyBudget) revert DailyBudgetExceeded();

        lastPurchaseAt = block.timestamp;
        spentToday += quotedPrice;
        paid = adapter.buyHen{ value: quotedPrice }(address(hen), henId, trustCustody, orderData);
        if (paid > quotedPrice || hen.ownerOf(henId) != trustCustody) revert PurchaseFailed();
        // Account using actual spend if the adapter returned unused value.
        spentToday -= quotedPrice - paid;
        emit FloorHenPurchased(henId, paid, floor);
    }
}
