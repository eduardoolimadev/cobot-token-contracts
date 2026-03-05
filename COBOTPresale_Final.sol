// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

contract COBOTPresale is Ownable, ReentrancyGuard {
    // ===== Token presale =====
    IERC20 public cobotToken;
    uint8 public cobotTokenDecimals;

    // ===== Wallets =====
    address public fundsWallet;
    address public ecosystemWallet;

    // ===== Controls =====
    uint256 public constant cooldownTime = 1; // segundos
    // Alterado: cooldown individual por usuário
    mapping(address => uint256) public lastTxTimestamp;
    uint256 public constant taxBase = 50; // 0.5% em basis points
    uint256 public dynamicTax;
    bool public presalePaused = false;

    // Preço em USD com 5 casas decimais (ex.: 0,004 => 400)
    uint8 public constant PRICE_DECIMALS = 5;

    struct Phase {
        uint256 priceUSD; // preço escalado por 10^PRICE_DECIMALS
        uint256 tokens;   // estoque em unidades mínimas do COBOT (10^cobotTokenDecimals)
    }

    Phase[] public phases;
    uint256 public currentPhase;

    // ===== Pagamentos =====
    mapping(address => bool) public acceptedTokens; // ERC20 aceitos
    mapping(address => AggregatorV3Interface) public priceFeeds; // token => feed USD
    mapping(address => uint8) public paymentTokenDecimals; // decimais do token de pagamento

    // ===== Eventos =====
    event TokensPurchased(address indexed buyer, uint256 amount, address paymentToken, uint256 finalPhaseIndex);
    event PhaseUpdated(uint256 phase, uint256 newPrice);
    event TaxUpdated(uint256 newTaxBps);
    event EcosystemWalletUpdated(address newWallet);
    event FundsWalletUpdated(address newWallet);
    event TokenStatusUpdated(address token, bool status);
    event PresalePaused(bool status);

    constructor(address _cobotToken, address _fundsWallet) Ownable(msg.sender) {
        require(_cobotToken != address(0), "Invalid token");
        require(_fundsWallet != address(0), "Invalid funds wallet");

        cobotToken = IERC20(_cobotToken);
        cobotTokenDecimals = IERC20Metadata(_cobotToken).decimals();

        fundsWallet = _fundsWallet;
        dynamicTax = taxBase;

        _initPhases();
    }

    // ===== Inicialização das fases (estoque em unidades mínimas do COBOT) =====
    function _initPhases() internal {
        uint256 d = 10 ** cobotTokenDecimals;

        phases.push(Phase(400,    26548541 * d));
        phases.push(Phase(580,    28773254 * d));
        phases.push(Phase(760,    31184406 * d));
        phases.push(Phase(940,    33797609 * d));
        phases.push(Phase(1120,   36629794 * d));
        phases.push(Phase(1362,   39699312 * d));
        phases.push(Phase(1480,   43026050 * d));
        phases.push(Phase(1645,   46631564 * d));
        phases.push(Phase(1881,   50539214 * d));
        phases.push(Phase(2070,   54774318 * d));
        phases.push(Phase(2245,   59364318 * d));
        phases.push(Phase(2380,   64338952 * d));
        phases.push(Phase(2560,   69730453 * d));
        phases.push(Phase(2750,   75573752 * d));
        phases.push(Phase(2920,   81906711 * d));
        phases.push(Phase(3100,   88770361 * d));
        phases.push(Phase(3277,   96209174 * d));
        phases.push(Phase(3460,   104271348 * d));
        phases.push(Phase(3640,   113009118 * d));
        phases.push(Phase(3820,   122479100 * d));
    }

    // ===== Modifiers =====
    modifier whenNotPaused() {
        require(!presalePaused, "Presale is paused");
        _;
    }

    // ===== Compra com ETH =====
    function buyWithETH() external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "Send ETH to buy tokens");
        require(address(priceFeeds[address(0)]) != address(0), "ETH price feed not set");
        _applyCooldown();

        // Taxa e valor líquido
        uint256 taxAmount = (msg.value * dynamicTax) / 10000;
        uint256 netAmount = msg.value - taxAmount;
        require(netAmount > 0, "Net amount is zero");

        // Calcula e entrega tokens
        uint256 totalTokens = _calculateTokensAcrossPhases(netAmount, address(0));
        require(totalTokens > 0, "Zero tokens");

        _deliverTokens(msg.sender, totalTokens);

        // Distribui ETH (taxa + líquido)
        if (ecosystemWallet != address(0) && taxAmount > 0) {
            payable(ecosystemWallet).transfer(taxAmount);
        }
        if (fundsWallet != address(0) && netAmount > 0) {
            payable(fundsWallet).transfer(netAmount);
        }

        emit TokensPurchased(msg.sender, totalTokens, address(0), currentPhase);
    }

    // ===== Compra com token ERC20 =====
    function buyWithToken(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(acceptedTokens[token], "Token not accepted");
        require(amount > 0, "Amount must be > 0");
        require(address(priceFeeds[token]) != address(0), "Price feed not set for token");
        require(paymentTokenDecimals[token] > 0, "Token decimals not set");
        _applyCooldown();

        // Taxa e valor líquido
        uint256 taxAmount = (amount * dynamicTax) / 10000;
        uint256 netAmount = amount - taxAmount;
        require(netAmount > 0, "Net amount is zero");

        // Transferências do token de pagamento
        if (ecosystemWallet != address(0) && taxAmount > 0) {
            require(IERC20(token).transferFrom(msg.sender, ecosystemWallet, taxAmount), "Tax transfer failed");
        }
        require(IERC20(token).transferFrom(msg.sender, fundsWallet, netAmount), "Funds transfer failed");

        // Calcula e entrega tokens
        uint256 totalTokens = _calculateTokensAcrossPhases(netAmount, token);
        require(totalTokens > 0, "Zero tokens");

        _deliverTokens(msg.sender, totalTokens);

        emit TokensPurchased(msg.sender, totalTokens, token, currentPhase);
    }

    // ===== Núcleo: Consome fases e usa o USD restante na próxima =====
    function _calculateTokensAcrossPhases(uint256 netPaymentAmount, address paymentToken) internal returns (uint256) {
        require(currentPhase < phases.length, "Presale ended");

        uint256 usdRemaining = _convertToUSD(netPaymentAmount, paymentToken);
        require(usdRemaining > 0, "USD value is zero");

        uint256 tokensTotal;

        while (usdRemaining > 0 && currentPhase < phases.length) {
            Phase storage phase = phases[currentPhase];
            uint256 tokensAvailable = phase.tokens;

            if (tokensAvailable == 0) {
                currentPhase++;
                continue;
            }

            // Quantos tokens daria para comprar com o USD restante nesta fase
            // tokensPotential = usdRemaining * 10^PRICE_DECIMALS * 10^cobotDecimals / priceUSD
            uint256 tokensPotential = (usdRemaining * (10 ** PRICE_DECIMALS) * (10 ** cobotTokenDecimals)) / phase.priceUSD;

            if (tokensPotential >= tokensAvailable) {
                // Consumir toda a fase atual
                tokensTotal += tokensAvailable;

                // USD gasto para consumir o estoque
                // usdCost = tokensAvailable * priceUSD / (10^cobotDecimals * 10^PRICE_DECIMALS)
                uint256 usdCost = (tokensAvailable * phase.priceUSD) / ((10 ** cobotTokenDecimals) * (10 ** PRICE_DECIMALS));

                // Subtrai do saldo e avança de fase
                usdRemaining = usdRemaining > usdCost ? usdRemaining - usdCost : 0;

                phase.tokens = 0;
                currentPhase++;
            } else {
                // Compra parcial dentro da fase atual e encerra
                tokensTotal += tokensPotential;

                uint256 usdCost = (tokensPotential * phase.priceUSD) / ((10 ** cobotTokenDecimals) * (10 ** PRICE_DECIMALS));
                usdRemaining = usdRemaining > usdCost ? usdRemaining - usdCost : 0;

                phase.tokens = tokensAvailable - tokensPotential;

                // Se o custo ficou zero por arredondamento extremo, evita loop infinito
                if (usdCost == 0) break;
            }
        }

        return tokensTotal;
    }

    // ===== Conversão de pagamento para USD (respeitando decimais do feed e do token) =====
    function _convertToUSD(uint256 amount, address token) internal view returns (uint256) {
        require(amount > 0, "Amount must be > 0");

        AggregatorV3Interface feed;
        uint8 decimalsToken;

        if (token == address(0)) {
            // ETH
            feed = priceFeeds[address(0)];
            require(address(feed) != address(0), "ETH feed not set");
            decimalsToken = 18; // wei
        } else {
            // ERC20
            feed = priceFeeds[token];
            require(address(feed) != address(0), "Feed not set");
            decimalsToken = paymentTokenDecimals[token];
        }

        (, int256 price,,,) = feed.latestRoundData();
        require(price > 0, "Invalid price feed");

        uint8 feedDecimals = feed.decimals();

        // usdValue = amount * price / 10^(decimalsToken + feedDecimals)
        uint256 usdValue = (amount * uint256(price)) / (10 ** (uint256(decimalsToken) + uint256(feedDecimals)));
        return usdValue;
    }

    // ===== Entrega de tokens COBOT =====
    function _deliverTokens(address buyer, uint256 amount) internal {
        require(cobotToken.balanceOf(address(this)) >= amount, "Not enough tokens");
        require(cobotToken.transfer(buyer, amount), "Token transfer failed");
    }

    // ===== Cooldown simples para evitar spam =====
    function _applyCooldown() internal {
        require(block.timestamp >= lastTxTimestamp[msg.sender] + cooldownTime, "Cooldown active");
        lastTxTimestamp[msg.sender] = block.timestamp;
    }

    // ===== Administração =====

    function pausePresale() external onlyOwner {
        presalePaused = true;
        emit PresalePaused(true);
    }

    function resumePresale() external onlyOwner {
        presalePaused = false;
        emit PresalePaused(false);
    }

    function updatePhasePrice(uint256 phaseIndex, uint256 newPriceScaled) external onlyOwner {
        require(phaseIndex < phases.length, "Invalid phase");
        require(newPriceScaled > 0, "Invalid price");
        phases[phaseIndex].priceUSD = newPriceScaled;
        emit PhaseUpdated(phaseIndex, newPriceScaled);
    }

    function updateTaxRate(uint256 newTaxBps) external onlyOwner {
        require(newTaxBps <= 10000, "Invalid tax");
        dynamicTax = newTaxBps;
        emit TaxUpdated(newTaxBps);
    }

    function updateEcosystemWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Invalid address");
        ecosystemWallet = newWallet;
        emit EcosystemWalletUpdated(newWallet);
    }

    function setFundsWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Invalid address");
        fundsWallet = newWallet;
        emit FundsWalletUpdated(newWallet);
    }

    function addPaymentToken(address token, address priceFeed, uint8 decimals) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(priceFeed != address(0), "Invalid feed");
        require(decimals > 0 && decimals <= 36, "Invalid decimals");
        acceptedTokens[token] = true;
        priceFeeds[token] = AggregatorV3Interface(priceFeed);
        paymentTokenDecimals[token] = decimals;
        emit TokenStatusUpdated(token, true);
    }

    function removePaymentToken(address token) external onlyOwner {
        acceptedTokens[token] = false;
        emit TokenStatusUpdated(token, false);
    }

    function setETHPriceFeed(address priceFeed) external onlyOwner {
        require(priceFeed != address(0), "Invalid feed");
        priceFeeds[address(0)] = AggregatorV3Interface(priceFeed);
    }

    // ===== Utilidades =====
    function phasesLength() external view returns (uint256) {
        return phases.length;
    }
}
