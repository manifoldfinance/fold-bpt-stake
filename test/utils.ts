import { providers, utils } from "ethers"

export const getBlockTimestamp = async (provider: providers.JsonRpcProvider) => {
    return (await provider.getBlock("latest")).timestamp
}

export const setNextBlockTimestamp = async (provider: providers.JsonRpcProvider, timestamp: number) => {
    await provider.send("evm_setNextBlockTimestamp", [utils.hexValue(timestamp)])
}
