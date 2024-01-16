#!/usr/bin/env bash

source .env

forge script script/DeployStakedBPT.s.sol:DeployStakedBPTScript \
    --chain-id 1 \
    --rpc-url $RPC_MAINNET \
    --broadcast \
    --private-key $PRIVATE_KEY \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvvv