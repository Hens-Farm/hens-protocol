// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IHeggLiquidityAdapter {
    /// @notice Uses native value to buy HEGG and pair it with native value, sending LP tokens to `lpRecipient`.
    function addLiquidityFromNative(
        address hegg,
        uint256 minimumHeggOut,
        uint256 minimumLpOut,
        address lpRecipient
    ) external payable returns (uint256 heggAdded, uint256 nativeAdded, uint256 lpOut);
}

/// @notice Converts the protocol's fixed 10% revenue share into HEGG liquidity.
contract HeggLiquidityManager is Ownable2Step, ReentrancyGuard {
    address public immutable hegg;
    address public immutable lpRecipient;
    IHeggLiquidityAdapter public adapter;
    uint256 public minimumProcessAmount;
    uint256 public maximumProcessAmount;
    bool public configurationLocked;

    event AdapterSet(address indexed adapter);
    event ProcessLimitsSet(uint256 minimumAmount, uint256 maximumAmount);
    event ConfigurationLocked();
    event LiquidityAdded(uint256 nativeIn, uint256 heggAdded, uint256 nativeAdded, uint256 lpOut);

    error InvalidConfiguration();
    error ConfigurationIsLocked();
    error ThresholdNotReached();

    constructor(address hegg_, address lpRecipient_, address owner_) Ownable(owner_) {
        if (hegg_ == address(0) || lpRecipient_ == address(0)) revert InvalidConfiguration();
        hegg = hegg_;
        lpRecipient = lpRecipient_;
    }

    receive() external payable { }

    function setAdapter(IHeggLiquidityAdapter adapter_) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (address(adapter_) == address(0)) revert InvalidConfiguration();
        adapter = adapter_;
        emit AdapterSet(address(adapter_));
    }

    function setProcessLimits(uint256 minimumAmount, uint256 maximumAmount) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (minimumAmount == 0 || maximumAmount < minimumAmount) revert InvalidConfiguration();
        minimumProcessAmount = minimumAmount;
        maximumProcessAmount = maximumAmount;
        emit ProcessLimitsSet(minimumAmount, maximumAmount);
    }

    function lockConfiguration() external onlyOwner {
        if (
            address(adapter) == address(0) || minimumProcessAmount == 0
                || maximumProcessAmount < minimumProcessAmount
        ) revert InvalidConfiguration();
        configurationLocked = true;
        emit ConfigurationLocked();
    }

    /// @notice Anyone may process revenue once the threshold is reached.
    function processLiquidity(uint256 minimumHeggOut, uint256 minimumLpOut)
        external
        nonReentrant
        returns (uint256 heggAdded, uint256 nativeAdded, uint256 lpOut)
    {
        uint256 balance = address(this).balance;
        if (balance < minimumProcessAmount) revert ThresholdNotReached();
        uint256 amount = balance > maximumProcessAmount ? maximumProcessAmount : balance;
        (heggAdded, nativeAdded, lpOut) = adapter.addLiquidityFromNative{ value: amount }(
            hegg, minimumHeggOut, minimumLpOut, lpRecipient
        );
        emit LiquidityAdded(amount, heggAdded, nativeAdded, lpOut);
    }
}
