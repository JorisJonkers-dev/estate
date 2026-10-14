#!/usr/bin/env bash
# compose-once.sh <since>: start composition, and wait until one Compose run
# started at or after <since> (an RFC 3339 time) has succeeded, so it read
# main as it stood then. A run that composition's concurrency replaced is
# started again; a run that failed fails this.
#
# Reads GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail

since="${1:?usage: compose-once.sh <since>}"
gh workflow run compose.yml --repo "$GITHUB_REPOSITORY" --ref main
for _ in $(seq 1 80); do
  sleep 15
  runs="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow compose.yml --limit 20 \
    --json status,conclusion,createdAt,databaseId \
    --jq "[.[] | select(.createdAt >= \"${since}\")]")"
  if jq -e '[.[] | select(.conclusion == "success")] | length > 0' <<< "$runs" > /dev/null; then
    echo "composed: run $(jq -r '[.[] | select(.conclusion == "success")][0].databaseId' <<< "$runs")"
    exit 0
  fi
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
