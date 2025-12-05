// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IShadowSwap} from "../src/interfaces/IShadowSwap.sol";

contract MockPoolManager {
    function unlock(bytes calldata data) external pure returns (bytes memory) {
        return data;
    }
}

contract MockShadowSwap is IShadowSwap {
    using PoolIdLibrary for PoolKey;

    mapping(uint256 => OrderInfo) public orders;
    mapping(uint256 => bool) public orderValidations;
    mapping(address => uint256[]) internal _userOrders;
    uint256 public orderCounter;
    address public prismHook;

    function setPrismHook(address _hook) external {
        prismHook = _hook;
    }

    function setOrderValidation(uint256 orderId, bool valid) external {
        orderValidations[orderId] = valid;
    }

    function createMockOrder(
        address user,
        PoolId poolId,
        Currency tokenIn,
        Currency tokenOut
    ) external returns (uint256) {
        uint256 orderId = ++orderCounter;
        orders[orderId] = OrderInfo({
            user: user,
            poolId: poolId,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            status: OrderStatus.Pending,
            createdAt: block.timestamp,
            executedAt: 0
        });
        _userOrders[user].push(orderId);
        orderValidations[orderId] = true;
        return orderId;
    }

    function createShadowOrder(
        PoolId poolId,
        Currency tokenIn,
        Currency tokenOut,
        bytes calldata,
        bytes calldata,
        bytes calldata
    ) external returns (uint256 orderId) {
        orderId = ++orderCounter;
        orders[orderId] = OrderInfo({
            user: msg.sender,
            poolId: poolId,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            status: OrderStatus.Pending,
            createdAt: block.timestamp,
            executedAt: 0
        });
        _userOrders[msg.sender].push(orderId);
        orderValidations[orderId] = true;
        emit ShadowOrderCreated(orderId, msg.sender, poolId, tokenIn, tokenOut);
        return orderId;
    }

    function cancelOrder(uint256 orderId) external {
        if (orders[orderId].user != msg.sender) revert Unauthorized();
        if (orders[orderId].status != OrderStatus.Pending)
            revert OrderNotPending();
        orders[orderId].status = OrderStatus.Cancelled;
        emit ShadowOrderCancelled(orderId, msg.sender);
    }

    function validateOrder(
        uint256 orderId,
        address sender,
        PoolId poolId
    ) external view returns (bool) {
        if (msg.sender != prismHook) revert Unauthorized();
        OrderInfo storage order = orders[orderId];
        if (order.user != sender) return false;
        if (PoolId.unwrap(order.poolId) != PoolId.unwrap(poolId)) return false;
        if (order.status != OrderStatus.Pending) return false;
        return orderValidations[orderId];
    }

    function settleOrder(
        uint256 orderId,
        address user,
        uint256
    ) external returns (bool) {
        if (msg.sender != prismHook) revert Unauthorized();
        if (orders[orderId].status != OrderStatus.Pending)
            revert OrderNotPending();
        orders[orderId].status = OrderStatus.Executed;
        orders[orderId].executedAt = block.timestamp;
        emit ShadowOrderExecuted(orderId, user, block.timestamp);
        return true;
    }

    function depositEncrypted(Currency, bytes calldata) external {}
    function withdrawEncrypted(
        Currency,
        bytes calldata,
        bytes calldata
    ) external {}
    function getEncryptedBalance(
        Currency,
        bytes calldata
    ) external pure returns (bytes memory) {
        return "";
    }
    function getUserOrders(
        address user
    ) external view returns (uint256[] memory) {
        return _userOrders[user];
    }
    function getOrder(
        uint256 orderId
    ) external view returns (OrderInfo memory) {
        return orders[orderId];
    }
    function getOrderCount() external view returns (uint256) {
        return orderCounter;
    }
    function isOrderActive(uint256 orderId) external view returns (bool) {
        return orders[orderId].status == OrderStatus.Pending;
    }
}

