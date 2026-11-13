#!/usr/bin/env bash
# test-compare-render.sh: run compare-render.sh against pairs of small trees,
# one identical pair and one for each way two renders can differ. A
# comparison that has only ever passed is untested, so every case but the
# first must fail, and on the right path.
# Exits non-zero on the first expectation that fails.
#
# Run from the repository root: bash .github/scripts/test-compare-render.sh
set -euo pipefail

compare="$(pwd)/.github/scripts/compare-render.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# setup: two copies of one render, a Project's unit with a nested directory
# and a file name holding a space.
setup() {
  rm -rf "$work/published" "$work/replayed"
  mkdir -p "$work/published/apps/app/app" "$work/published/estate"
  printf 'resources:\n  - app\n' > "$work/published/apps/app/kustomization.yaml"
  printf 'kind: Deployment\n' > "$work/published/apps/app/app/workload.yaml"
  printf 'kind: Namespace\n' > "$work/published/apps/app/name space.yaml"
  printf 'kind: PriorityClass\n' > "$work/published/estate/priority.yaml"
  cp -R "$work/published" "$work/replayed"
}

# run: compare the two trees, keeping what it printed and its status.
run() {
  set +e
  bash "$compare" "$work/published" "$work/replayed" > "$work/out" 2> "$work/err"
  status=$?
  set -e
}

expect_refusal() { # expect_refusal <case> <line>...: exit 1, printing exactly these lines
  local name="$1"
  shift
  [ "$status" -eq 1 ] || fail "${name}: exit ${status}, not 1"
  printf '%s\n' "$@" | diff - "$work/out" > /dev/null || fail "${name}: printed $(cat "$work/out")"
}

echo "identical trees pass, and print nothing"
setup
run
[ "$status" -eq 0 ] || fail "identical trees: exit ${status}"
[ ! -s "$work/out" ] || fail "identical trees printed $(cat "$work/out")"

echo "a file's mode and time are not its bytes, so they pass"
setup
chmod 600 "$work/replayed/apps/app/app/workload.yaml"
touch -t 200001010000 "$work/replayed/apps/app/kustomization.yaml"
run
[ "$status" -eq 0 ] || fail "mode and time: exit ${status}"

echo "an empty directory is not a file, so it passes"
setup
mkdir -p "$work/replayed/apps/app/empty"
run
[ "$status" -eq 0 ] || fail "an empty directory: exit ${status}"

echo "one changed byte fails, on its path"
setup
printf 'kind: StatefulSet\n' > "$work/replayed/apps/app/app/workload.yaml"
run
expect_refusal "a changed byte" "differs: apps/app/app/workload.yaml"

echo "a missing final newline fails"
setup
printf 'kind: PriorityClass' > "$work/replayed/estate/priority.yaml"
run
expect_refusal "a missing newline" "differs: estate/priority.yaml"

echo "a file only in the artifact fails, and so does one only in the replay"
setup
rm "$work/replayed/apps/app/name space.yaml"
printf 'kind: Job\n' > "$work/replayed/apps/app/app/backup.yaml"
run
expect_refusal "a file on one side" \
  "only in replayed: apps/app/app/backup.yaml" \
  "only in published: apps/app/name space.yaml"

echo "every differing path is named, sorted, not just the first"
setup
printf 'x\n' >> "$work/replayed/estate/priority.yaml"
printf 'x\n' >> "$work/replayed/apps/app/kustomization.yaml"
rm -r "$work/replayed/apps/app/app"
run
expect_refusal "several differences" \
  "only in published: apps/app/app/workload.yaml" \
  "differs: apps/app/kustomization.yaml" \
  "differs: estate/priority.yaml"

echo "a symlink is reported, never followed"
setup
rm "$work/published/estate/priority.yaml"
ln -s ../../replayed/estate/priority.yaml "$work/published/estate/priority.yaml"
run
expect_refusal "a symlink" \
  "not a regular file: estate/priority.yaml" \
  "only in replayed: estate/priority.yaml"

echo "a tree that is not there is a wrong call"
setup
rm -r "$work/replayed"
run
[ "$status" -eq 2 ] || fail "a missing tree: exit ${status}, not 2"

echo "ok"
