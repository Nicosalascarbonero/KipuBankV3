// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;/* =============================================================
   TODO PEGADO ADENTRO: OpenZeppelin + Chainlink + Uniswap
   ============================================================= */// --- Context ---
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}// --- Ownable ---
abstract contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _transferOwnership(_msgSender()); }
    modifier onlyOwner() { require(owner() == _msgSender(), "Ownable: caller is not the owner"); _; }
    function owner() public view virtual returns (address) { return _owner; }
    function renounceOwnership() public virtual onlyOwner { _transferOwnership(address(0)); }
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is zero address");
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}// --- ReentrancyGuard ---
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;
    constructor() { _status = _NOT_ENTERED; }
    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}// --- IERC20 ---
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}// --- SafeERC20 ---
library SafeERC20 {
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.approve.selector, spender, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: approve failed");
    }
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }
}// --- AggregatorV3Interface ---
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId)
        external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}// --- Uniswap V2 Interfaces ---
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);
    function WETH() external pure returns (address);
}interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}/* =============================================================
   CONTRATO PRINCIPAL: KipuBankV3
   ============================================================= */contract KipuBankV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;address public immutable USDC;
address public immutable UNISWAP_ROUTER;
address public immutable UNISWAP_FACTORY;
AggregatorV3Interface public immutable USDC_USD_FEED;
uint256 public immutable BANK_CAP_USD;
uint256 public constant SLIPPAGE_BPS = 50;
uint256 public constant BPS = 10_000;

mapping(address => uint256) private s_balances;
uint256 public totalUSDC;
uint256 public totalDeposits;
uint256 public totalWithdrawals;

error NoUSDCTradingPair(address token);
error SwapFailed(uint256 expectedMin, uint256 received);
error CapExceeded(uint256 availableUSD, uint256 attemptedUSD);
error InsufficientBalance(uint256 requested, uint256 available);
error ZeroAmount();
error TransferFailed();
error ChainlinkCallFailed();

event Deposit(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcReceived, uint256 newBalance);
event Withdrawal(address indexed user, uint256 usdcAmount, uint256 newBalance);
event SwapExecuted(address indexed tokenIn, uint256 amountIn, uint256 usdcOut);

constructor(
        address usdc,
        address uniswapRouter,
        address uniswapFactory,
        address usdcUsdFeed,
        uint256 bankCapUSD
    ) Ownable() ReentrancyGuard() {
        USDC = usdc;
        UNISWAP_ROUTER = uniswapRouter;
        UNISWAP_FACTORY = uniswapFactory;
        USDC_USD_FEED = AggregatorV3Interface(usdcUsdFeed);
        BANK_CAP_USD = bankCapUSD;
    }

receive() external payable { _depositETH(); }

function depositETH() external payable nonReentrant { _depositETH(); }

function depositToken(address token, uint256 amount) external nonReentrant { _depositToken(token, amount); }

function _depositETH() private {
    if (msg.value == 0) revert ZeroAmount();
    address weth = IUniswapV2Router02(UNISWAP_ROUTER).WETH();
    address pair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(weth, USDC);
    if (pair == address(0)) revert NoUSDCTradingPair(weth);
    (bool ok, ) = weth.call{value: msg.value}(abi.encodeWithSignature("deposit()"));
    if (!ok) revert TransferFailed();
    uint256 usdcReceived = _swapToUSDC(weth, msg.value, address(this));
    _finalizeDeposit(msg.sender, weth, msg.value, usdcReceived);
}

function _depositToken(address token, uint256 amount) private {
    if (amount == 0) revert ZeroAmount();
    if (token == USDC) {
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        _finalizeDeposit(msg.sender, token, amount, amount);
        return;
    }
    address pair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(token, USDC);
    if (pair == address(0)) revert NoUSDCTradingPair(token);
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    uint256 usdcReceived = _swapToUSDC(token, amount, address(this));
    _finalizeDeposit(msg.sender, token, amount, usdcReceived);
}

function _swapToUSDC(address tokenIn, uint256 amountIn, address to) private returns (uint256) {
    IERC20(tokenIn).safeApprove(UNISWAP_ROUTER, amountIn);
    address[] memory path = new address[](2); path[0] = tokenIn; path[1] = USDC;
    uint256[] memory amountsOut = IUniswapV2Router02(UNISWAP_ROUTER).getAmountsOut(amountIn, path);
    uint256 minOut = amountsOut[1] * (BPS - SLIPPAGE_BPS) / BPS;
    uint256[] memory amounts = IUniswapV2Router02(UNISWAP_ROUTER).swapExactTokensForTokens(
        amountIn, minOut, path, to, block.timestamp + 300
    );
    if (amounts[1] < minOut) revert SwapFailed(minOut, amounts[1]);
    emit SwapExecuted(tokenIn, amountIn, amounts[1]);
    return amounts[1];
}

function _finalizeDeposit(address user, address tokenIn, uint256 amountIn, uint256 usdcReceived) private {
    uint256 usdcValueUSD = _usdcToUSD(usdcReceived);
    uint256 currentUSD = _currentBankValueUSD();
    if (currentUSD + usdcValueUSD > BANK_CAP_USD) {
        revert CapExceeded(BANK_CAP_USD - currentUSD, usdcValueUSD);
    }
    s_balances[user] += usdcReceived;
    totalUSDC += usdcReceived;
    totalDeposits++;
    emit Deposit(user, tokenIn, amountIn, usdcReceived, s_balances[user]);
}

function withdraw(uint256 usdcAmount) external nonReentrant {
    if (usdcAmount == 0) revert ZeroAmount();
    uint256 bal = s_balances[msg.sender];
    if (usdcAmount > bal) revert InsufficientBalance(usdcAmount, bal);
    s_balances[msg.sender] = bal - usdcAmount;
    totalUSDC -= usdcAmount;
    totalWithdrawals++;
    IERC20(USDC).safeTransfer(msg.sender, usdcAmount);
    emit Withdrawal(msg.sender, usdcAmount, s_balances[msg.sender]);
}

function _usdcToUSD(uint256 usdcAmount) private view returns (uint256) {
    (, int256 price, , uint256 updatedAt, ) = USDC_USD_FEED.latestRoundData();
    if (price <= 0 || block.timestamp - updatedAt > 3600) revert ChainlinkCallFailed();
    return (usdcAmount * uint256(price)) / 1e14;
}

function _currentBankValueUSD() private view returns (uint256) {
    return _usdcToUSD(totalUSDC);
}

function getBalance(address user) external view returns (uint256) { return s_balances[user]; }
function getCurrentBankValueUSD() external view returns (uint256) { return _currentBankValueUSD(); }}

