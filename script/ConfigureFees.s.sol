// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {console} from "forge-std/console.sol";

import {VotingEscrowMarketplace, IVotingEscrowMarketplace} from "../build/VotingEscrowMarketplace.sol";

contract ConfigureFees is Script, Config {
    function run() public {
        _loadConfig("./config/deployments.toml", false);

        uint256 tier1Limit = config.get("tier1Limit").toUint256(); // locked >= 1m
        uint256 tier2Limit = config.get("tier2Limit").toUint256(); // locked >= 500k
        uint256 tier3Limit = config.get("tier3Limit").toUint256(); // locked >= 200k
        uint256 tier4Limit = config.get("tier4Limit").toUint256(); // locked >= 50k
        uint256 tier5Limit = config.get("tier5Limit").toUint256(); // locked >= 1

        uint256 tier1Rate = config.get("tier1Rate").toUint256(); // 100 bps == 1%
        uint256 tier2Rate = config.get("tier2Rate").toUint256(); // 50 bps == 0.5%
        uint256 tier3Rate = config.get("tier3Rate").toUint256(); // 20 bps == 0.2%
        uint256 tier4Rate = config.get("tier4Rate").toUint256(); // 10 bps == 0.1%
        uint256 tier5Rate = config.get("tier5Rate").toUint256(); // 5 bps == 0.05%

        address vem = config.get("vem").toAddress();

        uint256[5] memory feeLimits;
        uint256[5] memory feeRates;

        feeLimits[0] = tier1Limit;
        feeLimits[1] = tier2Limit;
        feeLimits[2] = tier3Limit;
        feeLimits[3] = tier4Limit;
        feeLimits[4] = tier5Limit;

        feeRates[0] = tier1Rate;
        feeRates[1] = tier2Rate;
        feeRates[2] = tier3Rate;
        feeRates[3] = tier4Rate;
        feeRates[4] = tier5Rate;

        vm.startBroadcast();
        IVotingEscrowMarketplace(vem).configureFees(feeLimits, feeRates);
        vm.stopBroadcast();

        console.log("Fee Tier 0: ", IVotingEscrowMarketplace(vem).feeLimitByTier(IVotingEscrowMarketplace.FeeTier(0)));
        console.log("Fee Tier 1: ", IVotingEscrowMarketplace(vem).feeLimitByTier(IVotingEscrowMarketplace.FeeTier(1)));
        console.log("Fee Tier 2: ", IVotingEscrowMarketplace(vem).feeLimitByTier(IVotingEscrowMarketplace.FeeTier(2)));
        console.log("Fee Tier 3: ", IVotingEscrowMarketplace(vem).feeLimitByTier(IVotingEscrowMarketplace.FeeTier(3)));
        console.log("Fee Tier 4: ", IVotingEscrowMarketplace(vem).feeLimitByTier(IVotingEscrowMarketplace.FeeTier(4)));
    }
}
