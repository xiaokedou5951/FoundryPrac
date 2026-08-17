// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.5.16;

import "@uniswap/v2-core/contracts/UniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/UniswapV2Pair.sol";

/**
 * @title V2Core
 * @dev 编译锚点：官方 v2-core 为 Solidity 0.5.16，与 0.8.x 合约不能同文件互相 import。
 *      本文件使 v2-core 以独立编译组件构建，生成 out/ 下的 artifact，
 *      供测试通过 vm.deployCode("UniswapV2Factory.sol", ...) 跨版本部署。
 *      注意：0.8.x 合约禁止 import 本文件。
 */
contract V2Core {}
