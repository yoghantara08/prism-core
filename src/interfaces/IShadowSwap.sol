// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

interface IShadowSwap {
    enum OrderStatus {
        Pending,
        Executed,
        Cancelled,
        Expired
    }

    struct OrderInfo {
        address user;
        PoolId poolId;
        Currency tokenIn;
        Currency tokenOut;
        OrderStatus status;
        uint256 createdAt;
        uint256 executedAt;
    }

    error Unauthorized();
    error OrderNotFound();
    error OrderAlreadyExecuted();
    error OrderNotPending();
    error InvalidOrder();
    error InsufficientEncryptedBalance();
    error InvalidEncryptedAmount();
    error SlippageExceeded();

    event ShadowOrderCreated(
        uint256 indexed orderId,
        address indexed user,
        PoolId indexed poolId,
        Currency tokenIn,
        Currency tokenOut
    );

    event ShadowOrderExecuted(
        uint256 indexed orderId,
        address indexed user,
        uint256 timestamp
    );

    event ShadowOrderCancelled(uint256 indexed orderId, address indexed user);

    event EncryptedBalanceUpdated(
        address indexed user,
        Currency indexed token,
        uint256 timestamp
    );

    function createShadowOrder(
        PoolId poolId,
        Currency tokenIn,
        Currency tokenOut,
        bytes calldata encryptedAmountIn,
        bytes calldata encryptedMinAmountOut,
        bytes calldata encryptedDeadline
    ) external returns (uint256 orderId);

    function cancelOrder(uint256 orderId) external;

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

    function depositEncrypted(
        Currency token,
        bytes calldata encryptedAmount
    ) external;

    function withdrawEncrypted(
        Currency token,
        bytes calldata encryptedAmount,
        bytes calldata permission
    ) external;

    function getEncryptedBalance(
        Currency token,
        bytes calldata permission
    ) external view returns (bytes memory);

    function getUserOrders(
        address user
    ) external view returns (uint256[] memory);

    function getOrder(uint256 orderId) external view returns (OrderInfo memory);

    function getOrderCount() external view returns (uint256);

    function isOrderActive(uint256 orderId) external view returns (bool);
}
