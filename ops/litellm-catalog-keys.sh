#!/usr/bin/env bash
#
# The LiteLLM provider keys of the catalogue sync: report, test, add and repair them. Values are
# never shown, only a 12-character SHA-256 fingerprint.
#
#   ops/litellm-catalog-keys.sh                  report every key, and test each one that is set
#   ops/litellm-catalog-keys.sh --sync           then start a catalogue run and show its log
#   ops/litellm-catalog-keys.sh --add [ID]       walk the providers with no key (or ID): sign-up
#                                                steps, open the pages, paste the key, test, write
#   ops/litellm-catalog-keys.sh --repair [ID]    for each key whose test fails (or ID): paste a
#                                                new one, test again, remove it, or skip
#   ops/litellm-catalog-keys.sh --list           the providers, their fields and key pages (offline)
#   ops/litellm-catalog-keys.sh --steps ID       how to make ID's account and key (offline)
#   --no-test                                    report without testing the keys
#
# Per key the report shows:
#   vault     the field in secret/platform/litellm: set, empty or missing
#   synced    the field in the Kubernetes Secret VSO writes from that document
#   same      whether the synced value has the Vault value's fingerprint (a stale copy if not)
#   test      the key tried from this workstation the way the sync lists the provider:
#             ok (n models), unproven (the list needs no key), unauthorized, no-credit,
#             rate-limited, wrong-base, server-error, network, needs-extra-field
#   models    the provider's model count in the last catalogue run, and its probe statuses
# and then, for every key that fails, what to do about it.
#
# The providers, their Vault fields, sign-up and key pages, the steps and the test of each live in
# ops/litellm-providers.json (LITELLM_PROVIDERS names another). A write happens only after the
# pasted key passes its test, or you confirm it anyway; it goes to Vault on stdin, is read back and
# its fingerprint compared. Then the script can nudge VSO, wait until the synced Secret matches,
# and start a catalogue run.
#
# Vault is reached the way bootstrap/secrets.sh reaches it: a port-forward to svc/vault and OIDC
# sign-in with your estate account (lib/estate.sh vault_connect), the token revoked on exit. The
# Secret read and the port-forward need the admin context (lib/kube.sh), so the sudo password is
# asked once. ESTATE_VAULT_ADDR names a Vault directly (a dry run against `vault server -dev`):
# the cluster and the published catalogue are skipped, and the CronJob's fields come from the
# registry.
#
# Environment: KUBE_CONTEXT (personal; its -admin context is used) or ESTATE_KUBE_CONTEXT,
# ESTATE_VAULT_ADDR as in lib/estate.sh; LITELLM_NAMESPACE (litellm-system), LITELLM_CRONJOB
# (litellm-catalog), LITELLM_KV_PATH (platform/litellm), CATALOG_REPO
# (JorisJonkers-dev/litellm-model-catalog), LITELLM_PROVIDERS, LK_TIMEOUT (20 seconds a request).

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
# shellcheck source=lib/litellm-keys.sh
source "$here/lib/litellm-keys.sh"

NS=${LITELLM_NAMESPACE:-litellm-system}
CRONJOB=${LITELLM_CRONJOB:-litellm-catalog}
KV_PATH=${LITELLM_KV_PATH:-platform/litellm}
CATALOG_REPO=${CATALOG_REPO:-JorisJonkers-dev/litellm-model-catalog}

MODE=report
TARGET=""
SYNC=""
NO_TEST=""
usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }
while (( $# )); do
  case "$1" in
    --add | --repair)
      MODE=${1#--}
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then TARGET=$2; shift; fi ;;
    --steps)
      MODE=steps
      [[ -n "${2:-}" ]] || { echo "--steps needs a provider id (see --list)" >&2; exit 2; }
      TARGET=$2; shift ;;
    --list) MODE=list ;;
    --sync) SYNC=yes ;;
    --no-test) NO_TEST=yes ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

require_tools jq
lk_registry_check || exit 1
[[ -z "$TARGET" ]] || lk_provider "$TARGET" >/dev/null || die "no provider \"$TARGET\" in the registry (see --list)"

