#!/usr/bin/env bash
#
# Removes what the estate's Vault still holds for something nothing uses any
# more: one retirement each, decided on its own issue. Each checks again,
# read-only and live, that nothing uses what it names; shows what it will
# delete; asks; deletes; and reads back that it is gone. A retirement already
# done is reported and skipped, so this is safe to re-run. What a retirement
# finds still in use, or bound to something other than its issue found, is
# refused and left alone.
#
#   bootstrap/retire.sh                 every retirement
#   bootstrap/retire.sh --list          the retirements, one line each
#   bootstrap/retire.sh downloads       one (several may be named)
#   bootstrap/retire.sh postgres rabbitmq stalwart auth-api
#                                       the old path's roles for Projects now on the estate path
#
# A one-off, not a secrets.sh section: secrets.sh puts values in a Vault and is
# re-run on every new cluster, and a fresh Vault never holds what is retired
# here. Vault is reached and signed in to the way secrets.sh does it
# (lib/estate.sh vault_connect).
#
# ESTATE_VAULT_ADDR=http://localhost:8200 runs against that Vault directly and
# skips every cluster step and live check: a dry run against `vault server -dev`.

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/wizard.sh
source "$here/lib/wizard.sh"
# shellcheck source=lib/estate.sh
source "$here/lib/estate.sh"
(( BASH_VERSINFO[0] >= 4 )) || die "bash 4 or newer is needed (macOS: brew install bash)"

# name|what it removes: the order a full run takes.
RETIREMENTS=(
  "downloads|the downloads Kubernetes auth role and policy, bound to a namespace that no longer exists (estate#227)"
  "postgres|the old path's postgres role and policy, which data's handover replaced (deploy-kit#661)"
  "rabbitmq|the old path's rabbitmq role and policy, which data's handover replaced (deploy-kit#661)"
  "stalwart|the old path's stalwart role and policy, which mail's handover replaced"
  "auth-api|the old path's auth-api role and policy, which auth's handover replaced"
)

usage() { sed -n '/^#   bootstrap/,/^#.*the old path.s roles/p' "$0" | sed 's/^# \{0,1\}//'; }

SELECTED=()
while (( $# )); do
  case "$1" in
    --list)
      for entry in "${RETIREMENTS[@]}"; do printf '  %-12s %s\n' "${entry%%|*}" "${entry#*|}"; done
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'unknown argument: %s (see --help)\n' "$1" >&2; exit 2 ;;
    *)
      known=""
      for entry in "${RETIREMENTS[@]}"; do [[ "${entry%%|*}" == "$1" ]] && known=yes; done
      [[ -n "$known" ]] || { printf 'unknown retirement: %s (see --list)\n' "$1" >&2; exit 2; }
      SELECTED+=("$1") ;;
  esac
  shift
