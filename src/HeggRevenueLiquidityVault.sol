// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

interface IHeggRevenueLiquidityAdapter {
    function addLiquidityFromRevenue(address hegg, uint256 contributedHegg, uint256 minimumHeggOut)
        external
        payable
        returns (uint256 heggPurchased, uint256 liquidityAdded);
}

/// @notice Upgradeable and fully recoverable treasury that compounds contributed revenue into HEGG liquidity.
/// @dev Starts paused. The keeper can process funds but cannot withdraw or reconfigure the vault.
contract HeggRevenueLiquidityVault is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant ONE = 1 ether;

    IERC20 public hegg;
    IHeggRevenueLiquidityAdapter public adapter;
    address public recoveryRecipient;

    uint256 public nativeReserve;
    uint256 public heggReserve;
    uint256 public minimumNativeProcess;
    uint256 public maximumNativeProcess;
    uint256 public maximumHeggProcess;
    uint256 public dailyNativeCap;
    uint256 public processCooldown;
    uint256 public minimumHeggPerNativeX18;

    uint256 public processedDay;
    uint256 public nativeProcessedToday;
    uint256 public lastProcessedAt;

    event NativeFunded(address indexed sender, uint256 amount);
    event AdapterSet(address indexed previousAdapter, address indexed newAdapter);
    event RecoveryRecipientSet(address indexed previousRecipient, address indexed newRecipient);
    event ReservesSet(uint256 nativeReserve, uint256 heggReserve);
    event ProcessLimitsSet(
        uint256 minimumNative,
        uint256 maximumNative,
        uint256 maximumHegg,
        uint256 dailyNative,
        uint256 cooldown
    );
    event PriceFloorSet(uint256 minimumHeggPerNativeX18);
    event RevenueLiquidityProcessed(
        address indexed keeper,
        uint256 nativeProcessed,
        uint256 heggContributed,
        uint256 heggPurchased,
        uint256 liquidityAdded
    );
    event NativeRecovered(address indexed recipient, uint256 amount);
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    error InvalidConfiguration();
    error ThresholdNotReached();
    error DailyLimitReached();
    error CooldownActive();
    error UnsafeMinimumOutput(uint256 supplied, uint256 required);
    error LiquidityNotAdded();
    error AdapterRetainedFunds();
    error NativeTransferFailed();
    error UpgradeRequiresPause();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address guardian,
        address keeper,
        IERC20 hegg_,
        address recoveryRecipient_
    ) external initializer {
        if (
            admin == address(0) || guardian == address(0) || keeper == address(0)
                || address(hegg_) == address(0) || recoveryRecipient_ == address(0)
        ) revert InvalidConfiguration();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(KEEPER_ROLE, keeper);

        hegg = hegg_;
        recoveryRecipient = recoveryRecipient_;
        _pause();
    }

    receive() external payable {
        emit NativeFunded(msg.sender, msg.value);
    }

    function setAdapter(IHeggRevenueLiquidityAdapter newAdapter)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused
    {
        if (address(newAdapter) == address(0) || address(newAdapter).code.length == 0) {
            revert InvalidConfiguration();
        }
        address previous = address(adapter);
        adapter = newAdapter;
        emit AdapterSet(previous, address(newAdapter));
    }

    function setRecoveryRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        if (newRecipient == address(0)) revert InvalidConfiguration();
        address previous = recoveryRecipient;
        recoveryRecipient = newRecipient;
        emit RecoveryRecipientSet(previous, newRecipient);
    }

    function setReserves(uint256 nativeReserve_, uint256 heggReserve_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused
    {
        nativeReserve = nativeReserve_;
        heggReserve = heggReserve_;
        emit ReservesSet(nativeReserve_, heggReserve_);
    }

    function setProcessLimits(
        uint256 minimumNative,
        uint256 maximumNative,
        uint256 maximumHegg,
        uint256 dailyNative,
        uint256 cooldown
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        if (
            minimumNative < 2 || maximumNative < minimumNative || dailyNative < minimumNative
                || maximumNative > type(uint128).max || maximumHegg == 0 || maximumHegg > type(uint128).max
                || cooldown > 7 days
        ) revert InvalidConfiguration();

        minimumNativeProcess = minimumNative;
        maximumNativeProcess = maximumNative;
        maximumHeggProcess = maximumHegg;
        dailyNativeCap = dailyNative;
        processCooldown = cooldown;
        emit ProcessLimitsSet(minimumNative, maximumNative, maximumHegg, dailyNative, cooldown);
    }

    /// @notice Independent on-chain floor that a keeper-provided quote may never undercut.
    function setMinimumHeggPerNative(uint256 minimumHeggPerNativeX18_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused
    {
        if (minimumHeggPerNativeX18_ == 0) revert InvalidConfiguration();
        minimumHeggPerNativeX18 = minimumHeggPerNativeX18_;
        emit PriceFloorSet(minimumHeggPerNativeX18_);
    }

    function pause() external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, GUARDIAN_ROLE);
        }
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            address(adapter) == address(0) || minimumNativeProcess < 2
                || maximumNativeProcess < minimumNativeProcess || maximumHeggProcess == 0
                || dailyNativeCap < minimumNativeProcess || minimumHeggPerNativeX18 == 0
        ) revert InvalidConfiguration();
        _unpause();
    }

    function remainingDailyNativeCapacity() public view returns (uint256) {
        uint256 day = block.timestamp / 1 days;
        if (processedDay != day) return dailyNativeCap;
        if (nativeProcessedToday >= dailyNativeCap) return 0;
        return dailyNativeCap - nativeProcessedToday;
    }

    function processableNative() public view returns (uint256 amount) {
        if (paused() || address(this).balance <= nativeReserve) return 0;
        amount = address(this).balance - nativeReserve;
        amount = Math.min(amount, maximumNativeProcess);
        amount = Math.min(amount, remainingDailyNativeCapacity());
        if (amount < minimumNativeProcess) return 0;
    }

    function processableHegg() public view returns (uint256 amount) {
        uint256 balance = hegg.balanceOf(address(this));
        if (balance <= heggReserve) return 0;
        amount = Math.min(balance - heggReserve, maximumHeggProcess);
    }

    /// @notice Compounds the currently processable balance into the configured existing position.
    /// @dev The adapter determines the maximum addable liquidity from live pool state; the keeper cannot choose it.
    function processLiquidity(uint256 minimumHeggOut)
        external
        onlyRole(KEEPER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 heggPurchased, uint256 liquidityAdded)
    {
        if (lastProcessedAt != 0 && block.timestamp < lastProcessedAt + processCooldown) {
            revert CooldownActive();
        }

        uint256 nativeAmount = processableNative();
        if (nativeAmount == 0) {
            if (
                address(this).balance <= nativeReserve
                    || address(this).balance - nativeReserve < minimumNativeProcess
            ) {
                revert ThresholdNotReached();
            }
            revert DailyLimitReached();
        }

        uint256 nativeForSwap = nativeAmount / 2;
        uint256 requiredMinimum = Math.mulDiv(nativeForSwap, minimumHeggPerNativeX18, ONE);
        if (minimumHeggOut < requiredMinimum) {
            revert UnsafeMinimumOutput(minimumHeggOut, requiredMinimum);
        }

        uint256 heggAmount = processableHegg();
        uint256 day = block.timestamp / 1 days;
        if (processedDay != day) {
            processedDay = day;
            nativeProcessedToday = 0;
        }
        nativeProcessedToday += nativeAmount;
        lastProcessedAt = block.timestamp;

        if (heggAmount != 0) hegg.safeTransfer(address(adapter), heggAmount);
        (heggPurchased, liquidityAdded) = adapter.addLiquidityFromRevenue{ value: nativeAmount }(
            address(hegg), heggAmount, minimumHeggOut
        );
        if (liquidityAdded == 0) revert LiquidityNotAdded();
        if (address(adapter).balance != 0 || hegg.balanceOf(address(adapter)) != 0) {
            revert AdapterRetainedFunds();
        }

        emit RevenueLiquidityProcessed(msg.sender, nativeAmount, heggAmount, heggPurchased, liquidityAdded);
    }

    function recoverNative(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused nonReentrant {
        if (amount == 0 || amount > address(this).balance) revert InvalidConfiguration();
        (bool success,) = payable(recoveryRecipient).call{ value: amount }("");
        if (!success) revert NativeTransferFailed();
        emit NativeRecovered(recoveryRecipient, amount);
    }

    function recoverToken(IERC20 token, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused
        nonReentrant
    {
        if (address(token) == address(0) || amount == 0 || amount > token.balanceOf(address(this))) {
            revert InvalidConfiguration();
        }
        token.safeTransfer(recoveryRecipient, amount);
        emit TokenRecovered(address(token), recoveryRecipient, amount);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {
        if (!paused()) revert UpgradeRequiresPause();
    }

    uint256[32] private __gap;
}
