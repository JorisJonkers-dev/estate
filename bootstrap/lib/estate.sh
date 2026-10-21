# shellcheck shell=bash
# What the estate's bootstrap scripts share, above the wizard library: the
# names they agree on, and the checks and writes more than one script makes.
# Sourced after lib/wizard.sh, never run.

ORG="JorisJonkers-dev"
ESTATE="$ORG/estate"
KUBECTL=${KUBECTL:-kubectl}

# The App ids are not secret, and both scripts read them, so they are kept
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
AUTH_KV_PATH="auth-api"
DASHBOARD_CLIENT_KV_KEY="auth.clients.estate-dashboard.secret"
# The dashboard's sign-in document, where its project file grants its Process a read
# (JorisJonkers-dev/estate-dashboard deploy/estate-dashboard.project.yml): the OIDC client
# secret, the key its session cookie is sealed with, and the token it reads the Estate
# repository with. One document, because its reader set is that one Process.
DASHBOARD_KV_PATH="estate-dashboard-system/sign-in"
DASHBOARD_KV_KEY="oidc-client-secret"
DASHBOARD_SESSION_KV_KEY="session-key"
DASHBOARD_GITHUB_KV_KEY="github-token"

ok()  { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
die() { printf '\n  %s✗ %s%s\n\n' "$RED" "$1" "$RESET" >&2; exit 1; }

# require_tools TOOL... stops unless every tool is on PATH.
require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
  done
}

# require_cluster names the kubectl context and stops if Vault is not there.
require_cluster() {
  $KUBECTL -n data-system get pod vault-0 >/dev/null 2>&1 \
    || die "cannot see pod data-system/vault-0 (context: $($KUBECTL config current-context 2>/dev/null))"
  ok "cluster reachable, context $($KUBECTL config current-context)"
  confirm "Is $($KUBECTL config current-context) the cluster you mean to write to?" \
    || die "switch the kubectl context and re-run"
}

# vault_exec ARGS... runs the vault CLI inside vault-0, stdin passed through,
# so no port-forward and no local Vault address are needed.
vault_exec() {
  $KUBECTL -n data-system exec -i vault-0 -c vault -- env VAULT_TOKEN="$VAULT_TOKEN" vault "$@"
}

# require_vault_token asks for a token once and stops unless Vault accepts it.
require_vault_token() {
  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    step "The next stages read and write Vault. Use the Vault UI's 'Copy token',"
    step "or the root token on a cluster just restored."
    open_url "https://vault.jorisjonkers.dev/ui/"
    ask_secret VAULT_TOKEN "Paste a Vault token:"
  fi
  [[ -n "${VAULT_TOKEN:-}" ]] || die "no Vault token given"
  vault_exec token lookup >/dev/null 2>&1 || die "Vault rejected that token"
  ok "Vault accepted the token"
}

# vault_field PATH FIELD prints one field of a KV entry, or nothing. A lookup
# never reads stdin: `kubectl exec -i` would forward, and so swallow, whatever
# the caller is piping to a later write.
vault_field() {
  vault_exec kv get -mount=secret -field="$2" "$1" </dev/null 2>/dev/null || true
}

# vault_set PATH FIELD reads a value on stdin and writes it as FIELD of PATH,
# patching an entry that exists and creating one that does not. The value is
# read first, so the existence check cannot consume it.
vault_set() {
  local value
  value=$(cat)
  [[ -n "$value" ]] || die "refusing to write an empty $2 to secret/$1"
  if vault_exec kv get -mount=secret "$1" </dev/null >/dev/null 2>&1; then
    printf '%s' "$value" | vault_exec kv patch -mount=secret "$1" "$2=-" >/dev/null 2>&1
  else
    printf '%s' "$value" | vault_exec kv put -mount=secret "$1" "$2=-" >/dev/null
  fi
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
  # One put: the entry is the App's alone, so nothing else is overwritten.
  vault_exec kv put -mount=secret "$path" \
    app-id="$app_id" installation-id="$installation_id" private-key=- < "$pem" >/dev/null
  check_app_key "$prefix" "$path" || die "secret/$path did not read back"
}

# check_app_key PREFIX KV_PATH succeeds when Vault holds the App's id,
# installation id and a private key matching the saved ids.
check_app_key() {
  local prefix="$1" path="$2"
  [[ "$(vault_field "$path" app-id)" == "$(_existing "${prefix}_APP_ID" || true)" ]] \
    && [[ "$(vault_field "$path" installation-id)" == "$(_existing "${prefix}_INSTALLATION_ID" || true)" ]] \
    && [[ "$(vault_field "$path" private-key)" == *"PRIVATE KEY"* ]]
}

store_collector_key() { store_app_key ESTATE_COLLECTOR "$COLLECTOR_KV_PATH" "$1"; }
check_collector_key() { check_app_key ESTATE_COLLECTOR "$COLLECTOR_KV_PATH"; }
store_reporter_key() { store_app_key ESTATE_REPORTER "$REPORTER_KV_PATH" "$1"; }
check_reporter_key() { check_app_key ESTATE_REPORTER "$REPORTER_KV_PATH"; }
