// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IBooster {
    /// @notice Pool Info for deposits and staking
    /// @custom: lptoken:  the underlying token(ex. the curve lp token)
    /// @custom: cvxtoken: the convex deposit token(a 1:1 token representing an lp deposit).  The supply of this token can be used to calculate the TVL of the pool
    /// @custom: gauge: the curve "gauge" or staking contract used by the pool
    /// @custom: crvRewards: the main reward contract for the pool
    /// @custom: stash: a helper contract used to hold extra rewards (like snx) on behalf of the pool until distribution is called
    /// @custom: shutdown: a shutdown flag of the pool
    struct PoolInfo {
        address lptoken;
        address cvxtoken;
        address gauge;
        address crvRewards;
        address stash;
        bool shutdown;
    }

    function poolInfo(uint256 _pid) external returns (PoolInfo memory);

    //deposit into convex, receive a tokenized deposit.  parameter to stake immediately
    function deposit(uint256 _pid, uint256 _amount, bool _stake) external returns (bool);

    //burn a tokenized deposit to receive curve lp tokens back
    function withdraw(uint256 _pid, uint256 _amount) external returns (bool);

    function earmarkRewards(uint256 pid) external;
}
