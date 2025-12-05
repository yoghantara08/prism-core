// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "./BaseHook.sol";
import {IShadowSwap} from "./interfaces/IShadowSwap.sol";

contract PrismHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    IShadowSwap public immutable SHADOW_SWAP;

    mapping(PoolId => mapping(address => bool)) public activeOrders;

    event ShadowSwapExecuted(
        PoolId indexed poolId,
        address indexed user,
        uint256 orderId,
        bool success
    );

    error InvalidOrder();

    constructor(
        IPoolManager _poolManager,
        address _shadowSwap
    ) BaseHook(_poolManager) {
        SHADOW_SWAP = IShadowSwap(_shadowSwap);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata hookData
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        uint256 orderId = abi.decode(hookData, (uint256));

        if (!SHADOW_SWAP.validateOrder(orderId, sender, poolId)) {
            revert InvalidOrder();
        }

        activeOrders[poolId][sender] = true;

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        uint256 orderId = abi.decode(hookData, (uint256));

        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();

        uint256 outputAmount;
        if (amount0 > 0) {
            outputAmount = uint256(amount0);
        } else if (amount1 > 0) {
            outputAmount = uint256(amount1);
        }

        bool success = SHADOW_SWAP.settleOrder(orderId, sender, outputAmount);
        activeOrders[poolId][sender] = false;

        emit ShadowSwapExecuted(poolId, sender, orderId, success);

        return (BaseHook.afterSwap.selector, 0);
    }
}
