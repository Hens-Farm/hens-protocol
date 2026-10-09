// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IHeggRevenueLiquidityAdapter } from "./HeggRevenueLiquidityVault.sol";
import { Currency, IHooks, IUniversalRouter, PoolKey } from "./RobinhoodV4GldAdapter.sol";
import { IPermit2Allowance } from "./RobinhoodV4HeggFeeAdapter.sol";
import { LiquidityAmounts } from "v4-periphery/src/libraries/LiquidityAmounts.sol";

interface IV4RevenuePositionManager is IERC721 {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        returns (PoolKey memory poolKey, uint256 positionInfo);
    function poolManager() external view returns (IPoolManager);
}

/// @notice Increases one externally owned full-range HEGG/native position using recoverable revenue.
/// @dev The position owner can revoke the exact-token approval at any time. This contract cannot decrease,
///      transfer or burn the position. A paused vault can replace this adapter without moving the position.
contract RobinhoodV4RevenueLiquidityOperator is IHeggRevenueLiquidityAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

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
    IV4RevenuePositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;
    IPermit2Allowance public immutable permit2;
    address public immutable liquidityVault;
    address public immutable positionOwner;
    uint256 public immutable positionTokenId;
    int24 public immutable positionTickLower;
    int24 public immutable positionTickUpper;
    PoolKey private _poolKey;

    event RevenuePositionIncreased(
        uint256 indexed tokenId,
        uint256 nativeIn,
        uint256 contributedHegg,
        uint256 heggPurchased,
        uint256 liquidityAdded,
        uint256 nativeReturned,
        uint256 heggReturned
    );
    event StuckNativeRecovered(uint256 amount);
    event StuckTokenRecovered(address indexed token, uint256 amount);

    error UnauthorizedCaller();
    error InvalidConfiguration();
    error AmountTooLarge();
    error InsufficientHeggOutput();
    error ZeroLiquidity();
    error UnexpectedLiquidityAdded();
    error PositionOwnerChanged();
    error PositionApprovalMissing();
    error PositionConfigurationChanged();
    error PoolManagerChanged();
    error NativeTransferFailed();

    constructor(
        IERC20 canonicalHegg_,
        IUniversalRouter router_,
        IV4RevenuePositionManager positionManager_,
        IPermit2Allowance permit2_,
        address liquidityVault_,
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
                || liquidityVault_ == address(0) || positionOwner_ == address(0) || positionTokenId_ == 0
                || address(hooks) == address(0) || tickSpacing <= 0 || expectedTickLower >= expectedTickUpper
        ) revert InvalidConfiguration();
        if (
            address(canonicalHegg_).code.length == 0 || address(router_).code.length == 0
                || address(positionManager_).code.length == 0 || address(permit2_).code.length == 0
                || liquidityVault_.code.length == 0
        ) revert InvalidConfiguration();

        canonicalHegg = canonicalHegg_;
        router = router_;
        positionManager = positionManager_;
        permit2 = permit2_;
        liquidityVault = liquidityVault_;
        positionOwner = positionOwner_;
        positionTokenId = positionTokenId_;
        positionTickLower = expectedTickLower;
        positionTickUpper = expectedTickUpper;
        poolManager = positionManager_.poolManager();
        if (address(poolManager) == address(0) || address(poolManager).code.length == 0) {
            revert InvalidConfiguration();
        }

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

    function addLiquidityFromRevenue(address hegg, uint256 contributedHegg, uint256 minimumHeggOut)
        external
        payable
        nonReentrant
        returns (uint256 heggPurchased, uint256 liquidityAdded)
    {
        if (msg.sender != liquidityVault) revert UnauthorizedCaller();
        if (
            hegg != address(canonicalHegg) || msg.value < 2 || minimumHeggOut == 0
                || canonicalHegg.balanceOf(address(this)) < contributedHegg
        ) revert InvalidConfiguration();
        if (msg.value > type(uint128).max || minimumHeggOut > type(uint128).max) {
            revert AmountTooLarge();
        }

        _validatePositionConfiguration();
        if (!_isApproved()) revert PositionApprovalMissing();

        uint256 nativeForSwap = msg.value / 2;
        uint256 nativeForLiquidity = msg.value - nativeForSwap;
        uint256 heggBeforeSwap = canonicalHegg.balanceOf(address(this));
        _buyHegg(nativeForSwap, minimumHeggOut);
        heggPurchased = canonicalHegg.balanceOf(address(this)) - heggBeforeSwap;
        if (heggPurchased < minimumHeggOut) revert InsufficientHeggOutput();

        uint256 heggAvailable = canonicalHegg.balanceOf(address(this));
        if (heggAvailable > type(uint128).max) revert AmountTooLarge();
        liquidityAdded = _maximumLiquidity(nativeForLiquidity, heggAvailable);
        if (liquidityAdded == 0) revert ZeroLiquidity();
        if (liquidityAdded > type(uint128).max) revert AmountTooLarge();
        _increasePosition(liquidityAdded, nativeForLiquidity, heggAvailable);
        _validatePositionConfiguration();

        canonicalHegg.forceApprove(address(permit2), 0);
        permit2.approve(address(canonicalHegg), address(positionManager), 0, 0);

        uint256 heggReturned = canonicalHegg.balanceOf(address(this));
        uint256 nativeReturned = address(this).balance;
        if (heggReturned != 0) canonicalHegg.safeTransfer(liquidityVault, heggReturned);
        if (nativeReturned != 0) _sendNativeToVault(nativeReturned);

        emit RevenuePositionIncreased(
            positionTokenId,
            msg.value,
            contributedHegg,
            heggPurchased,
            liquidityAdded,
            nativeReturned,
            heggReturned
        );
    }

    function _maximumLiquidity(uint256 nativeAmount, uint256 heggAmount) private view returns (uint256) {
        PoolKey memory key = _poolKey;
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert InvalidConfiguration();
        return uint256(
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(positionTickLower),
                TickMath.getSqrtPriceAtTick(positionTickUpper),
                nativeAmount,
                heggAmount
            )
        );
    }

    function _increasePosition(uint256 liquidity, uint256 nativeMaximum, uint256 heggMaximum) private {
        canonicalHegg.forceApprove(address(permit2), heggMaximum);
        permit2.approve(
            address(canonicalHegg),
            address(positionManager),
            uint160(heggMaximum),
            uint48(block.timestamp + DEADLINE_WINDOW)
        );

        uint128 liquidityBefore = positionManager.getPositionLiquidity(positionTokenId);
        bytes memory actions = abi.encodePacked(INCREASE_LIQUIDITY, CLOSE_CURRENCY, CLOSE_CURRENCY, SWEEP);
        bytes[] memory params = new bytes[](4);
        params[0] =
            abi.encode(positionTokenId, liquidity, uint128(nativeMaximum), uint128(heggMaximum), bytes(""));
        params[1] = abi.encode(Currency.wrap(address(0)));
        params[2] = abi.encode(Currency.wrap(address(canonicalHegg)));
        params[3] = abi.encode(Currency.wrap(address(0)), address(this));
        positionManager.modifyLiquidities{ value: nativeMaximum }(
            abi.encode(actions, params), block.timestamp + DEADLINE_WINDOW
        );

        uint128 liquidityAfter = positionManager.getPositionLiquidity(positionTokenId);
        if (uint256(liquidityAfter) - uint256(liquidityBefore) != liquidity) {
            revert UnexpectedLiquidityAdded();
        }
    }

    /// @notice Sweeps only balances stranded outside a successful atomic processing call.
    function recoverStuckNative() external nonReentrant {
        if (msg.sender != liquidityVault && msg.sender != positionOwner) revert UnauthorizedCaller();
        uint256 amount = address(this).balance;
        if (amount != 0) _sendNativeToVault(amount);
        emit StuckNativeRecovered(amount);
    }

    function recoverStuckToken(IERC20 token) external nonReentrant {
        if ((msg.sender != liquidityVault && msg.sender != positionOwner) || address(token) == address(0)) {
            revert UnauthorizedCaller();
        }
        uint256 amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(liquidityVault, amount);
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
        if (address(positionManager.poolManager()) != address(poolManager)) revert PoolManagerChanged();

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

    function _sendNativeToVault(uint256 amount) private {
        (bool success,) = payable(liquidityVault).call{ value: amount }("");
        if (!success) revert NativeTransferFailed();
    }
}
