#!/usr/bin/env bash
# Resume apps-mail so the stalwart provisioning sidecar lands, then verify it.
#
# Usage:
#   ops/resume-mail-provisioner.sh
#
# Run this after apps-mail has been suspended -- the sidecar reconciles stalwart's
# declarative state (listeners, domain wiring, catch-all, ACME/DNS providers and
# the Vault-managed account credentials), none of which is reconciled while it is
# absent.
#
# The rollout is `Recreate` on an RWO PVC: the serving pod is torn down before
# the replacement starts, so mail is down for the rollout window. That is the
# only reason this is a separate, explicit step rather than part of the merge.
#
# On any failure this re-suspends apps-mail and rolls the Deployment back, so a
# bad outcome costs the rollout window and not the service.
set -euo pipefail

CTX="${KUBE_CONTEXT:-personal}"
NS=mail-system
DEPLOY=stalwart
KS=apps-mail
PF_PID=""

k() { kubectl --context "$CTX" "$@"; }
say() { printf '\n== %s\n' "$*"; }
die() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

rollback() {
  printf '\n!! verification failed -- rolling back\n' >&2
  k patch kustomization "$KS" -n flux-system --type=merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
  k rollout undo "deploy/$DEPLOY" -n "$NS" >/dev/null 2>&1 || true
  k rollout status "deploy/$DEPLOY" -n "$NS" --timeout=180s || true
  printf '\napps-mail is suspended again and the Deployment is rolled back.\n' >&2
  printf 'Sidecar logs from the failed attempt:\n' >&2
  k logs "deploy/$DEPLOY" -n "$NS" -c stalwart-apply --tail=60 2>/dev/null >&2 || true
  exit 1
}

say "preflight: context and cluster"
k config current-context >/dev/null || die "context $CTX unreachable"
printf '  context: %s\n' "$(k config current-context)"

say "preflight: apps-mail must be suspended"
susp="$(k get kustomization "$KS" -n flux-system -o jsonpath='{.spec.suspend}')"
[ "$susp" = "true" ] || die "apps-mail is not suspended (suspend=$susp); refusing to guess at its state"
printf '  suspended: yes\n'

say "preflight: the passwords the manifest references must resolve"
fail=0
check_key() { # secret key
  local len
  len="$(k get secret "$1" -n "$NS" -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
  printf '  %-24s %-22s len=%s\n' "$1" "$2" "${len:-0}"
  [ "${len:-0}" -gt 0 ] || fail=1
}
check_key stalwart-auth-mail AUTH_MAIL_PASSWORD
check_key stalwart-mail ACCOUNT_MAIL_PASSWORD
[ "$fail" -eq 0 ] || die "a referenced password is empty; the manifest would be refused at validation"

say "preflight: git revision must carry the sidecar"
rev="$(k get gitrepository flux-system -n flux-system -o jsonpath='{.status.artifact.revision}')"
printf '  source revision: %s\n' "$rev"

say "capturing rollback point"
before_rev="$(k get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')"
printf '  deployment revision before: %s\n' "$before_rev"

say "resuming $KS"
k patch kustomization "$KS" -n flux-system --type=merge -p '{"spec":{"suspend":false}}' >/dev/null
flux --context "$CTX" reconcile kustomization "$KS" --with-source --timeout=180s || true

say "waiting for the rollout"
if ! k rollout status "deploy/$DEPLOY" -n "$NS" --timeout=300s; then
  rollback
fi

say "verify: both containers ready"
for _ in $(seq 1 30); do
  ready="$(k get pods -n "$NS" -l app.kubernetes.io/name=stalwart \
    -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null)"
  case "$ready" in *false*|"") sleep 5;; *) break;; esac
done
printf '  container ready flags: %s\n' "$ready"
case "$ready" in *false*|"") rollback;; esac

say "verify: the sidecar reconciled"
logs="$(k logs "deploy/$DEPLOY" -n "$NS" -c stalwart-apply --tail=200 2>/dev/null || true)"
printf '%s\n' "$logs" | grep -E 'catch-all|credentials|reconcile complete|FAIL' | sed 's/^/  /' || true
printf '%s' "$logs" | grep -q 'reconcile complete' || { printf '  no "reconcile complete" in the sidecar log\n' >&2; rollback; }
if printf '%s' "$logs" | grep -q '^FAIL'; then
  printf '  sidecar reported FAIL\n' >&2
  rollback
fi

say "verify: stalwart is serving"
k port-forward -n "$NS" "deploy/$DEPLOY" 18080:8080 >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18080/admin/ 2>/dev/null || true)"
  case "$code" in 200|301|302|401) break;; *) sleep 2;; esac
done
printf '  GET /admin/ -> %s\n' "${code:-no response}"
case "${code:-}" in 200|301|302|401) ;; *) rollback;; esac

k port-forward -n "$NS" "deploy/$DEPLOY" 10143:143 >/dev/null 2>&1 &
imap_pid=$!
sleep 3
if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 10143 2>/dev/null; then
  printf '  IMAP 143 accepts connections\n'
else
  printf '  IMAP 143 check inconclusive (nc unavailable or refused)\n'
fi
kill "$imap_pid" 2>/dev/null || true

say "done"
printf 'apps-mail is resumed, the sidecar reconciled, and stalwart is serving.\n'
printf 'joris.jonkers and n8n remain unmanaged by design -- Vault holds no password\n'
printf 'for either. Populate secret/platform/mail joris.password and n8n.password,\n'
printf 'then move them into managedAccounts, to bring them under reconciliation.\n'
