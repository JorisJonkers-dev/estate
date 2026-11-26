#!/usr/bin/env bash
#
# Why a LiteLLM provider has no models in the catalogue: follows each provider
# key from Vault to the catalogue sync's pod and prints where it stops. Read
# only; no value is ever shown, only a 12-character SHA-256 fingerprint.
#
#   ops/litellm-catalog-keys.sh           check every key the catalogue sync reads
#   ops/litellm-catalog-keys.sh --sync    then start a catalogue run and show its log
#
# Per key it reports four things:
#   vault     the field in secret/platform/litellm: set (with fingerprint), empty or missing
#   synced    the field in the Kubernetes Secret VSO writes from that document
#   same      whether the synced value has the Vault value's fingerprint (a stale copy if not)
#   models    the provider's model count in the last catalogue run, and its probe statuses
# It also lists the Vault fields no catalogue env reads, which is where a key
# written under a wrong name ends up.
#
# Vault is reached the way bootstrap/secrets.sh reaches it: a port-forward to
# svc/vault and OIDC sign-in with your estate account (lib/estate.sh
# vault_connect). The Secret read and the port-forward need the admin context
# (lib/kube.sh), so the sudo password is asked once.
#
# Environment: KUBE_CONTEXT (personal; its -admin context is used) or
# ESTATE_KUBE_CONTEXT, ESTATE_VAULT_ADDR as in lib/estate.sh;
# LITELLM_NAMESPACE (litellm-system), LITELLM_CRONJOB (litellm-catalog),
# LITELLM_KV_PATH (platform/litellm), CATALOG_REPO
# (JorisJonkers-dev/litellm-model-catalog).

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# Like the other scripts here: KUBE_CONTEXT (default personal), used through its -admin context.
KUBE_CONTEXT=${KUBE_CONTEXT:-personal}
export ESTATE_KUBE_CONTEXT=${ESTATE_KUBE_CONTEXT:-$KUBE_CONTEXT-admin}
# shellcheck source=../bootstrap/lib/wizard.sh
source "$here/../bootstrap/lib/wizard.sh"
# shellcheck source=../bootstrap/lib/estate.sh
source "$here/../bootstrap/lib/estate.sh"
(( BASH_VERSINFO[0] >= 4 )) || die "bash 4 or newer is needed (macOS: brew install bash)"

NS=${LITELLM_NAMESPACE:-litellm-system}
CRONJOB=${LITELLM_CRONJOB:-litellm-catalog}
KV_PATH=${LITELLM_KV_PATH:-platform/litellm}
CATALOG_REPO=${CATALOG_REPO:-JorisJonkers-dev/litellm-model-catalog}

SYNC=""
case "${1:-}" in
  "") ;;
  --sync) SYNC=yes ;;
  -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

require_tools kubectl vault jq curl gh
# A heading that, unlike the wizard's stage, keeps the earlier output on screen.
section() { printf '\n%s%s▸ %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"; }
WORK=$(umask 077 && mktemp -d)
trap estate_cleanup EXIT
trap 'exit 130' INT TERM

section "Cluster"
[[ -n "$KUBE_CTX" ]] || die "kubectl has no current context: set ESTATE_KUBE_CONTEXT"
[[ -n "$_KUBECTL_CUSTOM" ]] || kube_prime "$KUBE_CTX" || exit 1
ok "context $KUBE_CTX"

# Every env of the CronJob that comes from a Secret: env name, Secret, key.
$KUBECTL -n "$NS" get cronjob "$CRONJOB" -o json <"$KUBE_STDIN" \
  | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].env[]
           | select(.valueFrom.secretKeyRef) | [.name, .valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key] | @tsv' \
  >"$WORK/refs" || die "cannot read cronjob $NS/$CRONJOB"
[[ -s "$WORK/refs" ]] || die "cronjob $NS/$CRONJOB reads no Secret"
ok "cronjob $NS/$CRONJOB reads $(wc -l <"$WORK/refs" | tr -d ' ') env values from Secrets"

# The synced Secrets, decoded, kept in $WORK only.
for secret in $(cut -f2 "$WORK/refs" | sort -u); do
  if $KUBECTL -n "$NS" get secret "$secret" -o json <"$KUBE_STDIN" \
       | jq -c '.data // {} | map_values(@base64d)' >"$WORK/secret.$secret" 2>/dev/null; then
    ok "Secret $NS/$secret holds $(jq 'length' "$WORK/secret.$secret") fields"
  else
    printf '{}' >"$WORK/secret.$secret"
    warn "Secret $NS/$secret is missing or unreadable: VSO has not written it"
  fi
done

section "Vault"
vault_connect
kv_load "$KV_PATH" >"$WORK/vault"
ok "secret/$KV_PATH holds $(jq 'length' "$WORK/vault") fields"

section "Catalogue"
catalogue=""
if sha=$(gh api "repos/$CATALOG_REPO/contents/model-catalog.json" --jq .sha 2>/dev/null) \
   && gh api "repos/$CATALOG_REPO/git/blobs/$sha" --jq .content 2>/dev/null | base64 -d >"$WORK/catalog.json" 2>/dev/null; then
  catalogue="$WORK/catalog.json"
  ok "catalogue of $(jq -r .updated_at "$catalogue") read from $CATALOG_REPO"
else
  warn "cannot read the catalogue from $CATALOG_REPO (gh auth?); the models column stays empty"
