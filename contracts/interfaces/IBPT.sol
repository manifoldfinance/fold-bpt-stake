// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IBPT {
    function getSwapFeePercentage() external returns (uint256);

    function getActualSupply() external returns (uint256);

    function getLastInvariant() external returns (uint256);

    function getNormalizedWeights() external returns (uint256[] memory);

    function totalSupply() external returns (uint256);

    function getPrice() external returns (uint256);
}
