#!/usr/bin/env bash
# Diagnose (and optionally recover) a frozen apiserver watch cache.
#
# Usage:
#   ops/recover-wedged-apiserver-cache.sh                        # diagnose only, read-only
#   ops/recover-wedged-apiserver-cache.sh --install-dns-fallback # household DNS while wedged
#   ops/recover-wedged-apiserver-cache.sh --fix                  # restart the control plane
#   ops/recover-wedged-apiserver-cache.sh --remove-dns-fallback  # after --fix has verified
#
# DEFAULT IS READ-ONLY. Nothing is changed unless a flag asks for it.
#
# The failure this addresses (first seen 2026-09-02, diagnosed 2026-09-04):
# a control-plane stall desynced the apiserver's cacher for one resource, kine
# then compacted past the revision the cacher wanted, and the cacher's re-list
# can never succeed again. It is a permanent wedge with no API-level remedy --
# restarting the k3s server is the only way to reinitialise a cacher.
#
# It presents as "a node is Ready but runs nothing", which sends you to the
# node. The node is a victim. See ops/runbooks/apiserver-watch-cache-wedge.md.
#
# Why a restart is the fix and not a workaround: there is no endpoint, flag or
# kubectl verb that resets a single cacher. k3s here is a single-node control
# plane on kine/SQLite, so there is no quorum to lose, the unit is
# Restart=always, and running pods survive an apiserver bounce.
set -euo pipefail

CTX="${KUBE_CONTEXT:-personal}"
CP_HOST="${CP_HOST:-167.86.79.203}"
CP_SSH_PORT="${CP_SSH_PORT:-2222}"
CP_SSH_USER="${CP_SSH_USER:-deploy}"
CP_SSH_KEY="${CP_SSH_KEY:-$HOME/.ssh/ps-fleet}"
DNS_NODE="${DNS_NODE:-100.103.175.110}"
MANIFEST_DIR=/var/lib/rancher/k3s/agent/pod-manifests
MANIFEST_NAME=adguard-static.yaml
# Resources worth checking. The nodes cacher is the one that wedged and the one
# whose failure stops kubelets dead, but the mechanism is not nodes-specific.
RESOURCES=("nodes" "pods" "services")

MODE=diagnose

k() { kubectl --context "$CTX" "$@"; }
say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

cp_ssh() {
  ssh -i "$CP_SSH_KEY" -p "$CP_SSH_PORT" \
    -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "${CP_SSH_USER}@${CP_HOST}" "$@"
}

node_ssh() {
  ssh -i "$CP_SSH_KEY" -p "$CP_SSH_PORT" \
    -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "${CP_SSH_USER}@${DNS_NODE}" "$@"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fix) MODE=fix ;;
    --install-dns-fallback) MODE=install-dns ;;
    --remove-dns-fallback) MODE=remove-dns ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# --- measurement helpers -----------------------------------------------------
#
# The whole diagnosis rests on one asymmetry, so both halves are measured
# rather than inferred:
#
#   resourceVersion=0   -> served from the watch cache, may be arbitrarily stale
#   (no resourceVersion) -> demands a consistent read, must reach the datastore
#
# A frozen cacher answers the first happily. That is why a check written with
# resourceVersion=0 reports a healthy cluster while every informer hangs -- the
# earlier investigation of this incident dead-ended on exactly that.

cached_rv() {
  k get --raw "/api/v1/$1?resourceVersion=0" 2>/dev/null \
    | grep -oE '"resourceVersion":"[0-9]+"' | head -1 | grep -oE '[0-9]+' || true
}

live_rv() {
  k get --raw "/api/v1/$1" 2>/dev/null \
    | grep -oE '"resourceVersion":"[0-9]+"' | head -1 | grep -oE '[0-9]+' || true
}

