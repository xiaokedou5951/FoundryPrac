// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/NFTMarket.sol";

// 模拟ERC20代币合约
contract MockERC20 is IExtendedERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply = 1000000 * 10**18;
    
    constructor() {
        _balances[msg.sender] = totalSupply;
    }
    
    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }
    
    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[recipient] += amount;
        return true;
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        require(_allowances[sender][msg.sender] >= amount, "ERC20: insufficient allowance");
        _allowances[sender][msg.sender] -= amount;
        _balances[sender] -= amount;
        _balances[recipient] += amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }
    
    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }
    
    function transferWithCallback(address _to, uint256 _value) external override returns (bool) {
        _balances[msg.sender] -= _value;
        _balances[_to] += _value;
        ITokenReceiver(_to).tokensReceived(msg.sender, _value, "");
        return true;
    }
    
    function transferWithCallbackAndData(address _to, uint256 _value, bytes calldata _data) external override returns (bool) {
        _balances[msg.sender] -= _value;
        _balances[_to] += _value;
        ITokenReceiver(_to).tokensReceived(msg.sender, _value, _data);
        return true;
    }
}

// 模拟ERC721代币合约
contract MockERC721 is IERC721 {
    mapping(uint256 => address) private _owners;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => address) private _tokenApprovals;
    
    function mint(address to, uint256 tokenId) external {
        _owners[tokenId] = to;
    }
    
    function ownerOf(uint256 tokenId) external view override returns (address) {
        require(_owners[tokenId] != address(0), "ERC721: owner query for nonexistent token");
        return _owners[tokenId];
    }
    
    function transferFrom(address /*from*/, address to, uint256 tokenId) external override {
        require(_isApprovedOrOwner(msg.sender, tokenId), "ERC721: transfer caller is not owner nor approved");
        _owners[tokenId] = to;
    }
    
    function safeTransferFrom(address /*from*/, address to, uint256 tokenId) external override {
        require(_isApprovedOrOwner(msg.sender, tokenId), "ERC721: transfer caller is not owner nor approved");
        _owners[tokenId] = to;
    }
    
    function approve(address to, uint256 tokenId) external {
        address owner = _owners[tokenId];
        require(msg.sender == owner || _operatorApprovals[owner][msg.sender], "ERC721: approve caller is not owner nor approved for all");
        _tokenApprovals[tokenId] = to;
    }
    
    function getApproved(uint256 tokenId) external view override returns (address) {
        return _tokenApprovals[tokenId];
    }
    
    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }
    
    function isApprovedForAll(address owner, address operator) external view override returns (bool) {
        return _operatorApprovals[owner][operator];
    }
    
    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address owner = _owners[tokenId];
        return (spender == owner || 
                _operatorApprovals[owner][spender] || 
                _tokenApprovals[tokenId] == spender);
    }
}

