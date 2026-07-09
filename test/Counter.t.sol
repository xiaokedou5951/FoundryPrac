// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Counter} from "../src/Counter.sol";

contract CounterTest is Test {
    Counter public counter;
    address public zhangsan;
    address public lisi;
    address public wangwu;
    address public zhaolu;

    function setUp() public {
        counter = new Counter();
        counter.setNumber(0);

        zhangsan = vm.addr(1);
        console.log("zhangsan:", zhangsan);
        lisi = makeAddr("lisi");
        console.log("lisi:", lisi);
        wangwu = address(0x01);
        console.log("wangwu:", wangwu);
        zhaolu = address(1);
        console.log("zhaolu:", zhaolu);
    }

    function test_Increment() public {
        counter.increment();
        assertEq(counter.number(), 1);
    }

    function testFuzz_SetNumber(uint256 x) public {
        counter.setNumber(x);
        assertEq(counter.number(), x);
    }
}
