#!/usr/bin/env bash
# commit-pins.sh <moved> <composed> [<composition>]: one local commit holding
# every pin source a composition changes
# (deploy-kit spec/v1/55-delivery.md#what-a-pin-source-holds).
#
# <moved> lists one published artifact a line, as `<project> <digest>
# <repository>`; <composed> is the `projects` directory composition wrote;
# <composition> is the composition.json it wrote beside it, whose Rollouts name
# the release each moved pin delivers, so the commit, the estate's deploy log,
# says which version reached production.
# Composition writes a source there in two cases, and this commits both:
#
# - The pin moves. The source replaces the committed one, naming the digest
#   the artifact was published at. This is the deploy.
# - The pin stays, and the committed source no longer says what composition
#   derives: the Platform document's repository, signer or pull Secret
#   changed, or a unit it follows joined the estate path. The source replaces
#   the committed one at the digest that one names, so it deploys nothing.
#
# Commits nothing where composition wrote nothing. Never pushes: the caller
# does, with the Collector App's token, and only when `committed=true`.
set -euo pipefail
shopt -s nullglob

moved="${1:-}"
composed="${2:-}"
composition="${3:-}"
[ -f "$moved" ] && [ -n "$composed" ] || {
  echo "::error::usage: commit-pins.sh <moved> <composed> [<composition>]"
  exit 2
}

# rollout <project>: `<version> <repository> <sha>` of the release a moved pin
# delivers, or nothing. Each value comes from a fragment, so it is held to the
# shape it must have before it reaches the commit or a log line.
rollout() {
  [ -f "$composition" ] || return 0
  local version repository sha
  read -r version repository sha < <(jq -r --arg p "$1" \
    'first(.rollouts[] | select(.project == $p)) | "\(.version) \(.repository) \(.sha)"' "$composition") || return 0
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$repository" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ && "$sha" =~ ^[0-9a-f]{40}$ ]] \
    && echo "${version} ${repository} ${sha}"
  return 0
}

digest_of() { yq 'select(.kind == "OCIRepository") | .spec.ref.digest' "$1"; }

while read -r project digest _repository; do
  mkdir -p "projects/${project}"
  cp "${composed}/${project}/source.yaml" "projects/${project}/source.yaml"
  DIGEST="$digest" yq -i '(select(.kind == "OCIRepository") | .spec.ref.digest) = strenv(DIGEST)' \
    "projects/${project}/source.yaml"
done < "$moved"

rewritten=""
for source in "${composed}"/*/source.yaml; do
  project="$(basename "$(dirname "$source")")"
  awk -v project="$project" '$1 == project { found = 1 } END { exit !found }' "$moved" && continue
  committed="projects/${project}/source.yaml"
  # A source whose pin stays is only ever a rewrite of a committed one, at
  # that one's digest. Anything else would move a pin to an artifact this run
  # did not publish, so it is refused rather than committed.
  named=""
  [ -f "$committed" ] && named="$(digest_of "$committed")"
  [[ "$named" == sha256:* && "$(digest_of "$source")" == "$named" ]] || {
    echo "::error::${project}: composition wrote a pin source that moves a pin it did not publish"
    exit 1
  }
  cp "$source" "$committed"
  rewritten="${rewritten:+${rewritten},}${project}"
done

git add projects
if git diff --cached --quiet; then
  echo "no pin moved and no pin source changed; nothing to commit"
  echo "committed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

git config user.name "estate-composition"
git config user.email "estate-composition@users.noreply.github.com"
if [ -s "$moved" ]; then
  # The deploy: one commit moves every Project whose artifact changed, and
  # names the release each one now runs in production.
  names=""
  details=""
  while read -r project digest _repository; do
    read -r version repository sha <<<"$(rollout "$project")" || true
    names="${names:+${names}, }${project}${version:+ ${version}}"
    if [ -n "${version:-}" ]; then
      details="${details}${project} ${version}, released from ${repository}@${sha:0:12}, at ${digest}"$'\n'
    else
      details="${details}${project}, at ${digest}"$'\n'
    fi
  done < "$moved"
  body="Delivered to production:"$'\n\n'"${details}"
  [ -n "$rewritten" ] && body="${body}"$'\n'"Pin sources rewritten at the digest they name: ${rewritten}"
  git commit --quiet -m "chore(deploy): ${names} [ci skip]" -m "$body"
else
  git commit --quiet -m "chore(deploy): rewrite the pin source of ${rewritten} [ci skip]"
fi
git log -1 --format='%h %s'
echo "committed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
