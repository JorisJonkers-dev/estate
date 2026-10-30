#!/usr/bin/env bash
#
# Every secret a person puts in the estate's Vault, in one place: run it on a
# new cluster after Vault is unsealed, after a restore, and whenever a value
# needs adding or replacing. With no flags it checks every section, skips each
# value that is already right, and stops only where one is missing or wrong:
# there it says what it will write, asks, writes, and reads it back. Safe to
# re-run at any time.
#
#   bootstrap/secrets.sh                        check everything, fix what is missing
#   bootstrap/secrets.sh --list                 the sections, one line each
#   bootstrap/secrets.sh --only tribelt,grimoire
#   bootstrap/secrets.sh --only tribelt --rotate          a new OIDC client secret
#   bootstrap/secrets.sh --only hermes --replace          rewrite secret/agents/hermes whole
#   bootstrap/secrets.sh --only overleaf --rollback       restore an earlier version
#
# Flags:
#   --only S[,S]           run these sections (and the auth-api stage, when one is a client)
#   --rotate               with --only: replace values that are present instead of skipping
#                          them: an OIDC client secret, an API key, the Discord webhook, the
#                          metrics token, the Cloudflare DNS token, the off-cluster backup
#                          credential. Never a key whose rotation breaks stored state (a session
#                          key, a VAPID or grimoire's S3 pair): those are only ever minted where
#                          missing. --rotate-client-secret is the same flag.
#   --replace              with --only hermes|overleaf: write a new version holding only the
#                          fields offered; names every field it drops and waits for "yes"
#   --rollback             with --only hermes|overleaf: roll the document back to a version
#   --restart-auth-api     restart auth-api even when no client secret changed
#   --rerun-garage-bootstrap  with grimoire: re-run the garage-bootstrap Job and prove the grant
#   --test-alert           with discord-webhook: fire a test alert after a rotation
#
# Vault is reached with the local vault CLI: a port-forward to svc/vault, then
# OIDC sign-in with your estate account (lib/estate.sh vault_connect). Every
# secret travels to vault on stdin, never as an argument, and is shown only as
# a 12-character SHA-256 fingerprint. secret/auth-api is only ever patched, and
# never created: it holds every client's secret, and a Vault without it wants a
# restore, not a fresh document.
#
# ESTATE_VAULT_ADDR=http://localhost:8200 runs against that Vault directly and
# skips every cluster step and live check: a dry run against `vault server -dev`.
#
# Not written here, because deploy-kit's Vault policy job generates them once
# and never changes them (deploy-kit spec/v1/10-project-intent.md#generated-keys);
# the script only reports whether they exist yet:
#   secret/tribelt-system/keys               session_key, visitor_hmac_key (adopted from
#                                            secret/platform/tribelt, where this script's
#                                            predecessor minted them)
#   secret/findability-explorer-system/session  key (the app's SESSION_KEY)

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/wizard.sh
source "$here/lib/wizard.sh"
# shellcheck source=lib/estate.sh
source "$here/lib/estate.sh"
(( BASH_VERSINFO[0] >= 4 )) || die "bash 4 or newer is needed (macOS: brew install bash)"

AUTH_HOST=${AUTH_HOST:-https://auth.jorisjonkers.dev}

# name|what it does: the order a full run takes.
SECTIONS=(
  "vault-bootstrap|the policy and Kubernetes auth role fleet-infra's vault-bootstrap-auth Job logs in as"
  "policy-admin|the role deploy-kit's Vault policy job logs in as, confined to its namespace's names"
  "metrics-token|the token Prometheus scrapes Vault's metrics with; re-minted only when invalid"
  "discord-webhook|the Discord webhook Alertmanager posts alerts to"
  "cloudflare|the Cloudflare DNS token the public tier's Traefik issues certificates with"
  "collector-key|the delivery Collector GitHub App's id, installation id and key"
  "reporter-key|the delivery Reporter GitHub App's id, installation id and key"
  "estate-dashboard|the dashboard's OIDC client secret, session key and GitHub token"
  "tribelt|tribelt's OIDC client secret"
  "grimoire|grimoire's S3 and VAPID key pairs and OIDC client secret"
  "findability-explorer|the Findability Explorer's OIDC client secret and Anthropic API key"
  "overleaf|Overleaf's session and invite secrets and the latex@ mail password"
  "mail|Stalwart's recovery admin, the user:password pair its server reads, from its admin login"
  "hermes|the Hermes Agent's provider keys and its Hindsight token"
  "mistral|the Mistral API keys Hindsight and Karakeep read"
  "backup-off-cluster|the S3 credential irreplaceable volumes' backups copy off-cluster with"
  "garage-keys|optional: the Garage web and archive keys, pre-generated so a rebuild reproduces them"
  "agents-github-app|optional: the agents GitHub App's id, key and runner bearer"
  "agents-deploy-key|optional: the shared read-only deploy key agent workspaces fall back to"
)
# The three optional sections only report in a full run, and act when --only names them.

usage() { sed -n '/^#   bootstrap/,/^#   --test-alert/p' "$0" | sed 's/^# \{0,1\}//'; }

ONLY=""
ROTATE=""
REPLACE=""
ROLLBACK=""
RESTART_AUTH=""
RERUN_GARAGE=""
TEST_ALERT=""
while (( $# )); do
  case "$1" in
    --only) shift; ONLY="${ONLY:+$ONLY,}${1:-}" ;;
    --only=*) ONLY="${ONLY:+$ONLY,}${1#--only=}" ;;
    --rotate|--rotate-client-secret) ROTATE=yes ;;
    --replace) REPLACE=yes ;;
    --rollback) ROLLBACK=yes ;;
    --restart-auth-api) RESTART_AUTH=yes ;;
    --rerun-garage-bootstrap) RERUN_GARAGE=yes ;;
    --test-alert) TEST_ALERT=yes ;;
    --list)
      for entry in "${SECTIONS[@]}"; do printf '  %-22s %s\n' "${entry%%|*}" "${entry#*|}"; done
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

SELECTED=()
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a wanted <<<"$ONLY"
  for name in "${wanted[@]}"; do
    known=""
    for entry in "${SECTIONS[@]}"; do [[ "${entry%%|*}" == "$name" ]] && known=yes; done
    [[ -n "$known" ]] || { printf 'unknown section: %s (see --list)\n' "$name" >&2; exit 2; }
  done
  # In the order of SECTIONS, whatever order --only named them in.
  for entry in "${SECTIONS[@]}"; do
    for name in "${wanted[@]}"; do [[ "${entry%%|*}" == "$name" ]] && SELECTED+=("$name") && break; done
  done
else
  for entry in "${SECTIONS[@]}"; do SELECTED+=("${entry%%|*}"); done
fi
selected() { [[ " ${SELECTED[*]} " == *" $1 "* ]]; }
named() { [[ ",$ONLY," == *",$1,"* ]]; }
[[ -z "$ROTATE" || -n "$ONLY" ]] || { echo "--rotate needs --only: it replaces values that are present" >&2; exit 2; }
if [[ -n "$REPLACE$ROLLBACK" ]]; then
  [[ "$ONLY" == hermes || "$ONLY" == overleaf ]] \
    || { echo "--replace and --rollback take --only hermes or --only overleaf, alone" >&2; exit 2; }
  [[ -z "$REPLACE" || -z "$ROLLBACK" ]] || { echo "--replace or --rollback, not both" >&2; exit 2; }
fi

WORK=$(umask 077 && mktemp -d)
trap estate_cleanup EXIT
trap 'exit 130' INT TERM

CLIENTS=()      # id|redirect URI|auth-api env name, of each client section that ran
AUTH_WRITTEN=() # ids whose secret/auth-api copy this run wrote
RESULTS=()      # one line per section, for the closing summary

