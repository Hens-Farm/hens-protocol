// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IGldSwapAdapter } from "./GldAcquisitionManager.sol";

type Currency is address;

interface IHooks { }

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Executes only a fixed Robinhood Uniswap v4 native-ETH/GLD pool route.
/// @dev Token routes are deliberately rejected until an independently verified route is configured.
contract RobinhoodV4GldAdapter is IGldSwapAdapter {
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

    IUniversalRouter public immutable router;
    IERC20 public immutable canonicalGld;
    address public immutable manager;
    PoolKey private _poolKey;

    error UnauthorizedCaller();
    error InvalidConfiguration();
    error UnsupportedTokenRoute();
    error AmountTooLarge();
    error InsufficientOutput();

    constructor(
        IUniversalRouter router_,
        IERC20 canonicalGld_,
        address manager_,
        uint24 poolFee,
        int24 tickSpacing,
        IHooks hooks
    ) {
        if (address(router_) == address(0) || address(canonicalGld_) == address(0) || manager_ == address(0))
        {
            revert InvalidConfiguration();
        }
        router = router_;
        canonicalGld = canonicalGld_;
        manager = manager_;
        _poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(canonicalGld_)),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert UnauthorizedCaller();
        _;
    }

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

    function swapNativeForGld(address gld, uint256 minimumGldOut, address recipient)
        external
        payable
        onlyManager
        returns (uint256 gldOut)
    {
        if (gld != address(canonicalGld) || recipient == address(0) || msg.value == 0 || minimumGldOut == 0) {
            revert InvalidConfiguration();
        }
        if (msg.value > type(uint128).max || minimumGldOut > type(uint128).max) revert AmountTooLarge();

        uint256 balanceBefore = canonicalGld.balanceOf(address(this));
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: _poolKey,
                zeroForOne: true,
                amountIn: uint128(msg.value),
                amountOutMinimum: uint128(minimumGldOut),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), msg.value);
        params[2] = abi.encode(Currency.wrap(address(canonicalGld)), minimumGldOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        router.execute{ value: msg.value }(
            abi.encodePacked(V4_SWAP), inputs, block.timestamp + DEADLINE_WINDOW
        );

        gldOut = canonicalGld.balanceOf(address(this)) - balanceBefore;
        if (gldOut < minimumGldOut) revert InsufficientOutput();
        canonicalGld.safeTransfer(recipient, gldOut);
    }

    function swapTokenForGld(address, address, uint256, uint256, address) external pure returns (uint256) {
        revert UnsupportedTokenRoute();
    }
}
