# Security Audit — `chain-payments-sui`

**Classification:** Internal security review (first pass, awaiting external review)
**Project:** chain-payments-sui  (`chain_payments` — exact, quoted payments to a merchant on Sui: permissionless merchants,
  `pay<T>` that verifies an ed25519 quote and takes exactly the quoted amount with the change returned in the same
  transaction, a per-merchant prepaid-period ledger, single-use nonces, `MerchantCap` governance with a recipient timelock;
  plus the publish script)
**Project type:** Move package (+ on-chain operations script)
**Template:** AUDIT_TEMPLATE.md (2026-11-01) + AUDIT_TEMPLATE_SUI.md (2026-09-28) + AUDIT_TEMPLATE_OPS.md (2026-10-08) +
  AUDIT_TEMPLATE_SUI_CLIENT.md (2026-10-08, applied only to the `publish.sh` PTBs and their output parsing)
**Package:** `chain_payments` `Move.toml` 0.0.1; edition 2024; framework rev `83f11dc85d5695a57894329b005b78d75f9bb059`
  (`Move.lock`, testnet); no other dependency
**Deployment status:**

| Network | Package (original-id = published-at) | Version | UpgradeCap | Status |
| --- | --- | --- | --- | --- |
| testnet | `0x5f67109c6b436fc0c0415d7f3e63ca10d374d8c4bb5e3b1f087cabb1c785bc14` | 1 | `0x3f6ec244c5807b4a241b02315b66073ebb1f2799c476a6e898748a453c54eea1` — **live**, `AddressOwner` `0xa991ae11…164864a` (the publisher EOA; GraphQL read 2026-11-17) | published 2026-11-16 (digest `aDjUeNf6NwNum6ZEyN3HTdzUQ6pEoAyMMcr6dccTVZV`), toolchain 1.81.0 |
| mainnet | — | — | — | unpublished (FU-0103) |

Merchants on testnet (`deployments.json`, read on-chain 2026-11-17, both `Shared`, `version` 1, not paused, no pending
recipient, recipient `0xa991…864a`):

