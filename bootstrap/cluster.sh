#!/usr/bin/env bash
#
# Everything a cluster needs, outside git, before the estate path can deliver
# to it: run once per cluster, after Flux is installed and Vault is unsealed
# (fleet-infra cluster/bootstrap/flux-bootstrap-playbook.md, and its Vault
# unseal and restore playbooks), and again after any move.
#
#   Flux       Secret flux-system/estate, an SSH key pair generated in the
#              cluster whose public half is a read-only deploy key on estate,
#              and Secret flux-system/render-pull, the ghcr.io credential every
#              pin names.
#   Vault      the Collector's and the Reporter's App keys; the estate-dashboard's
#              OIDC client secret, in both the copy auth-api reads and the
#              dashboard's own sign-in document, beside its session key and its
#              GitHub token; and the role the Vault policy job logs in as.
#   Postgres   the estate-dashboard's database and its login, on the Postgres
#              the old path runs, whose URL goes to Vault beside the sign-in
#              document, until deploy-kit derives that credential.
#              A restored Vault already holds both and this only checks them; a
#              fresh one gets them back here.
#
# The GitHub Apps themselves are github-apps.sh's, once per organization. Safe
# to re-run: each stage checks what exists before it writes, and reads back
# what it wrote.

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/wizard.sh
source "$here/lib/wizard.sh"
# shellcheck source=lib/estate.sh
source "$here/lib/estate.sh"

TOTAL_STAGES=11

