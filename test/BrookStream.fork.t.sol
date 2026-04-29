// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BrookStream} from "../src/BrookStream.sol";

/// @notice T17 — fork test against real Arc testnet USDC.
///         Default-skipped to keep CI/local runs offline-friendly.
///         To run: `ARC_FORK=1 forge test --match-contract Fork`
///         Requires `arc_testnet` rpc alias in foundry.toml or ARC_TESTNET_RPC env.
contract BrookStreamForkTest is Test {
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    BrookStream internal brook;
    IERC20 internal usdc;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint128 internal constant DEPOSIT = 10_000_000; // 10 USDC
    uint64 internal constant DURATION = 1 days;

    modifier withFork() {
        if (vm.envOr("ARC_FORK", uint256(0)) == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (vm.envOr("ARC_FORK", uint256(0)) == 0) return;
        vm.createSelectFork("arc_testnet");
        usdc = IERC20(ARC_USDC);
        brook = new BrookStream(usdc);

        // Forge cheatcode — set USDC balance for alice on the fork.
        deal(ARC_USDC, alice, DEPOSIT, true);
        vm.prank(alice);
        usdc.approve(address(brook), type(uint256).max);
    }

    function test_Fork_CreateAndStream_OnArcTestnet() public withFork {
        vm.prank(alice);
        uint256 sid = brook.createStream(bob, DEPOSIT, DURATION);

        assertEq(usdc.balanceOf(address(brook)), DEPOSIT);
        assertEq(usdc.balanceOf(alice), 0);

        vm.warp(block.timestamp + DURATION);
        uint128 w = brook.withdrawable(sid);
        assertEq(w, DEPOSIT);

        vm.prank(bob);
        brook.withdraw(sid, bob, w);
        assertEq(usdc.balanceOf(bob), DEPOSIT);
        assertEq(usdc.balanceOf(address(brook)), 0);
    }

    function test_Fork_Cancel_OnArcTestnet() public withFork {
        vm.prank(alice);
        uint256 sid = brook.createStream(bob, DEPOSIT, DURATION);

        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(alice);
        brook.cancel(sid);

        assertEq(usdc.balanceOf(bob), DEPOSIT / 2);
        assertEq(usdc.balanceOf(alice), DEPOSIT / 2);
    }
}