# A heading that, unlike the wizard's stage, keeps the earlier output on screen.
section() { printf '\n%s%s▸ %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"; }

if [[ "$MODE" == list ]]; then
  printf '\n  %-16s %-50s %-9s %s\n' ID FIELDS CHECKED "KEY PAGE"
  for id in $(lk_ids); do
    printf '  %-16s %-50s %-9s %s\n' "$id" "$(lk_fields "$id" | paste -sd, -)" \
      "$(lk_get "$id" '.verified | tostring')" "$(lk_get "$id" '.key_url // "-"')"
  done
  printf '\n'; note "CHECKED: true = steps read on the provider site, partial = some of it, n/a = no website"
  exit 0
fi
if [[ "$MODE" == steps ]]; then
  lk_show_steps "$TARGET"
  printf '\n'
  exit 0
fi

require_tools vault curl
[[ -n "$LOCAL_VAULT" ]] || require_tools kubectl gh
WORK=$(umask 077 && mktemp -d)
LK_WORK=$WORK
trap estate_cleanup EXIT
trap 'exit 130' INT TERM

WRITTEN=()   # Vault fields written this run
REMOVED=()   # Vault fields removed this run
declare -A RESULT_CLASS=() RESULT_DETAIL=()

# ── what the CronJob reads ────────────────────────────────────────────────
# $WORK/refs: one line per env of the CronJob that comes from a Secret: env, Secret, Vault field.
if [[ -n "$LOCAL_VAULT" ]]; then
  section "Registry"
  jq -r '.providers[].fields[] | [.env, "-", .name] | @tsv' "$LK_REGISTRY" >"$WORK/refs"
  ok "ESTATE_VAULT_ADDR: no cluster; the fields come from $(basename "$LK_REGISTRY")"
else
  section "Cluster"
  [[ -n "$KUBE_CTX" ]] || die "kubectl has no current context: set ESTATE_KUBE_CONTEXT"
  [[ -n "$_KUBECTL_CUSTOM" ]] || kube_prime "$KUBE_CTX" || exit 1
  ok "context $KUBE_CTX"
  $KUBECTL -n "$NS" get cronjob "$CRONJOB" -o json <"$KUBE_STDIN" \
    | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].env[]
             | select(.valueFrom.secretKeyRef) | [.name, .valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key] | @tsv' \
    >"$WORK/refs" || die "cannot read cronjob $NS/$CRONJOB"
  [[ -s "$WORK/refs" ]] || die "cronjob $NS/$CRONJOB reads no Secret"
  ok "cronjob $NS/$CRONJOB reads $(wc -l <"$WORK/refs" | tr -d ' ') env values from Secrets"
fi

# load_secrets decodes the synced Secrets into $WORK only.
load_secrets() {
  local secret
  [[ -z "$LOCAL_VAULT" ]] || return 0
  for secret in $(cut -f2 "$WORK/refs" | sort -u); do
    if $KUBECTL -n "$NS" get secret "$secret" -o json <"$KUBE_STDIN" 2>/dev/null \
         | jq -c '.data // {} | map_values(@base64d)' >"$WORK/secret.$secret" 2>/dev/null; then
      [[ "${1:-}" == quiet ]] || ok "Secret $NS/$secret holds $(jq 'length' "$WORK/secret.$secret") fields"
    else
      printf '{}' >"$WORK/secret.$secret"
      [[ "${1:-}" == quiet ]] || warn "Secret $NS/$secret is missing or unreadable: VSO has not written it"
    fi
  done
}
load_secrets

# ── Vault ─────────────────────────────────────────────────────────────────
section "Vault"
vault_connect
VDOC=""
# load_vault reads the document into VDOC and LK_VAL (every registry field). A plain assignment,
# so a failed read stops the script.
load_vault() {
  local f
  # Also called where errexit is off (`enter_key ... || true`), so a failed read stops explicitly.
  VDOC=$(kv_load "$KV_PATH") || die "cannot read secret/$KV_PATH"
  printf '%s' "$VDOC" >"$WORK/vault"
  LK_VAL=()
  for f in $(jq -r '.providers[].fields[].name' "$LK_REGISTRY"); do
    LK_VAL[$f]=$(kv_field "$VDOC" "$f")
  done
}
load_vault
ok "secret/$KV_PATH holds $(jq 'length' "$WORK/vault") fields"

