# VotingEscrowMarketplace Audit Report

**Target:** `src/VotingEscrowMarketplace.sol`  
**Solidity:** `0.8.27`  
**Severity guide:** `severity-rubric.md`

## Summary (initial sweep)

| Severity       | Count |
| -------------- | ----- |
| Critical       | 7     |
| High           | 3     |
| Medium         | 4     |
| Low            | 5     |
| Informational  | 6     |

## Summary (after fix validation + second sweep)

| Severity       | Count (new this sweep) |
| -------------- | ---------------------- |
| Critical       | 4                      |
| High           | 2                      |
| Medium         | 2                      |
| Low            | 2                      |
| Informational  | 8                      |

## Summary (third validation)

| Outcome                         | Count |
| ------------------------------- | ----- |
| Resolved: yes                   | 36    |
| Resolved: no but acknowledged   | 6     |
| Resolved: no (still open)       | 1     |
| New residual findings (sweep 3) | 4     |

## Summary (fourth validation — against BUG/NOTE tags)

| Outcome                         | Count |
| ------------------------------- | ----- |
| Prior findings now resolved     | M-7, L-8, L-9, I-8, I-15 (and I-16 partially) |
| Still open / incomplete         | C-9, I-16 |
| Acknowledged (unchanged)        | M-3, I-5, I-6, I-10, I-11, I-13 |
| New findings this sweep         | 3 (C-12, M-8, I-17) |

**Verdict (fourth):** Tagged fixes for **M-7**, **L-8**, **L-9**, and stale-comment items checked out; **C-9** / **I-16** were incomplete pending payable wrap.

## Summary (fifth validation — recent C-12 / M-8 patches)

| Outcome                    | Status |
| -------------------------- | ------ |
| C-12                       | **yes** — `createOffering` is `payable`; `_wrapEtherFor` enforces `msg.value` |
| C-9 / I-16 (offering path) | **yes** — wrap at create + `transferFrom` on fulfill |
| I-17                       | **yes** — comments say `Open` |
| M-8                        | **no** — exception condition is logically inverted (still reverts) |
| New                        | **M-9** — non-WETH `createOffering` can accept and trap ETH |

**Verdict (fifth):** Offering ETH flow fixed; listing WETH exception was still wrong; non-WETH payable create could trap ETH.

## Summary (sixth validation — latest M-8 / M-9 patches)

| Finding | Resolved | Notes |
| ------- | -------- | ----- |
| M-8 | **yes** | `_marketOrderStatus` skips allowance when `paymentToken == weth` |
| M-9 | **yes** | non-WETH `createOffering` reverts on `msg.value > 0` |
| New L-10 | **no** | WETH **offerings** also skip allowance status → false `Open`; fulfill fails later on `transferFrom` |
| New I-18 | **no** | Stale TODO / C-9 NOTE still imply offering WETH needs status-level approval |

**Verdict (sixth):** M-8/M-9 fixed; WETH allowance skip was too broad for offerings (**L-10**).

## Summary (seventh validation — L-10 / I-18 patches)

| Finding | Resolved | Notes |
| ------- | -------- | ----- |
| L-10 | **yes** | `MarketOrderKind`; allowance skipped only for `weth && Listing` |
| I-18 | **yes** | Comments updated to match listing-only WETH skip |
| Open Critical / High / Medium | **none** | |
| Still acknowledged only | M-3, I-5, I-6, I-10, I-11, I-13 | Domain/trust/docs |

**Verdict:** All actionable audit findings are resolved or explicitly acknowledged. No new Critical/High/Medium issues found in this pass.

---

## Critical

### C-1: Order/auction storage writes to dynamic arrays without `push` — all creation paths revert

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes

Storage is now nested mappings (`tokenId => index => order/auction`) with 1-based indices, so creation writes no longer depend on dynamic-array `push` / length.

**Also appears elsewhere:** Listings, offerings, and auctions all use the same mapping pattern.

---

### C-2: Missing `IERC721Receiver` — auction custody via `safeTransferFrom` always fails

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes

`onERC721Received` is implemented and restricted to `msg.sender == ve`.

**Also appears elsewhere:** All custody moves go through `_transferToken` → `safeTransferFrom`.

---

### C-3: `AuctionStatus.Active` never progresses — bids permanently lock NFT and funds

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes

Post-deadline `Active` → `Complete`, `Pending` → `Expired` in `_auctionStatus`.

**Also appears elsewhere:** Shared by `cancelAuction`, `auctionBid`, `settleAuction`.

---

