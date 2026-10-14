#!/usr/bin/env bash
# rollback.sh <step> <project> ...: the steps of a Rollback
# (deploy-kit spec/v1/55-delivery.md#pause-and-rollback), each one thing the
# rollback workflow runs in order.
#
#   target  <project> <version>   refuse a release that is not the proven one;
#                                 write fragment=<image@digest> and
#                                 pinned=<image@digest> to $GITHUB_OUTPUT
#   ask     <project> <request>   pause the Project and ask for its backup
#   expect  <project> <request>   the backup Jobs composition rendered for the
#                                 request, one name a line, into expected.txt
#   await   <project> <request>   wait until each expected Job ended; fail on a
#                                 failed, unknown or missing one by DEADLINE
#   record  <project> <version> <fragment> <pinned>
#                                 drop the request and record the target, once
#                                 the pin is still the one the target was
#                                 proven against
#   stop    <project> <why>       drop the request, leave the Project paused
#
# Reads ACTOR and REASON (ask), PUSH_URL (every step that commits), OWNER,
# COMPOSED, SIGNER_ISSUER, SIGNER_SUBJECT and FRAGMENT_SIGNER (target, record)
# and DEADLINE, an epoch second (await). The steps share the job's working
# directory: expect reads the pinned release target pulled. Every commit replays its edit on a newer main when a
# composition's pin commit landed first, as hold.sh does.
set -euo pipefail