fi

# models ENV prints "<count> <status:n,...>" for the provider whose key_env is ENV.
models() {
  [[ -n "$catalogue" ]] || { printf -- '-'; return; }
  jq -r --arg env "$1" '
    [.providers | to_entries[] | select(.value.metadata.key_env == $env) | .value.metadata][0]
    | if . == null then "-"
      else "\(.count) \(.by_status | to_entries | map("\(.key):\(.value)") | join(","))" end' "$catalogue"
}

section "Keys"
printf '\n  %-28s %-26s %-9s %-6s %s\n' ENV "VAULT FIELD" SYNCED SAME MODELS
problems=0
while IFS=$'\t' read -r env secret key; do
  v=$(kv_field "$(cat "$WORK/vault")" "$key")
  s=$(jq -r --arg k "$key" '.[$k] // empty' "$WORK/secret.$secret")
  if jq -e --arg k "$key" 'has($k)' "$WORK/vault" >/dev/null; then
    if [[ -n "$v" ]]; then vstate="set $(fp "$v")"; else vstate="empty"; fi
  else
    vstate="missing"
  fi
  if [[ -n "$s" ]]; then sstate="yes"; else sstate="no"; fi
  same="-"
  if [[ -n "$v" && -n "$s" ]]; then
    if [[ "$v" == "$s" ]]; then same="yes"; else same="NO"; fi
  fi
  m=$(models "$env")
  colour=""
  if [[ -n "$v" && ( "$sstate" == no || "$same" == NO ) ]]; then
    colour=$RED; problems=$((problems + 1))
  elif [[ -n "$v" && "${m%% *}" == 0 ]]; then
    colour=$YELLOW; problems=$((problems + 1))
  elif [[ -z "$v" ]]; then
    colour=$DIM
  fi
  printf '  %s%-28s %-26s %-9s %-6s %s%s\n' "$colour" "$env" "$key: ${vstate%% *}" "$sstate" "$same" "$m" "$RESET"
done < <(sort -k3 "$WORK/refs")

# Vault fields with a value that no catalogue env reads: a key under a wrong name lands here.
stray=$(jq -r 'to_entries[] | select(.value != "") | .key' "$WORK/vault" \
  | grep -vxF -f <(cut -f3 "$WORK/refs") \
  | grep -vx -e master_key -e salt_key -e oidc_client_secret -e catalog_pr_token || true)

printf '\n'
if [[ -n "$stray" ]]; then
  warn "Vault fields with a value that the catalogue sync never reads (a wrong name?):"
  while read -r f; do note "    $f"; done <<<"$stray"
  note "  The names it reads are the VAULT FIELD column above; rename with bootstrap/secrets.sh --only litellm."
fi
# A key missing here may sit in another document: walk the whole `secret` mount
# (names only, values never leave Vault's answer) and report each field whose
# name holds a missing provider's stem, e.g. "axforge" for axforge_api_key.
missing=$(while IFS=$'\t' read -r _ _ key; do
  [[ -n "$(kv_field "$(cat "$WORK/vault")" "$key")" ]] || printf '%s\n' "${key%%_*}"
done <"$WORK/refs" | sort -u)
if [[ -n "$missing" ]]; then
  section "Elsewhere in Vault"
  note "looking for the missing keys in every document under secret/ (names only)"
  walk() {
    local dir=$1 entry
    vault kv list -mount=secret -format=json "$dir" </dev/null 2>/dev/null | jq -r '.[]' | while read -r entry; do
      if [[ "$entry" == */ ]]; then walk "$dir$entry"; else printf '%s\n' "$dir$entry"; fi
    done
  }
  found=0
  while read -r path; do
    [[ "$path" == "$KV_PATH" ]] && continue
    fields=$(vault kv get -mount=secret -format=json "$path" </dev/null 2>/dev/null \
      | jq -r '.data.data // {} | to_entries[] | select(.value != "" and .value != null) | .key') || continue
    while read -r stem; do
      hits=$(grep -i -- "$stem" <<<"$fields" || true)
      [[ -n "$hits" ]] || continue
      while read -r h; do warn "secret/$path has $h (the sync reads secret/$KV_PATH)"; found=$((found + 1)); done <<<"$hits"
    done <<<"$missing"
  done < <(walk "")
  (( found > 0 )) || note "none of the missing keys is anywhere under secret/: they were never written to this Vault"
fi

printf '\n'
note "red: in Vault but not (or not the same) in the synced Secret: VSO has not refreshed it"
note "yellow: in the pod but the provider lists 0 models: the key is wrong, expired or the account needs a setting"
note "dim: no value in Vault: write it with bootstrap/secrets.sh --only litellm"

if [[ -n "$SYNC" ]]; then
  section "Catalogue run"
  job="litellm-catalog-manual-$(date +%s)"
  $KUBECTL -n "$NS" create job --from="cronjob/$CRONJOB" "$job" <"$KUBE_STDIN" >/dev/null
  ok "started job $NS/$job; waiting up to 10 minutes"
  $KUBECTL -n "$NS" wait --for=condition=complete --timeout=600s "job/$job" <"$KUBE_STDIN" >/dev/null \
    || warn "job $job did not complete in 10 minutes"
  $KUBECTL -n "$NS" logs "job/$job" <"$KUBE_STDIN" | grep -v 'tier step' || true
fi

(( problems == 0 )) || exit 1
