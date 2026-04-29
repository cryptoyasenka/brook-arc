// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fee-on-transfer ERC20 mock — burns `feeBps` (default 1%) of every transferFrom.
///         Used to verify BrookStream rejects fee tokens via balance-delta check.
contract FeeOnTransferERC20 is ERC20 {
    uint8 private immutable _decimals;
    uint256 public feeBps = 100; // 1%

    constructor() ERC20("FeeOnTransfer", "FOT") {
        _decimals = 6;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount * feeBps / 10_000;
        uint256 net = amount - fee;
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, net);
        if (fee > 0) _burn(from, fee);
        return true;
    }
}
