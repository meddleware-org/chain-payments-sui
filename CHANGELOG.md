# Changelog

## Unreleased (source only; the testnet package is still 0.0.1)

- `create_merchant` and `propose_recipient` refuse the zero address (`EBadRecipient` = 19). Ships with the next upgrade.
- `scripts/publish.sh`: CLI toolchain preflight against `Published.toml`, no publish over a recorded package without
  `REPLACE_PUBLISHED=1`, created objects read by their exact types, effects checked on every step, recipient and limits
  validated, the merchant recorded before its coins are accepted, resume commands printed.
- Dependabot keeps the workflow's pinned action SHAs current.
- Tests: every shared quote vector's message is checked against `quote_message`; zero-recipient tests.

## 0.0.1 — 2026-11-16

- First release: merchants, exact quoted payments in any accepted coin with change returned in the same transaction,
  the prepaid-period ledger, nonce pruning, governance with a two-day recipient delay. Published on testnet.
