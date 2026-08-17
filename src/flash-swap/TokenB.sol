// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title TokenB
 * @dev 本地测试网套利演示用 ERC20，初始供应量全部铸造给部署者
 */
contract TokenB is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 10 ** 18;

    constructor() ERC20("Token B", "TKB") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