contract PrismHookHarness {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    IShadowSwap public immutable SHADOW_SWAP;
    address public immutable POOL_MANAGER;
    mapping(PoolId => mapping(address => bool)) public activeOrders;

    event ShadowSwapExecuted(
        PoolId indexed poolId,
        address indexed user,
        uint256 orderId,
        bool success
    );
    error InvalidOrder();
    error NotPoolManager();

    constructor(address _poolManager, address _shadowSwap) {
        POOL_MANAGER = _poolManager;
        SHADOW_SWAP = IShadowSwap(_shadowSwap);
    }

    modifier onlyPoolManager() {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager();
        _;
    }

    function getHookPermissions()
        public
        pure
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
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        uint256 orderId = abi.decode(hookData, (uint256));
        if (!SHADOW_SWAP.validateOrder(orderId, sender, poolId))
            revert InvalidOrder();
        activeOrders[poolId][sender] = true;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        uint256 orderId = abi.decode(hookData, (uint256));
        uint256 outputAmount;
        if (delta.amount0() > 0)
            outputAmount = uint256(int256(delta.amount0()));
        else if (delta.amount1() > 0)
            outputAmount = uint256(int256(delta.amount1()));
        bool success = SHADOW_SWAP.settleOrder(orderId, sender, outputAmount);
        activeOrders[poolId][sender] = false;
        emit ShadowSwapExecuted(poolId, sender, orderId, success);
        return (this.afterSwap.selector, 0);
    }
}

contract PrismHookTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager poolManager;
    MockShadowSwap shadowSwap;
    PrismHookHarness hook;
    address user = makeAddr("user");
    address attacker = makeAddr("attacker");
    Currency token0;
    Currency token1;
    PoolKey poolKey;

    function setUp() public {
        poolManager = new MockPoolManager();
        shadowSwap = new MockShadowSwap();
        hook = new PrismHookHarness(address(poolManager), address(shadowSwap));
        shadowSwap.setPrismHook(address(hook));
        token0 = Currency.wrap(makeAddr("token0"));
        token1 = Currency.wrap(makeAddr("token1"));
        poolKey = PoolKey({
            currency0: token0,
            currency1: token1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function test_GetHookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeInitialize);
    }

    function test_BeforeSwap_ValidOrder() public {
        uint256 orderId = shadowSwap.createMockOrder(
            user,
            poolKey.toId(),
            token0,
            token1
        );
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 1000,
            sqrtPriceLimitX96: 0
        });
        vm.prank(address(poolManager));
        (bytes4 selector, , uint24 fee) = hook.beforeSwap(
            user,
            poolKey,
            params,
            abi.encode(orderId)
        );
        assertEq(selector, hook.beforeSwap.selector);
        assertEq(fee, 0);
        assertTrue(hook.activeOrders(poolKey.toId(), user));
    }

    function test_BeforeSwap_RevertOnInvalidOrder() public {
        uint256 orderId = shadowSwap.createMockOrder(
            user,
            poolKey.toId(),
            token0,
            token1
        );
        shadowSwap.setOrderValidation(orderId, false);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 1000,
            sqrtPriceLimitX96: 0
        });
        vm.prank(address(poolManager));
        vm.expectRevert(PrismHookHarness.InvalidOrder.selector);
        hook.beforeSwap(user, poolKey, params, abi.encode(orderId));
    }

    function test_BeforeSwap_RevertOnNonPoolManager() public {
        uint256 orderId = shadowSwap.createMockOrder(
            user,
            poolKey.toId(),
            token0,
            token1
        );
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 1000,
            sqrtPriceLimitX96: 0
        });
        vm.prank(attacker);
        vm.expectRevert(PrismHookHarness.NotPoolManager.selector);
        hook.beforeSwap(user, poolKey, params, abi.encode(orderId));
    }

    function test_AfterSwap_SettlesOrder() public {
        uint256 orderId = shadowSwap.createMockOrder(
            user,
            poolKey.toId(),
            token0,
            token1
        );
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 1000,
            sqrtPriceLimitX96: 0
        });
        vm.startPrank(address(poolManager));
        hook.beforeSwap(user, poolKey, params, abi.encode(orderId));
        BalanceDelta delta = toBalanceDelta(int128(-1000), int128(950));
        (bytes4 selector, ) = hook.afterSwap(
            user,
            poolKey,
            params,
            delta,
            abi.encode(orderId)
        );
        vm.stopPrank();
        assertEq(selector, hook.afterSwap.selector);
        assertFalse(hook.activeOrders(poolKey.toId(), user));
        assertEq(
            uint8(shadowSwap.getOrder(orderId).status),
            uint8(IShadowSwap.OrderStatus.Executed)
        );
    }
}

