
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

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
 * @title KipuBankV2
 * @notice Banco con swap automático a USDC vía Uniswap V2. Soporta cualquier token con par directo en USDC.
 * @dev Todos los depósitos se convierten a USDC. El límite del banco (`BANK_CAP_USD`) se verifica en USD (8 decimales)
 *      usando el precio de Chainlink USDC/USD. El cálculo respeta los 6 decimales de USDC.
 */
contract KipuBankV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- CONSTANTES ---
    address public immutable USDC;
    address public immutable UNISWAP_ROUTER;
    address public immutable UNISWAP_FACTORY;
    AggregatorV3Interface public immutable USDC_USD_FEED;
    uint256 public immutable BANK_CAP_USD;               // Límite en USD con 8 decimales
    uint256 public constant SLIPPAGE_BPS = 50;           // 0.5 % de slippage máximo
    uint256 public constant BPS = 10_000;

    // --- ALMACENAMIENTO ---
    mapping(address => uint256) private s_balances;       // user => USDC balance (6 decimales)
    uint256 public totalUSDC;                             // Total USDC en el banco (6 decimales)
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;

    // --- ERRORES ---
    /// @notice No existe par directo con USDC en Uniswap V2.
    error NoUSDCTradingPair(address token);
    /// @notice Swap falló o el slippage superó el límite permitido.
    error SwapFailed(uint256 expectedMin, uint256 received);
    /// @notice Se intenta superar el límite global del banco.
    error CapExceeded(uint256 availableUSD, uint256 attemptedUSD);
    /// @notice Saldo insuficiente para la operación.
    error InsufficientBalance(uint256 requested, uint256 available);
    /// @notice Cantidad cero no permitida.
    error ZeroAmount();
    /// @notice Fallo en transferencia de tokens o ETH.
    error TransferFailed();
    /// @notice Llamada a Chainlink devolvió datos inválidos o está desactualizada.
    error ChainlinkCallFailed();

    // --- EVENTOS ---
    event Deposit(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcReceived, uint256 newBalance);
    event Withdrawal(address indexed user, uint256 usdcAmount, uint256 newBalance);
    event SwapExecuted(address indexed tokenIn, uint256 amountIn, uint256 usdcOut);

    // --- CONSTRUCTOR ---
    /**
     * @notice Despliega el contrato con los parámetros necesarios.
     * @param usdc               Dirección del token USDC (6 decimales).
     * @param uniswapRouter      Dirección del Uniswap V2 Router.
     * @param uniswapFactory     Dirección del Uniswap V2 Factory.
     * @param usdcUsdFeed        Feed Chainlink USDC/USD (8 decimales).
     * @param bankCapUSD         Límite del banco en USD con 8 decimales.
     */
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
    /**
     * @notice Depósito de ETH (se envuelve a WETH y luego se swapea a USDC).
     */
    function depositETH() external payable nonReentrant {
        _depositETH();
    }

    /**
     * @notice Depósito de cualquier ERC-20. Si es USDC se guarda directamente; de lo contrario se swapea a USDC.
     * @param token  Dirección del token a depositar.
     * @param amount Cantidad en unidades nativas del token.
     */
    function depositToken(address token, uint256 amount) external nonReentrant {
        _depositToken(token, amount);
    }

    /** @dev Lógica interna para ETH. */
    function _depositETH() private {
        if (msg.value == 0) revert ZeroAmount();

        address weth = IUniswapV calcRouter02(UNISWAP_ROUTER).WETH();
        address pair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(weth, USDC);
        if (pair == address(0)) revert NoUSDCTradingPair(weth);

        // Wrap ETH → WETH
        (bool ok, ) = weth.call{value: msg.value}(abi.encodeWithSignature("deposit()"));
        if (!ok) revert TransferFailed();

        uint256 usdcReceived = _swapToUSDC(weth, msg.value, address(this));
        _finalizeDeposit(usdcReceived);
    }

    /** @dev Lógica interna para tokens ERC-20. */
    function _depositToken(address token, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();

        if (token == USDC) {
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
            _finalizeDeposit(amount);
            return;
        }

        address pair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(token, USDC);
        if (pair == address(0)) revert NoUSDCTradingPair(token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 usdcReceived = _swapToUSDC(token, amount, address(this));
        _finalizeDeposit