step="${1:-}"
project="${2:-}"
if ! [[ "$project" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "::error::'${project}' is not a Project's name"
  exit 1
fi
source="projects/${project}/source.yaml"
repository='select(.kind == "OCIRepository")'
key='estate.jorisjonkers.dev/'

annotation() { # annotation <name>: its value on the pin source, or nothing
  yq "${repository} | .metadata.annotations[\"${key}$1\"] // \"\"" "$source"
}

commit() { # commit <message> <edit function>: one commit to the pin source, pushed
  git config user.name "estate-composition"
  git config user.email "estate-composition@users.noreply.github.com"
  for attempt in 1 2 3; do
    git fetch --quiet "$PUSH_URL" main
    git reset --quiet --hard FETCH_HEAD
    [ -f "$source" ] || {
      echo "::error::${project} has no pin on the estate path (${source})"
      exit 1
    }
    "$2"
    git add "$source"
    git commit --quiet -m "chore(deploy): $1 [ci skip]"
    if git push --quiet "$PUSH_URL" HEAD:main; then
      return 0
    fi
    echo "main moved under attempt ${attempt}; replaying"
  done
  echo "::error::main kept moving; ${project} is unchanged"
  exit 1
}

latest_lock() { # latest_lock <directory>: the newest composition's lock, verified
  composed_lock "$(oras resolve "${COMPOSED}:latest")" "$1"
}

composed_lock() { # composed_lock <digest> <directory>: a composition's lock, verified
  cosign verify "${COMPOSED}@$1" \
    --certificate-oidc-issuer "$SIGNER_ISSUER" --certificate-identity "$SIGNER_SUBJECT" > /dev/null \
    || { echo "::error::${COMPOSED}@$1 is not signed by composition"; exit 1; }
  oras pull "${COMPOSED}@$1" --output "$2" > /dev/null
}

case "$step" in
target)
  version="${3:-}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "::error::'${version}' is not a release version"; exit 1; }
  [ -f "$source" ] || { echo "::error::${project} has no pin on the estate path (${source})"; exit 1; }
  [ -z "$(annotation rollback-backup)$(annotation rollback-fragment)" ] \
    || { echo "::error::${project} is already being rolled back; resume it first"; exit 1; }

  # What the Project is pinned to: the newest composition's lock says.
  latest_lock latest
  current="$(jq -r --arg p "$project" '.spec.fragments[$p].ref // ""' latest/lock.json)"
  serving="$(jq -r --arg p "$project" '.spec.fragments[$p].version // ""' latest/lock.json)"
  [ -n "$current" ] || { echo "::error::${project} has never composed"; exit 1; }
  [ "$version" != "$serving" ] && [ "$(printf '%s\n%s\n' "$version" "$serving" | sort -V | head -n 1)" = "$version" ] \
    || { echo "::error::${version} is not earlier than ${serving}, the release ${project} is pinned to"; exit 1; }

  # The release asked for, by the digest its version tag names now.
  image="ghcr.io/${OWNER}/intent-${project}"
  digest="$(oras resolve "${image}:${version}" 2> /dev/null)" \
    || { echo "::error::${project} has no release ${version}"; exit 1; }
  # Signed by publish-fragment from the repository it names, as composition
  # holds every fragment it reads, before anything of it is read.
  signatures="$(cosign verify "${image}@${digest}" \
    --certificate-oidc-issuer "$SIGNER_ISSUER" --certificate-identity-regexp "$FRAGMENT_SIGNER")" \
    || { echo "::error::${image}@${digest} is not signed by publish-fragment"; exit 1; }
  oras pull "${image}@${digest}" --output asked > /dev/null
  [ "$(yq '.spec.project' asked/fragment.yml)" = "$project" ] && [ "$(yq '.spec.version' asked/fragment.yml)" = "$version" ] \
    || { echo "::error::${image}:${version} is not ${project} ${version}"; exit 1; }
  named="$(yq '.metadata.repository' asked/fragment.yml | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$signatures" | jq -e --arg repository "$named" \
    '[.[].optional.githubWorkflowRepository // "" | ascii_downcase | . == $repository] | any' > /dev/null \
    || { echo "::error::${image}@${digest} is not signed from ${named}, the repository it names"; exit 1; }

  # Only a release proven against the schema the pinned release left: the one
  # whose rendered revision every Application's Migration Proof names. A
  # Project whose pinned release proves nothing may go to any earlier one.
  oras pull "$current" --output pinned > /dev/null
  if [ -f pinned/migration-proof.yml ] && [ "$(yq '.applications | length' pinned/migration-proof.yml)" != 0 ]; then
    yq -e '.applications | all_c(has("testedAgainst"))' pinned/migration-proof.yml > /dev/null \
      || { echo "::error::${project} ${serving} is a first release: no earlier release is proven against its schema"; exit 1; }
    wanted="$(yq -o=json '[.applications[] | {"key": .id, "value": .testedAgainst}] | from_entries' pinned/migration-proof.yml)"
    proven=false
    # Every composition's lock, found by the signature each carries.
    for tag in $(oras repo tags "$COMPOSED" | grep -E '^sha256-[a-f0-9]{64}\.sig$'); do
      digest_of="sha256:${tag:7:64}"
      rm -rf walked && composed_lock "$digest_of" walked
      if jq -e --arg p "$project" --arg v "$version" --argjson w "$wanted" '
        .spec.fragments[$p] | select(. != null and .version == $v) | .revisions as $r
        | $w | to_entries | all(.value == $r[.key])' walked/lock.json > /dev/null; then
        proven=true
        break
      fi
    done
    [ "$proven" = true ] \
      || { echo "::error::${project} ${version} is not the release ${serving}'s Migration Proof names; only that one runs against the current schema"; exit 1; }
  fi
  echo "fragment=${image}@${digest}" >> "$GITHUB_OUTPUT"
  echo "pinned=${current}" >> "$GITHUB_OUTPUT"
  echo "${project} ${version} is proven: ${image}@${digest}"
  ;;

ask)
  request="${3:-}"
  [ -n "${REASON//[[:space:]]/}" ] || { echo "::error::a rollback needs a reason"; exit 1; }
  ask_edit() {
    AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" REQUEST="$request" yq -i "
      (${repository} | .metadata.annotations[\"${key}paused-by\"]) = strenv(ACTOR) |
      (${repository} | .metadata.annotations[\"${key}paused-at\"]) = strenv(AT) |
      (${repository} | .metadata.annotations[\"${key}paused-reason\"]) = strenv(REASON) |
      (${repository} | .metadata.annotations[\"${key}rollback-backup\"]) = strenv(REQUEST)
    " "$source"
  }
  commit "back up ${project} before a rollback" ask_edit
  echo "paused ${project} and asked for backup ${request}"
  ;;

expect)
  request="${3:-}"
  git fetch --quiet "$PUSH_URL" main
  git reset --quiet --hard FETCH_HEAD
  : > expected.txt
  # Whether the pinned release has anything to back up: a volume of a class
  # that derives a backup. Only then may the render hold no Job, so a render
  # that dropped the request fails here rather than rolling back unprotected.
  backed_up="$(cat pinned/*.project.yml | yq -N '[.. | select(tag == "!!map" and has("durability")) | .durability | select(. == "recoverable" or . == "irreplaceable")] | length')"
  none() {
    if [ "$backed_up" = 0 ]; then
      echo "::notice::${project}'s pinned release has no backed-up volume: there is nothing to back up"
      exit 0
    fi
    echo "::error::${project}'s pinned release has ${backed_up} backed-up volume(s), but $1"
    exit 1
  }
  estate="projects/_estate/source.yaml"
  if [ "$(yq 'select(.kind == "Kustomization" and .metadata.name == "estate-rollback-backups") | .metadata.name' "$estate")" = "" ]; then
    none "the render applies no backup unit"
  fi
  url="$(yq "${repository} | .spec.url" "$estate")"
  digest="$(yq "${repository} | .spec.ref.digest" "$estate")"
  oras pull "${url#oci://}@${digest}" --output estate-render > /dev/null
  jobs="estate-render/estate/rollback-backups/${project}.yaml"
  [ -f "$jobs" ] || none "the render holds no backup Job for it"
  REQUEST="$request" yq -N 'select(.kind == "Job" and .metadata.labels["estate.jorisjonkers.dev/rollback-backup"] == strenv(REQUEST)) | .metadata.name' "$jobs" \
    | sort > expected.txt
  [ -s expected.txt ] || { echo "::error::the render holds backup Jobs for ${project}, but none for request ${request}"; exit 1; }
  echo "expecting: $(paste -sd' ' expected.txt)"
  ;;

await)
  request="${3:-}"
  [ -s expected.txt ] || { echo "nothing to wait for"; exit 0; }
  while :; do
    git fetch --quiet "$PUSH_URL" main
    git show FETCH_HEAD:cluster-state.yml \
      | REQUEST="$request" PROJECT="$project" yq -o=json '[.backups // [] | .[] | select(.request == strenv(REQUEST) and .project == strenv(PROJECT))]' > reported.json
    if jq -e --rawfile expected expected.txt '
        ($expected | split("\n") | map(select(. != ""))) as $e
        | [.[] | .job] - $e | length > 0' reported.json > /dev/null; then
      echo "::error::the Collector reports a backup Job for request ${request} the render does not hold: $(jq -c '[.[].job]' reported.json)"
      exit 1
    fi
    if jq -e '[.[] | select(.outcome != "succeeded")] | length > 0' reported.json > /dev/null; then
      echo "::error::a backup Job failed: $(jq -c '[.[] | select(.outcome != "succeeded") | .job]' reported.json)"
      exit 1
    fi
    if [ "$(jq -r '[.[].job] | sort | .[]' reported.json)" = "$(cat expected.txt)" ]; then
      echo "every backup Job of ${request} succeeded"
      exit 0
    fi
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      echo "::error::the backup did not end in time; reported: $(jq -c '[.[] | {job, outcome}]' reported.json)"
      exit 1
    fi
    sleep 30
  done
  ;;

record)
  version="${3:-}"
  fragment="${4:-}"
  pinned="${5:-}"
  # The proof was read from the release pinned when the run began. The Pause
  # froze that pin, but a composition may have moved it before the Pause
  # landed: a different pin is a different proof, and the run stops.
  latest_lock now
  [ "$(jq -r --arg p "$project" '.spec.fragments[$p].ref // ""' now/lock.json)" = "$pinned" ] \
    || { echo "::error::${project}'s pin moved since its release was proven; run the rollback again"; exit 1; }
  record_edit() {
    VERSION="$version" FRAGMENT="$fragment" yq -i "
      del(${repository} | .metadata.annotations[\"${key}rollback-backup\"]) |
      (${repository} | .metadata.annotations[\"${key}rollback-version\"]) = strenv(VERSION) |
      (${repository} | .metadata.annotations[\"${key}rollback-fragment\"]) = strenv(FRAGMENT)
    " "$source"
  }
  commit "roll ${project} back to ${version}" record_edit
  echo "${project} rolls back to ${version}, and stays paused"
  ;;

stop)
  why="${3:-}"
  stop_edit() {
    WHY="$why" yq -i "
      del(${repository} | .metadata.annotations[\"${key}rollback-backup\"]) |
      (${repository} | .metadata.annotations[\"${key}paused-reason\"]) = strenv(WHY)
    " "$source"
  }
  commit "stop the rollback of ${project}" stop_edit
  echo "${project} stays where it was, paused"
  ;;

*)
  echo "::error::usage: rollback.sh target|ask|expect|await|record|stop <project> ..."
  exit 2
  ;;
esac
