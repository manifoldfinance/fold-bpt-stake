// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Test utils
import "forge-std/Test.sol";

import {IWETH} from "./interfaces/IWETH.sol";
import {IBasicRewards} from "contracts/interfaces/IBasicRewards.sol";
import {IAsset, IVault} from "./interfaces/IVault.sol";
import {IERC20, StakedBPT} from "contracts/StakedBPT.sol";

contract StakedBPTTest is Test {
    using stdStorage for StdStorage;
    address constant bpt = 0xb3b675a9A3CB0DF8F66Caf08549371BfB76A9867; // Gyroscope ECLP mevETH/wETH
    address constant auraBal = 0xED2BE1c4F6aEcEdA9330CeB8A747d42b0446cB0F; // Gyroscope ECLP mevETH/wETH Aura Deposit
    address constant depositor = 0xA57b8d98dAE62B26Ec3bcC4a365338157060B234; // Booster
    address constant pool = 0xF9b6BdC7fbf3B760542ae24cB939872705108399; // Gyroscope ECLP mevETH/wETH Aura Deposit Vault
    address constant treasury = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    uint256 constant minLockDuration = 30 days; // 1 month
    address constant owner = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    uint256 constant pid = 170;
    bytes32 constant poolId =
        0xb3b675a9a3cb0df8f66caf08549371bfb76a9867000200000000000000000611;
    string RPC_ETH_MAINNET = vm.envString("RPC_MAINNET");
    uint256 FORK_ID;
    address constant aura = 0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;

    IWETH weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IVault _vault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    StakedBPT stakedBPT;

    address constant mevEth = 0x24Ae2dA0f361AA4BE46b48EB19C91e02c5e4f27E;
    address constant bal = 0xba100000625a3754423978a60c9317c58a424e3D;

    function setUp() public virtual {
        FORK_ID = vm.createSelectFork(RPC_ETH_MAINNET);
        stakedBPT = new StakedBPT(
            bpt,
            auraBal,
            depositor,
            pool,
            treasury,
            minLockDuration,
            owner,
            pid
        );
    }

    function testdepositBPT(uint128 amount) public virtual {
        vm.assume(amount > 0.1 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), bpt, amount);
        IERC20(bpt).approve(address(stakedBPT), amount);
        stakedBPT.depositBPT(
            IERC20(bpt).balanceOf(address(this)),
            address(this)
        );
        assertGt(stakedBPT.balanceOf(address(this)), 0);
    }

    function testWithdraw(uint128 amount) public virtual {
        vm.assume(amount > 0.1 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), bpt, amount);
        IERC20(bpt).approve(address(stakedBPT), amount);
        stakedBPT.depositBPT(
            IERC20(bpt).balanceOf(address(this)),
            address(this)
        );
        vm.warp(block.timestamp + 60 days);
        stakedBPT.withdraw(
            stakedBPT.balanceOf(address(this)),
            address(this),
            address(this)
        );
        assertGt(IERC20(auraBal).balanceOf(address(this)), 0);
    }

    function testHarvest(uint128 amount) public virtual {
        vm.assume(amount > 1 ether);
        vm.assume(amount < 100000000 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), bpt, amount);
        IERC20(bpt).approve(address(stakedBPT), amount);
        stakedBPT.depositBPT(
            IERC20(bpt).balanceOf(address(this)),
            address(this)
        );
        // uint256 auraBalBefore = IERC20(aura).balanceOf(treasury);
        uint256 balBalBefore = IERC20(bal).balanceOf(treasury);
        vm.warp(block.timestamp + 60 days);

        stakedBPT.harvest();
        // assertGt(IERC20(aura).balanceOf(treasury), auraBalBefore);
        assertGt(IERC20(bal).balanceOf(treasury), balBalBefore);
    }

    function testDepositTimestamp() public virtual {
        uint128 amount = 10 ether;
        vm.assume(amount > 0.1 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), bpt, 2 * amount);
        IERC20(bpt).approve(address(stakedBPT), amount);
        stakedBPT.depositBPT(amount, address(this));
        uint256 balStaked = stakedBPT.balanceOf(address(this));
        vm.expectRevert();
        stakedBPT.withdraw(balStaked, address(this), address(this));
        // warp 10 days (i.e. less than min lockup)
        vm.warp(block.timestamp + 10 days);
        IERC20(bpt).approve(address(stakedBPT), amount);
        stakedBPT.depositBPT(
            IERC20(bpt).balanceOf(address(this)),
            address(this)
        );
        // warp to full 30 days from original deposit
        vm.warp(block.timestamp + 20 days);
        balStaked = stakedBPT.balanceOf(address(this));
        vm.expectRevert();
        stakedBPT.withdraw(balStaked, address(this), address(this));
        vm.warp(block.timestamp + 20 days);
        stakedBPT.withdraw(balStaked, address(this), address(this));
        assertGt(IERC20(auraBal).balanceOf(address(this)), 0);
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