### C-4: Outbid auction participants are never refunded

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes

Refund runs only when status is already `Active` (i.e. there is a previous bidder), before overwriting bid state:

```611:613:src/VotingEscrowMarketplace.sol
        if (_status == AuctionStatus.Active) {
            _transferPaymentOut(_auction.paymentToken, _auction.highestBidder, _auction.highestBid);
        }
```

**Also appears elsewhere:** Only `auctionBid` escrows competing bids.

---

### C-5: `cancelAuction` marks canceled but never returns the escrowed NFT

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes

Pending cancel returns the NFT to the seller.

**Also appears elsewhere:** Expired settle also returns the NFT.

---

### C-6: Native ETH / WETH payment path is comprehensively broken

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes

`deposit{value:}`, `receive()`, and payable `auctionBid` / `fulfillOffering` / `fulfillListing` are in place.

**Also appears elsewhere:** Centralized in `_transferPaymentIn` / `_transferPaymentOut`. Residual allowance gate tracked under **C-9**.

---

### C-7: Successful auction settlement would double-charge the winner

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes

Settle pays from escrow only (fee + seller net); no second `transferFrom` / `msg.value` pull.

**Also appears elsewhere:** Listing/offering pulls once in `_executeTokenSwap`.

---

## High

### H-1: Lock-amount validity check is inverted (and mislabeled)

**Impact:** High  
**Likelihood:** Medium  
**Severity:** High  
**Resolved:** yes

Comparisons now match documented buyer protection:

```745:748:src/VotingEscrowMarketplace.sol
        else if (_marketOrder.snapshotAmount > _lockedAmountNow) {
            _status = MarketOrderStatus.LockAmountDecreased;
        } else if (_marketOrder.snapshotEnd < _lockedEndNow) {
            _status = MarketOrderStatus.LockEndIncreased;
        }
```

**Also appears elsewhere:** Shared `_marketOrderStatus` for listings and offerings.

---

### H-2: Anyone can cancel the first auction for a token (`index == 0`)

**Impact:** Medium–High  
**Likelihood:** High  
**Severity:** High  
**Resolved:** yes

`msg.sender != _auction.seller` reverts with `OnlyOwner`.

**Also appears elsewhere:** Cancel-only equality check; bid/settle still key off `_seller` argument (see residual **L-9**).

---

### H-3: Creating a new listing/offering orphans the previous one as still `Open`

**Impact:** Medium  
**Likelihood:** High  
**Severity:** High  
**Resolved:** yes

Create paths delete a prior `Open` order for the same creator when `_existingIndex != 0`, and mapping storage aligns with 1-based indices (**C-8**).

**Also appears elsewhere:** Both `createListing` and `createOffering`. Auctions still do not auto-clear listings — see **M-7**.

---

## Medium

### M-1: Default index `0` lets `delist` / `fulfillListing` / `rescind` / `fulfillOffering` hit the wrong order

**Impact:** Medium  
**Likelihood:** Medium  
**Severity:** Medium  
**Resolved:** yes

1-based counters mean real orders live at index `>= 1`. Fulfill paths also require `creator` match (`OnlySeller` / `OnlyBuyer`), so index `0` empty structs cannot be executed as another party’s order.

**Also appears elsewhere:** Residual: `delist` / `rescind` still succeed with index `0` and write status on the unused slot — **L-8**.

---

### M-2: Accidental ETH sent with ERC-20 `fulfillListing` is trapped

**Impact:** High  
**Likelihood:** Low  
**Severity:** Medium  
**Resolved:** yes

Non-WETH `_transferPaymentIn` reverts on `msg.value > 0`.

**Also appears elsewhere:** Shared by all payable payment entrypoints.

---

### M-3: Auctions never validate KeyGen attachment

**Impact:** Medium  
**Likelihood:** Medium  
**Severity:** Medium  
**Resolved:** no but acknowledged  

Checked on `createAuction`. Bid/cancel/settle notes state escrowed tokens cannot be attached to a node (domain assumption).

**Also appears elsewhere:** Listings/offerings still enforce KeyGen at fulfill via `_marketOrderStatus`.

---

### M-4: No reentrancy guard around payment + NFT swap

**Impact:** Medium  
**Likelihood:** Low–Medium  
**Severity:** Medium  
**Resolved:** yes

`nonReentrant` on `fulfillListing`, `fulfillOffering`, `auctionBid`, and `settleAuction`.

**Also appears elsewhere:** ETH `.call` payouts remain; guards cover the external entrypoints that use them.

---

## Low

