// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {MarketplaceBase} from "./MarketplaceBase.sol";
import {VotingEscrowMarketplace} from "../src/VotingEscrowMarketplace.sol";
import {IVotingEscrowMarketplace} from "../src/IVotingEscrowMarketplace.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AdminTest is MarketplaceBase {
    function test_constructorSetsProtocolContractsAndBoundaryDurations() public view {
        assertEq(market.ve(), address(ve));
        assertEq(market.gov(), gov);
        assertEq(market.np(), address(np));
        assertEq(market.weth(), address(weth));
        assertEq(market.minimumDuration(), MIN_DURATION);
        assertEq(market.maximumDuration(), MAX_DURATION);
    }

    function test_setProtocolContractsUpdatesAllAddresses() public {
        address newVe = makeAddr("newVe");
        address newGov = makeAddr("newGov");
        address newNp = makeAddr("newNp");
        address newWeth = makeAddr("newWeth");

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.ProtocolContractsUpdated(newVe, newGov, newNp, newWeth);

        vm.prank(gov);
        market.setProtocolContracts(newVe, newGov, newNp, newWeth);

        assertEq(market.ve(), newVe);
        assertEq(market.gov(), newGov);
        assertEq(market.np(), newNp);
        assertEq(market.weth(), newWeth);
    }

    function test_setBoundaryDurationsUpdatesMinAndMax() public {
        uint256 newMin = 2 days;
        uint256 newMax = 14 days;

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.BoundaryDurationsUpdated(newMin, newMax);

        vm.prank(gov);
        market.setBoundaryDurations(newMin, newMax);

        assertEq(market.minimumDuration(), newMin);
        assertEq(market.maximumDuration(), newMax);
    }

    function test_setBoundaryDurationsAllowsEqualMinAndMax() public {
        uint256 duration = 7 days;

        vm.prank(gov);
        market.setBoundaryDurations(duration, duration);

        assertEq(market.minimumDuration(), duration);
        assertEq(market.maximumDuration(), duration);
    }

    function test_setPaymentTokenValidityAddsAndRemovesToken() public {
        MockERC20 dai = new MockERC20("Dai", "DAI");
        assertFalse(market.isValidPaymentToken(address(dai)));

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.PaymentTokenValidityUpdated(address(dai), true);

        vm.prank(gov);
        market.setPaymentTokenValidity(address(dai), true);
        assertTrue(market.isValidPaymentToken(address(dai)));

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.PaymentTokenValidityUpdated(address(dai), false);

        vm.prank(gov);
        market.setPaymentTokenValidity(address(dai), false);
        assertFalse(market.isValidPaymentToken(address(dai)));
    }

    function test_setPaymentTokenValidityIsIdempotentWhenUnchanged() public {
        assertTrue(market.isValidPaymentToken(address(usdc)));

        vm.recordLogs();
        vm.prank(gov);
        market.setPaymentTokenValidity(address(usdc), true);
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(market.isValidPaymentToken(address(usdc)));
    }

    function test_configureFeesStoresLimitsAndRates() public {
        uint256[5] memory limits = [uint256(2_000_000 ether), 800_000 ether, 300_000 ether, 80_000 ether, 2 ether];
        uint256[5] memory rates = [uint256(300), 240, 180, 120, 60];

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.FeesConfigured(
            limits[0], limits[1], limits[2], limits[3], limits[4], rates[0], rates[1], rates[2], rates[3], rates[4]
        );

        vm.prank(gov);
        market.configureFees(limits, rates);

        assertEq(market.feeLimitByTier(IVotingEscrowMarketplace.FeeTier.Black), limits[0]);
        assertEq(market.feeLimitByTier(IVotingEscrowMarketplace.FeeTier.Gold), limits[1]);
        assertEq(market.feeLimitByTier(IVotingEscrowMarketplace.FeeTier.Silver), limits[2]);
        assertEq(market.feeLimitByTier(IVotingEscrowMarketplace.FeeTier.Bronze), limits[3]);
        assertEq(market.feeLimitByTier(IVotingEscrowMarketplace.FeeTier.Blue), limits[4]);

        assertEq(market.feeRateByTier(IVotingEscrowMarketplace.FeeTier.Black), rates[0]);
        assertEq(market.feeRateByTier(IVotingEscrowMarketplace.FeeTier.Gold), rates[1]);
        assertEq(market.feeRateByTier(IVotingEscrowMarketplace.FeeTier.Silver), rates[2]);
        assertEq(market.feeRateByTier(IVotingEscrowMarketplace.FeeTier.Bronze), rates[3]);
        assertEq(market.feeRateByTier(IVotingEscrowMarketplace.FeeTier.Blue), rates[4]);
    }

    function test_onERC721ReceivedReturnsSelectorWhenCalledByVotingEscrow() public {
        vm.prank(address(ve));
        bytes4 selector = market.onERC721Received(address(0), address(0), 1, "");
        assertEq(selector, market.onERC721Received.selector);
    }

    function test_receiveAcceptsEther() public {
        uint256 amount = 1 ether;
        (bool success,) = address(market).call{value: amount}("");
        assertTrue(success);
        assertEq(address(market).balance, amount);
    }
}
