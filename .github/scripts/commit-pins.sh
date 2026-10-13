#!/usr/bin/env bash
# commit-pins.sh <moved> <composed>: one local commit holding every pin source
# a composition changes (deploy-kit spec/v1/55-delivery.md#what-a-pin-source-holds).
#
# <moved> lists one published artifact a line, as `<project> <digest>
# <repository>`; <composed> is the `projects` directory composition wrote.
# Composition writes a source there in two cases, and this commits both:
#
# - The pin moves. The source replaces the committed one, naming the digest
#   the artifact was published at. This is the deploy.
# - The pin stays, and the committed source no longer says what composition
#   derives: the Platform document's repository, signer or pull Secret
#   changed, or a unit it follows joined the estate path. The source replaces
#   the committed one at the digest that one names, so it deploys nothing. One
#   that differs from the committed source only in how it is written is left.
#
# Commits nothing where composition wrote nothing. Never pushes: the caller
# does, with the Collector App's token, and only when `committed=true`.
set -euo pipefail
shopt -s nullglob

moved="${1:-}"
composed="${2:-}"
[ -f "$moved" ] && [ -n "$composed" ] || {
  echo "::error::usage: commit-pins.sh <moved> <composed>"
  exit 2
}

digest_of() { yq 'select(.kind == "OCIRepository") | .spec.ref.digest' "$1"; }
# Whether two sources hold the same objects, however each is written.
same() { cmp -s <(yq -o=json -I=0 '.' "$1") <(yq -o=json -I=0 '.' "$2"); }

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
  # Composition compares the text, and a Pause writes its time quoted where
  # composition writes it bare: a source that says what the committed one says
  # is not a change, and committing it would follow every Pause with a commit
  # that changes nothing. Composition's own to decide; held here until it does
  # (JorisJonkers-dev/deploy-kit#412).
  same "$source" "$committed" && continue
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
  # The deploy: one commit moves every Project whose artifact changed.
  subject="chore(deploy): $(cut -d' ' -f1 "$moved" | paste -sd, -) [ci skip]"
  if [ -n "$rewritten" ]; then
    git commit --quiet -m "$subject" -m "Pin sources rewritten at the digest they name: ${rewritten}"
  else
    git commit --quiet -m "$subject"
  fi
else
  git commit --quiet -m "chore(deploy): rewrite the pin source of ${rewritten} [ci skip]"
fi
git log -1 --format='%h %s'
echo "committed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
