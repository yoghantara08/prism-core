// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {FHE, euint32, inEuint32} from "fhenix-contracts/contracts/FHE.sol";
import {EncryptedSwapStorage} from "./EncryptedSwapStorage.sol";
import {SwapTypes} from "../libraries/SwapTypes.sol";

/// @title ShadowSwapManager
/// @notice Handles FHE encryption and swap execution logic
/// @dev Called by PrismHook, interacts with EncryptedSwapStorage
contract ShadowSwapManager {
    using PoolIdLibrary for PoolKey;

    // Dependencies
    EncryptedSwapStorage public immutable storage_;
    IPoolManager public immutable poolManager;

    // Errors
    error InvalidEncryptedInput();
    error DeadlineExpired();

    event SwapIntentCreated(
        bytes32 indexed intentId,
        address indexed user,
        PoolId indexed poolId,
        uint32 deadline
    );
    event SwapExecuted(bytes32 indexed intentId, uint256 executionBlock);
    event SwapClaimed(
        bytes32 indexed intentId,
        address indexed user,
        bytes encryptedOutput
    );

    constructor(address _storage, address _poolManager) {
        storage_ = EncryptedSwapStorage(_storage);
        poolManager = IPoolManager(_poolManager);
    }

    /// @notice Process encrypted inputs and create swap intent
    /// @dev Called from hook's beforeSwap
    /// @return intentId Unique identifier for this swap
    function processSwapIntent(
        inEuint32 calldata encAmountIn,
        inEuint32 calldata encMinOut,
        address user,
        PoolKey calldata key,
        bool zeroForOne,
        uint32 deadline
    ) external returns (bytes32 intentId) {
        if (block.timestamp >= deadline) revert DeadlineExpired();

        // Convert input ciphertexts to storage type
        euint32 storedAmountIn = FHE.asEuint32(encAmountIn);
        euint32 storedMinOut = FHE.asEuint32(encMinOut);

        // Generate unique intent ID
        intentId = keccak256(
            abi.encodePacked(user, key.toId(), block.timestamp, block.number)
        );

        storage_.createSwapIntent(
            intentId,
            storedAmountIn,
            storedMinOut,
            user,
            key.toId(),
            zeroForOne,
            deadline
        );

        // Emit swap intent creation event
        emit SwapIntentCreated(intentId, user, key.toId(), deadline);

        return intentId;
    }

    /// @notice Encrypt swap output and store result
    /// @dev Called from hook's afterSwap
    function recordSwapResult(bytes32 intentId, uint256 amountOut) external {
        // Encrypt the output amount
        euint32 encryptedOutput = FHE.asEuint32(uint32(amountOut));

        // Store encrypted result
        storage_.recordExecution(intentId, encryptedOutput);

        // Emit execution event
        emit SwapExecuted(intentId, block.number);
    }

    /// @notice User claims their encrypted swap output
    /// @dev Re-encrypts output for user's public key (seal pattern)
    /// @param intentId The swap intent ID
    /// @param publicKey User's FHE public key for sealing
    /// @return encryptedOutput Sealed ciphertext only user can decrypt
    function claimSwapOutput(
        bytes32 intentId,
        bytes32 publicKey
    ) external returns (string memory encryptedOutput) {
        // Verify ownership (will revert if not owner)
        require(storage_.isSwapOwner(intentId, msg.sender), "Not owner");

        // Get encrypted output
        SwapTypes.SwapExecution memory execution = storage_.getSwapExecution(
            intentId
        );

        // Seal for user's public key
        encryptedOutput = execution.encryptedAmountOut.seal(publicKey);

        // Mark as claimed
        storage_.markClaimed(intentId);

        // Emit claim event
        emit SwapClaimed(intentId, msg.sender, bytes(encryptedOutput));

        return encryptedOutput;
    }
}
