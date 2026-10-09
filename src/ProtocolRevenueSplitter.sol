// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Permissionless, immutable 70/10/10/10 distribution of collected protocol revenue.
/// @dev The GLD recipient is the acquisition module that converts its share and funds the redemption vault.
contract ProtocolRevenueSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant GLD_VAULT_BPS = 7_000;
    uint256 public constant HEGG_LIQUIDITY_BPS = 1_000;
    uint256 public constant FLOOR_SUPPORT_BPS = 1_000;
    uint256 public constant CREATOR_BPS = 1_000;

    address public immutable gldAcquisitionRecipient;
    address public immutable heggLiquidityManager;
    address public immutable floorSupportReserve;
    address public immutable creatorRecipient;

    event NativeRevenueDistributed(
        uint256 total, uint256 gldShare, uint256 liquidityShare, uint256 floorShare, uint256 creatorShare
    );
    event TokenRevenueDistributed(
        address indexed token,
        uint256 total,
        uint256 gldShare,
        uint256 liquidityShare,
        uint256 floorShare,
        uint256 creatorShare
    );

    error ZeroAddress();
    error NothingToDistribute();
    error NativeTransferFailed();

    constructor(
        address gldRecipient_,
        address liquidityRecipient_,
        address floorRecipient_,
        address creatorRecipient_
    ) {
        if (
            gldRecipient_ == address(0) || liquidityRecipient_ == address(0) || floorRecipient_ == address(0)
                || creatorRecipient_ == address(0)
        ) {
            revert ZeroAddress();
        }
        gldAcquisitionRecipient = gldRecipient_;
        heggLiquidityManager = liquidityRecipient_;
        floorSupportReserve = floorRecipient_;
        creatorRecipient = creatorRecipient_;
    }

    receive() external payable { }

    /// @notice Anyone may trigger distribution; no administrator can redirect the proceeds.
    function distributeNative() external nonReentrant {
        uint256 total = address(this).balance;
        if (total == 0) revert NothingToDistribute();
        (uint256 gldShare, uint256 liquidityShare, uint256 floorShare, uint256 creatorShare) = _shares(total);

        _sendNative(gldAcquisitionRecipient, gldShare);
        _sendNative(heggLiquidityManager, liquidityShare);
        _sendNative(floorSupportReserve, floorShare);
        _sendNative(creatorRecipient, creatorShare);
        emit NativeRevenueDistributed(total, gldShare, liquidityShare, floorShare, creatorShare);
    }

    /// @notice Splits ERC-20 royalties paid in marketplace settlement tokens.
    function distributeToken(IERC20 token) external nonReentrant {
        uint256 total = token.balanceOf(address(this));
        if (total == 0) revert NothingToDistribute();
        (uint256 gldShare, uint256 liquidityShare, uint256 floorShare, uint256 creatorShare) = _shares(total);

        token.safeTransfer(gldAcquisitionRecipient, gldShare);
        token.safeTransfer(heggLiquidityManager, liquidityShare);
        token.safeTransfer(floorSupportReserve, floorShare);
        token.safeTransfer(creatorRecipient, creatorShare);
        emit TokenRevenueDistributed(
            address(token), total, gldShare, liquidityShare, floorShare, creatorShare
        );
    }

    function _shares(uint256 total)
        internal
        pure
        returns (uint256 gldShare, uint256 liquidityShare, uint256 floorShare, uint256 creatorShare)
    {
        liquidityShare = total * HEGG_LIQUIDITY_BPS / BPS;
        floorShare = total * FLOOR_SUPPORT_BPS / BPS;
        creatorShare = total * CREATOR_BPS / BPS;
        // Assign rounding dust to the user-facing GLD vault.
        gldShare = total - liquidityShare - floorShare - creatorShare;
    }

    function _sendNative(address recipient, uint256 amount) internal {
        (bool success,) = recipient.call{ value: amount }("");
        if (!success) revert NativeTransferFailed();
    }
}
