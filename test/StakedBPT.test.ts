import { Chain, SignerWithAddress } from "@lz-kit/cli"
import { getChain } from "hardhat"
import { IBasicRewards, ICrvDepositor, IERC20, StakedBPT } from "../typechain-types"
import { utils } from "ethers"
import { expect } from "chai"
import { getBlockTimestamp, setNextBlockTimestamp } from "./utils"

interface Context extends Mocha.Context {
    eth: Env
    opt: Env
}

interface Env extends Chain {
    deployer: SignerWithAddress
    alice: SignerWithAddress
    bob: SignerWithAddress
    carol: SignerWithAddress
    bpt?: IERC20
    auraBal?: IERC20
    crvDepositor?: ICrvDepositor
    stakedBPT?: StakedBPT
}
async function setup(chain: Chain) {
    const { name, getSigners, getContract, getContractAt, setBalance } = chain
    const networkName = name.endsWith("-fork") ? name.slice(0, -5) : name
    const [deployer, alice, bob, carol] = await getSigners()
    for (const signer of [deployer, alice, bob, carol]) {
        await setBalance(signer.address, utils.parseEther("10000"))
    }
    const env = {
        ...chain,
        deployer,
        alice,
        bob,
        carol,
    } as Env
    if (networkName == "ethereum") {
        env.bpt = (await getContractAt("IERC20", "0x5c6Ee304399DBdB9C8Ef030aB642B10820DB8F56")) as IERC20
        env.auraBal = (await getContractAt("IERC20", "0x616e8BfA43F920657B3497DBf40D6b1A02D4608d")) as IERC20
        env.crvDepositor = (await getContractAt(
            "ICrvDepositor",
            "0xeAd792B55340Aa20181A80d6a16db6A0ECd1b827"
        )) as ICrvDepositor
        env.stakedBPT = (await getContract("StakedBPT")) as StakedBPT
    }
    return env
}

describe("StakedBPT", function () {
    beforeEach(async function (this: Context) {
        this.opt = await setup(await getChain("optimism-fork"))
        this.eth = await setup(await getChain("ethereum-fork"))
    })

    afterEach(async function (this: Context) {
        await this.eth.snapshot.restore()
        await this.opt.snapshot.restore()
    })

    it("should depositBPT()", async function (this: Context) {
        const amount = utils.parseEther("0.01")
        await this.eth.bpt.connect(this.eth.deployer).transfer(this.eth.alice.address, amount)

        await this.eth.bpt.connect(this.eth.alice).approve(this.eth.stakedBPT.address, amount)
        await this.eth.stakedBPT.connect(this.eth.alice).depositBPT(amount, this.eth.alice.address)

        expect(await this.eth.stakedBPT.balanceOf(this.eth.alice.address)).to.eq(amount)
    })

    it("should deposit()", async function (this: Context) {
        const amount = utils.parseEther("0.01")
        await this.eth.crvDepositor.connect(this.eth.deployer).deposit(amount, true)
        expect(await this.eth.auraBal.balanceOf(this.eth.deployer.address)).to.eq(amount)

        await this.eth.auraBal.connect(this.eth.deployer).transfer(this.eth.alice.address, amount)

        await this.eth.auraBal.connect(this.eth.alice).approve(this.eth.stakedBPT.address, amount)
        await this.eth.stakedBPT.connect(this.eth.alice).deposit(amount, this.eth.alice.address)

        expect(await this.eth.stakedBPT.balanceOf(this.eth.alice.address)).to.eq(amount)
    })

    it("should harvest()", async function (this: Context) {
        const amount = utils.parseEther("0.01")
        await this.eth.bpt.connect(this.eth.deployer).transfer(this.eth.alice.address, amount)

        await this.eth.bpt.connect(this.eth.alice).approve(this.eth.stakedBPT.address, amount)
        await this.eth.stakedBPT.connect(this.eth.alice).depositBPT(amount, this.eth.alice.address)

        const pool = (await this.eth.getContractAt("IBasicRewards", await this.eth.stakedBPT.pool())) as IBasicRewards
        const rewardToken = (await this.eth.getContractAt("IERC20", await pool.rewardToken())) as IERC20

        const treasury = await this.eth.stakedBPT.treasury()
        const balance = await rewardToken.balanceOf(treasury)
        const { wait } = await this.eth.stakedBPT.connect(this.eth.bob).harvest()
        const { events } = await wait()
        expect(events.length).to.gte(3)

        const { user, reward } = pool.interface.parseLog(events[2]).args
        expect(user).to.eq(this.eth.stakedBPT.address)
        expect(await rewardToken.balanceOf(treasury)).to.eq(balance.add(reward))
    })

    it("should withdraw()", async function (this: Context) {
        const amount = utils.parseEther("0.01")
        await this.eth.bpt.connect(this.eth.deployer).transfer(this.eth.alice.address, amount)

        await this.eth.bpt.connect(this.eth.alice).approve(this.eth.stakedBPT.address, amount)
        await this.eth.stakedBPT.connect(this.eth.alice).depositBPT(amount, this.eth.alice.address)
        expect(await this.eth.stakedBPT.balanceOf(this.eth.alice.address)).to.eq(amount)

        await expect(
            this.eth.stakedBPT.connect(this.eth.alice).withdraw(amount, this.eth.alice.address, this.eth.alice.address)
        ).to.revertedWith("StakedBPT: locked")

        await setNextBlockTimestamp(this.eth.provider, (await getBlockTimestamp(this.eth.provider)) + 86400 * 7)
        await this.eth.stakedBPT
            .connect(this.eth.alice)
            .withdraw(amount, this.eth.alice.address, this.eth.alice.address)
        expect(await this.eth.stakedBPT.balanceOf(this.eth.alice.address)).to.eq(0)
    })
})