done
if (( ! ${#SELECTED[@]} )); then
  for entry in "${RETIREMENTS[@]}"; do SELECTED+=("${entry%%|*}"); done
fi

trap estate_cleanup EXIT
trap 'exit 130' INT TERM

RESULTS=()
# section NAME: a heading that does not clear the screen, as in secrets.sh.
section() {
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ %s/%s · %s%s\n' "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}
result() { RESULTS+=("$(printf '%-12s %s' "$1" "$2")"); }
later() { warn "$1"; SKIPPED+=("$1"); }
# refuse WHAT: stop this retirement, deleting nothing, and say why.
refuse() { later "$1"; }

# vault_get PATH prints what Vault reads at PATH as JSON, or nothing when
# Vault holds nothing there. Any other failure (a denial above all) stops:
# "could not read" must never pass for "absent", which would delete a grant
# still in use. Call it only as a plain assignment (x=$(vault_get p)).
vault_get() {
  local out
  if out=$(vault read -format=json "$1" 2>&1 </dev/null); then
    printf '%s' "$out"
  elif grep -q '^No value found' <<<"$out"; then
    return 0
  else
    die "could not read $1: $(grep -m1 'Code:' <<<"$out" || head -n 1 <<<"$out")"
  fi
}

# vault_keys PATH prints the keys a LIST at PATH returns, one a line, or
# nothing for an empty list. Any other failure stops, as vault_get does.
vault_keys() {
  local out
  if out=$(vault list -format=json "$1" 2>&1 </dev/null); then
    jq -r '.[]' <<<"$out"
  elif [[ "$out" == "{}"* || "$out" == *"No value found"* ]]; then
    return 0
  else
    die "could not list $1: $(grep -m1 'Code:' <<<"$out" || head -n 1 <<<"$out")"
  fi
}

# flat_rules prints the policy on stdin with its comments dropped and its
# whitespace squeezed to one space: how it is compared and shown.
flat_rules() { sed 's/#.*//' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }

# policy_get NAME prints the policy's rules, or nothing when there is no such
# policy. Any other failure stops.
policy_get() {
  local out
  if out=$(vault policy read "$1" 2>&1 </dev/null); then
    printf '%s' "$out"
  elif grep -q '^No policy named' <<<"$out"; then
    return 0
  else
    die "could not read policy $1: $(grep -m1 'Code:' <<<"$out" || head -n 1 <<<"$out")"
  fi
}

# vault_read_many PATH... reads every path in one request stream (one process,
# however many roles and entities there are) and prints each answer as one
# JSON line, {"path": ..., "data": ...}. A path Vault holds nothing at is left
# out; any other answer, a denial above all, stops. The token travels in a
# header on stdin, never as an argument.
vault_read_many() {
  local token url out
  (( $# )) || return 0
  token=$(vault print token </dev/null) || die "no Vault token to read with"
  [[ -n "$token" ]] || die "no Vault token to read with"
  local -a urls=()
  for url in "$@"; do urls+=("$VAULT_ADDR/v1/$url"); done
  out=$(printf 'X-Vault-Token: %s\n' "$token" \
    | curl -sS --max-time 120 -H @- -w '\n{"_code":%{http_code},"_url":"%{url_effective}"}\n' "${urls[@]}") \
    || die "Vault did not answer a read of $# paths"
  unset token
  # Each answer is followed by its status line: pair them up.
  jq -nc --arg base "$VAULT_ADDR/v1/" '
    [inputs] as $all
    | range(0; $all | length; 2) as $i
    | {path: ($all[$i + 1]._url | ltrimstr($base)), code: $all[$i + 1]._code, body: $all[$i]}' <<<"$out" \
    | while IFS= read -r line; do
        case "$(jq -r .code <<<"$line")" in
          200) jq -c '{path, data: .body.data}' <<<"$line" ;;
          404) ;;
          *) die "could not read $(jq -r .path <<<"$line"): $(jq -r '.code|tostring' <<<"$line") $(jq -r '[.body.errors[]?] | join("; ")' <<<"$line")" ;;
        esac
      done
}

# Both run in a command substitution, where `set -e` does not reach: every
# step that can fail ends the subshell itself, and the caller's plain
# assignment then stops the script.
#
# policy_holders POLICY [SKIP] prints, one a line, everything in Vault that
# hands out POLICY: a role on any auth mount that has roles, a userpass user,
# a token role, an identity group or entity. SKIP is the path of the role
# being retired with it.
policy_holders() {
  local policy="$1" skip="${2:-}" mounts mount type list names name answers
  local -a paths=()
  mounts=$(vault auth list -format=json </dev/null) || die "could not list Vault's auth methods"
  while IFS=$'\t' read -r mount type; do
    case "$type" in
      kubernetes|jwt|oidc|approle) list=role ;;
      userpass) list=users ;;
      token) list=roles ;;
      *) note "auth/$mount is a $type method: it has no roles to hand out $policy" >&2; continue ;;
    esac
    names=$(vault_keys "auth/$mount$list") || exit 1
    while IFS= read -r name; do
      [[ -n "$name" && "auth/$mount$list/$name" != "$skip" ]] && paths+=("auth/$mount$list/$name")
    done <<<"$names"
  done <<<"$(jq -r 'to_entries[] | [.key, .value.type] | @tsv' <<<"$mounts")"
  for list in group entity; do
    names=$(vault_keys "identity/$list/id") || exit 1
    while IFS= read -r name; do
      [[ -n "$name" ]] && paths+=("identity/$list/id/$name")
    done <<<"$names"
  done
  note "reading ${#paths[@]} roles, users, groups and entities" >&2
  answers=$(vault_read_many "${paths[@]}") || exit 1
  [[ -z "$answers" ]] || jq -r --arg p "$policy" '
    select([.data.token_policies[]?, .data.policies[]?, .data.allowed_policies[]?] | index($p) != null)
    | if (.path | startswith("identity/")) then "\(.path | split("/")[1]) \(.data.name)" else .path end' <<<"$answers"
}

