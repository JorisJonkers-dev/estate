#!/usr/bin/env bash
# compose-once.sh <since> <commit>: start composition, and wait until one
# Compose run started at or after <since> (an RFC 3339 time) has succeeded on
# a main that holds <commit>, so it composed what that commit asked for. A run
# that composition's concurrency replaced is started again; a run that failed
# fails this, and so does a success on a main without <commit>.
#
# Reads GH_TOKEN, GITHUB_REPOSITORY and PUSH_URL.
set -euo pipefail

since="${1:?usage: compose-once.sh <since> <commit>}"
commit="${2:?usage: compose-once.sh <since> <commit>}"
gh workflow run compose.yml --repo "$GITHUB_REPOSITORY" --ref main
for _ in $(seq 1 80); do
  sleep 15
  runs="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow compose.yml --limit 20 \
    --json status,conclusion,createdAt,databaseId,headSha \
    --jq "[.[] | select(.createdAt >= \"${since}\")]")"
  for run in $(jq -r '.[] | select(.conclusion == "success") | "\(.databaseId)/\(.headSha)"' <<< "$runs"); do
    git fetch --quiet "$PUSH_URL" main
    if git merge-base --is-ancestor "$commit" "${run#*/}"; then
      echo "composed: run ${run%%/*}, on ${run#*/}"
      exit 0
    fi
    echo "::error::run ${run%%/*} composed ${run#*/}, which does not hold ${commit}"
    exit 1
  done
  if jq -e '[.[] | select(.conclusion == "failure")] | length > 0' <<< "$runs" > /dev/null; then
    echo "::error::composition failed: run $(jq -r '[.[] | select(.conclusion == "failure")][0].databaseId' <<< "$runs")"
    exit 1
  fi
  # Every run since was replaced before it ran: start one more.
  if [ "$(jq 'length' <<< "$runs")" -gt 0 ] && jq -e 'all(.status == "completed")' <<< "$runs" > /dev/null; then
    gh workflow run compose.yml --repo "$GITHUB_REPOSITORY" --ref main
  fi
done
echo "::error::no composition succeeded in 20 minutes"
exit 1
