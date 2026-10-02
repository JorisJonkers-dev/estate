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
#   Vault      the Collector App's key, and the estate-dashboard's OIDC client
#              secret in both the copy auth-api reads and the dashboard's own.
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

TOTAL_STAGES=7

AUTH_NS=auth-system
AUTH_HOST=${AUTH_HOST:-https://auth.jorisjonkers.dev}
DASHBOARD_CLIENT_ID=estate-dashboard
DASHBOARD_REDIRECT_URI=https://estate.jorisjonkers.dev/auth/callback
DEPLOY_KEY_TITLE="flux-system/estate (read-only)"

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
for key in ESTATE_COLLECTOR_APP_ID ESTATE_COLLECTOR_INSTALLATION_ID; do
  if [[ -z "$(_existing "$key" || true)" ]]; then
    note "$ENV_FILE has no $key (a new machine?). The App's settings page shows it."
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
if ! gh repo deploy-key list --repo "$ESTATE" --json key --jq '.[].key' | grep -qF "$KEY_BODY"; then
  gh repo deploy-key add "$WORK/estate.pub" --repo "$ESTATE" --title "$DEPLOY_KEY_TITLE" >/dev/null
fi
[[ "$(gh repo deploy-key list --repo "$ESTATE" --json key,readOnly \
  --jq ".[] | select(.key | contains(\"$KEY_BODY\")) | .readOnly")" == "true" ]] \
  || die "no read-only deploy key on estate matches Secret flux-system/estate"
ok "the cluster's key is a read-only deploy key on estate"
# A key a previous cluster left behind still reads estate: offer to drop it.
for id in $(gh repo deploy-key list --repo "$ESTATE" --json id,key,title \
  --jq ".[] | select(.title == \"$DEPLOY_KEY_TITLE\" and (.key | contains(\"$KEY_BODY\") | not)) | .id"); do
  if confirm "Delete deploy key $id, left by an earlier cluster?"; then
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
  step "Private keys → Generate a private key. Your browser downloads a .pem file."
  ask COLLECTOR_PEM "Path of the downloaded .pem:"
  [[ -s "$COLLECTOR_PEM" ]] || die "no file at $COLLECTOR_PEM"
  store_collector_key "$COLLECTOR_PEM"
  if confirm "Delete $COLLECTOR_PEM now that Vault holds it?"; then rm -f "$COLLECTOR_PEM"; fi
  ok "secret/$COLLECTOR_KV_PATH restored"
  note "Delete the older key in the App's settings once the Collector has run."
fi
pause

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "Vault: the estate-dashboard's OIDC client secret"
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
pause

# ── 6 ─────────────────────────────────────────────────────────────────────
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

# ── 7 ─────────────────────────────────────────────────────────────────────
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
