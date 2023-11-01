import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { endpoint } from "@lz-asia/lz-constants/constants/layerzero.json";

module.exports = async ({ getNamedAccounts, deployments, network }: HardhatRuntimeEnvironment) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    let networkName = network.name;
    if (networkName.endsWith("-fork")) {
        networkName = networkName.substring(0, networkName.length - 5);
    }
    await deploy("ShuttleTerminal", {
        from: deployer,
        args: [endpoint[networkName]],
        deterministicDeployment: true,
        log: true,
    });
};
