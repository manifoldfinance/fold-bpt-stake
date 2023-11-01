// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract StakedBPT is ERC4626, ReentrancyGuard {
    address public immutable token;
    uint256 public immutable minLockDuration;

    event Harvest(address indexed _caller, uint256 _value);

    constructor(
        address _token,
        uint256 _minLockDuration
    )
        ERC20(
            string(abi.encodePacked("Staked ", ERC20(_token).name())),
            string(abi.encodePacked("stk", ERC20(_token).symbol()))
        )
        ERC4626(IERC20(_token))
    {
        token = _token;
        minLockDuration = _minLockDuration;
    }

    function maxDeposit(address) public view override returns (uint256) {
        // TODO: could there be any limitations?
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        // TODO: could there be any limitations?
        return type(uint256).max;
    }

    function _transfer(address, address, uint256) internal override {
        revert("Transfer not supported");
    }

    function _approve(address, address, uint256) internal override {
        revert("Approve not supported");
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // TODO: stake into aura

        return super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        // TODO: unstake from aura

        return super._withdraw(caller, receiver, owner, assets, shares);
    }

    function harvest() public nonReentrant {
        // TODO
    }
}