- `0x29d6c7619957e0bde34becad3f8376eedd98f90f404b18915660dc3efc4b63f8` — Link in Bio (merchant #1 of the service); quote key
  `c80751d8…2e8c` (the service's key); accepts SUI at 1 000 000 MIST and native USDC
  (`a1ec7fc0…7e29::usdc::USDC`) at 1 000 per unit; `max_units` 12, `max_ahead_ms` 63 115 200 000; cap
  `0xc57f292e…87d0` held by `0xa991…864a`.
- `0x30b6d544652d35d4a481fa7e45adf8e514b9ae1596377e837b6fdf36d967dae8` — the throwaway TEST merchant (quote key = the public
  test key, seed `0x01`×32); accepts SUI at 1 MIST; 3 used nonces and 2 ledger entries from the live checks (F17).

**Review date:** 2026-11-17
**Reviewer:** Internal review
**Severity ceiling:** High — `pay<T>` moves the payer's coin on every purchase and the quote signature is the only price
  authority, so a signature, coin-type or accounting flaw would misprice or misroute every payment of every merchant. Realised
  ceiling at this pass: **Medium** (F5, the unwatched recipient timelock, DEFERRED).
**Status:** first-pass baseline

**CLI tools:** sui **1.81.0** (`suiup` 0.0.14 sha256-pinned and the installed `sui` binary sha256-checked in `move-ci.yml`),
  equal to `Published.toml` `toolchain-version = "1.81.0"`; `publish.sh` now hard-fails on a major.minor mismatch (F13).
  `jq` is required.
**Networks targetable:** `publish.sh`: localnet, testnet (chain id `4c78adac` checked), mainnet (chain id `35834a8a`,
  `EXPECTED_SIGNER` and `MAINNET_CONFIRM=1`).
**Key material:** the operator's local `sui` keystore (active address). **No keys in CI**: no workflow signs on a chain.

---

## Executive summary

`chain_payments` is one dependency-free Move module of 423 lines. A merchant is a shared object created by anyone; a
merchant's service signs short-lived quotes; `pay<T>` verifies the quote and moves exactly the quoted amount. The core
guarantees hold and are tested:

- **The quote message** is the domain tag `chain-payments:quote:v1` followed by the BCS of every field, the merchant object id
  first. The encoding is injective (fixed-width ids and u64s, length-prefixed vectors and strings). It binds the merchant, so
  a quote cannot be used at another merchant, on another network or under a republished package. It is byte-identical to the
  service's signer: the shared vectors match by `cmp`, and every vector is now asserted against `quote_message` itself (F9).
- **Replay.** Each nonce can be used once per merchant. A quote is usable only while `now < expires_ms ≤ now + 10 min`, so
  the window is ten minutes before expiry. Pruning is allowed only after expiry, when the quote can no longer pay anyway
  (F10).
- **Coin types.** `accepted` is keyed by `type_name::with_defining_ids<T>()`, and the same string is signed, so a look-alike
  coin from another package is refused (F11).
- **Change.** Exactly `amount` goes to the recipient and the rest back to the sender in the same transaction. A zero
  remainder is destroyed, and no path strands value (F12).
- **Minimums.** The minimum per unit is checked in u128 against `amount`, so a leaked quote key can sell only at or above the
  merchant's on-chain floor (F6). A zero floor is refused by the script, not by the package.
- **Capabilities.** Every governance entry checks that the cap is bound to the merchant and that the merchant's version is
  current. A new recipient waits two days.

**This pass fixed inline:**

- **F3:** the zero-address recipient is refused. This is in source and ships with the next upgrade.
- **F9:** every shared vector is asserted against `quote_message`.
- **F13:** the publish script was hardened (toolchain preflight, republish guard, exact-type object reads, effects checks,
  input validation, record-before-continue, resume commands).
- **F14:** a runbook was added.
- **F1:** `SECURITY.md` now carries the off-chain verifier contract and the missing sections.
- **F16:** Dependabot was added.

**Open, most important first:**

1. **F5 (Medium)** — the two-day recipient timelock protects only if someone notices a proposal. `MerchantUpdated` carries no
   detail, and nothing watches it yet (FU-0122; OQ1 for a detailed event).
2. **F2 (Low, mainnet-blocked)** — the UpgradeCap and merchant #1's `MerchantCap` are held by the publisher EOA. There is no
   `CUSTODY.md` and no custody tooling (FU-0120, FU-0103; OQ3).
3. **F19 (Low)** — the shared vectors have no negative cases (FU-0128).

**Dispositions (19 findings):** RESOLVED 6 · MITIGATED 1 · ADJUDICATED 3 · DEFERRED 3 · Positive 6.
**Counts by severity:** Medium 1 · Low 9 · Info 3 · Positive 6.

**Posture:** a small, carefully bounded contract. The trust boundary with the service is explicit and tested byte for byte.
The residual work is governance custody and monitoring, not contract logic.

## Threat model / trust boundaries

| Authority / actor | Holds / proves | Can do | Bounded by |
| --- | --- | --- | --- |
| Anyone (permissionless) | nothing | `create_merchant`, `pay<T>` with a valid quote (for any subscription reference: gifts), `prune_nonces` of expired nonces, every read | quote signature (8), expiry (2, 3), nonce (4), coin type (5), minimum (6), units (7, 18), identifier bounds (13), version (0), pause (1) |
| Merchant quote key (the service's ed25519 seed) | signs quotes | sell any accepted coin at any amount ≥ `min_per_unit × units`, for ≤ `max_units`, extending a reference by ≤ `max_ahead_ms` | the on-chain minimums and limits; rotation by `set_quote_key`; pause |
| `MerchantCap` holder | `MerchantCap { merchant_id }` | set key, accepted coins and minimums, limits, pause; propose, cancel and confirm a new recipient | `cap.merchant_id == id(merchant)` (11); version (0); **two-day recipient delay** (15); zero recipient refused (19, F3) |
| Package publisher | `UpgradeCap` | replace the code of every merchant's payments | custody undecided (F2, OQ3); version gating means an upgrade must also `migrate` (F4) |
| Off-chain verifier (chain-payments-service) | reads `Paid` by digest | credits a checkout session | its own binding tuple (B.5); full type match by original id |
| Operator running `publish.sh` | local keystore + active env | publish, create a merchant, accept coins | OPS preflight (below) |

**Primary trust anchor:** the merchant's quote key, as stored in the `Merchant` and bound into every quote message with the
merchant object id, plus the on-chain minimums that bound that key. The `MerchantCap` and the `UpgradeCap` are the authorities
over it.

### Capabilities & shared objects (Move lens)

| Object / type | Minted / created by | Holder / custodian | Authority it confers | Compromise / misuse impact | Immutability / rotation plan |
| --- | --- | --- | --- | --- | --- |
| `UpgradeCap` `0x3f6ec244…eea1` (testnet) | publish | publisher EOA `0xa991…864a` (read 2026-11-17) | replace package code | arbitrary payment logic for every merchant (e.g. pay without a quote) | undecided (OQ3); pre-mainnet blocking (F2, FU-0120) |
| `MerchantCap` (per merchant; `store`, transferable) | `create_merchant` (returned to the caller) | merchant #1: `0xa991…864a` (testnet) | key, coins, minimums, limits, pause, recipient (delayed) | rotate the key to its own and set the minimum to 1: give the product away; propose itself as recipient and, if unnoticed for two days, take every later payment | mainnet: the entity's multisig (FU-0103); alerting on proposals (F5, FU-0122) |
| `Merchant` (shared, `key` only) | `create_merchant` | shared | read by every `pay` | — (mutable only through its cap and by `pay`/`prune_nonces`) | version field for gating (F4) |
| `Clock` `0x6` (external) | system | shared, immutable reference | expiry and the recipient delay | none | n/a |

No `Publisher`, no `Display`, no platform-wide admin object: the package has no global authority except the UpgradeCap.

### Operations matrix (OPS lens)

| Actor / asset | Power | Bounded by |
| --- | --- | --- |
| Operator EOA / keystore (`0xa991…`) | signs the publish, merchant creation and coin acceptance | preflight: env, chain id, CLI toolchain (F13), `EXPECTED_SIGNER` on mainnet |
| CI runner | none: no workflow signs | — |
| Env variables the script reads | recipient, quote key, limits, minimums, USDC type | validated: full-form non-zero recipient, 64-hex key, positive integers, the exact `0x…::usdc::USDC` shape (F13) |
| CLI binary / installer | what executes | suiup and binary sha256-pinned in CI; toolchain checked against `Published.toml` |
| Operator's global CLI state | which network and signer | the script never switches env or address |
| Downstream consumers of written IDs | `deployments.json`, `Published.toml` | B.SC-1 trace below: the service's `methods.json` matches |

### Script inventory (OPS lens)

| Script / job | Signs? | Objects touched | Irreversible? | Dry-run default | Confirmation | Network guard | Writes IDs to |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `scripts/publish.sh <net>` | yes | new package + UpgradeCap | effectively (new ids) | no (no irreversible custody step exists yet) | none; mainnet `MAINNET_CONFIRM=1` + `EXPECTED_SIGNER`; `REPLACE_PUBLISHED=1` over a record | active env + chain id + toolchain | `deployments.json` (`packageId`, `upgradeCap`, `publishDigest`, `publisher`, `publishedAt`); `Published.toml` (by the CLI) |
| `publish.sh <net> --create-merchant` | yes (1 + one per coin) | new `Merchant` + `MerchantCap`; `set_accepted<T>` | no | no | as above | as above | `deployments.json` `merchants[]` (recorded before the coin steps) |
| `scripts/gen-test-vectors.py` | no (fixed TEST key) | — | — | — | — | — | `tests/vectors.{json,move}` |
| `.github/workflows/move-ci.yml` | no | — | — | — | — | — | — |

## Severity scale

Critical / High / Medium / Low / Info / Positive.

## Scope

**In scope (`main` = `356d286` plus this pass's changes):** `sources/chain_payments.move` (423 lines),
`tests/chain_payments_tests.move` (551 lines, 39 tests), `tests/vectors.{json,move}`, `scripts/{publish.sh,gen-test-vectors.py}`,
`Move.toml`, `Move.lock`, `Published.toml`, `deployments.json`, `.github/workflows/move-ci.yml`, `.github/dependabot.yml`,
`SECURITY.md`, `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md`.

**Cross-repo evidence (read-only):**

- `chain-payments-service`: `crates/core/src/quote.rs` (the signer), `fixtures/quote-vectors.json` and
  `crates/chain-sui/src/lib.rs` (the `Paid` verifier);
- `chain-payments-client/src/sui.ts` (the PTB);
- `post-bootstrap/chain-payments/overlays/default/files/methods.json` (the ids the service uses);
- `docs/architecture/ADR-0011-chain-payments.md`.

**Out of scope:** the Sui framework; the service, SDK and kit (their own audits).

**Environment / commands (2026-11-17):**

| Command | Result |
| --- | --- |
| `sui --version` | `sui 1.81.0-bf0c491c17b8` (the CI pin) |
| `sui move build --build-env testnet --lint --warnings-are-errors` | clean |
| `sui move test --build-env testnet --coverage` | **39 passed, 0 failed** (37 before this pass) |
| `sui move coverage summary --build-env testnet` | **100.00%** module coverage |
| `cmp chain-payments-service/fixtures/quote-vectors.json tests/vectors.json` | identical |
| `bash -n scripts/publish.sh`; the jq helpers run against synthetic short- and long-form object changes | clean; exact-type matching picks the right ids and refuses a look-alike package |
| `shellcheck` | **not run** (not installed in the review sandbox); CI runs `shellcheck -x -P SCRIPTDIR scripts/*.sh` on every push |
| GraphQL `graphql.testnet.sui.io` (read-only) | package `Immutable` v1; UpgradeCap and merchant #1's cap `AddressOwner 0xa991…`; both merchants' fields as in the front matter |

## Findings

### F1 — `SECURITY.md` lacked the off-chain verifier contract and three required sections

**Severity:** Low   **Disposition:** RESOLVED
**Where:** `SECURITY.md`.
**Issue:** The policy had Scope, Model and Reporting only. It did not have Supported versions or Disclosure (base template).
It also did not say what an off-chain verifier must check, though the chain deliberately knows nothing about sessions (Sui
lens MUST: "document, in `SECURITY.md` and the audit, what off-chain verifiers are responsible for").
**Impact:** An integrator writing a second verifier could match the `Paid` event by suffix, or skip fields. The
gateway's 2026-10 forged-consume bug was exactly this.
**Remediation / evidence:** `SECURITY.md` now states the verifier contract. A verifier reads the transaction by digest,
requires successful effects, and matches the full type `<original id>::chain_payments::Paid`. It then compares the merchant
id, session, nonce, coin type, amount, units and reference, and treats the nonce as single-use itself. The policy also gains
Supported versions and Disclosure, and records that a minimum is never zero.

### F2 — Upgrade and merchant authority held by the publisher EOA; no custody record or tooling

**Severity:** Low   **Disposition:** DEFERRED (mainnet-blocked; FU-0120, FU-0103; OQ3 decided: fresh package, cap burned)
**Where:** `deployments.json` (`publisher`, `upgradeCap`, `merchants[].merchantCap`); `scripts/publish.sh` header ("transfer
it to the entity's multisig afterwards, CUSTODY.md").
**Issue:** On testnet, the UpgradeCap `0x3f6ec244…` and merchant #1's `MerchantCap` `0xc57f292e…` are owned by
`0xa991…864a` (read on-chain). The script points at a `CUSTODY.md` that does not exist. No script transfers the caps or
burns the UpgradeCap, and the package's intended upgrade policy is not written down.
**Impact:** Testnet only today. On mainnet, a single key could replace the payment code (the UpgradeCap) or redirect
merchant #1 after the delay (the MerchantCap).
**Remediation / evidence:**

- Before mainnet, decide the policy (OQ3). The `VERSION` field suggests upgradeable under a multisig; access-gate-sui's
  model is multisig, then a verification window, then a burn.
- Write `CUSTODY.md`.
- Add `transfer-authority.sh` (UpgradeCap and MerchantCap; dry run by default, typed confirmation, mainnet double guard,
  re-read of the new owner) and, if the policy is a burn, `make-immutable.sh`, on access-gate-sui's pattern.
- Tracked in FU-0120; the mainnet publish itself is FU-0103.

### F3 — The zero address was accepted as a recipient

**Severity:** Low   **Disposition:** RESOLVED (in source; ships with the next upgrade, FU-0121)
**Where:** `sources/chain_payments.move::create_merchant` (`:146`) and `::propose_recipient` (`:386`).
**Issue:** `create_merchant(@0x0, …)` and `propose_recipient(…, @0x0, …)` were accepted. Every later payment would then go
to an address with no key.
**Impact:** A misconfigured merchant would make its payers' coins unrecoverable. The payers are third parties, so the
merchant's mistake costs them.
**Remediation / evidence:**

- Both functions now `assert!(recipient != @0x0, EBadRecipient)`, a new code 19. Signatures are unchanged and the change is
  upgrade-compatible.
- Tests: `a_merchant_cannot_pay_the_zero_address` and `the_zero_address_cannot_be_proposed`.
- `publish.sh` refuses a short-form or zero `MERCHANT_RECIPIENT` (F13).
- Both testnet merchants have a non-zero recipient (read on-chain), so the deployed v1 code is not exposed today.
- This follows access-gate-sui's OQ12 decision.

### F4 — Version gating without a `migrate`

**Severity:** Info   **Disposition:** ADJUDICATED (the first upgrade that bumps `VERSION` must add it; FU-0121)
**Where:** `VERSION` (`:43`); `pay` (`:212`) and `check_cap` (`:328`) require `merchant.version == VERSION`.
**Issue:** The comment says the version is "bumped with a `migrate` at a behaviour-changing upgrade", but no `migrate`
exists yet.
**Impact:** None today. If an upgrade bumps `VERSION` without a cap-gated `migrate(cap, merchant)`, every existing merchant
refuses the new code. The old package's code keeps serving them, because v1 code accepts v1 merchants, so the upgrade would
retire nothing.
**Remediation / evidence:** Adding a public function is upgrade-compatible. The upgrade that first bumps `VERSION` adds
`migrate(cap: &MerchantCap, merchant: &mut Merchant)`: it checks the cap binding, sets `merchant.version = VERSION`, and
is tested on a v1 merchant. That upgrade is recorded in FU-0121.

### F5 — The recipient timelock protects only if a proposal is noticed, and nothing watches

**Severity:** Medium   **Disposition:** DEFERRED (FU-0122, the watcher; OQ1 decided: typed events, in source)
**Where:** `propose_recipient` (`:384`) emits `MerchantUpdated { what: b"recipient_proposed" }`, which carries no address.
Neither the service nor the alert rules (`k8s/…/vmalert/rules/alerts.yaml`, group `chain-payments`) read the merchant
object.
**Issue:** The two-day delay is the package's defence against a stolen `MerchantCap`. The thief proposes, waits and
confirms. Nobody is told: the event says only that a proposal happened, and no monitor reads `pending_recipient`.
**Impact:** A cap holder's key compromise, unnoticed for two days, redirects every later payment of that merchant. Each
payment is still exactly the quoted amount, but it goes to the thief.
**Remediation / evidence:**

- Mitigation available now, without an upgrade: a watcher reads each registry merchant's `recipient` and
  `pending_recipient` and alerts when either differs from the configured value. Candidates are a worker duty in the service
  or a vmalert rule on an exported gauge.
- The service should also refuse to quote while a merchant has a pending recipient it does not expect.
- A `RecipientProposed { merchant_id, recipient, effective_ms }` event (and `QuoteKeyChanged`) would make indexers see the
  address. It is a new public struct, so it is an interface addition shipped by an upgrade: OQ1.
- Tracked in FU-0122.

### F6 — A leaked quote key is bounded only by the merchant's minimum, which the package lets be zero

**Severity:** Low   **Disposition:** MITIGATED
**Where:** `pay` (`:229`) `amount ≥ min_per_unit × units` (u128); `set_accepted<T>` (`:341`) accepts any `min_per_unit`.
**Issue:** The minimum is the only on-chain bound on what a leaked quote key can sell. `set_accepted` accepts 0.
**Impact:** With a zero minimum, a leaked key gives away subscriptions (a zero-value split to the recipient). Payers'
funds are not at risk.
**Remediation / evidence:**

- `publish.sh` refuses a non-positive `SUI_MIN_PER_UNIT` or `USDC_MIN_PER_UNIT` (F13), and `SECURITY.md` states the rule.
- Merchant #1's testnet minimums are 1 000 000 MIST and 1 000 USDC units (read on-chain).
- 2026-11-17: `set_accepted` now refuses zero on-chain (OQ2; test `a_zero_minimum_is_refused`).
- A floor of 1 MIST is equally weak: the real control is a floor near the real price. Choosing it is merchant policy,
  revisited at the mainnet merchant setup (FU-0103).

### F7 — Abort codes and arithmetic

**Severity:** Positive
**Where:** codes 0–19 (`:59-79`); `pay` (`:229`, `:260-267`).

- Codes are unique within the single module.
- `min × units` and `units × period_ms` are computed in u128.
- `end − now` cannot underflow, because `start ≥ now`.
- `end` fits in u64 because `end − now ≤ max_ahead_ms ≤ 120 × 2 629 800 000`.
- `expires_ms − now` is reached only after `now < expires_ms`.
- The abort-code map is in B.5.

### F8 — The quote message is injective, domain-separated and bound to the merchant

**Severity:** Positive
**Where:** `quote_message` (`:170-191`); `pay` (`:231-244`).

- The domain tag comes first and cannot collide with a Sui intent message (those start with the intent bytes `[0,0,0]`), as
  long as the quote key is never also a wallet key; the service's key is a dedicated seed.
- The merchant object id is fixed-width, and every other variable field is length-prefixed BCS. No two field tuples encode
  to the same bytes.
- Binding the merchant object id blocks cross-merchant, cross-network and cross-package replay, because object ids are
  unique per chain.
- `ed25519::ed25519_verify` is the framework's native verifier. A malleated signature would not help an attacker: the nonce,
  not the signature, is the replay key.

### F9 — The conformance test asserted only one of the four shared vectors against `quote_message`

**Severity:** Low   **Disposition:** RESOLVED
**Where:** `tests/chain_payments_tests.move::message_matches_the_vectors`.
**Issue:** Only `basic_message` was compared with the contract's own encoder. The other three vectors (`second`, `too_far`
and `one_off`, the last with an empty reference and a zero period) were exercised only through their signatures in `pay`.
**Impact:** A drift in an edge encoding, such as the empty-vector length prefix, would surface as a bad signature rather
than as a message difference.
**Remediation / evidence:** The test now asserts all four messages against `quote_message`. The service asserts all four
messages and signatures against its signer (`chain-payments-service/crates/core/src/quote.rs::matches_the_move_package_vectors`),
and CI regenerates the vectors and fails on any diff (`move-ci.yml` job `vectors`).

### F10 — Replay protection: nonces, expiry and pruning

**Severity:** Positive
**Where:** `pay` (`:215-224`, `:256`); `prune_nonces` (`:289-301`).

- A nonce is stored per merchant with its quote's expiry and refused while present (`ENonceUsed`).
- `now < expires_ms` and `expires_ms − now ≤ 10 min`: a quote signed with a far expiry becomes usable only in its last ten
  minutes, and never after.
- `prune_nonces` removes only entries whose expiry has passed (`ENotExpired` otherwise). A pruned nonce's quote has expired,
  so it cannot pay again.
- The nonce is in the signed message, so a payer cannot pick a fresh one.
- Tests: `a_quote_cannot_be_used_twice`, `an_expired_quote_is_refused`, `a_quote_valid_for_too_long_is_refused`,
  `expired_nonces_can_be_pruned_by_anyone`, `live_nonces_cannot_be_pruned`.

### F11 — No coin-type confusion

**Severity:** Positive
**Where:** `pay` (`:226-232`); `set_accepted` / `remove_accepted` / `minimum_per_unit`.
The accepted map is keyed by `TypeName` from `with_defining_ids<T>()`, the same string the quote signs. A coin type from
another package named `…::sui::SUI` or `…::usdc::USDC` has a different defining address, so it is not accepted, and its
signed string differs. The service's canonical form (64 hex digits, no `0x`) equals it: vector `coinType`. Merchant #1
accepts exactly `0x2::sui::SUI` and Circle's testnet USDC (read on-chain). Note: for a coin type introduced in a later
version of its package, the defining id is that version's id, and the service registry must carry that form. Today's coins
are defined at their packages' first versions. Tests: `a_coin_type_not_accepted_is_refused`, `a_changed_amount_breaks_the_signature`.

### F12 — Exact take, change in the same transaction, nothing stranded

**Severity:** Positive
**Where:** `pay` (`:247-255`).

- `payment.value() ≥ amount` is asserted, then `split(amount)` goes to `merchant.recipient`.
- The remainder goes to `ctx.sender()`, or is destroyed with `destroy_zero` when empty.
- In a sponsored transaction the change goes to the sender, the payer who chose the coin, not the sponsor.
- The package holds no balance.
- Tests: `pays_exactly_and_returns_the_change` and `exact_payment_leaves_no_change_coin` assert 5000/2000 and no change
  coin; `too_small_a_coin_is_refused`.

### F13 — `publish.sh` preflight, parsing and recovery gaps

**Severity:** Low   **Disposition:** RESOLVED
**Where:** `scripts/publish.sh`.
**Issue (before this pass):**

- (a) No CLI toolchain check against `Published.toml`.
- (b) A second `publish` silently replaced the recorded package id.
- (c) Created objects (`UpgradeCap`, `Merchant`, `MerchantCap`) were found with `endswith(...)`, which accepts a look-alike
  type.
- (d) The effects of `create_merchant` and of each `set_accepted` were not checked; the coin step's output went to
  `/dev/null`, and "accepts …" was printed regardless.
- (e) The merchant was recorded only after the coin steps, so a failed coin step lost its ids.
- (f) `MERCHANT_RECIPIENT` (short form or zero), the limits and the minimums (zero) were not validated.
- (g) No resume command was printed.

**Impact:** An operator could believe a coin was accepted when it was not, or lose a merchant's ids. Payers would then see
`ECoinNotAccepted`. The other gaps fail the OPS lens's preflight, output-parsing and partial-failure rows.
**Remediation / evidence:**

- (a) A major.minor check against `toolchain-version`; `ALLOW_TOOLCHAIN_CHANGE=1` allows a deliberate move.
- (b) `REPLACE_PUBLISHED=1` is required to publish over a record.
- (c) `created_of_type` matches `<package>::<module>::<Name>` exactly, comparing addresses without `0x` and leading zeros, so
  the CLI's long-form `0x000…2::package::UpgradeCap` matches. It requires exactly one match and was checked against
  synthetic output with a look-alike package.
- (d) `succeeded` checks the effects status of every step.
- (e) The merchant is written to `deployments.json` right after creation.
- (f) Recipients are full-form and non-zero, numbers are positive integers, and `USDC_TYPE` must be a full `0x…::usdc::USDC`
  type.
- (g) Every failure prints the `sui client tx-block` or `sui client ptb` command that recovers or resumes.
- `bash -n` is clean; shellcheck runs in CI.

### F14 — No runbook for the script

**Severity:** Low   **Disposition:** RESOLVED
**Where:** `README.md`; FU-0103 says "the exact command is in its README".
**Issue:** The README did not mention the script (OPS B.OPS-1).
**Remediation / evidence:** A *Scripts* section now lists each command, what it records, its guards and what to do when it
stops part-way.

### F15 — Event ordering and fields

**Severity:** Positive
**Where:** `pay` (`:275-285`).
`Paid` is emitted after the transfers and the ledger update, with everything a verifier binds: merchant id, session, payer,
coin type, amount, units, reference, `paid_until_ms` and nonce. No object is deleted, so emit-before-delete does not
apply. `MerchantCreated` is emitted before the share. `MerchantUpdated` names the setter, but not the value (F5).

### F16 — No automated dependency updates

**Severity:** Low   **Disposition:** RESOLVED
**Where:** `.github/`.
**Issue:** The workflow pins `actions/checkout` by SHA, but no Dependabot configuration existed (base §B.2).
**Remediation / evidence:** `.github/dependabot.yml` covers `github-actions` weekly. The package has no npm or Cargo
dependencies; the framework revision follows the CLI pin.

### F17 — The throwaway TEST merchant accepts SUI at 1 MIST under a public key

**Severity:** Info   **Disposition:** ADJUDICATED
**Where:** `deployments.json` merchant `0x30b6d544…dae8`.
**Issue:** Its quote key is the public test key (seed `0x01`×32), so anyone can sign quotes for it. It accepts SUI at 1 MIST
per unit.
**Impact:** None to anyone else. Anyone may extend its ledger references for dust, paid to the deploy key. It exists for the
live checks (`chain-payments-service/scripts/e2e-testnet.sh`, the recorded fixture), and its note in `deployments.json`
says so. It must never appear in a service registry. The deployed `methods.json` names `0x29d6…63f8` only (B.SC-1).

### F18 — Permissionless surfaces

**Severity:** Info   **Disposition:** ADJUDICATED (see B.4)
**Where:** `create_merchant`, `pay`, `prune_nonces`.
**Issue:** Anyone can create look-alike merchants, pay for any reference, and collect the storage rebate of expired nonces
that payers funded.
**Impact:** Look-alike merchants are harmless because verifiers bind the merchant object id. Gifts are a feature. The
nonce rebate is a few MIST per nonce. See B.4 for each.

### F19 — The shared vectors have no negative cases

**Severity:** Low   **Disposition:** DEFERRED (FU-0128)
**Where:** `scripts/gen-test-vectors.py`; the service's `fixtures/quote-vectors.json` is a copy.
**Issue:** The four vectors are all valid quotes (SC lens: "shared golden vectors include negative cases"). The Move tests
cover a changed amount and reference locally. A wrong merchant, wrong coin type, wrong expiry, wrong nonce or truncated
signature are not shared vectors that both sides consume. The service's copy also has no drift check against this repo.
**Remediation / evidence:** Add `negative` entries to the generator: each a valid signature over one field, presented with
another value. Assert them in `pay` (expect `EBadSignature`) and in the service (message differs). Make the service's CI
compare its fixture with this repo's file at the pinned commit. Tracked in FU-0128.

## Section A — Invariant verification matrix

| # | Invariant | Enforced at | Proven by | Status |
| --- | --- | --- | --- | --- |
| I1 | Ownership: governance needs `&MerchantCap`, bound to the merchant; `Merchant` is shared and never assumed owner-gated | `check_cap` `:326-329` | `another_merchants_cap_has_no_power`, `reads_and_governance_round_trip` | HOLDS |
| I2 | Abilities: `Merchant` is `key` only (cannot be wrapped or `public_transfer`red); `MerchantCap` is `key, store` (deliberately transferable to a multisig) | struct declarations `:86`, `:104` | type system | HOLDS (code-only) |
| I3 | Capability binding on every privileged path (`set_accepted`, `remove_accepted`, `set_quote_key`, `set_paused`, `set_limits`, `propose/cancel/confirm_recipient`) | `check_cap` | `another_merchants_cap_has_no_power`, `an_old_merchant_version_refuses_governance` | HOLDS |
| I4 | Isolation: a quote for merchant A never pays at merchant B; a nonce is per merchant | merchant id in `quote_message`; `merchant.nonces` | `message_matches_the_vectors` (merchant id), F8 | HOLDS |
| I5 | Arithmetic: no overflow in `min × units`, `units × period`, the ledger end; no underflow | `:229`, `:260-267` (u128) | `the_ledger_cannot_run_too_far_ahead`, `limits_have_a_hard_ceiling` | HOLDS |
| I6 | Funds routing: payment = amount to the recipient + change to the sender; nothing stranded; recipient never `@0x0` | `:247-255`; `:146`, `:386` | `pays_exactly_and_returns_the_change`, `exact_payment_leaves_no_change_coin`, zero-recipient tests (F3) | HOLDS (source; testnet v1 has no zero-recipient guard, and no testnet merchant has a zero recipient) |
| I7 | A payment is exactly the signed quote: every field signed; the signature checked before any transfer | `:231-244` | `a_changed_amount_breaks_the_signature`, `a_changed_reference_breaks_the_signature` | HOLDS |
| I8 | Byte layout: `quote_message` is bit-for-bit the service's signer | `quote_message` | `message_matches_the_vectors` (four vectors, F9) + the service's vector test | HOLDS |
| I9 | Replay: a nonce pays once while live; a pruned nonce's quote has expired | `:215-224`, `:296` | F10 tests | HOLDS |
| I10 | Coin type: only accepted `with_defining_ids` types, at or above their minimum | `:226-229` | `a_coin_type_not_accepted_is_refused`, `a_quote_below_the_minimum_is_refused_even_if_signed` | HOLDS |
| I11 | Limits: `0 < units ≤ max_units ≤ 120`; ledger at most `max_ahead_ms ≤ 120 months` ahead | `:217-218`, `:266`, `check_limits` | `zero_units_are_refused`, `more_units_than_the_limit_are_refused`, `the_ledger_cannot_run_too_far_ahead`, `set_limits_checks_the_ceiling`, `zero_max_*` | HOLDS |
| I12 | Recipient changes only after two days, by the cap | `confirm_recipient` `:400-407` | `a_new_recipient_waits_for_the_delay`, `a_new_recipient_cannot_be_confirmed_early` | HOLDS — effective only if watched (F5) |
| I13 | Identifiers bounded (session, nonce non-empty, ≤ 64 bytes; reference ≤ 64) | `:219-223` | `an_empty_*`, `a_too_long_*` | HOLDS |
| I14 | Version gating: only the current version's code pays or governs | `:212`, `:328` | `an_old_merchant_version_refuses_*` | HOLDS (no `migrate` yet, F4) |
| I15 | Side-effect-freedom (dry-run policy) | — | — | N/A (no Seal policy or dry-run function) |
| I16 | Abort codes unique within the module; map published | `:59-79` | B.5 map | HOLDS |
| I17 | Event ordering: `Paid` after the effects it reports | `:275` | `pays_exactly_and_returns_the_change` (state), F15 | HOLDS (code-only for the event fields; the service's recorded-transaction test reads them) |

## Section B — Supply-chain, publish-authority & capability matrix

### B.1 Dependency, liveness & coupling

| Dependency | Exact id / rev | Fails open or closed | Paths it can block | Notes |
| --- | --- | --- | --- | --- |
| Sui framework (`Sui`, `MoveStdlib`) | `83f11dc85d5695a57894329b005b78d75f9bb059` (`Move.lock`, testnet) | n/a | build | implicit system dependency; no git dependency of its own |
| `Clock` `0x6` | system | closed (no clock, no transaction) | pay, prune, recipient | — |
| Merchant's quote signer (chain-payments-service) | the key in the `Merchant` | **closed**: no quote, no payment | pay | the price authority (F6) |
| sui CLI 1.81.0, suiup 0.0.14 | sha256-pinned in `move-ci.yml` | — | CI | — |
| `cryptography==41.0.7` (vector generator, CI) | version-pinned `pip install` | — | the vectors job | pinned by version, not by hash; it generates test data only |

**Wire / identity-format coupling:**

| Format | Exact layout | On-chain decoder | Off-chain encoder | Conformance vector |
| --- | --- | --- | --- | --- |
| Quote message | `"chain-payments:quote:v1"` ‖ ID(32) ‖ BCS vec(session) ‖ BCS ascii(coin type, `with_defining_ids`, no `0x`) ‖ u64 LE amount ‖ u64 units ‖ u64 period_ms ‖ BCS vec(reference) ‖ u64 expires_ms ‖ BCS vec(nonce) | `quote_message` + `ed25519_verify` in `pay` | `chain-payments-service/crates/core/src/quote.rs::QuoteFields::message` | `tests/vectors.json` = service `fixtures/quote-vectors.json` (`cmp` identical 2026-11-17); asserted by `message_matches_the_vectors` (4 messages) and the four `pay` tests using the signatures; the service asserts 4 messages + 4 signatures; negatives missing (F19) |
| `Paid` event | `{merchant_id, session, payer, coin_type, amount, units, subscription_ref, paid_until_ms, nonce}` | — (emitted) | read by `chain-payments-service/crates/chain-sui::check_response` | the service's recorded testnet transaction `fixtures/sui-paid-transaction.bin` (`7AkSLeZf…UGYR`) |
| `pay<T>` arguments | `(merchant, session, amount, units, period_ms, subscription_ref, expires_ms, nonce, signature, Coin<T>, &Clock)` | `pay` | `chain-payments-client/src/sui.ts`; the service's `e2e-testnet.sh` | the client's argument-by-argument test (its audit F3) |

### B.2 Publish authority & secret custody

| Authority / secret | Where held | Custody | Gates | Rotation |
| --- | --- | --- | --- | --- |
| Deploy key `0xa991…864a` | operator keystore | single EOA | publish, merchant creation, every cap today | moves to multisig custody before mainnet (F2) |
| TEST quote key (seed `0x01`×32) | public, in the generator | none (public by design) | the throwaway merchant only (F17) | never used for a real merchant |
| Merchant #1's quote key | the service's Secret (`chain-payments-keys`, SOPS) | node | quotes | `set_quote_key` with the cap (the service's runbook) |

#### CI & release integrity

| Item | Holds? | Evidence |
| --- | --- | --- |
| Actions pinned by SHA | yes | `actions/checkout@3d3c42e5…` (v7.0.1) |
| Least privilege | yes | `permissions: contents: read` |
| OIDC trusted publishing | n/a | no npm or crate release; the package is published on-chain by the operator |
| Tag-gated, idempotent publish | n/a (on-chain publish is manual; republish guarded by `REPLACE_PUBLISHED`, F13) | — |
| Release gate equals CI | n/a | no release workflow |
| Automated dependency updates | yes (F16) | `.github/dependabot.yml` |
| Secrets never echoed | yes | the script prints ids and digests only |
| Real funds are manual | yes | no workflow signs |
| Test-only modes | yes | `#[test_only]` helpers (`merchant_id_of`, `set_version_for_testing`, `destroy_cap_for_testing`) are absent from the published bytecode |

### B.3 `UpgradeCap` custody & immutability policy

| Network | Package ID | `UpgradeCap` ID | Status | Intended policy | Tooling |
| --- | --- | --- | --- | --- | --- |
| testnet | `0x5f67109c…bc14` | `0x3f6ec244…eea1` | held by the publisher EOA (read 2026-11-17) | **undecided** (OQ3): `VERSION` and the planned on-chain oracle path (FU-0105) imply upgrades | none (FU-0120) |
| mainnet | — | — | unpublished | decide before publish (OQ3) | FU-0120 before FU-0103 |

Integrators pin the package id through the service's `methods.json`. The client takes it from the service (client audit
F4). One id feeds both the call target and the event type, so the first upgrade must split them: published-at for calls,
original-id for `Paid` (FU-0123).

### B.4 Permissionless & griefing surfaces

| Function | Attacker controls | Confidentiality impact | Discoverability / UX impact | Gas / state growth | Mitigation |
| --- | --- | --- | --- | --- | --- |
| `create_merchant` | a merchant with any recipient, key and limits | none | a look-alike merchant could phish a payer through a different checkout | the attacker's own storage | the verifier binds the merchant object id; the kit takes the merchant from the service, not from the user |
| `pay<T>` (valid quote, any payer) | which reference a quote they hold extends (only as signed) | none | gifts by design | each payment adds a nonce entry (payer-funded) and possibly a ledger entry | nonces prunable after expiry |
| `prune_nonces` | which expired nonces to delete | none | none | frees storage; the rebate goes to the caller, not to the payers who funded it | accepted: a few MIST per nonce |
| reads | — | none | — | — | — |

### B.5 Replay protection & event semantics

**Replay.**

- The chain enforces:
  - nonce non-empty and ≤ 64 bytes;
  - nonce unique per merchant while stored;
  - expiry in the future and at most 10 minutes away;
  - every quote field covered by the signature.
- The chain does not know sessions.
- The off-chain verifier MUST:
  - read by digest and require successful effects;
  - match `<original id>::chain_payments::Paid` exactly;
  - bind (merchant object id, session, nonce, coin type, amount, units, subscription reference) to the quote it issued;
  - treat its own nonce as single-use (one quote, one sale).
- `SECURITY.md` states this (F1).
- The service does all of it as of this pass (its audit, F1–F3).

| Event | Emitted by | Fields (MUST check) | Before / after structural change | Consumers |
| --- | --- | --- | --- | --- |
| `Paid` | `pay` | merchant_id, session, nonce, coin_type, amount, units, subscription_ref (all MUST); payer, paid_until_ms (informational) | after transfers and ledger update | chain-payments-service (settlement) |
| `MerchantCreated` | `create_merchant` | merchant_id, recipient | before the share | indexers |
| `MerchantUpdated` | every setter | merchant_id, `what` (no value: F5) | after the change | none yet (FU-0122) |

**Abort-code map (`chain_payments`):**

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EWrongVersion` | the merchant's version is not this code's |
| 1 | `EPaused` | the merchant is paused |
| 2 | `EQuoteExpired` | the quote's expiry has passed |
| 3 | `EQuoteTooLong` | the quote expires more than 10 minutes from now |
| 4 | `ENonceUsed` | the nonce was used |
| 5 | `ECoinNotAccepted` | the coin type is not accepted |
| 6 | `EBelowMinimum` | the amount is below `min × units` |
| 7 | `ETooManyUnits` | more units than `max_units` |
| 8 | `EBadSignature` | the quote signature does not verify |
| 9 | `EInsufficientPayment` | the coin is smaller than the amount |
| 10 | `ETooFarAhead` | the ledger would run past `max_ahead_ms` |
| 11 | `EWrongCap` | the cap belongs to another merchant |
| 12 | `EBadKey` | a quote key is not 32 bytes |
| 13 | `EBadIdentifier` | an empty or over-long session, nonce or reference |
| 14 | `ENoPendingRecipient` | confirm without a proposal |
| 15 | `ERecipientNotYetDue` | confirm before the delay |
| 16 | `EBadLimits` | a limit is zero or above the hard maximum |
| 17 | `ENotExpired` | pruning a live nonce |
| 18 | `EZeroUnits` | zero units |
| 19 | `EBadRecipient` | the zero address as recipient (source; next upgrade, F3) |

No other module, so no cross-module code reuse.

### B.SC-1 ID-constant trace (consumers of this package's ids)

| Location | Network | Value | original-id / published-at | Matches latest (evidence) |
| --- | --- | --- | --- | --- |
| `Published.toml` | testnet | `0x5f67…bc14` | both (version 1) | Y (GraphQL: `Immutable` package v1) |
| `deployments.json` | testnet | `0x5f67…bc14`; merchants `0x29d6…63f8`, `0x30b6…dae8` | both | Y |
| `post-bootstrap/chain-payments/overlays/default/files/methods.json` (workspace) | testnet | `packageId 0x5f67…bc14`, `merchantObject 0x29d6…63f8` (both methods) | one field for both uses (FU-0123) | Y |
| `chain-payments-service/crates/chain-sui` test, `scripts/e2e-testnet.sh` | testnet | `0x5f67…bc14`, TEST merchant `0x30b6…dae8` | both | Y (test-only merchant, F17) |

### B.OPS-1 Runbook linkage

The README's *Scripts* section links both `publish.sh` modes with their guards and recovery (F14). There is no dry run:
neither mode is a custody step. The custody scripts that will need a dry run are FU-0120.

## Section C — Test-coverage & hermetic/live split

### C.1 Coverage grade — A (39/39 on sui 1.81.0; 100.00% module coverage)

| Dimension | Assessment |
| --- | --- |
| Happy path | covered: pay with change, exact pay, gift extension, one-off, prune, governance round trip, recipient delay |
| Error paths | every abort code 0–19 has an `expected_failure` test (0: two, governance and pay; 13: four; 16: four; 19: two) |
| Boundaries | zero units, `max_units` + 1, the 10-minute bound, the ledger ceiling, 64-byte identifiers, zero limits; u64 maxima are not tested directly, but every product is u128 (F7) |
| Security-relevant | changed amount and reference break the signature; foreign coin refused; below-minimum refused even if signed; wrong cap; old version; four shared vectors (F9); negatives not shared (F19) |

### C.2 Hermetic vs live

| Path | Hermetic test? | Deferred to | Tracking |
| --- | --- | --- | --- |
| Signature verification against the service's real signer | yes (shared vectors) | — | F9 |
| A real `pay` on testnet with the service's verification | no | testnet: `chain-payments-service/scripts/e2e-testnet.sh` (2026-11-16, tx `7AkSLeZf…UGYR`); client-built tx `AkJZej7B…LZw` (client CHANGELOG) | — |
| Custody transfers / burn | no tooling yet | testnet rehearsal before mainnet | FU-0120 |
| `publish.sh` against localnet | no (no localnet run recorded this pass) | localnet `sui start` run before the next publish | recorded as a suggestion |

## Section D — Deployment-readiness gates

### pre-localnet

- [x] `sui move build --lint --warnings-are-errors` clean; `sui move test` green (39/39) — `.github/workflows/move-ci.yml`
- [x] every abort code tested; no unchecked u64 products; all caps bound to their objects (F7, I3)
- [x] `SECURITY.md` present and consistent with the audit (F1)
- [ ] shellcheck green locally — not installed in the review sandbox; CI runs it (no finding: CI is the gate)

### pre-testnet

- [x] published; package id recorded consistently (`Published.toml`, `deployments.json`, the service's `methods.json`; B.SC-1)
- [x] no git dependencies; lockfile committed
- [x] integration exercised against real testnet objects (2026-11-16 live payment); quote-vector conformance green on both sides
- [ ] custody tooling with dry-run default and explicit confirmation — none yet (F2, FU-0120)
- [ ] the zero-recipient refusal deployed by an upgrade (F3, FU-0121)

### pre-mainnet

- [ ] B.3 policy decided and executed (UpgradeCap burned or held by a multisig) — blocking (F2, OQ3, FU-0120)
- [ ] merchant #1's `MerchantCap` with the entity's multisig, recipient the entity's address (FU-0103)
- [ ] recipient-proposal monitoring live (F5, FU-0122)
- [x] full Section A coverage (no GAP); abort-code map published (B.5)
- [ ] negative shared vectors (F19, FU-0128)
- [ ] external audit

## Cross-project themes

- **Supply chain & release integrity.**
  - `Move.lock` is committed and there are no git dependencies.
  - The CI action is pinned and the CLI is checksum-pinned.
  - Dependabot covers Actions (F16).
  - No npm package: the docs sites do not consume this repository yet.
- **Wire-format coupling & conformance vectors.** The quote message (B.1) is defined here, implemented by the service and
  pinned by the shared vectors (identical files, both sides assert them). Negatives and a drift check: F19.
- **On-chain-truth boundary.**
  - The price is off-chain: the service's agreed median. The chain enforces exactness, the signature and the minimum floor.
  - `paid_until` on-chain is the authoritative prepaid period for any reader. The merchant's own records follow webhooks.
- **Deployment readiness.** Section D above.
- **Chain-access layering & on-chain ID/ABI coupling.**
  - The domain client is `@meddleware/chain-payments-client`.
  - Ids trace to `Published.toml` / `deployments.json` (B.SC-1). One id feeds both uses until the first upgrade
    (FU-0123).
  - ABI coupling is pinned by the client's argument test.
- **Versioning policy.** The next publication is an upgrade (version 2); the npm and Move version labels follow the
  workspace's +1 patch rule.

## Normative requirements (MUST / MUST NOT)

- MUST NOT overflow or truncate in any reachable arithmetic — **holds** (F7).
- MUST bind every capability to its merchant and check it on every privileged path — **holds** (I3).
- MUST keep dry-run policy functions side-effect-free — **N/A** (none).
- MUST keep the on-chain quote encoder bit-for-bit identical to the service's, with a shared conformance vector tested on
  both sides — **holds** (F9); negative vectors before mainnet (F19).
- MUST have a decided and, before mainnet, executed UpgradeCap policy, and target custody for every `MerchantCap` —
  **does not hold yet** (F2, OQ3).
- MUST pin git dependencies to commit SHAs and commit the lockfile — **holds** (no git dependencies).
- MUST document what off-chain verifiers are responsible for — **holds** (F1, B.5).
- MUST refuse a recipient that loses funds (the zero address) — **holds in source**, deployed at the next upgrade (F3).
- MUST have a monitor on recipient proposals before mainnet, or the timelock is decorative — **does not hold** (F5).
- OPS-M1…M9: preflight with env, chain id and toolchain (holds, F13) · `set -euo pipefail`, shellcheck in CI (holds) ·
  irreversible steps dry-run by default (n/a until custody scripts exist, FU-0120) · machine output with abort on missing
  ids (holds, F13) · ids and recovery commands printed (holds) · ids recorded (holds; published-at = original-id until an
  upgrade) · no mainnet keys in CI (holds) · no real-chain CI jobs (holds) · global CLI state untouched (holds).

## Implementation suggestions (SHOULD / MAY)

- SHOULD run `publish.sh localnet` and `--create-merchant` against `sui start` once, and record it in C.2.
- SHOULD add a test that pays with `u64::MAX`-adjacent `min_per_unit` and `units` to show the u128 path explicitly.
- MAY emit the remaining time (`effective_ms`) in a future recipient event (OQ1).
- MAY offer `pay` with a `Coin<T>` the caller already split, and document that the change coin is then never created (it is
  today: `destroy_zero`).

## Addendum 2026-11-17: the platform fee (maintainer's decision)

The maintainer asked for 0.2 %, plus the platform's cost of a payment if it has one. Per `docs/economics/COST_MODEL.md`
§5, a wallet-to-fullnode action has a variable platform cost of 0. The payer's gas covers the whole transaction,
including creating the fee coin, and the service's checks run on the fixed-cost cluster. So the rate is 20 bps, with no
fixed part. This was reviewed against the Move lens:

- **Exactness.** The payer pays exactly the quote: the fee is taken out of `amount` after the signature and minimum
  checks, which still apply to the gross amount.
- **Arithmetic.** `fee = amount × bps / 10 000` in u128; it is at most 1 % of `amount`, so the split cannot underflow.
  A fee rounding to zero makes no coin.
- **Treasury.** It is never the zero address.
- **Ceiling.** The 1 % ceiling is a constant of immutable code, so merchants can rely on it; the rate and treasury
  setters need `PlatformAdminCap` and emit `PlatformConfigChanged` with old and new values.
- **Custody.** `PlatformAdminCap` belongs with the custody multisig on mainnet (FU-0120). Its theft could at worst raise
  the fee to 1 % or redirect future fees, never touch a merchant's recipient or a payer's change.
- **Tests.** Split values, rounding, the ceiling, a zero rate, the treasury refusal and the events (45 tests); a localnet
  rehearsal of publish, `set_platform_treasury`, the burn and a setter call after the burn.

## Open questions (`OQ#`)

- **OQ1** — DECIDED 2026-11-17 (maintainer): typed events. Every governance change emits its own event with the old and
  new values (`RecipientProposed`, `RecipientProposalCancelled`, `RecipientChanged`, `QuoteKeyChanged`, `AcceptedChanged`,
  `PausedChanged`, `LimitsChanged`), replacing `MerchantUpdated`. In source; ships with the next fresh package. (F5)
- **OQ2** — DECIDED 2026-11-17 (maintainer): `set_accepted` refuses a zero minimum (`EZeroMinimum` = 20). The useful floor
  is per coin and price-dependent, so it stays merchant configuration (README, "Choosing minimums"). (F6)
- **OQ3** — DECIDED 2026-11-17 (maintainer): (b). Every release is a fresh package with its UpgradeCap burned;
  `publish.sh` burns it as part of a mainnet publish (rehearsed on localnet 2026-11-17). Version gating stays as defence in
  depth but no upgrade will ever run on mainnet, so F4's `migrate` is moot there. (F2)

## Risks (residual)

- The service's quote key is the price authority. Its compromise is bounded by the minimums and stopped by `set_quote_key`
  or `set_paused`, but a sale at the minimum until then is a loss to the merchant.
- Clock agreement: quotes are dated by the service's clock and checked against the chain's `Clock`. A service clock more than
  two minutes behind makes quotes arrive expired; more than ten minutes ahead makes them `EQuoteTooLong`. Both fail closed.
- Third-party liveness: Sui itself; the coin issuers (Circle can freeze USDC addresses, including a merchant's recipient).
- Until F2 is executed, one key controls the code and merchant #1.

## Re-verification log

- 2026-11-17 — First pass at `356d286` plus this pass's changes:
  - read the source, the tests, the script, CI and the testnet objects (GraphQL);
  - `sui move test` 39/39 at 100% coverage;
  - fixed F1, F3 (in source), F9, F13, F14 and F16 inline;
  - deferred F2, F5 and F19 to FU-0120, FU-0122 and FU-0128, and the next upgrade to FU-0121;
  - opened OQ1–OQ3.

## Pre-save consistency checklist (this pass)

- [x] Section A ↔ findings (I6 notes the source-only fix; I12 points at F5)
- [x] Finding header ↔ body
- [x] Template line (`node docs/audit/check-template-dates.mjs`)
- [x] Closing structure in order
- [x] Open questions stay open
- [x] Section D ↔ dispositions
- [x] Executive summary matches the current dispositions
- [x] Counts re-measured (39 tests, 100%; testnet objects read 2026-11-17)
- [x] Re-verification log entry
