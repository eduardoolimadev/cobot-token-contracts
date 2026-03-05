// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPriceFeed {
    int256 private price;
    uint8 private decimalsValue;

    constructor(int256 _initialPrice, uint8 _decimals) {
        price = _initialPrice; // Ex.: 2000 * 10^8 para ETH/USD = $2000
        decimalsValue = _decimals; // Ex.: 8
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (0, price, block.timestamp, block.timestamp, 0);
    }

    function decimals() external view returns (uint8) {
        return decimalsValue;
    }

    // Função para atualizar preço manualmente durante testes
    function setPrice(int256 _newPrice) external {
        price = _newPrice;
    }
}