### L-1: `ListingFulfilled` / `OfferingFulfilled` emit fee and net swapped

**Impact:** Low  
**Likelihood:** High  
**Severity:** Low  
**Resolved:** yes

Events emit `(_price, _net, _fee)` per ABI.

---

### L-2: `configureFees` does not validate tier ordering or rate bounds

**Impact:** Medium  
**Likelihood:** High  
**Severity:** Low  
**Resolved:** yes

Limits must be strictly decreasing and non-zero; `_ratesBps[i] >= 10_000` reverts. See also **C-10**.

---

### L-3: ETH payouts use `transfer` (2300 gas), breaking contract recipients

**Impact:** Low  
**Likelihood:** Medium  
**Severity:** Low  
**Resolved:** yes

Uses `.call{value:}` with success checks.

---

### L-4: First auction bid must exceed `minimumBidIncrement` above zero

**Impact:** Low  
**Likelihood:** Medium  
**Severity:** Low  
**Resolved:** yes

Increment enforced only when `highestBid != 0`.

---

### L-5: `settleAuction` never writes terminal `Sold` status; Expired path is not idempotent-safe

**Impact:** Low  
**Likelihood:** Medium  
**Severity:** Low  
**Resolved:** yes

Writes `Expired` / `Sold`; repeat settle of already-expired is rejected.

---

## Informational

### I-1: `_validateSnapshot` is dead code and contradicts its comments

**Resolved:** yes  

Removed (commented out).

---

### I-2: `BidTooLow` error is declared but never used

**Resolved:** yes  

Removed.

---

### I-3: `_flashStamp` is public despite underscore naming

**Resolved:** yes  

`internal` visibility. Auction flash stamps were later removed intentionally (**I-10**).

---

### I-4: `_marketOrderStatus` overwrites statuses without priority

**Resolved:** yes  

`if` / `else if` chain with expiration first.

---

### I-5: Centralization / trust assumptions

**Resolved:** no but acknowledged  

DAO-controlled governance notes retained.

---

### I-6: Offerings do not escrow bid funds at creation

**Resolved:** no but acknowledged  

Documented as enforced at swap time.

---

## Notes for remediation (from initial sweep)

Historical. Most items closed in later validations; see third sweep for residuals.

---

# Second sweep (post-fix validation)

Findings from the prior incomplete-fix review. Statuses below reflect **current** code.

---

## Critical (second sweep)

### C-8: 1-based index mapping is misaligned with 0-based `push` storage

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes

Replaced arrays with `mapping(uint256 => mapping(uint256 => …))` so 1-based indices address the intended records directly (listings, offerings, auctions).

---

### C-9: WETH market orders blocked by ERC-20 allowance check in `_marketOrderStatus`

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes  

Offering path (tagged `BUG: C-9 & I-16` + `_from == msg.sender` branch) now matches the NOTE:

1. `createOffering` is `payable` and wraps `msg.value` to the offeror via `_wrapEtherFor` (see **C-12**).
2. `fulfillOffering` pulls WETH with `safeTransferFrom` (buyer ≠ `msg.sender`), so allowance is required and correctly enforced.

Listing WETH checkouts still go through `_marketOrderStatus` allowance and are handled under **M-8** (attempted exception is incorrect).

**Also appears elsewhere:** `_transferPaymentIn` WETH+`msg.sender` wrap used by listing fulfill and auction bid.

---

### C-10: `configureFees` rejects valid CTM tier floors by comparing limits to `10_000`

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes

`10_000` bound moved to `_ratesBps`; limits may be wei-scaled tier floors. **I-12** documents wei units.

---

### C-11: Premature order finalization before validation/swap (listings & offerings)

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes  

Marked fulfilled before swap is safe under EVM atomicity: any later `revert` rolls back the delete. Documented in NatSpec on `fulfillListing` / `fulfillOffering`.

---

## High (second sweep)

### H-4: Lock snapshot end/amount rules still opposite of documented buyer protection

**Impact:** High  
**Likelihood:** Medium  
**Severity:** High  
**Resolved:** yes  

Same fix as **H-1**.

---

### H-5: First ERC-20 auction bid can permanently DoS via refund-to-`address(0)`

**Impact:** High  
**Likelihood:** High  
**Severity:** High  
**Resolved:** yes  

Refund only on `Active` (same as **C-4**).

---

## Medium (second sweep)

### M-5: `settleAuction` still has no `nonReentrant` despite ETH `.call` payouts

**Impact:** Medium  
**Likelihood:** Medium  
**Severity:** Medium  
**Resolved:** yes  

