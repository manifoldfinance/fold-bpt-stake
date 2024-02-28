/// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.19;

interface IERC721 {
    function transferFrom(address, address, uint) external;
}

interface INonfungiblePositionManager is IERC721 {
    function positions(
        uint256 tokenId
    )
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}
