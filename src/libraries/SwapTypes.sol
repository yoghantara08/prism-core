// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {euint32} from "fhenix-contracts/contracts/FHE.sol";

library SwapTypes {
    /// @notice Status of a shadow swap
    enum SwapStatus {
        Pending,
        Executed,
        Claimed
    }

    /// @notice User's encrypted swap intent (before execution)
    /// @dev Separate from execution data for gas optimization
    struct SwapIntent {
        euint32 encryptedAmountIn;
        euint32 encryptedMinAmountOut;
        address user;
        PoolId poolId;
        bool zeroForOne;
        uint32 deadline;
        SwapStatus status;
    }

    /// @notice Encrypted swap execution result (after swap)
    /// @dev Stored separately to avoid loading unused encrypted fields
    struct SwapExecution {
        euint32 encryptedAmountOut;
        uint256 executionBlock;
    }

    /// @notice Event emitted when swap intent created
    /// @dev Does NOT include amounts (they're encrypted)
    event SwapIntentCreated(
        bytes32 indexed intentId,
        address indexed user,
        PoolId indexed poolId,
        uint32 deadline
    );

    /// @notice Event emitted when swap executed
    event SwapExecuted(bytes32 indexed intentId, uint256 executionBlock);

    /// @notice Event emitted when user claims output
    /// @dev encryptedOutput is sealed for user's public key
    event SwapClaimed(
        bytes32 indexed intentId,
        address indexed user,
        bytes encryptedOutput
    );
}