AUTH_NS=auth-system
AUTH_HOST=${AUTH_HOST:-https://auth.jorisjonkers.dev}
DASHBOARD_CLIENT_ID=estate-dashboard
DASHBOARD_REDIRECT_URI=https://estate.jorisjonkers.dev/auth/callback
DEPLOY_KEY_TITLE="flux-system/estate (read-only)"
# The Postgres the old path runs (platform.intent.yml handover.serving), where the
# dashboard's database is created while `data` is legacy.
PG_NS=data-system
PG_HOST=postgres.$PG_NS.svc.cluster.local
# The Vault policy job (platform.intent.yml policyJob): the role it logs in as,
# and the ServiceAccount it runs as, in the Secret Store's namespace. While
# `secrets` is legacy that is where the old path runs Vault, data-system, as
# platform.intent.yml's handover.serving states; it becomes secrets-system in
# the change that hands `secrets` over and removes that statement.
POLICY_ROLE=policy-admin
POLICY_SA=vault-policy
POLICY_NS=data-system
# The CRDs of the bootstrap set that no render holds (platform.intent.yml
# bootstrap.crds): Flagger's, at the release its image in the delivery Project is.
FLAGGER_VERSION=v1.45.0
FLAGGER_CRDS_URL="https://raw.githubusercontent.com/fluxcd/flagger/$FLAGGER_VERSION/artifacts/flagger/crd.yaml"
FLAGGER_CRDS_SHA256=58bd594b9e33deb0edceac81f6ed160b458a7933039fb295552724f656033ee5

WORK=$(umask 077 && mktemp -d)
trap 'rm -rf "$WORK"' EXIT

banner "Estate: one cluster's credentials"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "Preflight: tools, cluster, GitHub and Vault"
require_tools "$KUBECTL" flux gh jq curl openssl shasum
require_cluster
$KUBECTL get crd ocirepositories.source.toolkit.fluxcd.io >/dev/null 2>&1 \
  || die "Flux is not installed; run fleet-infra's flux-bootstrap-playbook first"
ok "Flux is installed"
gh auth status >/dev/null 2>&1 || die "gh is not signed in: run 'gh auth login'"
ok "gh signed in"
require_vault_token
for key in ESTATE_COLLECTOR_APP_ID ESTATE_COLLECTOR_INSTALLATION_ID ESTATE_REPORTER_APP_ID ESTATE_REPORTER_INSTALLATION_ID; do
  if [[ -z "$(_existing "$key" || true)" ]]; then
    note "$ENV_FILE has no $key (a new machine?). The App's settings page shows it."
    value=""
    ask value "$key:"
    [[ "$value" =~ ^[0-9]+$ ]] || die "$key is a number"
    write_env "$key" "$value"
  fi
done
pause

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "Flux: read access to the estate repository"
say "Flux generates the key pair in the cluster; only its public half leaves it."
if $KUBECTL -n flux-system get secret estate >/dev/null 2>&1 \
  && ! confirm "Secret flux-system/estate exists. Regenerate it (its deploy key stops working)?"; then
  ok "keeping Secret flux-system/estate"
else
  confirm "Write Secret flux-system/estate?" || die "stopped"
  flux create secret git estate --namespace=flux-system \
    --url=ssh://git@github.com/JorisJonkers-dev/estate >/dev/null
fi
$KUBECTL -n flux-system get secret estate -o jsonpath='{.data.identity\.pub}' | base64 -d > "$WORK/estate.pub"
KEY_BODY=$(awk '{print $2}' "$WORK/estate.pub")
[[ -n "$KEY_BODY" ]] || die "Secret flux-system/estate holds no public key"
# The REST endpoint, not `gh repo deploy-key list`: its --json readOnly reads null.
deploy_keys() { gh api "repos/$ESTATE/keys" --paginate; }
if ! deploy_keys | jq -r '.[].key' | grep -qF "$KEY_BODY"; then
  gh repo deploy-key add "$WORK/estate.pub" --repo "$ESTATE" --title "$DEPLOY_KEY_TITLE" >/dev/null
fi
[[ "$(deploy_keys | jq -r --arg key "$KEY_BODY" '.[] | select(.key | contains($key)) | .read_only')" == "true" ]] \
  || die "no read-only deploy key on estate matches Secret flux-system/estate"
ok "the cluster's key is a read-only deploy key on estate"
# A key no longer in Secret flux-system/estate (regenerated, or a previous
# cluster's) still reads estate: offer to drop it.
for id in $(deploy_keys | jq -r --arg key "$KEY_BODY" --arg title "$DEPLOY_KEY_TITLE" \
  '.[] | select(.title == $title and (.key | contains($key) | not)) | .id'); do
  if confirm "Delete deploy key $id, which Secret flux-system/estate no longer holds?"; then
    gh repo deploy-key delete "$id" --repo "$ESTATE" >/dev/null
    ok "deleted deploy key $id"
  fi
done
pause

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "Flux: pull access to the render packages"
if $KUBECTL -n flux-system get secret render-pull >/dev/null 2>&1 \
  && ! confirm "Secret flux-system/render-pull exists. Replace its token?"; then
  ok "keeping Secret flux-system/render-pull"
else
  say "The render/* packages on ghcr.io are private, and fine-grained tokens cannot"
  say "read packages, so this is a classic token with read:packages only."
  warn "Nothing watches its expiry: put the date in your calendar."
  open_url "https://github.com/settings/tokens/new?scopes=read:packages&description=flux-system%20render-pull"
  step "Set an expiry, keep only read:packages, Generate, copy."
  ask_secret RENDER_PULL_TOKEN "Paste the token:"
  [[ "$(GH_TOKEN="$RENDER_PULL_TOKEN" gh api -i user 2>/dev/null | grep -i '^x-oauth-scopes:')" == *read:packages* ]] \
    || die "that token does not carry read:packages"
  GH_LOGIN=$(GH_TOKEN="$RENDER_PULL_TOKEN" gh api user --jq .login)
  confirm "Write Secret flux-system/render-pull?" || die "stopped"
  # Server-side apply: no last-applied-configuration annotation copies the token.
  RENDER_PULL_TOKEN="$RENDER_PULL_TOKEN" GH_LOGIN="$GH_LOGIN" jq -n '{
    apiVersion: "v1", kind: "Secret", type: "kubernetes.io/dockerconfigjson",
    metadata: { name: "render-pull", namespace: "flux-system" },
    stringData: { ".dockerconfigjson": ({ auths: { "ghcr.io": {
      username: env.GH_LOGIN, password: env.RENDER_PULL_TOKEN,
      auth: ("\(env.GH_LOGIN):\(env.RENDER_PULL_TOKEN)" | @base64) } } } | tojson) }
  }' | $KUBECTL apply --server-side --field-manager=estate-bootstrap -f - >/dev/null
  unset RENDER_PULL_TOKEN
fi
$KUBECTL -n flux-system get secret render-pull -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
  | jq -e '.auths["ghcr.io"].username' >/dev/null \
  || die "Secret flux-system/render-pull holds no ghcr.io credential"
ok "Secret flux-system/render-pull holds a ghcr.io credential"
pause

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "Vault: the Collector's key"
if check_collector_key; then
  ok "secret/$COLLECTOR_KV_PATH holds the Collector's id, installation id and key"
