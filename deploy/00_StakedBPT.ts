import "hardhat-deploy"
import { HardhatRuntimeEnvironment } from "hardhat/types"

// const BPT = "0x5c6Ee304399DBdB9C8Ef030aB642B10820DB8F56"
// const AURA_BAL = "0x616e8BfA43F920657B3497DBf40D6b1A02D4608d"
// const CRV_DEPOSITOR = "0xeAd792B55340Aa20181A80d6a16db6A0ECd1b827"
// const BASE_REWARD_POOL = "0x00A7BA8Ae7bca0B10A32Ea1f8e2a1Da980c6CAd2"
// const TREASURY = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045" // TODO: change
const BPT = "0xb3b675a9A3CB0DF8F66Caf08549371BfB76A9867"
const AURA_BAL = "0xED2BE1c4F6aEcEdA9330CeB8A747d42b0446cB0F"
const CRV_DEPOSITOR = "0xA57b8d98dAE62B26Ec3bcC4a365338157060B234"
const BASE_REWARD_POOL = "0xF9b6BdC7fbf3B760542ae24cB939872705108399"
const TREASURY = "0x617c8dE5BdE54ffbb8d92716CC947858cA38f582" // TODO: change

const MIN_LOCK_DURATION = 7 * 24 * 60 * 60 // 1 week
const pid = 170

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
        args: [BPT, AURA_BAL, CRV_DEPOSITOR, BASE_REWARD_POOL, TREASURY, MIN_LOCK_DURATION, deployer, pid],
        deterministicDeployment: true,
        log: true,
    })
}
