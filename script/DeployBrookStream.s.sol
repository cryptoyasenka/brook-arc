// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BrookStream} from "../src/BrookStream.sol";

/// @notice Deploy BrookStream against the configured Arc testnet USDC.
/// @dev    Usage:
///         dry-run:  forge script script/DeployBrookStream.s.sol --rpc-url arc_testnet
///         deploy :  forge script script/DeployBrookStream.s.sol --rpc-url arc_testnet \
///                       --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify
///
///         Required env:
///           DEPLOYER_PRIVATE_KEY  hex-encoded private key with Arc testnet USDC for gas
///           USDC_ADDRESS          ERC20 token address (defaults to Arc testnet USDC)
///
///         On --broadcast: writes the deployed address to
///         deployments/<chainId>.json so the UI / smoke-test script can pick it up.
contract DeployBrookStream is Script {
    address internal constant DEFAULT_ARC_USDC = 0x3600000000000000000000000000000000000000;

    function run() external returns (BrookStream brook) {
        address usdc = vm.envOr("USDC_ADDRESS", DEFAULT_ARC_USDC);
        require(usdc != address(0), "USDC address must be non-zero");
        require(usdc != msg.sender, "USDC_ADDRESS equals deployer EOA - wrong env var");

        console2.log("Deploying BrookStream against USDC:", usdc);
        console2.log("Chain id:", block.chainid);
        console2.log("Deployer:", msg.sender);

        vm.startBroadcast();
        brook = new BrookStream(IERC20(usdc));
        vm.stopBroadcast();

        console2.log("BrookStream deployed at:", address(brook));
        _writeDeployment(address(brook), usdc);
    }

    function _writeDeployment(address brookAddr, address usdc) internal {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(block.chainid),
            ",\n",
            '  "brookStream": "',
            vm.toString(brookAddr),
            '",\n',
            '  "usdc": "',
            vm.toString(usdc),
            '",\n',
            '  "blockNumber": ',
            vm.toString(block.number),
            ",\n",
            '  "deployer": "',
            vm.toString(msg.sender),
            '"\n',
            "}\n"
        );
        vm.writeFile(path, json);
        console2.log("Deployment manifest written to:", path);
    }
}
