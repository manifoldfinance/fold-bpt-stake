#!/usr/bin/env bash

source .env

forge script script/DeployStakedBPT.s.sol:DeployStakedBPTScript \
    --chain-id 1 \
    --fork-url $RPC_MAINNET \
    -vvvvv