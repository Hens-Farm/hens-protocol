// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IHeggSwapAdapter } from "./HeggFeeCollector.sol";
import { Currency, IHooks, IUniversalRouter, PoolKey } from "./RobinhoodV4GldAdapter.sol";

interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Executes only a fixed Robinhood Uniswap v4 HEGG/native-ETH pool route.
contract RobinhoodV4HeggFeeAdapter is IHeggSwapAdapter {
    using SafeERC20 for IERC20;

    bytes1 private constant V4_SWAP = 0x10;
    bytes1 private constant SWAP_EXACT_IN_SINGLE = 0x06;
    bytes1 private constant SETTLE_ALL = 0x0c;
    bytes1 private constant TAKE_ALL = 0x0f;
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
    IPermit2Allowance public immutable permit2;
    address public immutable feeCollector;
    PoolKey private _poolKey;

    error UnauthorizedCaller();
    error InvalidConfiguration();
    error AmountTooLarge();
    error InsufficientOutput();
    error NativeTransferFailed();

    constructor(
        IERC20 canonicalHegg_,
        IUniversalRouter router_,
        IPermit2Allowance permit2_,
        address feeCollector_,
        uint24 poolFee,
        int24 tickSpacing,
        IHooks hooks
    ) {
        if (
            address(canonicalHegg_) == address(0) || address(router_) == address(0)
                || address(permit2_) == address(0) || feeCollector_ == address(0)
        ) revert InvalidConfiguration();
        canonicalHegg = canonicalHegg_;
        router = router_;
        permit2 = permit2_;
        feeCollector = feeCollector_;
        _poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(canonicalHegg_)),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
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

    function swapExactTokensForNative(address token, uint256 amount, uint256 minimumOut, address recipient)
        external
        returns (uint256 nativeOut)
    {
        if (msg.sender != feeCollector) revert UnauthorizedCaller();
        if (token != address(canonicalHegg) || amount == 0 || minimumOut == 0 || recipient == address(0)) {
            revert InvalidConfiguration();
        }
        if (amount > type(uint128).max || minimumOut > type(uint128).max) revert AmountTooLarge();

        canonicalHegg.safeTransferFrom(msg.sender, address(this), amount);
        canonicalHegg.forceApprove(address(permit2), amount);
        permit2.approve(token, address(router), uint160(amount), uint48(block.timestamp + DEADLINE_WINDOW));

        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: _poolKey,
                zeroForOne: false,
                amountIn: uint128(amount),
                amountOutMinimum: uint128(minimumOut),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(address(canonicalHegg)), amount);
        params[2] = abi.encode(Currency.wrap(address(0)), minimumOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 nativeBefore = address(this).balance;
        router.execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp + DEADLINE_WINDOW);
        nativeOut = address(this).balance - nativeBefore;
        if (nativeOut < minimumOut) revert InsufficientOutput();

        canonicalHegg.forceApprove(address(permit2), 0);
        (bool success,) = payable(recipient).call{ value: nativeOut }("");
        if (!success) revert NativeTransferFailed();
    }
}
