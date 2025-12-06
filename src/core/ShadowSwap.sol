// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    FHE,
    euint64,
    ebool,
    inEuint64
} from "fhenix-contracts/contracts/FHE.sol";
import {
    Permissioned,
    Permission
} from "fhenix-contracts/contracts/access/Permissioned.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {IShadowSwap} from "../interfaces/IShadowSwap.sol";

contract ShadowSwap is IShadowSwap, Permissioned {
    using PoolIdLibrary for PoolKey;

    struct ShadowOrder {
        address user;
        PoolId poolId;
        Currency tokenIn;
        Currency tokenOut;
        euint64 encryptedAmountIn;
        euint64 encryptedMinAmountOut;
        euint64 encryptedDeadline;
        OrderStatus status;
        uint256 createdAt;
        uint256 executedAt;
    }

    IPoolManager public immutable POOL_MANAGER;
    address public immutable OWNER;
    address public prismHook;

    uint256 public orderIdCounter;
    mapping(uint256 => ShadowOrder) internal _orders;
    mapping(address => mapping(Currency => euint64))
        internal _encryptedBalances;
    mapping(address => uint256[]) internal _userOrders;

    constructor(address _poolManager, address _owner) {
        POOL_MANAGER = IPoolManager(_poolManager);
        OWNER = _owner;
    }

    function setPrismHook(address _prismHook) external {
        if (msg.sender != OWNER) revert Unauthorized();
        if (prismHook != address(0)) revert AlreadyInitializedHook();
        prismHook = _prismHook;
    }

    modifier onlyHook() {
        if (msg.sender != prismHook) revert Unauthorized();
        _;
    }

    function createShadowOrder(
        PoolId poolId,
        Currency tokenIn,
        Currency tokenOut,
        bytes calldata encryptedAmountIn,
        bytes calldata encryptedMinAmountOut,
        bytes calldata encryptedDeadline
    ) external returns (uint256 orderId) {
        inEuint64 memory amountInInput = abi.decode(
            encryptedAmountIn,
            (inEuint64)
        );
        inEuint64 memory minAmountOutInput = abi.decode(
            encryptedMinAmountOut,
            (inEuint64)
        );
        inEuint64 memory deadlineInput = abi.decode(
            encryptedDeadline,
            (inEuint64)
        );

        euint64 amountIn = FHE.asEuint64(amountInInput);
        euint64 minAmountOut = FHE.asEuint64(minAmountOutInput);
        euint64 deadline = FHE.asEuint64(deadlineInput);

        euint64 userBalance = _encryptedBalances[msg.sender][tokenIn];
        ebool hasBalance = FHE.gte(userBalance, amountIn);
        FHE.req(hasBalance);

        orderId = ++orderIdCounter;

        _orders[orderId] = ShadowOrder({
            user: msg.sender,
            poolId: poolId,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            encryptedAmountIn: amountIn,
            encryptedMinAmountOut: minAmountOut,
            encryptedDeadline: deadline,
            status: OrderStatus.Pending,
            createdAt: block.timestamp,
            executedAt: 0
        });

        _userOrders[msg.sender].push(orderId);

        emit ShadowOrderCreated(orderId, msg.sender, poolId, tokenIn, tokenOut);

        return orderId;
    }

    function cancelOrder(uint256 orderId) external {
        ShadowOrder storage order = _orders[orderId];

        if (order.user != msg.sender) revert Unauthorized();
        if (order.status != OrderStatus.Pending) revert OrderNotPending();

        order.status = OrderStatus.Cancelled;

        emit ShadowOrderCancelled(orderId, msg.sender);
    }

    function validateOrder(
        uint256 orderId,
        address sender,
        PoolId poolId
    ) external view onlyHook returns (bool) {
        ShadowOrder storage order = _orders[orderId];

        if (order.user != sender) return false;
        if (PoolId.unwrap(order.poolId) != PoolId.unwrap(poolId)) return false;
        if (order.status != OrderStatus.Pending) return false;

        return true;
    }

    function settleOrder(
        uint256 orderId,
        address user,
        uint256 outputAmount
    ) external onlyHook returns (bool) {
        ShadowOrder storage order = _orders[orderId];

        if (order.status != OrderStatus.Pending) revert OrderNotPending();

        euint64 encryptedOutput = FHE.asEuint64(outputAmount);
        ebool meetsSlippage = FHE.gte(
            encryptedOutput,
            order.encryptedMinAmountOut
        );
        FHE.req(meetsSlippage);

        order.status = OrderStatus.Executed;
        order.executedAt = block.timestamp;

        euint64 currentBalanceIn = _encryptedBalances[user][order.tokenIn];
        _encryptedBalances[user][order.tokenIn] = FHE.sub(
            currentBalanceIn,
            order.encryptedAmountIn
        );

        euint64 currentBalanceOut = _encryptedBalances[user][order.tokenOut];
        _encryptedBalances[user][order.tokenOut] = FHE.add(
            currentBalanceOut,
            encryptedOutput
        );

        emit ShadowOrderExecuted(orderId, user, block.timestamp);
        emit EncryptedBalanceUpdated(user, order.tokenIn, block.timestamp);
        emit EncryptedBalanceUpdated(user, order.tokenOut, block.timestamp);

        return true;
    }

    function depositEncrypted(
        Currency token,
        bytes calldata encryptedAmount
    ) external {
        inEuint64 memory amountInput = abi.decode(encryptedAmount, (inEuint64));
        euint64 amount = FHE.asEuint64(amountInput);

        euint64 currentBalance = _encryptedBalances[msg.sender][token];
        _encryptedBalances[msg.sender][token] = FHE.add(currentBalance, amount);

        emit EncryptedBalanceUpdated(msg.sender, token, block.timestamp);
    }

    function withdrawEncrypted(
        Currency token,
        bytes calldata encryptedAmount
    ) external {
        inEuint64 memory amountInput = abi.decode(encryptedAmount, (inEuint64));

        euint64 amount = FHE.asEuint64(amountInput);
        euint64 currentBalance = _encryptedBalances[msg.sender][token];

        ebool hasSufficientBalance = FHE.gte(currentBalance, amount);
        FHE.req(hasSufficientBalance);

        _encryptedBalances[msg.sender][token] = FHE.sub(currentBalance, amount);

        emit EncryptedBalanceUpdated(msg.sender, token, block.timestamp);
    }

    function getEncryptedBalance(
        Currency token,
        bytes calldata permission
    ) external view returns (bytes memory) {
        Permission memory perm = abi.decode(permission, (Permission));
        euint64 balance = _encryptedBalances[msg.sender][token];
        return bytes(FHE.sealoutput(balance, perm.publicKey));
    }

    function getUserOrders(
        address user
    ) external view returns (uint256[] memory) {
        return _userOrders[user];
    }

    function getOrder(
        uint256 orderId
    ) external view returns (OrderInfo memory) {
        ShadowOrder storage order = _orders[orderId];
        return
            OrderInfo({
                user: order.user,
                poolId: order.poolId,
                tokenIn: order.tokenIn,
                tokenOut: order.tokenOut,
                status: order.status,
                createdAt: order.createdAt,
                executedAt: order.executedAt
            });
    }

    function getOrderCount() external view returns (uint256) {
        return orderIdCounter;
    }

    function isOrderActive(uint256 orderId) external view returns (bool) {
        return _orders[orderId].status == OrderStatus.Pending;
    }
}
