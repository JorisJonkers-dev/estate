#!/usr/bin/env bash
# hold.sh pause|resume <project>: one commit to a Project's pin file that
# pauses it or resumes it (deploy-kit spec/v1/55-delivery.md#pause-and-rollback).
#
# A Pause writes who, when and why on the OCIRepository in
# projects/<project>/source.yaml; composition reads them and moves no pin for
# the Project until a resume removes them, the Rollback's two with them.
#
# Reads ACTOR (the login that ran it), REASON (a pause's, required) and
# PUSH_URL (where to push, carrying the Collector App's token). Pushes to main,
# replaying the edit on a newer main when a composition's pin commit landed
# first.
set -euo pipefail

action="${1:-}"
project="${2:-}"

case "$action" in pause | resume) ;; *)
  echo "::error::usage: hold.sh pause|resume <project>"
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
  local paused
  paused="$(yq "${repository} | .metadata.annotations[\"${key}paused-by\"] // \"\"" "$source")"
  if [ "$action" = pause ]; then
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
    # Resuming removes all five: a Rollback's version and fragment too.
    yq -i "
      (${repository} | .metadata.annotations) |= with_entries(select(.key | test(\"^estate\\\\.jorisjonkers\\\\.dev/\") | not)) |
      del(${repository} | select(.metadata.annotations | length == 0) | .metadata.annotations)
    " "$source"
  fi
}

if [ "$action" = pause ] && [ -z "${REASON//[[:space:]]/}" ]; then
  echo "::error::a pause needs a reason"
  exit 1
fi

git config user.name "estate-composition"
git config user.email "estate-composition@users.noreply.github.com"

for attempt in 1 2 3; do
  git fetch --quiet "$PUSH_URL" main
  git reset --quiet --hard FETCH_HEAD
  edit
  git add "$source"
  git commit --quiet -m "chore(deploy): ${action} ${project} [ci skip]"
  if git push --quiet "$PUSH_URL" HEAD:main; then
    echo "${action}d ${project}"
    exit 0
  fi
  echo "main moved under attempt ${attempt}; replaying"
done
echo "::error::main kept moving; ${project} is unchanged"
exit 1
