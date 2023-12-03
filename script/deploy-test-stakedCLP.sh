#!/usr/bin/env bash

source .env

forge script script/DeployStakedCLP.s.sol:DeployStakedCLPScript \
    --chain-id 1 \
    --fork-url $RPC_MAINNET \
    -vvvvv