#!/usr/bin/env bash
# Unseal data-system/vault-0.
#
# Usage:
#   ops/unseal-vault.sh
#
# There is no auto-unseal. A sealed Vault does not fail loudly on its own:
# vault-0 stays up while unrelated pods across the cluster hang in Init or
# Unknown waiting on secrets they can no longer read, so the symptom rarely
# points at Vault. Check vault-0 first when several unconnected workloads stall
# at once.
#
# Reads key shares one at a time with hidden input (no $(cat) whitespace
# mangling), resets any half-finished progress first, and stops as soon as Vault
# reports Sealed: false. Works with a local `vault` CLI over a port-forward, or
# falls back to `kubectl exec`.
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

NS=data-system
POD=vault-0
LOCAL_PORT="${LOCAL_PORT:-8200}"
CTX="${KUBE_CONTEXT:-personal}"

kubectl config use-context "$CTX" >/dev/null 2>&1 || true

PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

# --- pick transport -------------------------------------------------------
if command -v vault >/dev/null 2>&1; then
  echo ">> using local 'vault' CLI via port-forward localhost:${LOCAL_PORT} -> ${POD}:8200"
  kubectl -n "$NS" port-forward "pod/$POD" "${LOCAL_PORT}:8200" >/dev/null 2>&1 &
  PF_PID=$!
  export VAULT_ADDR="http://127.0.0.1:${LOCAL_PORT}"
  export VAULT_SKIP_VERIFY=true
  # wait for the forward to answer (sealed vault => 503 normally; sealedcode=200 makes it 200)
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "${VAULT_ADDR}/v1/sys/health?sealedcode=200&uninitcode=200" && break
    sleep 0.5
  done
  v()        { vault "$@"; }
else
  echo ">> 'vault' CLI not found locally — using kubectl exec into ${POD}"
  v()        { kubectl -n "$NS" exec -i "$POD" -- vault "$@"; }
fi

# `vault status` aligns its columns with spaces, not a colon.
sealed() { v status 2>/dev/null | awk '$1 == "Sealed" {print $2; exit}'; }

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
    echo
    echo "=== VAULT IS UNSEALED ==="
    break
  fi
done

echo
echo "=== final status ==="
v status || true