# ── downloads ─────────────────────────────────────────────────────────────
# estate#227, and its comment of 2026-10-29: the role binds ServiceAccount
# downloads in media-system, a namespace that no longer exists, to the
# downloads policy, a read on secret/data/platform/media. fleet-infra#510
# removed the writes of both as dead grants, and nothing else carries the
# policy. The issue also named knowledge-platform keys in
# secret/platform/postgres: Vault no longer holds them (fleet-infra#510
# removed their only reader), so they are only reported here.
DL_ROLE=auth/kubernetes/role/downloads
DL_POLICY=downloads
DL_NS=media-system
DL_SA=downloads
# The policy as the issue found it; compared with every space dropped.
DL_RULES='path "secret/data/platform/media" { capabilities = ["read"] }'
# What the issue left for another decision, and this never touches.
DL_OUT_OF_SCOPE_POLICIES=(basic-memory knowledge-api knowledge-curator knowledge-ingest-worker lightrag)
DL_OUT_OF_SCOPE_KEYS=(kb hindsight assistant)

# downloads_live_check prints, one a line, anything in the cluster that would
# still log in as the role. Read-only.
downloads_live_check() {
  local out
  out=$($KUBECTL get namespace "$DL_NS" -o name --ignore-not-found) || die "could not read namespace $DL_NS"
  [[ -z "$out" ]] || printf 'namespace %s exists\n' "$DL_NS"
  out=$($KUBECTL get serviceaccount -A --field-selector "metadata.name=$DL_SA" -o name) \
    || die "could not list ServiceAccounts named $DL_SA"
  [[ -z "$out" ]] || printf 'ServiceAccount %s exists: %s\n' "$DL_SA" "$(tr '\n' ' ' <<<"$out")"
  # The Vault agent injector's annotation, on a workload or the template it stamps out.
  $KUBECTL get pods,deployments,statefulsets,daemonsets,jobs,cronjobs -A -o json \
    | jq -r --arg r "$DL_SA" '.items[]
        | select([.metadata, .spec.template.metadata?, .spec.jobTemplate.spec.template.metadata?]
                 | any(.annotations?["vault.hashicorp.com/role"]? == $r))
        | "\(.kind) \(.metadata.namespace)/\(.metadata.name) asks the injector for role \($r)"' \
    || die "could not read the cluster's workloads"
  $KUBECTL get vaultauths.secrets.hashicorp.com -A -o json \
    | jq -r --arg r "$DL_SA" '.items[] | select(.spec.kubernetes.role? == $r)
        | "VaultAuth \(.metadata.namespace)/\(.metadata.name) logs in as role \($r)"' \
    || die "could not read the cluster's VaultAuths"
}

retire_downloads() {
  downloads_delete
  downloads_report
}