else
  say "Vault does not hold the Collector's key (a fresh Vault?). GitHub shows a key"
  say "only once, so generate a new one; the old one keeps working until deleted."
  open_url "https://github.com/organizations/$ORG/settings/apps/$(_existing ESTATE_COLLECTOR_APP_SLUG || echo jorisjonkers-dev-estate-collector)"
  step "Credentials → Key pairs → Generate a private key. Your browser downloads a .pem file."
  step "Paste its full path below (/Users/…, not ~/…)."
  ask COLLECTOR_PEM "Path of the downloaded .pem:"
  [[ -s "$COLLECTOR_PEM" ]] || die "no file at $COLLECTOR_PEM"
  store_collector_key "$COLLECTOR_PEM"
  if confirm "Delete $COLLECTOR_PEM now that Vault holds it?"; then rm -f "$COLLECTOR_PEM"; fi
  ok "secret/$COLLECTOR_KV_PATH restored"
  note "Delete the older key in the App's settings once the Collector has run."
fi
pause

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "Vault: the Reporter's key"
if check_reporter_key; then
  ok "secret/$REPORTER_KV_PATH holds the Reporter's id, installation id and key"
else
  say "Vault does not hold the Reporter's key (a fresh Vault?). GitHub shows a key"
  say "only once, so generate a new one; the old one keeps working until deleted."
  open_url "https://github.com/organizations/$ORG/settings/apps/$(_existing ESTATE_REPORTER_APP_SLUG || echo jorisjonkers-dev-estate-reporter)"
  step "Credentials → Key pairs → Generate a private key. Your browser downloads a .pem file."
  step "Paste its full path below (/Users/…, not ~/…)."
  ask REPORTER_PEM "Path of the downloaded .pem:"
  [[ -s "$REPORTER_PEM" ]] || die "no file at $REPORTER_PEM"
  store_reporter_key "$REPORTER_PEM"
  if confirm "Delete $REPORTER_PEM now that Vault holds it?"; then rm -f "$REPORTER_PEM"; fi
  ok "secret/$REPORTER_KV_PATH restored"
  note "Delete the older key in the App's settings once the Reporter has run."
fi
pause

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "Vault: the estate-dashboard's sign-in document"
say "auth-api reads secret/$AUTH_KV_PATH → $DASHBOARD_CLIENT_KV_KEY;"
say "the dashboard reads secret/$DASHBOARD_KV_PATH → $DASHBOARD_KV_KEY. They must be equal."
AUTH_COPY=$(vault_field "$AUTH_KV_PATH" "$DASHBOARD_CLIENT_KV_KEY")
DASHBOARD_COPY=$(vault_field "$DASHBOARD_KV_PATH" "$DASHBOARD_KV_KEY")
MINTED=false
if [[ -n "$AUTH_COPY" && "$AUTH_COPY" == "$DASHBOARD_COPY" ]]; then
  ok "both copies present and equal"
  CLIENT_SECRET=$AUTH_COPY
