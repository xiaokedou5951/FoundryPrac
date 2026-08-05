// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC721_Upgrade_V1} from "../../src/upgrade-nft/ERC721_Upgrade_V1.sol";
import {ERC721_Upgrade_V2} from "../../src/upgrade-nft/ERC721_Upgrade_V2.sol";

contract DeployUpgradeNFT is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. 部署 V1 实现合约
        ERC721_Upgrade_V1 v1Impl = new ERC721_Upgrade_V1();
        console.log("V1 Implementation deployed at:", address(v1Impl));
        
        // 2. 部署 ERC1967Proxy，初始化为 V1
        bytes memory initData = abi.encodeWithSelector(
            ERC721_Upgrade_V1.initialize.selector,
            "UpgradeNFT",
            "UNFT"
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(v1Impl),
            initData
        );
        console.log("Proxy deployed at:", address(proxy));
        
        // 3. 通过代理调用 mint 测试 V1 功能
        ERC721_Upgrade_V1 nftV1 = ERC721_Upgrade_V1(address(proxy));
        nftV1.mint(deployer, 1);
        console.log("Minted token 1 to:", deployer);
        console.log("Owner of token 1:", nftV1.ownerOf(1));
        
        // 4. 部署 V2 实现合约
        ERC721_Upgrade_V2 v2Impl = new ERC721_Upgrade_V2();
        console.log("V2 Implementation deployed at:", address(v2Impl));
        
        // 5. 升级到 V2 并调用 initializeV2
        bytes memory upgradeData = abi.encodeWithSelector(
            ERC721_Upgrade_V2.initializeV2.selector
        );
        
        nftV1.upgradeToAndCall(address(v2Impl), upgradeData);
        console.log("Upgraded to V2");
        
        // 6. 验证 V2 功能
        ERC721_Upgrade_V2 nftV2 = ERC721_Upgrade_V2(address(proxy));
        console.log("Version:", nftV2.getVersion());
        console.log("Token 1 still owned by deployer:", nftV2.ownerOf(1));
        
        vm.stopBroadcast();
    }
}
