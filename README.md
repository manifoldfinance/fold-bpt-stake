# Balancer and Curve Pool Token (PT) Staker

### Staking mevETH and FOLD

Source code for 2 Staker contracts herein:

1. [StakerBPT](./contracts/StakedBPT.sol) - Balancer LP staked in Aura, earns AUR and BAL rewards
   - provides zapping directly from base token (eg mevETH and FOLD)
2. [StakerCPT](./contracts/StakedCPT.sol) - Curve LP staked in Convex, earns CRV and CVX rewards
   - provides zapping directly from base token (eg mevETH and FOLD)

Both contracts inherit from [StakerPT](./contracts/StakedPT.sol) which is an ERC4626 vault that manages staking and unstaking in return for the non-transferable vault token. A minimum lock-up time is enforced (initially set to 1 month).

1. [StakerUPT](./contracts/StakedUPT.sol) - This is a Uniswap V3 LP vault. The contract does not use the ERC4626 standard because that standard deals with ERC20 tokens...UniV3 LP shares are NFTs.
   - When instantiating the contract, msg.sender is used as the owner. Make sure to top-up the contract's WETH balance (for paying out rewards).
   - In the frontend, use [getLiquidityPositions.js](./contracts/StakedCPT.sol) to get the IERC721 tokenIds for a user's LP position(s). The script is hardcoded to query the FOLD<>USDC, and FOLD<>WETH pools. Pass in the corresponding LP owner address (must be lower-cased) to the query. If you omit the owner field, it will return all positions for the pool.
     - The tokenIds are necessary to pass in as parameters to `deposit` or `withdraw` in the vault (StakeUPT).
   - Also, in the frontend, require the user to sign a transaction on the `NonfungiblePositionManager`
     - NonfungiblePositionManager is an IERC721. It has an `approve` function. Use it to give the StakeUPT contract infinite approval to transfer LP tokens on behalf of the user.

## Setup

Originally built with hardhat. Foundry is currently being used.

### Create `.env` from `.env.example`

```bash
cp .env.example .env
```

**Fill in values**

### Install dependencies

```bash
yarn install
```

### Compile contracts

```bash
forge build
```

### Run tests

Currently tests for mevEth/sfrxEth convex pool and mevEth/weth balancer gyro pool

```bash
forge test -vvv
```

### Deploy contracts

```bash
./script/deploy-stakedBPT.sol
./script/deploy-stakedCPT.sol
```

## License

Distributed under the MIT License. See `LICENSE` for more information.

## Author

- [Manifold](https://twitter.com/foldfinance/)
- [LevX](https://twitter.com/LEVXeth/)
