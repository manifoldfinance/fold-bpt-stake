// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface ICrvDepositor {
    function crvBpt() external view returns (address);

    function minter() external view returns (address);

    function deposit(uint256 pid, uint256 _amount, bool _lock) external;
    function withdraw(uint256 pid, uint256 assets) external;
}