# downloads_delete removes the role and the policy, when what is there is what
# estate#227 found and nothing uses it.
downloads_delete() {
  local role rules bound holders live p
  role=$(vault_get "$DL_ROLE")
  rules=$(policy_get "$DL_POLICY")
  if [[ -z "$role" && -z "$rules" ]]; then
    ok "role $DL_ROLE and policy $DL_POLICY are already gone"
    result downloads "already gone"
  else
    # What is there must be what the issue found, or it is not this retirement.
    if [[ -n "$role" ]]; then
      bound=$(jq -c '.data | [.bound_service_account_names, .bound_service_account_namespaces, ((.token_policies // []) + (.policies // []) | unique)]' <<<"$role")
      if [[ "$bound" != "[[\"$DL_SA\"],[\"$DL_NS\"],[\"$DL_POLICY\"]]" ]]; then
        say "$DL_ROLE binds [names, namespaces, policies] $bound,"
        say "not ServiceAccount $DL_SA in $DL_NS to policy $DL_POLICY alone, as estate#227 found it."
        refuse "$DL_ROLE is not the role estate#227 found: nothing deleted"
        result downloads refused
        return 0
      fi
      ok "$DL_ROLE binds ServiceAccount $DL_SA in $DL_NS to policy $DL_POLICY, as estate#227 found"
    else
      ok "$DL_ROLE is already gone"
    fi
    if [[ -n "$rules" ]]; then
      if [[ "$(flat_rules <<<"$rules" | tr -d ' ')" != "${DL_RULES// /}" ]]; then
        say "policy $DL_POLICY is no longer the read on secret/data/platform/media estate#227 found:"
        while IFS= read -r p; do note "    $p"; done <<<"$rules"
        refuse "policy $DL_POLICY grants something else now: nothing deleted"
        result downloads refused
        return 0
      fi
      ok "policy $DL_POLICY is the read on secret/data/platform/media estate#227 found"
    else
      ok "policy $DL_POLICY is already gone"
    fi

    if [[ -n "$LOCAL_VAULT" ]]; then
      note "ESTATE_VAULT_ADDR: the cluster is not checked for $DL_NS, $DL_SA or a workload using the role"
    else
      say "Checking the cluster, read-only, for anything that still logs in as ${DL_SA}…"
      live=$(downloads_live_check)
      if [[ -n "$live" ]]; then
        while IFS= read -r p; do say "$p"; done <<<"$live"
        refuse "something in the cluster could still use $DL_ROLE: nothing deleted"
        result downloads refused
        return 0
      fi
      ok "no namespace $DL_NS, no ServiceAccount $DL_SA, and no workload or VaultAuth uses role $DL_SA"
    fi

    if [[ -n "$rules" ]]; then
      say "Checking every auth role, token role, identity group and entity for policy ${DL_POLICY}…"
      holders=$(policy_holders "$DL_POLICY" "$DL_ROLE")
      if [[ -n "$holders" ]]; then
        while IFS= read -r p; do say "$p hands out policy $DL_POLICY"; done <<<"$holders"
        refuse "policy $DL_POLICY is still handed out: nothing deleted"
        result downloads refused
        return 0
      fi
      ok "nothing but $DL_ROLE hands out policy $DL_POLICY"
    fi

    say "This deletes, in this order:"
    [[ -z "$role" ]] || step "role $DL_ROLE (ServiceAccount $DL_SA in $DL_NS, policy $DL_POLICY, ttl $(jq -r '.data.token_ttl' <<<"$role")s)"
    [[ -z "$rules" ]] || step "policy $DL_POLICY: $(flat_rules <<<"$rules")"
    note "No Secret, pod or VSO object reads either, so nothing restarts."
    if ! confirm "Delete them?"; then
      later "role and policy $DL_POLICY are not deleted: re-run bootstrap/retire.sh downloads"
      result downloads "not deleted"
      return 0
    fi
    if [[ -n "$role" ]]; then
      vault delete "$DL_ROLE" </dev/null >/dev/null || die "deleting $DL_ROLE failed"
    fi
    if [[ -n "$rules" ]]; then
      vault policy delete "$DL_POLICY" </dev/null >/dev/null || die "deleting policy $DL_POLICY failed"
    fi
    # Plain assignments, so a read that fails stops rather than passing for "gone".
    role=$(vault_get "$DL_ROLE")
    rules=$(policy_get "$DL_POLICY")
    [[ -z "$role" ]] || die "$DL_ROLE still reads back after the delete"
    [[ -z "$rules" ]] || die "policy $DL_POLICY still reads back after the delete"
    ok "role $DL_ROLE and policy $DL_POLICY read back as gone"
    result downloads deleted
  fi
}

# downloads_report is the issue's other half, and what it leaves alone: read,
# reported, never touched.
downloads_report() {
  local doc keys key policies p
  doc=$(kv_load platform/postgres)
  if [[ "$doc" == "{}" ]]; then
    note "secret/platform/postgres does not exist here, so it holds no knowledge-platform.* key"
  else
    keys=$(jq -r '[keys[] | select(startswith("knowledge-platform."))] | join(", ")' <<<"$doc")
    if [[ -z "$keys" ]]; then
      ok "secret/platform/postgres holds no knowledge-platform.* key: nothing to delete there"
    else
      later "secret/platform/postgres still holds $keys: not touched here, as deleting a key restarts auth-api-primary; decide it on estate#227"
    fi
  fi
  say "Out of scope, left as they are (estate#227 leaves them for a separate decision):"
  for key in "${DL_OUT_OF_SCOPE_KEYS[@]}"; do
    if [[ "$doc" != "{}" ]] && jq -e --arg k "$key." 'any(keys[]; startswith($k))' >/dev/null <<<"$doc"; then
      note "  $key.* in secret/platform/postgres: present"
    else
      note "  $key.* in secret/platform/postgres: not there"
    fi
  done
  policies=" $(vault policy list </dev/null | tr '\n' ' ') "
  for p in "${DL_OUT_OF_SCOPE_POLICIES[@]}"; do
    if [[ "$policies" == *" $p "* ]]; then note "  policy $p: present"; else note "  policy $p: not there"; fi
  done
}

