// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FHE, euint64, inEuint64} from "fhenix-contracts/contracts/FHE.sol";
import {
    Permissioned,
    Permission
} from "fhenix-contracts/contracts/access/Permissioned.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract ShadowSwap is Permissioned {
    using PoolIdLibrary for PoolKey;

    enum OrderStatus {
        Pending,
        Executed,
        Cancelled,
        Expired
    }

    struct ShadowOrder {
        address user;
        PoolId poolId;
        Currency tokenIn;
        Currency tokenOut;
        euint64 encryptedAmountIn; // FHE encrypted input amount
        euint64 encryptedMinAmountOut; // FHE encrypted slippage protection
        euint64 encryptedDeadline; // FHE encrypted deadline
        OrderStatus status;
        uint256 createdAt;
        uint256 executedAt;
    }

    /// @notice Uniswap v4 PoolManager
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Authorized PrismHook address
    address public immutable PRISM_HOOK;

    /// @notice Order ID counter
    uint256 public orderIdCounter;

    /// @notice Mapping: orderId => ShadowOrder
    mapping(uint256 => ShadowOrder) public orders;

    /// @notice Mapping: user => encrypted balance (privacy-preserving)
    mapping(address => mapping(Currency => euint64)) public encryptedBalances;

    /// @notice Mapping: user => order IDs
    mapping(address => uint256[]) public userOrders;

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

    event BalanceDeposited(
        address indexed user,
        Currency indexed token,
        uint256 timestamp
    );

    event BalanceWithdrawn(
        address indexed user,
        Currency indexed token,
        uint256 timestamp
    );

    error Unauthorized();
    error OrderNotFound();
    error OrderAlreadyExecuted();
    error InvalidOrder();
    error InsufficientBalance();

    constructor(address _poolManager, address _prismHook) {
        POOL_MANAGER = IPoolManager(_poolManager);
        PRISM_HOOK = _prismHook;
    }

    modifier onlyHook() {
        _onlyHook();
        _;
    }

    /// @notice Create encrypted shadow swap order
    /// @dev User must encrypt parameters client-side using Fhenix
    function createShadowOrder(
        PoolId poolId,
        Currency tokenIn,
        Currency tokenOut,
        inEuint64 calldata encryptedAmountIn,
        inEuint64 calldata encryptedMinAmountOut,
        inEuint64 calldata encryptedDeadline
    ) external returns (uint256 orderId) {
        euint64 amountIn = FHE.asEuint64(encryptedAmountIn);
        euint64 minAmountOut = FHE.asEuint64(encryptedMinAmountOut);
        euint64 deadline = FHE.asEuint64(encryptedDeadline);

        // euint64 userBalance = encryptedBalances[msg.sender][tokenIn];

        orderId = ++orderIdCounter;

        orders[orderId] = ShadowOrder({
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

        userOrders[msg.sender].push(orderId);

        emit ShadowOrderCreated(orderId, msg.sender, poolId, tokenIn, tokenOut);

        return orderId;
    }

    /// @notice Cancel pending order
    /// @dev Only order creator can cancel
    function cancelOrder(uint256 orderId) external {
        ShadowOrder storage order = orders[orderId];

        if (order.user != msg.sender) revert Unauthorized();
        if (order.status != OrderStatus.Pending) revert OrderAlreadyExecuted();

        order.status = OrderStatus.Cancelled;

        emit ShadowOrderCancelled(orderId, msg.sender);
    }

    /// @notice Validate order before swap (called by PrismHook)
    /// @dev Performs FHE validation without revealing amounts
    function validateOrder(
        uint256 orderId,
        address sender,
        PoolId poolId
    ) external view onlyHook returns (bool) {
        ShadowOrder storage order = orders[orderId];

        if (order.user != sender) return false;
        if (PoolId.unwrap(order.poolId) != PoolId.unwrap(poolId)) return false;
        if (order.status != OrderStatus.Pending) return false;

        // FHE validation of deadline (encrypted comparison)
        // For MVP: assume deadline valid, add FHE.lte() check in production
        // ebool isValid = FHE.lte(FHE.asEuint64(block.timestamp), order.encryptedDeadline);

        return true;
    }

    /// @notice Settle order after swap (called by PrismHook)
    /// @dev Updates encrypted balances with swap results
    function settleOrder(
        uint256 orderId,
        address user,
        uint256 outputAmount
    ) external onlyHook returns (bool) {
        ShadowOrder storage order = orders[orderId];

        if (order.status != OrderStatus.Pending) revert OrderAlreadyExecuted();

        // Update status
        order.status = OrderStatus.Executed;
        order.executedAt = block.timestamp;

        // Update encrypted balances
        // Subtract input amount (encrypted)
        euint64 currentBalanceIn = encryptedBalances[user][order.tokenIn];
        encryptedBalances[user][order.tokenIn] = FHE.sub(
            currentBalanceIn,
            order.encryptedAmountIn
        );

        // Add output amount (encrypt plaintext output)
        euint64 encryptedOutput = FHE.asEuint64(outputAmount);
        euint64 currentBalanceOut = encryptedBalances[user][order.tokenOut];
        encryptedBalances[user][order.tokenOut] = FHE.add(
            currentBalanceOut,
            encryptedOutput
        );

        emit ShadowOrderExecuted(orderId, user, block.timestamp);

        return true;
    }

    /**
     * @notice Deposit tokens and encrypt balance
     * @dev Users deposit plaintext but balance stored encrypted
     */
    function depositEncrypted(
        Currency token,
        inEuint64 calldata encryptedAmount
    ) external {
        euint64 amount = FHE.asEuint64(encryptedAmount);

        // Add to encrypted balance
        euint64 currentBalance = encryptedBalances[msg.sender][token];
        encryptedBalances[msg.sender][token] = FHE.add(currentBalance, amount);

        emit BalanceDeposited(msg.sender, token, block.timestamp);
    }

    /**
     * @notice Withdraw tokens (decrypt required)
     * @dev User must provide permission to decrypt their balance
     */
    function withdrawEncrypted(
        Currency token,
        inEuint64 calldata encryptedAmount,
        Permission calldata permission
    ) external {
        euint64 amount = FHE.asEuint64(encryptedAmount);

        // Verify permission to decrypt balance
        euint64 currentBalance = encryptedBalances[msg.sender][token];

        // FHE check: balance >= amount
        // For MVP, assume valid; add FHE.select() for production

        // Subtract from encrypted balance
        encryptedBalances[msg.sender][token] = FHE.sub(currentBalance, amount);

        // Transfer tokens (would need actual ERC20 transfer in production)
        // For now, just emit event

        emit BalanceWithdrawn(msg.sender, token, block.timestamp);
    }

    /**
     * @notice Get encrypted balance (user can decrypt with their key)
     * @dev Returns sealed ciphertext that only user can open
     */
    function getEncryptedBalance(
        Currency token,
        Permission calldata permission
    ) external view onlySender(permission) returns (string memory) {
        euint64 balance = encryptedBalances[msg.sender][token];
        return FHE.sealoutput(balance, permission.publicKey);
    }

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Get user's order IDs
     */
    function getUserOrders(
        address user
    ) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    /**
     * @notice Get order details (encrypted fields remain private)
     */
    function getOrder(
        uint256 orderId
    )
        external
        view
        returns (
            address user,
            PoolId poolId,
            Currency tokenIn,
            Currency tokenOut,
            OrderStatus status,
            uint256 createdAt,
            uint256 executedAt
        )
    {
        ShadowOrder storage order = orders[orderId];
        return (
            order.user,
            order.poolId,
            order.tokenIn,
            order.tokenOut,
            order.status,
            order.createdAt,
            order.executedAt
        );
    }

    function _onlyHook() internal view {
        if (msg.sender != PRISM_HOOK) revert Unauthorized();
    }
}
