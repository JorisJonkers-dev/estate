#!/usr/bin/env bash
# replay.sh <work-dir>: render every pinned Project again from the inputs its
# Rendered artifact names, and compare the render with the artifact byte for
# byte (deploy-kit spec/v1/55-delivery.md#rendered-artifacts-and-pins: an
# artifact "names the inputs that reproduce it").
#
# Read-only: it pulls from the registry and reads this repository's history,
# and it pushes, signs, tags and commits nothing.
#
# For each projects/<project>/source.yaml on the checked-out commit, the
# artifact its pin names carries `dev.jorisjonkers.lock-digest`, the composed
# artifact that holds the lock of the composition that rendered it, and that
# holds COMMIT, the estate commit that composition ran at. Each lock is
# replayed once, as compose.yml composed, from:
#   - every fragment the lock records, by digest, with the push time the
#     registry recorded for it, the Platform document's among them;
#   - participants.yml, cluster-state.yml and the pin sources at COMMIT, and
#     the pins compose.yml built from those sources;
#   - the toolkit release the lock records, `spec.toolkitVersion`, not the
#     one toolkit.yml names now: a pin a later composition left in place
#     still names a render an earlier release made, and a replay "runs the
#     recorded toolkit version" (deploy-kit
#     spec/v1/40-composition.md#the-composition-lock);
#   - the clock stopped at the lock's `metadata.generatedAt` (compose-at.mjs);
#   - the lock itself as the previous lock, so every Project composes at the
#     fragment the lock records and none of them counts as changed.
# Then, per pin, the artifact is pulled and compared with the replay's share
# for its Project (compare-render.sh), and the content and render hashes the
# artifact is annotated with are held to the replay's.
#
# Writes a Markdown summary to <work-dir>/summary.md and exits 1 when any
# Project does not reproduce. Reads OWNER, COMPOSED and PLATFORM_PROJECT, and
# expects `oras`, `jq`, `yq`, `node` and `npm` (with the toolkit's registry
# configured) on the path. Run from the repository root.
set -euo pipefail

work="${1:?usage: replay.sh <work-dir>}"
: "${OWNER:?}" "${COMPOSED:?}" "${PLATFORM_PROJECT:?}"
scripts="$(cd "$(dirname "$0")" && pwd)"
repository="$(pwd)"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
zero="sha256:$(printf '0%.0s' $(seq 64))"
fragment_ref="^ghcr\.io/${OWNER}/intent-[a-z0-9.-]+@sha256:[0-9a-f]{64}$"

die() { echo "::error::$1" >&2; exit 1; }

# toolkit <version>: install that deploy-kit release once, and print where.
toolkit() {
  local dir="${work}/toolkits/$1"
  if [ ! -d "${dir}/node_modules/@jorisjonkers-dev/deploy-kit" ]; then
    mkdir -p "$dir"
    npm install --prefix "$dir" --no-save --ignore-scripts --no-audit --no-fund \
      "@jorisjonkers-dev/deploy-kit@$1" > /dev/null
    [ "$(node -p "require('${dir}/node_modules/@jorisjonkers-dev/deploy-kit/package.json').version")" = "$1" ] \
      || die "npm installed another release than deploy-kit $1"
  fi
  printf '%s' "$dir"
}

# fragment <ref> <directory> [published]: pull a fragment by digest and record
# its reference, and its push time where asked, as compose.yml's pull does.
fragment() {
  # Checked before it is ever printed, as compose.yml does: a value a lock
  # holds never reaches a log line, where it could read as a workflow command.
  [[ "$1" =~ $fragment_ref ]] || die "a lock names a fragment that is not one of ${OWNER} by digest"
  oras pull "$1" --output "$2" > /dev/null || die "could not pull $1"
  echo "$1" > "$2/ref"
  if [ "${3:-}" = published ]; then
    oras manifest fetch "$1" | jq -er '.annotations["org.opencontainers.image.created"]' > "$2/published" \
      || die "$1 records no push time"
  fi
}

