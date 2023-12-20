// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./StakedBPT.sol";
import "./interfaces/ITokenWrapper.sol";

contract StakedCPT is StakedBPT {
    constructor(
        address _lptoken,
        address _cvxtoken,
        address _booster,
        address _treasury,
        address _owner,
        uint256 _minLockDuration,
        address _weth,
        uint256 _pid
    )
        StakedBPT(
            _lptoken,
            _cvxtoken,
            _booster,
            _treasury,
            _owner,
            _minLockDuration,
            _weth,
            address(0),
            _pid,
            bytes32(0)
        )
    {}

    function _getStashToken(address virtualRewards) internal override returns (address stashToken) {
        address stash = IVirtualRewards(virtualRewards).rewardToken();
        stashToken = ITokenWrapper(stash).token();
    }
}
