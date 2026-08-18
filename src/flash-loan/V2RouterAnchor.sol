// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.6.6;

import "@uniswap/v2-periphery/contracts/UniswapV2Router02.sol";

/**
 * @title V2RouterAnchor 编译锚点
 * @dev 官方 v2-periphery 为 Solidity 0.6.6，与 0.8.x 合约不能同文件互相 import。
 *      本文件让 forge 以 solc 0.6.6 编译 UniswapV2Router02，
 *      生成 out/ 下的 artifact，供测试用 vm.deployCode("UniswapV2Router02.sol", ...) 跨版本部署。
 *      注意：0.8.x 合约禁止 import 本文件。
 */
contract V2RouterAnchor {}
