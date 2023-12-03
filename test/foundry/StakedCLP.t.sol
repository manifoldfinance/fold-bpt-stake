// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Test utils
import "forge-std/Test.sol";

import {IWETH} from "./interfaces/IWETH.sol";
import {IERC20, StakedCLP} from "contracts/StakedCLP.sol";

contract StakedCLPTest is Test {
    using stdStorage for StdStorage;
    address constant clp = 0x9b77bd0a665F05995b68e36fC1053AFFfAf0d4B5; // Curve.fi Factory Crypto Pool: mevETH/frxETH
    address constant cvxtoken = 0xEFD9bC8c4f341a7dA06835F1790118D8372BA033; // Curve.fi Factory Crypto Pool: mevETH/frxETH Convex Deposit
    address constant booster = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31; // Booster
    address constant pool = 0x9A767E19cD9E5c9eD8494281da409Be38Fc76015; // Rewrds pool
    address constant treasury = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    uint256 constant minLockDuration = 30 days; // 1 month
    address constant owner = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    uint256 constant pid = 261;

    string RPC_ETH_MAINNET = vm.envString("RPC_MAINNET");
    uint256 FORK_ID;

    IWETH weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    StakedCLP stakedCLP;

    address constant mevEth = 0x24Ae2dA0f361AA4BE46b48EB19C91e02c5e4f27E;
    address constant crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    function setUp() public virtual {
        FORK_ID = vm.createSelectFork(RPC_ETH_MAINNET);
        stakedCLP = new StakedCLP(
            clp,
            cvxtoken,
            booster,
            treasury,
            owner,
            minLockDuration,
            pid
        );
    }

    function testdepositLP(uint128 amount) public virtual {
        vm.assume(amount > 0.1 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), clp, amount);
        IERC20(clp).approve(address(stakedCLP), amount);
        stakedCLP.depositLP(
            IERC20(clp).balanceOf(address(this)),
            address(this)
        );
        assertGt(stakedCLP.balanceOf(address(this)), 0);
    }

    function testWithdraw(uint128 amount) public virtual {
        vm.assume(amount > 0.1 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), clp, amount);
        IERC20(clp).approve(address(stakedCLP), amount);
        stakedCLP.depositLP(
            IERC20(clp).balanceOf(address(this)),
            address(this)
        );
        vm.warp(block.timestamp + 60 days);
        stakedCLP.withdraw(
            stakedCLP.balanceOf(address(this)),
            address(this),
            address(this)
        );
        assertGt(IERC20(cvxtoken).balanceOf(address(this)), 0);
    }

    function testHarvest(uint128 amount) public virtual {
        vm.assume(amount > 1 ether);
        vm.assume(amount < 100000000 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), clp, amount);
        IERC20(clp).approve(address(stakedCLP), amount);
        stakedCLP.depositLP(
            IERC20(clp).balanceOf(address(this)),
            address(this)
        );
        // uint256 cvxtokenBefore = IERC20(aura).balanceOf(treasury);
        uint256 balBalBefore = IERC20(crv).balanceOf(treasury);
        vm.warp(block.timestamp + 60 days);

        stakedCLP.harvest();
        // assertGt(IERC20(aura).balanceOf(treasury), cvxtokenBefore);
        assertGt(IERC20(crv).balanceOf(treasury), balBalBefore);
    }

    function testDepositTimestamp() public virtual {
        uint128 amount = 10 ether;
        vm.assume(amount > 0.1 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), clp, 2 * amount);
        IERC20(clp).approve(address(stakedCLP), amount);
        stakedCLP.depositLP(amount, address(this));
        uint256 balStaked = stakedCLP.balanceOf(address(this));
        vm.expectRevert();
        stakedCLP.withdraw(balStaked, address(this), address(this));
        // warp 10 days (i.e. less than min lockup)
        vm.warp(block.timestamp + 10 days);
        IERC20(clp).approve(address(stakedCLP), amount);
        stakedCLP.depositLP(
            IERC20(clp).balanceOf(address(this)),
            address(this)
        );
        // warp to full 30 days from original deposit
        vm.warp(block.timestamp + 20 days);
        balStaked = stakedCLP.balanceOf(address(this));
        vm.expectRevert();
        stakedCLP.withdraw(balStaked, address(this), address(this));
        vm.warp(block.timestamp + 20 days);
        stakedCLP.withdraw(balStaked, address(this), address(this));
        assertGt(IERC20(cvxtoken).balanceOf(address(this)), 0);
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
