#!/usr/bin/env bash
#
# The estate's two GitHub Apps, once per organization (deploy-kit
# spec/v1/60-setup.md#the-estate-repository). They live on GitHub, not in the
# cluster, so moving the cluster does not repeat this; cluster.sh restores the
# one key that lives in Vault.
#
#   dispatch   actions write, contents read, statuses write, installed on every
#              repository so any one can publish. Its key and id are an org secret
#              and an org variable that every repository's workflows read.
#   Collector  contents write, on estate only. Its key is in Vault, and in
#              estate's `compose` environment for composition's pin commit.
#
# Safe to re-run: a stage whose result exists is checked, not redone. The App
# ids it saves are not secret; it never writes a key to disk outside a 0600
# temporary file it removes.

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/wizard.sh
source "$here/lib/wizard.sh"
# shellcheck source=lib/estate.sh
source "$here/lib/estate.sh"

TOTAL_STAGES=7

WORK=$(umask 077 && mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# manifest_form NAME PERMISSIONS_JSON writes a page that posts a GitHub App
# manifest to the org's "new App" form, and prints its path.
manifest_form() {
  local name="$1" permissions="$2" file="$WORK/$1.html" manifest
  manifest=$(jq -nc --arg name "$name" --argjson perms "$permissions" '{
    name: $name,
    url: "https://github.com/JorisJonkers-dev/estate",
    redirect_url: "https://github.com/JorisJonkers-dev/estate",
    hook_attributes: { url: "https://github.com/JorisJonkers-dev/estate", active: false },
    public: false,
    default_permissions: $perms,
    default_events: []
  }')
  cat > "$file" <<HTML
<!doctype html><meta charset="utf-8"><title>Create $name</title>
<form id="f" method="post" action="https://github.com/organizations/$ORG/settings/apps/new">
<input type="hidden" name="manifest" value='$manifest'>
<p>Creating GitHub App <b>$name</b>. If nothing happens, press the button.</p>
<button type="submit">Create on GitHub</button></form>
<script>document.getElementById('f').submit()</script>
HTML
  printf '%s' "$file"
}

# create_app PREFIX NAME PERMISSIONS_JSON PEM_FILE walks the manifest flow,
# saves PREFIX_APP_ID and PREFIX_APP_SLUG, and writes the key to PEM_FILE.
# App names are unique on GitHub, so callers check the saved id first.
create_app() {
  local prefix="$1" name="$2" permissions="$3" pem="$4" form code response
  form=$(manifest_form "$name" "$permissions")
  open_url "file://$form"
  step "GitHub shows the App to be created. Click 'Create GitHub App for $ORG'."
  step "You land on the estate repository. Copy the 'code' value from the address bar"
  step "(…/estate?code=THIS_PART). It is single-use and expires in an hour."
  ask code "Paste the code:"
  response=$(gh api -X POST "app-manifests/$code/conversions") \
    || die "GitHub refused the code; re-run to start over"
  jq -r '.pem' <<<"$response" > "$pem"
  write_env "${prefix}_APP_ID" "$(jq -r '.id' <<<"$response")"
  write_env "${prefix}_APP_SLUG" "$(jq -r '.slug' <<<"$response")"
}

# require_selected PREFIX stops unless the App's installation is limited to
# selected repositories: the Collector can write contents, so on every
# repository it would reach far more than the estate. GitHub shows which repositories only to the App itself, so the list
# is the human's to confirm; "all" is what can be checked, and is refused.
require_selected() {
  local app_id selection
  app_id=$(_existing "$1_APP_ID")
  selection=$(gh api "orgs/$ORG/installations" --paginate \
    --jq ".installations[] | select(.app_id == $app_id) | .repository_selection")
  [[ -n "$selection" ]] || die "$(_existing "$1_APP_SLUG") is not installed on $ORG"
  [[ "$selection" == "selected" ]] \
    || die "$(_existing "$1_APP_SLUG") is installed on all repositories. Open
    https://github.com/organizations/$ORG/settings/installations, Configure it,
    choose 'Only select repositories', and re-run"
  ok "$(_existing "$1_APP_SLUG") is limited to selected repositories"
}

banner "Estate: the dispatch and Collector GitHub Apps"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "Preflight: tools, organization scope and Vault"
require_tools gh jq "$KUBECTL"
if gh auth status 2>&1 | grep -q "admin:org"; then
  ok "gh carries admin:org"
else
  say "Org secrets and variables need the admin:org scope."
  pause "Press Enter to run: gh auth refresh -h github.com -s admin:org"
  gh auth refresh -h github.com -s admin:org
  gh auth status 2>&1 | grep -q "admin:org" || die "admin:org still missing"
  ok "admin:org granted"
fi
say "The Collector's key goes to Vault, so Vault is checked before it exists."
require_cluster
require_vault_token
pause

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "Create the dispatch App"
say "Lets an application repository start composition, and composition report a"
say "commit status back. It cannot push."
if [[ -n "$(_existing ESTATE_DISPATCH_APP_ID || true)" ]]; then
  ok "already created: $(_existing ESTATE_DISPATCH_APP_SLUG) ($(_existing ESTATE_DISPATCH_APP_ID))"
else
  create_app ESTATE_DISPATCH "jorisjonkers-dev-estate-dispatch" \
    '{"actions":"write","contents":"read","statuses":"write","metadata":"read"}' "$WORK/dispatch.pem"
  gh secret set ESTATE_DISPATCH_APP_PRIVATE_KEY --org "$ORG" --visibility all \
    < "$WORK/dispatch.pem" >/dev/null
  rm -f "$WORK/dispatch.pem"
fi
DISPATCH_ID=$(_existing ESTATE_DISPATCH_APP_ID)
gh variable set ESTATE_DISPATCH_APP_ID --org "$ORG" --visibility all \
  --body "$DISPATCH_ID" >/dev/null
[[ "$(gh variable get ESTATE_DISPATCH_APP_ID --org "$ORG")" == "$DISPATCH_ID" ]] \
  || die "org variable ESTATE_DISPATCH_APP_ID does not read back"
ok "org variable ESTATE_DISPATCH_APP_ID reads $DISPATCH_ID"
gh secret list --org "$ORG" --json name --jq '.[].name' | grep -qx ESTATE_DISPATCH_APP_PRIVATE_KEY \
  || die "org secret missing: generate a private key in the App's settings, then
    gh secret set ESTATE_DISPATCH_APP_PRIVATE_KEY --org $ORG --visibility all < key.pem"
ok "org secret ESTATE_DISPATCH_APP_PRIVATE_KEY exists"
pause

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "Install the dispatch App"
open_url "https://github.com/apps/$(_existing ESTATE_DISPATCH_APP_SLUG)/installations/new"
step "Choose $ORG (or Configure, if it is installed already)."
step "All repositories: any repository may come to publish a fragment."
step "Install or Save."
gh api "orgs/$ORG/installations" --paginate \
  --jq ".installations[] | select(.app_id == $DISPATCH_ID) | .id" | grep -q . \
  || die "$(_existing ESTATE_DISPATCH_APP_SLUG) is not installed on $ORG; install it, then re-run"
ok "$(_existing ESTATE_DISPATCH_APP_SLUG) is installed on $ORG"
pause

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "Create the Collector App"
say "Commits cluster-state.yml to estate. Its key goes to Vault, never to GitHub."
if [[ -n "$(_existing ESTATE_COLLECTOR_APP_ID || true)" ]]; then
  ok "already created: $(_existing ESTATE_COLLECTOR_APP_SLUG) ($(_existing ESTATE_COLLECTOR_APP_ID))"
else
  create_app ESTATE_COLLECTOR "jorisjonkers-dev-estate-collector" \
    '{"contents":"write","metadata":"read"}' "$WORK/collector.pem"
fi
pause

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "Install the Collector App"
open_url "https://github.com/apps/$(_existing ESTATE_COLLECTOR_APP_SLUG)/installations/new"
step "Choose $ORG, Only select repositories, estate only, Install."
step "You land on …/settings/installations/NUMBER. Copy that NUMBER."
ask ESTATE_COLLECTOR_INSTALLATION_ID "Paste the installation id:"
[[ "$ESTATE_COLLECTOR_INSTALLATION_ID" =~ ^[0-9]+$ ]] || die "an installation id is a number"
write_env ESTATE_COLLECTOR_INSTALLATION_ID "$ESTATE_COLLECTOR_INSTALLATION_ID"
confirm "Is estate the only repository the Collector App is installed on?" || die "narrow it, then re-run"
require_selected ESTATE_COLLECTOR
pause

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "Store the Collector's key in Vault"
if [[ -s "$WORK/collector.pem" ]]; then
  store_collector_key "$WORK/collector.pem"
elif check_collector_key; then
  :
else
  say "Vault does not hold the Collector's key, and GitHub shows a key only once."
  open_url "https://github.com/organizations/$ORG/settings/apps/$(_existing ESTATE_COLLECTOR_APP_SLUG)"
  step "Private keys → Generate a private key. Your browser downloads a .pem file."
  ask COLLECTOR_PEM "Path of the downloaded .pem:"
  [[ -s "$COLLECTOR_PEM" ]] || die "no file at $COLLECTOR_PEM"
  store_collector_key "$COLLECTOR_PEM"
  if confirm "Delete $COLLECTOR_PEM now that Vault holds it?"; then rm -f "$COLLECTOR_PEM"; fi
fi
ok "secret/$COLLECTOR_KV_PATH holds the Collector's id, installation id and key"
pause

# ── 7 ─────────────────────────────────────────────────────────────────────
# Composition commits the moved pins as the Collector, the one App that
# bypasses main's ruleset with contents: write (deploy-kit
# spec/v1/60-setup.md#the-estate-repository). Its key goes to the `compose`
# environment of this repository alone, which only main deploys to: no other
# repository, and no workflow run from another branch, can read it.
stage "Give composition the Collector's key"
gh api -X PUT "repos/$ORG/estate/environments/compose" \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true' >/dev/null ||
  die "could not create the compose environment on $ORG/estate"
if ! gh api "repos/$ORG/estate/environments/compose/deployment-branch-policies" \
  --jq '.branch_policies[].name' | grep -qx main; then
  gh api -X POST "repos/$ORG/estate/environments/compose/deployment-branch-policies" \
    -f name=main -f type=branch >/dev/null || die "could not limit the compose environment to main"
fi
ok "the compose environment deploys from main alone"
if gh secret list --repo "$ORG/estate" --env compose --json name --jq '.[].name' | grep -qx ESTATE_COLLECTOR_APP_PRIVATE_KEY; then
  ok "estate already holds ESTATE_COLLECTOR_APP_PRIVATE_KEY"
else
  # From Vault into the secret through memory alone: the key never touches the
  # disk, and a read that failed never sets an empty secret.
  key="$(vault_exec kv get -mount=secret -field=private-key "$COLLECTOR_KV_PATH")" ||
    die "could not read secret/$COLLECTOR_KV_PATH"
  [[ "$key" == *"PRIVATE KEY"* ]] || die "secret/$COLLECTOR_KV_PATH holds no private key"
  printf '%s\n' "$key" | gh secret set ESTATE_COLLECTOR_APP_PRIVATE_KEY --repo "$ORG/estate" --env compose >/dev/null ||
    die "could not set ESTATE_COLLECTOR_APP_PRIVATE_KEY on $ORG/estate"
  unset key
  ok "estate holds ESTATE_COLLECTOR_APP_PRIVATE_KEY"
fi
gh variable set ESTATE_COLLECTOR_APP_ID --repo "$ORG/estate" --body "$(_existing ESTATE_COLLECTOR_APP_ID)" >/dev/null ||
  die "could not set ESTATE_COLLECTOR_APP_ID on $ORG/estate"
ok "estate's ESTATE_COLLECTOR_APP_ID is $(_existing ESTATE_COLLECTOR_APP_ID)"
pause

finish
note "App ids, for the ruleset's bypass actors (also in $ENV_FILE):"
note "  dispatch   $(_existing ESTATE_DISPATCH_APP_ID)"
note "  Collector  $(_existing ESTATE_COLLECTOR_APP_ID)"