contract ShadowSwapTest is Test {
    using PoolIdLibrary for PoolKey;

    MockShadowSwap shadowSwap;
    address prismHook = makeAddr("prismHook");
    address user = makeAddr("user");
    address attacker = makeAddr("attacker");
    Currency token0;
    Currency token1;
    PoolKey poolKey;

    function setUp() public {
        shadowSwap = new MockShadowSwap();
        shadowSwap.setPrismHook(prismHook);
        token0 = Currency.wrap(makeAddr("token0"));
        token1 = Currency.wrap(makeAddr("token1"));
        poolKey = PoolKey({
            currency0: token0,
            currency1: token1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function test_CreateShadowOrder() public {
        vm.prank(user);
        uint256 orderId = shadowSwap.createShadowOrder(
            poolKey.toId(),
            token0,
            token1,
            "",
            "",
            ""
        );
        assertEq(orderId, 1);
        assertTrue(shadowSwap.isOrderActive(orderId));
    }

    function test_CancelOrder() public {
        vm.prank(user);
        uint256 orderId = shadowSwap.createShadowOrder(
            poolKey.toId(),
            token0,
            token1,
            "",
            "",
            ""
        );
        vm.prank(user);
        shadowSwap.cancelOrder(orderId);
        assertFalse(shadowSwap.isOrderActive(orderId));
    }

    function test_CancelOrder_RevertOnUnauthorized() public {
        vm.prank(user);
        uint256 orderId = shadowSwap.createShadowOrder(
            poolKey.toId(),
            token0,
            token1,
            "",
            "",
            ""
        );
        vm.prank(attacker);
        vm.expectRevert(IShadowSwap.Unauthorized.selector);
        shadowSwap.cancelOrder(orderId);
    }

    function test_ValidateOrder_Success() public {
        vm.prank(user);
        uint256 orderId = shadowSwap.createShadowOrder(
            poolKey.toId(),
            token0,
            token1,
            "",
            "",
            ""
        );
        vm.prank(prismHook);
        assertTrue(shadowSwap.validateOrder(orderId, user, poolKey.toId()));
    }

    function test_ValidateOrder_RevertOnUnauthorized() public {
        vm.prank(user);
        uint256 orderId = shadowSwap.createShadowOrder(
            poolKey.toId(),
            token0,
            token1,
            "",
            "",
            ""
        );
        vm.prank(attacker);
        vm.expectRevert(IShadowSwap.Unauthorized.selector);
        shadowSwap.validateOrder(orderId, user, poolKey.toId());
    }

    function test_SettleOrder_Success() public {
        vm.prank(user);
        uint256 orderId = shadowSwap.createShadowOrder(
            poolKey.toId(),
            token0,
            token1,
            "",
            "",
            ""
        );
        vm.prank(prismHook);
        assertTrue(shadowSwap.settleOrder(orderId, user, 1000));
        assertEq(
            uint8(shadowSwap.getOrder(orderId).status),
            uint8(IShadowSwap.OrderStatus.Executed)
        );
    }

    function test_SettleOrder_RevertOnAlreadyExecuted() public {
        vm.prank(user);
        uint256 orderId = shadowSwap.createShadowOrder(
            poolKey.toId(),
            token0,
            token1,
            "",
            "",
            ""
        );
        vm.startPrank(prismHook);
        shadowSwap.settleOrder(orderId, user, 1000);
        vm.expectRevert(IShadowSwap.OrderNotPending.selector);
        shadowSwap.settleOrder(orderId, user, 1000);
    }
}
