# chain-payments-sui

Exact, quoted crypto payments on Sui for any merchant, with an optional prepaid-period ledger.

- **One exact price.** A merchant's service signs a short-lived quote (ed25519) for an exact amount of one coin type. `pay<T>`
  checks it, sends exactly that amount to the merchant and returns the change to the payer **in the same transaction**.
- **Any coin type** the merchant accepts (SUI, USDC, …), each with an on-chain minimum per unit that bounds what a leaked quote
  key could sell for.
- **Prepaid periods.** A quote may extend an opaque subscription reference by `units × period_ms`; anyone may pay for any
  reference (gifts), and `paid_until` is readable on-chain.
- **Governance with a delay.** The `MerchantCap` sets keys, coins, limits and the pause; a new recipient takes effect only two
  days after it is proposed.

Testnet deployment: see [deployments.json](deployments.json). The off-chain side (sessions, quotes, verification, webhooks) is
`chain-payments-service`; the TypeScript SDK is `@meddleware/chain-payments-client`; the Vue checkout is
`@meddleware/chain-payments-kit`.

## Quote message

```
"chain-payments:quote:v1" ‖ bcs(merchant_id: ID) ‖ bcs(session: vector<u8>) ‖ bcs(coin_type: ascii::String)
‖ bcs(amount: u64) ‖ bcs(units: u64) ‖ bcs(period_ms: u64) ‖ bcs(subscription_ref: vector<u8>) ‖ bcs(expires_ms: u64)
‖ bcs(nonce: vector<u8>)
```

`coin_type` is `type_name::with_defining_ids<T>()` as a string (64 hex digits without `0x`, then `::module::Name`). Vectors:
[tests/vectors.json](tests/vectors.json).

## Scripts

`scripts/publish.sh` is the only script that signs. It has no dry run: every step below sends a transaction from the active
`sui` address after the preflight (active env, chain identifier, CLI toolchain against `Published.toml`, and on mainnet
`EXPECTED_SIGNER` plus `MAINNET_CONFIRM=1`).

| Command | What it does | If it stops part-way |
| --- | --- | --- |
| `scripts/publish.sh testnet` | publishes the package; records the id, UpgradeCap and digest in `deployments.json` (the CLI writes `Published.toml`); refuses to publish over a recorded package unless `REPLACE_PUBLISHED=1` | the script prints the `sui client tx-block <digest> --json` to read the ids from |
| `scripts/publish.sh localnet\|testnet --burn-upgrade-cap` | burns the recorded UpgradeCap (typed `BURN`, or `BURN_CONFIRM=BURN`); records `immutable` only once the cap is gone | nothing is recorded until the cap is verified gone; re-run to retry |
| `MERCHANT_RECIPIENT=0x… QUOTE_PUBLIC_KEY=… SUI_MIN_PER_UNIT=… scripts/publish.sh testnet --create-merchant` | creates a merchant (cap to the active address), records it, then accepts each configured coin | the merchant is recorded first; a failed `set_accepted` prints the exact `sui client ptb` command that resumes it |

Mainnet: the same commands with the maintainer's key, `EXPECTED_SIGNER` and `MAINNET_CONFIRM=1`; the recipient must be the
entity's multisig, never the deploy key. Publishing on mainnet burns the UpgradeCap straight away.

## Releases

Every release is a fresh package with its UpgradeCap burned: nobody, the publisher included, can change code that merchants
and payers rely on. A fix means a new package, new merchants on it and a service configured for it. The old package keeps
serving the subscriptions it recorded, and they are still readable through `paid_until`.

## Choosing minimums

`set_accepted` refuses zero. The minimum that matters is the merchant's floor per unit, in each coin's smallest unit: it is
the most a leaked quote key could undersell by. Set it below the lowest price you expect to quote, not at 1:

- for a stablecoin, about 90 % of one unit's price;
- for a volatile coin, about a quarter of one unit's current price, so that a fourfold rise in the coin's price still
  leaves quotes above the floor.

Re-set it (`set_accepted`, which emits `AcceptedChanged`) when the price moves far enough that the service's quotes come
near it.

Licence: [0BSD](LICENSE).
