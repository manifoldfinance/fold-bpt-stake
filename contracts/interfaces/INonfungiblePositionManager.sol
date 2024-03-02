/// SPDX-License-Identifier: AGPL-3.0

pragma solidity =0.7.6;

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
            uint96,
            address,
            address token0,
            address token1,
            uint24,
            int24,
            int24,
            uint128 liquidity,
            uint256,
            uint256,
            uint128,
            uint128
        );
}
