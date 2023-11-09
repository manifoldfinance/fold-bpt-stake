# BPT Staked

You can staked 80BAL-20WETH BPT or auraBAL to receive non-transferrable StakedBPT(ERC4626) shares and
receive rewards on L2 accordingly.

## Getting Started

### Install dependencies

```bash
yarn install
```

### Compile contracts

```bash
yarn build
```

### Bootstrap forks

```bash
yarn run lz:bootstrap -- --mnemonic <Your Mnemonic>
```

### Deploy contracts on forked networks

```bash
yarn run lz:deploy -- --mnemonic <Your Mnemonic>
```

### Run tests on forked networks

```bash
yarn run lz:test -- --mnemonic <Your Mnemonic>
```

## License

Distributed under the MIT License. See `LICENSE` for more information.

## Author

- [LevX](https://twitter.com/LEVXeth/)
