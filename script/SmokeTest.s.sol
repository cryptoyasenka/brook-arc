// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BrookStream} from "../src/BrookStream.sol";

/// @notice Phase 4.7 — post-deploy smoke-tests against the live Arc testnet.
///         Three modes, each one transaction. Foundry scripts can't sleep
///         across blocks, so the operator runs `create`, waits wall-clock,
///         then `withdraw` (or `cancel`).
///
/// @dev    Required env:
///           DEPLOYER_PRIVATE_KEY   sender / recipient depending on mode
///           BROOK_ADDRESS          deployed BrookStream address
///           SMOKE_MODE             "create" | "withdraw" | "cancel"
///         Mode-specific env:
///           create:  SMOKE_RECIPIENT, SMOKE_AMOUNT (default 100_000 = 0.1 USDC), SMOKE_DURATION (default 60)
///           withdraw / cancel: SMOKE_STREAM_ID
///
///         Usage:
///           SMOKE_MODE=create SMOKE_RECIPIENT=0x... \
///               forge script script/SmokeTest.s.sol --rpc-url arc_testnet \
///               --private-key $DEPLOYER_PRIVATE_KEY --broadcast
contract SmokeTest is Script {
    function run() external {
        BrookStream brook = BrookStream(vm.envAddress("BROOK_ADDRESS"));
        string memory mode = vm.envString("SMOKE_MODE");
        bytes32 modeHash = keccak256(bytes(mode));

        console2.log("Brook:", address(brook));
        console2.log("Mode :", mode);

        if (modeHash == keccak256("create")) {
            _create(brook);
        } else if (modeHash == keccak256("withdraw")) {
            _withdraw(brook);
        } else if (modeHash == keccak256("cancel")) {
            _cancel(brook);
        } else {
            revert("SMOKE_MODE must be create | withdraw | cancel");
        }
    }

    function _create(BrookStream brook) internal {
        address recipient = vm.envAddress("SMOKE_RECIPIENT");
        uint128 amount = uint128(vm.envOr("SMOKE_AMOUNT", uint256(100_000)));
        uint64 duration = uint64(vm.envOr("SMOKE_DURATION", uint256(60)));
        IERC20 usdc = brook.USDC();

        console2.log("Recipient:", recipient);
        console2.log("Amount   :", uint256(amount));
        console2.log("Duration :", uint256(duration));

        vm.startBroadcast();
        if (usdc.allowance(msg.sender, address(brook)) < amount) {
            usdc.approve(address(brook), type(uint256).max);
        }
        uint256 streamId = brook.createStream(recipient, amount, duration);
        vm.stopBroadcast();

        console2.log("createStream OK, streamId:", streamId);
        console2.log("Wait", uint256(duration), "seconds, then run withdraw or cancel.");
    }

    function _withdraw(BrookStream brook) internal {
        uint256 streamId = vm.envUint("SMOKE_STREAM_ID");
        uint128 available = brook.withdrawable(streamId);
        require(available > 0, "nothing withdrawable yet");
        console2.log("Available:", uint256(available));

        vm.startBroadcast();
        brook.withdraw(streamId, msg.sender, available);
        vm.stopBroadcast();
        console2.log("withdraw OK");
    }

    function _cancel(BrookStream brook) internal {
        uint256 streamId = vm.envUint("SMOKE_STREAM_ID");
        vm.startBroadcast();
        brook.cancel(streamId);
        vm.stopBroadcast();
        console2.log("cancel OK");
    }
}
