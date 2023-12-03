// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./StakedBPT.sol";
import "./interfaces/ITokenWrapper.sol";

contract StakedCLP is StakedBPT {
    constructor(
        address _lptoken,
        address _cvxtoken,
        address _booster,
        address _treasury,
        address _owner,
        uint256 _minLockDuration,
        uint256 _pid
    ) StakedBPT(_lptoken, _cvxtoken, _booster, _treasury, _owner, _minLockDuration, _pid) {}

    function _getStashToken(address virtualRewards) internal override returns (address stashToken) {
        address stash = IVirtualRewards(virtualRewards).rewardToken();
        stashToken = ITokenWrapper(stash).token();
    }
}
