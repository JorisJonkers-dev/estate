# shellcheck shell=bash
# shellcheck disable=SC2034 # the names below are read by the scripts that source this
# What the estate's bootstrap scripts share, above the wizard library: the
# names they agree on, how they reach Vault, and the reads and writes more than
# one script makes. Sourced after lib/wizard.sh, never run.

ORG="JorisJonkers-dev"
ESTATE="$ORG/estate"
KUBECTL=${KUBECTL:-kubectl}

# The App ids are not secret, and the scripts read them, so they are kept
# outside the repository. The wizard library defaults ENV_FILE to ./.env, so
# set it outright. No key is ever written here.
ENV_FILE="${ESTATE_ENV_FILE:-$HOME/.config/estate-bootstrap.env}"
mkdir -p "$(dirname "$ENV_FILE")"

# Vault paths, on the KV v2 mount `secret`.
# The Collector reads its key where the render derives it, <namespace>/<application>
# of the delivery Project's collector; its rendered Vault policy grants that path alone.
COLLECTOR_KV_PATH="delivery-system/collector"
# The Reporter's, likewise: the delivery Project's reporter.
REPORTER_KV_PATH="delivery-system/reporter"
# Every OIDC client's secret at auth-api, one key per client. Shared by every
# client, so it is only ever patched, and never created here.
AUTH_KV_PATH="auth-api"

# ESTATE_VAULT_ADDR names a Vault directly, for a dry run against a local
# `vault server -dev`: every cluster step is skipped, and so is every check
# against a live service.
LOCAL_VAULT=""
[[ -n "${ESTATE_VAULT_ADDR:-}" ]] && LOCAL_VAULT=yes
# Vault's OIDC sign-in, where auth-api is the provider. The CLI's callback is
# http://localhost:8250/oidc/callback, which auth-api's `vault` client allows.
VAULT_OIDC_PATH=${ESTATE_VAULT_OIDC_PATH:-oidc}
# The namespace Vault's Service is in: secrets-system since the secrets
# Project's handover (JorisJonkers-dev/deploy-kit#663). Set it to data-system
# to reach the old path's Vault, which a rollback of that handover unseals.
VAULT_NAMESPACE=${ESTATE_VAULT_NAMESPACE:-secrets-system}
VAULT_OIDC_ROLE=${ESTATE_VAULT_OIDC_ROLE:-}

VAULT_PF_PID=""
VAULT_PF_LOG=""
VAULT_TOKEN_MINTED=""

ok()  { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
die() { printf '\n  %s✗ %s%s\n\n' "$RED" "$1" "$RESET" >&2; exit 1; }

# fp VALUE prints the first 12 hex characters of the value's SHA-256: how a
# secret is shown, since the value never is.
fp() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-12
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-12
  fi
}

# require_tools TOOL... stops unless every tool is on PATH.
require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
  done
}

# require_cluster names the kubectl context and stops if Vault is not there.
require_cluster() {
  $KUBECTL -n "$VAULT_NAMESPACE" get service vault >/dev/null 2>&1 \
    || die "cannot see service $VAULT_NAMESPACE/vault (context: $($KUBECTL config current-context 2>/dev/null))"
  ok "cluster reachable, context $($KUBECTL config current-context)"
  confirm "Is $($KUBECTL config current-context) the cluster you mean to write to?" \
    || die "switch the kubectl context and re-run"
}

# estate_cleanup is every script's EXIT trap: it revokes a Vault token this
# run signed in for, closes the port-forward, and removes $WORK.
estate_cleanup() {
  if [[ -n "$VAULT_TOKEN_MINTED" ]]; then
    vault token revoke -self >/dev/null 2>&1 </dev/null && printf '  revoked the Vault token this run signed in with\n'
  fi
  if [[ -n "$VAULT_PF_PID" ]]; then
    kill "$VAULT_PF_PID" 2>/dev/null || true
    wait "$VAULT_PF_PID" 2>/dev/null || true
  fi
  [[ -n "$VAULT_PF_LOG" ]] && rm -f "$VAULT_PF_LOG"
  [[ -n "${WORK:-}" ]] && rm -rf "$WORK"
  return 0
}

# vault_connect reaches Vault with the local vault CLI and signs in. It sets
# and exports VAULT_ADDR, and VAULT_TOKEN unless ~/.vault-token is the token.
#
#   address  ESTATE_VAULT_ADDR when set; else a port-forward to svc/vault in
#            $VAULT_NAMESPACE on a free local port, so the OIDC callback, which the
#            CLI serves itself on localhost:8250, never meets the forward.
#   token    a VAULT_TOKEN already in the environment that Vault accepts; else
#            OIDC sign-in with your estate account (a browser opens); else a
#            valid ~/.vault-token; else one you paste, which is the path for a
#            Vault initialised minutes ago, whose root token is the only way in.
vault_connect() {
  require_tools vault curl jq
  if [[ -n "${_ESTATE_VAULT_INHERITED:-}" ]]; then
    [[ -n "${VAULT_ADDR:-}" ]] || die "_ESTATE_VAULT_INHERITED without VAULT_ADDR"
  elif [[ -n "$LOCAL_VAULT" ]]; then
    export VAULT_ADDR="$ESTATE_VAULT_ADDR"
    warn "ESTATE_VAULT_ADDR: Vault at $VAULT_ADDR; cluster steps and live checks are skipped"
  else
    _vault_port_forward
  fi
  _vault_health
  _vault_login
}

