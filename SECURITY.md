# Security Policy

## Scope

The `chain_payments` Move package (`sources/chain_payments.move`) and its publish script (`scripts/publish.sh`), on every
network listed in [deployments.json](deployments.json). Out of scope: the off-chain service, SDK and kit (their own
policies) and wallets.

## Security model

- A payment moves exactly the quoted amount from the payer's coin to the merchant's recipient and returns the rest to the payer
  in the same transaction; the package holds no funds.
- Quotes are ed25519-signed by the merchant's key over a domain-separated message (`chain-payments:quote:v1`, then the BCS
  of every field, the merchant object id first); each nonce can be used once per merchant; a quote can be used only within
  ten minutes of its expiry and never after it.
- A compromised quote key can sign quotes only at or above the merchant's on-chain minimum per unit; rotate the key or pause.
  A minimum is therefore never zero (the publish script refuses one).
- A compromised `MerchantCap` can pause, rotate the key or change minimums at once, but a new recipient waits two days; the
  zero address is refused as a recipient.
- **What the chain does not do, and an off-chain verifier must.** The chain proves that a `Paid` event's quote was signed
  by the merchant's key at that moment; it does not know about checkout sessions. A verifier that credits a payment must
  read the transaction by digest, require successful effects, match the event type against the **full** type
  `<original package id>::chain_payments::Paid` (never a suffix), and compare the merchant object id, session, nonce,
  coin type, amount, units and subscription reference with the quote it issued. A nonce is unique per merchant only while
  its entry exists: once pruned (after expiry) the same quote can no longer pay because it has expired, but a verifier
  must still treat the nonce as single-use itself.

## Supported versions

The latest published package on each network in [deployments.json](deployments.json). Older packages, if any, are not
patched: a fix ships as an upgrade or a new package, recorded in `deployments.json` and `CHANGELOG.md`.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository. Please do not open a public issue. Expect an
acknowledgement within a week.

## Disclosure

Coordinated: a fix (upgrade or new package) is published first; the report and the fix are then described in
`CHANGELOG.md` and the audit's re-verification log.
