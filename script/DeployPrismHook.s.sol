// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {ShadowSwap} from "../src/core/ShadowSwap.sol";
import {PrismHook} from "../src/PrismHook.sol";

contract Deploy is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address owner = vm.envAddress("OWNER");

        ShadowSwap shadowSwap;
        PrismHook hook;

        console.log("Starting deployment...");
        console.log("Pool Manager:", poolManager);
        console.log("Owner:", owner);

        vm.startBroadcast();

        shadowSwap = new ShadowSwap(poolManager, owner);
        console.log("ShadowSwap deployed at:", address(shadowSwap));

        vm.stopBroadcast();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, owner);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(PrismHook).creationCode,
            constructorArgs
        );

        console.log("Computed hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        vm.startBroadcast();

        hook = new PrismHook{salt: salt}(IPoolManager(poolManager), owner);
        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("PrismHook deployed at:", address(hook));

        vm.stopBroadcast();

        console.log("\n=== Contracts deployed, now linking... ===");

        uint256 ownerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(ownerPrivateKey);

        hook.setShadowSwap(address(shadowSwap));
        console.log("ShadowSwap linked to PrismHook");

        shadowSwap.setPrismHook(address(hook));
        console.log("PrismHook linked to ShadowSwap");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("ShadowSwap:", address(shadowSwap));
        console.log("PrismHook:", address(hook));
        console.log("Owner:", owner);
        console.log("========================\n");
    }
}