# The exact request a client-go reflector makes. No resourceVersion at all.
#
# `timeout` execs its argument directly, so it cannot run the k() function --
# kubectl is spelled out here on purpose. This is also a watch, so it never
# returns on a healthy resource; the timeout is what ends it.
reflector_probe() {
  timeout 12 kubectl --context "$CTX" get --raw \
    "/api/v1/$1?watch=true&sendInitialEvents=true&allowWatchBookmarks=true&resourceVersionMatch=NotOlderThan&resourceVersion=" \
    2>&1 | head -c 600 || true
}

wedged_resources=()

diagnose() {
  say "watch cache vs datastore, per resource"
  printf '   %-10s %-14s %-14s %s\n' RESOURCE CACHED LIVE VERDICT
  for r in "${RESOURCES[@]}"; do
    c="$(cached_rv "$r")"
    l="$(live_rv "$r")"
    if [ -z "$c" ] || [ -z "$l" ]; then
      printf '   %-10s %-14s %-14s %s\n' "$r" "${c:-?}" "${l:-?}" "UNREADABLE"
      continue
    fi
    # The datastore RV advances constantly, so a small gap is normal and only a
    # large, non-closing one indicates a wedge.
    gap=$((l - c))
    if [ "$gap" -gt 10000 ]; then
      printf '   %-10s %-14s %-14s %s\n' "$r" "$c" "$l" "WEDGED (gap ${gap})"
      wedged_resources+=("$r")
    else
      printf '   %-10s %-14s %-14s %s\n' "$r" "$c" "$l" "ok (gap ${gap})"
    fi
  done

  say "reflector-shaped probe (the request that actually hangs)"
  for r in "${RESOURCES[@]}"; do
    out="$(reflector_probe "$r")"
    if printf '%s' "$out" | grep -q "Too large resource version"; then
      note "$r: WEDGED -- $(printf '%s' "$out" | grep -oE 'Too large resource version: [0-9]+, current: [0-9]+')"
    elif printf '%s' "$out" | grep -qE '"type":"(ADDED|BOOKMARK)"'; then
      note "$r: ok (stream opened)"
    else
      note "$r: inconclusive -- $(printf '%s' "$out" | head -c 120)"
    fi
  done

  say "kine compaction errors on the control plane (cause of the permanent wedge)"
  cp_ssh 'sudo journalctl -u k3s --since "-6h" --no-pager 2>/dev/null \
            | grep -c "required revision has been compacted"' 2>/dev/null \
    | sed 's/^/   occurrences in 6h: /' || note "could not read the journal"

  say "downstream damage"
  taints="$(k get nodes -o json 2>/dev/null \
    | grep -c '"key":"node.kubernetes.io/unreachable"' || true)"
  note "unreachable taints on nodes: ${taints:-0} (re-applied from the frozen cache while wedged)"
  k get pods -A --no-headers 2>/dev/null \
    | awk '{c[$4]++} END {for (s in c) printf "   %-22s %d\n", s, c[s]}'

  if [ "${#wedged_resources[@]}" -gt 0 ]; then
    say "VERDICT: wedged (${wedged_resources[*]})"
    note "Recover with: $0 --fix"
    note "Household DNS meanwhile: $0 --install-dns-fallback"
    return 1
  fi
  say "VERDICT: no frozen cacher detected"
  return 0
}

# --- actions -----------------------------------------------------------------

install_dns() {
  say "installing the break-glass AdGuard static pod on ${DNS_NODE}"
  local src
  src="$(dirname "$0")/break-glass/adguard-static-pod.yaml"
  [ -f "$src" ] || die "missing $src"
  # Strip the repo-only header so what lands on the node is byte-identical to
  # the "verbatim content" block. awk, not sed: `sed '/marker/,$!d;1d'` deletes
  # input line 1 rather than the marker line, so the marker survives into the
  # output and the copies drift by a line.
  awk 'flag { print } /^# ---- verbatim content as deployed ----$/ { flag = 1 }' "$src" \
    | node_ssh "sudo tee ${MANIFEST_DIR}/${MANIFEST_NAME} >/dev/null" \
    || die "could not write the manifest"
  note "written to ${MANIFEST_DIR}/${MANIFEST_NAME}"
  note "kubelet picks static pods up on its own; verify with --install-dns-fallback's output below"
  verify_dns || die "static pod did not come up"
  say "household DNS restored via the static pod"
  note "This is a stopgap. It does not fix the cluster; run --fix for that."
}

