#!/usr/bin/env bash
# push-pins.sh <remote>: push the one pin commit commit-pins.sh made onto the
# remote's main, and print the commit that landed.
#
# The Collector commits a ClusterState capture to main every ten minutes, so a
# composition that runs across one finds main moved under it. A capture
# changes cluster-state.yml alone, which the next composition reads afresh, so
# the pin commit is rebased onto it and pushed again. Anything else that moved
# is an input this composition read stale (a pin, the Platform document, a
# participant), and pushing over it would deploy what it no longer derives:
# the push is refused, and the next composition composes from main as it is.
set -euo pipefail

remote="${1:-}"
[ -n "$remote" ] || {
  echo "::error::usage: push-pins.sh <remote>"
  exit 2
}
attempts=5
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

for attempt in $(seq 1 "$attempts"); do
  if git push --quiet "$remote" HEAD:main 2> "$err"; then
    git rev-parse HEAD
    exit 0
  fi
  grep -q -e 'fetch first' -e 'non-fast-forward' "$err" || {
    cat "$err" >&2
    exit 1
  }
  git fetch --quiet "$remote" main
  moved="$(git diff --name-only "$(git merge-base HEAD FETCH_HEAD)" FETCH_HEAD -- . ':(exclude)cluster-state.yml')"
  if [ -n "$moved" ]; then
    echo "::error::main moved under this composition, beyond a ClusterState capture: ${moved//$'\n'/, }" >&2
    exit 1
  fi
  echo "main gained a ClusterState capture; rebasing the pin commit onto it (attempt ${attempt} of ${attempts})" >&2
  git rebase --quiet FETCH_HEAD
done

echo "::error::main kept moving; the pin commit was not pushed after ${attempts} attempts" >&2
exit 1
