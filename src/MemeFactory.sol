// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MemeToken} from "./MemeToken.sol";

contract MemeFactory {
    address public owner;
    address public implementation;
    mapping(address => bool) public isMemeToken;

    event MemeDeployed(address indexed tokenAddr, address indexed issuer, string symbol, uint256 totalSupply, uint256 perMint, uint256 price);
    event MemeMinted(address indexed tokenAddr, address indexed minter, uint256 amount, uint256 fee);

    constructor() {
        owner = msg.sender;
        implementation = address(new MemeToken());
    }

    function deployMeme(
        string calldata symbol,
        uint256 totalSupply,
        uint256 perMint,
        uint256 price
    ) external returns (address) {
        require(bytes(symbol).length > 0, "Empty symbol");
        require(totalSupply > 0 && perMint > 0 && price > 0, "Invalid params");
        require(totalSupply % perMint == 0, "totalSupply must be divisible by perMint");

        address proxy = Clones.clone(implementation);

        MemeToken(proxy).initialize(symbol, totalSupply, perMint, price, msg.sender, address(this));

        isMemeToken[proxy] = true;

        emit MemeDeployed(proxy, msg.sender, symbol, totalSupply, perMint, price);
        return proxy;
    }

    function mintMeme(address tokenAddr) external payable {
        require(isMemeToken[tokenAddr], "Not a valid Meme token");

        MemeToken token = MemeToken(tokenAddr);
        uint256 price = token.mintPrice();
        require(msg.value >= price, "Insufficient payment");

        token.mint(msg.sender);

        // 费用分配：1% 给项目方，99% 给 Meme 发行者
        uint256 projectFee = price / 100;
        uint256 issuerFee = price - projectFee;

        (bool ok1,) = owner.call{value: projectFee}("");
        require(ok1, "Project fee transfer failed");

        (bool ok2,) = token.issuer().call{value: issuerFee}("");
        require(ok2, "Issuer fee transfer failed");

        // 退还多余的 ETH
        if (msg.value > price) {
            (bool ok3,) = msg.sender.call{value: msg.value - price}("");
            require(ok3, "Refund failed");
        }

        emit MemeMinted(tokenAddr, msg.sender, token.perMint(), price);
    }
}