# ── the published catalogue ───────────────────────────────────────────────
catalogue=""
load_catalogue() {
  local sha
  catalogue=""
  [[ -z "$LOCAL_VAULT" ]] || return 0
  if sha=$(gh api "repos/$CATALOG_REPO/contents/model-catalog.json" --jq .sha 2>/dev/null) \
     && gh api "repos/$CATALOG_REPO/git/blobs/$sha" --jq .content 2>/dev/null | base64 -d >"$WORK/catalog.json" 2>/dev/null; then
    catalogue="$WORK/catalog.json"
    ok "catalogue of $(jq -r .updated_at "$catalogue") read from $CATALOG_REPO"
  else
    warn "cannot read the catalogue from $CATALOG_REPO (gh auth?); the models column stays empty"
  fi
}
if [[ -z "$LOCAL_VAULT" ]]; then
  section "Catalogue"
  load_catalogue
fi

# models ENV prints "<count> <status:n,...>" for the provider whose key_env is ENV.
models() {
  [[ -n "$catalogue" ]] || { printf -- '-'; return; }
  jq -r --arg env "$1" '
    [.providers | to_entries[] | select(.value.metadata.key_env == $env) | .value.metadata][0]
    | if . == null then "-"
      else "\(.count) \(.by_status | to_entries | map("\(.key):\(.value)") | join(","))" end' "$catalogue"
}

# test_provider ID tests the provider's key in LK_VAL once per run and keeps the result.
test_provider() {
  local id=$1
  if [[ -z "${RESULT_CLASS[$id]:-}" || "${2:-}" == again ]]; then
    lk_test "$id"
    RESULT_CLASS[$id]=$LK_CLASS
    RESULT_DETAIL[$id]=$LK_DETAIL
  fi
}

# class_colour CLASS prints the colour a test result is shown in.
class_colour() {
  case "$1" in
    ok) printf '%s' "$GREEN" ;;
    unproven | rate-limited | server-error | network) printf '%s' "$YELLOW" ;;
    missing) printf '%s' "$DIM" ;;
    *) printf '%s' "$RED" ;;
  esac
}
# repairable CLASS succeeds for a result that a new key or field can change.
repairable() { [[ "$1" == unauthorized || "$1" == no-credit || "$1" == wrong-base || "$1" == needs-extra-field ]]; }

# show_result ID prints a provider's test result and what to do about it.
show_result() {
  local id=$1 class=${RESULT_CLASS[$1]}
  printf '\n  %s%s%s  %s%s%s  %s\n' "$BOLD" "$(lk_get "$id" '.name')" "$RESET" \
    "$(class_colour "$class")" "$class" "$RESET" "${RESULT_DETAIL[$id]}"
  [[ "$class" == ok ]] && return 0
  local url; url=$(lk_get "$id" '.key_url')
  [[ -z "$url" ]] || note "  key page: $url"
  lk_show_fix "$id" "$class"
}

# ── writes ────────────────────────────────────────────────────────────────
# kv_remove_fields PATH FIELD... removes fields from the document in one version, checked against
# the version read (-cas), so a write that races another is refused rather than lost. The document
# goes to vault on stdin.
kv_remove_fields() {
  local path=$1 ver doc
  shift
  ver=$(vault kv metadata get -mount=secret -format=json "$path" </dev/null | jq -r '.data.current_version') \
    || die "cannot read the metadata of secret/$path"
  doc=$(kv_load "$path") || die "cannot read secret/$path"
  jq -c --args 'reduce $ARGS.positional[] as $f (.; del(.[$f]))' "$@" <<<"$doc" \
    | vault kv put -mount=secret -cas="$ver" "$path" - >/dev/null \
    || die "removing $* from secret/$path failed (changed meanwhile?)"
}