`nonReentrant` added on `settleAuction`.

---

### M-6: Fulfil/delete helpers still do not bind `order.creator` to the supplied counterparty

**Impact:** Medium  
**Likelihood:** Medium  
**Severity:** Medium  
**Resolved:** yes  

`OnlySeller` / `OnlyBuyer` checks on fulfill paths.

---

## Low (second sweep)

### L-6: `AuctionSettled` emits pre-terminal status rather than `Sold`

**Impact:** Low  
**Likelihood:** High  
**Severity:** Low  
**Resolved:** yes  

`_auction.status = _status = AuctionStatus.Sold` before `AuctionSettled`.

---

### L-7: `onERC721Received` accepts any token; `msg.sender` is not restricted to `ve`

**Impact:** Low  
**Likelihood:** Low  
**Severity:** Low  
**Resolved:** yes  

`OnlyVotingEscrow` if `msg.sender != ve`.

---

## Informational (second sweep)

### I-7: US English — “fulfil” / “Fulfils” should be “fulfill” / “Fulfills”

**Resolved:** yes  

Renamed to `fulfillListing` / `fulfillOffering` with updated NatSpec.

---

### I-8: Typos in comments / NatSpec

**Resolved:** yes  

Prior typos addressed; remaining comment polish tracked under **I-15** / **I-17** (now also fixed or narrowed in fourth sweep).

---

### I-9: US English — “different to” → “different from”

**Resolved:** yes  

Error notices use “different from.”

---

### I-10: Flash stamp on `auctionBid` keys the seller, not the bidder

**Resolved:** no but acknowledged  

Flash stamps removed from auction create/bid/settle; note says not required for auctions.

---

### I-11: `receive()` is unrestricted

**Resolved:** no but acknowledged  

Documented: ETH should not be sent outside payable flows.

---

### I-12: Fee tier comments vs `configureFees` units are easy to misconfigure

**Resolved:** yes  

Note: limits are in wei, not whole CTM.

---

### I-13: Copy-paste / comment quality residues from bugfix annotations

**Resolved:** no but acknowledged  

File header: inline BUG/NOTE/TODO comments to be removed before production.

---

### I-14: Grammar — FeeTiers NatSpec

**Resolved:** yes  

Replaced with clearer wording (minor: “The Fee tiers” still capitalizes “Fee” awkwardly — optional polish).

---

# Third sweep (re-validation after claimed fixes)

Re-checked every item above against the current contract. New or residual items only.

---

## Medium (third sweep)

### M-7: `createAuction` does not clear an open listing for the same token

**Impact:** Medium  
**Likelihood:** Medium  
**Severity:** Medium  
**Resolved:** yes  

`BUG: M-7` — `createAuction` deletes an existing `Open` listing for `msg.sender` / `_tokenId` before escrow.

**Also appears elsewhere:** Same clear pattern as **H-3** on `createListing` / `createOffering`.

---

## Low (third sweep)

### L-8: `delist` / `rescind` do not reject missing orders (`index == 0`)

**Impact:** Low  
**Likelihood:** Low  
**Severity:** Low  
**Resolved:** yes  

`BUG: L-8` — both paths require stored status `Open`, otherwise `UnexpectedMarketOrderState`. Index `0` / `NonExistent` can no longer silently “succeed.”

**Also appears elsewhere:** Listing and offering cancel paths updated symmetrically.

---

### L-9: `auctionBid` / `settleAuction` do not assert `_auction.seller == _seller`

**Impact:** Low  
**Likelihood:** Low  
**Severity:** Low  
**Resolved:** yes  

`BUG: L-9` — both functions revert `OnlyOwner` when `_seller != _auction.seller` (same idea as cancel).

**Also appears elsewhere:** Aligns with listing/offering creator checks (**M-6**).

---

## Informational (third sweep)

### I-15: Stale fix comments (`incremement`, “Added push … array”)

**Resolved:** yes  

Comments now say “increment” and “Changed array to mapping…”.

---

### I-16: C-9 NatSpec describes unimplemented Offering ETH wrap-at-create flow

**Resolved:** yes  

Implemented in fifth validation (`payable` + `_wrapEtherFor`); see **C-9** / **C-12**.

---

# Fourth sweep (validate against BUG/NOTE tags)

Checked each remaining open item and the new tagged patches in-source.

---

## Critical (fourth sweep)

### C-12: `createOffering` WETH wrap is not payable and can spend contract ETH