verify_dns() {
  say "verifying DNS actually answers (not merely that a container started)"
  local ok=1
  # Resolution.
  if dig +short +timeout=4 +tries=1 "@${DNS_NODE}" example.com A 2>/dev/null | grep -qE '^[0-9]'; then
    note "resolution: OK"
  else
    note "resolution: FAILED"; ok=0
  fi
  # Filtering -- proves it is AdGuard answering and its blocklists loaded,
  # not some other resolver on :53.
  if [ "$(dig +short +timeout=4 +tries=1 "@${DNS_NODE}" doubleclick.net A 2>/dev/null | head -1)" = "0.0.0.0" ]; then
    note "filtering: OK (doubleclick.net -> 0.0.0.0)"
  else
    note "filtering: not confirmed"
  fi
  [ "$ok" = 1 ]
}

remove_dns() {
  say "removing the break-glass static pod from ${DNS_NODE}"
  # Ordering matters: while the static pod holds :53, the real Deployment stays
  # Pending on "no free ports". The mirror pod never registers when the node
  # informer is wedged, so the scheduler does not know the port is taken and
  # could place the real pod here and crash-loop it against the static one.
  diagnose >/dev/null 2>&1 || die "the cache is still wedged -- run --fix first, or DNS will simply go down"
  node_ssh "sudo rm -f ${MANIFEST_DIR}/${MANIFEST_NAME}" || die "could not remove the manifest"
  note "manifest removed; kubelet will tear the static pod down"
  say "waiting for the real adguard Deployment to take over"
  k rollout status deploy/adguard -n utility-system --timeout=180s \
    || die "the adguard Deployment did not become available -- reinstall the fallback with --install-dns-fallback"
  verify_dns || die "the Deployment is Available but DNS does not answer"
  say "the real adguard Deployment is serving DNS again"
}

fix() {
  say "pre-state"
  diagnose || true
  local before_cached before_live
  before_cached="$(cached_rv nodes)"
  before_live="$(live_rv nodes)"

  say "restarting k3s on the control plane (${CP_HOST})"
  printf '   This bounces the apiserver. Running pods survive it; in-flight\n'
  printf '   API calls and watches do not. It is the only way to reinitialise\n'
  printf '   a wedged cacher.\n'
  cp_ssh 'sudo systemctl restart k3s' || die "restart failed"
  note "restart issued"

  say "waiting for the API to come back"
  for _ in $(seq 1 60); do
    if k get --raw /readyz >/dev/null 2>&1; then note "API is serving"; break; fi
    sleep 5
  done
  k get --raw /readyz >/dev/null 2>&1 || die "the API did not come back -- check 'systemctl status k3s' on ${CP_HOST}"

  # Verify the value, not the command. A successful restart proves nothing
  # about the cacher; only a tracking RV and a clean reflector probe do.
  say "post-state"
  wedged_resources=()
  if diagnose; then
    say "RECOVERED"
    note "nodes cacher before: cached=${before_cached} live=${before_live}"
    note "nodes cacher now:    cached=$(cached_rv nodes) live=$(live_rv nodes)"
    note "Next: clear any stale unreachable taints, then $0 --remove-dns-fallback"
  else
    die "still wedged after the restart -- do not retry blindly, read the runbook"
  fi
}

case "$MODE" in
  diagnose)   diagnose ;;
  fix)        fix ;;
  install-dns) install_dns ;;
  remove-dns) remove_dns ;;
esac
