// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MemeFactory} from "../../src/MemeFactory.sol";
import {MemeToken} from "../../src/MemeToken.sol";

// 测试命令：forge test test/meme/MemeFactory.t.sol -vvv
contract MemeFactoryTest is Test {
    MemeFactory public factory;
    address public owner;
    address public issuer;
    address public alice;
    address public bob;

    uint256 constant TOTAL_SUPPLY = 10000 * 1e18;
    uint256 constant PER_MINT = 100 * 1e18;
    uint256 constant PRICE = 0.01 ether;

    function setUp() public {
        owner = address(this);
        issuer = makeAddr("issuer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(issuer, 1 ether);

        factory = new MemeFactory();
    }

    // 测试合约需要能接收 ETH（作为项目方 owner）
    receive() external payable {}

    // ========== deployMeme 测试 ==========

    function test_DeployMeme() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);

        MemeToken token = MemeToken(tokenAddr);

        assertEq(token.symbol(), "DOGE");
        assertEq(token.name(), "Meme Token");
        assertEq(token.maxSupply(), TOTAL_SUPPLY);
        assertEq(token.perMint(), PER_MINT);
        assertEq(token.mintPrice(), PRICE);
        assertEq(token.issuer(), issuer);
        assertEq(token.factory(), address(factory));
        assertTrue(factory.isMemeToken(tokenAddr));
        assertEq(token.totalSupply(), 0);
    }

    function test_DeployMeme_RevertEmptySymbol() public {
        vm.prank(issuer);
        vm.expectRevert("Empty symbol");
        factory.deployMeme("", TOTAL_SUPPLY, PER_MINT, PRICE);
    }

    function test_DeployMeme_RevertZeroTotalSupply() public {
        vm.prank(issuer);
        vm.expectRevert("Invalid params");
        factory.deployMeme("DOGE", 0, PER_MINT, PRICE);
    }

    function test_DeployMeme_RevertZeroPerMint() public {
        vm.prank(issuer);
        vm.expectRevert("Invalid params");
        factory.deployMeme("DOGE", TOTAL_SUPPLY, 0, PRICE);
    }

    function test_DeployMeme_RevertZeroPrice() public {
        vm.prank(issuer);
        vm.expectRevert("Invalid params");
        factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, 0);
    }

    function test_DeployMeme_RevertNotDivisible() public {
        vm.prank(issuer);
        vm.expectRevert("totalSupply must be divisible by perMint");
        factory.deployMeme("DOGE", 100 * 1e18, 7 * 1e18, PRICE);
    }

    // ========== mintMeme 费用分配测试 ==========

    function test_MintMeme_FeeDistribution() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);

        uint256 ownerBalanceBefore = owner.balance;
        uint256 issuerBalanceBefore = issuer.balance;

        vm.prank(alice);
        factory.mintMeme{value: PRICE}(tokenAddr);

        // 1% 给项目方
        uint256 projectFee = PRICE / 100;
        // 99% 给发行者
        uint256 issuerFee = PRICE - projectFee;

        assertEq(owner.balance - ownerBalanceBefore, projectFee);
        assertEq(issuer.balance - issuerBalanceBefore, issuerFee);

        // 验证比例
        assertEq(projectFee * 100, PRICE); // 1%
        assertEq(issuerFee, PRICE - projectFee); // 99%
    }

    function test_MintMeme_FeeDistribution_MultipleMints() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);

        uint256 ownerBalanceBefore = owner.balance;
        uint256 issuerBalanceBefore = issuer.balance;

        uint256 mintCount = 5;
        for (uint256 i = 0; i < mintCount; i++) {
            vm.prank(alice);
            factory.mintMeme{value: PRICE}(tokenAddr);
        }

        uint256 projectFee = (PRICE * mintCount) / 100;
        uint256 issuerFee = (PRICE * mintCount) - projectFee;

        assertEq(owner.balance - ownerBalanceBefore, projectFee);
        assertEq(issuer.balance - issuerBalanceBefore, issuerFee);
    }

    // ========== 铸造数量与总量控制测试 ==========

    function test_MintMeme_CorrectAmountPerMint() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);
        MemeToken token = MemeToken(tokenAddr);

        vm.prank(alice);
        factory.mintMeme{value: PRICE}(tokenAddr);

        assertEq(token.balanceOf(alice), PER_MINT);
        assertEq(token.totalSupply(), PER_MINT);
    }

    function test_MintMeme_MultipleMintsAccumulate() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);
        MemeToken token = MemeToken(tokenAddr);

        uint256 mintCount = TOTAL_SUPPLY / PER_MINT;
        for (uint256 i = 0; i < mintCount; i++) {
            vm.prank(alice);
            factory.mintMeme{value: PRICE}(tokenAddr);
        }

        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(alice), TOTAL_SUPPLY);
    }

    function test_MintMeme_RevertExceedsMaxSupply() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);

        // 铸造直到 totalSupply 耗尽
        uint256 mintCount = TOTAL_SUPPLY / PER_MINT;
        for (uint256 i = 0; i < mintCount; i++) {
            vm.prank(alice);
            factory.mintMeme{value: PRICE}(tokenAddr);
        }

        // 再次铸造应 revert
        vm.prank(alice);
        vm.expectRevert("Exceeds max supply");
        factory.mintMeme{value: PRICE}(tokenAddr);
    }

    // ========== 安全性测试 ==========

    function test_MintMeme_RevertInsufficientPayment() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);

        vm.prank(alice);
        vm.expectRevert("Insufficient payment");
        factory.mintMeme{value: PRICE - 1}(tokenAddr);
    }

    function test_MintMeme_RevertInvalidToken() public {
        vm.prank(alice);
        vm.expectRevert("Not a valid Meme token");
        factory.mintMeme{value: PRICE}(address(0x1234));
    }

    function test_MintMeme_RefundExcessPayment() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);

        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        factory.mintMeme{value: PRICE + 0.5 ether}(tokenAddr);

        // alice 应该只花费了 PRICE
        assertEq(aliceBalanceBefore - alice.balance, PRICE);
    }

    function test_MintToken_RevertOnlyFactoryCanMint() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);
        MemeToken token = MemeToken(tokenAddr);

        // 直接调用 token.mint 应 revert
        vm.prank(alice);
        vm.expectRevert("Only factory can mint");
        token.mint(alice);
    }

    function test_MintToken_RevertDoubleInitialize() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);
        MemeToken token = MemeToken(tokenAddr);

        // 再次初始化应 revert
        vm.expectRevert("Already initialized");
        token.initialize("PEPE", TOTAL_SUPPLY, PER_MINT, PRICE, issuer, address(factory));
    }

    // ========== 事件测试 ==========

    function test_DeployMeme_Event() public {
        vm.prank(issuer);
        // 不检查 indexed tokenAddr（无法预知），只检查非 indexed 字段
        vm.expectEmit(false, true, false, true, address(factory));
        emit MemeFactory.MemeDeployed(address(0), issuer, "DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);
        factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);
    }

    function test_MintMeme_Event() public {
        vm.prank(issuer);
        address tokenAddr = factory.deployMeme("DOGE", TOTAL_SUPPLY, PER_MINT, PRICE);

        vm.expectEmit(address(factory));
        emit MemeFactory.MemeMinted(tokenAddr, alice, PER_MINT, PRICE);

        vm.prank(alice);
        factory.mintMeme{value: PRICE}(tokenAddr);
    }
}
