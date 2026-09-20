#!/bin/bash

# remove old build files
rm -r build/

# create folders
mkdir -p build/

echo -e "\n📄 Flattening src/ to build/..."

# utils
forge flatten src/VotingEscrowMarketplace.sol --output build/VotingEscrowMarketplace.sol
