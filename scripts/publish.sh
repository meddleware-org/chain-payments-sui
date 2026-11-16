#!/usr/bin/env bash
# =============================================================================
# chain_payments — publish, then (optionally) create a merchant
# =============================================================================
#   ./scripts/publish.sh localnet|testnet|mainnet
#   ./scripts/publish.sh localnet|testnet|mainnet --create-merchant
#
# Publishing records the package id and the UpgradeCap in deployments.json (and Published.toml, written by the CLI).
# --create-merchant (on an already published network) creates a merchant and accepts the coins below; the MerchantCap goes
# to the active address (mainnet: transfer it to the entity's multisig afterwards, CUSTODY.md).
#
# Env for --create-merchant:
#   MERCHANT_RECIPIENT   required: who receives payments (mainnet: the entity's multisig, never a personal key)
#   QUOTE_PUBLIC_KEY     required: the service's ed25519 quote key, 64 hex characters (printed by the service's key script)
#   MAX_UNITS            default 12           (units one payment may buy; the package's hard maximum is 120)
#   MAX_AHEAD_MS         default 63115200000  (24 average months; hard maximum 120)
#   SUI_MIN_PER_UNIT     default unset        (MIST per unit; set it to accept SUI)
#   USDC_TYPE            default unset        (the network's native USDC coin type, from Circle's documentation)
#   USDC_MIN_PER_UNIT    default unset        (smallest USDC unit per unit; set it with USDC_TYPE to accept USDC)
#   GAS_BUDGET           default 100000000
#
# Safety: the active `sui client` env must already be <network>; the chain identifier must match it; mainnet needs
# EXPECTED_SIGNER (the active address must equal it) and MAINNET_CONFIRM=1.
set -euo pipefail
cd "$(dirname "$0")/.."

net="${1:?usage: publish.sh localnet|testnet|mainnet [--create-merchant]}"
mode="${2:-publish}"
GAS_BUDGET="${GAS_BUDGET:-100000000}"
command -v jq > /dev/null || { echo "jq is required" >&2; exit 2; }

active_env="$(sui client active-env 2>/dev/null)"
[[ "$active_env" == "$net" ]] || { echo "the active sui env is ${active_env}; run: sui client switch --env ${net}" >&2; exit 2; }
chain="$(sui client chain-identifier 2>/dev/null | sed -n 's/^Hex: *//p' || true)"
case "$net" in
  testnet) [[ "$chain" == "4c78adac" ]] || { echo "chain identifier ${chain} is not testnet" >&2; exit 2; } ;;
  mainnet) [[ "$chain" == "35834a8a" ]] || { echo "chain identifier ${chain} is not mainnet" >&2; exit 2; } ;;
esac
signer="$(sui client active-address)"
if [[ "$net" == mainnet ]]; then
  [[ "${EXPECTED_SIGNER:-}" == "$signer" ]] || { echo "mainnet: EXPECTED_SIGNER must equal the active address (${signer})" >&2; exit 2; }
  [[ "${MAINNET_CONFIRM:-}" == 1 ]] || { echo "mainnet: set MAINNET_CONFIRM=1" >&2; exit 2; }
fi

[[ -f deployments.json ]] || echo '{}' > deployments.json

if [[ "$mode" == publish ]]; then
  out="$(sui client publish --gas-budget "$GAS_BUDGET" --json)"
  status="$(jq -r '.effects.status.status // .effects.V2.status // empty' <<< "$out")"
  [[ "$status" == success ]] || { echo "publish failed: $(jq -c '.effects.status // .' <<< "$out" | head -c 400)" >&2; exit 1; }
  pkg="$(jq -r '.objectChanges[] | select(.type == "published") | .packageId' <<< "$out")"
  cap="$(jq -r '.objectChanges[] | select(.type == "created" and (.objectType | endswith("::package::UpgradeCap"))) | .objectId' <<< "$out")"
  digest="$(jq -r '.digest' <<< "$out")"
  tmp="$(mktemp)"
  jq --arg n "$net" --arg p "$pkg" --arg c "$cap" --arg d "$digest" --arg s "$signer" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.[$n] = ((.[$n] // {}) + {packageId: $p, upgradeCap: $c, publishDigest: $d, publisher: $s, publishedAt: $t})' deployments.json > "$tmp"
  mv "$tmp" deployments.json
  echo "published ${net}: package ${pkg} (UpgradeCap ${cap}, tx ${digest})"
  exit 0
fi

[[ "$mode" == --create-merchant ]] || { echo "unknown mode ${mode}" >&2; exit 2; }
pkg="$(jq -r --arg n "$net" '.[$n].packageId // empty' deployments.json)"
[[ -n "$pkg" ]] || { echo "${net}: publish first" >&2; exit 2; }
: "${MERCHANT_RECIPIENT:?set MERCHANT_RECIPIENT}" "${QUOTE_PUBLIC_KEY:?set QUOTE_PUBLIC_KEY}"
[[ "$QUOTE_PUBLIC_KEY" =~ ^[0-9a-f]{64}$ ]] || { echo "QUOTE_PUBLIC_KEY must be 64 lowercase hex characters" >&2; exit 2; }
if [[ "$net" == mainnet && "$MERCHANT_RECIPIENT" == "$signer" ]]; then echo "mainnet: the recipient must not be the deploy key" >&2; exit 2; fi
key_vec="[$(sed 's/../0x&,/g; s/,$//' <<< "$QUOTE_PUBLIC_KEY")]"

ptb=(sui client ptb --gas-budget "$GAS_BUDGET" --json
  --move-call "${pkg}::chain_payments::create_merchant" "@${MERCHANT_RECIPIENT}" "vector${key_vec}" "${MAX_UNITS:-12}" "${MAX_AHEAD_MS:-63115200000}"
  --assign cap)
out="$("${ptb[@]}" --transfer-objects "[cap]" "@${signer}")"
merchant="$(jq -r '.objectChanges[] | select(.type == "created" and (.objectType | endswith("::chain_payments::Merchant"))) | .objectId' <<< "$out")"
mcap="$(jq -r '.objectChanges[] | select(.type == "created" and (.objectType | endswith("::chain_payments::MerchantCap"))) | .objectId' <<< "$out")"
[[ -n "$merchant" && -n "$mcap" ]] || { echo "create_merchant failed: $(head -c 400 <<< "$out")" >&2; exit 1; }
accept() { # <coin type> <min per unit>
  sui client ptb --gas-budget "$GAS_BUDGET" --json \
    --move-call "${pkg}::chain_payments::set_accepted" "<$1>" "@${mcap}" "@${merchant}" "$2" > /dev/null
  echo "  accepts $1 (minimum ${2} per unit)"
}
[[ -n "${SUI_MIN_PER_UNIT:-}" ]] && accept 0x2::sui::SUI "$SUI_MIN_PER_UNIT"
[[ -n "${USDC_TYPE:-}" && -n "${USDC_MIN_PER_UNIT:-}" ]] && accept "$USDC_TYPE" "$USDC_MIN_PER_UNIT"
tmp="$(mktemp)"
jq --arg n "$net" --arg m "$merchant" --arg c "$mcap" --arg r "$MERCHANT_RECIPIENT" \
  '.[$n].merchants = ((.[$n].merchants // []) + [{merchantId: $m, merchantCap: $c, recipient: $r}])' deployments.json > "$tmp"
mv "$tmp" deployments.json
echo "merchant ${merchant} (cap ${mcap}) on ${net}"
