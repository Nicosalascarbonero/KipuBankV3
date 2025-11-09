// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// === IMPORTS DESDE GITHUB (Remix no tiene npm) ===
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol";
import "https://github.com/chainlink/contracts/blob/master/src/v0.8/interfaces/AggregatorV3Interface.sol";

// === INTERFACES UNISWAP V2 ===
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);

    function WETH() external pure returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @title KipuBankV2 - Banco con swap automático a USDC
 * @notice Soporta ETH, USDC y cualquier token con par en Uniswap V2
 */
contract KipuBankV2 is Ownable, ReentrancyGuard {
    using SafeECF20 for IERC20;

    // --- CONSTANTES ---
    address public immutable USDC;
    address public immutable UNISWAP_ROUTER;
    address public immutable UNISWAP_FACTORY;
    AggregatorV3Interface public immutable USDC_USD_FEED;
    uint256 public immutable BANK_CAP_USD; // USD con 8 decimales
    uint256 public constant SLIPPAGE_BPS = 50; // 0.5%
    uint256 public constant BPS = 10_000;

    // --- ALMACENAMIENTO ---
    mapping(address => uint256) private s_balances; // user => USDC (6 decimals)
    uint256 public totalUSDC;
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;

    // --- ERRORES ---
    error NoUSDCTradingPair(address token);
    error SwapFailed(uint256 expectedMin, uint256 received);
    error CapExceeded(uint256 availableUSD, uint256 attemptedUSD);
    error InsufficientBalance(uint256 requested, uint256 available);
    error ZeroAmount();
    error TransferFailed();
    error ChainlinkCallFailed();

    // --- EVENTOS ---
    event Deposit(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcReceived, uint256 newBalance);
    event Withdrawal(address indexed user, uint256 usdcAmount, uint256 newBalance);
    event SwapExecuted(address indexed tokenIn, uint256 amountIn, uint256 usdcOut);

    // --- CONSTRUCTOR ---
    constructor(
        address usdc,
        address uniswapRouter,
        address uniswapFactory,
        address usdcUsdFeed,
        uint256 bankCapUSD
    ) Ownable() {
        USDC = usdc;
        UNISWAP_ROUTER = uniswapRouter;
        UNISWAP_FACTORY = uniswapFactory;
        USDC_USD_FEED = AggregatorV3Interface(usdcUsdFeed);
        BANK_CAP_USD = bankCapUSD;
    }

    // --- RECEIVE ETH ---
    receive() external payable {
        _depositETH();
    }

    // --- DEPÓSITOS ---
    function depositETH() external payable nonReentrant {
        _depositETH();
    }

    function depositToken(address token, uint256 amount) external nonReentrant {
        _depositToken(token, amount);
    }

    function _depositETH() private {
        if (msg.value == 0) revert ZeroAmount();

        address weth = IUniswapV2Router02(UNISWAP_ROUTER).WETH();
        address pair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(weth, USDC);
        if (pair == address(0)) revert NoUSDCTradingPair(weth);

        // Wrap ETH to WETH
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

    // --- SWAP ---
    function _swapToUSDC(address tokenIn, uint256 amountIn, address to) private returns (uint256) {
        IERC20(tokenIn).safeApprove(UNISWAP_ROUTER, amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = USDC;

        uint256[] memory amountsOut = IUniswapV2Router02(UNISWAP_ROUTER).getAmountsOut(amountIn, path);
        uint256 minOut = amountsOut[1] * (BPS - SLIPPAGE_BPS) / BPS;

        uint256[] memory amounts = IUniswapV2Router02(UNISWAP_ROUTER).swapExactTokensForTokens(
            amountIn,
            minOut,
            path,
            to,
            block.timestamp + 300
        );

        if (amounts[1] < minOut) revert SwapFailed(minOut, amounts[1]);
        emit SwapExecuted(tokenIn, amountIn, amounts[1]);
        return amounts[1];
    }

    // --- FINALIZAR DEPÓSITO ---
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

    // --- RETIRO ---
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

    // --- ORÁCULO ---
    function _usdcToUSD(uint256 usdcAmount) private view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = USDC_USD_FEED.latestRoundData();
        if (price <= 0 || block.timestamp - updatedAt > 3600) revert ChainlinkCallFailed();
        return (usdcAmount * uint256(price)) / 1e14;
    }

    function _currentBankValueUSD() private view returns (uint256) {
        return _usdcToUSD(totalUSDC);
    }

    // --- VIEWS ---
    function getBalance(address user) external view returns (uint256) {
        return s_balances[user];
    }

    function getCurrentBankValueUSD() external view returns (uint256) {
        return _currentBankValueUSD();
    }
}
