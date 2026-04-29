// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Placeholder} from "../src/Placeholder.sol";

contract PlaceholderTest is Test {
    Placeholder internal placeholder;

    function setUp() public {
        placeholder = new Placeholder();
    }

    function test_ArcChainId() public view {
        assertEq(placeholder.ARC_CHAIN_ID(), 5042002);
    }
}