# pins <estate-dir> <out>: the pins.json compose.yml builds from the pin
# sources it composes with: each artifact's content hash, the estate
# annotations on its source, and the release its unit's index labels pods with.
pins() {
  local source project digest url content annotations pinned labelled
  echo '{}' > "$2"
  for source in "$1"/projects/*/source.yaml; do
    project="$(basename "$(dirname "$source")")"
    [ "$project" = "_canary" ] && continue
    digest="$(yq 'select(.kind == "OCIRepository") | .spec.ref.digest' "$source")"
    [ "$digest" = "$zero" ] && continue
    url="$(yq 'select(.kind == "OCIRepository") | .spec.url' "$source")"
    content="$(oras manifest fetch "${url#oci://}@${digest}" \
      | jq -er '.annotations["dev.jorisjonkers.content-hash"]')" \
      || die "the artifact ${project} pinned at its replayed commit carries no content hash"
    annotations="$(yq -o=json 'select(.kind == "OCIRepository") | .metadata.annotations // {} | with_entries(select(.key | test("^estate\\.jorisjonkers\\.dev/")))' "$source")"
    pinned="$(mktemp -d)"
    oras pull "${url#oci://}@${digest}" --output "$pinned" > /dev/null \
      || die "could not pull the artifact ${project} pinned at its replayed commit"
    labelled=""
    if [ -f "${pinned}/apps/${project}/kustomization.yaml" ]; then
      labelled="$(yq '.patches[]? | select(.target.kind | test("Deployment")) | .patch' "${pinned}/apps/${project}/kustomization.yaml" \
        | yq '.spec.template.metadata.labels["app.kubernetes.io/version"] // ""')"
    fi
    rm -rf "$pinned"
    jq --arg p "$project" --arg c "$content" --argjson a "$annotations" --arg l "$labelled" \
      '.[$p] = {contentHash: $c, annotations: $a, labelled: (if $l == "" then null else $l end)}' "$2" > "$2.next"
    mv "$2.next" "$2"
  done
}

# replay <lock-digest>: compose again from the lock that composed artifact
# holds, into <work>/locks/<digest>/composed. Prints why it could not, and
# fails, where it could not.
replay() {
  local dir="${work}/locks/${1#sha256:}" commit at version tk integrity ref project source
  mkdir -p "$dir"
  oras pull "${COMPOSED}@$1" --output "${dir}/recorded" > /dev/null || die "could not pull ${COMPOSED}@$1"
  commit="$(cat "${dir}/recorded/COMMIT")"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "${COMPOSED}@$1 names no estate commit"
  at="$(jq -er '.metadata.generatedAt' "${dir}/recorded/lock.json")"
  version="$(jq -er '.spec.toolkitVersion' "${dir}/recorded/lock.json")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "${COMPOSED}@$1 records no toolkit release"
  echo "${commit}" > "${dir}/commit"
  echo "${version}" > "${dir}/toolkit"

  # The estate as that composition checked it out.
  git -C "$repository" cat-file -e "${commit}^{commit}" 2> /dev/null \
    || die "${COMPOSED}@$1 was composed at ${commit}, which this clone does not hold"
  mkdir -p "${dir}/estate"
  git -C "$repository" archive "$commit" participants.yml cluster-state.yml projects \
    | tar -x -C "${dir}/estate"

  # Every fragment the lock records: the Platform document's as --platform,
  # the rest as the newest of each participant, and all of them, with every
  # fragment a Rollback names at that commit, as the held fragments.
  mkdir -p "${dir}/fragments" "${dir}/held"
  while IFS=$'\t' read -r project ref; do
    if [ "$project" = "$PLATFORM_PROJECT" ]; then
      fragment "$ref" "${dir}/platform" published
    else
      [[ "$project" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "${COMPOSED}@$1 records a fragment for no project"
      fragment "$ref" "${dir}/fragments/${project}" published
    fi
  done < <(jq -r '.spec.fragments | to_entries[] | "\(.key)\t\(.value.ref)"' "${dir}/recorded/lock.json")
  [ -d "${dir}/platform" ] || die "${COMPOSED}@$1 records no Platform document"
  shopt -s nullglob
  for ref in $( { jq -r '.spec.fragments[].ref' "${dir}/recorded/lock.json"
                  for source in "${dir}"/estate/projects/*/source.yaml; do
                    yq 'select(.kind == "OCIRepository") | .metadata.annotations["estate.jorisjonkers.dev/rollback-fragment"] // ""' "$source"
                  done; } | sort -u ); do
    fragment "$ref" "${dir}/held/$(printf '%s' "$ref" | sha256sum | cut -c1-12)"
  done
  shopt -u nullglob

  pins "${dir}/estate" "${dir}/pins.json"

  tk="$(toolkit "$version")"
  integrity="$(node -p "require('${tk}/node_modules/.package-lock.json').packages['node_modules/@jorisjonkers-dev/deploy-kit'].integrity")"
  node "${scripts}/compose-at.mjs" "$tk" "$at" \
    --platform "${dir}/platform" \
    --fragments "${dir}/fragments" \
    --participants "${dir}/estate/participants.yml" \
    --held "${dir}/held" \
    --pins "${dir}/pins.json" \
    --sources "${dir}/estate/projects" \
    --lock "${dir}/recorded/lock.json" \
    --lock-commit "$commit" \
    --cluster-state "${dir}/estate/cluster-state.yml" \
    --schema-package-integrity "$integrity" \
    --out "${dir}/composed" > "${dir}/compose.log" 2>&1 \
    || { cat "${dir}/compose.log" >&2; die "deploy-kit ${version} refused to compose again from ${COMPOSED}@$1"; }

  # What the lock says of the render as a whole: the same tree of content
  # hashes, from the same ClusterState.
  local field
  for field in composedDigest clusterStateDigest; do
    [ "$(jq -r ".spec.${field}" "${dir}/composed/lock.json")" = "$(jq -r ".spec.${field}" "${dir}/recorded/lock.json")" ] \
      || die "the replay of ${COMPOSED}@$1 has another ${field} than the lock records"
  done
}

