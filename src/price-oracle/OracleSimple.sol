// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "./IUniswapV2Pair.sol";
import "./IUniswapV2Factory.sol";


/**
 * @title FixedPoint
 * @dev 用于实现定点数学运算的库
 */
library FixedPoint {
    // 带有 112 位小数位的无符号定点数
    struct uq112x112 {
        uint224 _x;
    }

    // 带有 224 位小数位的无符号定点数
    struct uq144x112 {
        uint256 _x;
    }

    uint8 private constant RESOLUTION = 112;
    uint private constant Q112 = 2**112;
    uint private constant Q224 = 2**224;

    // 将 uint112 编码为 uq112x112
    function encode(uint112 x) internal pure returns (uq112x112 memory) {
        uq112x112 memory result;
        result._x = uint224(uint(x) * Q112);
        return result;
    }

    // 将 uint 乘以 Q112 编码为 uq112x112
    function encodeUint(uint x) internal pure returns (uq112x112 memory) {
        require(x <= type(uint224).max / Q112, "FixedPoint: OVERFLOW");
        uq112x112 memory result;
        result._x = uint224(x * Q112);
        return result;
    }

    // 将 uq112x112 解码为 uint
    function decode(uq112x112 memory self) internal pure returns (uint112) {
        return uint112(self._x / Q112);
    }

    // 将 uq112x112 乘以 uint，解码结果为 uint
    function mul(uq112x112 memory self, uint y) internal pure returns (uq144x112 memory) {
        uint256 z = self._x * y;
        return uq144x112(z);
    }

    // 将 uq144x112 解码为 uint
    function decode144(uq144x112 memory self) internal pure returns (uint) {
        return self._x / Q112;
    }

    // 将 uq112x112 除以 uq112x112，结果为 uq112x112
    function div(uq112x112 memory self, uq112x112 memory other) internal pure returns (uq112x112 memory) {
        // 存储中间结果
        uint256 value = uint256(self._x) * Q112;
        value = value / other._x;
        require(value <= type(uint224).max, "FixedPoint: DIV_OVERFLOW");
        
        uq112x112 memory result;
        result._x = uint224(value);
        return result;
    }
}

/**
 * @title UniswapV2OracleLibrary
 * @dev Uniswap V2 Oracle 辅助库
 */
library UniswapV2OracleLibrary {
    // 获取当前累计价格
    function currentCumulativePrices(address pair) internal view returns (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) {
        blockTimestamp = uint32(block.timestamp % 2**32);
        IUniswapV2Pair uniswapPair = IUniswapV2Pair(pair);
        price0Cumulative = uniswapPair.price0CumulativeLast();
        price1Cumulative = uniswapPair.price1CumulativeLast();

        // 如果时间戳不同，则使用当前价格计算
        (uint112 reserve0, uint112 reserve1, uint32 timestampLast) = uniswapPair.getReserves();
        if (timestampLast != blockTimestamp) {
            // 从上次更新到现在经过的秒数
            uint32 timeElapsed = blockTimestamp - timestampLast;
            // 当 reserve0 或 reserve1 为 0 时，累计价格不变
            if (reserve0 != 0 && reserve1 != 0) {
                // 计算 token0 相对于 token1 的价格
                uint224 price0 = uint224((uint256(reserve1) * 2**112) / reserve0);
                uint224 price1 = uint224((uint256(reserve0) * 2**112) / reserve1);
                price0Cumulative += uint256(price0) * timeElapsed;
                price1Cumulative += uint256(price1) * timeElapsed;
            }
        }
    }
}

/**
 * @title UniswapV2Library
 * @dev Uniswap V2 辅助库
 */
library UniswapV2Library {
    // 计算 pair 地址
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint160(uint(keccak256(abi.encodePacked(
            hex'ff',
            factory,
            keccak256(abi.encodePacked(token0, token1)),
            hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
        )))));
    }

    // 按地址排序 token
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }
}

/**
 * @title OracleSimple
 * @dev 用于获取 Meme_FactoryV2 代币的 TWAP 价格的预言机
 */