# ask_fields ID fills NEW with the values typed for the provider's fields: a secret is read
# hidden, the rest in the open; Enter keeps the current value (or the field's default, or skips).
declare -A NEW=()
ask_fields() {
  local id=$1 f cur secret prompt def pattern prefix LK_IN
  NEW=()
  for f in $(lk_fields "$id"); do
    cur=${LK_VAL[$f]:-}
    secret=$(lk_field_attr "$id" "$f" secret)
    prompt=$(lk_field_attr "$id" "$f" prompt)
    def=$(lk_field_attr "$id" "$f" default)
    pattern=$(lk_field_attr "$id" "$f" pattern)
    LK_IN=""
    if [[ "$secret" == true ]]; then
      [[ -n "$prompt" ]] || prompt="Paste $f"
      if [[ -n "$cur" ]]; then prompt+=" (hidden; Enter keeps $(fp "$cur")):"; else prompt+=" (hidden; Enter skips):"; fi
      ask_secret LK_IN "$prompt"
      [[ -n "$LK_IN" ]] || LK_IN=$cur
      # Whitespace from a copy is never part of a key.
      LK_IN=${LK_IN//[$' \t\r\n']/}
      prefix=$(lk_get "$id" '.key_prefix')
      if [[ -n "$LK_IN" && -n "$prefix" && "$LK_IN" != "$prefix"* ]]; then
        warn "this does not start with \"$prefix\", which $(lk_get "$id" '.name') keys usually do: the wrong thing copied?"
      fi
    else
      [[ -n "$prompt" ]] || prompt=$f
      if [[ -n "$cur" ]]; then prompt+=" [Enter keeps $cur]:"
      elif [[ -n "$def" ]]; then prompt+=" [Enter takes $def]:"
      else prompt+=" [Enter skips]:"; fi
      ask LK_IN "$prompt"
      LK_IN=${LK_IN//[$' \t\r\n']/}
      [[ -n "$LK_IN" ]] || LK_IN=${cur:-$def}
      if [[ -n "$LK_IN" && -n "$pattern" ]] && ! grep -qE -- "$pattern" <<<"$LK_IN"; then
        warn "$f \"$LK_IN\" does not look like $pattern"
        confirm "Keep it anyway?" || LK_IN=$cur
      fi
    fi
    NEW[$f]=$LK_IN
  done
}

# enter_key ID shows the steps, offers the pages, asks the fields, tests them, and writes the
# fields that changed when the test passes (or on confirm). Fails when nothing was written.
enter_key() {
  local id=$1 f url keyf changed=()
  local -A old=() wrote=()
  lk_show_steps "$id"
  printf '\n'
  url=$(lk_get "$id" '.signup_url')
  if [[ -n "$url" && -z "${LK_VAL[$(lk_key_field "$id")]:-}" ]] && confirm "Open the sign-up page?"; then open_url "$url"; fi
  url=$(lk_get "$id" '.key_url')
  if [[ -n "$url" ]] && confirm "Open the key page?"; then open_url "$url"; fi
  ask_fields "$id"
  keyf=$(lk_key_field "$id")
  if [[ -z "${NEW[$keyf]:-}" ]]; then note "no key given; $id skipped"; return 1; fi
  for f in $(lk_fields "$id"); do
    old[$f]=${LK_VAL[$f]:-}
    [[ "${NEW[$f]}" == "${old[$f]}" ]] || changed+=("$f")
    LK_VAL[$f]=${NEW[$f]}
  done
  NEW=()
  if (( ${#changed[@]} == 0 )); then note "nothing changed for $id"; test_provider "$id" again; show_result "$id"; return 1; fi
  say "testing $(lk_get "$id" '.name') with key $(fp "${LK_VAL[$keyf]}") before anything is written"
  test_provider "$id" again
  show_result "$id"
  if ! lk_passes "${RESULT_CLASS[$id]}" && ! confirm "The test did not pass. Write ${changed[*]} anyway?"; then
    for f in "${!old[@]}"; do LK_VAL[$f]=${old[$f]}; done
    note "nothing written for $id"
    return 1
  fi
  for f in "${changed[@]}"; do
    if [[ -z "${LK_VAL[$f]}" ]]; then note "$f left empty"; continue; fi
    printf '%s' "${LK_VAL[$f]}" | kv_set "$KV_PATH" "$f" || die "writing $f to secret/$KV_PATH failed"
    wrote[$f]=${LK_VAL[$f]}
    WRITTEN+=("$f")
  done
  # Read the document back: what the sync will see, and LK_VAL with it.
  load_vault
  for f in "${!wrote[@]}"; do
    [[ "${LK_VAL[$f]}" == "${wrote[$f]}" ]] || die "secret/$KV_PATH → $f does not read back as written"
    ok "secret/$KV_PATH → $f = $(fp "${wrote[$f]}") (read back)"
  done
  return 0
}

# remove_provider ID removes the provider's fields from Vault after a confirm.
remove_provider() {
  local id=$1 f present=()
  for f in $(lk_fields "$id"); do [[ -z "${LK_VAL[$f]:-}" ]] || present+=("$f"); done
  (( ${#present[@]} )) || { note "$id has no field in Vault"; return 1; }
  confirm "Remove ${present[*]} from secret/$KV_PATH? The sync then skips $id." || return 1
  kv_remove_fields "$KV_PATH" "${present[@]}"
  load_vault
  for f in "${present[@]}"; do
    jq -e --arg f "$f" 'has($f) | not' "$WORK/vault" >/dev/null || die "secret/$KV_PATH still holds $f"
    ok "removed secret/$KV_PATH → $f"
    REMOVED+=("$f")
  done
  RESULT_CLASS[$id]=missing; RESULT_DETAIL[$id]="removed"
}

# ── after a write ─────────────────────────────────────────────────────────
# run_catalogue starts one catalogue run from the CronJob and prints its log.
run_catalogue() {
  local job
  section "Catalogue run"
  job="litellm-catalog-manual-$(date +%s)"
  $KUBECTL -n "$NS" create job --from="cronjob/$CRONJOB" "$job" <"$KUBE_STDIN" >/dev/null
  ok "started job $NS/$job; waiting up to 10 minutes"
  $KUBECTL -n "$NS" wait --for=condition=complete --timeout=600s "job/$job" <"$KUBE_STDIN" >/dev/null \
    || warn "job $job did not complete in 10 minutes"
  $KUBECTL -n "$NS" logs "job/$job" <"$KUBE_STDIN" | grep -v 'tier step' || true
}

# synced_matches succeeds when every written field holds Vault's value in the synced Secret, and
# every removed field is gone from it.
synced_matches() {
  local f secret
  load_secrets quiet
  for f in "${WRITTEN[@]}"; do
    secret=$(awk -F'\t' -v f="$f" '$3 == f { print $2; exit }' "$WORK/refs")
    [[ -n "$secret" ]] || continue
    [[ "$(jq -r --arg k "$f" '.[$k] // empty' "$WORK/secret.$secret")" == "$(kv_field "$VDOC" "$f")" ]] || return 1
  done
  for f in "${REMOVED[@]}"; do
    secret=$(awk -F'\t' -v f="$f" '$3 == f { print $2; exit }' "$WORK/refs")
    [[ -n "$secret" ]] || continue
    jq -e --arg k "$f" 'has($k) | not' "$WORK/secret.$secret" >/dev/null || return 1
  done
}

after_write() {
  local secret vss refresh i f id
  (( ${#WRITTEN[@]} + ${#REMOVED[@]} )) || return 0
  section "After the write"
  (( ${#WRITTEN[@]} == 0 )) || ok "written: ${WRITTEN[*]}"
  (( ${#REMOVED[@]} == 0 )) || ok "removed: ${REMOVED[*]}"
  if [[ -n "$LOCAL_VAULT" ]]; then note "ESTATE_VAULT_ADDR: no cluster, so no VSO sync and no catalogue run"; return 0; fi
  secret=$(cut -f2 "$WORK/refs" | sort -u | head -n 1)
  vss=$($KUBECTL -n "$NS" get vaultstaticsecrets -o json <"$KUBE_STDIN" 2>/dev/null \
    | jq -r --arg s "$secret" '[.items[] | select(.spec.destination.name == $s)][0] | "\(.metadata.name) \(.spec.refreshAfter // "?")"' || true)
  refresh=${vss#* }; vss=${vss%% *}
  say "VSO copies secret/$KV_PATH into Secret $NS/$secret every ${refresh:-?} (VaultStaticSecret ${vss:-not found}); the LiteLLM proxy's copy follows the same way."
  if [[ -n "$vss" && "$vss" != null ]] && confirm "Nudge VSO now (annotate VaultStaticSecret $vss, as bootstrap/secrets.sh documents)?"; then
    if $KUBECTL -n "$NS" annotate vaultstaticsecret "$vss" "force-sync=$(date +%s)" --overwrite <"$KUBE_STDIN" >/dev/null; then
      ok "annotated $NS/$vss"
    else
      warn "could not annotate $NS/$vss"
    fi
  fi
  if confirm "Wait until Secret $NS/$secret matches Vault (up to 10 minutes)?"; then
    for i in $(seq 1 60); do
      if synced_matches; then ok "Secret $NS/$secret matches Vault for every field changed"; break; fi
      (( i < 60 )) || { warn "Secret $NS/$secret still differs after 10 minutes; check the VaultStaticSecret's events"; break; }
      printf '.'; sleep 10
    done
    printf '\n'
  fi
  if confirm "Start a catalogue run now and show the new model counts?"; then
    run_catalogue
    SYNC=""
    load_catalogue
    for f in "${WRITTEN[@]}"; do
      id=$(lk_field_owner "$f")
      [[ -n "$id" && "$(lk_key_field "$id")" == "$f" ]] || continue
      ok "$id: models $(models "$(lk_get "$id" '.fields[0].env')")"
    done
  fi
}

# ── modes ─────────────────────────────────────────────────────────────────
report() {
  local env secret key v s vstate sstate same m colour owner test_col id problems=0 failing=() missing_ids=()
  section "Keys"
  [[ -z "$NO_TEST" ]] || note "--no-test: keys are not tried"
  printf '\n  %-28s %-26s %-7s %-5s %-19s %s\n' ENV "VAULT FIELD" SYNCED SAME TEST MODELS
  while IFS=$'\t' read -r env secret key; do
    v=${LK_VAL[$key]:-$(kv_field "$VDOC" "$key")}
    if [[ "$secret" == - ]]; then s=""; else s=$(jq -r --arg k "$key" '.[$k] // empty' "$WORK/secret.$secret"); fi
    if jq -e --arg k "$key" 'has($k)' "$WORK/vault" >/dev/null; then
      if [[ -n "$v" ]]; then vstate="set"; else vstate="empty"; fi
    else
      vstate="missing"
    fi
    if [[ "$secret" == - ]]; then sstate="-"; elif [[ -n "$s" ]]; then sstate="yes"; else sstate="no"; fi
    same="-"
    if [[ -n "$v" && -n "$s" ]]; then
      if [[ "$v" == "$s" ]]; then same="yes"; else same="NO"; fi
    fi
    owner=$(lk_field_owner "$key")
    test_col="-"
    if [[ -z "$owner" ]]; then
      test_col="not in registry"
    elif [[ -n "$v" && "$(lk_key_field "$owner")" == "$key" && -z "$NO_TEST" ]]; then
      test_provider "$owner"
      test_col=${RESULT_CLASS[$owner]}
      [[ "$test_col" != ok ]] || test_col="ok ${RESULT_DETAIL[$owner]%% *}"
    fi
    m=$(models "$env")
    colour=""
    if [[ -n "$v" && ( "$sstate" == no || "$same" == NO ) ]]; then
      colour=$RED; problems=$((problems + 1))
    elif [[ -n "$owner" && -n "${RESULT_CLASS[$owner]:-}" && "$(lk_key_field "$owner")" == "$key" ]] && repairable "${RESULT_CLASS[$owner]}"; then
      colour=$RED; problems=$((problems + 1))
    elif [[ -n "$v" && "${m%% *}" == 0 ]]; then
      colour=$YELLOW; problems=$((problems + 1))
    elif [[ -z "$v" ]]; then
      colour=$DIM
    fi
    printf '  %s%-28s %-26s %-7s %-5s %-19s %s%s\n' "$colour" "$env" "$key: $vstate" "$sstate" "$same" "$test_col" "$m" "$RESET"
  done < <(sort -t$'\t' -k3 "$WORK/refs")

  # Registry and CronJob drift: a field one names and the other does not.
  if [[ -z "$LOCAL_VAULT" ]]; then
    local unread
    unread=$(jq -r '.providers[].fields[].name' "$LK_REGISTRY" | grep -vxF -f <(cut -f3 "$WORK/refs") || true)
    [[ -z "$unread" ]] || warn "registry fields the CronJob does not read (registry out of date?): $(paste -sd' ' - <<<"$unread")"
  fi

  for id in $(lk_ids); do
    [[ -n "${RESULT_CLASS[$id]:-}" && "${RESULT_CLASS[$id]}" != ok ]] && failing+=("$id")
    [[ -z "${LK_VAL[$(lk_key_field "$id")]:-}" ]] && missing_ids+=("$id")
  done
  if (( ${#failing[@]} )); then
    section "Keys that do not pass their test"
    for id in "${failing[@]}"; do show_result "$id"; done
    printf '\n'; note "repair them with: ops/litellm-catalog-keys.sh --repair [ID]"
  fi
  if (( ${#missing_ids[@]} )); then
    section "Providers with no key"
    note "  ${missing_ids[*]}"
    note "  add them, with the sign-up steps, with: ops/litellm-catalog-keys.sh --add [ID]"
  fi

  # Vault fields with a value that no catalogue env reads: a key under a wrong name lands here.
  local stray
  stray=$(jq -r 'to_entries[] | select(.value != "") | .key' "$WORK/vault" \
    | grep -vxF -f <(cut -f3 "$WORK/refs") \
    | grep -vx -e master_key -e salt_key -e oidc_client_secret -e catalog_pr_token || true)
  if [[ -n "$stray" ]]; then
    printf '\n'
    warn "Vault fields with a value that the catalogue sync never reads (a wrong name?):"
    while read -r f; do note "    $f"; done <<<"$stray"
    note "  The names it reads are the VAULT FIELD column above."
  fi
  elsewhere

  printf '\n'
  note "red: not synced, or the key fails its test in a way a new key or field can fix"
  note "yellow: in the pod but the provider lists 0 models: run the test's advice above, or --sync"
  note "dim: no value in Vault: --add"
  PROBLEMS=$problems
}

# elsewhere walks the whole `secret` mount (names only, values never leave Vault's answer) and
# reports each field whose name holds a missing provider's stem, e.g. "axforge" for axforge_api_key.
elsewhere() {
  local missing found=0 path fields stem hits h
  missing=$(while IFS=$'\t' read -r _ _ key; do
    [[ -n "$(kv_field "$VDOC" "$key")" ]] || printf '%s\n' "${key%%_*}"
  done <"$WORK/refs" | sort -u)
  [[ -n "$missing" ]] || return 0
  section "Elsewhere in Vault"
  note "looking for the missing keys in every document under secret/ (names only)"
  walk() {
    local dir=$1 entry
    vault kv list -mount=secret -format=json "$dir" </dev/null 2>/dev/null | jq -r '.[]' | while read -r entry; do
      if [[ "$entry" == */ ]]; then walk "$dir$entry"; else printf '%s\n' "$dir$entry"; fi
    done
  }
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
}

add() {
  local ids=() id
  section "Add keys"
  if [[ -n "$TARGET" ]]; then
    ids=("$TARGET")
  else
    for id in $(lk_ids); do [[ -n "${LK_VAL[$(lk_key_field "$id")]:-}" ]] || ids+=("$id"); done
  fi
  (( ${#ids[@]} )) || { ok "every provider in the registry has a key; --repair tests and replaces them"; return 0; }
  note "${#ids[@]} provider(s): ${ids[*]}"
  for id in "${ids[@]}"; do
    printf '\n'
    if [[ -z "$TARGET" ]] && ! confirm "Set up $(lk_get "$id" '.name') ($id) now?"; then continue; fi
    enter_key "$id" || true
  done
  after_write
}

repair() {
  local ids=() failing=() id choice
  section "Repair keys"
  if [[ -n "$TARGET" ]]; then
    ids=("$TARGET")
  else
    for id in $(lk_ids); do [[ -z "${LK_VAL[$(lk_key_field "$id")]:-}" ]] || ids+=("$id"); done
  fi
  for id in "${ids[@]}"; do
    test_provider "$id"
    printf '  %-16s %s%s%s %s\n' "$id" "$(class_colour "${RESULT_CLASS[$id]}")" "${RESULT_CLASS[$id]}" "$RESET" "${RESULT_DETAIL[$id]}"
    if [[ -n "$TARGET" ]] || ! lk_passes "${RESULT_CLASS[$id]}"; then failing+=("$id"); fi
  done
  (( ${#failing[@]} )) || { ok "every key that is set passes its test"; return 0; }
  for id in "${failing[@]}"; do
    while :; do
      show_result "$id"
      printf '\n  %s? %s: [p]aste a new key, [t]est again, [r]emove from Vault, [s]kip %s' "$YELLOW" "$id" "$RESET"
      read -r choice || choice=s
      case "$choice" in
        p | P) enter_key "$id" || true; lk_passes "${RESULT_CLASS[$id]}" && break ;;
        t | T) test_provider "$id" again; lk_passes "${RESULT_CLASS[$id]}" && { show_result "$id"; break; } ;;
        r | R) remove_provider "$id" && break ;;
        *) break ;;
      esac
    done
  done
  after_write
}

PROBLEMS=0
case "$MODE" in
  report) report ;;
  add) add ;;
  repair) repair ;;
esac
[[ -z "$SYNC" || -n "$LOCAL_VAULT" ]] || run_catalogue
(( PROBLEMS == 0 )) || exit 1