_vault_port_forward() {
  local port="" _
  VAULT_PF_LOG=$(mktemp)
  # Local port 0: kubectl picks a free one and logs it, so no port ever collides.
  $KUBECTL -n "$VAULT_NAMESPACE" port-forward svc/vault 0:8200 </dev/null >"$VAULT_PF_LOG" 2>&1 &
  VAULT_PF_PID=$!
  for _ in $(seq 1 30); do
    kill -0 "$VAULT_PF_PID" 2>/dev/null || die "the port-forward to svc/vault exited: $(tr '\n' ' ' <"$VAULT_PF_LOG")"
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$VAULT_PF_LOG" | head -n 1)
    [[ -n "$port" ]] && break
    sleep 1
  done
  [[ -n "$port" ]] || die "the port-forward to svc/vault did not start within 30s"
  export VAULT_ADDR="http://localhost:$port"
}

_vault_health() {
  local health="" _
  for _ in $(seq 1 15); do
    health=$(curl -s --max-time 3 "$VAULT_ADDR/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200" || true)
    [[ -n "$health" ]] && break
    sleep 1
  done
  [[ -n "$health" ]] || die "Vault does not answer at $VAULT_ADDR"
  [[ "$(jq -r .initialized <<<"$health")" == true ]] \
    || die "Vault is not initialised: fleet-infra's Vault playbooks come first"
  [[ "$(jq -r .sealed <<<"$health")" == false ]] \
    || die "Vault is sealed: run fleet-infra's scripts/ops/unseal-vault.sh first"
  ok "Vault answers at $VAULT_ADDR, initialised and unsealed"
}

# _vault_oidc_ready succeeds when Vault answers an OIDC sign-in request with an
# auth URL (200). An unmounted method answers 403, an unconfigured one 400.
_vault_oidc_ready() {
  local body
  body=$(printf '{"role":"%s","redirect_uri":"http://localhost:8250/oidc/callback"}' "$VAULT_OIDC_ROLE")
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST --data "$body" \
    "$VAULT_ADDR/v1/auth/$VAULT_OIDC_PATH/oidc/auth_url")" == 200 ]]
}

_vault_login() {
  local token=""
  if [[ -n "${VAULT_TOKEN:-}" ]] && vault token lookup >/dev/null 2>&1 </dev/null; then
    ok "Vault accepts the VAULT_TOKEN in the environment"
  else
    unset VAULT_TOKEN
    if [[ -n "$LOCAL_VAULT" ]]; then
      note "ESTATE_VAULT_ADDR: no OIDC sign-in against a local Vault"
    elif _vault_oidc_ready; then
      say "Signing in to Vault with your estate account. A browser opens on auth;"
      say "the CLI catches the callback on localhost:8250."
      # -token-only implies -no-store: the token stays in this process, and is revoked on exit.
      if token=$(vault login -method=oidc -path="$VAULT_OIDC_PATH" -token-only \
        ${VAULT_OIDC_ROLE:+"role=$VAULT_OIDC_ROLE"} </dev/null) && [[ -n "$token" ]]; then
        export VAULT_TOKEN="$token"
        VAULT_TOKEN_MINTED=yes
      else
        warn "OIDC sign-in did not complete"
      fi
    else
      note "Vault offers no OIDC sign-in at auth/$VAULT_OIDC_PATH (a Vault initialised minutes ago?)"
    fi
    if [[ -z "${VAULT_TOKEN:-}" ]] && vault token lookup >/dev/null 2>&1 </dev/null; then
      ok "Vault accepts ~/.vault-token"
    elif [[ -z "${VAULT_TOKEN:-}" ]]; then
      step "Paste a Vault token: the root token on a Vault just initialised or restored."
      ask_secret VAULT_TOKEN "Vault token:"
      [[ -n "${VAULT_TOKEN:-}" ]] || die "no Vault token given"
      export VAULT_TOKEN
    fi
  fi
  vault token lookup >/dev/null 2>&1 </dev/null || die "Vault rejected the token"
  ok "signed in to Vault as $(vault token lookup -format=json </dev/null \
    | jq -r '"\(.data.display_name), policies \(.data.policies | join(","))"')"
}

