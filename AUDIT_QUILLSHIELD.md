# Audit QuillShield 16 Sep 2026

## Critical

None

## High

### QA-H-001: Missing price commitment in fulfill functions - front-running possible

### QA-H-002: Reentrancy is possible in createOffering because flash-stamp occurs after function body is invoked in modifier

### QA-H-003: Failsafe not implemented for ERC-20 tokens that may implement ERC-777 or don't return true (causing safeTransfer to fail), bricking auctions

## Medium

### QA-M-001: Treasury receives NFT or ether in case of receive/onERC721Received hook misimplementation, comments claim otherwise

### QA-M-002: (See QA-H-002) createOffering: Reentrancy is possible as flash-stamp doesn't prevent it

## Low

### QA-L-001: Fee calculation can overflow if auction bid is too high (gross * rate = fee)

### QA-L-002: Zero reserve price can cause unlimited 0 bids until someone bids 1 wei

## Informational

None
