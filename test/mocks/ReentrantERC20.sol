// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Malicious ERC20: on every `transfer`, optionally re-enters a target contract
///         with arbitrary calldata. Used to verify BrookStream's nonReentrant guard.
contract ReentrantERC20 is ERC20 {
    uint8 private immutable _decimals;
    address public target;
    bytes public reentrantCalldata;
    bool public attackArmed;

    constructor() ERC20("Reentrant", "REENT") {
        _decimals = 6;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address _target, bytes calldata _calldata) external {
        target = _target;
        reentrantCalldata = _calldata;
        attackArmed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (attackArmed) {
            attackArmed = false;
            (bool ok, bytes memory ret) = target.call(reentrantCalldata);
            if (!ok) {
                assembly {
                    let size := returndatasize()
                    returndatacopy(0, 0, size)
                    revert(0, size)
                }
            }
            ret; // silence unused warning
        }
        return super.transfer(to, amount);
    }
}
