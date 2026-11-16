# Security Policy

## Scope

The `chain_payments` Move package. Out of scope: the off-chain service, SDK and kit (their own policies) and wallets.

## Model

- A payment moves exactly the quoted amount from the payer's coin to the merchant's recipient and returns the rest to the payer
  in the same transaction; the package holds no funds.
- Quotes are ed25519-signed by the merchant's key over a domain-separated message; each nonce can be used once; a quote
  must expire within ten minutes of use.
- A compromised quote key can sign quotes only at or above the merchant's on-chain minimum per unit; rotate the key or pause.
- A compromised `MerchantCap` can pause, rotate the key or change minimums at once, but a new recipient waits two days.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository. Please do not open a public issue.
