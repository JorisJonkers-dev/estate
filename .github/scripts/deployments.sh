#!/usr/bin/env bash
# deployments.sh <composition.json> <lock.json>: open one GitHub Deployment
# per Rollout this delivery moved a pin for, on the repository that released
# it (deploy-kit spec/v1/55-delivery.md#rollouts).
#
# Each Deployment is environment `production`, at the release's commit, with
# the Rollout's URL, the artifact Flux applies and the lock that pinned it. Its
# first status is in_progress, "<project> <version> pinned"; every status after
# that is the Reporter's. An earlier Deployment of the same repository still in
# progress is marked inactive, superseded by this one.
#
# A Rollout's repository and commit are what its fragment says of itself. One
# is opened only where the fragment's signature was made by a run in that
# repository, at that commit; anything else is a warning, never a Deployment.
# Nothing here changes what was delivered, so a failure here warns and moves on.
#
# Reads DEPLOY_TOKEN (the dispatch App's, which holds deployments: write on
# every repository), OWNER, FRAGMENT_SIGNER and RUN, and writes a line per
# Deployment to $GITHUB_STEP_SUMMARY where it is set.
set -euo pipefail

composition="${1:?usage: deployments.sh <composition.json> <lock.json>}"
lock="${2:?usage: deployments.sh <composition.json> <lock.json>}"
: "${OWNER:?}" "${FRAGMENT_SIGNER:?}" "${RUN:?}"
DEPLOY_TOKEN="${DEPLOY_TOKEN:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Read whole before anything acts on it: a file that does not parse stops here.
rollouts="$(jq -c '.rollouts // [] | .[]' "$composition")"
if [ -z "$rollouts" ]; then
  echo "no pin moved for a Project: no Deployment to open"
  exit 0
fi
if [ -z "$DEPLOY_TOKEN" ]; then
  echo "::warning::no dispatch App token, so no Deployment is opened"
  exit 0
fi

api() { GH_TOKEN="$DEPLOY_TOKEN" gh api "$@"; }

{
  echo
  echo "### Deployments"
  echo
} >> "$summary"

while read -r rollout; do
  project="$(jq -r .project <<< "$rollout")"
  repository="$(jq -r .repository <<< "$rollout")"
  sha="$(jq -r .sha <<< "$rollout")"
  version="$(jq -r .version <<< "$rollout")"
  url="$(jq -r '.url // ""' <<< "$rollout")"
  # Every value is checked before it is printed or sent: none reaches a log
  # line, where it could read as a workflow command, unchecked.
  if ! [[ "$project" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && "${repository,,}" =~ ^${OWNER,,}/[a-z0-9._-]+$ &&
    "$sha" =~ ^[0-9a-f]{40}$ && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ &&
    ("$url" = "" || "$url" =~ ^https?://[a-z0-9]([a-z0-9.-]*[a-z0-9])?$) ]]; then
    echo "::warning::a Rollout names a Project, repository, commit, version or URL that is not valid; no Deployment is opened for it"
    continue
  fi

  # The fragment the pin moved to, and the run that signed it.
  fragment="$(jq -r --arg p "$project" '.spec.fragments[$p].ref // ""' "$lock")"
  if [ -z "$fragment" ]; then
    echo "::warning::${project} has no fragment in the lock; no Deployment is opened"
    continue
  fi
  signatures="$(cosign verify "$fragment" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp "$FRAGMENT_SIGNER" 2> /dev/null)" || signatures='[]'
  if ! jq -e --arg repository "${repository,,}" --arg sha "$sha" \
    '[.[].optional | select((.githubWorkflowRepository // "" | ascii_downcase) == $repository and .githubWorkflowSha == $sha)] | length > 0' \
    <<< "$signatures" > /dev/null; then
    echo "::warning::${project} ${version}: its fragment was not signed by a run of ${repository} at ${sha}; no Deployment is opened"
    continue
  fi
  artifact="$(yq 'select(.kind == "OCIRepository") | .spec.url + "@" + .spec.ref.digest' "projects/${project}/source.yaml" 2> /dev/null || true)"

  # The earlier release of this Project still in progress is superseded by
  # this one; a repository can release more than one Project.
  for earlier in $(api "repos/${repository}/deployments?environment=production&per_page=30" \
    --jq ".[] | select(.payload.project == \"${project}\") | .id" 2> /dev/null || true); do
    state="$(api "repos/${repository}/deployments/${earlier}/statuses?per_page=1" --jq '.[0].state // ""' 2> /dev/null || true)"
    case "$state" in in_progress | queued | pending)
      api --silent -X POST "repos/${repository}/deployments/${earlier}/statuses" \
        -f state=inactive -f description="superseded by ${version}" -f log_url="$RUN" ||
        echo "::warning::could not mark ${repository}'s Deployment ${earlier} superseded"
      ;;
    esac
  done

  created="$(jq -n --arg sha "$sha" --arg project "$project" --arg version "$version" \
    --arg artifact "${artifact#oci://}" --arg run "$RUN" --arg lock "$(jq -r '.spec.composedDigest // ""' "$lock")" '{
      ref: $sha, task: "deploy", environment: "production",
      description: "\($project) \($version)",
      auto_merge: false, required_contexts: [],
      production_environment: true, transient_environment: false,
      payload: {project: $project, version: $version, artifact: $artifact, composed: $lock, run: $run}
    }' | api -X POST "repos/${repository}/deployments" --input - --jq .id 2>&1)" || {
    echo "::warning::could not open a Deployment of ${project} ${version} on ${repository}"
    continue
  }
  if ! [[ "$created" =~ ^[0-9]+$ ]]; then
    echo "::warning::could not open a Deployment of ${project} ${version} on ${repository}"
    continue
  fi
  jq -n --arg description "${project} ${version} pinned" --arg run "$RUN" --arg url "$url" '{
      state: "in_progress", description: $description, log_url: $run, auto_inactive: true
    } + (if $url == "" then {} else {environment_url: $url} end)' |
    api --silent -X POST "repos/${repository}/deployments/${created}/statuses" --input - ||
    echo "::warning::opened ${repository}'s Deployment ${created}, but could not give it its first status"

  echo "opened ${project} ${version} on ${repository} (Deployment ${created})"
  echo "- **${project} ${version}**: [Deployment ${created}](https://github.com/${repository}/deployments) on ${repository}${url:+, at ${url}}" >> "$summary"
done <<< "$rollouts"
