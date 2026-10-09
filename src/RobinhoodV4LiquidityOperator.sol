// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IHeggLiquidityAdapter } from "./HeggLiquidityManager.sol";
import { Currency, IHooks, IUniversalRouter, PoolKey } from "./RobinhoodV4GldAdapter.sol";
import { IPermit2Allowance } from "./RobinhoodV4HeggFeeAdapter.sol";

interface IV4PositionManager is IERC721 {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
}

/// @notice Buys HEGG with half of each allocation and adds both assets to one locked v4 position.
contract RobinhoodV4LiquidityOperator is IHeggLiquidityAdapter {
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
    IV4PositionManager public immutable positionManager;
    IPermit2Allowance public immutable permit2;
    address public immutable liquidityManager;
    address public immutable positionCustody;
    uint256 public immutable positionTokenId;
    PoolKey private _poolKey;

    error UnauthorizedCaller();
    error InvalidConfiguration();
    error AmountTooLarge();
    error InsufficientHeggOutput();
    error InsufficientLiquidityAdded();
    error PositionCustodyChanged();
    error NativeRefundFailed();

    constructor(
        IERC20 canonicalHegg_,
        IUniversalRouter router_,
        IV4PositionManager positionManager_,
        IPermit2Allowance permit2_,
        address liquidityManager_,
        address positionCustody_,
        uint256 positionTokenId_,
        uint24 poolFee,
        int24 tickSpacing,
        IHooks hooks
    ) {
        if (
            address(canonicalHegg_) == address(0) || address(router_) == address(0)
                || address(positionManager_) == address(0) || address(permit2_) == address(0)
                || liquidityManager_ == address(0) || positionCustody_ == address(0) || positionTokenId_ == 0
        ) revert InvalidConfiguration();
        canonicalHegg = canonicalHegg_;
        router = router_;
        positionManager = positionManager_;
        permit2 = permit2_;
        liquidityManager = liquidityManager_;
        positionCustody = positionCustody_;
        positionTokenId = positionTokenId_;
        _poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(canonicalHegg_)),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    receive() external payable { }

    function addLiquidityFromNative(
        address hegg,
        uint256 minimumHeggOut,
        uint256 minimumLiquidityAdded,
        address lpRecipient
    ) external payable returns (uint256 heggAdded, uint256 nativeAdded, uint256 liquidityAdded) {
        if (msg.sender != liquidityManager) revert UnauthorizedCaller();
        if (
            hegg != address(canonicalHegg) || lpRecipient != positionCustody || msg.value < 2
                || minimumHeggOut == 0 || minimumLiquidityAdded == 0
        ) revert InvalidConfiguration();
        if (
            msg.value > type(uint128).max || minimumHeggOut > type(uint128).max
                || minimumLiquidityAdded > type(uint128).max
        ) revert AmountTooLarge();
        if (positionManager.ownerOf(positionTokenId) != positionCustody) revert PositionCustodyChanged();

        uint256 startingNative = address(this).balance - msg.value;
        uint256 heggBefore = canonicalHegg.balanceOf(address(this));
        uint256 nativeForSwap = msg.value / 2;
        uint256 nativeForPosition = msg.value - nativeForSwap;

        _buyHegg(nativeForSwap, minimumHeggOut);
        uint256 purchased = canonicalHegg.balanceOf(address(this)) - heggBefore;
        if (purchased < minimumHeggOut) revert InsufficientHeggOutput();

        uint256 heggAvailable = canonicalHegg.balanceOf(address(this));
        canonicalHegg.forceApprove(address(permit2), heggAvailable);
        permit2.approve(
            address(canonicalHegg),
            address(positionManager),
            uint160(heggAvailable),
            uint48(block.timestamp + DEADLINE_WINDOW)
        );

        uint128 liquidityBefore = positionManager.getPositionLiquidity(positionTokenId);
        // Increasing an existing position realizes its accrued fees. Either
        // currency can therefore finish with a positive delta even though the
        // principal increase owes both currencies. CLOSE_CURRENCY handles both
        // signs (settle debt or take credit); SETTLE_PAIR reverts on a credit.
        bytes memory actions = abi.encodePacked(INCREASE_LIQUIDITY, CLOSE_CURRENCY, CLOSE_CURRENCY, SWEEP);
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            positionTokenId,
            minimumLiquidityAdded,
            uint128(nativeForPosition),
            uint128(heggAvailable),
            bytes("")
        );
        params[1] = abi.encode(Currency.wrap(address(0)));
        params[2] = abi.encode(Currency.wrap(address(canonicalHegg)));
        params[3] = abi.encode(Currency.wrap(address(0)), address(this));
        positionManager.modifyLiquidities{ value: nativeForPosition }(
            abi.encode(actions, params), block.timestamp + DEADLINE_WINDOW
        );
        uint128 liquidityAfter = positionManager.getPositionLiquidity(positionTokenId);
        liquidityAdded = liquidityAfter - liquidityBefore;
        if (liquidityAdded < minimumLiquidityAdded) revert InsufficientLiquidityAdded();
        if (positionManager.ownerOf(positionTokenId) != positionCustody) revert PositionCustodyChanged();

        canonicalHegg.forceApprove(address(permit2), 0);
        heggAdded = heggAvailable - canonicalHegg.balanceOf(address(this));
        uint256 refundableNative = address(this).balance - startingNative;
        nativeAdded = msg.value - nativeForSwap - refundableNative;
        if (refundableNative != 0) {
            (bool success,) = payable(liquidityManager).call{ value: refundableNative }("");
            if (!success) revert NativeRefundFailed();
        }
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
}
