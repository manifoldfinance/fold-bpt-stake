// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./IERC20.sol";

interface IMevEth is IERC20 {
    function fraction() external view returns (uint128 elastic, uint128 base);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function convertToShares(uint256 assets) external view returns (uint256 shares);

    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    function previewMint(uint256 shares) external view returns (uint256 assets);

    function deposit(uint256 assets, address receiver) external payable returns (uint256 shares);

    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    function withdrawQueue(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}
