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

Licence: [0BSD](LICENSE).
