// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IHeggPositionLiquidityAdapterV2 } from "./HeggPositionLiquidityManagerV2.sol";
import { Currency, IHooks, IUniversalRouter, PoolKey } from "./RobinhoodV4GldAdapter.sol";
import { IPermit2Allowance } from "./RobinhoodV4HeggFeeAdapter.sol";

interface IV4ExistingPositionManager is IERC721 {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        returns (PoolKey memory poolKey, uint256 positionInfo);
}

/// @notice Adds native-funded liquidity to one existing, externally owned HEGG/native v4 position.
/// @dev It cannot transfer, decrease or burn the position. The owner can revoke its single-token approval.
contract RobinhoodV4ExistingPositionOperatorV2 is IHeggPositionLiquidityAdapterV2, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes1 private constant V4_SWAP = 0x10;
    bytes1 private constant SWAP_EXACT_IN_SINGLE = 0x06;
    bytes1 private constant SETTLE_ALL = 0x0c;
    bytes1 private constant TAKE_ALL = 0x0f;
    bytes1 private constant INCREASE_LIQUIDITY = 0x00;
    bytes1 private constant CLOSE_CURRENCY = 0x12;
    bytes1 private constant SWEEP = 0x14;
    uint256 private constant DEADLINE_WINDOW = 2 minutes;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    IERC20 public immutable canonicalHegg;
    IUniversalRouter public immutable router;
    IV4ExistingPositionManager public immutable positionManager;
    IPermit2Allowance public immutable permit2;
    address public immutable liquidityManager;
    address public immutable positionOwner;
    uint256 public immutable positionTokenId;
    int24 public immutable positionTickLower;
    int24 public immutable positionTickUpper;
    PoolKey private _poolKey;

    event ExistingPositionIncreased(
        uint256 indexed tokenId,
        uint256 nativeIn,
        uint256 heggPurchased,
        uint256 liquidityAdded,
        uint256 residualNativeReturned,
        uint256 residualHeggReturned
    );
    event StuckNativeRecovered(uint256 amount);
    event StuckTokenRecovered(address indexed token, uint256 amount);

    error UnauthorizedCaller();
    error InvalidConfiguration();
    error AmountTooLarge();
    error InsufficientHeggOutput();
    error UnexpectedLiquidityAdded();
    error PositionOwnerChanged();
    error PositionApprovalMissing();
    error PositionConfigurationChanged();
    error NativeTransferFailed();

    constructor(
        IERC20 canonicalHegg_,
        IUniversalRouter router_,
        IV4ExistingPositionManager positionManager_,
        IPermit2Allowance permit2_,
        address liquidityManager_,
        address positionOwner_,
        uint256 positionTokenId_,
        uint24 poolFee,
        int24 tickSpacing,
        IHooks hooks,
        int24 expectedTickLower,
        int24 expectedTickUpper
    ) {
        if (
            address(canonicalHegg_) == address(0) || address(router_) == address(0)
                || address(positionManager_) == address(0) || address(permit2_) == address(0)
                || liquidityManager_ == address(0) || positionOwner_ == address(0) || positionTokenId_ == 0
                || address(hooks) == address(0) || tickSpacing <= 0 || expectedTickLower >= expectedTickUpper
        ) revert InvalidConfiguration();

        canonicalHegg = canonicalHegg_;
        router = router_;
        positionManager = positionManager_;
        permit2 = permit2_;
        liquidityManager = liquidityManager_;
        positionOwner = positionOwner_;
        positionTokenId = positionTokenId_;
        positionTickLower = expectedTickLower;
        positionTickUpper = expectedTickUpper;
        _poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(canonicalHegg_)),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });

        _validatePositionConfiguration();
    }

    receive() external payable { }

    function poolKey() external view returns (address, address, uint24, int24, address) {
        PoolKey memory key = _poolKey;
        return (
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            key.fee,
            key.tickSpacing,
            address(key.hooks)
        );
    }

    function addLiquidityFromNative(
        address hegg,
        uint256 minimumHeggOut,
        uint256 liquidityToAdd,
        address expectedPositionOwner
    )
        external
        payable
        nonReentrant
        returns (uint256 heggPurchased, uint256 nativeAllocated, uint256 liquidityAdded)
    {
        if (msg.sender != liquidityManager) revert UnauthorizedCaller();
        if (
            hegg != address(canonicalHegg) || expectedPositionOwner != positionOwner || msg.value < 2
                || minimumHeggOut == 0 || liquidityToAdd == 0
        ) revert InvalidConfiguration();
        if (
            msg.value > type(uint128).max || minimumHeggOut > type(uint128).max
                || liquidityToAdd > type(uint128).max
        ) revert AmountTooLarge();

        _validatePositionConfiguration();
        if (!_isApproved()) revert PositionApprovalMissing();

        uint256 startingNative = address(this).balance - msg.value;
        uint256 startingHegg = canonicalHegg.balanceOf(address(this));
        uint256 nativeForSwap = msg.value / 2;
        nativeAllocated = msg.value - nativeForSwap;

        _buyHegg(nativeForSwap, minimumHeggOut);
        heggPurchased = canonicalHegg.balanceOf(address(this)) - startingHegg;
        if (heggPurchased < minimumHeggOut) revert InsufficientHeggOutput();

        canonicalHegg.forceApprove(address(permit2), heggPurchased);
        permit2.approve(
            address(canonicalHegg),
            address(positionManager),
            uint160(heggPurchased),
            uint48(block.timestamp + DEADLINE_WINDOW)
        );

        uint128 liquidityBefore = positionManager.getPositionLiquidity(positionTokenId);
        bytes memory actions = abi.encodePacked(INCREASE_LIQUIDITY, CLOSE_CURRENCY, CLOSE_CURRENCY, SWEEP);
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            positionTokenId, liquidityToAdd, uint128(nativeAllocated), uint128(heggPurchased), bytes("")
        );
        params[1] = abi.encode(Currency.wrap(address(0)));
        params[2] = abi.encode(Currency.wrap(address(canonicalHegg)));
        params[3] = abi.encode(Currency.wrap(address(0)), address(this));
        positionManager.modifyLiquidities{ value: nativeAllocated }(
            abi.encode(actions, params), block.timestamp + DEADLINE_WINDOW
        );

        uint128 liquidityAfter = positionManager.getPositionLiquidity(positionTokenId);
        liquidityAdded = uint256(liquidityAfter) - uint256(liquidityBefore);
        if (liquidityAdded != liquidityToAdd) revert UnexpectedLiquidityAdded();
        _validatePositionConfiguration();

        canonicalHegg.forceApprove(address(permit2), 0);
        permit2.approve(address(canonicalHegg), address(positionManager), 0, 0);

        uint256 residualHegg = canonicalHegg.balanceOf(address(this)) - startingHegg;
        uint256 residualNative = address(this).balance - startingNative;
        if (residualHegg != 0) canonicalHegg.safeTransfer(positionOwner, residualHegg);
        if (residualNative != 0) _sendNative(payable(positionOwner), residualNative);

        emit ExistingPositionIncreased(
            positionTokenId, msg.value, heggPurchased, liquidityAdded, residualNative, residualHegg
        );
    }

    /// @notice Recovers only balances that predate or arrive outside a successful processing call.
    function recoverStuckNative() external nonReentrant {
        if (msg.sender != positionOwner) revert UnauthorizedCaller();
        uint256 amount = address(this).balance;
        if (amount != 0) _sendNative(payable(positionOwner), amount);
        emit StuckNativeRecovered(amount);
    }

    function recoverStuckToken(IERC20 token) external nonReentrant {
        if (msg.sender != positionOwner || address(token) == address(0)) revert UnauthorizedCaller();
        uint256 amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(positionOwner, amount);
        emit StuckTokenRecovered(address(token), amount);
    }

    function _buyHegg(uint256 nativeIn, uint256 minimumHeggOut) private {
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: _poolKey,
                zeroForOne: true,
                amountIn: uint128(nativeIn),
                amountOutMinimum: uint128(minimumHeggOut),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), nativeIn);
        params[2] = abi.encode(Currency.wrap(address(canonicalHegg)), minimumHeggOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        router.execute{ value: nativeIn }(
            abi.encodePacked(V4_SWAP), inputs, block.timestamp + DEADLINE_WINDOW
        );
    }

    function _isApproved() private view returns (bool) {
        return positionManager.getApproved(positionTokenId) == address(this)
            || positionManager.isApprovedForAll(positionOwner, address(this));
    }

    function _validatePositionConfiguration() private view {
        if (positionManager.ownerOf(positionTokenId) != positionOwner) revert PositionOwnerChanged();

        (PoolKey memory actualKey, uint256 positionInfo) =
            positionManager.getPoolAndPositionInfo(positionTokenId);
        PoolKey memory expectedKey = _poolKey;
        if (
            Currency.unwrap(actualKey.currency0) != Currency.unwrap(expectedKey.currency0)
                || Currency.unwrap(actualKey.currency1) != Currency.unwrap(expectedKey.currency1)
                || actualKey.fee != expectedKey.fee || actualKey.tickSpacing != expectedKey.tickSpacing
                || address(actualKey.hooks) != address(expectedKey.hooks)
                || _tickLower(positionInfo) != positionTickLower
                || _tickUpper(positionInfo) != positionTickUpper
        ) revert PositionConfigurationChanged();
    }

    function _tickLower(uint256 positionInfo) private pure returns (int24) {
        return int24(uint24(positionInfo >> 8));
    }

    function _tickUpper(uint256 positionInfo) private pure returns (int24) {
        return int24(uint24(positionInfo >> 32));
    }

    function _sendNative(address payable recipient, uint256 amount) private {
        (bool success,) = recipient.call{ value: amount }("");
        if (!success) revert NativeTransferFailed();
    }
}