else
  if [[ -n "$AUTH_COPY" ]]; then
    CLIENT_SECRET=$AUTH_COPY
    ok "auth-api's copy exists; the dashboard's copy is missing or different and takes it"
  else
    CLIENT_SECRET=$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-48)
    [[ ${#CLIENT_SECRET} -eq 48 ]] || die "could not generate a 48-character secret"
    MINTED=true
    ok "no copy in Vault; generated a new 48-character secret"
  fi
  confirm "Write it to secret/$AUTH_KV_PATH and secret/$DASHBOARD_KV_PATH?" || die "stopped"
  printf '%s' "$CLIENT_SECRET" | vault_set "$AUTH_KV_PATH" "$DASHBOARD_CLIENT_KV_KEY"
  printf '%s' "$CLIENT_SECRET" | vault_set "$DASHBOARD_KV_PATH" "$DASHBOARD_KV_KEY"
  [[ "$(vault_field "$AUTH_KV_PATH" "$DASHBOARD_CLIENT_KV_KEY")" == "$CLIENT_SECRET" \
    && "$(vault_field "$DASHBOARD_KV_PATH" "$DASHBOARD_KV_KEY")" == "$CLIENT_SECRET" ]] \
    || die "the two Vault copies do not read back equal"
  ok "both Vault copies read back equal"
fi
# The session key seals the dashboard's cookie and the refresh tokens it stores. Kept where it
# exists: a new one signs every admin out and makes every stored token unreadable.
SESSION_HELD=$(vault_field "$DASHBOARD_KV_PATH" "$DASHBOARD_SESSION_KV_KEY")
if [[ ${#SESSION_HELD} -ge 32 ]]; then
  ok "secret/$DASHBOARD_KV_PATH holds a session key"
  unset SESSION_HELD
else
  SESSION_KEY=$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-48)
  [[ ${#SESSION_KEY} -eq 48 ]] || die "could not generate a 48-character session key"
  printf '%s' "$SESSION_KEY" | vault_set "$DASHBOARD_KV_PATH" "$DASHBOARD_SESSION_KV_KEY"
  [[ "$(vault_field "$DASHBOARD_KV_PATH" "$DASHBOARD_SESSION_KV_KEY")" == "$SESSION_KEY" ]] \
    || die "the session key does not read back"
  unset SESSION_KEY
  ok "secret/$DASHBOARD_KV_PATH holds a new 48-character session key"
fi
# The dashboard reads pins, the deploy log and open issues from the Estate repository, which is
# private. GitHub shows a token only once, so a fresh Vault needs a new one.
if [[ -n "$(vault_field "$DASHBOARD_KV_PATH" "$DASHBOARD_GITHUB_KV_KEY")" ]]; then
  ok "secret/$DASHBOARD_KV_PATH holds a GitHub token"
else
  say "The dashboard reads the Estate repository with a token that may read it and nothing else."
  open_url "https://github.com/settings/personal-access-tokens/new"
  step "Resource owner: $ORG. Repository access: Only select repositories, estate."
  step "Repository permissions: Contents, Issues and Metadata, read-only. Nothing else."
  step "Generate token, and copy it."
  ask_secret DASHBOARD_GITHUB_TOKEN "Paste the token (Enter skips; the dashboard then reads no estate):"
  if [[ -n "${DASHBOARD_GITHUB_TOKEN:-}" ]]; then
    printf '%s' "$DASHBOARD_GITHUB_TOKEN" | vault_set "$DASHBOARD_KV_PATH" "$DASHBOARD_GITHUB_KV_KEY"
    [[ -n "$(vault_field "$DASHBOARD_KV_PATH" "$DASHBOARD_GITHUB_KV_KEY")" ]] || die "the GitHub token does not read back"
    unset DASHBOARD_GITHUB_TOKEN
    ok "secret/$DASHBOARD_KV_PATH holds the GitHub token"
  else
    SKIPPED+=("the estate-dashboard's GitHub token: re-run cluster.sh to add it")
  fi
fi
pause

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "Prove auth accepts the estate-dashboard client"
# token_error SECRET prints the OAuth error the token endpoint answers a bogus
# code with: invalid_grant means the client and secret were accepted.
token_error() {
  printf 'user = "%s:%s"\n' "$DASHBOARD_CLIENT_ID" "$1" \
    | curl -sS --config - "$AUTH_HOST/api/oauth2/token" \
        --data-urlencode grant_type=authorization_code \
        --data-urlencode code=bootstrap-check \
        --data-urlencode "redirect_uri=$DASHBOARD_REDIRECT_URI" \
    | sed -n 's/.*"error" *: *"\([^"]*\)".*/\1/p' || true
}
if ! $KUBECTL -n "$AUTH_NS" get deploy auth-api >/dev/null 2>&1; then
  warn "auth-api is not deployed yet; re-run cluster.sh once it is"
  SKIPPED+=("prove the estate-dashboard client once auth-api runs: re-run cluster.sh")
else
  # auth-api reads its env file once, at start, so a new secret needs a restart.
  if [[ "$MINTED" == true ]] && confirm "Restart auth-api so it reads the new secret?"; then
    $KUBECTL -n "$AUTH_NS" rollout restart deploy/auth-api >/dev/null
    $KUBECTL -n "$AUTH_NS" rollout status deploy/auth-api --timeout=15m >/dev/null \
      || die "auth-api did not finish restarting"
    ok "auth-api restarted"
  fi
  WITH_REAL=$(token_error "$CLIENT_SECRET")
  WITH_WRONG=$(token_error "not-the-secret-$(openssl rand -hex 4)")
  say "with the Vault secret: ${WITH_REAL:-<no error field>}"
  say "with a wrong secret:   ${WITH_WRONG:-<no error field>}"
  [[ "$WITH_REAL" == "invalid_grant" ]] || die "auth did not accept estate-dashboard with the Vault secret"
  [[ "$WITH_WRONG" == "invalid_client" ]] || die "auth accepted a wrong secret"
  ok "estate-dashboard authenticates at $AUTH_HOST with the Vault secret, and only with it"
fi
pause

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "Postgres: the estate-dashboard's database"
# The dashboard reads its database URL from secret/$DASHBOARD_DB_KV_PATH until
# deploy-kit derives the credential from its edge to platform-postgres
# (JorisJonkers-dev/deploy-kit#378). Nothing on the estate path creates the
# database while `data` is legacy, so this does, on the Postgres the old path
# runs: the project's database, $DASHBOARD_DB_NAME, owned by a login of its own,
# since the dashboard applies its own migrations.
# pg_exec SCRIPT runs SCRIPT in the postgres container, with the superuser's
# login sourced the way the container's own command sources it. Stdin is passed.
pg_exec() {
  $KUBECTL -n "$PG_NS" exec -i deploy/postgres -c postgres -- sh -c \
    ". /vault/secrets/postgres.env && $1"
}
# pg_login PASSWORD prints the user the dashboard's login connects to its
# database as, the password read on stdin so it never sits in an argument. It
# connects to the pod's own address, as the dashboard's connections arrive:
# Postgres trusts loopback, so a check over it would pass any password.
pg_login() {
  printf '%s\n' "$1" | pg_exec "IFS= read -r PGPASSWORD && export PGPASSWORD && \
    psql -h \"\$(hostname -i | cut -d' ' -f1)\" -U '$DASHBOARD_DB_ROLE' -d '$DASHBOARD_DB_NAME' \
      -tAc 'select current_user'" 2>/dev/null || true
}
if ! $KUBECTL -n "$PG_NS" get deploy postgres >/dev/null 2>&1; then
  warn "the old path runs no Postgres in $PG_NS; re-run cluster.sh once it does"
  SKIPPED+=("the estate-dashboard's database: re-run cluster.sh once Postgres runs")
else
  DB_URL=$(vault_field "$DASHBOARD_DB_KV_PATH" "$DASHBOARD_DB_KV_KEY")
  DB_PASSWORD=""
  if [[ "$DB_URL" =~ ^postgres://[^:]+:([^@]+)@ ]]; then
    DB_PASSWORD="${BASH_REMATCH[1]}"
  fi
  if [[ -n "$DB_PASSWORD" && "$(pg_login "$DB_PASSWORD")" == "$DASHBOARD_DB_ROLE" ]]; then
    ok "secret/$DASHBOARD_DB_KV_PATH holds a URL that signs in to $DASHBOARD_DB_NAME"
  else
    say "Creating $DASHBOARD_DB_NAME and its login $DASHBOARD_DB_ROLE on $PG_NS/postgres,"
    say "or setting a new password where the login exists, and writing the URL to Vault."
    confirm "Create or reset them?" || die "stopped"
    DB_PASSWORD=$(openssl rand -hex 24)
    # The password reaches psql on stdin and through its environment, never as an argument.
    printf '%s\n' "$DB_PASSWORD" | pg_exec "IFS= read -r DB_PASSWORD && export DB_PASSWORD && \
      psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d postgres -q -f - <<'SQL'
\\getenv pw DB_PASSWORD
SELECT format('CREATE ROLE %I LOGIN', '$DASHBOARD_DB_ROLE')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DASHBOARD_DB_ROLE') \\gexec
ALTER ROLE \"$DASHBOARD_DB_ROLE\" WITH LOGIN PASSWORD :'pw';
SELECT format('CREATE DATABASE %I OWNER %I', '$DASHBOARD_DB_NAME', '$DASHBOARD_DB_ROLE')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DASHBOARD_DB_NAME') \\gexec
ALTER DATABASE \"$DASHBOARD_DB_NAME\" OWNER TO \"$DASHBOARD_DB_ROLE\";
SQL" >/dev/null || die "Postgres refused the database or its login"
    [[ "$(pg_login "$DB_PASSWORD")" == "$DASHBOARD_DB_ROLE" ]] \
      || die "$DASHBOARD_DB_ROLE cannot sign in to $DASHBOARD_DB_NAME"
    DB_URL="postgres://$DASHBOARD_DB_ROLE:$DB_PASSWORD@$PG_HOST:5432/$DASHBOARD_DB_NAME?sslmode=disable"
    printf '%s' "$DB_URL" | vault_set "$DASHBOARD_DB_KV_PATH" "$DASHBOARD_DB_KV_KEY"
    [[ "$(vault_field "$DASHBOARD_DB_KV_PATH" "$DASHBOARD_DB_KV_KEY")" == "$DB_URL" ]] \
      || die "the database URL does not read back"
    ok "$DASHBOARD_DB_ROLE signs in to $DASHBOARD_DB_NAME, and secret/$DASHBOARD_DB_KV_PATH holds its URL"
  fi
  unset DB_URL DB_PASSWORD
fi
pause

# ── 9 ─────────────────────────────────────────────────────────────────────
stage "Vault: the role the policy job logs in as"
# The job writes every rendered policy and Kubernetes auth role, so its own
# role is the one thing it cannot create: it exists before the first render.
#
# What it may write is everything a render can hold, so a compromised job is
# a compromised Vault; what is denied below is what a render never needs, so
# it cannot quietly keep that access: changing its own policy or role, the
# built-in policies, or minting a role that hands out policy-admin or root.
vault_exec policy write "$POLICY_ROLE" - >/dev/null <<'HCL'
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "auth/kubernetes/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
  denied_parameters = {
    "token_policies" = ["policy-admin", "root"]
    "policies"       = ["policy-admin", "root"]
  }
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
vault_exec write "auth/kubernetes/role/$POLICY_ROLE" \
  bound_service_account_names="$POLICY_SA" \
  bound_service_account_namespaces="$POLICY_NS" \
  token_policies="$POLICY_ROLE" \
  token_ttl=10m </dev/null >/dev/null
[[ "$(vault_exec read -field=token_policies "auth/kubernetes/role/$POLICY_ROLE" </dev/null)" == *"$POLICY_ROLE"* ]] \
  || die "auth/kubernetes/role/$POLICY_ROLE does not read back with its policy"
ok "role $POLICY_ROLE binds $POLICY_NS/$POLICY_SA to policy $POLICY_ROLE"
pause

# ── 10 ────────────────────────────────────────────────────────────────────
stage "The bootstrap set: Flagger's CRDs"
# platform.intent.yml lists flagger.app/v1beta1 in the bootstrap set: the
# render holds Flagger's Deployment, never its CRDs, and Flagger exits at start
# while canaries.flagger.app is not registered. Pinned to the release the
# delivery Project's Flagger image is, by the file's own digest.
curl -fsSL "$FLAGGER_CRDS_URL" -o "$WORK/flagger-crds.yaml" \
  || die "could not download $FLAGGER_CRDS_URL"
[[ "$(shasum -a 256 "$WORK/flagger-crds.yaml" | cut -d' ' -f1)" == "$FLAGGER_CRDS_SHA256" ]] \
  || die "$FLAGGER_CRDS_URL does not hash to $FLAGGER_CRDS_SHA256"
$KUBECTL apply --server-side --field-manager=estate-bootstrap -f "$WORK/flagger-crds.yaml" >/dev/null \
  || die "Flagger's CRDs did not apply"
$KUBECTL wait --for=condition=Established --timeout=60s \
  crd/canaries.flagger.app crd/metrictemplates.flagger.app crd/alertproviders.flagger.app >/dev/null \
  || die "Flagger's CRDs are not established"
ok "Flagger $FLAGGER_VERSION's CRDs are established"
pause

# ── 11 ────────────────────────────────────────────────────────────────────
stage "Prove Flux reads the estate repository"
if ! $KUBECTL -n flux-system get gitrepository platform >/dev/null 2>&1; then
  warn "GitRepository flux-system/platform is not applied yet (fleet-infra's estate.yaml)"
  SKIPPED+=("prove Flux reads estate once flux-system/platform exists: re-run cluster.sh")
else
  flux reconcile source git platform -n flux-system >/dev/null \
    || die "flux-system/platform did not reconcile: flux get sources git platform -n flux-system"
  ESTATE_HEAD=$(gh api "repos/$ESTATE/commits/main" --jq .sha)
  FETCHED=$($KUBECTL -n flux-system get gitrepository platform -o jsonpath='{.status.artifact.revision}')
  [[ "$FETCHED" == *"$ESTATE_HEAD" ]] || die "Flux fetched $FETCHED, but estate main is $ESTATE_HEAD"
  ok "flux-system/platform fetched estate main at ${ESTATE_HEAD:0:12}"
  flux reconcile kustomization estate-pins -n flux-system >/dev/null \
    || die "estate-pins did not apply: flux get kustomizations estate-pins -n flux-system"
  ok "estate-pins applied"
fi
pause

finish
