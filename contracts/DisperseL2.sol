// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@solmate/utils/SafeTransferLib.sol";

contract DisperseL2 {
    using SafeTransferLib for ERC20;

    function disperse(address token, address[] memory recipients, uint256[] memory amounts) external {
        uint256 length = recipients.length;
        require(length == amounts.length, "Invalid lengths");

        if (token == address(0)) {
            for (uint256 i; i < length; ) {
                uint256 amount = amounts[i];
                if (amount > 0) {
                    payable(recipients[i]).transfer(amount);
                }
                unchecked {
                    ++i;
                }
            }
        } else {
            for (uint256 i; i < length; ) {
                uint256 amount = amounts[i];
                if (amount > 0) {
                    ERC20(token).safeTransfer(recipients[i], amount);
                }
                unchecked {
                    ++i;
                }
            }
        }
    }
}
