#!/usr/bin/env bash
# compose-once.sh <since> <commit> [<reason>]: start a delivery to production,
# and wait until one run of compose.yml started at or after <since> (an RFC
# 3339 time) has delivered on a main that holds <commit>, so it composed what
# that commit asked for. <reason> becomes the run's title. A run that the
# workflow's concurrency replaced is started again; a run that failed fails
# this, and so does a delivery on a main without <commit>.
#
# A run that failed only on its last step, because composition isolated some
# Project, has delivered everything else, so it counts as delivered here: one
# Project's refused release must not stop another Project's rollback.
#
# Reads GH_TOKEN, GITHUB_REPOSITORY and PUSH_URL.
set -euo pipefail

since="${1:?usage: compose-once.sh <since> <commit> [<reason>]}"
commit="${2:?usage: compose-once.sh <since> <commit> [<reason>]}"
reason="${3:-}"
# The step compose.yml fails on, last, when composition isolated a Project.
VERDICT="Fail when a Project is refused"

start() {
  if [ -n "$reason" ]; then
    gh workflow run compose.yml --repo "$GITHUB_REPOSITORY" --ref main -f reason="$reason"
  else
    gh workflow run compose.yml --repo "$GITHUB_REPOSITORY" --ref main
  fi
}

# refused_only <run id>: the run's only failed step is the verdict.
refused_only() {
  gh run view "$1" --repo "$GITHUB_REPOSITORY" --json jobs \
    --jq "[.jobs[].steps[] | select(.conclusion == \"failure\") | .name] == [\"${VERDICT}\"]" | grep -qx true
}

start
for _ in $(seq 1 80); do
  sleep 15
  runs="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow compose.yml --limit 20 \
    --json status,conclusion,createdAt,databaseId,headSha \
    --jq "[.[] | select(.createdAt >= \"${since}\")]")"
  delivered=""
  for run in $(jq -r '.[] | select(.conclusion == "success" or .conclusion == "failure") | "\(.databaseId)/\(.headSha)/\(.conclusion)"' <<< "$runs"); do
    case "$run" in
      */success) delivered="${delivered} ${run%/*}" ;;
      */failure) refused_only "${run%%/*}" && delivered="${delivered} ${run%/*}" \
        && echo "::warning::run ${run%%/*} delivered, and composition refused a Project; see its summary" ;;
    esac
  done
  for run in $delivered; do
    git fetch --quiet "$PUSH_URL" main
    if git merge-base --is-ancestor "$commit" "${run#*/}"; then
      echo "composed: run ${run%%/*}, on ${run#*/}"
      exit 0
    fi
    echo "::error::run ${run%%/*} composed ${run#*/}, which does not hold ${commit}"
    exit 1
  done
  if jq -e '[.[] | select(.conclusion == "failure")] | length > 0' <<< "$runs" > /dev/null; then
    echo "::error::the delivery failed: run $(jq -r '[.[] | select(.conclusion == "failure")][0].databaseId' <<< "$runs")"
    exit 1
  fi
  # Every run since was replaced before it ran: start one more.
  if [ "$(jq 'length' <<< "$runs")" -gt 0 ] && jq -e 'all(.status == "completed")' <<< "$runs" > /dev/null; then
    start
  fi
done
echo "::error::no delivery succeeded in 20 minutes"
exit 1
