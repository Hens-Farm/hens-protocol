// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Immutable 1% buy / 2% sell HEGG fee for one native-ETH/HEGG Uniswap v4 pool.
/// @dev The hook address must have flags 0x00cc: before/after swap and both return-delta flags.
contract HeggV4TaxHook is IHooks {
    uint256 public constant BPS = 10_000;
    uint256 public constant BUY_TAX_BPS = 100;
    uint256 public constant SELL_TAX_BPS = 200;

    IPoolManager public immutable poolManager;
    IERC20 public immutable hegg;
    address public immutable feeCollector;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;

    event TradeTaxCollected(bool indexed buy, bool indexed exactInput, uint256 heggAmount);

    error UnauthorizedCaller();
    error InvalidConfiguration();
    error InvalidPool();
    error HookNotImplemented();
    error AmountTooLarge();

    constructor(
        IPoolManager poolManager_,
        IERC20 hegg_,
        address feeCollector_,
        uint24 poolFee_,
        int24 tickSpacing_
    ) {
        if (
            address(poolManager_) == address(0) || address(hegg_) == address(0) || feeCollector_ == address(0)
                || tickSpacing_ <= 0
        ) revert InvalidConfiguration();
        Hooks.validateHookPermissions(IHooks(address(this)), _permissions());
        poolManager = poolManager_;
        hegg = hegg_;
        feeCollector = feeCollector_;
        poolFee = poolFee_;
        tickSpacing = tickSpacing_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert UnauthorizedCaller();
        _;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validatePool(key);
        bool exactInput = params.amountSpecified < 0;
        bool buy = params.zeroForOne;
        bool feeIsSpecifiedHegg = (buy && !exactInput) || (!buy && exactInput);
        if (!feeIsSpecifiedHegg) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 fee = _absolute(params.amountSpecified) * (buy ? BUY_TAX_BPS : SELL_TAX_BPS) / BPS;
        _takeFee(fee);
        emit TradeTaxCollected(buy, exactInput, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(fee), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _validatePool(key);
        bool exactInput = params.amountSpecified < 0;
        bool buy = params.zeroForOne;
        bool feeIsUnspecifiedHegg = (buy && exactInput) || (!buy && !exactInput);
        if (!feeIsUnspecifiedHegg) return (IHooks.afterSwap.selector, 0);

        uint256 fee =
            _absolute(int256(BalanceDeltaLibrary.amount1(delta))) * (buy ? BUY_TAX_BPS : SELL_TAX_BPS) / BPS;
        _takeFee(fee);
        emit TradeTaxCollected(buy, exactInput, fee);
        return (IHooks.afterSwap.selector, _toInt128(fee));
    }

    function _takeFee(uint256 fee) private {
        if (fee != 0) poolManager.take(Currency.wrap(address(hegg)), feeCollector, fee);
    }

    function _validatePool(PoolKey calldata key) private view {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != address(hegg)
                || key.fee != poolFee || key.tickSpacing != tickSpacing || address(key.hooks) != address(this)
        ) revert InvalidPool();
    }

    function _absolute(int256 amount) private pure returns (uint256) {
        if (amount == type(int256).min) revert AmountTooLarge();
        return uint256(amount < 0 ? -amount : amount);
    }

    function _toInt128(uint256 amount) private pure returns (int128) {
        if (amount > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return int128(uint128(amount));
    }

    function _permissions() private pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}

/// @notice Stateless CREATE2 factory used to mine the permission bits encoded in a v4 hook address.
contract HeggV4TaxHookFactory {
    function deploy(
        bytes32 salt,
        IPoolManager poolManager,
        IERC20 hegg,
        address feeCollector,
        uint24 poolFee,
        int24 tickSpacing
    ) external returns (HeggV4TaxHook) {
        return new HeggV4TaxHook{ salt: salt }(poolManager, hegg, feeCollector, poolFee, tickSpacing);
    }
}
