#!/usr/bin/env bash
# Transfer chain_payments authority objects from the deploy key to a multisig (CUSTODY.md).
#
# Objects (IDs from deployments.json, never guessed):
#   - PlatformAdminCap   the platform fee's rate (at most 1 %) and treasury
#   - MerchantCap        each recorded merchant's recipient (after its two-day delay), quote key, coins, pause, limits;
#                        only with --merchant <merchant object id> (repeatable), because a merchant may belong to someone
#                        other than the platform
# The UpgradeCap is not here: every release burns it at publish (publish.sh), so there is none to hold.
#
# Safety: every object is re-read on-chain first and must have this package's exact type and be owned by the active
# address; a MerchantCap must name the merchant it is recorded for. DRY_RUN=1 by default; DRY_RUN=0 asks for a typed
# YES. The recipient must be the multisig re-derived from MULTISIG_PKS / MULTISIG_WEIGHTS / MULTISIG_THRESHOLD, or the
# script refuses. Mainnet needs MAINNET_CONFIRM=1 and EXPECTED_SIGNER. Every object is re-read after the transfer.
#
# Usage:
#   MULTISIG_PKS="<pk1>" MULTISIG_WEIGHTS="1" MULTISIG_THRESHOLD=1 NETWORK=testnet MULTISIG_ADDRESS=0x… \
#     bash scripts/transfer-authority.sh [--merchant 0x…]...
#   DRY_RUN=0 … (the same) to execute.
set -euo pipefail
cd "$(dirname "$0")/.."
warn() { printf '%s\n' "$*" >&2; }
command -v jq > /dev/null || { warn "jq is required"; exit 2; }

NETWORK="${NETWORK:-testnet}"
DRY_RUN="${DRY_RUN:-1}"
MERCHANTS=()
while (( $# )); do
  case "$1" in
    --merchant) MERCHANTS+=("${2:?--merchant <merchant object id>}"); shift 2 ;;
    *) warn "unknown argument: $1"; exit 2 ;;
  esac
done
MULTISIG_ADDRESS="${MULTISIG_ADDRESS:?set MULTISIG_ADDRESS}"
[[ "$MULTISIG_ADDRESS" =~ ^0x[0-9a-fA-F]{64}$ ]] || { warn "MULTISIG_ADDRESS must be 0x + 64 hex"; exit 2; }

rec() { jq -r --arg n "$NETWORK" "$1" deployments.json; }
PACKAGE_ID="$(rec ".[\$n].packageId // empty")"
ADMIN_CAP="$(rec ".[\$n].platformAdminCap // empty")"
[[ -n "$PACKAGE_ID" && -n "$ADMIN_CAP" ]] || { warn "deployments.json has no ${NETWORK} package or PlatformAdminCap"; exit 2; }

env="$(sui client active-env 2>/dev/null || true)"
[[ "$env" == "$NETWORK" ]] || { warn "the active sui env is '${env:-none}', not $NETWORK"; exit 2; }
case "$NETWORK" in testnet) want=4c78adac ;; mainnet) want=35834a8a ;; *) want="" ;; esac
if [[ -n "$want" ]]; then
  chain="$(sui client chain-identifier 2> /dev/null | sed -n 's/^Hex: *//p')"
  [[ "$chain" == "$want" ]] || { warn "chain identifier ${chain:-unknown} is not $NETWORK"; exit 2; }
fi
ACTIVE="$(sui client active-address)"
long_addr() { local h="${1#0x}"; printf '0x%064s' "${h,,}" | tr ' ' 0; }
if [[ "$NETWORK" == mainnet ]]; then
  [[ "${MAINNET_CONFIRM:-}" == 1 ]] || { warn "mainnet: set MAINNET_CONFIRM=1"; exit 2; }
  [[ "$(long_addr "${EXPECTED_SIGNER:-0x0}")" == "$(long_addr "$ACTIVE")" ]] || { warn "mainnet: EXPECTED_SIGNER must be the active address"; exit 2; }
fi

