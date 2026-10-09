// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IGldSwapAdapter {
    function swapNativeForGld(address gld, uint256 minimumGldOut, address recipient)
        external
        payable
        returns (uint256 gldOut);

    function swapTokenForGld(
        address inputToken,
        address gld,
        uint256 amount,
        uint256 minimumGldOut,
        address recipient
    ) external returns (uint256 gldOut);
}

interface IDailyGldDepositRecorder {
    function recordGldDeposit() external returns (uint256 recorded);
}

/// @notice Converts the protocol's 70% revenue share into GLD sent directly to the redemption vault.
contract GldAcquisitionManager is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Limits {
        uint128 minimum;
        uint128 maximum;
    }

    IERC20 public immutable gld;
    address public immutable redemptionVault;
    IGldSwapAdapter public adapter;
    Limits public nativeLimits;
    mapping(address token => Limits) public tokenLimits;
    bool public configurationLocked;

    event AdapterSet(address indexed adapter);
    event NativeLimitsSet(uint256 minimum, uint256 maximum);
    event TokenLimitsSet(address indexed token, uint256 minimum, uint256 maximum);
    event ConfigurationLocked();
    event NativeRevenueConverted(uint256 nativeIn, uint256 gldOut);
    event TokenRevenueConverted(address indexed token, uint256 tokenIn, uint256 gldOut);
    event VaultFundingNotification(bool recorded);

    error InvalidConfiguration();
    error ConfigurationIsLocked();
    error ThresholdNotReached();
    error InsufficientOutput();

    constructor(IERC20 gld_, address redemptionVault_, address owner_) Ownable(owner_) {
        if (address(gld_) == address(0) || redemptionVault_ == address(0)) revert InvalidConfiguration();
        gld = gld_;
        redemptionVault = redemptionVault_;
    }

    receive() external payable { }

    function setAdapter(IGldSwapAdapter adapter_) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (address(adapter_) == address(0)) revert InvalidConfiguration();
        adapter = adapter_;
        emit AdapterSet(address(adapter_));
    }

    function setNativeLimits(uint128 minimum, uint128 maximum) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        _validateLimits(minimum, maximum);
        nativeLimits = Limits(minimum, maximum);
        emit NativeLimitsSet(minimum, maximum);
    }

    function setTokenLimits(IERC20 token, uint128 minimum, uint128 maximum) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (address(token) == address(0) || address(token) == address(gld)) revert InvalidConfiguration();
        _validateLimits(minimum, maximum);
        tokenLimits[address(token)] = Limits(minimum, maximum);
        emit TokenLimitsSet(address(token), minimum, maximum);
    }

    function lockConfiguration() external onlyOwner {
        if (address(adapter) == address(0) || nativeLimits.minimum == 0) revert InvalidConfiguration();
        configurationLocked = true;
        emit ConfigurationLocked();
    }

    /// @notice Anyone may convert native revenue after the configured threshold is reached.
    function processNative(uint256 minimumGldOut) external nonReentrant returns (uint256 gldOut) {
        uint256 amount = _boundedAmount(address(this).balance, nativeLimits);
        uint256 beforeBalance = gld.balanceOf(redemptionVault);
        gldOut = adapter.swapNativeForGld{ value: amount }(address(gld), minimumGldOut, redemptionVault);
        uint256 received = gld.balanceOf(redemptionVault) - beforeBalance;
        if (received < minimumGldOut || received < gldOut) revert InsufficientOutput();
        _notifyVault();
        emit NativeRevenueConverted(amount, received);
        return received;
    }

    /// @notice Anyone may convert an allowlisted settlement token after its threshold is reached.
    function processToken(IERC20 token, uint256 minimumGldOut)
        external
        nonReentrant
        returns (uint256 gldOut)
    {
        Limits memory limits = tokenLimits[address(token)];
        uint256 amount = _boundedAmount(token.balanceOf(address(this)), limits);
        token.forceApprove(address(adapter), amount);
        uint256 beforeBalance = gld.balanceOf(redemptionVault);
        gldOut = adapter.swapTokenForGld(address(token), address(gld), amount, minimumGldOut, redemptionVault);
        token.forceApprove(address(adapter), 0);
        uint256 received = gld.balanceOf(redemptionVault) - beforeBalance;
        if (received < minimumGldOut || received < gldOut) revert InsufficientOutput();
        _notifyVault();
        emit TokenRevenueConverted(address(token), amount, received);
        return received;
    }

    function _boundedAmount(uint256 balance, Limits memory limits) internal pure returns (uint256) {
        if (limits.minimum == 0 || balance < limits.minimum) revert ThresholdNotReached();
        return balance > limits.maximum ? limits.maximum : balance;
    }

    function _validateLimits(uint128 minimum, uint128 maximum) internal pure {
        if (minimum == 0 || maximum < minimum) revert InvalidConfiguration();
    }

    /// @dev Best effort preserves compatibility while the existing immutable acquisition module is replaced.
    function _notifyVault() internal {
        if (redemptionVault.code.length == 0) {
            emit VaultFundingNotification(false);
            return;
        }
        try IDailyGldDepositRecorder(redemptionVault).recordGldDeposit() returns (uint256) {
            emit VaultFundingNotification(true);
        } catch {
            emit VaultFundingNotification(false);
        }
    }
}
