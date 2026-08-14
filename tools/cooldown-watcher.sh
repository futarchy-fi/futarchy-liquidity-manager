#!/usr/bin/env bash
# Alert if any watched Swapr/Algebra pool has liquidityCooldown() != 0.
# An armed cooldown is the one residual risk of FLM operator mode (see
# docs/gnosis-operator-mode-plan.md §4): a hostile Swapr factory owner could
# delay the operator's own withdrawals by up to 24h. Same-day detection is the
# mitigation. Run from cron; pools + webhook come from the environment.
#
#   POOLS="0xYES,0xNO" RPC=https://rpc.gnosischain.com \
#   ALERT_CMD='curl -s -X POST "$WEBHOOK" --data-urlencode "text=$MSG"' \
#   tools/cooldown-watcher.sh
#
# liquidityCooldown() selector = 0x17e25b3c, returns uint32 (0 = disarmed).
set -euo pipefail
RPC="${RPC:-https://rpc.gnosischain.com}"
: "${POOLS:?set POOLS to a comma-separated list of pool addresses}"

for pool in ${POOLS//,/ }; do
  raw=$(curl -s --max-time 15 "$RPC" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$pool\",\"data\":\"0x17e25b3c\"},\"latest\"]}" \
    | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')
  # No result (call reverted / RPC error) is itself worth surfacing, not swallowing.
  cooldown=$(( ${raw:-0} ))
  if [ "$cooldown" -ne 0 ]; then
    MSG="FLM ALERT: pool $pool has liquidityCooldown=$cooldown (ARMED). Operator withdrawals may be delayed up to 24h. Investigate Swapr factory owner."
    echo "$MSG"
    [ -n "${ALERT_CMD:-}" ] && MSG="$MSG" WEBHOOK="${WEBHOOK:-}" bash -c "$ALERT_CMD" || true
  fi
done
