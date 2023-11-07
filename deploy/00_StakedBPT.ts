import "hardhat-deploy"
import { HardhatRuntimeEnvironment } from "hardhat/types"

const BPT = "0x5c6Ee304399DBdB9C8Ef030aB642B10820DB8F56"
const AURA_BAL = "0x616e8BfA43F920657B3497DBf40D6b1A02D4608d"
const CRV_DEPOSITOR = "0xeAd792B55340Aa20181A80d6a16db6A0ECd1b827"
const BASE_REWARD_POOL = "0x00A7BA8Ae7bca0B10A32Ea1f8e2a1Da980c6CAd2"
const TREASURY = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045" // TODO: change
const MIN_LOCK_DURATION = 7 * 24 * 60 * 60 // 1 week

module.exports = async ({ getNamedAccounts, deployments, network }: HardhatRuntimeEnvironment) => {
    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    let networkName = network.name
    if (networkName.endsWith("-fork")) {
        networkName = networkName.substring(0, networkName.length - 5)
    }
    if (networkName != "ethereum") return

    await deploy("StakedBPT", {
        from: deployer,
        args: [BPT, AURA_BAL, CRV_DEPOSITOR, BASE_REWARD_POOL, TREASURY, MIN_LOCK_DURATION, deployer],
        deterministicDeployment: true,
        log: true,
    })
}