# kv_load PATH prints the document's keys as JSON, or {} when Vault holds
# nothing there (never written, or its current version deleted). Any other
# failure stops: "could not read" must never pass for "absent", which would
# mint new values over live ones. Call it only as a plain assignment
# (doc=$(kv_load p)), never with `local`, so that stopping stops the script.
kv_load() {
  local out
  if out=$(vault kv get -mount=secret -format=json "$1" 2>&1 </dev/null); then
    jq -c '.data.data // {}' <<<"$out"
  elif grep -q 'No value found' <<<"$out"; then
    printf '{}'
  else
    die "could not read secret/$1: $(head -n 1 <<<"$out")"
  fi
}

# kv_field JSON KEY prints one key of a document kv_load printed, or nothing.
kv_field() { jq -r --arg k "$2" '.[$k] // empty' <<<"$1"; }

# Every patch reads the document and writes it back (-method=rw): an estate admin's policy grants
# read and update but not Vault's separate "patch" capability, and without it a plain
# `vault kv patch` falls back on its own, prints "Data was written" for a document that does not
# exist, writes nothing and exits 2.
#
# _kv_write PATH ARG... patches the document; where Vault holds no current
# version, it creates one, checked against the version it saw, so a write that
# races another is refused rather than lost. Values arrive on stdin, never in
# an argument: `key=-` for one, `-` for a JSON object.
_kv_write() {
  local path="$1" input out cas
  shift
  input=$(cat)
  if out=$(printf '%s' "$input" | vault kv patch -method=rw -mount=secret "$path" "$@" 2>&1); then
    return 0
  fi
  # A document that does not exist yet: the read half of the read-and-write finds nothing.
  grep -q -e 'Code: 404' -e 'No value found' <<<"$out" \
    || die "writing secret/$path failed: $(head -n 1 <<<"$out")"
  cas=$(vault kv metadata get -mount=secret -format=json "$path" 2>/dev/null </dev/null \
    | jq -r '.data.current_version // 0' || true)
  printf '%s' "$input" | vault kv put -mount=secret -cas="${cas:-0}" "$path" "$@" >/dev/null \
    || die "creating secret/$path failed"
}

# kv_set PATH KEY writes the value on stdin as KEY of PATH, creating the
# document if Vault holds none. Never for secret/auth-api: that is kv_patch.
kv_set() {
  local value
  value=$(cat)
  [[ -n "$value" ]] || die "refusing to write an empty $2 to secret/$1"
  printf '%s' "$value" | _kv_write "$1" "$2=-"
}

# kv_patch PATH KEY writes the value on stdin as KEY of a document that must
# already exist, and never creates it.
kv_patch() {
  local value out
  value=$(cat)
  [[ -n "$value" ]] || die "refusing to write an empty $2 to secret/$1"
  out=$(printf '%s' "$value" | vault kv patch -method=rw -mount=secret "$1" "$2=-" 2>&1) \
    || die "patching secret/$1 failed: $(head -n 1 <<<"$out")"
}

# kv_set_pair PATH KEY1 VALUE1 KEY2 VALUE2 writes two keys in one version, so
# a pair (an access key and its secret) never lands half. For values that need
# no JSON escaping only: hex and base64url. printf is a builtin, so the values
# are in no process's arguments.
kv_set_pair() {
  printf '{"%s":"%s","%s":"%s"}' "$2" "$3" "$4" "$5" | _kv_write "$1" -
}

# check_app_key PREFIX KV_PATH succeeds when Vault holds the App's id,
# installation id and a private key, and the ids match the saved ones.
check_app_key() {
  local prefix="$1" path="$2" doc
  doc=$(kv_load "$path")
  [[ -n "$(kv_field "$doc" app-id)" ]] \
    && [[ "$(kv_field "$doc" app-id)" == "$(_existing "${prefix}_APP_ID" || true)" ]] \
    && [[ "$(kv_field "$doc" installation-id)" == "$(_existing "${prefix}_INSTALLATION_ID" || true)" ]] \
    && [[ "$(kv_field "$doc" private-key)" == *"PRIVATE KEY"* ]]
}

# store_app_key PREFIX KV_PATH PEM_FILE writes an App's key, and the id and
# installation id saved as PREFIX_APP_ID and PREFIX_INSTALLATION_ID, to Vault,
# and stops unless all three read back.
store_app_key() {
  local prefix="$1" path="$2" pem="$3" app_id installation_id
  app_id=$(_existing "${prefix}_APP_ID" || true)
  installation_id=$(_existing "${prefix}_INSTALLATION_ID" || true)
  [[ -n "$app_id" && -n "$installation_id" ]] \
    || die "$ENV_FILE lacks ${prefix}_APP_ID or ${prefix}_INSTALLATION_ID; run github-apps.sh first"
  grep -q "PRIVATE KEY" "$pem" || die "$pem is not a private key"
  # One put: the entry is the App's alone, so nothing else is overwritten. The
  # ids are not secret; the key arrives on stdin.
  vault kv put -mount=secret "$path" \
    app-id="$app_id" installation-id="$installation_id" private-key=- < "$pem" >/dev/null
  check_app_key "$prefix" "$path" || die "secret/$path did not read back"
}
