// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Test utils
import "forge-std/Test.sol";

import {IWETH} from "./interfaces/IWETH.sol";
import {IERC20, StakedCPT} from "contracts/StakedCPT.sol";

contract StakedCPTTest is Test {
    using stdStorage for StdStorage;
    address constant clp = 0x9b77bd0a665F05995b68e36fC1053AFFfAf0d4B5; // Curve.fi Factory Crypto Pool: mevETH/frxETH
    address constant cvxtoken = 0xEFD9bC8c4f341a7dA06835F1790118D8372BA033; // Curve.fi Factory Crypto Pool: mevETH/frxETH Convex Deposit
    address constant booster = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31; // Booster
    address constant pool = 0xF1B0382A141040601Bd4c98Ee1A05b44A7392A80; // Curve pool
    address constant treasury = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    uint256 constant minLockDuration = 30 days; // 1 month
    address constant owner = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    uint256 constant pid = 261;

    string RPC_ETH_MAINNET = vm.envString("RPC_MAINNET");
    uint256 FORK_ID;

    IWETH weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    StakedCPT stakedCPT;

    address constant mevEth = 0x24Ae2dA0f361AA4BE46b48EB19C91e02c5e4f27E;
    address constant frxEth = 0x5E8422345238F34275888049021821E8E08CAa1f;
    address constant crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    function setUp() public virtual {
        FORK_ID = vm.createSelectFork(RPC_ETH_MAINNET, 19034135);
        stakedCPT = new StakedCPT(
            clp,
            cvxtoken,
            booster,
            treasury,
            owner,
            minLockDuration,
            address(weth),
            pid,
            pool
        );
    }

    function testZapCpt(uint128 amount) public virtual {
        vm.assume(amount > 0.1 ether);
        vm.assume(amount < 5000 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), mevEth, amount);
        IERC20(mevEth).approve(address(stakedCPT), amount);
        uint256[2] memory amounts;
        amounts[0] = 0.0001 ether;
        amounts[1] = amount;
        writeTokenBalance(address(this), frxEth, 0.0001 ether);
        IERC20(frxEth).approve(address(stakedCPT), amount);
        stakedCPT.zapCPT(amounts, address(this));
        assertGt(stakedCPT.balanceOf(address(this)), 0);
    }

    function testZipCpt(uint128 amount) public virtual {
        vm.assume(amount > 0.1 ether);
        vm.assume(amount < 5000 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), mevEth, amount);
        IERC20(mevEth).approve(address(stakedCPT), amount);
        uint256[2] memory amounts;
        amounts[0] = 0;
        amounts[1] = amount;
        // writeTokenBalance(address(this), frxEth, 0.0001 ether);
        // IERC20(frxEth).approve(address(stakedCPT), amount);
        uint256 stakedAuraCPT = stakedCPT.zapCPT(amounts, address(this));
        vm.warp(block.timestamp + 60 days);
        stakedCPT.approve(address(stakedCPT), stakedAuraCPT);
        uint256[2] memory minAmountsOut;
        minAmountsOut[0] = 0;
        minAmountsOut[1] = (amount * 98) / 100;
        stakedCPT.zipCPT(
            stakedAuraCPT,
            address(this),
            address(this),
            minAmountsOut
        );

        assertGt(IERC20(mevEth).balanceOf(address(this)), minAmountsOut[1]);
    }

    function testdepositLP(uint128 amount) public virtual {
        vm.assume(amount > 0.1 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), clp, amount);
        IERC20(clp).approve(address(stakedCPT), amount);
        stakedCPT.depositLP(
            IERC20(clp).balanceOf(address(this)),
            address(this)
        );
        assertGt(stakedCPT.balanceOf(address(this)), 0);
    }

    function testWithdraw(uint128 amount) public virtual {
        vm.assume(amount > 0.1 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), clp, amount);
        IERC20(clp).approve(address(stakedCPT), amount);
        stakedCPT.depositLP(
            IERC20(clp).balanceOf(address(this)),
            address(this)
        );
        vm.warp(block.timestamp + 60 days);
        stakedCPT.withdraw(
            stakedCPT.balanceOf(address(this)),
            address(this),
            address(this)
        );
        assertGt(IERC20(cvxtoken).balanceOf(address(this)), 0);
    }

    function testHarvest(uint128 amount) public virtual {
        vm.assume(amount > 100 ether);
        vm.assume(amount < 100000000 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), clp, amount);
        IERC20(clp).approve(address(stakedCPT), amount);
        stakedCPT.depositLP(
            IERC20(clp).balanceOf(address(this)),
            address(this)
        );
        // uint256 cvxtokenBefore = IERC20(aura).balanceOf(treasury);
        // uint256 balBalBefore = IERC20(crv).balanceOf(treasury);
        uint256 valBefore = stakedCPT.previewRedeem(
            IERC20(address(stakedCPT)).balanceOf(address(this))
        );
        vm.warp(block.timestamp + 180 days);

        stakedCPT.harvest();
        // assertGt(IERC20(aura).balanceOf(treasury), cvxtokenBefore);
        // assertGt(IERC20(crv).balanceOf(treasury), balBalBefore);
        assertGt(
            stakedCPT.previewRedeem(
                IERC20(address(stakedCPT)).balanceOf(address(this))
            ),
            valBefore
        );
    }

    function testDepositTimestamp() public virtual {
        uint128 amount = 10 ether;
        vm.assume(amount > 0.1 ether);
        vm.selectFork(FORK_ID);
        writeTokenBalance(address(this), clp, 2 * amount);
        IERC20(clp).approve(address(stakedCPT), amount);
        stakedCPT.depositLP(amount, address(this));
        uint256 balStaked = stakedCPT.balanceOf(address(this));
        vm.expectRevert();
        stakedCPT.withdraw(balStaked, address(this), address(this));
        // warp 10 days (i.e. less than min lockup)
        vm.warp(block.timestamp + 10 days);
        IERC20(clp).approve(address(stakedCPT), amount);
        stakedCPT.depositLP(
            IERC20(clp).balanceOf(address(this)),
            address(this)
        );
        // warp to full 30 days from original deposit
        vm.warp(block.timestamp + 20 days);
        balStaked = stakedCPT.balanceOf(address(this));
        vm.expectRevert();
        stakedCPT.withdraw(balStaked, address(this), address(this));
        vm.warp(block.timestamp + 20 days);
        stakedCPT.withdraw(balStaked, address(this), address(this));
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
