# CLAUDE.md — chain-payments-sui

The Sui Move package of Chain Payments (ADR-0011 in the operator's workspace; this repository carries no operator data):
merchants, exact quoted payments with in-transaction change, and an optional prepaid-period ledger. One module,
`sources/chain_payments.move`; its header comment is the design.

## Invariants

- **The quote message is a contract with the service.** `quote_message` (the domain tag `chain-payments:quote:v1`, then the
  BCS of each field in order) must match what the Chain Payments service signs. `scripts/gen-test-vectors.py` writes the
  shared vectors (`tests/vectors.json`, `tests/vectors.move`) with a fixed TEST key; CI fails if they drift. Changing the
  message is a new domain tag and a coordinated service release.
- **Exact take, change back.** `pay` never keeps more than the quoted amount and never holds funds.
- **A leaked quote key is bounded** by the per-coin minimum per unit; keep those minimums meaningful.
- **Hard ceilings:** 120 units per payment, 120 average months ahead.
- **Coverage stays at 100%** (`sui move test --coverage`, then `sui move coverage summary`).

## Commands

```bash
sui move build --lint --warnings-are-errors
sui move test --coverage && sui move coverage summary
python3 -I scripts/gen-test-vectors.py      # after changing the message or the test merchant
bash scripts/publish.sh testnet             # active env must be testnet; records deployments.json
QUOTE_PUBLIC_KEY=<hex> MERCHANT_RECIPIENT=0x… SUI_MIN_PER_UNIT=… bash scripts/publish.sh testnet --create-merchant
```

Commit messages: one short line, no body, no trailer.
