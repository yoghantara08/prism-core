// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwapTypes} from "../libraries/SwapTypes.sol";
import {euint32} from "fhenix-contracts/contracts/FHE.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title EncryptedSwapStorage
/// @notice Manages encrypted swap state with access control
/// @dev Only PrismHook can write, users can read their own swaps
contract EncryptedSwapStorage {
    using SwapTypes for *;

    // State variables
    address public immutable hook;

    /// @notice Maps intentId => SwapIntent
    mapping(bytes32 => SwapTypes.SwapIntent) internal swapIntents;

    /// @notice Maps intentId => SwapExecution
    /// @dev Separate mapping for gas optimization
    mapping(bytes32 => SwapTypes.SwapExecution) internal swapExecutions;

    // Errors
    error Unauthorized();
    error InvalidDeadline();
    error SwapNotFound();
    error SwapAlreadyExecuted();
    error SwapNotExecuted();
    error NotSwapOwner();

    /// @notice Only PrismHook can modify storage
    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        _;
    }

    /// @notice Only swap owner can claim
    modifier onlySwapOwner(bytes32 intentId) {
        if (swapIntents[intentId].user != msg.sender) revert NotSwapOwner();
        _;
    }

    constructor(address _hook) {
        hook = _hook;
    }

    /// @notice Create new swap intent
    /// @dev Called by hook in beforeSwap
    function createSwapIntent(
        bytes32 intentId,
        euint32 encAmountIn,
        euint32 encMinOut,
        address user,
        PoolId poolId,
        bool zeroForOne,
        uint32 deadline
    ) external onlyHook {
        if (block.timestamp >= deadline) revert InvalidDeadline();
        if (swapIntents[intentId].user != address(0))
            revert SwapAlreadyExecuted();

        swapIntents[intentId] = SwapTypes.SwapIntent({
            encryptedAmountIn: encAmountIn,
            encryptedMinAmountOut: encMinOut,
            user: user,
            poolId: poolId,
            zeroForOne: zeroForOne,
            deadline: deadline,
            status: SwapTypes.SwapStatus.Pending
        });
    }

    /// @notice Record swap execution result
    /// @dev Called by hook in afterSwap
    function recordExecution(
        bytes32 intentId,
        euint32 encAmountOut
    ) external onlyHook {
        SwapTypes.SwapIntent storage intent = swapIntents[intentId];
        if (intent.user == address(0)) revert SwapNotFound();
        if (intent.status != SwapTypes.SwapStatus.Pending)
            revert SwapAlreadyExecuted();

        intent.status = SwapTypes.SwapStatus.Executed;

        swapExecutions[intentId] = SwapTypes.SwapExecution({
            encryptedAmountOut: encAmountOut,
            executionBlock: block.number
        });
    }

    /// @notice Mark swap as claimed
    /// @dev Called after user retrieves encrypted output
    function markClaimed(bytes32 intentId) external onlyHook {
        SwapTypes.SwapIntent storage intent = swapIntents[intentId];
        if (intent.status != SwapTypes.SwapStatus.Executed)
            revert SwapNotExecuted();

        intent.status = SwapTypes.SwapStatus.Claimed;
    }

    /// @notice Get swap intent (read-only)
    function getSwapIntent(
        bytes32 intentId
    ) external view returns (SwapTypes.SwapIntent memory) {
        return swapIntents[intentId];
    }

    /// @notice Get swap execution (read-only)
    function getSwapExecution(
        bytes32 intentId
    ) external view returns (SwapTypes.SwapExecution memory) {
        return swapExecutions[intentId];
    }

    /// @notice Check if user owns swap
    function isSwapOwner(
        bytes32 intentId,
        address user
    ) external view returns (bool) {
        return swapIntents[intentId].user == user;
    }
}
