// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

interface IShadowSwap {
    function validateOrder(
        uint256 orderId,
        address sender,
        PoolId poolId
    ) external view returns (bool);

    function settleOrder(
        uint256 orderId,
        address user,
        uint256 outputAmount
    ) external returns (bool);
}
