// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./StakedPT.sol";
import "./interfaces/ITokenWrapper.sol";

/**
 * @title StakedCPT
 * @dev StakedCPT is a contract that represents staked Curve LP (Liquidity Provider) tokens,
 * allowing users to stake their LP tokens to earn rewards in another token (cvxtoken).
 * This contract extends ERC4626, implements ReentrancyGuard, and is Owned.
 */
contract StakedCPT is StakedPT {
    constructor(
        address _lptoken,
        address _cvxtoken,
        address _booster,
        address _treasury,
        address _owner,
        uint256 _minLockDuration,
        address _weth,
        uint256 _pid
    ) StakedPT(_lptoken, _cvxtoken, _booster, _treasury, _owner, _minLockDuration, _weth, _pid) {}

    function _getStashToken(address virtualRewards) internal override returns (address stashToken) {
        address stash = IVirtualRewards(virtualRewards).rewardToken();
        stashToken = ITokenWrapper(stash).token();
    }
}
