// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {console} from "forge-std/Console.sol";

contract Counter {
    uint256 public number;

    function setNumber(uint256 newNumber) public {
        number = newNumber;
        console.log("Number set to", number);
    }

    function increment() public {
        number++;
        console.log("Number incremented to", number);
    }
}
