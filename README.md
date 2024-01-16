# Balancer and Curve Pool Token (PT) Staker

### Staking mevETH and FOLD

Source code for 2 Staker contracts herein:

1. [StakerBPT](./contracts/StakedBPT.sol) - Balancer LP staked in Aura, earns AUR and BAL rewards
   - provides zapping directly from base token (eg mevETH and FOLD)
2. [StakerCPT](./contracts/StakedCPT.sol) - Curve LP staked in Convex, earns CRV and CVX rewards
   - provides zapping directly from base token (eg mevETH and FOLD)

Both contracts inherit from [StakerPT](./contracts/StakedPT.sol) which is an ERC4626 vault that manages staking and unstaking in return for the non-transferable vault token. A minimum lock-up time is enforced (initially set to 1 month).

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
