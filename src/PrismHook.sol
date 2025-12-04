// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {inEuint32} from "fhenix-contracts/contracts/FHE.sol";
import {ShadowSwapManager} from "./core/ShadowSwapManager.sol";
import {EncryptedSwapStorage} from "./core/EncryptedSwapStorage.sol";

contract PrismHook is BaseHook {
    // Dependencies
    ShadowSwapManager public immutable manager;
    EncryptedSwapStorage public immutable storageContract;

    // Reentrancy guard for claims
    bool private _locked;

    // Errors
    error ReentrantCall();

    /// @notice Prevents reentrancy on claim functions
    modifier nonReentrant() {
        if (_locked) revert ReentrantCall();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        // Deploy storage contract (hook is authorized writer)
        storageContract = new EncryptedSwapStorage(address(this));

        // Deploy manager with dependencies
        manager = new ShadowSwapManager(
            address(storageContract),
            address(_poolManager)
        );
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

    /// @notice Hook callback before swap execution
    /// @dev Accepts encrypted parameters and stores intent
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Decode encrypted params from hookData
        (
            inEuint32 memory encAmountIn,
            inEuint32 memory encMinOut,
            uint32 deadline
        ) = abi.decode(hookData, (inEuint32, inEuint32, uint32));

        // Process and store encrypted intent
        manager.processSwapIntent(
            encAmountIn,
            encMinOut,
            sender,
            key,
            params.zeroForOne,
            deadline
        );

        // Return: selector, no delta modification, no fee override
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /// @notice Hook callback after swap execution
    /// @dev Encrypts actual output amount for user claim
    /// @param sender User who initiated swap
    /// @param key Pool that was swapped against
    /// @param params Original swap parameters
    /// @param delta Actual swap result from PoolManager
    /// @param hookData Contains intentId from beforeSwap
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        // Decode intentId from hookData
        bytes32 intentId = abi.decode(hookData, (bytes32));

        // Extract actual output amount from delta
        uint256 amountOut = params.zeroForOne
            ? uint256(uint128(-delta.amount1()))
            : uint256(uint128(-delta.amount0()));

        // Encrypt and store result
        manager.recordSwapResult(intentId, amountOut);

        // Return: selector, no delta override
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice User claims their encrypted swap output
    /// @dev Protected by nonReentrant guard
    /// @param intentId The swap intent identifier
    /// @param publicKey User's FHE public key for sealing
    /// @return Sealed ciphertext only user can decrypt
    function claimSwapOutput(
        bytes32 intentId,
        bytes32 publicKey
    ) external nonReentrant returns (string memory) {
        return manager.claimSwapOutput(intentId, publicKey);
    }
}
