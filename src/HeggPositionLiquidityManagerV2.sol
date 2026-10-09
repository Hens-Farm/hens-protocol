// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Adapter used by the recoverable V2 manager to increase one existing HEGG position.
interface IHeggPositionLiquidityAdapterV2 {
    function addLiquidityFromNative(
        address hegg,
        uint256 minimumHeggOut,
        uint256 liquidityToAdd,
        address positionOwner
    ) external payable returns (uint256 heggPurchased, uint256 nativeAllocated, uint256 liquidityAdded);
}

/// @notice Recoverable funding manager for an externally owned, existing Uniswap v4 position.
/// @dev Starts paused. The owner must configure an adapter and limits before activation.
contract HeggPositionLiquidityManagerV2 is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable hegg;
    address public immutable positionOwner;

    IHeggPositionLiquidityAdapterV2 public adapter;
    address public processor;
    uint256 public minimumProcessAmount;
    uint256 public maximumProcessAmount;
    uint256 public dailyProcessCap;
    uint256 public processedDay;
    uint256 public processedToday;

    event NativeFunded(address indexed sender, uint256 amount);
    event AdapterSet(address indexed previousAdapter, address indexed newAdapter);
    event ProcessorSet(address indexed previousProcessor, address indexed newProcessor);
    event ProcessLimitsSet(uint256 minimumAmount, uint256 maximumAmount, uint256 dailyCap);
    event LiquidityProcessed(
        uint256 nativeProcessed, uint256 heggPurchased, uint256 nativeAllocated, uint256 liquidityAdded
    );
    event NativeRecovered(address indexed recipient, uint256 amount);
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    error UnauthorizedProcessor();
    error InvalidConfiguration();
    error ThresholdNotReached();
    error DailyLimitReached();
    error NativeTransferFailed();

    constructor(IERC20 hegg_, address positionOwner_, address initialOwner_, address initialProcessor_)
        Ownable(initialOwner_)
    {
        if (
            address(hegg_) == address(0) || positionOwner_ == address(0) || initialOwner_ == address(0)
                || initialProcessor_ == address(0)
        ) revert InvalidConfiguration();

        hegg = hegg_;
        positionOwner = positionOwner_;
        processor = initialProcessor_;
        _pause();
    }

    receive() external payable {
        emit NativeFunded(msg.sender, msg.value);
    }

    modifier onlyProcessorOrOwner() {
        if (msg.sender != processor && msg.sender != owner()) revert UnauthorizedProcessor();
        _;
    }

    /// @notice Adapter changes remain possible after a fault, but only while processing is paused.
    function setAdapter(IHeggPositionLiquidityAdapterV2 newAdapter) external onlyOwner whenPaused {
        if (address(newAdapter) == address(0)) revert InvalidConfiguration();
        address previous = address(adapter);
        adapter = newAdapter;
        emit AdapterSet(previous, address(newAdapter));
    }

    function setProcessor(address newProcessor) external onlyOwner {
        if (newProcessor == address(0)) revert InvalidConfiguration();
        address previous = processor;
        processor = newProcessor;
        emit ProcessorSet(previous, newProcessor);
    }

    function setProcessLimits(uint256 minimumAmount, uint256 maximumAmount, uint256 dailyCap)
        external
        onlyOwner
        whenPaused
    {
        if (minimumAmount == 0 || maximumAmount < minimumAmount || dailyCap < minimumAmount) {
            revert InvalidConfiguration();
        }
        minimumProcessAmount = minimumAmount;
        maximumProcessAmount = maximumAmount;
        dailyProcessCap = dailyCap;
        emit ProcessLimitsSet(minimumAmount, maximumAmount, dailyCap);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        if (
            address(adapter) == address(0) || processor == address(0) || minimumProcessAmount == 0
                || maximumProcessAmount < minimumProcessAmount || dailyProcessCap < minimumProcessAmount
        ) revert InvalidConfiguration();
        _unpause();
    }

    function remainingDailyCapacity() public view returns (uint256) {
        uint256 day = block.timestamp / 1 days;
        if (processedDay != day) return dailyProcessCap;
        if (processedToday >= dailyProcessCap) return 0;
        return dailyProcessCap - processedToday;
    }

    function processableAmount() public view returns (uint256) {
        if (paused()) return 0;
        uint256 balance = address(this).balance;
        uint256 capacity = remainingDailyCapacity();
        uint256 amount = balance > maximumProcessAmount ? maximumProcessAmount : balance;
        if (amount > capacity) amount = capacity;
        return amount >= minimumProcessAmount ? amount : 0;
    }

    /// @notice Processes at most the configured maximum using caller-supplied, keeper-validated bounds.
    function processLiquidity(uint256 minimumHeggOut, uint256 liquidityToAdd)
        external
        onlyProcessorOrOwner
        whenNotPaused
        nonReentrant
        returns (uint256 heggPurchased, uint256 nativeAllocated, uint256 liquidityAdded)
    {
        if (minimumHeggOut == 0 || liquidityToAdd == 0) revert InvalidConfiguration();

        uint256 balance = address(this).balance;
        if (balance < minimumProcessAmount) revert ThresholdNotReached();
        uint256 amount = processableAmount();
        if (amount == 0) revert DailyLimitReached();

        uint256 day = block.timestamp / 1 days;
        if (processedDay != day) {
            processedDay = day;
            processedToday = 0;
        }
        processedToday += amount;

        (heggPurchased, nativeAllocated, liquidityAdded) = adapter.addLiquidityFromNative{ value: amount }(
            address(hegg), minimumHeggOut, liquidityToAdd, positionOwner
        );
        if (liquidityAdded != liquidityToAdd) revert InvalidConfiguration();

        emit LiquidityProcessed(amount, heggPurchased, nativeAllocated, liquidityAdded);
    }

    /// @notice Recovers unprocessed native funds while paused, preventing another permanent lock.
    function recoverNative(address payable recipient, uint256 amount)
        external
        onlyOwner
        whenPaused
        nonReentrant
    {
        if (recipient == address(0) || amount == 0 || amount > address(this).balance) {
            revert InvalidConfiguration();
        }
        (bool success,) = recipient.call{ value: amount }("");
        if (!success) revert NativeTransferFailed();
        emit NativeRecovered(recipient, amount);
    }

    /// @notice Recovers tokens accidentally sent to the manager while paused.
    function recoverToken(IERC20 token, address recipient, uint256 amount) external onlyOwner whenPaused {
        if (address(token) == address(0) || recipient == address(0) || amount == 0) {
            revert InvalidConfiguration();
        }
        token.safeTransfer(recipient, amount);
        emit TokenRecovered(address(token), recipient, amount);
    }
}
