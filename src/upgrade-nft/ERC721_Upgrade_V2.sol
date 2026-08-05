// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC721_Upgrade_V1} from "./ERC721_Upgrade_V1.sol";

contract ERC721_Upgrade_V2 is ERC721_Upgrade_V1 {
    // 添加一个新的状态变量来标识 V2 版本
    uint256 public version;

    // 添加一个简单的函数来获取版本
    function getVersion() public view returns (uint256) {
        return version;
    }
    
    // 添加一个函数来初始化version，在升级后调用
    function initializeV2() public reinitializer(2) {
        version = 2;
    }
}