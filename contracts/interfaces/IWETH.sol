// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IWETH {
    function approve(address spender, uint256 amount) external;

    function deposit() external payable;

    function transfer(address to, uint value) external returns (bool);

    function withdraw(uint) external;
}
