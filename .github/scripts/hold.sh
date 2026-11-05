#!/usr/bin/env bash
# hold.sh pause|resume|retry <project>: one commit to a Project's pin file that
# pauses it, resumes it or retries its release
# (deploy-kit spec/v1/55-delivery.md#pause-and-rollback).
#
# A Pause writes who, when and why on the OCIRepository in
# projects/<project>/source.yaml; composition reads them and moves no pin for
# the Project until a resume removes them, the Rollback's two with them.
#
# A Retry writes when it ran, which composition renders onto the pod template
# of every gated Deployment, so Flagger analyses the pinned release once more.
# Who ran it and why are its commit's. A resume keeps it: removing it would be
# one more release for Flagger to analyse.
#
# Reads ACTOR (the login that ran it), REASON (a pause's or a retry's,
# required) and PUSH_URL (where to push, carrying the Collector App's token).
# Pushes to main, replaying the edit on a newer main when a composition's pin
# commit landed first.
set -euo pipefail

action="${1:-}"
project="${2:-}"

case "$action" in pause | resume | retry) ;; *)
  echo "::error::usage: hold.sh pause|resume|retry <project>"
  exit 2
  ;;
esac

# A Project's name, as the participants list keys it; the estate-scoped and
# canary sources start with an underscore, so they never match.
if ! [[ "$project" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "::error::'${project}' is not a Project's name"
  exit 1
fi
source="projects/${project}/source.yaml"

repository='select(.kind == "OCIRepository")'
key='estate.jorisjonkers.dev/'

edit() {
  [ -f "$source" ] || {
    echo "::error::${project} has no pin on the estate path (${source})"
    exit 1
  }
  local paused rolled
  paused="$(yq "${repository} | .metadata.annotations[\"${key}paused-by\"] // \"\"" "$source")"
  rolled="$(yq "${repository} | .metadata.annotations[\"${key}rollback-fragment\"] // \"\"" "$source")"
  if [ "$action" = retry ]; then
    # A paused Project's pin moves only to the release a Rollback recorded.
    [ -z "$paused" ] || [ -n "$rolled" ] || {
      echo "::error::${project} is paused by ${paused}; resume it, which composes its newest release"
      exit 1
    }
    AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" yq -i "
      (${repository} | .metadata.annotations[\"${key}retried-at\"]) = strenv(AT)
    " "$source"
  elif [ "$action" = pause ]; then
    [ -z "$paused" ] || {
      echo "::error::${project} is already paused by ${paused}"
      exit 1
    }
    AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" yq -i "
      (${repository} | .metadata.annotations[\"${key}paused-by\"]) = strenv(ACTOR) |
      (${repository} | .metadata.annotations[\"${key}paused-at\"]) = strenv(AT) |
      (${repository} | .metadata.annotations[\"${key}paused-reason\"]) = strenv(REASON)
    " "$source"
  else
    [ -n "$paused" ] || {
      echo "::error::${project} is not paused"
      exit 1
    }
    # Resuming removes the Pause and a Rollback's version and fragment, and
    # keeps a Retry: removing it would change every gated pod template.
    yq -i "
      (${repository} | .metadata.annotations) |= with_entries(select(.key | test(\"^estate\\\\.jorisjonkers\\\\.dev/(paused|rollback)-\") | not)) |
      del(${repository} | select(.metadata.annotations | length == 0) | .metadata.annotations)
    " "$source"
  fi
}

if [ "$action" != resume ] && [ -z "${REASON//[[:space:]]/}" ]; then
  echo "::error::a ${action} needs a reason"
  exit 1
fi

# Who ran a Retry and why are its commit's, not the pin file's.
body=()
done="${action}d"
if [ "$action" = retry ]; then
  body=(-m "Retried by ${ACTOR}: ${REASON}")
  done=retried
fi

git config user.name "estate-composition"
git config user.email "estate-composition@users.noreply.github.com"

for attempt in 1 2 3; do
  git fetch --quiet "$PUSH_URL" main
  git reset --quiet --hard FETCH_HEAD
  edit
  git add "$source"
  git commit --quiet -m "chore(deploy): ${action} ${project} [ci skip]" ${body[@]+"${body[@]}"}
  if git push --quiet "$PUSH_URL" HEAD:main; then
    echo "${done} ${project}"
    exit 0
  fi
  echo "main moved under attempt ${attempt}; replaying"
done
echo "::error::main kept moving; ${project} is unchanged"
exit 1