: "${MULTISIG_PKS:?set MULTISIG_PKS}" "${MULTISIG_WEIGHTS:?set MULTISIG_WEIGHTS}" "${MULTISIG_THRESHOLD:?set MULTISIG_THRESHOLD}"
read -r -a PKS <<< "$MULTISIG_PKS"
read -r -a WEIGHTS <<< "$MULTISIG_WEIGHTS"
DERIVED="$(sui keytool multi-sig-address --pks "${PKS[@]}" --weights "${WEIGHTS[@]}" --threshold "$MULTISIG_THRESHOLD" --json 2> /dev/null | jq -r '.multisigAddress // empty')"
[[ -n "$DERIVED" && "$(long_addr "$DERIVED")" == "$(long_addr "$MULTISIG_ADDRESS")" ]] \
  || { warn "MULTISIG_ADDRESS is not the multisig of those keys, weights and threshold (that is ${DERIVED:-unknown}); nothing sent"; exit 1; }

PKG="$(long_addr "$PACKAGE_ID")"
# verify <id> <label> <type> [<merchant id the cap must name>]
verify() {
  local json typ owner named
  json="$(sui client object "$1" --json 2> /dev/null)" || { warn "cannot read $2 ($1)"; exit 1; }
  typ="$(jq -r '.objType // empty' <<< "$json")"
  owner="$(jq -r '.owner.AddressOwner // empty' <<< "$json")"
  [[ "$typ" == "$3" ]] || { warn "$2 $1 has type '$typ', not '$3'"; exit 1; }
  [[ "$(long_addr "$owner")" == "$(long_addr "$ACTIVE")" ]] || { warn "$2 $1 is not owned by the active address"; exit 1; }
  if [[ -n "${4:-}" ]]; then
    named="$(jq -r '.content.merchant_id // empty' <<< "$json")"
    [[ "$(long_addr "$named")" == "$(long_addr "$4")" ]] || { warn "$2 $1 names merchant '$named', not $4"; exit 1; }
  fi
  echo "OK    $2 $1"
}

IDS=("$ADMIN_CAP"); LABELS=("PlatformAdminCap")
verify "$ADMIN_CAP" PlatformAdminCap "${PKG}::chain_payments::PlatformAdminCap"
for m in "${MERCHANTS[@]}"; do
  cap="$(jq -r --arg n "$NETWORK" --arg m "$(long_addr "$m")" '.[$n].merchants[]? | select((.merchantId | ascii_downcase) == $m) | .merchantCap' deployments.json)"
  [[ -n "$cap" ]] || { warn "no MerchantCap recorded for merchant $m"; exit 2; }
  verify "$cap" "MerchantCap($m)" "${PKG}::chain_payments::MerchantCap" "$m"
  IDS+=("$cap"); LABELS+=("MerchantCap($m)")
done

echo; echo "Transfer to $MULTISIG_ADDRESS on $NETWORK:"; for i in "${!IDS[@]}"; do echo "  ${LABELS[$i]}  ${IDS[$i]}"; done; echo
[[ "$DRY_RUN" == 0 ]] || { echo "Dry run: nothing sent. DRY_RUN=0 to execute."; exit 0; }
read -r -p "Type YES to transfer these objects: " ok
[[ "$ok" == YES ]] || { warn "aborted"; exit 1; }
for i in "${!IDS[@]}"; do
  out="$(sui client transfer --object-id "${IDS[$i]}" --to "$MULTISIG_ADDRESS" --gas-budget 10000000 --json 2>&1)" \
    || { warn "transferring ${LABELS[$i]} failed: $out"; warn "the ones before it were sent; re-run for the rest (ownership is re-checked)"; exit 1; }
done
for i in "${!IDS[@]}"; do
  owner="$(sui client object "${IDS[$i]}" --json 2> /dev/null | jq -r '.owner.AddressOwner // empty')"
  [[ "$(long_addr "$owner")" == "$(long_addr "$MULTISIG_ADDRESS")" ]] || { warn "${LABELS[$i]} is owned by '${owner:-unknown}' after the transfer"; exit 1; }
  echo "OK    ${LABELS[$i]} now owned by the multisig"
done
tmp="$(mktemp)"
jq --arg n "$NETWORK" --arg ms "$MULTISIG_ADDRESS" --argjson merchants "$(printf '%s\n' "${MERCHANTS[@]}" | jq -R . | jq -s 'map(ascii_downcase)')" \
  '.[$n].custody.multisigAddress = $ms | .[$n].custody.platformAdminCapOwner = $ms
   | .[$n].merchants |= map(if (.merchantId | ascii_downcase) as $id | ($merchants | index($id)) then .merchantCapOwner = $ms else . end)' \
  deployments.json > "$tmp" && mv "$tmp" deployments.json
echo "Recorded in deployments.json; commit it."
