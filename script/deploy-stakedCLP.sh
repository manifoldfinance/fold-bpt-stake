#!/usr/bin/env bash

source .env

forge script script/DeployStakedCLP.s.sol:DeployStakedCLPScript \
    --chain-id 1 \
    --rpc-url $RPC_MAINNET \
    --broadcast \
    --private-key $PRIVATE_KEY \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvvv