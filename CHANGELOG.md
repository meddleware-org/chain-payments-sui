# Changelog

## Unreleased (source only; the testnet package is still 0.0.1)

- Platform fee: `pay<T>` takes the shared `PlatformConfig` (its first argument) and sends 0.2 % of the quoted amount,
  rounded down, to the platform treasury; the merchant's recipient gets the rest and the payer still pays exactly the
  quote. `PlatformAdminCap` sets the rate (at most 1 %, `EFeeTooHigh` = 21) and the treasury (never zero), each emitting
  `PlatformConfigChanged`. `Paid` gains `platform_fee`. `publish.sh` records both objects and takes `PLATFORM_TREASURY`.
- Release policy: every release is a fresh package whose UpgradeCap is burned. `publish.sh` burns it on mainnet as part of
  publishing (typed `BURN`) and offers `--burn-upgrade-cap` elsewhere; the burn is recorded only once the cap is gone.
- Typed governance events with old and new values (`RecipientProposed`, `RecipientProposalCancelled`, `RecipientChanged`,
  `QuoteKeyChanged`, `AcceptedChanged`, `PausedChanged`, `LimitsChanged`) replace `MerchantUpdated`.
- `set_accepted` refuses a zero minimum (`EZeroMinimum` = 20).
- `publish.sh localnet` works (a test publication with a throwaway pubfile) and every failed publish shows the CLI's error.
- `create_merchant` and `propose_recipient` refuse the zero address (`EBadRecipient` = 19). Ships with the next upgrade.
- `scripts/publish.sh`: CLI toolchain preflight against `Published.toml`, no publish over a recorded package without
  `REPLACE_PUBLISHED=1`, created objects read by their exact types, effects checked on every step, recipient and limits
  validated, the merchant recorded before its coins are accepted, resume commands printed.
- Dependabot keeps the workflow's pinned action SHAs current.
- Tests: every shared quote vector's message is checked against `quote_message`; zero-recipient tests.

## 0.0.1 — 2026-11-16

- First release: merchants, exact quoted payments in any accepted coin with change returned in the same transaction,
  the prepaid-period ledger, nonce pruning, governance with a two-day recipient delay. Published on testnet.