contract NFTMarketTest is Test {
    NFTMarket public market;
    MockERC20 public paymentToken;
    MockERC721 public nftContract;
    
    address public seller = address(1);
    address public buyer = address(2);
    address public operator = address(3);
    
    uint256 public tokenId = 1;
    uint256 public price = 100 * 10**18; // 100 tokens
    
    function setUp() public {
        // 部署模拟代币合约
        paymentToken = new MockERC20();
        nftContract = new MockERC721();
        
        // 部署NFT市场合约
        market = new NFTMarket(address(paymentToken));
        
        // 为测试账户铸造NFT和代币
        nftContract.mint(seller, tokenId);
        paymentToken.mint(buyer, 1000 * 10**18); // 1000 tokens
        
        // 设置测试账户
        vm.label(seller, "Seller");
        vm.label(buyer, "Buyer");
        vm.label(operator, "Operator");
        vm.label(address(market), "NFTMarket");
    }
    
    // 测试上架NFT成功的情况
    function testListNFTSuccess() public {
        // 切换到卖家账户
        vm.startPrank(seller);
        
        // 预期会发出NFTListed事件
        vm.expectEmit(true, true, true, true);
        emit NFTMarket.NFTListed(0, seller, address(nftContract), tokenId, price);
        
        // 上架NFT
        uint256 listingId = market.list(address(nftContract), tokenId, price);
        
        // 验证上架信息
        (address listedSeller, address listedNftContract, uint256 listedTokenId, uint256 listedPrice, bool isActive) = market.listings(listingId);
        assertEq(listedSeller, seller, "Seller address mismatch");
        assertEq(listedNftContract, address(nftContract), "NFT contract address mismatch");
        assertEq(listedTokenId, tokenId, "Token ID mismatch");
        assertEq(listedPrice, price, "Price mismatch");
        assertTrue(isActive, "Listing should be active");
        
        // 验证listingId
        assertEq(listingId, 0, "First listing ID should be 0");
        assertEq(market.nextListingId(), 1, "Next listing ID should be incremented");
        
        vm.stopPrank();
    }
    
    // 测试非所有者上架NFT失败的情况
    function testListNFTFailureNotOwner() public {
        // 切换到非所有者账户
        vm.startPrank(buyer);
        
        // 预期会失败，并显示特定错误信息
        vm.expectRevert("NFTMarket: caller is not owner nor approved");
        market.list(address(nftContract), tokenId, price);
        
        vm.stopPrank();
    }
    
    // 测试价格为零上架NFT失败的情况
    function testListNFTFailureZeroPrice() public {
        // 切换到卖家账户
        vm.startPrank(seller);
        
        // 预期会失败，并显示特定错误信息
        vm.expectRevert("NFTMarket: price must be greater than zero");
        market.list(address(nftContract), tokenId, 0);
        
        vm.stopPrank();
    }
    
    // 测试NFT合约地址为零上架NFT失败的情况
    function testListNFTFailureZeroAddress() public {
        // 切换到卖家账户
        vm.startPrank(seller);
        
        // 预期会失败，并显示特定错误信息
        vm.expectRevert("NFTMarket: NFT contract address cannot be zero");
        market.list(address(0), tokenId, price);
        
        vm.stopPrank();
    }
    
    // 测试授权操作员上架NFT成功的情况
    function testListNFTByApprovedOperator() public {
        // 卖家授权操作员
        vm.startPrank(seller);
        nftContract.setApprovalForAll(operator, true);
        vm.stopPrank();
        
        // 切换到操作员账户
        vm.startPrank(operator);
        
        // 预期会发出NFTListed事件
        vm.expectEmit(true, true, true, true);
        emit NFTMarket.NFTListed(0, seller, address(nftContract), tokenId, price);
        
        // 操作员上架NFT
        uint256 listingId = market.list(address(nftContract), tokenId, price);
        
        // 验证上架信息
        (address listedSeller, , , , ) = market.listings(listingId);
        assertEq(listedSeller, seller, "Seller should be the NFT owner, not the operator");
        
        vm.stopPrank();
    }
    
    // 测试单个代币授权上架NFT成功的情况
    function testListNFTByApprovedForToken() public {
        // 卖家授权特定代币
        vm.startPrank(seller);
        nftContract.approve(operator, tokenId);
        vm.stopPrank();
        
        // 切换到被授权账户
        vm.startPrank(operator);
        
        // 预期会发出NFTListed事件
        vm.expectEmit(true, true, true, true);
        emit NFTMarket.NFTListed(0, seller, address(nftContract), tokenId, price);
        
        // 被授权账户上架NFT
        uint256 listingId = market.list(address(nftContract), tokenId, price);
        
        // 验证上架信息
        (address listedSeller, , , , ) = market.listings(listingId);
        assertEq(listedSeller, seller, "Seller should be the NFT owner, not the approved address");
        
        vm.stopPrank();
    }
    
    // 测试购买NFT成功的情况
    function testBuyNFTSuccess() public {
        // 先上架NFT
        vm.startPrank(seller);
        uint256 listingId = market.list(address(nftContract), tokenId, price);
        
        // 卖家需要授权市场合约转移NFT
        nftContract.approve(address(market), tokenId);
        vm.stopPrank();
        
        // 买家授权市场合约转移代币
        vm.startPrank(buyer);
        paymentToken.approve(address(market), price);
        
        // 预期会发出NFTSold事件
        vm.expectEmit(true, true, true, true);
        emit NFTMarket.NFTSold(listingId, buyer, seller, address(nftContract), tokenId, price);
        
        // 购买NFT
        market.buyNFT(listingId);
        
        // 验证NFT所有权已转移
        assertEq(nftContract.ownerOf(tokenId), buyer, "NFT ownership should be transferred to buyer");
        
        // 验证代币已转移
        assertEq(paymentToken.balanceOf(seller), price, "Payment should be transferred to seller");
        
        // 验证上架信息已更新为非活跃
        (, , , , bool isActive) = market.listings(listingId);
        assertFalse(isActive, "Listing should be inactive after purchase");
        
        vm.stopPrank();
    }
    
    // 测试自己购买自己的NFT
    function testBuySelfNFT() public {
        // 给卖家铸造代币用于支付
        paymentToken.mint(seller, 1000 * 10**18);
        
        // 卖家上架NFT
        vm.startPrank(seller);
        uint256 listingId = market.list(address(nftContract), tokenId, price);
        
        // 卖家授权市场合约转移NFT和代币
        nftContract.approve(address(market), tokenId);
        paymentToken.approve(address(market), price);
        
        // 预期会发出NFTSold事件
        vm.expectEmit(true, true, true, true);
        emit NFTMarket.NFTSold(listingId, seller, seller, address(nftContract), tokenId, price);
        
        // 卖家购买自己的NFT
        market.buyNFT(listingId);
        
        // 验证NFT所有权仍然是卖家
        assertEq(nftContract.ownerOf(tokenId), seller, "NFT ownership should remain with seller");
        
        // 验证上架信息已更新为非活跃
        (, , , , bool isActive) = market.listings(listingId);
        assertFalse(isActive, "Listing should be inactive after purchase");
        
        vm.stopPrank();
    }
    
    // 测试NFT被重复购买的情况
    function testBuyNFTTwice() public {
        // 先上架NFT
        vm.startPrank(seller);
        uint256 listingId = market.list(address(nftContract), tokenId, price);
        
        // 卖家授权市场合约转移NFT
        nftContract.approve(address(market), tokenId);
        vm.stopPrank();
        
        // 买家授权市场合约转移代币并购买NFT
        vm.startPrank(buyer);
        paymentToken.approve(address(market), price);
        market.buyNFT(listingId);
        
        // 尝试再次购买同一个NFT，预期会失败
        vm.expectRevert("NFTMarket: listing is not active");
        market.buyNFT(listingId);
        
        vm.stopPrank();
    }
    
    // 测试支付Token过少的情况
    function testBuyNFTInsufficientBalance() public {
        // 先上架NFT
        vm.startPrank(seller);
        uint256 listingId = market.list(address(nftContract), tokenId, price);
        vm.stopPrank();
        
        // 创建一个余额不足的新买家
        address poorBuyer = address(4);
        vm.label(poorBuyer, "Poor Buyer");
        paymentToken.mint(poorBuyer, price / 2); // 只有一半的价格
        
        // 切换到余额不足的买家
        vm.startPrank(poorBuyer);
        paymentToken.approve(address(market), price);
        
        // 尝试购买NFT，预期会失败
        vm.expectRevert("NFTMarket: insufficient token balance");
        market.buyNFT(listingId);
        
        vm.stopPrank();
    }
    
    // 测试使用回调方式购买NFT并支付过多Token的情况
    function testBuyNFTWithCallbackIncorrectAmount() public {
        // 先上架NFT
        vm.startPrank(seller);
        uint256 listingId = market.list(address(nftContract), tokenId, price);
        vm.stopPrank();
        
        // 准备一个错误的价格（过多）
        uint256 incorrectPrice = price * 2;
        
        // 买家一步完成购买，无需提前调用 approve
        vm.startPrank(buyer);
        
        // 编码listingId作为附加数据
        bytes memory data = abi.encode(listingId);
        
        // 直接调用transferWithCallbackAndData，模拟支付过多的代币
        vm.expectRevert("NFTMarket: incorrect payment amount");
        paymentToken.transferWithCallbackAndData(address(market), incorrectPrice, data);
        
        vm.stopPrank();
    }
    
    // 测试使用回调方式成功购买NFT
    function testBuyNFTWithCallbackSuccess() public {
        // 先上架NFT
        vm.startPrank(seller);
        uint256 listingId = market.list(address(nftContract), tokenId, price);
        
        // 卖家授权市场合约转移NFT
        nftContract.approve(address(market), tokenId);
        vm.stopPrank();
        
        // 买家一步完成购买，无需提前调用 approve
        vm.startPrank(buyer);
        
        // 编码listingId作为附加数据
        bytes memory data = abi.encode(listingId);
        
        // 预期会发出NFTSold事件
        vm.expectEmit(true, true, true, true);
        emit NFTMarket.NFTSold(listingId, buyer, seller, address(nftContract), tokenId, price);
        
        // 直接调用transferWithCallbackAndData，而不是使用buyNFTWithCallback
        paymentToken.transferWithCallbackAndData(address(market), price, data);
        
        // 验证NFT所有权已转移
        assertEq(nftContract.ownerOf(tokenId), buyer, "NFT ownership should be transferred to buyer");
        
        // 验证代币已转移
        assertEq(paymentToken.balanceOf(seller), price, "Payment should be transferred to seller");
        
        // 验证上架信息已更新为非活跃
        (, , , , bool isActive) = market.listings(listingId);
        assertFalse(isActive, "Listing should be inactive after purchase");
        
        vm.stopPrank();
    }
    
    // 模糊测试：测试随机价格上架NFT并随机地址购买NFT
    function testFuzz_ListAndBuyNFT(uint256 fuzzPrice, address fuzzBuyer) public {
        // 限制价格范围在 0.01-10000 Token之间（考虑到18位小数）
        uint256 listingPrice = bound(fuzzPrice, 10**16, 10000 * 10**18);
        
        // 确保买家地址有效（不为零地址，不是卖家，不是市场合约）
        vm.assume(fuzzBuyer != address(0));
        vm.assume(fuzzBuyer != seller);
        vm.assume(fuzzBuyer != address(market));
        vm.assume(fuzzBuyer != address(this));
        
        // 为买家铸造足够的代币
        paymentToken.mint(fuzzBuyer, listingPrice * 2); // 铸造两倍价格的代币，确保足够
        
        // 卖家上架NFT
        vm.startPrank(seller);
        uint256 listingId = market.list(address(nftContract), tokenId, listingPrice);
        
        // 卖家授权市场合约转移NFT
        nftContract.approve(address(market), tokenId);
        vm.stopPrank();
        
        // 切换到随机买家账户
        vm.startPrank(fuzzBuyer);
        
        // 买家授权市场合约转移代币
        paymentToken.approve(address(market), listingPrice);
        
        // 预期会发出NFTSold事件
        vm.expectEmit(true, true, true, true);
        emit NFTMarket.NFTSold(listingId, fuzzBuyer, seller, address(nftContract), tokenId, listingPrice);
        
        // 购买NFT
        market.buyNFT(listingId);
        
        // 验证NFT所有权已转移
        assertEq(nftContract.ownerOf(tokenId), fuzzBuyer, "NFT ownership should be transferred to buyer");
        
        // 验证代币已转移
        assertEq(paymentToken.balanceOf(seller), listingPrice, "Payment should be transferred to seller");
        
        // 验证上架信息已更新为非活跃
        (, , , , bool isActive) = market.listings(listingId);
        assertFalse(isActive, "Listing should be inactive after purchase");
        
        vm.stopPrank();
    }
    
    // 不可变测试：测试无论如何买卖，NFTMarket合约中都不可能有Token持仓
    function testInvariant_NoTokenBalance() public {
        // 设置初始场景：上架NFT
        vm.startPrank(seller);
        uint256 listingId = market.list(address(nftContract), tokenId, price);
        nftContract.approve(address(market), tokenId);
        vm.stopPrank();
        
        // 买家购买NFT
        vm.startPrank(buyer);
        paymentToken.approve(address(market), price);
        market.buyNFT(listingId);
        vm.stopPrank();
        
        // 验证市场合约中没有Token持仓
        assertEq(paymentToken.balanceOf(address(market)), 0, "Market contract should not hold any tokens");
        
        // 再次上架NFT（现在由买家上架）
        vm.startPrank(buyer);
        uint256 newListingId = market.list(address(nftContract), tokenId, price * 2); // 双倍价格
        nftContract.approve(address(market), tokenId);
        vm.stopPrank();
        
        // 卖家（原来的）购买NFT
        paymentToken.mint(seller, price * 2); // 为卖家铸造足够的代币
        vm.startPrank(seller);
        paymentToken.approve(address(market), price * 2);
        market.buyNFT(newListingId);
        vm.stopPrank();
        
        // 验证市场合约中仍然没有Token持仓
        assertEq(paymentToken.balanceOf(address(market)), 0, "Market contract should not hold any tokens");
        
        // 测试使用回调方式购买
        vm.startPrank(seller);
        uint256 callbackListingId = market.list(address(nftContract), tokenId, price);
        nftContract.approve(address(market), tokenId);
        vm.stopPrank();
        
        // 买家使用回调方式购买NFT
        vm.startPrank(buyer);
        bytes memory data = abi.encode(callbackListingId);
        paymentToken.transferWithCallbackAndData(address(market), price, data);
        vm.stopPrank();
        
        // 验证市场合约中仍然没有Token持仓
        assertEq(paymentToken.balanceOf(address(market)), 0, "Market contract should not hold any tokens after callback purchase");
    }
}