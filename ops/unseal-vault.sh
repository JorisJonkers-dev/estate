#!/usr/bin/env bash
# Unseal the running Vault pod, found by label.
#
# Usage:
#   ops/unseal-vault.sh
#
#   KUBE_CONTEXT     the kubectl context (default personal)
#   VAULT_NS         pin the namespace; VAULT_POD pins the pod (see lib/vault.sh)
#   VAULT_SELECTOR   the label that finds the pod (default app.kubernetes.io/name=vault)
#   LOCAL_PORT       local end of the port-forward when a vault CLI is installed (default 8200)
#
# There is no auto-unseal. A sealed Vault does not fail loudly on its own:
# the pod stays up while unrelated pods across the cluster hang in Init or
# Unknown waiting on secrets they can no longer read, so the symptom rarely
# points at Vault. Check Vault first when several unconnected workloads stall
# at once.
#
# Nothing here names Vault's namespace or pod: it has moved before, and a name
# that is wrong makes every share go to a connection that cannot answer. The
# pod is found by label (lib/vault.sh), shown before any share is asked for, and
# the script stops unless exactly one running pod matches.
#
# Reads key shares one at a time with hidden input (no $(cat) whitespace
# mangling), resets any half-finished progress first, and stops as soon as Vault
# reports Sealed false. It exits 0 only after reading that back; running out of
# shares exits 1. Works with a local `vault` CLI over a port-forward, or falls
# back to `kubectl exec`.
#
# The share is passed to `vault operator unseal` as an argument, which puts it in
# the process list for the life of the call. That is deliberate and should not be
# "fixed" by piping it instead: vault refuses a non-TTY stdin outright --
#
#   file descriptor 0 is not a terminal
#   ... If this is not an option, the unseal key can be provided as the first
#   argument to the unseal command.
#
# -- so argv is the only form that works from a script that manages its own
# retry and reset logic. Verified against a sealed Vault 1.21.2.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vault.sh
source "$here/lib/vault.sh"

LOCAL_PORT="${LOCAL_PORT:-8200}"
CTX="${KUBE_CONTEXT:-personal}"

# --context rather than `kubectl config use-context`: a script that unseals
# should not change which cluster the caller's next command talks to.
k() { kubectl --context "$CTX" "$@"; }

PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

vault_locate || exit 1
TARGET="pod/$VAULT_POD"
echo ">> vault pod: ${VAULT_NS}/${VAULT_POD} (context ${CTX})"

# --- pick transport -------------------------------------------------------
if command -v vault >/dev/null 2>&1; then
  echo ">> using local 'vault' CLI via port-forward localhost:${LOCAL_PORT} -> ${TARGET}:8200"
  k -n "$VAULT_NS" port-forward "$TARGET" "${LOCAL_PORT}:8200" >/dev/null 2>&1 &
  PF_PID=$!
  export VAULT_ADDR="http://127.0.0.1:${LOCAL_PORT}"
  # wait for the forward to answer (sealed vault => 503 normally; sealedcode=200 makes it 200)
  forwarded=no
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "${VAULT_ADDR}/v1/sys/health?sealedcode=200&uninitcode=200"; then
      forwarded=yes
      break
    fi
    sleep 0.5
  done
  if [[ "$forwarded" != yes ]]; then
    echo "!! the port-forward to ${VAULT_NS}/${VAULT_POD} never answered; no share was asked for." >&2
    exit 1
  fi
  v() { vault "$@"; }
else
  echo ">> 'vault' CLI not found locally — using kubectl exec into ${TARGET}"
  v() { k -n "$VAULT_NS" exec -i "$TARGET" -- vault "$@"; }
fi

# `vault status` prints a Key/Value table and exits 2 while sealed, so read the
# second column of the Sealed row and ignore the exit code.
sealed() { v status 2>/dev/null | awk '$1 == "Sealed" { print $2; exit }' | tr -d '[:space:]'; }

echo
echo "=== current status ==="
v status || true

if [[ "$(sealed)" == "false" ]]; then
  echo ">> already unsealed, nothing to do."
  exit 0
fi

echo
echo ">> resetting any partial unseal progress..."
v operator unseal -reset >/dev/null 2>&1 || true

echo
echo "Enter unseal key shares one at a time (input hidden)."
echo "Blank line aborts. It will stop automatically once unsealed."
echo
attempt=0
opened=no
while :; do
  printf "Unseal key share #%d: " "$((attempt + 1))"
  IFS= read -rs KEY
  echo
  # strip ALL whitespace (base64 shares contain none) to kill paste/newline cruft
  KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"
  if [[ -z "$KEY" ]]; then
    echo ">> no key entered — aborting."
    break
  fi
  attempt=$((attempt + 1))
  if ! v operator unseal "$KEY"; then
    echo "!! that share was REJECTED (see error above)."
    echo "   If this says 'message authentication failed', the share is wrong"
    echo "   or belongs to a different Vault init. Resetting progress."
    v operator unseal -reset >/dev/null 2>&1 || true
    attempt=0
    continue
  fi
  if [[ "$(sealed)" == "false" ]]; then
    opened=yes
    echo
    echo "=== VAULT IS UNSEALED ==="
    break
  fi
done

echo
echo "=== final status ==="
v status || true
[[ "$opened" == yes ]]
