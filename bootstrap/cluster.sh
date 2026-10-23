#!/usr/bin/env bash
#
# Everything a cluster needs, outside git and outside Vault, before the estate
# path can deliver to it: run once per cluster, after Flux is installed and
# Vault is unsealed (fleet-infra cluster/bootstrap/flux-bootstrap-playbook.md,
# and its Vault unseal and restore playbooks), and again after any move.
#
#   Flux       Secret flux-system/estate, an SSH key pair generated in the
#              cluster whose public half is a read-only deploy key on estate,
#              and Secret flux-system/render-pull, the ghcr.io credential every
#              pin names.
#   Flagger    the CRDs of the bootstrap set that no render holds.
#
# Vault is secrets.sh's, which runs first: the Collector's and the Reporter's
# App keys, the estate-dashboard's sign-in document, and the role the Vault
# policy job logs in as all live there. The GitHub Apps themselves are
# github-apps.sh's, once per organization. Safe to re-run: each stage checks
# what exists before it writes, and reads back what it wrote.

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/wizard.sh
source "$here/lib/wizard.sh"
# shellcheck source=lib/estate.sh
source "$here/lib/estate.sh"

TOTAL_STAGES=5

DEPLOY_KEY_TITLE="flux-system/estate (read-only)"
# The CRDs of the bootstrap set that no render holds (platform.intent.yml
# bootstrap.crds): Flagger's, at the release its image in the delivery Project is.
FLAGGER_VERSION=v1.45.0
FLAGGER_CRDS_URL="https://raw.githubusercontent.com/fluxcd/flagger/$FLAGGER_VERSION/artifacts/flagger/crd.yaml"
FLAGGER_CRDS_SHA256=58bd594b9e33deb0edceac81f6ed160b458a7933039fb295552724f656033ee5

WORK=$(umask 077 && mktemp -d)
trap estate_cleanup EXIT

banner "Estate: one cluster's credentials"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "Preflight: tools, cluster and GitHub"
require_tools "$KUBECTL" flux gh jq curl shasum
require_cluster
$KUBECTL get crd ocirepositories.source.toolkit.fluxcd.io >/dev/null 2>&1 \
  || die "Flux is not installed; run fleet-infra's flux-bootstrap-playbook first"
ok "Flux is installed"
gh auth status >/dev/null 2>&1 || die "gh is not signed in: run 'gh auth login'"
ok "gh signed in"
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

# ── 5 ─────────────────────────────────────────────────────────────────────
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
note "Vault's part is secrets.sh's: run ./bootstrap/secrets.sh if it has not run on this cluster."
