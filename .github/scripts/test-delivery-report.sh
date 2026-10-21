#!/usr/bin/env bash
# test-delivery-report.sh: run delivery-report.sh record against fixtures laid
# out as the compose job leaves its working directory. Exits non-zero on the
# first expectation that fails.
#
# Run from the repository root: bash .github/scripts/test-delivery-report.sh
set -euo pipefail

root="$(pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

A="$(printf 'a%.0s' $(seq 40))"
DIGEST="sha256:$(printf 'e%.0s' $(seq 64))"

fragment() { # fragment <dir> <project> <version> <published>
  mkdir -p "$work/$1"
  printf 'spec:\n  project: %s\n  version: %s\n' "$2" "$3" > "$work/$1/fragment.yml"
  printf '%s\n' "$4" > "$work/$1/published"
}

layout() { # the working directory of a run that composed
  rm -rf "${work:?}"/*
  mkdir -p "$work/composed"
  printf 'deploy-kit: 0.26.1\n' > "$work/toolkit.yml"
  printf 'kind: ClusterState\ncapturedAt: "2026-10-21T09:44:34Z"\n' > "$work/cluster-state.yml"
  printf 'metadata:\n  project: jorisjonkers.dev\nhandover:\n  legacy: [tribelt]\n' > "$work/platform.intent.yml"
  fragment platform-fragment jorisjonkers.dev 1.4.0 2026-10-01T08:00:00Z
  cp "$work/platform.intent.yml" "$work/platform-fragment/platform.intent.yml"
  fragment fragments/delivery delivery 0.4.0 2026-10-21T09:00:00Z
  fragment fragments/app app 0.12.0 2026-10-20T12:00:00Z
  fragment fragments/knowledge knowledge 1.13.1 2026-10-19T10:00:00Z
  fragment fragments/grimoire grimoire 0.21.0 2026-10-12T10:00:00Z
  fragment fragments/notes notes 0.9.1 2026-10-21T08:00:00Z
  cat > "$work/composed/lock.json" << EOF
{"metadata": {"cluster": "production"}, "spec": {"toolkitVersion": "0.26.1",
  "fragments": {
    "jorisjonkers.dev": {"version": "1.4.0", "repository": "JorisJonkers-dev/estate", "sourceSha": "$A"},
    "delivery": {"version": "0.4.0", "repository": "JorisJonkers-dev/delivery", "sourceSha": "$A"},
    "app": {"version": "0.12.0", "repository": "JorisJonkers-dev/home-portal", "sourceSha": "$A"},
    "knowledge": {"version": "1.12.0", "repository": "JorisJonkers-dev/knowledge", "sourceSha": "$A"},
    "notes": {"version": "0.9.1", "repository": "JorisJonkers-dev/notes", "sourceSha": "$A"},
    "tribelt": {"version": "0.3.0", "repository": "JorisJonkers-dev/tribelt", "sourceSha": "$A"}},
  "isolated": {
    "knowledge": {"codes": ["E_DUPLICATE_HOST"]},
    "grimoire": {"codes": ["E_PARTICIPANT_STALE"]},
    "media": {"codes": ["E_PARTICIPANT_MISSING"]}}}}
EOF
  cat > "$work/composed/composition.json" << 'EOF'
{"artifacts": [
  {"name": "_estate", "moves": true},
  {"name": "delivery", "moves": true},
  {"name": "app", "moves": false},
  {"name": "notes", "moves": false}],
 "rollouts": [{"project": "delivery", "version": "0.4.0"}],
 "conditions": [{"project": "notes", "condition": "paused"}, {"project": "knowledge", "condition": "isolated"}]}
EOF
}

record() { # record [DELIVERED]: delivery-report.sh record in $work
  (cd "$work" && DELIVERED="${1:-}" LOCK_DIGEST="$DIGEST" bash "$root/.github/scripts/delivery-report.sh" record)
}
row() { jq -c --arg p "$2" '.fragments[] | select(.project == $p) | [.version, .outcome, .reason, .published]' <<< "$1"; }
expect() { # expect <description> <actual> <wanted>
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1: got '$2', wanted '$3'"
    exit 1
  fi
  echo "ok: $1"
}

layout
out="$(record "$A")"
expect "a delivered run names its toolkit, its snapshot and its lock" \
  "$(jq -c '[.refused, .toolkit, .snapshotAt, .lock]' <<< "$out")" \
  "[false,\"0.26.1\",\"2026-10-21T09:44:34Z\",\"$DIGEST\"]"
expect "it moved only the Project whose pin commit it pushed, not the estate-scoped artifact" \
  "$(jq -c .moved <<< "$out")" '["delivery"]'
expect "the moved Project is moved, at its release, with its push time" \
  "$(row "$out" delivery)" '["0.4.0","moved",null,"2026-10-21T09:00:00Z"]'
expect "a Project whose pin stays is unchanged" \
  "$(row "$out" app)" '["0.12.0","unchanged",null,"2026-10-20T12:00:00Z"]'
expect "a refused fragment is isolated at the release it refused, with its codes" \
  "$(row "$out" knowledge)" '["1.13.1","isolated","E_DUPLICATE_HOST","2026-10-19T10:00:00Z"]'
expect "a fragment too old to compose is stale" \
  "$(row "$out" grimoire)" '["0.21.0","stale","E_PARTICIPANT_STALE","2026-10-12T10:00:00Z"]'
expect "a Project that published no fragment is stale, with no release and no push time" \
  "$(row "$out" media)" '[null,"stale","E_PARTICIPANT_MISSING",null]'
expect "a paused Project is held" \
  "$(row "$out" notes)" '["0.9.1","held","paused","2026-10-21T08:00:00Z"]'
expect "the Platform document is read like any fragment" \
  "$(row "$out" jorisjonkers.dev)" '["1.4.0","unchanged",null,"2026-10-01T08:00:00Z"]'
expect "the estate-scoped artifact is no fragment" \
  "$(jq -c '[.fragments[] | select(.project == "_estate")] | length' <<< "$out")" 0

out="$(record "")"
expect "a run that pushed no pin commit moved nothing" "$(jq -c .moved <<< "$out")" '[]'
expect "and says why the Project it would have moved did not move" \
  "$(row "$out" delivery)" '["0.4.0","unchanged","not delivered: the run failed before the pin commit","2026-10-21T09:00:00Z"]'

layout
rm "$work/composed/lock.json" "$work/composed/composition.json"
out="$(record "")"
expect "a composition that refused outright says so, with the toolkit and snapshot it read, and no fragments" \
  "$(jq -c '[.refused, .toolkit, .snapshotAt, .moved, .fragments]' <<< "$out")" \
  '[true,"0.26.1","2026-10-21T09:44:34Z",[],[]]'

layout
printf 'spec:\n  project: knowledge\n  version: "1.13.1<b>"\n' > "$work/fragments/knowledge/fragment.yml"
printf 'yesterday\n' > "$work/fragments/knowledge/published"
out="$(record "$A")"
expect "a value a refused fragment states is held to its shape" \
  "$(jq -c '.fragments[] | select(.project == "knowledge") | [.version, .published]' <<< "$out")" '["?",null]'

echo "all delivery-report.sh record expectations hold"
