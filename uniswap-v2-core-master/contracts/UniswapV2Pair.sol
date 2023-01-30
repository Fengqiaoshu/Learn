pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol'; 
// 配对合约 继承 IUniswapV2Pair UniswapV2ERC20
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    // 把两个的方法赋予到类型中
    using SafeMath  for uint;
    using UQ112x112 for uint224;
    // 最小流动性 = 10000
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // 赋值常量SELECTOR为'transfer(address,uint256)'字符串哈希值的前四位十六进制  
    // transfer(address,uint256) 是ERC-20合约中 transfer函数的函数签名
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
    // 工厂合约地址
    address public factory;
    // token0地址
    address public token0;
    // token1地址
    address public token1;
    // 储备量0  私有
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    // 储备量1 私有
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    // 更新储备量的最后时间戳
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves
    // 价格0最后的累计
    uint public price0CumulativeLast;
    // 价格1最后的累计
    uint public price1CumulativeLast;
    // 储备量0 * 储备量1，自最近一次流动性事件发生后
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event
    // 锁定变量，防止重入的锁
    uint private unlocked = 1;
    // 定义函数修饰符lock 防止重攻击
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }
    // 获取储备量
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        //返回储备量
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        // 时间戳
        _blockTimestampLast = blockTimestampLast;
    }
    // 私有安全发送
    function _safeTransfer(address token, address to, uint value) private {
        // 调用token合约地址的transfer方法 通过底层call方法 在不知道另一个合约接口的情况下可以调用
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // 确认操作必须返回true并且返回data的长度为0或者解码后为true
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }
    // 事件：铸造
    event Mint(address indexed sender, uint amount0, uint amount1);
    // 事件：销毁 
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    // 事件：交易 
    // sender 发送者地址  amount0In 输入金额0 amount1In 输入金额1
    // amount0Out 输出金额0 amount1Out 输出金额1  to to地址
    event Swap(
        address indexed sender, 
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    // 事件： 同步
    event Sync(uint112 reserve0, uint112 reserve1);
    // 构造函数调用者为工厂合约地址
    constructor() public {
        factory = msg.sender;
    }

    // 初始化方法，部署时由工厂合约调用一次 
    function initialize(address _token0, address _token1) external {
        // 确认调用者是不是工厂合约
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }
    
    // 更新储备，并在每个区块的第一次调用时更新价格累加器
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // 确认余额0和余额1小于等于最大的uint112
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // 区块时间戳，将时间戳转换成uint32
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        // 计算时间流逝
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // 如果时间流逝>0 并且 储备量0,1不等于0
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            // 价格0最后累计 += 储备量1 * 2**112 / 储备量0 * 时间流逝
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            // 价格1最后累计 += 储备量0 * 2**112 / 储备量1 * 时间流逝
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        // 余额0，放入储备量0,1
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        // 更新时间戳
        blockTimestampLast = blockTimestamp;
        // 触发事件
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    // 铸造收费
     function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        // 查询工厂合约的feeTo变量值
        address feeTo = IUniswapV2Factory(factory).feeTo();
        //如果feeTo不等于0地址，FeeOn等于true否则为false
        feeOn = feeTo != address(0);
        //定义k值
        uint _kLast = kLast; // gas savings
        //如果 feeOn 是true
        if (feeOn) {
            // 如果k值不等于0
            if (_kLast != 0) {
                //计算_reserve0*_reserve1的平方根
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                //计算k值得平方根
                uint rootKLast = Math.sqrt(_kLast);
                // 如果rootK > rootKLast
                if (rootK > rootKLast) {
                    //  分子 = erc20总量 * (rootK - rootKLast)
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    // 分母 = rooK * 5 + rootKLast
                    uint denominator = rootK.mul(5).add(rootKLast);
                    // 流动性 = 分子 / 分母
                    uint liquidity = numerator / denominator;
                    // 如果流动性 > 0 流动性将铸造给feeTo地址
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
            // 否则如果_kLast 不等于0
        } else if (_kLast != 0) {
            // k值 = 0
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 铸造方法
    function mint(address to) external lock returns (uint liquidity) {
        // 获取储备量
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 求当前合约在token0内的余额
        uint balance0 = IERC20(token0).balanceOf(address(this));
        // 求当前合约在token1内的余额
        uint balance1 = IERC20(token1).balanceOf(address(this));
        // amount0 = 余额0 - 储备量0
        uint amount0 = balance0.sub(_reserve0);
        // amount1 = 余额1 - 储备量1
        uint amount1 = balance1.sub(_reserve1);
        // 返回铸造费开关
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取totalSupply，必须在此定义，因为totalSupply可以在mintFee中更新
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        //如果totalSupply等于0
        if (_totalSupply == 0) {
            // 流动性 = （数量0 * 数量1）的平方根 - 最小流动性1000
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            // 在总量为0的初始状态，永久锁定最低流动性
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            // 流动性 = 最小值（amount0 * _totalSupply / _reserve0）和（amount1 *_totalSupply / _reserve1）
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        // 缺认流动性是否>0
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 铸造流动性给to地址
        _mint(to, liquidity);
        // 更新储备量池
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果feeOn开关为true，k值 = 储备量0 * 储备量1
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 触发铸造事件 
        emit Mint(msg.sender, amount0, amount1);
    }

    // 销毁
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        // 获取储备0 储备1
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 变量赋值
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        // 获取当前合约在token0合约内的余额
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        // 获取当前合约在token1合约内的余额
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        // 当前合约的balanceOf映射中获取当前合约自身流动性数量
        uint liquidity = balanceOf[address(this)];
        // 返回铸造费开关
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取totalSupply，必须在此处定义，因为totalSupply可以在mintFee中更新
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // amount0  = 流动性 * 余额0 /totalSupply 使用余额确保按比例分配
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        // amount1  = 流动性 * 余额1 /totalSupply 使用余额确保按比例分配
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        // amount0 amount1 都大于0
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        // 销毁当前合约的流动性
        _burn(address(this), liquidity);
        // 将amount0的数量的_token0发送给to地址
        _safeTransfer(_token0, to, amount0);
         // 将amount1的数量的_token1发送给to地址
        _safeTransfer(_token1, to, amount1);
        // 更新 balance0
        balance0 = IERC20(_token0).balanceOf(address(this));
        // 更新 balance1
        balance1 = IERC20(_token1).balanceOf(address(this));
        // 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果 铸造费开关为true k值 = 储备0 * 储备1
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 触发事件
        emit Burn(msg.sender, amount0, amount1, to);
    }
    // 交换方法
    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        // 确认amount0Out和amount1Out都大于0
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        // 获取 储备量0  储备量 1
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 确认输出数量0 1 < 储备量 0 1
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');
        // 初始化变量
        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        // 标记_token{0,1}的作用域 避免堆栈太深的错误
        address _token0 = token0;
        address _token1 = token1;
        // 确认to 地址不等于 _token0和token1
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        // 如果 输出数量0 > 0 安全发送 输出数量0 的token0 到to地址  
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        // 如果 输出数量1 > 0 安全发送 输出数量1 的token0 到to地址  
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        // 如果 data 的长度大于0 调用to地址的接口
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        // 余额0 1 = 当前合约在token 0 1 合约内的余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        // 如果 余额0> 储备0 - amount0Out 则 amount0In  = 余额0 -（储备0 -amount0Out） 否则 amount0In = 0
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        // 如果 余额1> 储备1 - amount1Out 则 amount1In  = 余额1 -（储备1 -amount1Out） 否则 amount1In = 0
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
       // 确认 输入数量0 || 1 大于 0
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        // 标记_token{0,1}的作用域 避免堆栈太深的错误
        // 调整后的余额0 = 余额0 * 1000 - （amount0In * 3）
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        // 调整后的余额1 = 余额0 * 1000 - amount1In * 3）
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        // 确认balance0Adjusted * balance1Adjusted >= 储备0 * 储备量1 * 1000000
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }
        // 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 触发事件
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // 强制平衡以匹配储备
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(
            _token0, 
            to, 
            IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // 强制准备金与余额匹配
    function sync() external lock {
        _update(
            IERC20(token0).balanceOf(address(this)), 
            IERC20(token1).balanceOf(address(this)), 
            reserve0, 
            reserve1
            );
    }
}
