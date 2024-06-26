// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IRewards {
    //get balance of an address
    function balanceOf(address _account) external view returns (uint256);

    //withdraw to a convex tokenized deposit
    function withdraw(uint256 _amount, bool _claim) external returns (bool);

    //withdraw directly to curve LP token
    function withdrawAndUnwrap(uint256 _amount, bool _claim) external returns (bool);

    //claim rewards
    function getReward() external returns (bool);

    //stake a convex tokenized deposit
    function stake(uint256 _amount) external returns (bool);

    //stake a convex tokenized deposit for another address(transfering ownership)
    function stakeFor(address _account, uint256 _amount) external returns (bool);

    function exit() external returns (bool);

    function rewardToken() external view returns (address);

    function extraRewards(uint256) external view returns (address);

    function extraRewardsLength() external view returns (uint256);
}
