#!/usr/bin/env bash
# Reagent step 0b, part 2 (ported from Touchstone script/demo/warmup.sh; spec OQ-2): reference swaps through the RefDriver for at least 1.5 x (GRID_SEC + REF_WINDOW)
# (900 s on DEMO, 1,260 s on TEST) before the vault is deployed, so the reference pool holds a TWAP history. A bounded random walk around the
# start tick; one swap per SPACING seconds (>= (GRID_SEC + REF_WINDOW) / MIN_CARD = 0.6 s).
# Usage: RPC=<rpc of 1301 or 11155111> DRIVER=<RefDriver> POOL=<v3 pool> DURATION=960 script/deploy/warmup.sh
# Needs DEPLOYER_PK in the environment (never printed). cast takes it as --private-key, so it is visible to local
# process listings while a swap is sent: run on a single-user machine, testnet keys only.
set -euo pipefail
: "${RPC:?}" "${DRIVER:?}" "${POOL:?}" "${DEPLOYER_PK:?}"
DURATION=${DURATION:-960}
SPACING=${SPACING:-15}
CENTER=${CENTER:-196250}
CID=$(cast chain-id --rpc-url "$RPC"); case "$CID" in 1301|11155111) ;; *) echo "not a Reagent chain: $CID"; exit 1;; esac
end=$(( $(date +%s) + DURATION ))
i=0
while [ "$(date +%s)" -lt "$end" ]; do
  tick=$(cast call "$POOL" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' --rpc-url "$RPC" 2>/dev/null | sed -n 2p | awk '{print $1}' || true)
  # a failed read is retried next round, never fatal (tools review m-7)
  if [ -z "$tick" ]; then echo "$(date +%T) read failed; retrying next round"; sleep "$SPACING"; continue; fi
  r=$(( RANDOM % 100 ))
  if [ "$tick" -gt $((CENTER + 250)) ]; then dir=true; elif [ "$tick" -lt $((CENTER - 250)) ]; then dir=false;
  elif [ $((RANDOM % 2)) -eq 0 ]; then dir=true; else dir=false; fi
  if [ "$dir" = true ]; then amt=$(( (300 + r * 40) * 1000000 )); else amt="$(( 100 + r * 13 ))000000000000000"; fi
  # a failed send (e.g. a load-balanced RPC answering a stale nonce) is logged and retried next round, never fatal
  if ! cast send "$DRIVER" 'swap(bool,uint256,uint160)' "$dir" "$amt" 0 --rpc-url "$RPC" --private-key "$DEPLOYER_PK" >/dev/null 2>&1; then
    echo "$(date +%T) send failed; retrying next round"; sleep "$SPACING"; continue
  fi
  i=$((i + 1))
  echo "$(date +%T) swap $i zeroForOne=$dir tick_before=$tick"
  sleep "$SPACING"
done
echo "warm-up done: $i swaps"
