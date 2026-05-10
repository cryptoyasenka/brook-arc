// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice ERC20 mock that simulates a USDC-style blacklist: transfers TO the
///         blacklisted address revert. Used to prove cancel() is DoS-proof when
///         either party gets blacklisted.
contract BlacklistERC20 is MockERC20 {
    mapping(address => bool) public blacklisted;

    error Blacklisted(address account);

    constructor(string memory n, string memory s, uint8 d) MockERC20(n, s, d) {}

    function setBlacklisted(address account, bool isBlocked) external {
        blacklisted[account] = isBlocked;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (blacklisted[to]) revert Blacklisted(to);
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (blacklisted[to]) revert Blacklisted(to);
        if (blacklisted[from]) revert Blacklisted(from);
        return super.transferFrom(from, to, value);
    }
}