# Every pin, and the lock its artifact names.
: > "${work}/pins.tsv"
for source in projects/*/source.yaml; do
  project="$(basename "$(dirname "$source")")"
  [ "$project" = "_canary" ] && continue
  digest="$(yq 'select(.kind == "OCIRepository") | .spec.ref.digest' "$source")"
  [ "$digest" = "$zero" ] && continue
  url="$(yq 'select(.kind == "OCIRepository") | .spec.url' "$source")"
  oras manifest fetch "${url#oci://}@${digest}" > "${work}/manifest.json" || die "could not fetch ${url#oci://}@${digest}"
  lock="$(jq -er '.annotations["dev.jorisjonkers.lock-digest"]' "${work}/manifest.json")" \
    || die "${project}'s artifact names no lock"
  [[ "$lock" =~ ^sha256:[0-9a-f]{64}$ ]] || die "${project}'s artifact names no lock by digest"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$project" "${url#oci://}" "$digest" "$lock" \
    "$(jq -r '.annotations["dev.jorisjonkers.content-hash"] // ""' "${work}/manifest.json")" \
    "$(jq -r '.annotations["dev.jorisjonkers.render-hash"] // ""' "${work}/manifest.json")" >> "${work}/pins.tsv"
done
rm -f "${work}/manifest.json"

# Each lock once, however many pins it composed. A lock that cannot be
# replayed fails every pin it composed, with why, and the next lock still runs.
# The subshell turns errexit back on: under `if` or `||` bash would ignore it.
# Read on its own descriptor, so nothing the loop runs can read the list.
while read -r lock <&3; do
  set +e
  (set -e; replay "$lock") 2> "${work}/locks.${lock#sha256:}.err"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    cat "${work}/locks.${lock#sha256:}.err" >&2
    grep -q '::error::' "${work}/locks.${lock#sha256:}.err" \
      || echo "::error::the replay of ${COMPOSED}@${lock} stopped (exit ${status})" >> "${work}/locks.${lock#sha256:}.err"
  else
    rm -f "${work}/locks.${lock#sha256:}.err"
  fi
done 3< <(cut -f4 "${work}/pins.tsv" | sort -u)

# Each pin against its replay.
failed=0
{
  echo "### Production renders replayed"
  echo
  echo "Each pinned artifact, rendered again from the lock it names and compared byte for byte ([how](https://github.com/${GITHUB_REPOSITORY:-JorisJonkers-dev/estate}#replaying-a-render))."
  echo "Each replays with the deploy-kit release its own lock records; \`toolkit.yml\` names $(yq -r '."deploy-kit"' toolkit.yml), which the next composition runs."
  echo
  echo "| Project | artifact | composed at | toolkit | result |"
  echo "|---|---|---|---|---|"
} > "${work}/summary.md"
: > "${work}/differences.txt"
while IFS=$'\t' read -r project url digest lock content render <&3; do
  dir="${work}/locks/${lock#sha256:}"
  commit="$(cat "${dir}/commit" 2> /dev/null || echo "?")"
  version="$(cat "${dir}/toolkit" 2> /dev/null || echo "?")"
  result=""
  if [ -f "${work}/locks.${lock#sha256:}.err" ]; then
    result="not replayed: $(grep -m1 '::error::' "${work}/locks.${lock#sha256:}.err" | sed 's/^::error:://')"
  else
    composed="$(jq -r --arg p "$project" '.artifacts[] | select(.name == $p) | "\(.repository)\t\(.contentHash)"' "${dir}/composed/composition.json")"
    if [ -z "$composed" ] || [ ! -d "${dir}/composed/artifacts/${project}" ]; then
      result="the replay renders no artifact ${project}"
    elif [ "${composed%%$'\t'*}" != "$url" ]; then
      result="the replay publishes ${project} at ${composed%%$'\t'*}, not ${url}"
    elif [ "${composed#*$'\t'}" != "$content" ]; then
      result="content hash ${composed#*$'\t'} is not the artifact's ${content}"
    elif [ "$(jq -r '.spec.composedDigest' "${dir}/composed/lock.json")" != "$render" ]; then
      result="render hash is not the artifact's ${render}"
    else
      rm -rf "${work}/published/${project}"
      if ! oras pull "${url}@${digest}" --output "${work}/published/${project}" > /dev/null; then
        result="could not pull ${url}@${digest}"
      elif ! bash "${scripts}/compare-render.sh" "${work}/published/${project}" "${dir}/composed/artifacts/${project}" \
        > "${work}/compare.out" 2>&1; then
        result="$(grep -c . "${work}/compare.out") paths differ"
        { echo "${project} (${url}@${digest}):"; sed 's/^/  /' "${work}/compare.out"; } >> "${work}/differences.txt"
      fi
    fi
  fi
  if [ -z "$result" ]; then
    echo "${project}: reproduces"
    result="reproduces"
  else
    failed=1
    echo "::error::${project} does not reproduce: ${result}"
  fi
  echo "| \`${project}\` | \`${digest:7:12}\` | \`${commit:0:12}\` | ${version} | ${result} |" >> "${work}/summary.md"
done 3< "${work}/pins.tsv"
rm -f "${work}/compare.out"

if [ -s "${work}/differences.txt" ]; then
  cat "${work}/differences.txt"
  { echo; echo "#### Every differing path"; echo; echo '```text'; cat "${work}/differences.txt"; echo '```'; } >> "${work}/summary.md"
fi
exit "$failed"