contract OracleSimple {
    using FixedPoint for *;

    uint public constant PERIOD = 24 hours; // 更新周期

    IUniswapV2Pair public immutable pair; // Uniswap V2 交易对
    address public immutable token0; // 交易对中的第一个代币
    address public immutable token1; // 交易对中的第二个代币
    address public immutable factory; // Uniswap V2 工厂合约
    address public immutable memeToken; // Meme 代币地址
    address public immutable weth; // WETH 地址

    uint public price0CumulativeLast; // token0 相对于 token1 的累计价格
    uint public price1CumulativeLast; // token1 相对于 token0 的累计价格
    uint32 public blockTimestampLast; // 上次更新的区块时间戳

    FixedPoint.uq112x112 public price0Average; // token0 相对于 token1 的平均价格
    FixedPoint.uq112x112 public price1Average; // token1 相对于 token0 的平均价格

    /**
     * @dev 构造函数
     * @param _factory Uniswap V2 工厂合约地址
     * @param _memeToken Meme 代币地址
     * @param _weth WETH 地址
     */
    constructor(address _factory, address _memeToken, address _weth) {
        factory = _factory;
        memeToken = _memeToken;
        weth = _weth;

        // 直接使用预期的交易对地址而不计算
        // 在测试环境中，我们使用 getPair 获取已创建的交易对
        IUniswapV2Factory factoryContract = IUniswapV2Factory(_factory);
        address pairAddress = factoryContract.getPair(_memeToken, _weth);
        require(pairAddress != address(0), "OracleSimple: PAIR_NOT_EXIST");
        
        IUniswapV2Pair _pair = IUniswapV2Pair(pairAddress);
        pair = _pair;
        
        // 确定 token0 和 token1
        token0 = _pair.token0();
        token1 = _pair.token1();
        
        // 获取当前累计价格
        price0CumulativeLast = _pair.price0CumulativeLast();
        price1CumulativeLast = _pair.price1CumulativeLast();
        
        // 获取当前储备量和时间戳
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, blockTimestampLast) = _pair.getReserves();
        
        // 确保交易对中有流动性
        require(reserve0 != 0 && reserve1 != 0, 'OracleSimple: NO_RESERVES');
    }

    /**
     * @dev 更新 TWAP 价格
     * 需要确保至少经过了一个完整的周期
     */
    function update() external {
        // 获取当前累计价格和时间戳
        (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) =
            UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
        
        // 计算经过的时间（溢出是预期的）
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        
        // 确保至少经过了一个完整的周期
        require(timeElapsed >= PERIOD, 'OracleSimple: PERIOD_NOT_ELAPSED');
        
        // 计算平均价格
        // 溢出是预期的，强制转换永远不会截断
        price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
        price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));
        
        // 更新状态
        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;
    }

    /**
     * @dev 获取代币价格
     * @param token 要查询价格的代币地址
     * @param amountIn 输入金额
     * @return amountOut 等值的输出金额
     * 注意：在首次成功调用 update 之前，此函数始终返回 0
     */
    function consult(address token, uint amountIn) public view returns (uint amountOut) {
        if (token == token0) {
            amountOut = price0Average.mul(amountIn).decode144();
        } else {
            require(token == token1, 'OracleSimple: INVALID_TOKEN');
            amountOut = price1Average.mul(amountIn).decode144();
        }
    }

    /**
     * @dev 获取 Meme 代币对 ETH 的价格
     * @param amountIn Meme 代币输入金额
     * @return 等值的 ETH 金额
     */
    function getMemePrice(uint amountIn) external view returns (uint) {
        if (memeToken == token0) {
            return consult(token0, amountIn);
        } else {
            return consult(token1, amountIn);
        }
    }

    /**
     * @dev 获取 ETH 对 Meme 代币的价格
     * @param ethAmount ETH 输入金额
     * @return 等值的 Meme 代币金额
     */
    function getEthPrice(uint ethAmount) external view returns (uint) {
        if (weth == token0) {
            return consult(token0, ethAmount);
        } else {
            return consult(token1, ethAmount);
        }
    }

    /**
     * @dev 手动设置 TWAP 价格（仅用于测试）
     * @param _price0Average token0 相对于 token1 的平均价格
     * @param _price1Average token1 相对于 token0 的平均价格
     */
    function setPrice(uint224 _price0Average, uint224 _price1Average) external {
        // 此函数仅用于测试目的
        price0Average = FixedPoint.uq112x112(_price0Average);
        price1Average = FixedPoint.uq112x112(_price1Average);
    }
}