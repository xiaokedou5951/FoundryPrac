// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.5.16;

import "@uniswap/v2-core/contracts/UniswapV2Factory.sol";

/**
 * @title V2CoreAnchor 编译锚点
 * @dev 官方 v2-core 为 Solidity 0.5.16，与 0.8.x 合约不能同文件互相 import。
 *      本文件让 forge 以 solc 0.5.16 编译 UniswapV2Factory（含 UniswapV2Pair），
 *      生成 out/ 下的 artifact，供测试用 vm.deployCode("UniswapV2Factory.sol", ...) 跨版本部署。
 *      注意：0.8.x 合约禁止 import 本文件。
 */
contract V2CoreAnchor {}