**Impact:** High  
**Likelihood:** High  
**Severity:** Critical  
**Resolved:** yes  

`BUG: C-12`: `createOffering` is `payable`, and `_wrapEtherFor` now validates/refunds `msg.value` before `deposit{value: _amount}()`, so wrapping is funded by the caller rather than arbitrary contract balance.

**Also appears elsewhere:** `_transferPaymentIn` WETH path delegates to the same `_wrapEtherFor`. Residual: non-WETH `createOffering` does not reject stray `msg.value` — **M-9**.

---

## Medium (fourth sweep)

### M-8: `fulfillListing` with `weth` still requires WETH allowance while paying `msg.value`

**Impact:** Medium  
**Likelihood:** Medium  
**Severity:** Medium  
**Resolved:** yes  

Fixed in `_marketOrderStatus` by skipping the allowance gate when `paymentToken == weth`:

```782:782:src/VotingEscrowMarketplace.sol
        } else if (IERC20(_marketOrder.paymentToken).allowance(_buyer, address(this)) < _marketOrder.price && _marketOrder.paymentToken != weth) {
```

WETH listings can stay `Open` without approve and pay via `msg.value` on fulfill. Side effect on WETH offerings: see **L-10**.

**Also appears elsewhere:** Shared helper for `fulfillListing` and `fulfillOffering`.

---

## Informational (fourth sweep)

### I-17: L-8 comments say “Active” instead of `Open`

**Resolved:** yes  

Comments now say “only Open Listings/Offerings canceled.”

---

### I-16: C-9 NatSpec describes unimplemented Offering ETH wrap-at-create flow

**Resolved:** yes  

Wrap-at-create is implemented with payable + `_wrapEtherFor(msg.sender, _bid)`.

---

# Fifth sweep (re-check after C-12 / M-8 patches)

---

## Medium (fifth sweep)

### M-9: Non-WETH `createOffering` is payable but does not reject `msg.value`

**Impact:** High  
**Likelihood:** Low  
**Severity:** Medium  
**Resolved:** yes  

```478:480:src/VotingEscrowMarketplace.sol
        if (_paymentToken == weth) _wrapEtherFor(msg.sender, _bid);
        // BUG: M-9: Added revert for msg.value > 0 for non-ether Offerings
        else if (msg.value > 0) revert InvalidEtherAmount();
```

**Also appears elsewhere:** Matches `_transferPaymentIn` non-WETH stray-ETH guard (**M-2**).

---

# Sixth sweep (latest M-8 / M-9 patches)

---

## Low (sixth sweep)

### L-10: WETH offerings never surface `PaymentApprovalRequired`

**Impact:** Low  
**Likelihood:** Medium  
**Severity:** Low  
**Resolved:** yes  

`MarketOrder` now stores `MarketOrderKind`. Allowance is required unless both WETH **and** Listing:

```806:808:src/VotingEscrowMarketplace.sol
            (_marketOrder.paymentToken != weth || _marketOrder.kind != MarketOrderKind.Listing)
                && IERC20(_marketOrder.paymentToken).allowance(_buyer, address(this)) < _marketOrder.price
```

WETH offerings again report `PaymentApprovalRequired` when unapproved; WETH listings still skip approve for `msg.value` checkout.

**Also appears elsewhere:** `createListing` / `createOffering` set `kind` explicitly.

---

## Informational (sixth sweep)

### I-18: Stale TODO / C-9 NOTE after WETH allowance skip

**Resolved:** yes  

Tagged `BUG: L-10 & I18` comment states only `Listing + WETH` skips approval; C-9 NOTE retained for offering wrap/approve semantics.

---

# Seventh sweep (L-10 / kind-aware allowance)

Validated `MarketOrderKind` wiring and the allowance predicate above. Listing + WETH → no allowance gate; Offering + WETH → allowance gated; all ERC-20 → allowance gated. No further functional findings.

---

## Tag checklist (seventh validation)

| Tag | Validated |
| --- | --------- |
| L-10 / I-18 | **yes** |
| M-8 / M-9 / C-9 / C-12 | **yes** |
| All earlier Critical/High/Medium | **yes** or acknowledged |
| Remaining acknowledged | M-3, I-5, I-6, I-10, I-11, I-13 |

---

## Suggested fix priority (current codebase)

1. **I-13** — Remove inline BUG/NOTE/TODO comments before production (already acknowledged).  
2. Optional polish only — no open severity findings requiring code changes.

**Overall:** Marketplace audit items are closed pending acknowledged governance/docs notes and pre-production comment cleanup.
