# Custody — chain_payments

Who holds this package's authority objects. Every release is a **fresh package with its UpgradeCap burned at
publish** (`scripts/publish.sh`; on mainnet the burn is part of publishing), so no object can change the code. What
remains to hold:

| Object | Created by | Controls | Long-term holder |
| --- | --- | --- | --- |
| `PlatformAdminCap` | `init` | the platform fee's rate (never above 1 %) and its treasury | the entity's multisig, permanently |
| `MerchantCap` (one per merchant) | `create_merchant` | that merchant's recipient (after a two-day delay), quote key, accepted coins and minimums, pause and limits | the merchant: for the platform's own merchants, the entity's multisig |

A third-party merchant's cap belongs to that merchant and is outside this process.

## Release lifecycle

1. **Publish** from the deploy key: `PLATFORM_TREASURY=0x… scripts/publish.sh <network>`. On mainnet this burns the
   UpgradeCap (typed `BURN`) and requires the treasury to be the entity's.
2. **Create the platform's merchants** (`--create-merchant`), with minimums per README "Choosing minimums".
3. **Transfer** the PlatformAdminCap and the platform's MerchantCaps to the multisig:
   ```bash
   MULTISIG_PKS="<pk…>" MULTISIG_WEIGHTS="<w…>" MULTISIG_THRESHOLD=<n> NETWORK=<network> MULTISIG_ADDRESS=0x… \
     DRY_RUN=0 bash scripts/transfer-authority.sh --merchant <merchant object id> …
   ```
   The script re-derives the multisig from the keys, weights and threshold, re-reads each object (exact type, this
   package, owned by the active address, a MerchantCap naming its merchant) and re-reads the owners afterwards. It
   records `custody` and each `merchantCapOwner` in `deployments.json`.

Keep the platform's MerchantCap usable at short notice. The service's merchant watch
(`ChainPaymentsMerchantChanged`) gives two days to answer an unexpected recipient proposal (`cancel_recipient`).

## The multisig and signing

`scripts/multisig-address.sh` derives the address from its members' public keys (`sui keytool list`, field
`publicBase64KeyWithFlag`). A 1-of-1 multisig of the maintainer's key works while there is one signer. The multisig pays
its own gas.

1. Build unsigned: `sui client ptb --move-call <target> <args…> --sender @<multisig> --gas-budget 20000000 --serialize-unsigned-transaction > tx.b64`.
2. Each signer: `sui keytool sign --address <signer> --data "$(cat tx.b64)" --json` → `suiSignature`.
3. Combine: `sui keytool multi-sig-combine-partial-sig --pks <pk…> --weights <w…> --threshold <t> --sigs <sig…> --json` → `multisigSerialized`.
4. Execute: `sui client execute-signed-tx --tx-bytes "$(cat tx.b64)" --signatures <multisigSerialized>`.

## Rehearsal (testnet, 2026-11-17)

- Multisig `0x9d909846…5151`, 1-of-1 of the deploy key `0xa991…864a`.
- `transfer-authority.sh` moved the PlatformAdminCap `0x6e01aac8…a162` and the TEST merchant's cap `0x0e6dcc95…56f2`.
  The script verified both owners on-chain.
- A multisig-signed `set_platform_fee_bps(20)` (no change) executed as tx
  `3dxs23gX1hvgkqSCx5ohLv7aycyjFCkqaR2JmsFATzY8`, emitting `PlatformConfigChanged`.
- Merchant #1's cap stays with the deploy key on testnet, so the watch can be answered without the multisig steps.

## Current state

`deployments.json` (`custody`, `merchants[].merchantCapOwner`) is the record. On mainnet, steps 1 to 3 follow the first
publish (FU-0103).
