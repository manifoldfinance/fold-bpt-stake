// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@balancer-labs/v2-solidity-utils/contracts/math/LogExpMath.sol";
import "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";

library BPTCalculator {
    using FixedPoint for uint256;

    // Calculates the expected amount of BPT tokens to be returned when joining the pool
    function calculateBPTOut(
        uint256 bptTotalSupply, // The total supply of BPT tokens in the pool
        uint256 swapFeePercentage, // The protocol swap fee percentage
        uint256[] memory amountsIn, // The amounts of tokens sent to the pool
        uint256[] memory balances, // The balances of tokens in the pool
        uint256[] memory normalizedWeights // The normalized weights of tokens in the pool
    ) internal pure returns (uint256) {
        // Check that the input arrays have the same length
        uint256 numTokens = amountsIn.length;
        require(numTokens == balances.length && numTokens == normalizedWeights.length, "ERR_INVALID_INPUT_LENGTH");

        // Check that the input values are within the fixed point range
        for (uint256 i = 0; i < numTokens; i++) {
            _requireWithinBounds(amountsIn[i]);
            _requireWithinBounds(balances[i]);
            _requireWithinBounds(normalizedWeights[i]);
        }

        // Calculate the invariant ratio
        uint256 invariantRatio = FixedPoint.ONE;
        for (uint256 i = 0; i < numTokens; i++) {
            uint256 balanceRatio = balances[i].divUp(amountsIn[i]);
            invariantRatio = invariantRatio.mulDown(balanceRatio.powDown(normalizedWeights[i]));
        }

        // Calculate the BPT out
        uint256 bptOut = bptTotalSupply.mulDown(invariantRatio.complement());
        uint256 fee = bptOut.mulDown(swapFeePercentage).div(1e18);
        return bptOut.sub(fee);
    }

    // Checks that a value is within the fixed point range
    function _requireWithinBounds(uint256 value) internal pure {
        require(value < 2 ** 112, "ERR_OUT_OF_BOUNDS");
    }
}