# ── the old path's roles ─────────────────────────────────────────────────
# fleet-infra's vault-bootstrap-auth Job wrote one Kubernetes auth role and one
# policy per old-path workload, each reading that workload's platform document.
# A Project on the estate path logs in with roles its own vault-policy Job
# writes (<namespace>-<process>), so the old pair serves nothing once its
# Project has handed over. The ServiceAccount a role binds may still exist,
# under the same name, as the estate path's own: what matters is that nothing
# logs in with the old role.
#
# name|role|policy|ServiceAccount|namespace|the one path the policy reads
OLD_ROLES=(
  "postgres|postgres|postgres|postgres|data-system|secret/data/platform/postgres"
  "rabbitmq|rabbitmq|rabbitmq|rabbitmq|data-system|secret/data/platform/rabbitmq"
  "stalwart|stalwart|stalwart|stalwart|mail-system|secret/data/platform/mail"
  "auth-api|auth-api|auth-api|auth-api|auth-system|"
)

# old_role_live_check ROLE prints, one a line, anything in the cluster that
# would log in as ROLE or write it again. Read-only.
old_role_live_check() {
  local role="$1"
  # The injector's annotation, a VaultAuth, or a script that logs in by name.
  $KUBECTL get pods,deployments,statefulsets,daemonsets,jobs,cronjobs -A -o json \
    | jq -r --arg r "$role" '.items[]
        | select(
            ([.metadata, .spec.template.metadata?, .spec.jobTemplate.spec.template.metadata?]
             | any(.annotations?["vault.hashicorp.com/role"]? == $r))
            or ([.. | strings] | any(test("(^|[^a-z-])role=\"?" + $r + "(\"|\\s|$)"))))
        | "\(.kind) \(.metadata.namespace)/\(.metadata.name) logs in as role \($r)"' \
    || die "could not read the cluster's workloads"
  $KUBECTL get vaultauths.secrets.hashicorp.com -A -o json \
    | jq -r --arg r "$role" '.items[] | select(.spec.kubernetes.role? == $r)
        | "VaultAuth \(.metadata.namespace)/\(.metadata.name) logs in as role \($r)"' \
    || die "could not read the cluster's VaultAuths"
  # The old bootstrap Job's script, while fleet-infra still applies it, writes the role
  # again on its next run.
  $KUBECTL get configmaps -A -o json \
    | jq -r --arg r "$role" '.items[] | select(.metadata.name | startswith("vault-bootstrap-auth"))
        | select([.data[]?] | any(contains("auth/kubernetes/role/" + $r + " ")))
        | "ConfigMap \(.metadata.namespace)/\(.metadata.name) writes role \($r) again"' \
    || die "could not read the cluster's ConfigMaps"
}

