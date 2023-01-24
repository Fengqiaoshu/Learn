pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';
//工厂合约继承 IUniswapV2Factory
contract UniswapV2Factory is IUniswapV2Factory {
    // 收税地址
    address public feeTo;      
    // 收税控制地址
    address public feeToSetter;
    // 映射 地址=>(地址=>地址)
    mapping(address => mapping(address => address)) public getPair;
    // 数组 配对数组
    address[] public allPairs;
    // 事件 当配对被创建时
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    // 构造函数 创建收税控制地址
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }
    // 计算配对数组的长度
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }
    // 创建配对 tokenA tokenB 返回配对地址
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // 判定两个token不相同
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // 赋值 比大小确保 A大于B 如果tokenA 小于 tokeB 则 (tokenA, tokenB) 反之 (tokenB, tokenA)
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // 判定token0 不是空地址 因为上面已经判断了 tokenA和tokenB不相同这里只用判断一次就够
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // 判定 映射中不存在tokenA=>tokenB
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient\
        // 给bytecode变量赋值"UniswapV2Pair"合约的创建字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        // 将token0和token1打包后创建哈希
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        // 内联汇编
        assembly {
            //通过create2方法部署合约，
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        // 调用pair地址合约中的initialize 传值 token0 token1
        IUniswapV2Pair(pair).initialize(token0, token1);
        // 配对映射中 token0=>token1 = pair 
        getPair[token0][token1] = pair;
        // 配对映射中 token1=>token0 = pair 
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        // 把配对数组推入allPairs数组中
        allPairs.push(pair);
        // 写入事件 token0 token1 配对地址 所有配的长度
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
    // 修改收税地址
    function setFeeTo(address _feeTo) external {
        // 判定 feeToSetter才能修改
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }
    // 修改收税控制地址
    function setFeeToSetter(address _feeToSetter) external {
        // 判定 feeToSetter才能修改
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
