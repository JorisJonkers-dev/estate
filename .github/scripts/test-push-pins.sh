#!/usr/bin/env bash
# test-push-pins.sh: run push-pins.sh against a local bare repository standing
# in for GitHub, with main moved under the pin commit in each way it can be.
# Exits non-zero on the first expectation that fails.
#
# Run from the repository root: bash .github/scripts/test-push-pins.sh
set -euo pipefail

push_pins="$(pwd)/.github/scripts/push-pins.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# setup: a remote whose main holds a pin and a ClusterState, and a clone of it
# that has made one pin commit, as commit-pins.sh leaves the composition's.
setup() {
  rm -rf "$work/remote.git" "$work/composition" "$work/collector"
  git init --quiet --bare --initial-branch=main "$work/remote.git"
  git clone --quiet "$work/remote.git" "$work/collector" 2> /dev/null
  (cd "$work/collector" && mkdir -p projects/app && echo "digest: a" > projects/app/source.yaml \
    && echo "state: 1" > cluster-state.yml && git add . && git commit --quiet -m base && git push --quiet origin HEAD:main)
  git clone --quiet "$work/remote.git" "$work/composition"
  (cd "$work/composition" && echo "digest: b" > projects/app/source.yaml && git commit --quiet -am "chore(deploy): app")
}

# land <file> <content>: another writer pushes a commit to main first.
land() {
  (cd "$work/collector" && git pull --quiet --rebase origin main && echo "$2" > "$1" \
    && git add "$1" && git commit --quiet -m "lands $1" && git push --quiet origin HEAD:main)
}

remote_has() { git --git-dir="$work/remote.git" show "main:$1" | grep -qx "$2"; }

echo "a pin commit onto an unmoved main is pushed as it is"
setup
(cd "$work/composition" && bash "$push_pins" "$work/remote.git" > "$work/out" 2> /dev/null) || fail "unmoved main refused"
remote_has projects/app/source.yaml "digest: b" || fail "unmoved main: the pin did not land"
[ "$(cat "$work/out")" = "$(git --git-dir="$work/remote.git" rev-parse main)" ] || fail "unmoved main: printed the wrong commit"

echo "a pin commit is rebased onto a ClusterState capture and pushed"
setup
land cluster-state.yml "state: 2"
(cd "$work/composition" && bash "$push_pins" "$work/remote.git" > "$work/out" 2> /dev/null) || fail "capture refused"
remote_has projects/app/source.yaml "digest: b" || fail "capture: the pin did not land"
remote_has cluster-state.yml "state: 2" || fail "capture: the capture was lost"
[ "$(cat "$work/out")" = "$(git --git-dir="$work/remote.git" rev-parse main)" ] || fail "capture: printed the wrong commit"

echo "a pin commit is refused when another pin moved under it"
setup
land projects/other.yaml "digest: c"
if (cd "$work/composition" && bash "$push_pins" "$work/remote.git" > /dev/null 2> "$work/err"); then
  fail "a moved pin was pushed over"
fi
grep -q "beyond a ClusterState capture: projects/other.yaml" "$work/err" || fail "a moved pin: the refusal names no file"
remote_has projects/app/source.yaml "digest: a" || fail "a moved pin: main changed"

echo "ok"
