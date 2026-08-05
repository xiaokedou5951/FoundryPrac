// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC721_Upgrade_V1} from "../../src/upgrade-nft/ERC721_Upgrade_V1.sol";
import {ERC721_Upgrade_V2} from "../../src/upgrade-nft/ERC721_Upgrade_V2.sol";

contract ERC721UpgradeTest is Test {
    ERC721_Upgrade_V1 public v1Impl;
    ERC721_Upgrade_V2 public v2Impl;
    ERC1967Proxy public proxy;
    ERC721_Upgrade_V1 public nftV1;
    ERC721_Upgrade_V2 public nftV2;
    
    address public owner = address(this);
    address public user = address(0x1234);
    
    function setUp() public {
        // 部署 V1 实现合约
        v1Impl = new ERC721_Upgrade_V1();
        
        // 部署代理合约，初始化为 V1
        bytes memory initData = abi.encodeWithSelector(
            ERC721_Upgrade_V1.initialize.selector,
            "UpgradeNFT",
            "UNFT"
        );
        
        proxy = new ERC1967Proxy(address(v1Impl), initData);
        nftV1 = ERC721_Upgrade_V1(address(proxy));
        nftV2 = ERC721_Upgrade_V2(address(proxy));
    }
    
    function test_Initialization() public view {
        assertEq(nftV1.name(), "UpgradeNFT");
        assertEq(nftV1.symbol(), "UNFT");
        assertEq(nftV1.owner(), owner);
    }
    
    function test_Mint() public {
        nftV1.mint(user, 1);
        assertEq(nftV1.ownerOf(1), user);
        assertEq(nftV1.balanceOf(user), 1);
    }
    
    function test_MintOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        nftV1.mint(user, 1);
    }
    
    function test_UpgradeToV2() public {
        // 部署 V2 实现合约
        v2Impl = new ERC721_Upgrade_V2();
        
        // 升级到 V2
        bytes memory upgradeData = abi.encodeWithSelector(
            ERC721_Upgrade_V2.initializeV2.selector
        );
        
        nftV1.upgradeToAndCall(address(v2Impl), upgradeData);
        
        // 验证版本
        assertEq(nftV2.getVersion(), 2);
    }
    
    function test_StatePreservationAfterUpgrade() public {
        // V1 状态下铸造 NFT
        nftV1.mint(user, 1);
        assertEq(nftV1.ownerOf(1), user);
        
        // 升级到 V2
        v2Impl = new ERC721_Upgrade_V2();
        bytes memory upgradeData = abi.encodeWithSelector(
            ERC721_Upgrade_V2.initializeV2.selector
        );
        nftV1.upgradeToAndCall(address(v2Impl), upgradeData);
        
        // 验证状态保留
        assertEq(nftV2.ownerOf(1), user);
        assertEq(nftV2.balanceOf(user), 1);
        assertEq(nftV2.name(), "UpgradeNFT");
        assertEq(nftV2.symbol(), "UNFT");
    }
    
    function test_V2Functionality() public {
        // 升级到 V2
        v2Impl = new ERC721_Upgrade_V2();
        bytes memory upgradeData = abi.encodeWithSelector(
            ERC721_Upgrade_V2.initializeV2.selector
        );
        nftV1.upgradeToAndCall(address(v2Impl), upgradeData);
        
        // 测试 V2 功能
        nftV2.mint(user, 2);
        assertEq(nftV2.ownerOf(2), user);
        assertEq(nftV2.getVersion(), 2);
    }
    
    function test_UpgradeOnlyOwner() public {
        v2Impl = new ERC721_Upgrade_V2();
        
        vm.prank(user);
        vm.expectRevert();
        nftV1.upgradeToAndCall(address(v2Impl), "");
    }
}
