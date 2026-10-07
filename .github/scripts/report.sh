#!/usr/bin/env bash
# Report what one composition decided, from the composition.json
# `deploy-kit compose` wrote (deploy-kit spec/v1/55-delivery.md#notifications):
#
#   a commit status on each commit that published a fragment, as the dispatch
#   App, which holds statuses: write on every repository;
#   one issue per pair of Project and condition, opened when it starts,
#   commented when it comes back changed, closed when it clears;
#   a Discord post when an issue opens or closes.
#
# Nothing here changes what composition decided.
set -euo pipefail

composition="${1:?usage: report.sh <composition.json>}"
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${RUN:?}"
STATUS_TOKEN="${STATUS_TOKEN:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
LABEL="area: deploy"

discord() {
  [ -n "$DISCORD_WEBHOOK_URL" ] || return 0
  jq -n --arg content "$1" '{content: $content}' |
    curl -fsS -H 'Content-Type: application/json' --data @- "$DISCORD_WEBHOOK_URL" > /dev/null ||
    echo "::warning::the Discord post failed: $1"
}

if [ -z "$STATUS_TOKEN" ]; then
  echo "::warning::no dispatch App token, so no commit status is reported"
else
  owner="${GITHUB_REPOSITORY%%/*}"
  jq -c '.statuses[]' "$composition" | while read -r status; do
    repository="$(jq -r .repository <<<"$status")"
    sha="$(jq -r .sha <<<"$status")"
    # The dispatch App can write a status anywhere it is installed; it writes
    # one only on a commit of this owner's that a fragment named.
    if [[ "${repository,,}" != "${owner,,}/"?* || ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      # Not printed: a value no check has passed never reaches a log line.
      echo "::warning::a status names a repository or a commit that is not ${owner}'s; it is not written"
      continue
    fi
    GH_TOKEN="$STATUS_TOKEN" gh api --silent "repos/${repository}/statuses/${sha}" \
      -f state="$(jq -r .state <<<"$status")" \
      -f context=estate/compose \
      -f description="$(jq -r '.description[0:140]' <<<"$status")" \
      -f target_url="$RUN"
  done
fi

# Each issue carries its key, `<project>/<condition>`, in a marker the body
# ends with, so a run finds the issue it owns whatever its title became.
marker() { printf '<!-- estate-condition: %s -->' "$1"; }
# A key is checked before it is printed, so no value reaches a log line as a
# workflow command.
valid() { [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?/[a-z]+(-[a-z]+)*$ ]]; }
# shellcheck disable=SC2016 # $key is jq's, not the shell's
open="$(gh issue list --repo "$GITHUB_REPOSITORY" --state open --label "$LABEL" --limit 500 \
  --json number,body \
  --jq '[.[] | (.body | capture("<!-- estate-condition: (?<key>[^ ]+) -->") | .key) as $key
         | {key: $key, number, body}]')"

current=()
while read -r condition; do
  [ -n "$condition" ] || continue
  key="$(jq -r '"\(.project)/\(.condition)"' <<<"$condition")"
  valid "$key" || { echo "::warning::a condition names no Project; it is not reported"; continue; }
  current+=("$key")
  body="$(jq -r .body <<<"$condition")

$(marker "$key")"
  existing="$(jq -c --arg key "$key" 'map(select(.key == $key)) | first // empty' <<<"$open")"
  if [ -z "$existing" ]; then
    gh issue create --repo "$GITHUB_REPOSITORY" --label "$LABEL" \
      --title "$(jq -r .title <<<"$condition")" --body "$body" > /dev/null
    discord "$(jq -r .discord <<<"$condition") ($RUN)"
    echo "opened ${key}"
  elif [ "$(jq -r .body <<<"$existing")" != "$body" ]; then
    number="$(jq -r .number <<<"$existing")"
    gh issue comment "$number" --repo "$GITHUB_REPOSITORY" --body "Still ${key#*/}, now:

$(jq -r .body <<<"$condition")

[run]($RUN)" > /dev/null
    gh issue edit "$number" --repo "$GITHUB_REPOSITORY" --body "$body" > /dev/null
    echo "updated ${key}"
  fi
done < <(jq -c '.conditions[]' "$composition")

# A condition this run no longer reports has cleared.
while read -r issue; do
  [ -n "$issue" ] || continue
  key="$(jq -r .key <<<"$issue")"
  valid "$key" || continue
  for held in ${current[@]+"${current[@]}"}; do
    [ "$held" = "$key" ] && continue 2
  done
  gh issue close "$(jq -r .number <<<"$issue")" --repo "$GITHUB_REPOSITORY" \
    --comment "Cleared: composition no longer reports ${key} ([run]($RUN))." > /dev/null
  discord "Cleared: ${key} ($RUN)"
  echo "closed ${key}"
done < <(jq -c '.[]' <<<"$open")
