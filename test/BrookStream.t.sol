// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {BrookStream} from "../src/BrookStream.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {BlacklistERC20} from "./mocks/BlacklistERC20.sol";

/// @notice Phase 3 test suite — covers T1–T16 from CONTRACT-DESIGN-AUDIT.md section D
///         plus fuzz invariants. T17 (fork) lives in BrookStream.fork.t.sol.
contract BrookStreamTest is Test {
    BrookStream internal brook;
    MockERC20 internal usdc;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint128 internal constant DEPOSIT = 100_000_000; // 100 USDC (6 decimals)
    uint64 internal constant DURATION = 30 days;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        brook = new BrookStream(usdc);

        usdc.mint(alice, 10 * DEPOSIT);
        vm.prank(alice);
        usdc.approve(address(brook), type(uint256).max);
    }

    function _create() internal returns (uint256 streamId) {
        vm.prank(alice);
        streamId = brook.createStream(bob, DEPOSIT, DURATION);
    }

    // ------------------------------------------------------------------ T1
    function test_T1_HappyPath_LinearAccumulation_NoDust() public {
        uint256 streamId = _create();
        assertEq(streamId, 0);
        assertEq(usdc.balanceOf(address(brook)), DEPOSIT);
        assertEq(usdc.balanceOf(alice), 9 * DEPOSIT);

        vm.warp(block.timestamp + DURATION / 2);
        uint128 mid = brook.withdrawable(streamId);
        assertEq(mid, DEPOSIT / 2);

        vm.prank(bob);
        brook.withdraw(streamId, bob, mid);
        assertEq(usdc.balanceOf(bob), DEPOSIT / 2);

        vm.warp(block.timestamp + DURATION);
        uint128 remainder = brook.withdrawable(streamId);
        assertEq(remainder, DEPOSIT - mid);

        vm.prank(bob);
        brook.withdraw(streamId, bob, remainder);
        assertEq(usdc.balanceOf(bob), DEPOSIT);
        assertEq(usdc.balanceOf(address(brook)), 0);
    }

    // ------------------------------------------------------------------ T2
    function test_T2_CancelMidStream_CreditsPendingClaims() public {
        uint256 streamId = _create();

        vm.warp(block.timestamp + DURATION / 2);

        vm.expectEmit(true, false, false, true);
        emit BrookStream.Canceled(streamId, DEPOSIT / 2, DEPOSIT / 2);
        vm.prank(alice);
        brook.cancel(streamId);

        // Funds stay in brook, accounted in pendingClaims (pull-pattern).
        assertEq(brook.pendingClaims(bob), DEPOSIT / 2);
        assertEq(brook.pendingClaims(alice), DEPOSIT / 2);
        assertEq(usdc.balanceOf(address(brook)), DEPOSIT);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(alice), 9 * DEPOSIT);

        // Each party pulls their share.
        vm.prank(bob);
        brook.claim(bob, DEPOSIT / 2);
        vm.prank(alice);
        brook.claim(alice, DEPOSIT / 2);

        assertEq(usdc.balanceOf(bob), DEPOSIT / 2);
        assertEq(usdc.balanceOf(alice), 9 * DEPOSIT + DEPOSIT / 2);
        assertEq(usdc.balanceOf(address(brook)), 0);
    }

    // ------------------------------------------------------------------ T3
    function test_T3_WithdrawableZeroAfterCancel() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 4);
        vm.prank(alice);
        brook.cancel(streamId);

        assertEq(brook.withdrawable(streamId), 0);

        vm.prank(bob);
        vm.expectRevert(BrookStream.InsufficientWithdrawable.selector);
        brook.withdraw(streamId, bob, 1);
    }

    // ------------------------------------------------------------------ T4
    function test_T4_StartTimeIsAlwaysBlockTimestamp() public {
        vm.warp(1_700_000_000);
        uint256 streamId = _create();
        (,,,, uint64 startTime,,) = brook.streams(streamId);
        assertEq(startTime, 1_700_000_000);
    }

    // ------------------------------------------------------------------ T5
    function test_T5_RecipientZero_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InvalidRecipient.selector);
        brook.createStream(address(0), DEPOSIT, DURATION);
    }

    function test_T5_RecipientIsSender_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InvalidRecipient.selector);
        brook.createStream(alice, DEPOSIT, DURATION);
    }

    // ------------------------------------------------------------------ T6
    function test_T6_AmountZero_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InvalidAmount.selector);
        brook.createStream(bob, 0, DURATION);
    }

    function test_T6_DurationZero_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InvalidDuration.selector);
        brook.createStream(bob, DEPOSIT, 0);
    }

    // ------------------------------------------------------------------ T7
    function test_T7_Reentrancy_OnClaim_Blocked() public {
        // cancel() no longer transfers, so it can't be reentered via token.transfer.
        // The transfer surface moved to claim() — guard it there.
        ReentrantERC20 token = new ReentrantERC20();
        BrookStream brook2 = new BrookStream(IERC20(address(token)));

        token.mint(alice, DEPOSIT);
        vm.prank(alice);
        token.approve(address(brook2), type(uint256).max);

        vm.prank(alice);
        uint256 sid = brook2.createStream(bob, DEPOSIT, DURATION);

        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(alice);
        brook2.cancel(sid); // credits pendingClaims, no transfer

        // arm: when token.transfer fires (during claim), re-enter claim
        token.arm(address(brook2), abi.encodeCall(BrookStream.claim, (alice, 1)));

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        brook2.claim(alice, DEPOSIT / 2);
    }

    function test_T7_Reentrancy_OnWithdraw_Blocked() public {
        ReentrantERC20 token = new ReentrantERC20();
        BrookStream brook2 = new BrookStream(IERC20(address(token)));

        token.mint(alice, DEPOSIT);
        vm.prank(alice);
        token.approve(address(brook2), type(uint256).max);

        vm.prank(alice);
        uint256 sid = brook2.createStream(bob, DEPOSIT, DURATION);

        token.arm(address(brook2), abi.encodeCall(BrookStream.withdraw, (sid, bob, 1)));

        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(bob);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        brook2.withdraw(sid, bob, DEPOSIT / 4);
    }

    // ------------------------------------------------------------------ T8
    function test_T8_FeeOnTransfer_Reverts() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        BrookStream brook2 = new BrookStream(IERC20(address(fot)));

        fot.mint(alice, DEPOSIT);
        vm.prank(alice);
        fot.approve(address(brook2), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(BrookStream.FeeOnTransferNotSupported.selector);
        brook2.createStream(bob, DEPOSIT, DURATION);
    }

    // ------------------------------------------------------------------ T9
    function test_T9_ConcurrentStreams_SameSenderRecipient_Independent() public {
        vm.prank(alice);
        uint256 s0 = brook.createStream(bob, DEPOSIT, DURATION);
        vm.prank(alice);
        uint256 s1 = brook.createStream(bob, DEPOSIT, DURATION * 2);
        vm.prank(alice);
        uint256 s2 = brook.createStream(bob, DEPOSIT / 2, DURATION);

        assertEq(s0, 0);
        assertEq(s1, 1);
        assertEq(s2, 2);

        vm.warp(block.timestamp + DURATION);
        // s0 fully streamed; s1 half streamed; s2 fully streamed
        assertEq(brook.withdrawable(s0), DEPOSIT);
        assertEq(brook.withdrawable(s1), DEPOSIT / 2);
        assertEq(brook.withdrawable(s2), DEPOSIT / 2);

        // cancel s1; s0 and s2 unaffected
        vm.prank(alice);
        brook.cancel(s1);
        assertEq(brook.withdrawable(s0), DEPOSIT);
        assertEq(brook.withdrawable(s1), 0);
        assertEq(brook.withdrawable(s2), DEPOSIT / 2);
    }

    // ------------------------------------------------------------------ T10
    function test_T10_WithdrawAmountExceedsAvailable_Reverts() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 4);

        uint128 available = brook.withdrawable(streamId);
        vm.prank(bob);
        vm.expectRevert(BrookStream.InsufficientWithdrawable.selector);
        brook.withdraw(streamId, bob, available + 1);
    }

    // ------------------------------------------------------------------ T11
    function test_T11_WithdrawToZeroAddress_Reverts() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 2);

        vm.prank(bob);
        vm.expectRevert(BrookStream.InvalidRecipient.selector);
        brook.withdraw(streamId, address(0), 1);
    }

    // ------------------------------------------------------------------ T12
    function test_T12_DoubleCancel_Reverts() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 2);

        vm.prank(alice);
        brook.cancel(streamId);

        vm.prank(alice);
        vm.expectRevert(BrookStream.AlreadyCanceled.selector);
        brook.cancel(streamId);
    }

    // ------------------------------------------------------------------ T13
    function test_T13_DoubleWithdrawSameBlock_SecondReverts() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 2);

        uint128 available = brook.withdrawable(streamId);
        vm.prank(bob);
        brook.withdraw(streamId, bob, available);

        // No further block progress — withdrawable returns 0 (streamed - withdrawn == 0)
        assertEq(brook.withdrawable(streamId), 0);
        vm.prank(bob);
        vm.expectRevert(BrookStream.InsufficientWithdrawable.selector);
        brook.withdraw(streamId, bob, 1);
    }

    // ------------------------------------------------------------------ T14
    function test_T14_EndTimeOverflow_Reverts() public {
        // Warp close to uint64 max so startTime + duration overflows uint64.
        uint64 nearMax = type(uint64).max - 100;
        vm.warp(uint256(nearMax));

        vm.prank(alice);
        vm.expectRevert(); // Panic 0x11 — arithmetic overflow on startTime + duration
        brook.createStream(bob, DEPOSIT, 1000);
    }

    // ------------------------------------------------------------------ T15
    function test_T15_WithdrawForeignStream_Reverts() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 2);

        vm.prank(carol);
        vm.expectRevert(BrookStream.NotRecipient.selector);
        brook.withdraw(streamId, carol, 1);
    }

    // ------------------------------------------------------------------ T16
    function test_T16_CancelForeignStream_Reverts() public {
        uint256 streamId = _create();

        vm.prank(carol);
        vm.expectRevert(BrookStream.NotSender.selector);
        brook.cancel(streamId);
    }

    // ------------------------------------------------------------------ Bonus
    function test_Withdrawable_NonExistentStream_ReturnsZero() public view {
        assertEq(brook.withdrawable(999), 0);
    }

    function test_StreamNotFound_Withdraw() public {
        vm.prank(bob);
        vm.expectRevert(BrookStream.StreamNotFound.selector);
        brook.withdraw(999, bob, 1);
    }

    function test_StreamNotFound_Cancel() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.StreamNotFound.selector);
        brook.cancel(999);
    }

    function test_WithdrawZeroAmount_Reverts() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(bob);
        vm.expectRevert(BrookStream.InvalidAmount.selector);
        brook.withdraw(streamId, bob, 0);
    }

    function test_CancelAtExactEndTime_FullPayoutToRecipient() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION);

        vm.prank(alice);
        brook.cancel(streamId);
        assertEq(brook.pendingClaims(bob), DEPOSIT);
        assertEq(brook.pendingClaims(alice), 0);

        vm.prank(bob);
        brook.claim(bob, DEPOSIT);
        assertEq(usdc.balanceOf(bob), DEPOSIT);
        assertEq(usdc.balanceOf(alice), 9 * DEPOSIT);
    }

    function test_CancelImmediately_NoElapsedTime_RefundFull() public {
        uint256 streamId = _create();
        // No vm.warp — same block as create.
        vm.prank(alice);
        brook.cancel(streamId);

        assertEq(brook.pendingClaims(alice), DEPOSIT);
        assertEq(brook.pendingClaims(bob), 0);

        vm.prank(alice);
        brook.claim(alice, DEPOSIT);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(alice), 10 * DEPOSIT);
        assertEq(usdc.balanceOf(address(brook)), 0);
    }

    function test_CreateStreamWithPermit_HappyPath() public {
        uint256 alicePk = 0xA11CE;
        address alicePerm = vm.addr(alicePk);
        usdc.mint(alicePerm, DEPOSIT);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = usdc.nonces(alicePerm);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alicePerm,
                address(brook),
                uint256(DEPOSIT),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.prank(alicePerm);
        uint256 streamId = brook.createStreamWithPermit(bob, DEPOSIT, DURATION, deadline, v, r, s);
        assertEq(streamId, 0);
        assertEq(usdc.balanceOf(address(brook)), DEPOSIT);
        assertEq(usdc.balanceOf(alicePerm), 0);

        vm.warp(block.timestamp + DURATION);
        vm.prank(bob);
        brook.withdraw(streamId, bob, DEPOSIT);
        assertEq(usdc.balanceOf(bob), DEPOSIT);
    }

    function test_CreateStreamWithPermit_FrontrunSurvives() public {
        uint256 alicePk = 0xA11CE;
        address alicePerm = vm.addr(alicePk);
        usdc.mint(alicePerm, DEPOSIT);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = usdc.nonces(alicePerm);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alicePerm,
                address(brook),
                uint256(DEPOSIT),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // Attacker grabs (v,r,s) from mempool and submits permit() directly to USDC first.
        vm.prank(carol);
        usdc.permit(alicePerm, address(brook), DEPOSIT, deadline, v, r, s);
        assertEq(usdc.allowance(alicePerm, address(brook)), DEPOSIT);

        // Victim's tx still lands successfully — try/catch + allowance check covers the grief.
        vm.prank(alicePerm);
        uint256 streamId = brook.createStreamWithPermit(bob, DEPOSIT, DURATION, deadline, v, r, s);
        assertEq(streamId, 0);
        assertEq(usdc.balanceOf(address(brook)), DEPOSIT);
        assertEq(usdc.balanceOf(alicePerm), 0);
    }

    function test_CreateStreamWithPermit_RevertsWhenPermitFailsAndAllowanceShort() public {
        uint256 alicePk = 0xA11CE;
        address alicePerm = vm.addr(alicePk);
        usdc.mint(alicePerm, DEPOSIT);

        uint256 deadline = block.timestamp + 1 hours;

        // Sign with the WRONG nonce so permit always reverts and no allowance is set.
        uint256 wrongNonce = usdc.nonces(alicePerm) + 99;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alicePerm,
                address(brook),
                uint256(DEPOSIT),
                wrongNonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.prank(alicePerm);
        vm.expectRevert(BrookStream.PermitFailedAndAllowanceInsufficient.selector);
        brook.createStreamWithPermit(bob, DEPOSIT, DURATION, deadline, v, r, s);
    }

    function test_CancelAfterPartialWithdraw_NoDoublePay() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 4);

        vm.prank(bob);
        brook.withdraw(streamId, bob, DEPOSIT / 4);

        vm.warp(block.timestamp + DURATION / 4);
        // accrued = 50%, withdrawn = 25%, so on cancel bob is credited +25%, alice gets 50%
        vm.prank(alice);
        brook.cancel(streamId);

        assertEq(brook.pendingClaims(bob), DEPOSIT / 4);
        assertEq(brook.pendingClaims(alice), DEPOSIT / 2);

        vm.prank(bob);
        brook.claim(bob, DEPOSIT / 4);
        vm.prank(alice);
        brook.claim(alice, DEPOSIT / 2);

        assertEq(usdc.balanceOf(bob), DEPOSIT / 2);
        assertEq(usdc.balanceOf(alice), 9 * DEPOSIT + DEPOSIT / 2);
        assertEq(usdc.balanceOf(address(brook)), 0);
    }

    // ====================================================== CLAIM / DoS ===

    /// @notice The headline fix: cancel must succeed even when the recipient is
    ///         USDC-blacklisted, so the sender's funds aren't held hostage.
    function test_Cancel_BlacklistedRecipient_DoesNotBlockSender() public {
        BlacklistERC20 blUsdc = new BlacklistERC20("USD Coin", "USDC", 6);
        BrookStream brook2 = new BrookStream(IERC20(address(blUsdc)));

        blUsdc.mint(alice, DEPOSIT);
        vm.prank(alice);
        blUsdc.approve(address(brook2), type(uint256).max);

        vm.prank(alice);
        uint256 sid = brook2.createStream(bob, DEPOSIT, DURATION);

        // Bob gets blacklisted mid-stream (USDC enforcement action).
        blUsdc.setBlacklisted(bob, true);

        vm.warp(block.timestamp + DURATION / 2);

        // Cancel must succeed — no transfers happen, only accounting.
        vm.prank(alice);
        brook2.cancel(sid);

        assertEq(brook2.pendingClaims(alice), DEPOSIT / 2);
        assertEq(brook2.pendingClaims(bob), DEPOSIT / 2);

        // Alice can pull her refund unconditionally.
        vm.prank(alice);
        brook2.claim(alice, DEPOSIT / 2);
        assertEq(blUsdc.balanceOf(alice), DEPOSIT / 2);

        // Bob's claim to himself reverts (token-level), but he can route to a
        // non-blacklisted address — the contract doesn't gate him.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BlacklistERC20.Blacklisted.selector, bob));
        brook2.claim(bob, DEPOSIT / 2);

        vm.prank(bob);
        brook2.claim(carol, DEPOSIT / 2);
        assertEq(blUsdc.balanceOf(carol), DEPOSIT / 2);
    }

    function test_Claim_HappyPath() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(alice);
        brook.cancel(streamId);

        vm.expectEmit(true, true, false, true);
        emit BrookStream.Claimed(bob, bob, DEPOSIT / 2);
        vm.prank(bob);
        brook.claim(bob, DEPOSIT / 2);

        assertEq(brook.pendingClaims(bob), 0);
        assertEq(usdc.balanceOf(bob), DEPOSIT / 2);
    }

    function test_Claim_PartialThenRest() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(alice);
        brook.cancel(streamId);

        vm.prank(bob);
        brook.claim(bob, DEPOSIT / 4);
        assertEq(brook.pendingClaims(bob), DEPOSIT / 4);

        vm.prank(bob);
        brook.claim(bob, DEPOSIT / 4);
        assertEq(brook.pendingClaims(bob), 0);
        assertEq(usdc.balanceOf(bob), DEPOSIT / 2);
    }

    function test_Claim_AccumulatesAcrossStreams() public {
        uint256 s0 = _create();
        uint256 s1 = _create();
        vm.warp(block.timestamp + DURATION / 2);

        vm.prank(alice);
        brook.cancel(s0);
        vm.prank(alice);
        brook.cancel(s1);

        // Two cancels at midstream → bob credited DEPOSIT total.
        assertEq(brook.pendingClaims(bob), DEPOSIT);
        assertEq(brook.pendingClaims(alice), DEPOSIT);

        vm.prank(bob);
        brook.claim(bob, DEPOSIT);
        assertEq(usdc.balanceOf(bob), DEPOSIT);
    }

    function test_Claim_ZeroAmount_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InvalidAmount.selector);
        brook.claim(alice, 0);
    }

    function test_Claim_ToZeroAddress_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InvalidRecipient.selector);
        brook.claim(address(0), 1);
    }

    function test_Claim_InsufficientPending_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(BrookStream.InsufficientClaim.selector);
        brook.claim(alice, 1);
    }

    function test_Claim_ExceedsPending_Reverts() public {
        uint256 streamId = _create();
        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(alice);
        brook.cancel(streamId);

        vm.prank(bob);
        vm.expectRevert(BrookStream.InsufficientClaim.selector);
        brook.claim(bob, DEPOSIT / 2 + 1);
    }

    // ============================================================ FUZZ ===

    /// @dev streamed amount is monotone in elapsed, bounded by deposit, exact at endTime.
    function testFuzz_Withdrawable_Invariants(uint128 amount, uint64 duration, uint64 elapsed) public {
        amount = uint128(bound(uint256(amount), 1, type(uint128).max / 2));
        duration = uint64(bound(uint256(duration), 1, 365 days));
        elapsed = uint64(bound(uint256(elapsed), 0, uint256(duration) * 2));

        usdc.mint(alice, amount);
        vm.prank(alice);
        uint256 sid = brook.createStream(bob, amount, duration);

        vm.warp(block.timestamp + elapsed);
        uint128 w = brook.withdrawable(sid);

        assertLe(w, amount, "withdrawable must not exceed deposit");
        if (elapsed >= duration) {
            assertEq(w, amount, "at/after end, full deposit available");
        } else if (elapsed == 0) {
            assertEq(w, 0, "no time elapsed, nothing available");
        }
    }

    /// @dev cancel at any point preserves total: pendingClaims[alice] + pendingClaims[bob] == amount,
    ///      brook holds exactly that amount in USDC (pull-pattern).
    function testFuzz_Cancel_Conservation(uint128 amount, uint64 duration, uint64 elapsed) public {
        amount = uint128(bound(uint256(amount), 1, type(uint128).max / 2));
        duration = uint64(bound(uint256(duration), 1, 365 days));
        elapsed = uint64(bound(uint256(elapsed), 0, uint256(duration) * 2));

        usdc.mint(alice, amount);

        vm.prank(alice);
        uint256 sid = brook.createStream(bob, amount, duration);

        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        brook.cancel(sid);

        uint256 totalCredited = uint256(brook.pendingClaims(alice)) + uint256(brook.pendingClaims(bob));
        assertEq(totalCredited, amount, "cancel credits total deposit");
        assertEq(usdc.balanceOf(address(brook)), amount, "brook holds full amount until claims");
    }

    /// @dev partial withdraw + cancel + claim: combined external balances == deposit, no dust.
    function testFuzz_PartialWithdrawThenCancel_Conservation(
        uint128 amount,
        uint64 duration,
        uint64 elapsed1,
        uint64 elapsed2
    ) public {
        amount = uint128(bound(uint256(amount), 1000, type(uint128).max / 4));
        duration = uint64(bound(uint256(duration), 100, 365 days));
        elapsed1 = uint64(bound(uint256(elapsed1), 1, duration - 1));
        elapsed2 = uint64(bound(uint256(elapsed2), 0, duration));

        usdc.mint(alice, amount);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 sid = brook.createStream(bob, amount, duration);

        vm.warp(block.timestamp + elapsed1);
        uint128 w1 = brook.withdrawable(sid);
        if (w1 > 0) {
            vm.prank(bob);
            brook.withdraw(sid, bob, w1);
        }

        vm.warp(block.timestamp + elapsed2);
        vm.prank(alice);
        brook.cancel(sid);

        // Drain pending claims to external balances.
        uint128 alicePending = brook.pendingClaims(alice);
        uint128 bobPending = brook.pendingClaims(bob);
        if (alicePending > 0) {
            vm.prank(alice);
            brook.claim(alice, alicePending);
        }
        if (bobPending > 0) {
            vm.prank(bob);
            brook.claim(bob, bobPending);
        }

        uint256 total =
            usdc.balanceOf(alice) - (aliceBefore - amount) + usdc.balanceOf(bob) + usdc.balanceOf(address(brook));
        assertEq(total, amount, "withdraw+cancel+claim preserves total");
        assertEq(usdc.balanceOf(address(brook)), 0, "no dust");
    }

    /// @dev sequential partial withdraws after end == full deposit, no dust.
    function testFuzz_FullStream_NoDust(uint128 amount, uint64 duration, uint8 chunks) public {
        amount = uint128(bound(uint256(amount), 1000, type(uint128).max / 4));
        duration = uint64(bound(uint256(duration), 10, 365 days));
        chunks = uint8(bound(uint256(chunks), 1, 10));

        usdc.mint(alice, amount);
        vm.prank(alice);
        uint256 sid = brook.createStream(bob, amount, duration);

        uint64 step = duration / chunks;
        for (uint256 i = 0; i < chunks; i++) {
            vm.warp(block.timestamp + step);
            uint128 w = brook.withdrawable(sid);
            if (w > 0) {
                vm.prank(bob);
                brook.withdraw(sid, bob, w);
            }
        }
        // ensure we're past endTime
        vm.warp(block.timestamp + duration);
        uint128 finalW = brook.withdrawable(sid);
        if (finalW > 0) {
            vm.prank(bob);
            brook.withdraw(sid, bob, finalW);
        }

        assertEq(usdc.balanceOf(bob), amount, "bob receives full deposit");
        assertEq(usdc.balanceOf(address(brook)), 0, "no dust on contract");
    }
}
