// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {StakedCPT} from "contracts/StakedCPT.sol";

contract DeployStakedCLPScript is Script {
    address constant clp = 0x9b77bd0a665F05995b68e36fC1053AFFfAf0d4B5; // Curve.fi Factory Crypto Pool: mevETH/frxETH
    address constant cvxtoken = 0xEFD9bC8c4f341a7dA06835F1790118D8372BA033; // Curve.fi Factory Crypto Pool: mevETH/frxETH Convex Deposit
    address constant booster = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31; // Booster
    address constant pool = 0xF1B0382A141040601Bd4c98Ee1A05b44A7392A80; // Curve pool
    address constant treasury = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    uint256 constant minLockDuration = 30 days; // 1 month
    uint256 constant pid = 261;
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() public {
        address owner = tx.origin;
        vm.startBroadcast();
        new StakedCPT(
            clp,
            cvxtoken,
            booster,
            treasury,
            owner,
            minLockDuration,
            weth,
            pid,
            pool
        );
        vm.stopBroadcast();
    }
}
