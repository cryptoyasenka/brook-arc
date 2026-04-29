// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BrookStream} from "../src/BrookStream.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Smoke tests for Phase 2. Full T1-T17 suite lands in Phase 3.
contract BrookStreamSmokeTest is Test {
    BrookStream internal brook;
    MockERC20 internal usdc;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint128 internal constant DEPOSIT = 100_000_000; // 100 USDC (6 decimals)
    uint64 internal constant DURATION = 30 days;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        brook = new BrookStream(usdc);

        usdc.mint(alice, DEPOSIT);
        vm.prank(alice);
        usdc.approve(address(brook), type(uint256).max);
    }

    function test_HappyPath_CreateMidWithdrawEndFlush() public {
        // create
        vm.prank(alice);
        uint256 streamId = brook.createStream(bob, DEPOSIT, DURATION);
        assertEq(streamId, 0);
        assertEq(usdc.balanceOf(address(brook)), DEPOSIT);
        assertEq(usdc.balanceOf(alice), 0);

        // half-way
        vm.warp(block.timestamp + DURATION / 2);
        uint128 mid = brook.withdrawable(streamId);
        assertEq(mid, DEPOSIT / 2);

        vm.prank(bob);
        brook.withdraw(streamId, bob, mid);
        assertEq(usdc.balanceOf(bob), DEPOSIT / 2);

        // end-flush — past endTime, recipient pulls remainder, no dust
        vm.warp(block.timestamp + DURATION);
        uint128 remainder = brook.withdrawable(streamId);
        assertEq(remainder, DEPOSIT - mid);

        vm.prank(bob);
        brook.withdraw(streamId, bob, remainder);
        assertEq(usdc.balanceOf(bob), DEPOSIT);
        assertEq(usdc.balanceOf(address(brook)), 0);
    }

    function test_Cancel_MidStream_PaysBothImmediately() public {
        vm.prank(alice);
        uint256 streamId = brook.createStream(bob, DEPOSIT, DURATION);

        vm.warp(block.timestamp + DURATION / 2);

        vm.prank(alice);
        brook.cancel(streamId);

        // bob got streamed half, alice got refund of remaining half
        assertEq(usdc.balanceOf(bob), DEPOSIT / 2);
        assertEq(usdc.balanceOf(alice), DEPOSIT / 2);
        assertEq(usdc.balanceOf(address(brook)), 0);
        assertEq(brook.withdrawable(streamId), 0);
    }

    function test_Revert_RecipientIsZero() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InvalidRecipient.selector);
        brook.createStream(address(0), DEPOSIT, DURATION);
    }

    function test_Revert_RecipientIsSelf() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InvalidRecipient.selector);
        brook.createStream(alice, DEPOSIT, DURATION);
    }

    function test_Revert_AmountZero() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InvalidAmount.selector);
        brook.createStream(bob, 0, DURATION);
    }

    function test_Revert_DurationZero() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InvalidDuration.selector);
        brook.createStream(bob, DEPOSIT, 0);
    }

    function test_Revert_NonRecipientWithdraw() public {
        vm.prank(alice);
        uint256 streamId = brook.createStream(bob, DEPOSIT, DURATION);

        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(alice); // alice is sender, not recipient
        vm.expectRevert(BrookStream.NotRecipient.selector);
        brook.withdraw(streamId, alice, 1);
    }

    function test_Revert_NonSenderCancel() public {
        vm.prank(alice);
        uint256 streamId = brook.createStream(bob, DEPOSIT, DURATION);

        vm.prank(bob); // bob is recipient, not sender
        vm.expectRevert(BrookStream.NotSender.selector);
        brook.cancel(streamId);
    }
}
