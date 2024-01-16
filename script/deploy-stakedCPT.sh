#!/usr/bin/env bash

source .env

forge script script/DeployStakedCPT.s.sol:DeployStakedCPTScript \
    --chain-id 1 \
    --rpc-url $RPC_MAINNET \
    --broadcast \
    --private-key $PRIVATE_KEY \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvvv