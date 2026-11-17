#!/usr/bin/env bash
# =============================================================================
# chain_payments — publish, then (optionally) create a merchant
# =============================================================================
#   ./scripts/publish.sh localnet|testnet|mainnet
#   ./scripts/publish.sh localnet|testnet|mainnet --create-merchant
#   ./scripts/publish.sh localnet|testnet|mainnet --burn-upgrade-cap
#
# Release policy (ADR-0011): every release is a FRESH package whose UpgradeCap is burned (0x2::package::make_immutable),
# so nobody, the publisher included, can change the code merchants and payers rely on. A fix is a new package and new
# merchants on it; the old package keeps working for what was already paid. On mainnet the burn is part of publishing
# (a typed BURN, or BURN_CONFIRM=BURN); elsewhere it is --burn-upgrade-cap, to rehearse it. The burn is recorded only after
# the cap is definitely gone.
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
# Safety: the active `sui client` env must already be <network>; the chain identifier must match it; the sui CLI's
# major.minor must equal the toolchain recorded in Published.toml (ALLOW_TOOLCHAIN_CHANGE=1 for a deliberate move); mainnet
# needs EXPECTED_SIGNER (the active address must equal it) and MAINNET_CONFIRM=1. Publishing again over a recorded
# package needs REPLACE_PUBLISHED=1 (the old record stays in git history). Every signing step prints what it created and,
# on failure, the command that resumes.
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
recorded_toolchain="$(sed -n 's/^toolchain-version = "\([0-9]*\.[0-9]*\)\..*"$/\1/p' Published.toml 2>/dev/null | head -n 1)"
cli_toolchain="$(sui --version | sed -n 's/^sui \([0-9]*\.[0-9]*\)\..*/\1/p')"
if [[ -n "$recorded_toolchain" && "$cli_toolchain" != "$recorded_toolchain" && "${ALLOW_TOOLCHAIN_CHANGE:-}" != 1 ]]; then
  echo "sui ${cli_toolchain} differs from the recorded toolchain ${recorded_toolchain} (Published.toml); set ALLOW_TOOLCHAIN_CHANGE=1 to move" >&2
  exit 2
fi
if [[ "$net" == mainnet ]]; then
  [[ "${EXPECTED_SIGNER:-}" == "$signer" ]] || { echo "mainnet: EXPECTED_SIGNER must equal the active address (${signer})" >&2; exit 2; }
  [[ "${MAINNET_CONFIRM:-}" == 1 ]] || { echo "mainnet: set MAINNET_CONFIRM=1" >&2; exit 2; }
fi

[[ -f deployments.json ]] || echo '{}' > deployments.json

succeeded() { [[ "$(jq -r '.effects.status.status // .effects.V2.status // empty' <<< "$1" 2>/dev/null)" == success ]]; }
# The id of the one created object of exactly <package>::<module>::<Name> (addresses compared without 0x and leading
# zeros, so the short and the long form of a type both match; any other package's look-alike does not).
created_of_type() { # <json> <package> <module> <name>
  jq -r --arg p "$2" --arg m "$3" --arg n "$4" '
    def norm: ascii_downcase | sub("^0x"; "") | sub("^0+"; "");
    [.objectChanges[] | select(.type == "created")
      | select((.objectType | split("::")) as $t | ($t | length) == 3 and ($t[0] | norm) == ($p | norm) and $t[1] == $m and $t[2] == $n)
      | .objectId] | if length == 1 then .[0] else empty end' <<< "$1"
}

# object_state <id>: found | gone | unknown (as in token-issuance-template-sui's publish.sh). Only "gone" means consumed.
object_state() {
  local want out rc=0 json
  want=$(printf '%s' "${1#0x}" | tr '[:upper:]' '[:lower:]' | sed 's/^0*//')
  out=$(sui client object "$1" --json 2>&1) || rc=$?
  json=$(printf '%s\n' "$out" | awk '/^{/,0')
  if [[ $rc -eq 0 ]]; then
    if jq -e '.objectId != null' <<< "$json" > /dev/null 2>&1; then echo found; return 0; fi
    if jq -e '(.error.code // "") | test("^(deleted|notExists)$")' <<< "$json" > /dev/null 2>&1; then echo gone; return 0; fi
  elif printf '%s\n' "$out" | tr '[:upper:]' '[:lower:]' | grep -Eq "object 0x0*${want} not found"; then
    echo gone; return 0
  fi
  printf 'sui client object %s: could not tell whether the object exists (exit %s):\n%s\n' "$1" "$rc" "$out" >&2
  echo unknown
}

# burn_upgrade_cap: make the recorded package immutable, then record it (only once the cap is gone).
burn_upgrade_cap() {
  local cap out answer state tmp
  cap="$(jq -r --arg n "$net" '.[$n].upgradeCap // empty' deployments.json)"
  [[ -n "$cap" ]] || { echo "${net}: no UpgradeCap recorded (already burned, or not published)" >&2; exit 2; }
  if [[ "${BURN_CONFIRM:-}" != BURN ]]; then
    read -r -p "Burn UpgradeCap ${cap} on ${net}? The package can then never be changed. Type BURN: " answer
    [[ "$answer" == BURN ]] || { echo "not burned; later: ./scripts/publish.sh ${net} --burn-upgrade-cap" >&2; exit 1; }
  fi
  out="$(sui client call --package 0x2 --module package --function make_immutable --args "$cap" --gas-budget "$GAS_BUDGET" --json)" || out=""
  succeeded "$out" || { echo "make_immutable failed: $(jq -c '.effects.status // .' <<< "$out" 2> /dev/null | head -c 400)" >&2; exit 1; }
  state="$(object_state "$cap")"
  [[ "$state" == gone ]] || { echo "make_immutable succeeded but the UpgradeCap is ${state}; check by hand before recording" >&2; exit 1; }
  tmp="$(mktemp)"
  jq --arg n "$net" --arg d "$(jq -r '.digest' <<< "$out")" \
    '.[$n] |= ((del(.upgradeCap)) + {immutable: true, burnDigest: $d})' deployments.json > "$tmp"
  mv "$tmp" deployments.json
  echo "${net}: package is immutable (UpgradeCap ${cap} burned, tx $(jq -r '.digest' <<< "$out"))"
}

if [[ "$mode" == --burn-upgrade-cap ]]; then
  burn_upgrade_cap
  exit 0
fi

if [[ "$mode" == publish ]]; then
  existing="$(jq -r --arg n "$net" '.[$n].packageId // empty' deployments.json)"
  if [[ -n "$existing" && "${REPLACE_PUBLISHED:-}" != 1 ]]; then
    echo "${net} already records package ${existing}; set REPLACE_PUBLISHED=1 to publish a new one over it" >&2
    exit 2
  fi
  if [[ "$net" == localnet ]]; then
    # The package defines testnet and mainnet only; a localnet publication is a test publication, recorded in a
    # throwaway pubfile so Published.toml is never touched (localnet is regenerated at will).
    publish=(sui client test-publish --build-env testnet --pubfile-path "$(mktemp -u).localnet.toml")
  else
    publish=(sui client publish)
  fi
  errs="$(mktemp)"
  out="$("${publish[@]}" --gas-budget "$GAS_BUDGET" --json 2> "$errs")" || true
  if ! succeeded "$out"; then
    echo "publish failed: $(jq -c '.effects.status // .' <<< "$out" 2> /dev/null | head -c 400)" >&2
    grep -v '^\(INCLUDING DEPENDENCY\|BUILDING\)' "$errs" | head -20 >&2
    exit 1
  fi
  rm -f "$errs"
  pkg="$(jq -r '.objectChanges[] | select(.type == "published") | .packageId' <<< "$out")"
  cap="$(created_of_type "$out" 0x2 package UpgradeCap)"
  digest="$(jq -r '.digest // empty' <<< "$out")"
  if [[ -z "$pkg" || -z "$cap" || -z "$digest" || "$pkg" == null || "$cap" == null ]]; then
    echo "publish succeeded but the package, UpgradeCap or digest could not be read; record them by hand from: sui client tx-block ${digest:-<digest>} --json" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  jq --arg n "$net" --arg p "$pkg" --arg c "$cap" --arg d "$digest" --arg s "$signer" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.[$n] = ((.[$n] // {}) + {packageId: $p, upgradeCap: $c, publishDigest: $d, publisher: $s, publishedAt: $t})' deployments.json > "$tmp"
  mv "$tmp" deployments.json
  echo "published ${net}: package ${pkg} (UpgradeCap ${cap}, tx ${digest})"
  if [[ "$net" == mainnet ]]; then burn_upgrade_cap; fi
  exit 0
fi

[[ "$mode" == --create-merchant ]] || { echo "unknown mode ${mode}" >&2; exit 2; }
pkg="$(jq -r --arg n "$net" '.[$n].packageId // empty' deployments.json)"
[[ -n "$pkg" ]] || { echo "${net}: publish first" >&2; exit 2; }
: "${MERCHANT_RECIPIENT:?set MERCHANT_RECIPIENT}" "${QUOTE_PUBLIC_KEY:?set QUOTE_PUBLIC_KEY}"
[[ "$QUOTE_PUBLIC_KEY" =~ ^[0-9a-f]{64}$ ]] || { echo "QUOTE_PUBLIC_KEY must be 64 lowercase hex characters" >&2; exit 2; }
# Full-form addresses only (a short form pads into a different address); never the zero address.
[[ "$MERCHANT_RECIPIENT" =~ ^0x[0-9a-f]{64}$ && ! "$MERCHANT_RECIPIENT" =~ ^0x0{64}$ ]] \
  || { echo "MERCHANT_RECIPIENT must be a full 0x + 64 lowercase hex address, not zero" >&2; exit 2; }
for v in MAX_UNITS MAX_AHEAD_MS SUI_MIN_PER_UNIT USDC_MIN_PER_UNIT; do
  # A minimum of 0 would let a leaked quote key give the product away; limits are positive by the package's rules too.
  [[ -z "${!v:-}" || "${!v}" =~ ^[1-9][0-9]{0,19}$ ]] || { echo "${v} must be a positive integer" >&2; exit 2; }
done
if [[ -n "${USDC_TYPE:-}" ]]; then
  [[ "$USDC_TYPE" =~ ^0x[0-9a-f]{64}::usdc::USDC$ ]] || { echo "USDC_TYPE must be the full 0x…::usdc::USDC type" >&2; exit 2; }
fi
if [[ "$net" == mainnet && "$MERCHANT_RECIPIENT" == "$signer" ]]; then echo "mainnet: the recipient must not be the deploy key" >&2; exit 2; fi
key_vec="[$(sed 's/../0x&,/g; s/,$//' <<< "$QUOTE_PUBLIC_KEY")]"

ptb=(sui client ptb --gas-budget "$GAS_BUDGET" --json
  --move-call "${pkg}::chain_payments::create_merchant" "@${MERCHANT_RECIPIENT}" "vector${key_vec}" "${MAX_UNITS:-12}" "${MAX_AHEAD_MS:-63115200000}"
  --assign cap)
out="$("${ptb[@]}" --transfer-objects "[cap]" "@${signer}")"
succeeded "$out" || { echo "create_merchant failed: $(jq -c '.effects.status // .' <<< "$out" | head -c 400)" >&2; exit 1; }
# Created objects by their exact types (this package's), never by a suffix.
merchant="$(created_of_type "$out" "$pkg" chain_payments Merchant)"
mcap="$(created_of_type "$out" "$pkg" chain_payments MerchantCap)"
[[ -n "$merchant" && -n "$mcap" ]] || { echo "create_merchant succeeded but its objects could not be read: sui client tx-block $(jq -r '.digest' <<< "$out") --json" >&2; exit 1; }
# Record the merchant before anything else can fail, so a failed coin step never loses it.
tmp="$(mktemp)"
jq --arg n "$net" --arg m "$merchant" --arg c "$mcap" --arg r "$MERCHANT_RECIPIENT" \
  '.[$n].merchants = ((.[$n].merchants // []) + [{merchantId: $m, merchantCap: $c, recipient: $r}])' deployments.json > "$tmp"
mv "$tmp" deployments.json
echo "merchant ${merchant} (cap ${mcap}) on ${net}, recorded in deployments.json"
accept() { # <coin type> <min per unit>
  local res
  res="$(sui client ptb --gas-budget "$GAS_BUDGET" --json \
    --move-call "${pkg}::chain_payments::set_accepted" "<$1>" "@${mcap}" "@${merchant}" "$2")" || res=""
  if ! succeeded "$res"; then
    echo "set_accepted<$1> failed; resume with: sui client ptb --gas-budget ${GAS_BUDGET} --move-call ${pkg}::chain_payments::set_accepted \"<$1>\" @${mcap} @${merchant} $2" >&2
    exit 1
  fi
  echo "  accepts $1 (minimum ${2} per unit)"
}
if [[ -n "${SUI_MIN_PER_UNIT:-}" ]]; then accept 0x2::sui::SUI "$SUI_MIN_PER_UNIT"; fi
if [[ -n "${USDC_TYPE:-}" && -n "${USDC_MIN_PER_UNIT:-}" ]]; then accept "$USDC_TYPE" "$USDC_MIN_PER_UNIT"; fi
