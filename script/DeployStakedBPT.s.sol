// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {StakedBPT} from "contracts/StakedBPT.sol";

contract DeployStakedBPTScript is Script {
    address constant bpt = 0xb3b675a9A3CB0DF8F66Caf08549371BfB76A9867; // Gyroscope ECLP mevETH/wETH
    address constant auraBal = 0xED2BE1c4F6aEcEdA9330CeB8A747d42b0446cB0F; // Gyroscope ECLP mevETH/wETH Aura Deposit
    address constant depositor = 0xA57b8d98dAE62B26Ec3bcC4a365338157060B234; // Booster
    // address constant pool = 0xF9b6BdC7fbf3B760542ae24cB939872705108399; // Gyroscope ECLP mevETH/wETH Aura Deposit Vault
    address constant treasury = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    uint256 constant minLockDuration = 30 days; // 1 month
    // address constant owner = 0x617c8dE5BdE54ffbb8d92716CC947858cA38f582; // Multisig
    uint256 constant pid = 170;
    bytes32 constant poolId =
        0xb3b675a9a3cb0df8f66caf08549371bfb76a9867000200000000000000000611;

    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant _vault = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    function run() public {
        address owner = tx.origin;
        vm.startBroadcast();
        new StakedBPT(
            bpt,
            auraBal,
            depositor,
            treasury,
            owner,
            minLockDuration,
            weth,
            _vault,
            pid,
            poolId
        );
        vm.stopBroadcast();
    }
}
