// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IHeggSwapAdapter {
    function swapExactTokensForNative(address token, uint256 amount, uint256 minimumOut, address recipient)
        external
        returns (uint256 nativeOut);
}

/// @notice Holds HEGG trade fees and swaps bounded batches to native value for the revenue splitter.
contract HeggFeeCollector is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable hegg;
    address public immutable vault;
    IHeggSwapAdapter public adapter;
    uint256 public swapThreshold;
    uint256 public maximumSwapAmount;
    bool public configurationLocked;

    event AdapterSet(address indexed adapter);
    event SwapLimitsSet(uint256 threshold, uint256 maximumAmount);
    event ConfigurationLocked();
    event FeesProcessed(uint256 heggIn, uint256 nativeOut);

    error InvalidConfiguration();
    error ConfigurationIsLocked();
    error ThresholdNotReached();
    error InsufficientOutput();

    constructor(IERC20 hegg_, address vault_, address owner_) Ownable(owner_) {
        if (address(hegg_) == address(0) || vault_ == address(0)) revert InvalidConfiguration();
        hegg = hegg_;
        vault = vault_;
    }

    function setAdapter(IHeggSwapAdapter adapter_) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (address(adapter_) == address(0)) revert InvalidConfiguration();
        adapter = adapter_;
        emit AdapterSet(address(adapter_));
    }

    function setSwapLimits(uint256 threshold, uint256 maximumAmount) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (threshold == 0 || maximumAmount < threshold) revert InvalidConfiguration();
        swapThreshold = threshold;
        maximumSwapAmount = maximumAmount;
        emit SwapLimitsSet(threshold, maximumAmount);
    }

    /// @notice Permanently freezes the swap route and processing bounds.
    function lockConfiguration() external onlyOwner {
        if (address(adapter) == address(0) || swapThreshold == 0 || maximumSwapAmount < swapThreshold) {
            revert InvalidConfiguration();
        }
        configurationLocked = true;
        emit ConfigurationLocked();
    }

    function processFees(uint256 minimumNativeOut) external nonReentrant returns (uint256 nativeOut) {
        uint256 balance = hegg.balanceOf(address(this));
        if (balance < swapThreshold) revert ThresholdNotReached();
        uint256 amount = balance > maximumSwapAmount ? maximumSwapAmount : balance;
        hegg.forceApprove(address(adapter), amount);
        nativeOut = adapter.swapExactTokensForNative(address(hegg), amount, minimumNativeOut, vault);
        hegg.forceApprove(address(adapter), 0);
        if (nativeOut < minimumNativeOut) revert InsufficientOutput();
        emit FeesProcessed(amount, nativeOut);
    }
}
