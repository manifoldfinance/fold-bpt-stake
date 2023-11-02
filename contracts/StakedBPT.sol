// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/ICrvDepositor.sol";
import "./interfaces/IBasicRewards.sol";

// Take BPT -> Stake on Aura -> Someone need to pay to harvest rewards -> Send to treasury multisig
contract StakedBPT is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable bpt;
    address public immutable auraBal;
    address public immutable depositor;
    address public immutable staking;
    uint256 public immutable minLockDuration;

    event Harvest(address indexed _caller, uint256 _value);

    constructor(
        address _depositor,
        address _bpt,
        address _auroBal,
        address _staking,
        uint256 _minLockDuration
    )
        ERC4626(IERC20(_bpt))
        ERC20(
            string(abi.encodePacked("Staked ", ERC20(_bpt).name())),
            string(abi.encodePacked("stk", ERC20(_bpt).symbol()))
        )
    {
        bpt = _bpt;
        auraBal = _auroBal;
        depositor = _depositor;
        staking = _staking;
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
        IERC20(bpt).safeTransferFrom(receiver, address(this), assets);

        uint256 amountBPT = IERC20(bpt).balanceOf(address(this));
        IERC20(bpt).approve(depositor, amountBPT);
        ICrvDepositor(depositor).deposit(amountBPT, true);

        uint256 amountAuraBal = IERC20(auraBal).balanceOf(address(this));
        IBasicRewards(staking).stake(amountAuraBal);

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
