// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ICrvDepositor.sol";
import "./interfaces/IBasicRewards.sol";

// Take BPT -> Stake on Aura -> Someone need to pay to harvest rewards -> Send to treasury multisig
contract StakedBPT is ERC4626, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    address public immutable bpt;
    address public immutable auraBal;
    address public immutable depositor;
    address public immutable staking;
    address public treasury;
    uint256 public minLockDuration;

    event UpdateTreasury(address indexed treasury);
    event UpdateMinLockDuration(uint256 duration);

    constructor(
        address _bpt,
        address _auroBal,
        address _depositor,
        address _staking,
        address _treasury,
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
        treasury = _treasury;
        minLockDuration = _minLockDuration;

        emit UpdateTreasury(_treasury);
        emit UpdateMinLockDuration(_minLockDuration);
    }

    function maxDeposit(address) public view override returns (uint256) {
        // TODO: could there be any limitations?
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        // TODO: could there be any limitations?
        return type(uint256).max;
    }

    function updateTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;

        emit UpdateTreasury(_treasury);
    }

    function updateMinLockDuration(uint256 _minLockDuration) external onlyOwner {
        minLockDuration = _minLockDuration;

        emit UpdateMinLockDuration(_minLockDuration);
    }

    function _transfer(address, address, uint256) internal override {
        revert("Transfer not supported");
    }

    function _approve(address, address, uint256) internal override {
        revert("Approve not supported");
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        IERC20(bpt).safeTransferFrom(caller, address(this), assets);

        // Receive auraBal
        IERC20(bpt).approve(depositor, assets);
        ICrvDepositor(depositor).deposit(assets, true);

        IBasicRewards(staking).stake(assets);

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Receive auraBal
        IBasicRewards(staking).withdraw(assets, false);

        _burn(owner, shares);
        IERC20(auraBal).safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function harvest() public nonReentrant {
        IBasicRewards(staking).getReward();
    }

    function transferTokens(address[] memory tokens) public nonReentrant {
        for (uint256 i; i < tokens.length; ) {
            IERC20(tokens[i]).safeTransfer(treasury, IERC20(tokens[i]).balanceOf(address(this)));
            unchecked {
                ++i;
            }
        }
    }
}
