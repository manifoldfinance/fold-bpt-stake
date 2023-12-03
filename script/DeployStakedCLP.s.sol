// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {StakedCLP} from "contracts/StakedCLP.sol";

contract DeployStakedCLPScript is Script {
    address constant clp = 0x9b77bd0a665F05995b68e36fC1053AFFfAf0d4B5; // Curve.fi Factory Crypto Pool: mevETH/frxETH
    address constant cvxtoken = 0xEFD9bC8c4f341a7dA06835F1790118D8372BA033; // Curve.fi Factory Crypto Pool: mevETH/frxETH Convex Deposit
    address constant booster = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31; // Booster
    address constant pool = 0x9A767E19cD9E5c9eD8494281da409Be38Fc76015; // Rewrds pool
    address constant treasury = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    uint256 constant minLockDuration = 30 days; // 1 month
    uint256 constant pid = 261;

    function run() public {
        address owner = tx.origin;
        vm.startBroadcast();
        new StakedCLP(
            clp,
            cvxtoken,
            booster,
            treasury,
            owner,
            minLockDuration,
            pid
        );
        vm.stopBroadcast();
    }
}