# retire_old_role NAME: one entry of OLD_ROLES.
retire_old_role() {
  local entry name="" role policy sa ns reads doc rules bound holders live p
  for entry in "${OLD_ROLES[@]}"; do [[ "${entry%%|*}" == "$1" ]] && IFS='|' read -r name role policy sa ns reads <<<"$entry"; done
  [[ -n "$name" ]] || die "no old role named $1"
  local path="auth/kubernetes/role/$role"
  doc=$(vault_get "$path")
  rules=$(policy_get "$policy")
  if [[ -z "$doc" && -z "$rules" ]]; then
    ok "role $path and policy $policy are already gone"
    result "$name" "already gone"
    return 0
  fi
  if [[ -n "$doc" ]]; then
    bound=$(jq -c '.data | [.bound_service_account_names, .bound_service_account_namespaces, ((.token_policies // []) + (.policies // []) | unique)]' <<<"$doc")
    if [[ "$bound" != "[[\"$sa\"],[\"$ns\"],[\"$policy\"]]" ]]; then
      say "$path binds [names, namespaces, policies] $bound,"
      say "not ServiceAccount $sa in $ns to policy $policy alone, as the old path wrote it."
      refuse "$path is not the old path's role: nothing deleted"
      result "$name" refused
      return 0
    fi
    ok "$path binds ServiceAccount $sa in $ns to policy $policy, as the old path wrote it"
  else
    ok "$path is already gone"
  fi
  if [[ -n "$rules" ]]; then
    say "policy $policy reads:"
    while IFS= read -r p; do note "    $p"; done <<<"$(flat_rules <<<"$rules" | sed 's/} /}\n/g')"
    if [[ -n "$reads" && "$(flat_rules <<<"$rules" | tr -d ' ')" != "path\"$reads\"{capabilities=[\"read\"]}" ]]; then
      refuse "policy $policy grants more than a read on $reads: nothing deleted"
      result "$name" refused
      return 0
    fi
  fi

  if [[ -n "$LOCAL_VAULT" ]]; then
    note "ESTATE_VAULT_ADDR: the cluster is not checked for a workload using role $role"
  else
    say "Checking the cluster, read-only, for anything that logs in as $role or writes it again…"
    live=$(old_role_live_check "$role")
    if [[ -n "$live" ]]; then
      while IFS= read -r p; do say "$p"; done <<<"$live"
      refuse "something in the cluster still uses or writes $path: nothing deleted"
      result "$name" refused
      return 0
    fi
    ok "no workload, VaultAuth or bootstrap script uses role $role"
  fi
  if [[ -n "$rules" ]]; then
    say "Checking every auth role, token role, identity group and entity for policy ${policy}…"
    holders=$(policy_holders "$policy" "$path")
    if [[ -n "$holders" ]]; then
      while IFS= read -r p; do say "$p hands out policy $policy"; done <<<"$holders"
      refuse "policy $policy is still handed out: nothing deleted"
      result "$name" refused
      return 0
    fi
    ok "nothing but $path hands out policy $policy"
  fi

  say "This deletes, in this order:"
  [[ -z "$doc" ]] || step "role $path (ServiceAccount $sa in $ns, policy $policy)"
  [[ -z "$rules" ]] || step "policy $policy"
  note "No pod logs in with either, so nothing restarts."
  if ! confirm "Delete them?"; then
    later "role and policy $policy are not deleted: re-run bootstrap/retire.sh $name"
    result "$name" "not deleted"
    return 0
  fi
  if [[ -n "$doc" ]]; then
    vault delete "$path" </dev/null >/dev/null || die "deleting $path failed"
  fi
  if [[ -n "$rules" ]]; then
    vault policy delete "$policy" </dev/null >/dev/null || die "deleting policy $policy failed"
  fi
  doc=$(vault_get "$path")
  rules=$(policy_get "$policy")
  [[ -z "$doc" ]] || die "$path still reads back after the delete"
  [[ -z "$rules" ]] || die "policy $policy still reads back after the delete"
  ok "role $path and policy $policy read back as gone"
  result "$name" deleted
}

# ── run ───────────────────────────────────────────────────────────────────
TOTAL_STAGES=$(( 1 + ${#SELECTED[@]} ))
banner "Estate: retire what nothing uses from Vault"
section "Vault: reach it and sign in"
require_tools jq curl
[[ -n "$LOCAL_VAULT" || -n "${_ESTATE_VAULT_INHERITED:-}" ]] || { require_tools "$KUBECTL"; require_cluster; }
vault_connect

for CURRENT in "${SELECTED[@]}"; do
  for entry in "${RETIREMENTS[@]}"; do [[ "${entry%%|*}" == "$CURRENT" ]] && section "$CURRENT: ${entry#*|}"; done
  case "$CURRENT" in
    downloads) retire_downloads ;;
    *) retire_old_role "$CURRENT" ;;
  esac
done

printf '\n%s%s  Done%s\n' "$BOLD" "$GREEN" "$RESET"
for line in "${RESULTS[@]}"; do note "  $line"; done
if (( ${#SKIPPED[@]} )); then
  printf '\n'; warn "still to do:"
  for s in "${SKIPPED[@]}"; do note "  - $s"; done
fi
printf '\n'
