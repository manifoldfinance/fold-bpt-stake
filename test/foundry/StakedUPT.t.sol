// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Test utils
import "forge-std/Test.sol";

import {IWETH} from "./interfaces/IWETH.sol";
import {IERC20, StakedUPT} from "contracts/StakedUPT.sol";
import "contracts/interfaces/INonfungiblePositionManager.sol";

contract StakedUPTTest is Test {
    using stdStorage for StdStorage;
    address constant treasury = 0xe664B134d96fdB0bf7951E0c0557B87Bac5e5277; // Multisig
    address constant owner = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    address constant FOLD = 0xd084944d3c05CD115C09d072B9F44bA3E0E45921;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Uniswap's NonFungiblePositionManager (one for all new pools)
    address constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    string RPC_ETH_MAINNET = vm.envString("RPC_MAINNET");
    uint256 FORK_ID;

    IWETH weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    INonfungiblePositionManager nfpm = INonfungiblePositionManager(NFPM);
    StakedUPT stakedUPT;

    function setUp() public virtual {
        FORK_ID = vm.createSelectFork(RPC_ETH_MAINNET, 19034135);
        stakedUPT = new StakedUPT();
    }

    function testDepositAndWithdraw(uint128 amount) public virtual {
        vm.assume(amount > 1 ether);
        vm.assume(amount < 1000000 ether);
        vm.selectFork(FORK_ID);

        writeTokenBalance(address(this), FOLD, amount);

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams(
                WETH,
                FOLD,
                10000,
                -887200,
                887200,
                amount / 100,
                amount,
                1,
                1,
                address(this),
                block.timestamp
            );

        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(NFPM, amount);

        IERC20(FOLD).approve(NFPM, amount);
        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = nfpm.mint(params);
        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        nfpm.approve(address(stakedUPT), tokenId);
        stakedUPT.deposit(tokenId);
        assertGt(stakedUPT.depositTimestamps(address(this), tokenId), 0);

        // withdraw
        vm.warp(block.timestamp + 60 days);
        // note withdraw requires sufficient rewards sent to contract in weth
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(stakedUPT), 10 ether);
        stakedUPT.withdrawToken(tokenId);
        assertEq(stakedUPT.depositTimestamps(address(this), tokenId), 0);
    }

    function writeTokenBalance(
        address who,
        address token,
        uint256 amt
    ) internal {
        stdstore
            .target(token)
            .sig(IERC20(token).balanceOf.selector)
            .with_key(who)
            .checked_write(amt);
    }
}