# section NAME: a heading that does not clear the screen, so a run that finds
# everything right ends with every section's verdict still in view.
section() {
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ %s/%s · %s%s\n' "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}
result() { RESULTS+=("$(printf '%-22s %s' "$1" "$2")"); }
# later WHAT: something left for a re-run, listed again at the end.
later() { warn "$1"; SKIPPED+=("$1"); }
# fp_or VALUE prints the value's fingerprint, or "none".
fp_or() { if [[ -n "$1" ]]; then fp "$1"; else printf none; fi; }
hex32() { openssl rand -hex 32; }
# b48 is 48 characters of base64 with the punctuation dropped: the shape the
# estate-dashboard's secrets have always had.
b48() { openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-48; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# generated_check PATH KEY...: the keys deploy-kit's policy job generates. Read,
# never written: report whether they exist yet.
generated_check() {
  local path="$1" doc key
  shift
  doc=$(kv_load "$path")
  for key in "$@"; do
    if [[ -n "$(kv_field "$doc" "$key")" ]]; then
      ok "secret/$path → $key exists (deploy-kit generates it; not written here)"
    else
      note "secret/$path → $key is not there yet: deploy-kit's Vault policy job generates it within the hour"
    fi
  done
}

# resync NS SECRET KEY makes VSO rebuild a destination Secret now, rather than
# at its refreshAfter, by deleting it, and waits for KEY to come back. Sets
# RESYNCED to the value it came back with (empty if it has not yet).
RESYNCED=""
resync() {
  local ns="$1" secret="$2" key="$3" _
  RESYNCED=""
  if ! $KUBECTL -n "$ns" get vaultstaticsecret "$secret" >/dev/null 2>&1; then
    note "VaultStaticSecret $ns/$secret is not applied; VSO projects it once it is"
    return 0
  fi
  $KUBECTL -n "$ns" delete secret "$secret" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    RESYNCED=$($KUBECTL -n "$ns" get secret "$secret" -o "jsonpath={.data.${key//./\\.}}" 2>/dev/null | base64 -d 2>/dev/null || true)
    [[ -n "$RESYNCED" ]] && break
    sleep 3
  done
  if [[ -n "$RESYNCED" ]]; then
    ok "$ns/$secret re-projected ($key $(fp "$RESYNCED"))"
  else
    note "$ns/$secret not re-projected yet; VSO will at its refreshAfter"
  fi
}

# kubernetes_accessor prints the accessor of the kubernetes auth mount, or nothing.
kubernetes_accessor() {
  vault auth list -format=json </dev/null | jq -r '."kubernetes/".accessor // empty'
}

# ── vault-bootstrap ───────────────────────────────────────────────────────
# Was fleet-infra scripts/ops/fix-vault-bootstrap-auth.sh. The Job writes every
# auth role, policy and engine Vault's workloads need, so its own role is the
# one thing it cannot create. Scoped to what bootstrap-auth.sh does: enable the
# kubernetes auth method and the kvv2/database/rabbitmq engines, write the
# policies and roles it defines, manage the auth-api transit signing key, and
# read the engine admin credentials it configures those engines with.
VB_NS=data-system
VB_SA=vault-bootstrap-auth
VB_NAME=vault-bootstrap
vault_bootstrap_policy() {
  cat <<'HCL'
path "sys/auth" {
  capabilities = ["read", "list"]
}
path "sys/auth/*" {
  capabilities = ["create", "update", "read", "sudo"]
}
path "sys/mounts" {
  capabilities = ["read", "list"]
}
path "sys/mounts/*" {
  capabilities = ["create", "update", "read"]
}
path "sys/policies/acl/*" {
  capabilities = ["create", "update", "read"]
}
path "auth/kubernetes/config" {
  capabilities = ["create", "update", "read"]
}
path "auth/kubernetes/role/*" {
  capabilities = ["create", "update", "read"]
}
path "database/config/*" {
  capabilities = ["create", "update", "read"]
}
path "database/roles/*" {
  capabilities = ["create", "update", "read"]
}
path "rabbitmq/config/*" {
  capabilities = ["create", "update", "read"]
}
path "rabbitmq/roles/*" {
  capabilities = ["create", "update", "read"]
}
path "transit/keys/*" {
  capabilities = ["create", "update", "read"]
}
path "kvv2/data/*" {
  capabilities = ["create", "update", "read"]
}
path "kvv2/metadata/*" {
  capabilities = ["create", "update", "read", "list", "delete"]
}
# Engine admin credentials the bootstrap reads to configure database/ and
# rabbitmq/ above. Read-only: the bootstrap never writes these.
path "secret/data/platform/postgres" {
  capabilities = ["read"]
}
path "secret/data/platform/rabbitmq" {
  capabilities = ["read"]
}
# immich's own Postgres: the bootstrap mints its superuser password once,
# where none exists, and keeps the catalog's and the backup's logins and the
# database connection in step with it.
path "secret/data/platform/media/immich-postgres" {
  capabilities = ["create", "update", "read"]
}
path "secret/data/immich/immich-postgres/*" {
  capabilities = ["create", "update", "read"]
}
path "sys/tools/random/*" {
  capabilities = ["update"]
}
HCL
}

section_vault_bootstrap() {
  local policy_ok="" role_ok="" ca out
  if [[ -z "$LOCAL_VAULT" ]]; then
    $KUBECTL -n "$VB_NS" get sa "$VB_SA" >/dev/null 2>&1 \
      || { later "ServiceAccount $VB_NS/$VB_SA is missing: Flux applies it with fleet-infra's apps-data; re-run then"; result vault-bootstrap "waiting for Flux"; return 0; }
    # Vault's TokenReview call needs the SA bound to system:auth-delegator; the Job manifest installs it.
    $KUBECTL get clusterrolebinding vault-bootstrap-auth-token-reviewer >/dev/null 2>&1 \
      || { later "ClusterRoleBinding vault-bootstrap-auth-token-reviewer is missing: apply fleet-infra's bootstrap-auth-job.yaml"; result vault-bootstrap "waiting for Flux"; return 0; }
  fi
  if [[ -z "$(kubernetes_accessor)" ]]; then
    # A Vault initialised minutes ago: the Job cannot log in until the method
    # exists, so enable it and point it at the API server the way the Job does.
    [[ -z "$LOCAL_VAULT" ]] || die "the local Vault has no kubernetes auth method: vault auth enable kubernetes"
    say "Vault has no kubernetes auth method yet (a fresh Vault), so the Job cannot log in."
    confirm "Enable auth/kubernetes and point it at the in-cluster API server?" \
      || { later "auth/kubernetes is not enabled; re-run secrets.sh --only vault-bootstrap"; result vault-bootstrap "not written"; return 0; }
    ca=$($KUBECTL -n "$VB_NS" get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')
    [[ "$ca" == *"BEGIN CERTIFICATE"* ]] || die "configmap $VB_NS/kube-root-ca.crt holds no CA"
    vault auth enable kubernetes </dev/null >/dev/null
    # No token_reviewer_jwt: Vault reviews with its own projected token (bootstrap-auth.sh says why).
    printf '%s' "$ca" | vault write auth/kubernetes/config \
      kubernetes_host=https://kubernetes.default.svc kubernetes_ca_cert=- >/dev/null
    ok "auth/kubernetes enabled; the Job rewrites its config on every run"
  fi
  [[ "$(vault policy read "$VB_NAME" 2>/dev/null </dev/null || true)" == "$(vault_bootstrap_policy)" ]] && policy_ok=yes
  [[ "$(vault read -format=json "auth/kubernetes/role/$VB_NAME" 2>/dev/null </dev/null \
    | jq -c '.data | [.bound_service_account_names, .bound_service_account_namespaces, .token_policies, .token_ttl, .token_max_ttl]' || true)" \
    == "[[\"$VB_SA\"],[\"$VB_NS\"],[\"$VB_NAME\"],1200,3600]" ]] && role_ok=yes
  if [[ -n "$policy_ok" && -n "$role_ok" ]]; then
    ok "policy $VB_NAME and role $VB_NAME are as the Job needs them"
    result vault-bootstrap "already right"
    return 0
  fi
  [[ -n "$policy_ok" ]] || say "policy $VB_NAME is missing or differs from the one the Job needs"
  [[ -n "$role_ok" ]] || say "role $VB_NAME is missing or binds something else"
  confirm "Write policy $VB_NAME and role $VB_NAME (bound to $VB_NS/$VB_SA, ttl 20m)?" \
    || { later "policy/role $VB_NAME not written"; result vault-bootstrap "not written"; return 0; }
  vault_bootstrap_policy | vault policy write "$VB_NAME" - >/dev/null
  # The TTL only has to outlast a single bootstrap run.
  out=$(vault write "auth/kubernetes/role/$VB_NAME" bound_service_account_names="$VB_SA" \
    bound_service_account_namespaces="$VB_NS" token_policies="$VB_NAME" ttl=20m max_ttl=1h </dev/null 2>&1) \
    || die "writing role $VB_NAME failed: $out"
  [[ "$(vault policy read "$VB_NAME" </dev/null)" == "$(vault_bootstrap_policy)" ]] || die "policy $VB_NAME does not read back"
  [[ "$(vault read -field=token_policies "auth/kubernetes/role/$VB_NAME" </dev/null)" == *"$VB_NAME"* ]] \
    || die "role $VB_NAME does not read back with its policy"
  ok "policy and role $VB_NAME written and read back"
  result vault-bootstrap "written"
  [[ -z "$LOCAL_VAULT" ]] || return 0
  vault_bootstrap_probe
}

# The only verification that counts: log in from inside the cluster as that
# ServiceAccount, the way the Job will.
vault_bootstrap_probe() {
  local phase="" _ probe=vault-bootstrap-login-probe
  $KUBECTL -n "$VB_NS" delete pod "$probe" --ignore-not-found >/dev/null 2>&1
  $KUBECTL apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $probe
  namespace: $VB_NS
spec:
  serviceAccountName: $VB_SA
  restartPolicy: Never
  nodeSelector:
    platform.jorisjonkers.dev/site: frankfurt
  containers:
    - name: probe
      image: hashicorp/vault:1.21.4
      env:
        - name: VAULT_ADDR
          value: http://vault.data-system.svc.cluster.local:8200
      command: ['/bin/sh', '-ec']
      args:
        - |
          VAULT_TOKEN="\$(vault write -field=token auth/kubernetes/login role=$VB_NAME \\
            jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)"
          export VAULT_TOKEN
          echo "login: ok"
          vault policy read vso >/dev/null && echo "policy read: ok"
EOF
  for _ in $(seq 1 40); do
    phase=$($KUBECTL -n "$VB_NS" get pod "$probe" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 3
  done
  $KUBECTL -n "$VB_NS" logs "$probe" 2>&1 | sed 's/^/    /'
  $KUBECTL -n "$VB_NS" delete pod "$probe" --ignore-not-found >/dev/null 2>&1
  [[ "$phase" == Succeeded ]] || die "$VB_NS/$VB_SA could not log in with role $VB_NAME"
  ok "$VB_NS/$VB_SA logs in with role $VB_NAME"
  say "The Job now only needs a re-run:"
  note "  kubectl -n $VB_NS delete job vault-bootstrap-auth"
  note "  flux reconcile kustomization apps-data --with-source"
}

# ── policy-admin ──────────────────────────────────────────────────────────
# Was cluster.sh's stage 8. The policy job (platform.intent.yml policyJob)
# writes every rendered policy and Kubernetes auth role, so its own role is
# the one thing it cannot create: it exists before the first render.
#
# One role serves every Project's job, so what it may write is confined by name
# to the namespace the job's ServiceAccount is in: the `<namespace>-*` policies
# and roles, and KV documents under `secret/data/<namespace>/`, the generated
# keys. Vault fills the namespace in from the login's alias, so a job in one
# namespace cannot write another's names. It cannot confine what a written
# policy grants or a written role binds, so the job is trusted as far as the
# signed render is (deploy-kit docs/adr/model/0087). It reads every KV
# document, because a generated key may adopt a value from an old location
# outside its Project, and it lists the policies and roles, which it reads
# back to report what the render no longer names. What is denied below is what
# a render never needs: changing its own policy or role, the built-in
# policies, or minting a role that hands out policy-admin or root.
POLICY_ROLE=policy-admin
# The ServiceAccount each Project's job runs as in its own namespace (deploy-kit
# 0.31.0, deploy-kit#548).
POLICY_SA=vault-policy
policy_admin_policy() {
  local ns="{{identity.entity.aliases.$1.metadata.service_account_namespace}}"
  cat <<HCL
path "sys/policies/acl" {
  capabilities = ["list"]
}
path "sys/policies/acl/$ns-*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "auth/kubernetes/role" {
  capabilities = ["list"]
}
path "auth/kubernetes/role/$ns-*" {
  capabilities = ["create", "read", "update", "delete"]
  denied_parameters = {
    "token_policies" = ["policy-admin", "root"]
    "policies"       = ["policy-admin", "root"]
  }
}
path "secret/data/$ns/*" {
  capabilities = ["create", "read", "update"]
}
path "secret/data/*" {
  capabilities = ["read"]
}
path "sys/policies/acl/policy-admin" {
  capabilities = ["deny"]
}
path "sys/policies/acl/root" {
  capabilities = ["deny"]
}
path "sys/policies/acl/default" {
  capabilities = ["deny"]
}
path "auth/kubernetes/role/policy-admin" {
  capabilities = ["deny"]
}
HCL
}

section_policy_admin() {
  local accessor policy_ok="" role_ok="" out
  accessor=$(kubernetes_accessor)
  if [[ "$accessor" != auth_kubernetes_* ]]; then
    later "Vault has no kubernetes auth method: run secrets.sh --only vault-bootstrap first"
    result policy-admin "waiting for vault-bootstrap"
    return 0
  fi
  [[ "$(vault policy read "$POLICY_ROLE" 2>/dev/null </dev/null || true)" == "$(policy_admin_policy "$accessor")" ]] && policy_ok=yes
  [[ "$(vault read -format=json "auth/kubernetes/role/$POLICY_ROLE" 2>/dev/null </dev/null \
    | jq -c '.data | [.bound_service_account_names, .bound_service_account_namespaces, .token_policies, .token_ttl]' || true)" \
    == "[[\"$POLICY_SA\"],[\"*\"],[\"$POLICY_ROLE\"],600]" ]] && role_ok=yes
  if [[ -n "$policy_ok" && -n "$role_ok" ]]; then
    ok "role $POLICY_ROLE binds every namespace's $POLICY_SA to policy $POLICY_ROLE, confined to its namespace's names"
    result policy-admin "already right"
    return 0
  fi
  [[ -n "$policy_ok" ]] || say "policy $POLICY_ROLE is missing or differs from the one the render expects"
  [[ -n "$role_ok" ]] || say "role $POLICY_ROLE is missing or binds something else"
  confirm "Write policy and role $POLICY_ROLE?" \
    || { later "policy/role $POLICY_ROLE not written"; result policy-admin "not written"; return 0; }
  policy_admin_policy "$accessor" | vault policy write "$POLICY_ROLE" - >/dev/null
  out=$(vault write "auth/kubernetes/role/$POLICY_ROLE" bound_service_account_names="$POLICY_SA" \
    bound_service_account_namespaces="*" token_policies="$POLICY_ROLE" token_ttl=10m </dev/null 2>&1) \
    || die "writing role $POLICY_ROLE failed: $out"
  [[ "$(vault read -field=token_policies "auth/kubernetes/role/$POLICY_ROLE" </dev/null)" == *"$POLICY_ROLE"* ]] \
    || die "auth/kubernetes/role/$POLICY_ROLE does not read back with its policy"
  ok "role $POLICY_ROLE binds every namespace's $POLICY_SA to policy $POLICY_ROLE, confined to its namespace's names"
  result policy-admin "written"
}

# ── metrics-token ─────────────────────────────────────────────────────────
# Was fleet-infra scripts/ops/mint-vault-metrics-token.sh, now break-glass:
# the vault-metrics-token-renewal CronJob (fleet-infra
# cluster/flux/apps/data/vault/metrics-token-renewal.yaml) renews the periodic
# token daily, and mints one when it has lapsed. This re-mints only a token
# Vault no longer accepts, or with --rotate. Removing the token is not the fix:
# vault's release.yaml keeps unauthenticated_metrics_access off on purpose.
OBS_KV_PATH=platform/observability
METRICS_KEY=vault.prometheus_token
METRICS_POLICY=prometheus-metrics
section_metrics_token() {
  local doc cur policies="" new
  doc=$(kv_load "$OBS_KV_PATH")
  cur=$(kv_field "$doc" "$METRICS_KEY")
  # The lookup's output carries the token itself, so only the policies leave jq.
  [[ -n "$cur" ]] && policies=$(VAULT_TOKEN="$cur" vault token lookup -format=json 2>/dev/null </dev/null \
    | jq -r '.data.policies | join(",")' || true)
  if [[ -z "$ROTATE" && ",$policies," == *",$METRICS_POLICY,"* ]]; then
    ok "secret/$OBS_KV_PATH → $METRICS_KEY is a live token with policy $METRICS_POLICY ($(fp "$cur"))"
    result metrics-token "already right"
    return 0
  fi
  if [[ -n "$cur" ]]; then say "Vault no longer accepts the metrics token ($(fp "$cur")), or --rotate asked for a new one."
  else say "Vault holds no metrics token: Prometheus cannot scrape Vault, and VaultSealed cannot evaluate."; fi
  confirm "Mint a periodic ${PERIOD:-720h} token with policy $METRICS_POLICY and write it to secret/$OBS_KV_PATH?" \
    || { later "the metrics token is not replaced"; result metrics-token "not written"; return 0; }
  if ! vault policy read "$METRICS_POLICY" >/dev/null 2>&1 </dev/null; then
    vault policy write "$METRICS_POLICY" - >/dev/null <<'HCL'
path "sys/metrics" {
  capabilities = ["read", "list"]
}
HCL
    ok "policy $METRICS_POLICY created, read-only on the metrics endpoint"
  fi
  new=$(vault token create -policy="$METRICS_POLICY" -period="${PERIOD:-720h}" -field=token </dev/null)
  [[ -n "$new" && "$new" != "$cur" ]] || die "token creation returned nothing new"
  printf '%s' "$new" | kv_set "$OBS_KV_PATH" "$METRICS_KEY"
  doc=$(kv_load "$OBS_KV_PATH")
  [[ "$(kv_field "$doc" "$METRICS_KEY")" == "$new" ]] || die "the metrics token does not read back"
  ok "secret/$OBS_KV_PATH → $METRICS_KEY = $(fp "$new")"
  result metrics-token "re-minted"
  [[ -z "$LOCAL_VAULT" ]] || return 0
  resync data-system vault-prometheus-token token
  [[ -z "$RESYNCED" || "$RESYNCED" == "$new" ]] || die "data-system/vault-prometheus-token came back with another token"
  metrics_scrape_check
}

# The only check that matters: the ServiceMonitor reads the Secret as a bearer
# token, so the scrape either works or the token is wrong.
metrics_scrape_check() {
  local log pid port="" up="" _
  log="$WORK/prometheus-pf.log"
  $KUBECTL -n observability port-forward svc/metrics-stack-prometheus 0:9090 </dev/null >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 20); do
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$log" | head -n 1)
    [[ -n "$port" ]] && break
    sleep 1
  done
  for _ in $(seq 1 24); do
    [[ -n "$port" ]] || break
    up=$(curl -s --get "http://localhost:$port/api/v1/query" --data-urlencode 'query=up{job="vault"}' 2>/dev/null \
      | jq -r '.data.result[0].value[1] // empty' || true)
    [[ "$up" == 1 ]] && break
    sleep 10
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [[ "$up" == 1 ]]; then
    ok 'up{job="vault"} == 1: the scrape works and VaultSealed can evaluate again'
  else
    later 'up{job="vault"} is not 1 after ~4 minutes; the token is in place, so check the ServiceMonitor and the vault target in Prometheus'
  fi
}

# ── discord-webhook ───────────────────────────────────────────────────────
# Was fleet-infra scripts/ops/rotate-discord-webhook.sh. The value flows Vault
# -> VSO -> Secret -> generated Alertmanager config, and each hop is checked by
# fingerprint. The last is what decides whether alerts go anywhere:
# prometheus-operator resolves apiURL.secretKeyRef when it renders the config.
DISCORD_KEY=discord.alert_webhook_url
section_discord_webhook() {
  local doc cur url
  doc=$(kv_load "$OBS_KV_PATH")
  cur=$(kv_field "$doc" "$DISCORD_KEY")
  if [[ -z "$ROTATE" && "$cur" == https://discord.com/api/webhooks/*/* ]]; then
    ok "secret/$OBS_KV_PATH → $DISCORD_KEY holds a Discord webhook ($(fp "$cur"))"
    result discord-webhook "already right"
    return 0
  fi
  say "Creating the webhook is Discord's side:"
  step "Discord → Server Settings → Integrations → Webhooks → New Webhook"
  step "Pick the alerts channel, Copy Webhook URL."
  ask_secret DISCORD_URL "Paste the new webhook URL (Enter skips):"
  url=$(printf '%s' "${DISCORD_URL:-}" | tr -d '[:space:]')
  unset DISCORD_URL
  if [[ -z "$url" ]]; then
    later "no Discord webhook in Vault: Alertmanager has nowhere to send alerts"
    result discord-webhook "not written"
    return 0
  fi
  [[ "$url" == https://discord.com/api/webhooks/*/* ]] \
    || die "that is not a Discord webhook URL (https://discord.com/api/webhooks/<id>/<token>)"
  [[ "$url" != "$cur" ]] || die "that is the webhook already in use: a rotation that changes nothing is worse than none"
  confirm "Write webhook $(fp "$url") to secret/$OBS_KV_PATH?" \
    || { later "the Discord webhook is not written"; result discord-webhook "not written"; return 0; }
  printf '%s' "$url" | kv_set "$OBS_KV_PATH" "$DISCORD_KEY"
  doc=$(kv_load "$OBS_KV_PATH")
  [[ "$(kv_field "$doc" "$DISCORD_KEY")" == "$url" ]] || die "the webhook does not read back"
  ok "secret/$OBS_KV_PATH → $DISCORD_KEY = $(fp "$url")"
  result discord-webhook "written"
  if [[ -z "$LOCAL_VAULT" ]]; then
    resync observability alertmanager-discord webhook-url
    [[ -z "$RESYNCED" || "$RESYNCED" == "$url" ]] || die "observability/alertmanager-discord came back with another URL"
    discord_config_check "$(fp "$url")"
    [[ -z "$TEST_ALERT" ]] || discord_test_alert
  fi
  [[ -z "$cur" ]] || later "delete the OLD webhook ($(fp "$cur")) in Discord: until then it still posts, and nothing is revoked"
}

discord_config_check() {
  local _
  require_tools python3
  for _ in $(seq 1 40); do
    if $KUBECTL -n observability get secret alertmanager-metrics-stack-alertmanager-generated -o json 2>/dev/null \
      | python3 -c '
import sys, json, base64, gzip, re, hashlib
want = sys.argv[1]
for v in (json.load(sys.stdin).get("data") or {}).values():
    raw = base64.b64decode(v)
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    m = re.search(rb"https://discord\.com/api/webhooks/[A-Za-z0-9_/\-]+", raw)
    if m and hashlib.sha256(m.group(0)).hexdigest()[:12] == want:
        sys.exit(0)
sys.exit(1)' "$1"; then
      ok "the generated Alertmanager config carries the new webhook"
      return 0
    fi
    sleep 5
  done
  die "the generated Alertmanager config still carries another webhook: alerts would go to the old one"
}

discord_test_alert() {
  local log pid port="" code _
  log="$WORK/alertmanager-pf.log"
  $KUBECTL -n observability port-forward svc/metrics-stack-alertmanager 0:9093 </dev/null >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 20); do
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$log" | head -n 1)
    [[ -n "$port" ]] && break
    sleep 1
  done
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "[{\"labels\":{\"alertname\":\"DiscordWebhookRotationTest\",\"severity\":\"warning\"},\"annotations\":{\"summary\":\"Webhook rotation test -- resolves on its own\"},\"startsAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]" \
    "http://localhost:${port:-0}/api/v2/alerts" || true)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [[ "$code" == 200 || "$code" == 202 ]]; then
    ok "test alert sent: a DiscordWebhookRotationTest notification should arrive within a minute"
  else
    later "the test alert was not accepted (HTTP $code); verify delivery another way"
  fi
}

# ── cloudflare ────────────────────────────────────────────────────────────
# On deploy-kit 1.0 the public tier's own Traefik issues its certificates: its
# ACME resolver reads CF_DNS_API_TOKEN from the document platform.intent.yml's
# acme.token names (deploy-kit src/model/tier-proxy.ts, DNS_TOKEN_KEYS). Until
# edge hands over (JorisJonkers-dev/deploy-kit#662) fleet-infra's cert-manager
# and external-dns read the same token from secret/platform/edge, so the first
# write copies it from there and both keep working.
CF_KV_PATH=platform/cloudflare
CF_KEY=CF_DNS_API_TOKEN
CF_EDGE_PATH=platform/edge
CF_EDGE_KEY=cloudflare.dns_api_token
CF_ZONE=jorisjonkers.dev
section_cloudflare() {
  local doc cur edge token from
  doc=$(kv_load "$CF_KV_PATH")
  cur=$(kv_field "$doc" "$CF_KEY")
  doc=$(kv_load "$CF_EDGE_PATH")
  edge=$(kv_field "$doc" "$CF_EDGE_KEY")
  if [[ -n "$cur" && -z "$ROTATE" ]]; then
    ok "secret/$CF_KV_PATH → $CF_KEY exists ($(fp "$cur"))"
    [[ -z "$edge" || "$edge" == "$cur" ]] \
      || note "it differs from secret/$CF_EDGE_PATH → $CF_EDGE_KEY ($(fp "$edge")), which fleet-infra still reads"
    result cloudflare "already right"
    return 0
  fi
  if [[ -n "$edge" && -z "$ROTATE" ]]; then
    token=$edge
    from="secret/$CF_EDGE_PATH → $CF_EDGE_KEY"
  else
    say "Creating the token is Cloudflare's side:"
    step "dash.cloudflare.com → My Profile → API Tokens → Create Token → Edit zone DNS"
    step "Zone Resources: Include, Specific zone, $CF_ZONE."
    CF_TOKEN=""
    ask_secret CF_TOKEN "Paste the new token (Enter skips):"
    token=$(printf '%s' "${CF_TOKEN:-}" | tr -d '[:space:]')
    unset CF_TOKEN
    from="the token pasted"
    if [[ -z "$token" ]]; then
      later "secret/$CF_KV_PATH has no $CF_KEY: the public tier cannot issue certificates once edge hands over"
      result cloudflare "not written"
      return 0
    fi
    [[ "$token" != "$cur" ]] || die "that is the token already in use: a rotation that changes nothing is worse than none"
  fi
  if [[ -z "$LOCAL_VAULT" ]]; then
    cf_token_check "$token" "$from"
  fi
  confirm "Write $from ($(fp "$token")) to secret/$CF_KV_PATH → $CF_KEY?" \
    || { later "secret/$CF_KV_PATH → $CF_KEY is not written"; result cloudflare "not written"; return 0; }
  printf '%s' "$token" | kv_set "$CF_KV_PATH" "$CF_KEY"
  doc=$(kv_load "$CF_KV_PATH")
  [[ "$(kv_field "$doc" "$CF_KEY")" == "$token" ]] || die "secret/$CF_KV_PATH does not read back"
  ok "secret/$CF_KV_PATH → $CF_KEY = $(fp "$token")"
  result cloudflare written
  [[ -z "$ROTATE" || -z "$edge" ]] \
    || later "secret/$CF_EDGE_PATH → $CF_EDGE_KEY still holds $(fp "$edge"): fleet-infra reads that one until edge hands over"
  unset token
}

# cf_token_check TOKEN FROM asks Cloudflare whether the token sees the zone. The
# live token is limited to the cluster's addresses, so from anywhere else
# Cloudflare refuses it by location (9109): that says nothing about the token,
# and is reported rather than stopped on. Any other refusal stops.
cf_token_check() {
  local reply
  reply=$(printf 'Authorization: Bearer %s\n' "$1" \
    | curl -sS --max-time 20 -H @- "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE") \
    || die "Cloudflare does not answer: $(head -n 1 <<<"$reply")"
  if jq -e --arg z "$CF_ZONE" 'any(.result[]?; .name == $z)' >/dev/null <<<"$reply"; then
    ok "Cloudflare accepts $(fp "$1") and it sees $CF_ZONE"
  elif jq -e 'any(.errors[]?; .code == 9109)' >/dev/null <<<"$reply"; then
    note "Cloudflare refuses $(fp "$1") from this machine's address: the token is limited to certain client IPs, so it is not checked here"
  else
    die "Cloudflare rejects $2 ($(fp "$1")): $(jq -r '[.errors[]?.message] | join("; ")' <<<"$reply")"
  fi
}

# ── collector-key, reporter-key ───────────────────────────────────────────
# Were cluster.sh's stages 4 and 5. github-apps.sh hands a newly created App's
# key over in ESTATE_COLLECTOR_PEM or ESTATE_REPORTER_PEM; otherwise GitHub
# shows a key only once, so a fresh Vault gets a newly generated one.
section_app_key() {
  local name="$1" prefix="$2" path="$3" label="$4" pem="${5:-}" doc id key value
  doc=$(kv_load "$path")
  # The ids are not secret and Vault is their source of truth: a new machine
  # takes them from there, and asks only when Vault has none.
  for key in APP_ID:app-id INSTALLATION_ID:installation-id; do
    if [[ -z "$(_existing "${prefix}_${key%%:*}" || true)" ]]; then
      value=$(kv_field "$doc" "${key#*:}")
      if [[ -z "$value" ]]; then
        note "$ENV_FILE has no ${prefix}_${key%%:*}. The $label App's settings page shows it."
        ask value "${prefix}_${key%%:*}:"
      fi
      [[ "$value" =~ ^[0-9]+$ ]] || die "${prefix}_${key%%:*} is a number"
      write_env "${prefix}_${key%%:*}" "$value"
    fi
  done
  id=$(_existing "${prefix}_APP_ID")
  if [[ "$(kv_field "$doc" app-id)" == "$id" \
    && "$(kv_field "$doc" installation-id)" == "$(_existing "${prefix}_INSTALLATION_ID")" \
    && "$(kv_field "$doc" private-key)" == *"PRIVATE KEY"* ]]; then
    ok "secret/$path holds the $label's id, installation id and key ($(fp "$(kv_field "$doc" private-key)"))"
    result "$name" "already right"
    return 0
  fi
  if [[ -z "$pem" || ! -s "$pem" ]]; then
    say "Vault does not hold the $label's key (a fresh Vault?). GitHub shows a key only"
    say "once, so generate a new one; the old one keeps working until deleted."
    open_url "https://github.com/organizations/$ORG/settings/apps/$(_existing "${prefix}_APP_SLUG" || echo "jorisjonkers-dev-estate-${name%-key}")"
    step "Credentials → Key pairs → Generate a private key. Your browser downloads a .pem file."
    step "Paste its full path below (/Users/…, not ~/…). Enter skips."
    pem=""
    ask pem "Path of the downloaded .pem:"
    if [[ -z "$pem" ]]; then
      later "secret/$path has no $label key: re-run secrets.sh --only $name"
      result "$name" "not written"
      return 0
    fi
    [[ -s "$pem" ]] || die "no file at $pem"
  fi
  confirm "Write the $label's id $id and key $(fp "$(cat "$pem")") to secret/$path?" \
    || { later "secret/$path not written"; result "$name" "not written"; return 0; }
  store_app_key "$prefix" "$path" "$pem"
  ok "secret/$path holds the $label's id, installation id and key"
  result "$name" "written"
  if [[ "$pem" != "$WORK"/* && "$pem" != "${ESTATE_COLLECTOR_PEM:-}" && "$pem" != "${ESTATE_REPORTER_PEM:-}" ]]; then
    if confirm "Delete $pem now that Vault holds it?"; then rm -f "$pem"; fi
    note "Delete the older key in the App's settings once the $label has run."
  fi
}

# ── OIDC clients ──────────────────────────────────────────────────────────
# oidc_client ID REDIRECT_URI APP_PATH APP_KEY MINT
#
# auth-api reads secret/auth-api → auth.clients.<ID>.secret, and the app its
# own copy at APP_PATH → APP_KEY; the two must be equal. Both present and equal
# is right, and kept. auth-api's copy present and the app's missing or
# different: the app takes auth-api's, which is what auth-api serves, so auth-api
# needs no restart. auth-api's missing, or --rotate: MINT a new one into both.
# auth-api reads its client secrets only at pod start (the Vault agent
# injector's template in fleet-infra's auth-api deployment.yaml), so a new
# auth-api copy restarts it, at the auth-api stage after every section.
oidc_client() {
  local id="$1" redirect="$2" app_path="$3" app_key="$4" mint="$5"
  local auth_key="auth.clients.$1.secret" auth app cur_auth cur_app secret rest_before wrote_auth=""
  auth=$(kv_load "$AUTH_KV_PATH")
  [[ "$auth" != "{}" ]] || die "secret/$AUTH_KV_PATH does not exist: refusing to create it. It holds every client's
    secret, so a Vault without it wants a restore from backup, not a new document."
  app=$(kv_load "$app_path")
  cur_auth=$(kv_field "$auth" "$auth_key")
  cur_app=$(kv_field "$app" "$app_key")
  CLIENTS+=("$id|$redirect|AUTH_CLIENTS_$(printf '%s' "$id" | tr 'a-z-' 'A-Z_')_SECRET")
  if [[ -z "$ROTATE" && -n "$cur_auth" && "$cur_auth" == "$cur_app" ]]; then
    ok "client secret: secret/$AUTH_KV_PATH and secret/$app_path agree ($(fp "$cur_auth"))"
    return 0
  fi
  if [[ -z "$ROTATE" && -n "$cur_auth" ]]; then
    secret=$cur_auth
    say "auth-api holds the $id client secret ($(fp "$cur_auth")); secret/$app_path → $app_key"
    say "is missing or different ($(fp_or "$cur_app")), and takes auth-api's."
  else
    secret=$($mint)
    [[ ${#secret} -ge 32 ]] || die "could not mint a client secret"
    wrote_auth=yes
    if [[ -n "$cur_auth" ]]; then say "--rotate: a new $id client secret ($(fp "$secret")) replaces $(fp "$cur_auth")."
    else say "auth-api holds no $id client secret; minted $(fp "$secret")."; fi
  fi
  if [[ -n "$wrote_auth" ]]; then
    confirm "Write it to secret/$AUTH_KV_PATH → $auth_key and secret/$app_path → $app_key?" \
      || { later "the $id client secret is not written"; return 0; }
  else
    confirm "Write it to secret/$app_path → $app_key?" || { later "the $id client secret is not written"; return 0; }
  fi
  # Everything in auth-api except this client's key, to prove the patch touched nothing else.
  rest_before=$(fp "$(jq -cS --arg k "$auth_key" 'del(.[$k])' <<<"$auth")")
  [[ -z "$wrote_auth" ]] || printf '%s' "$secret" | kv_patch "$AUTH_KV_PATH" "$auth_key"
  printf '%s' "$secret" | kv_set "$app_path" "$app_key"
  auth=$(kv_load "$AUTH_KV_PATH")
  app=$(kv_load "$app_path")
  [[ "$(kv_field "$auth" "$auth_key")" == "$secret" && "$(kv_field "$app" "$app_key")" == "$secret" ]] \
    || die "the two copies of the $id client secret do not read back equal"
  [[ "$(fp "$(jq -cS --arg k "$auth_key" 'del(.[$k])' <<<"$auth")")" == "$rest_before" ]] \
    || die "auth-api's other keys changed: inspect secret/$AUTH_KV_PATH's versions now"
  ok "both copies read back equal ($(fp "$secret")); every other auth-api key unchanged"
  [[ -z "$wrote_auth" ]] || AUTH_WRITTEN+=("$id")
}

# ── estate-dashboard ──────────────────────────────────────────────────────
# Was cluster.sh's stage 6, and before it fleet-infra
# scripts/ops/bootstrap-estate-dashboard-oidc.sh, whose secret/platform/estate-dashboard
# copy nothing reads any more. The dashboard's sign-in document, where its
# project file grants its Process a read (JorisJonkers-dev/estate-dashboard
# deploy/estate-dashboard.project.yml): one document, because its reader set
# is that one Process.
DASHBOARD_KV_PATH="estate-dashboard-system/sign-in"
section_estate_dashboard() {
  local doc session
  oidc_client estate-dashboard https://estate.jorisjonkers.dev/auth/callback \
    "$DASHBOARD_KV_PATH" oidc-client-secret b48
  # The session key seals the dashboard's cookie and the refresh tokens it
  # stores. Kept where it exists: a new one signs every admin out and makes
  # every stored token unreadable. Never rotated here.
  doc=$(kv_load "$DASHBOARD_KV_PATH")
  session=$(kv_field "$doc" session-key)
  if [[ ${#session} -ge 32 ]]; then
    ok "secret/$DASHBOARD_KV_PATH → session-key exists ($(fp "$session"))"
  else
    SESSION_KEY=$(b48)
    if confirm "secret/$DASHBOARD_KV_PATH has no session key. Write a new 48-character one ($(fp "$SESSION_KEY"))?"; then
      printf '%s' "$SESSION_KEY" | kv_set "$DASHBOARD_KV_PATH" session-key
      doc=$(kv_load "$DASHBOARD_KV_PATH")
      [[ "$(kv_field "$doc" session-key)" == "$SESSION_KEY" ]] || die "the session key does not read back"
      ok "secret/$DASHBOARD_KV_PATH → session-key = $(fp "$SESSION_KEY")"
    else
      later "the estate-dashboard has no session key"
    fi
    unset SESSION_KEY
  fi
  # The dashboard reads pins, the deploy log, open issues and composition runs
  # from the Estate repository, which is private. GitHub shows a token only
  # once, so a fresh Vault needs a new one.
  if [[ -n "$(kv_field "$doc" github-token)" && -z "$ROTATE" ]]; then
    ok "secret/$DASHBOARD_KV_PATH → github-token exists ($(fp "$(kv_field "$doc" github-token)"))"
  else
    say "The dashboard reads the Estate repository with a token that may read it and nothing else."
    open_url "https://github.com/settings/personal-access-tokens/new"
    step "Resource owner: $ORG. Repository access: Only select repositories, estate."
    step "Repository permissions: Actions, Contents, Issues and Metadata, read-only. Nothing else."
    step "Generate token, and copy it."
    ask_secret DASHBOARD_GITHUB_TOKEN "Paste the token (Enter skips; the dashboard then reads no estate):"
    if [[ -n "${DASHBOARD_GITHUB_TOKEN:-}" ]] && confirm "Write token $(fp "$DASHBOARD_GITHUB_TOKEN") to secret/$DASHBOARD_KV_PATH?"; then
      printf '%s' "$DASHBOARD_GITHUB_TOKEN" | kv_set "$DASHBOARD_KV_PATH" github-token
      doc=$(kv_load "$DASHBOARD_KV_PATH")
      [[ "$(kv_field "$doc" github-token)" == "$DASHBOARD_GITHUB_TOKEN" ]] || die "the GitHub token does not read back"
      ok "secret/$DASHBOARD_KV_PATH → github-token = $(fp "$DASHBOARD_GITHUB_TOKEN")"
    else
      later "the estate-dashboard has no GitHub token: re-run secrets.sh --only estate-dashboard"
    fi
    unset DASHBOARD_GITHUB_TOKEN
  fi
  result estate-dashboard "checked"
}

# ── tribelt ───────────────────────────────────────────────────────────────
# Was fleet-infra scripts/ops/provision-tribelt-secrets.sh. Its session_key and
# visitor_hmac_key are deploy-kit generated keys now (tribelt's project file,
# secret/tribelt-system/keys, adopting the values in secret/platform/tribelt),
# so they are not written here, and never could be rotated from here: a new
# session key signs every Stats Viewer out, a new HMAC key splits every Daily
# Visitor. Its Search Console and Bing keys live in tribelt's Postgres (tribelt
# docs/adr/0005), so --gsc-json and --bing-key are gone.
section_tribelt() {
  oidc_client tribelt https://tribelt.jorisjonkers.dev/auth/callback platform/tribelt oidc.client_secret hex32
  generated_check tribelt-system/keys session_key visitor_hmac_key
  result tribelt "checked"
}

# ── grimoire ──────────────────────────────────────────────────────────────
# Was fleet-infra scripts/ops/provision-grimoire-secrets.sh. The S3 pair and
# the VAPID pair are minted once and never rotated here: a new S3 pair needs a
# Garage re-grant, and a new VAPID pair silently invalidates every push
# subscription a player's device holds.
GRIMOIRE_KV_PATH=platform/grimoire
# Prints "<public> <private>". The public key comes from the same PEM, so the pair matches.
mint_vapid() {
  local pem pub priv
  pem=$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null)
  priv=$(printf '%s\n' "$pem" | openssl ec -outform DER 2>/dev/null | tail -c +8 | head -c 32 | b64url)
  pub=$(printf '%s\n' "$pem" | openssl ec -pubout -outform DER 2>/dev/null | tail -c 65 | b64url)
  printf '%s %s\n' "$pub" "$priv"
}

section_grimoire() {
  local doc ak sk vp vk projected
  doc=$(kv_load "$GRIMOIRE_KV_PATH")
  if [[ -n "$(kv_field "$doc" s3.access_key_id)" && -n "$(kv_field "$doc" s3.secret_access_key)" ]]; then
    ok "S3 key pair exists ($(fp "$(kv_field "$doc" s3.access_key_id)")), kept"
  elif confirm "secret/$GRIMOIRE_KV_PATH has no S3 key pair. Mint one (Garage's GK + 24 hex id, 64 hex secret)?"; then
    kv_set_pair "$GRIMOIRE_KV_PATH" s3.access_key_id "GK$(openssl rand -hex 12)" s3.secret_access_key "$(hex32)"
    ok "S3 key pair minted"
  else
    later "grimoire has no S3 key pair"
  fi
  if [[ -n "$(kv_field "$doc" vapid.public_key)" && -n "$(kv_field "$doc" vapid.private_key)" ]]; then
    ok "VAPID key pair exists ($(fp "$(kv_field "$doc" vapid.public_key)")), kept"
  elif confirm "secret/$GRIMOIRE_KV_PATH has no VAPID key pair. Mint one (P-256)?"; then
    read -r vp vk < <(mint_vapid)
    kv_set_pair "$GRIMOIRE_KV_PATH" vapid.public_key "$vp" vapid.private_key "$vk"
    ok "VAPID key pair minted"
  else
    later "grimoire has no VAPID key pair"
  fi
  oidc_client grimoire https://grimoire.jorisjonkers.dev/oidc/callback "$GRIMOIRE_KV_PATH" oidc.client_secret hex32
  # Read back what is there now, whatever this run wrote.
  doc=$(kv_load "$GRIMOIRE_KV_PATH")
  ak=$(kv_field "$doc" s3.access_key_id); sk=$(kv_field "$doc" s3.secret_access_key)
  vp=$(kv_field "$doc" vapid.public_key); vk=$(kv_field "$doc" vapid.private_key)
  [[ -z "$ak" || "$ak" =~ ^GK[0-9a-f]{24}$ ]] || die "s3.access_key_id is not GK + 24 hex"
  [[ -z "$sk" || "$sk" =~ ^[0-9a-f]{64}$ ]] || die "s3.secret_access_key is not 64 hex"
  [[ -z "$vp" || ( ${#vp} -eq 87 && "${vp:0:1}" == B ) ]] || die "vapid.public_key is not an uncompressed P-256 point"
  [[ -z "$vk" || ${#vk} -eq 43 ]] || die "vapid.private_key is not a 32-byte scalar"
  unset sk vk
  result grimoire "checked"
  [[ -z "$LOCAL_VAULT" && -n "$ak" ]] || return 0
  # Garage's copy of the key id is fleet-infra's VaultStaticSecret in data-system.
  projected=$($KUBECTL -n data-system get secret garage-grimoire-key -o jsonpath='{.data.GARAGE_GRIMOIRE_KEY_ID}' 2>/dev/null | base64 -d || true)
  if [[ -n "$projected" && "$projected" != "$ak" ]]; then
    resync data-system garage-grimoire-key GARAGE_GRIMOIRE_KEY_ID
    projected=$RESYNCED
  fi
  if [[ -z "$projected" ]]; then
    note "data-system/garage-grimoire-key is not projected yet"
  elif [[ "$projected" == "$ak" ]]; then
    ok "data-system/garage-grimoire-key matches Vault"
  else
    die "data-system/garage-grimoire-key holds a different key id than Vault"
  fi
  [[ -n "$RERUN_GARAGE" ]] && garage_bootstrap_rerun "$projected"
  return 0
}

# Needed once if the Job ran before the key reached data-system: it skips the
# grant rather than failing.
garage_bootstrap_rerun() {
  local log
  [[ -n "$1" ]] || die "data-system/garage-grimoire-key is not projected: nothing for the Job to grant yet"
  require_tools flux
  confirm "Delete Job data-system/garage-bootstrap and reconcile apps-data?" || return 0
  $KUBECTL -n data-system delete job garage-bootstrap --ignore-not-found >/dev/null
  flux reconcile kustomization apps-data --with-source >/dev/null || die "flux reconcile apps-data failed"
  $KUBECTL -n data-system wait --for=condition=complete job/garage-bootstrap --timeout=300s >/dev/null \
    || die "garage-bootstrap did not complete"
  # Read the whole log first: grep leaving a pipe early would fail it under pipefail.
  log=$($KUBECTL -n data-system logs job/garage-bootstrap)
  grep -q '==> granting read/write on grimoire-assets' <<<"$log" \
    || die "garage-bootstrap completed without granting the grimoire key: read its log"
  ok "the grimoire key is granted on grimoire-assets"
}

# ── findability-explorer ──────────────────────────────────────────────────
# JorisJonkers-dev/findability-explorer deploy/findability-explorer.project.yml.
# Its SESSION_KEY is the deploy-kit generated key secret/findability-explorer-system/session
# → key, so it is not written here: replacing it signs everyone out and makes
# every API key an admin added unreadable.
FE_NS=findability-explorer-system
section_findability_explorer() {
  local doc
  oidc_client findability-explorer https://digital-strategy.jorisjonkers.dev/auth/callback \
    "$FE_NS/oidc" client-secret hex32
  # Read once at start. Without it product matching is off, and every other feature works.
  doc=$(kv_load "$FE_NS/anthropic")
  if [[ -n "$(kv_field "$doc" api-key)" && -z "$ROTATE" ]]; then
    ok "secret/$FE_NS/anthropic → api-key exists ($(fp "$(kv_field "$doc" api-key)"))"
  else
    say "The Anthropic API key product matching uses by default (optional: admins can add others in the app)."
    ask_secret FE_ANTHROPIC "Paste an Anthropic API key (sk-ant-…; Enter skips):"
    if [[ -n "${FE_ANTHROPIC:-}" ]]; then
      [[ "$FE_ANTHROPIC" == sk-ant-* ]] || warn "that does not start with sk-ant-"
      if [[ -z "$LOCAL_VAULT" ]]; then
        [[ "$(printf 'x-api-key: %s\n' "$FE_ANTHROPIC" | curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
          -H @- -H 'anthropic-version: 2023-06-01' https://api.anthropic.com/v1/models)" == 200 ]] \
          || die "api.anthropic.com does not accept that key"
        ok "api.anthropic.com accepts the key"
      fi
      if confirm "Write key $(fp "$FE_ANTHROPIC") to secret/$FE_NS/anthropic → api-key?"; then
        printf '%s' "$FE_ANTHROPIC" | kv_set "$FE_NS/anthropic" api-key
        doc=$(kv_load "$FE_NS/anthropic")
        [[ "$(kv_field "$doc" api-key)" == "$FE_ANTHROPIC" ]] || die "the Anthropic key does not read back"
        ok "secret/$FE_NS/anthropic → api-key = $(fp "$FE_ANTHROPIC")"
      fi
    else
      note "no Anthropic key: product matching stays off until an admin adds one"
    fi
    unset FE_ANTHROPIC
  fi
  generated_check "$FE_NS/session" key
  result findability-explorer "checked"
}

# ── fields: overleaf and hermes ───────────────────────────────────────────
# edit_fields PATH SPEC... checks, and where needed asks for, the fields of a
# document only people write. Each SPEC is key|kind|prompt, kind one of:
#   required    asked when missing
#   asked       optional, asked when missing (Enter skips)
#   rotate      optional, asked only with --rotate or --replace
#   gen:N       required, asked when missing; Enter generates N random bytes, hex
#   hindsight   Hermes' MEMORY_API token for hindsight-api: pasted, or minted by signing in
# Default: present fields are skipped, nothing is asked unless one is missing.
# --rotate asks every field; Enter keeps the current value.
# --replace asks every field (Enter keeps the current value, - drops it) and
# writes a new version holding only them: anything else in the document is
# dropped, and named first, and nothing is written without a typed "yes".
# Values reach vault as JSON on stdin; jq takes them from its environment, not
# its arguments.
edit_fields() {
  local path="$1" doc spec key kind prompt cur value i=0 filter='.' new_doc changes dropping="" dropped
  local -a changed=()
  shift
  doc=$(kv_load "$path")
  for spec in "$@"; do
    IFS='|' read -r key kind prompt <<<"$spec"
    cur=$(kv_field "$doc" "$key")
    if [[ -z "$ROTATE$REPLACE" ]]; then
      if [[ -n "$cur" ]]; then ok "$key exists ($(fp "$cur"))"; continue; fi
      [[ "$kind" == rotate ]] && { note "$key is not set (optional; --only ${CURRENT_SECTION} --rotate asks for it)"; continue; }
    fi
    value=""
    if [[ "$kind" == hindsight ]]; then
      hermes_hindsight_token value "$cur"
    else
      ask_secret value "$prompt${cur:+ [current $(fp "$cur"); Enter keeps${REPLACE:+, - drops}]}:"
      [[ "$kind" == gen:* && -z "$value" && -z "$cur" ]] && value=$(openssl rand -hex "${kind#gen:}") && note "generated $key"
    fi
    if [[ "$value" == - && -n "$REPLACE" ]]; then
      filter+=" | del(.[\"$key\"])"
      continue
    fi
    if [[ -z "$value" ]]; then
      [[ -n "$cur" ]] && continue
      [[ "$kind" == required || "$kind" == gen:* || "$kind" == hindsight ]] && later "secret/$path → $key is still missing"
      continue
    fi
    [[ "$value" != "$cur" ]] || continue
    export "ESV_$i=$value"
    filter+=" | .[\"$key\"] = env.ESV_$i"
    changed+=("$key=$(fp "$value")")
    i=$((i + 1))
  done
  if [[ -n "$REPLACE" ]]; then
    # Keep only what was offered: every key not named in a SPEC goes.
    local offered=""
    for spec in "$@"; do offered+="\"${spec%%|*}\","; done
    filter+=" | with_entries(select(.key | IN(${offered%,})))"
  fi
  new_doc=$(jq -c "$filter" <<<"$doc")
  # Only what changed, for a patch: the same filter over an empty document.
  changes=$(jq -c "$filter" <<<'{}')
  for ((i = 0; i < ${#changed[@]}; i++)); do unset "ESV_$i"; done
  if [[ "$new_doc" == "$(jq -c . <<<"$doc")" ]]; then
    result "$CURRENT_SECTION" "already right"
    return 0
  fi
  dropped=$(jq -r --argjson new "$(jq -c 'keys' <<<"$new_doc")" 'keys - $new | join(" ")' <<<"$doc")
  [[ ${#changed[@]} -eq 0 ]] || say "writing: ${changed[*]}"
  if [[ -n "$dropped" ]]; then
    printf '\n  %sTHIS PERMANENTLY REMOVES:%s %s\n' "$RED" "$RESET" "$dropped"
    note "(recoverable with --only $CURRENT_SECTION --rollback: KV v2 keeps history)"
    [[ " $dropped " != *" smtp.password "* ]] || note "Losing smtp.password fails stalwart's provisioner sidecar, which takes mail down with it."
    printf '  Type yes to proceed: '
    read -r dropping || true
    [[ "$dropping" == yes ]] || { later "secret/$path not written"; result "$CURRENT_SECTION" "not written"; return 0; }
  else
    confirm "Write ${#changed[@]} field(s) to secret/$path?" \
      || { later "secret/$path not written"; result "$CURRENT_SECTION" "not written"; return 0; }
  fi
  if [[ -n "$REPLACE" ]]; then
    printf '%s' "$new_doc" | vault kv put -mount=secret "$path" - >/dev/null
  else
    printf '%s' "$changes" | _kv_write "$path" -
  fi
  # Read back, not trusting the exit code: names and fingerprints only.
  [[ "$(jq -cS . <<<"$(kv_load "$path")")" == "$(jq -cS . <<<"$new_doc")" ]] \
    || die "secret/$path does not read back as written"
  kv_load "$path" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' | while IFS=$'\t' read -r key value; do
    printf '    %-32s %s\n' "$key" "$(fp "$value")"
  done
  ok "secret/$path written and read back"
  result "$CURRENT_SECTION" "written"
  WROTE_FIELDS=yes
  CHANGED_KEYS=" ${changed[*]} $dropped "
}

# kv_rollback PATH lists the document's versions, the field names each holds,
# and rolls back to the one chosen.
kv_rollback() {
  local path="$1" meta v target
  meta=$(vault kv metadata get -mount=secret -format=json "$path" </dev/null) || die "secret/$path has no history"
  jq -r '.data as $m | $m.versions | to_entries | sort_by(.key | tonumber)[]
    | "  version \(.key)  \(.value.created_time[:19])  \(if .value.destroyed then "destroyed" elif .value.deletion_time != "" then "deleted" else "live" end)\(if (.key | tonumber) == $m.current_version then "  <- current" else "" end)"' <<<"$meta"
  for v in $(jq -r '.data.versions | keys[]' <<<"$meta" | sort -n); do
    printf '  version %-4s %s\n' "$v" "$(vault kv get -mount=secret -version="$v" -format=json "$path" 2>/dev/null </dev/null \
      | jq -r '.data.data // {} | keys | join(", ")' || echo '(unreadable)')"
  done
  target=""
  ask target "Roll back to which version? (Enter aborts)"
  [[ -n "$target" ]] || { result "$CURRENT_SECTION" "not rolled back"; return 0; }
  confirm "Roll secret/$path back to version $target?" || { result "$CURRENT_SECTION" "not rolled back"; return 0; }
  vault kv rollback -mount=secret -version="$target" "$path" </dev/null >/dev/null || die "rollback to version $target failed"
  kv_load "$path" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' | while IFS=$'\t' read -r key v; do
    printf '    %-32s %s\n' "$key" "$(fp "$v")"
  done
  ok "secret/$path rolled back to version $target"
  result "$CURRENT_SECTION" "rolled back"
  WROTE_FIELDS=yes
  CHANGED_KEYS=" $(kv_load "$path" | jq -r 'keys | join(" ")') "
}

# ── overleaf ──────────────────────────────────────────────────────────────
# Was fleet-infra scripts/ops/set-overleaf-secrets.sh. Two hard failures hang
# on it: Overleaf throws at boot without invite_token_secret (required since
# 6.2.0), and stalwart's provisioner sidecar treats an empty latex@ password as
# fatal and takes the whole stalwart Pod, mail included, down with it. Its
# Garage keys (secret/overleaf-system/garage) are deploy-kit generated keys.
section_overleaf() {
  WROTE_FIELDS=""
  CHANGED_KEYS=""
  if [[ -n "$ROLLBACK" ]]; then
    kv_rollback platform/overleaf
  else
    say "session_secret signs Overleaf's session cookies: replacing it signs everyone out."
    say "smtp.password is latex@'s password: stalwart-provisioner sets the account to it."
    edit_fields platform/overleaf \
      "session_secret|gen:32|session_secret (Enter generates)" \
      "invite_token_secret|gen:32|invite_token_secret (Enter generates)" \
      "smtp.password|gen:24|smtp.password (Enter generates)"
  fi
  [[ -n "$WROTE_FIELDS" ]] || return 0
  note "Overleaf reads platform/overleaf through its deploy-kit grant; VSO refreshes it and restarts Overleaf."
  # Stalwart reads the same key through its own grant (platform/mail), so a new
  # latex@ password reaches both within VSO's ten-minute refresh, each restarted
  # by it: Stalwart's restart takes mail down for about a minute.
  [[ "$CHANGED_KEYS" != *" smtp.password"* ]] \
    || note "smtp.password changed: Stalwart sets latex@ to it on its restart, within ten minutes; mail is down for about a minute then."
}

# ── mail ──────────────────────────────────────────────────────────────────
# Stalwart seeds its admin from STALWART_RECOVERY_ADMIN, one variable in the
# form user:password. An env file's value is one placeholder, never two
# (deploy-kit spec/v1/10-project-intent.md#the-dotenv-subset-that-is-read), so
# Vault holds the pair as a key of its own, stalwart.recovery_admin, derived
# here from stalwart.admin_user and stalwart.admin_password: the two the
# provisioner sidecar signs in with. Re-run it after either changes. The admin
# login itself is Stalwart's own, so a Vault without it wants a restore, and
# this section never mints one (JorisJonkers-dev/deploy-kit#656).
MAIL_KV_PATH=platform/mail

# vso_readers PATH prints, one a line, every VaultStaticSecret that projects
# secret/PATH, with what VSO restarts when it changes and the version it is
# pinned to, if any. Read-only; nothing in a dry run.
vso_readers() {
  [[ -z "$LOCAL_VAULT" ]] || return 0
  $KUBECTL get vaultstaticsecrets.secrets.hashicorp.com -A -o json 2>/dev/null \
    | jq -r --arg p "$1" '.items[] | select(.spec.mount == "secret" and .spec.path == $p)
        | "\(.metadata.namespace)/\(.metadata.name): " + (if .spec.version then "pinned to version \(.spec.version), so it does not change"
          else "restarts " + ([.spec.rolloutRestartTargets[]? | "\(.kind)/\(.name)"] | if length == 0 then "nothing" else join(", ") end)
               + " within its refresh, \(.spec.refreshAfter // "?")" end)' || true
}

section_mail() {
  local doc user password current wanted readers line
  doc=$(kv_load "$MAIL_KV_PATH")
  user=$(kv_field "$doc" stalwart.admin_user)
  password=$(kv_field "$doc" stalwart.admin_password)
  current=$(kv_field "$doc" stalwart.recovery_admin)
  if [[ -z "$user" || -z "$password" ]]; then
    later "secret/$MAIL_KV_PATH has no stalwart.admin_user or stalwart.admin_password: restore them, then re-run --only mail"
    result mail "waiting for the admin login"
    return 0
  fi
  wanted="$user:$password"
  unset user password
  if [[ "$current" == "$wanted" ]]; then
    ok "secret/$MAIL_KV_PATH → stalwart.recovery_admin matches the admin login ($(fp "$wanted"))"
    result mail "already right"
    return 0
  fi
  [[ -z "$current" ]] || note "stalwart.recovery_admin ($(fp "$current")) differs from the admin login ($(fp "$wanted"))"
  warn "Writing secret/$MAIL_KV_PATH makes a new version of it, and auth reads that path too"
  warn "(account.password): the Vault Secrets Operator then restarts auth-api, one pod at a time."
  readers=$(vso_readers "$MAIL_KV_PATH")
  if [[ -n "$readers" ]]; then
    say "What reads secret/$MAIL_KV_PATH now:"
    while IFS= read -r line; do step "$line"; done <<<"$readers"
  fi
  confirm "Write stalwart.recovery_admin ($(fp "$wanted")) to secret/$MAIL_KV_PATH, restarting auth-api?" \
    || { later "secret/$MAIL_KV_PATH → stalwart.recovery_admin is not written"; result mail "not written"; return 0; }
  printf '%s' "$wanted" | kv_patch "$MAIL_KV_PATH" stalwart.recovery_admin
  doc=$(kv_load "$MAIL_KV_PATH")
  [[ "$(kv_field "$doc" stalwart.recovery_admin)" == "$wanted" ]] || die "secret/$MAIL_KV_PATH does not read back"
  ok "secret/$MAIL_KV_PATH → stalwart.recovery_admin = $(fp "$wanted")"
  result mail written
  note "VSO restarts auth-api-primary within its ten-minute refresh. Stalwart reads the key once mail hands over to the estate path."
  unset wanted
}

# ── hermes ────────────────────────────────────────────────────────────────
# Was fleet-infra scripts/ops/set-hermes-secrets.sh and
# provision-hermes-memory-token.sh. Every key the Deployment reads is optional,
# but config.yaml selects provider: openrouter, so without that key Hermes has
# no model. The dashboard-basic-auth-* fields are unused (OIDC is
# the dashboard's only auth provider), so they are no longer offered, and
# --replace drops them.
HERMES_KV_PATH=agents/hermes
HINDSIGHT_HOST=https://hindsight-api.jorisjonkers.dev
section_hermes() {
  WROTE_FIELDS=""
  if [[ -n "$ROLLBACK" ]]; then
    kv_rollback "$HERMES_KV_PATH"
  else
    edit_fields "$HERMES_KV_PATH" \
      "openrouter-api-key|required|OpenRouter API key (sk-or-…)" \
      "hindsight-api-token|hindsight|" \
      "github-pat|rotate|GitHub PAT for the github MCP server" \
      "anthropic-api-key|rotate|Anthropic API key (for a provider switch)" \
      "openai-api-key|rotate|OpenAI API key (for a provider switch)" \
      "overleaf-session|rotate|Overleaf session cookie (overleaf_session2) for the overleaf MCP server" \
      "memory-api-key|rotate|memory MCP server key (expected empty until that service exists)"
  fi
  [[ -n "$WROTE_FIELDS" && -z "$LOCAL_VAULT" ]] || return 0
  # Reloader restarts Hermes when the Secret changes; its seed-config names any provider key still missing.
  resync agents-system hermes-credentials openrouter-api-key
  note "kubectl -n agents-system logs deploy/hermes -c seed-config   names any key still missing"
}

# hermes_hindsight_token VAR CURRENT: Hermes reaches Hindsight only through the
# gated public host, so it needs a MEMORY_API service token labelled "hermes",
# revocable without touching any device. Paste one, or sign in to mint it.
hermes_hindsight_token() {
  local var="$1" cur="$2" token="" code
  if [[ -n "$cur" ]]; then
    ask_secret token "Hermes's MEMORY_API token (smt_…) [current $(fp "$cur"); Enter keeps, mint signs in for a new one]:"
  else
    ask_secret token "Hermes's MEMORY_API token (smt_…), or Enter to sign in and mint one:"
  fi
  if [[ -z "$token" && -n "$cur" || "$token" == - ]]; then printf -v "$var" '%s' "$token"; return 0; fi
  if [[ -z "$token" || "$token" == mint ]]; then
    [[ -z "$LOCAL_VAULT" ]] || { note "ESTATE_VAULT_ADDR: not signing in to the live auth-api"; printf -v "$var" '%s' ""; return 0; }
    hermes_mint_token token
  fi
  [[ "$token" == smt_* ]] || die "that is not a service token (smt_…)"
  if [[ -z "$LOCAL_VAULT" ]]; then
    code=$(printf 'Authorization: Bearer %s\n' "$token" | curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H @- \
      "$HINDSIGHT_HOST/v1/default/banks/default/documents?limit=1")
    [[ "$code" == 200 ]] || die "hindsight-api refuses the token on the shared bank (HTTP $code)"
    code=$(printf 'Authorization: Bearer %s\n' "$token" | curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H @- \
      "$HINDSIGHT_HOST/v1/default/banks")
    [[ "$code" == 404 ]] || die "the bank list answered HTTP $code with this token; the route should 404 it"
    ok "hindsight-api accepts the token on the shared bank and refuses it elsewhere"
  fi
  printf -v "$var" '%s' "$token"
}

# hermes_mint_token VAR signs in to auth-api with your estate account
# (password, then TOTP if enabled), mints a MEMORY_API token labelled "hermes",
# and logs the session out. Credentials travel on stdin, never as arguments.
hermes_mint_token() {
  local var="$1" api="$AUTH_HOST/api/v1" jar="$WORK/auth.jar" out code body user pass totp="" xsrf
  login() {
    AK_USER="$user" AK_PASS="$pass" AK_TOTP="$totp" jq -n \
      '{username: env.AK_USER, password: env.AK_PASS} + (if env.AK_TOTP != "" then {totpCode: env.AK_TOTP} else {} end)' \
      | curl -s --max-time 20 -c "$jar" -b "$jar" -w '\n%{http_code}' -H 'Content-Type: application/json' \
          --data-binary @- "$api/auth/session-login"
  }
  ask user "Estate username or email:"
  ask_secret pass "Password:"
  [[ -n "$user" && -n "$pass" ]] || die "username and password are required"
  out=$(login); code=${out##*$'\n'}; body=${out%$'\n'*}
  [[ "$code" == 200 ]] || die "sign-in refused (HTTP $code)"
  if [[ "$(jq -r '.totpRequired // false' <<<"$body")" == true ]]; then
    ask totp "TOTP code:"
    out=$(login); code=${out##*$'\n'}; body=${out%$'\n'*}
    [[ "$code" == 200 ]] || die "TOTP refused (HTTP $code)"
  fi
  unset pass
  [[ "$(jq -r '.success // false' <<<"$body")" == true ]] || die "sign-in did not complete"
  # Any authenticated GET issues the XSRF-TOKEN cookie the mint must echo.
  curl -s -o /dev/null --max-time 20 -c "$jar" -b "$jar" "$api/auth/me"
  xsrf=$(awk '$6 == "XSRF-TOKEN" { v = $7 } END { print v }' "$jar")
  [[ -n "$xsrf" ]] || die "auth-api issued no XSRF-TOKEN cookie"
  out=$(printf 'X-XSRF-TOKEN: %s\n' "$xsrf" | curl -s --max-time 20 -b "$jar" -w '\n%{http_code}' -H @- \
    -H 'Content-Type: application/json' --data-binary '{"service":"MEMORY_API","label":"hermes"}' "$api/auth/service-tokens")
  code=${out##*$'\n'}; body=${out%$'\n'*}
  curl -s -o /dev/null --max-time 10 -b "$jar" "$api/auth/logout" || true
  rm -f "$jar"
  [[ "$code" != 403 ]] || die "mint refused (HTTP 403): your account lacks the MEMORY_API grant"
  [[ "$code" == 201 ]] || die "mint refused (HTTP $code)"
  ok "minted MEMORY_API token \"hermes\" (id $(jq -r .id <<<"$body")); the sign-in session is logged out"
  printf -v "$var" '%s' "$(jq -r .token <<<"$body")"
}

# ── mistral ───────────────────────────────────────────────────────────────
# Was fleet-infra scripts/ops/provision-mistral-keys.sh. One key per reader, so
# a leak of one surface does not expose the other and rotating one does not
# break the other: paste the same key twice if you accept that coupling. Each
# key is checked against api.mistral.ai, including that the model is served.
MISTRAL_MODEL=mistral-small-2603
section_mistral() {
  local path doc cur name any=""
  for path in platform/hindsight platform/karakeep; do
    name=${path##*/}
    doc=$(kv_load "$path")
    if [[ "$doc" == "{}" ]]; then
      later "secret/$path does not exist: its other keys come from a Vault restore; not creating it"
      continue
    fi
    cur=$(kv_field "$doc" mistral_api_key)
    if [[ -n "$cur" && -z "$ROTATE" ]]; then
      ok "secret/$path → mistral_api_key exists ($(fp "$cur"))"
      continue
    fi
    MISTRAL_KEY=""
    ask_secret MISTRAL_KEY "Mistral API key for $name (Enter skips):"
    if [[ -z "$MISTRAL_KEY" ]]; then later "secret/$path has no mistral_api_key"; continue; fi
    if [[ -z "$LOCAL_VAULT" ]]; then
      printf 'Authorization: Bearer %s\n' "$MISTRAL_KEY" | curl -fsS --max-time 20 -H @- https://api.mistral.ai/v1/models \
        | jq -e --arg m "$MISTRAL_MODEL" 'any(.data[]; .id == $m)' >/dev/null \
        || die "api.mistral.ai rejects the $name key, or does not serve it $MISTRAL_MODEL"
      ok "api.mistral.ai accepts the key and serves it $MISTRAL_MODEL"
    fi
    if confirm "Write key $(fp "$MISTRAL_KEY") to secret/$path → mistral_api_key?"; then
      printf '%s' "$MISTRAL_KEY" | kv_patch "$path" mistral_api_key
      doc=$(kv_load "$path")
      [[ "$(kv_field "$doc" mistral_api_key)" == "$MISTRAL_KEY" ]] || die "secret/$path does not read back"
      ok "secret/$path → mistral_api_key = $(fp "$MISTRAL_KEY")"
      any=yes
    fi
    unset MISTRAL_KEY
  done
  if [[ -n "$any" ]]; then result mistral written; else result mistral checked; fi
  [[ -z "$any" ]] || note "VSO re-renders both Secrets on its next refresh and restarts the workloads."
}

# ── backup-off-cluster ────────────────────────────────────────────────────
# The credential an irreplaceable volume's backup copies off-cluster with
# (estate#228). platform.intent.yml's durability.irreplaceable.offCluster
# names its path; the render grants it to each backup identity alone and hands
# the whole document to the method as variables (envFrom), so its keys are the
# variable names JorisJonkers-dev/delivery's backup method reads
# (internal/offcluster): AWS_ENDPOINT_URL, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, and AWS_REGION where the provider wants one (it
# defaults to us-east-1). The bucket is not here: it is offCluster.destination.
# Until the document exists, a backup's VaultStaticSecret cannot sync, and a
# Project with an irreplaceable volume never goes Ready.
BACKUP_KV_PATH=platform/backup/off-cluster
BACKUP_ENDPOINT_DEFAULT=https://eu2.contabostorage.com

# backup_destination prints offCluster.destination from platform.intent.yml.
backup_destination() {
  sed -n '/^ *offCluster:/,/^ *egress:/s/^ *destination: *"\{0,1\}\([^" ]*\)"\{0,1\}.*/\1/p' \
    "$here/../platform.intent.yml" | head -n 1
}

# backup_s3_check ENDPOINT BUCKET REGION ID SECRET asks the provider, signed with
# the key pair, whether it sees the bucket (path-style, as the method writes).
# Prints the HTTP status. The pair travels on stdin, never as an argument.
backup_s3_check() {
  printf 'user = "%s:%s"\n' "$4" "$5" \
    | curl -sS --max-time 20 --config - -o /dev/null -w '%{http_code}' -I \
        --aws-sigv4 "aws:amz:$3:s3" "${1%/}/$2" 2>/dev/null || printf 'unreachable'
}

section_backup_off_cluster() {
  local doc endpoint id secret region dest bucket code cas
  doc=$(kv_load "$BACKUP_KV_PATH")
  dest=$(backup_destination)
  [[ "$dest" == s3://* ]] || die "platform.intent.yml names no s3:// offCluster.destination (read: '${dest}')"
  bucket=${dest#s3://}
  bucket=${bucket%%/*}
  endpoint=$(kv_field "$doc" AWS_ENDPOINT_URL)
  id=$(kv_field "$doc" AWS_ACCESS_KEY_ID)
  secret=$(kv_field "$doc" AWS_SECRET_ACCESS_KEY)
  region=$(kv_field "$doc" AWS_REGION)
  if [[ "$endpoint" =~ ^https?://[^/]+/?$ && -n "$id" && -n "$secret" && -z "$ROTATE" ]]; then
    ok "secret/$BACKUP_KV_PATH holds AWS_ENDPOINT_URL $endpoint, AWS_ACCESS_KEY_ID $(fp "$id"), AWS_SECRET_ACCESS_KEY $(fp "$secret")${region:+, AWS_REGION $region}"
    note "the bucket, $bucket, is platform.intent.yml's offCluster.destination, not the credential's"
    result backup-off-cluster "already right"
    return 0
  fi
  if [[ "$doc" == "{}" ]]; then
    say "secret/$BACKUP_KV_PATH does not exist: every irreplaceable volume's backup reads it,"
    say "and a Project with one (mail) never goes Ready without it."
  else
    say "secret/$BACKUP_KV_PATH is incomplete or --rotate asked for a new pair:"
    note "  AWS_ENDPOINT_URL ${endpoint:-none}, AWS_ACCESS_KEY_ID $(fp_or "$id"), AWS_SECRET_ACCESS_KEY $(fp_or "$secret"), AWS_REGION ${region:-none}"
  fi
  say "The key pair is Contabo's: my.contabo.com → Object Storage → S3 credentials, for the"
  say "bucket $bucket ($dest, from platform.intent.yml; the credential does not hold it)."
  BACKUP_ENDPOINT=""
  ask BACKUP_ENDPOINT "S3 endpoint [Enter: ${endpoint:-$BACKUP_ENDPOINT_DEFAULT}]:"
  endpoint=${BACKUP_ENDPOINT:-${endpoint:-$BACKUP_ENDPOINT_DEFAULT}}
  unset BACKUP_ENDPOINT
  [[ "$endpoint" =~ ^https://[^/[:space:]]+/?$ ]] || die "the endpoint is https://host, nothing more: '$endpoint'"
  endpoint=${endpoint%/}
  BACKUP_ID="" BACKUP_SECRET="" BACKUP_REGION=""
  ask_secret BACKUP_ID "Access key id (hidden; Enter skips):"
  ask_secret BACKUP_SECRET "Secret access key (hidden; Enter skips):"
  id=$(printf '%s' "$BACKUP_ID" | tr -d '[:space:]')
  secret=$(printf '%s' "$BACKUP_SECRET" | tr -d '[:space:]')
  unset BACKUP_ID BACKUP_SECRET
  if [[ -z "$id" || -z "$secret" ]]; then
    later "secret/$BACKUP_KV_PATH is not written: an access key id and its secret are both needed"
    result backup-off-cluster "not written"
    return 0
  fi
  ask BACKUP_REGION "Region (optional; Enter leaves it out, and the method signs for us-east-1):"
  region=$(printf '%s' "$BACKUP_REGION" | tr -d '[:space:]')
  unset BACKUP_REGION
  if [[ -z "$LOCAL_VAULT" ]]; then
    code=$(backup_s3_check "$endpoint" "$bucket" "${region:-us-east-1}" "$id" "$secret")
    case "$code" in
      200) ok "$endpoint accepts the pair and it sees bucket $bucket" ;;
      401|403) warn "$endpoint refuses the pair for bucket $bucket ($code): a wrong key, or one without access to it" ;;
      404) warn "$endpoint has no bucket $bucket (404): create it, or fix offCluster.destination" ;;
      *) warn "could not check the pair against $endpoint ($code); the backup's first run will" ;;
    esac
    [[ "$code" == 200 ]] || confirm "Write it anyway?" \
      || { later "secret/$BACKUP_KV_PATH is not written"; result backup-off-cluster "not written"; return 0; }
  fi
  confirm "Write AWS_ENDPOINT_URL $endpoint, AWS_ACCESS_KEY_ID $(fp "$id"), AWS_SECRET_ACCESS_KEY $(fp "$secret")${region:+, AWS_REGION $region} to secret/$BACKUP_KV_PATH?" \
    || { later "secret/$BACKUP_KV_PATH is not written"; result backup-off-cluster "not written"; return 0; }
  # One whole version, checked against the one read, so no stale key survives
  # and a racing write is refused. The values reach jq and vault on stdin.
  cas=$(vault kv metadata get -mount=secret -format=json "$BACKUP_KV_PATH" 2>/dev/null </dev/null \
    | jq -r '.data.current_version // 0' || true)
  printf '%s\0%s\0%s\0%s' "$endpoint" "$id" "$secret" "$region" \
    | jq -Rs 'split("\u0000") as $v
        | {AWS_ENDPOINT_URL: $v[0], AWS_ACCESS_KEY_ID: $v[1], AWS_SECRET_ACCESS_KEY: $v[2]}
          + (if ($v[3] // "") == "" then {} else {AWS_REGION: $v[3]} end)' \
    | vault kv put -mount=secret -cas="${cas:-0}" "$BACKUP_KV_PATH" - >/dev/null \
    || die "writing secret/$BACKUP_KV_PATH failed"
  doc=$(kv_load "$BACKUP_KV_PATH")
  [[ "$(kv_field "$doc" AWS_ENDPOINT_URL)" == "$endpoint" \
    && "$(kv_field "$doc" AWS_ACCESS_KEY_ID)" == "$id" \
    && "$(kv_field "$doc" AWS_SECRET_ACCESS_KEY)" == "$secret" \
    && "$(kv_field "$doc" AWS_REGION)" == "$region" ]] || die "secret/$BACKUP_KV_PATH does not read back"
  ok "secret/$BACKUP_KV_PATH → AWS_ENDPOINT_URL $endpoint, AWS_ACCESS_KEY_ID $(fp "$id"), AWS_SECRET_ACCESS_KEY $(fp "$secret")${region:+, AWS_REGION $region}"
  note "Each backup's VaultStaticSecret syncs it within its refresh; nothing else reads it, so nothing restarts."
  result backup-off-cluster written
  unset id secret
}

# ── garage-keys (optional) ────────────────────────────────────────────────
# fleet-infra cluster/flux/apps/data/garage (README.md, vault-secrets.yaml):
# keys pre-generated in Vault so a rebuild reproduces them. web.* is the key CI
# would publish to assets.jorisjonkers.dev with; archive.* the knowledge
# platform's private archive key. Until a pair exists the bootstrap Job skips
# only that grant, and says so.
section_garage_keys() {
  local doc prefix wrote=""
  doc=$(kv_load platform/garage)
  for prefix in web archive; do
    if [[ -n "$(kv_field "$doc" "$prefix.access_key_id")" && -n "$(kv_field "$doc" "$prefix.secret_access_key")" ]]; then
      ok "secret/platform/garage holds the $prefix key ($(fp "$(kv_field "$doc" "$prefix.access_key_id")"))"
    elif ! named garage-keys; then
      note "no $prefix key in secret/platform/garage (optional: secrets.sh --only garage-keys mints one)"
    elif [[ "$doc" == "{}" ]]; then
      later "secret/platform/garage does not exist: Garage's own keys come from a Vault restore; not creating it"
      break
    elif confirm "Mint the $prefix key pair (GK + 24 hex id, 64 hex secret) into secret/platform/garage?"; then
      kv_set_pair platform/garage "$prefix.access_key_id" "GK$(openssl rand -hex 12)" "$prefix.secret_access_key" "$(hex32)"
      doc=$(kv_load platform/garage)
      [[ "$(kv_field "$doc" "$prefix.access_key_id")" =~ ^GK[0-9a-f]{24}$ ]] || die "the $prefix key does not read back"
      ok "secret/platform/garage → $prefix.access_key_id = $(fp "$(kv_field "$doc" "$prefix.access_key_id")")"
      wrote=yes
    fi
  done
  if [[ -n "$wrote" ]]; then
    note "Re-run the bootstrap Job: kubectl -n data-system delete job garage-bootstrap (Flux recreates it)"
    result garage-keys written
  else
    result garage-keys checked
  fi
}

# ── agents-github-app (optional) ──────────────────────────────────────────
# fleet-infra cluster/flux/apps/agents/GITHUB-APP-SETUP.md: the App id, its
# private key, and the bearer runners present to its token endpoint.
section_agents_github_app() {
  local doc path=agents/github-app pem="" app_id=""
  doc=$(kv_load "$path")
  if [[ -n "$(kv_field "$doc" app-id)" && "$(kv_field "$doc" private-key)" == *"PRIVATE KEY"* && -n "$(kv_field "$doc" token-bearer)" ]]; then
    ok "secret/$path holds the App id, key and bearer"
    result agents-github-app "already right"
    return 0
  fi
  if ! named agents-github-app; then
    note "secret/$path is incomplete (optional: secrets.sh --only agents-github-app)"
    result agents-github-app "optional, not set"
    return 0
  fi
  if [[ -z "$(kv_field "$doc" app-id)" || "$(kv_field "$doc" private-key)" != *"PRIVATE KEY"* ]]; then
    open_url "https://github.com/$ORG/fleet-infra/blob/main/cluster/flux/apps/agents/GITHUB-APP-SETUP.md"
    step "Create and install the App as that page says, and generate a private key."
    ask app_id "The App's id:"
    [[ "$app_id" =~ ^[0-9]+$ ]] || die "an App id is a number"
    ask pem "Full path of the downloaded .pem:"
    grep -q "PRIVATE KEY" "$pem" 2>/dev/null || die "$pem is not a private key"
  fi
  confirm "Write the App id, key and a missing bearer to secret/$path?" \
    || { later "secret/$path not written"; result agents-github-app "not written"; return 0; }
  [[ -z "$app_id" ]] || printf '%s' "$app_id" | kv_set "$path" app-id
  [[ -z "$pem" ]] || kv_set "$path" private-key < "$pem"
  [[ -n "$(kv_field "$doc" token-bearer)" ]] || hex32 | kv_set "$path" token-bearer
  doc=$(kv_load "$path")
  [[ -n "$(kv_field "$doc" app-id)" && "$(kv_field "$doc" private-key)" == *"PRIVATE KEY"* && -n "$(kv_field "$doc" token-bearer)" ]] \
    || die "secret/$path does not read back whole"
  ok "secret/$path holds the App id, key ($(fp "$(kv_field "$doc" private-key)")) and bearer"
  result agents-github-app "written"
  if [[ -n "$pem" ]] && confirm "Delete $pem now that Vault holds it?"; then rm -f "$pem"; fi
}

# ── agents-deploy-key (optional) ──────────────────────────────────────────
# fleet-infra cluster/flux/apps/agents/SETUP.md: the shared read-only deploy
# key ad-hoc "Repo URL" workspaces fall back to. Project-backed workspaces do
# not need it. Generated here, so the private key never leaves $WORK.
section_agents_deploy_key() {
  local doc path=agents/github-deploy-key key="$WORK/agents-deploy"
  doc=$(kv_load "$path")
  if [[ -n "$(kv_field "$doc" private_key)" && -n "$(kv_field "$doc" public_key)" && -n "$(kv_field "$doc" known_hosts)" ]]; then
    ok "secret/$path holds a deploy key ($(fp "$(kv_field "$doc" public_key)")) and known_hosts"
    result agents-deploy-key "already right"
    return 0
  fi
  if ! named agents-deploy-key; then
    note "secret/$path is incomplete (optional: secrets.sh --only agents-deploy-key)"
    result agents-deploy-key "optional, not set"
    return 0
  fi
  require_tools ssh-keygen ssh-keyscan
  ssh-keygen -q -t ed25519 -f "$key" -C "agents-shared-deploy-key" -N "" </dev/null
  ssh-keyscan github.com 2>/dev/null > "$key.known_hosts"
  [[ -s "$key.known_hosts" ]] || die "ssh-keyscan github.com returned nothing"
  say "Add this public key as a deploy key, write access unchecked, on a sandbox repository:"
  printf '\n    %s\n\n' "$(cat "$key.pub")"
  pause "Press Enter once GitHub shows the deploy key"
  confirm "Write the key pair and known_hosts to secret/$path?" \
    || { later "secret/$path not written"; result agents-deploy-key "not written"; return 0; }
  kv_set "$path" private_key < "$key"
  kv_set "$path" public_key < "$key.pub"
  kv_set "$path" known_hosts < "$key.known_hosts"
  doc=$(kv_load "$path")
  [[ "$(kv_field "$doc" public_key)" == "$(cat "$key.pub")" ]] || die "secret/$path does not read back"
  ok "secret/$path holds the deploy key ($(fp "$(cat "$key.pub")")); the local copy goes with \$WORK"
  result agents-deploy-key "written"
}

# ── auth-api ──────────────────────────────────────────────────────────────
# After every client section: restart auth-api once if it must read a new
# secret, then prove each client. The token endpoint is asked to redeem a
# bogus code: invalid_grant means the client and secret were accepted and
# only the code was refused; invalid_client, an unknown client or a wrong secret.
token_error() { # token_error ID SECRET REDIRECT_URI
  printf 'user = "%s:%s"\n' "$1" "$2" \
    | curl -sS --max-time 15 --config - "$AUTH_HOST/api/oauth2/token" \
        --data-urlencode grant_type=authorization_code \
        --data-urlencode code=bootstrap-check \
        --data-urlencode "redirect_uri=$3" 2>/dev/null \
    | sed -n 's/.*"error" *: *"\([^"]*\)".*/\1/p' || true
}

section_auth_api() {
  local template entry id redirect env_name auth secret real wrong restart="" missing=""
  if [[ -n "$LOCAL_VAULT" ]]; then
    note "ESTATE_VAULT_ADDR: no auth-api to restart or prove against"
    result auth-api "skipped (local Vault)"
    return 0
  fi
  if ! $KUBECTL -n auth-system get deploy auth-api >/dev/null 2>&1; then
    later "auth-api is not deployed yet: re-run secrets.sh once it is, to prove the clients"
    result auth-api "not deployed"
    return 0
  fi
  template=$($KUBECTL -n auth-system get deploy auth-api \
    -o jsonpath='{.spec.template.metadata.annotations.vault\.hashicorp\.com/agent-inject-template-auth-api\.env}')
  for entry in "${CLIENTS[@]}"; do
    IFS='|' read -r id redirect env_name <<<"$entry"
    if [[ "$template" != *"$env_name"* ]]; then
      note "auth-api's template has no $env_name yet: fleet-infra's change adding it rolls auth-api when it merges"
      missing+=" $id"
    elif [[ " ${AUTH_WRITTEN[*]} " == *" $id "* ]]; then
      restart=yes
    fi
  done
  [[ -z "$RESTART_AUTH" ]] || restart=yes
  if [[ -n "$restart" ]]; then
    if confirm "Restart auth-api? It reads client secrets only at pod start."; then
      $KUBECTL -n auth-system rollout restart deploy/auth-api >/dev/null
      # Two replicas of a JVM take longer than five minutes to replace on a busy
      # node. Slow is not failed: the proof below reads what is serving now.
      $KUBECTL -n auth-system rollout status deploy/auth-api --timeout=600s >/dev/null \
        || warn "auth-api is still rolling; the proof reads what is serving now"
    else
      later "auth-api still serves the old secret: restart it (secrets.sh --only <client> --restart-auth-api)"
    fi
  fi
  auth=$(kv_load "$AUTH_KV_PATH")
  for entry in "${CLIENTS[@]}"; do
    IFS='|' read -r id redirect env_name <<<"$entry"
    secret=$(kv_field "$auth" "auth.clients.$id.secret")
    [[ -n "$secret" ]] || continue
    real=$(token_error "$id" "$secret" "$redirect")
    wrong=$(token_error "$id" "not-the-secret-$(openssl rand -hex 4)" "$redirect")
    if [[ -z "$wrong" ]]; then later "$AUTH_HOST did not answer for $id: re-run to prove it"; continue; fi
    [[ "$wrong" == invalid_client ]] || die "auth-api answered '$wrong' to a wrong $id secret: it is not checking it"
    if [[ "$real" == invalid_grant ]]; then
      ok "$id authenticates at $AUTH_HOST with the Vault secret, and only with it"
    else
      later "auth-api does not serve $id with the Vault secret yet ($real): deploy the auth-api release that registers it${missing:+, merge the template line in fleet-infra,} and wait for the rollout, then: secrets.sh --only $id --restart-auth-api"
    fi
  done
  result auth-api "proved"
}

# ── run ───────────────────────────────────────────────────────────────────
CLIENT_SECTIONS=" estate-dashboard tribelt grimoire findability-explorer "
any_client=""
for name in "${SELECTED[@]}"; do [[ "$CLIENT_SECTIONS" == *" $name "* ]] && any_client=yes; done
TOTAL_STAGES=$(( 1 + ${#SELECTED[@]} ))
[[ -z "$any_client" ]] || TOTAL_STAGES=$((TOTAL_STAGES + 1))

if [[ -z "${_ESTATE_VAULT_INHERITED:-}" ]]; then
  banner "Estate: the secrets people put in Vault"
fi
section "Vault: reach it and sign in"
require_tools jq curl openssl
[[ -n "$LOCAL_VAULT" || -n "${_ESTATE_VAULT_INHERITED:-}" ]] || { require_tools "$KUBECTL"; require_cluster; }
vault_connect

for CURRENT_SECTION in "${SELECTED[@]}"; do
  for entry in "${SECTIONS[@]}"; do [[ "${entry%%|*}" == "$CURRENT_SECTION" ]] && section "$CURRENT_SECTION: ${entry#*|}"; done
  case "$CURRENT_SECTION" in
    vault-bootstrap) section_vault_bootstrap ;;
    policy-admin) section_policy_admin ;;
    metrics-token) section_metrics_token ;;
    discord-webhook) section_discord_webhook ;;
    cloudflare) section_cloudflare ;;
    collector-key) section_app_key collector-key ESTATE_COLLECTOR "$COLLECTOR_KV_PATH" Collector "${ESTATE_COLLECTOR_PEM:-}" ;;
    reporter-key) section_app_key reporter-key ESTATE_REPORTER "$REPORTER_KV_PATH" Reporter "${ESTATE_REPORTER_PEM:-}" ;;
    estate-dashboard) section_estate_dashboard ;;
    tribelt) section_tribelt ;;
    grimoire) section_grimoire ;;
    findability-explorer) section_findability_explorer ;;
    overleaf) section_overleaf ;;
    mail) section_mail ;;
    hermes) section_hermes ;;
    mistral) section_mistral ;;
    backup-off-cluster) section_backup_off_cluster ;;
    garage-keys) section_garage_keys ;;
    agents-github-app) section_agents_github_app ;;
    agents-deploy-key) section_agents_deploy_key ;;
  esac
done
if [[ -n "$any_client" ]]; then
  section "auth-api: read the client secrets, and prove each client"
  section_auth_api
fi

printf '\n%s%s  Done%s\n' "$BOLD" "$GREEN" "$RESET"
for line in "${RESULTS[@]}"; do note "  $line"; done
(( ${#WRITTEN_ENV[@]} )) && note "wrote ${WRITTEN_ENV[*]} to $ENV_FILE"
if (( ${#SKIPPED[@]} )); then
  printf '\n'; warn "still to do:"
  for s in "${SKIPPED[@]}"; do note "  - $s"; done
fi
printf '\n'
