// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  Brook — USDC streaming primitive for Arc
/// @notice Linear, per-second USDC streams from sender to recipient.
///         End-flush dust strategy (no stored ratePerSecond).
///         Cancel pays both parties immediately. nonReentrant on all state-mutating paths.
contract BrookStream is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    struct Stream {
        address sender;
        address recipient;
        uint128 depositAmount;
        uint128 withdrawn;
        uint64 startTime;
        uint64 endTime;
        bool canceled;
    }

    mapping(uint256 => Stream) public streams;
    uint256 public nextStreamId;

    error InvalidRecipient();
    error InvalidAmount();
    error InvalidDuration();
    error NotSender();
    error NotRecipient();
    error AlreadyCanceled();
    error InsufficientWithdrawable();
    error StreamNotFound();
    error FeeOnTransferNotSupported();
    error PermitFailedAndAllowanceInsufficient();

    event StreamCreated(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        uint128 depositAmount,
        uint64 startTime,
        uint64 endTime
    );
    event Withdrawn(uint256 indexed streamId, address indexed to, uint128 amount);
    event Canceled(uint256 indexed streamId, uint128 senderRefund, uint128 recipientPayout);

    constructor(IERC20 usdc) {
        USDC = usdc;
    }

    /// @notice Create a stream paying `recipient` `amount` USDC over `duration` seconds.
    /// @dev Caller must have USDC allowance >= amount on this contract.
    function createStream(address recipient, uint128 amount, uint64 duration)
        external
        nonReentrant
        returns (uint256 streamId)
    {
        return _createStream(msg.sender, recipient, amount, duration);
    }

    /// @notice Create stream + pull USDC via EIP-2612 permit signature in one tx.
    /// @dev Frontrun-safe: if an attacker copies (v,r,s) from mempool and submits
    ///      permit() directly on USDC first, our permit call reverts on
    ///      already-used nonce — but the allowance is in place, so we still proceed.
    ///      We revert only when permit failed AND allowance is genuinely insufficient.
    function createStreamWithPermit(
        address recipient,
        uint128 amount,
        uint64 duration,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s_
    ) external nonReentrant returns (uint256 streamId) {
        // Permit may have been frontrun and consumed; if so, fall back to existing allowance.
        try IERC20Permit(address(USDC)).permit(msg.sender, address(this), amount, permitDeadline, v, r, s_) {}
        catch {
            if (USDC.allowance(msg.sender, address(this)) < amount) {
                revert PermitFailedAndAllowanceInsufficient();
            }
        }
        return _createStream(msg.sender, recipient, amount, duration);
    }

    function _createStream(address from, address recipient, uint128 amount, uint64 duration)
        internal
        returns (uint256 streamId)
    {
        if (recipient == address(0) || recipient == from) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();

        uint256 balanceBefore = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(from, address(this), amount);
        uint256 received = USDC.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert FeeOnTransferNotSupported();

        streamId = nextStreamId++;
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = startTime + duration;

        streams[streamId] = Stream({
            sender: from,
            recipient: recipient,
            depositAmount: amount,
            withdrawn: 0,
            startTime: startTime,
            endTime: endTime,
            canceled: false
        });

        emit StreamCreated(streamId, from, recipient, amount, startTime, endTime);
    }

    /// @notice Amount currently withdrawable by recipient. Zero if stream canceled
    ///         (cancel pays out immediately, leaves no balance for recipient).
    function withdrawable(uint256 streamId) public view returns (uint128) {
        Stream memory s = streams[streamId];
        if (s.recipient == address(0)) return 0;
        if (s.canceled) return 0;

        if (block.timestamp >= s.endTime) {
            return s.depositAmount - s.withdrawn;
        }

        uint64 elapsed = uint64(block.timestamp) - s.startTime;
        uint64 totalDuration = s.endTime - s.startTime;
        uint128 streamed = uint128(uint256(s.depositAmount) * elapsed / totalDuration);
        return streamed - s.withdrawn;
    }

    /// @notice Recipient pulls `amount` USDC to `to`. Use `withdrawable()` to query max.
    function withdraw(uint256 streamId, address to, uint128 amount) external nonReentrant {
        Stream storage s = streams[streamId];
        if (s.recipient == address(0)) revert StreamNotFound();
        if (msg.sender != s.recipient) revert NotRecipient();
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();

        uint128 available = withdrawable(streamId);
        if (amount > available) revert InsufficientWithdrawable();

        s.withdrawn += amount;
        USDC.safeTransfer(to, amount);

        emit Withdrawn(streamId, to, amount);
    }

    /// @notice Sender cancels stream. Recipient gets accrued, sender gets remainder.
    /// @dev Pays both parties immediately. After cancel, withdrawable() returns 0.
    function cancel(uint256 streamId) external nonReentrant {
        Stream storage s = streams[streamId];
        if (s.recipient == address(0)) revert StreamNotFound();
        if (msg.sender != s.sender) revert NotSender();
        if (s.canceled) revert AlreadyCanceled();

        uint128 streamed;
        if (block.timestamp >= s.endTime) {
            streamed = s.depositAmount;
        } else {
            uint64 elapsed = uint64(block.timestamp) - s.startTime;
            uint64 totalDuration = s.endTime - s.startTime;
            streamed = uint128(uint256(s.depositAmount) * elapsed / totalDuration);
        }

        uint128 recipientPayout = streamed - s.withdrawn;
        uint128 senderRefund = s.depositAmount - streamed;

        s.canceled = true;
        s.withdrawn = streamed;

        if (recipientPayout > 0) USDC.safeTransfer(s.recipient, recipientPayout);
        if (senderRefund > 0) USDC.safeTransfer(s.sender, senderRefund);

        emit Canceled(streamId, senderRefund, recipientPayout);
    }
}
