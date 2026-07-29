// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MemeToken is ERC20 {
    uint256 public maxSupply;
    uint256 public perMint;
    uint256 public mintPrice;
    address public issuer;
    address public factory;

    string private _tokenName;
    string private _tokenSymbol;

    constructor() ERC20("", "") {}

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function initialize(
        string memory symbol,
        uint256 _totalSupply,
        uint256 _perMint,
        uint256 _price,
        address _issuer,
        address _factory
    ) external {
        require(maxSupply == 0, "Already initialized");
        require(_perMint > 0 && _price > 0 && _issuer != address(0), "Invalid params");

        _tokenName = "Meme Token";
        _tokenSymbol = symbol;
        maxSupply = _totalSupply;
        perMint = _perMint;
        mintPrice = _price;
        issuer = _issuer;
        factory = _factory;
    }

    function mint(address to) external {
        require(msg.sender == factory, "Only factory can mint");
        require(ERC20.totalSupply() + perMint <= maxSupply, "Exceeds max supply");
        _mint(to, perMint);
    }
}
