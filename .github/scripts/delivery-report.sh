#!/usr/bin/env bash
# delivery-report.sh summary|verdict: what one delivery to production did, for
# a human to review, read from what composition wrote
# (deploy-kit spec/v1/55-delivery.md#notifications).
#
#   summary  Markdown on stdout, for the run's job summary: one row per
#            Project with the release it ran before this run, the release it
#            runs after it, whether its pin moved, and why not when it did
#            not. A composition that refused outright says so, with what it
#            refused on.
#   verdict  exits 1, with one error annotation per Project, when composition
#            isolated any Project: a refused fragment, a missing one or a stale
#            one. It runs last, so the run is red only after everything else
#            was delivered; a red run then means a Project needs a fix, never
#            that the others were held back.
#
# Reads, from the job's working directory: composed/composition.json and
# composed/lock.json (absent when composition refused), refusal.txt (what it
# refused on), fragments/<project>/fragment.yml and platform-fragment/ (the
# newest fragment of each Project), and the pin sources as BASE, the commit
# the run checked out, committed them. Reads BASE, DELIVERED (the pin commit
# this run pushed, or empty), PUBLISHED ("true" when the run was allowed to
# publish), LOCK_DIGEST, RUN, GITHUB_SERVER_URL and GITHUB_REPOSITORY.
#
# Every value that comes from a fragment is held to the shape it must have
# before it is printed, here or in a log line; one that is not prints as `?`.
set -euo pipefail
shopt -s nullglob

mode="${1:-}"
composition=composed/composition.json
lock=composed/lock.json

project_re='^[a-z0-9_]([a-z0-9.-]*[a-z0-9])?$'
code_re='^E_[A-Z0-9_]+$'

verdict() {
  [ -f "$lock" ] || return 0
  local failed=0 project codes
  while IFS=$'\t' read -r project codes; do
    [ -n "$project" ] || continue
    [[ "$project" =~ $project_re ]] || project='?'
    [[ "$codes" =~ ^E_[A-Z0-9_,]+$ ]] || codes='?'
    echo "::error title=${project} isolated::${project} is isolated (${codes//,/, }): its pin stays where it was until a release composes. See the run summary and the issue the report opened."
    failed=1
  done < <(jq -r '.spec.isolated // {} | to_entries[] | [.key, (.value.codes | join(","))] | @tsv' "$lock")
  return "$failed"
}

summary() {
  : "${BASE:?}" "${RUN:?}" "${GITHUB_SERVER_URL:?}" "${GITHUB_REPOSITORY:?}"
  local server="$GITHUB_SERVER_URL"

  if [ ! -f "$composition" ] || [ ! -f "$lock" ]; then
    echo "## Production: composition refused, nothing delivered"
    echo
    echo "Composition refused the estate as a whole: the Platform document, or an error no single fragment caused. No pin moved and no artifact was published."
    if [ -s refusal.txt ]; then
      echo
      echo '~~~~text'
      head -c 60000 refusal.txt
      echo '~~~~'
    fi
    return 0
  fi

  # The release each Project's pin source named before this run, from the
  # Rollout identity composition writes on it.
  local pinned='{}' source project version
  for source in $(git ls-tree --name-only -r "$BASE" -- projects | grep '/source\.yaml$' || true); do
    project="$(basename "$(dirname "$source")")"
    version="$(git show "${BASE}:${source}" \
      | yq 'select(.kind == "Kustomization") | .metadata.annotations["event.toolkit.fluxcd.io/version"] // ""' \
      | grep -m1 . || true)"
    pinned="$(jq --arg p "$project" --arg v "$version" '. + {($p): $v}' <<<"$pinned")"
  done

  # The newest release each Project published, whether or not it composed.
  local published='{}' fragment
  for fragment in platform-fragment/fragment.yml fragments/*/fragment.yml; do
    published="$(jq --arg p "$(yq '.spec.project' "$fragment")" --arg v "$(yq '.spec.version' "$fragment")" \
      '. + {($p): $v}' <<<"$published")"
  done

  local legacy='[]' platform=''
  if [ -f platform-fragment/platform.intent.yml ]; then
    legacy="$(yq -o=json '.handover.legacy // []' platform-fragment/platform.intent.yml)"
    platform="$(yq '.metadata.project' platform-fragment/platform.intent.yml)"
  fi

  jq -r \
    --slurpfile lock "$lock" \
    --argjson pinned "$pinned" \
    --argjson published "$published" \
    --argjson legacy "$legacy" \
    --arg platform "$platform" \
    --arg delivered "${DELIVERED:-}" \
    --arg allowed "${PUBLISHED:-false}" \
    --arg lockDigest "${LOCK_DIGEST:-}" \
    --arg base "$BASE" \
    --arg run "$RUN" \
    --arg server "$server" \
    --arg estate "$GITHUB_REPOSITORY" \
    --arg projectRe "$project_re" \
    --arg codeRe "$code_re" '
    def safe($re): if type == "string" and test($re) then . else "?" end;
    def ver: safe("^[0-9]+\\.[0-9]+\\.[0-9]+$");
    def short: .[0:7];
    def commit($repository; $sha):
      if ($repository | test("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$")) and ($sha | test("^[0-9a-f]{40}$"))
      then "[\($repository)@\($sha | short)](\($server)/\($repository)/commit/\($sha))"
      else "?" end;

    $lock[0] as $lock
    | ($lock.spec.isolated // {}) as $isolated
    | ($lock.metadata.cluster | safe($projectRe)) as $cluster
    | (.artifacts | map({key: .name, value: .}) | from_entries) as $artifacts
    | (.rollouts | map({key: .project, value: .}) | from_entries) as $rollouts
    | (.conditions | map(select(.condition != "isolated")) | map({key: .project, value: .}) | from_entries) as $held
    | ($delivered | test("^[0-9a-f]{40}$")) as $pushed
    | ([$lock.spec.fragments | keys[]] + [$isolated | keys[]] + [$artifacts | keys[]] | unique) as $projects

    # One row a Project.
    | [ $projects[] as $p
        | ($lock.spec.fragments[$p] // null) as $f
        | ($artifacts[$p] // null) as $a
        | ($rollouts[$p] // null) as $r
        | ($pinned[$p] // "") as $before
        | ($a != null and $a.moves) as $moves
        | {
            project: ($p | safe($projectRe)),
            moves: $moves,
            refused: ($isolated[$p] != null),
            release: (
              if $p == "_estate" then "estate-scoped"
              elif $r != null and $before != "" and $before != $r.version then "\($before | ver) → **\($r.version | ver)**"
              elif $r != null then "**\($r.version | ver)**"
              elif $a != null and $before != "" then ($before | ver)
              elif $f != null then ($f.version | ver)
              else "none" end),
            notes: ([
              (if $a != null and $f != null and $before != "" and $r == null and $f.version != $before
               then "composed \($f.version | ver), not delivered" else empty end),
              (if $published[$p] != null and ($f == null or $published[$p] != $f.version)
               then "newest \($published[$p] | ver), \(if $isolated[$p] != null then "refused" else "not composed" end)" else empty end)
            ] | join("<br>")),
            pin: (
              if $a == null then
                (if ($legacy | index($p)) != null then "not on the estate path yet"
                 elif $p == $platform then "the Platform document"
                 else "none" end)
              elif $moves and $pushed then "moved"
              elif $moves and $allowed == "true" then "**not moved**: the run failed before the pin commit"
              elif $moves then "would move (not published from this ref)"
              else "stays" end),
            state: (
              if $isolated[$p] != null then
                "**refused**: \([$isolated[$p].codes[] | safe($codeRe)] | join(", "))"
                + (if $f != null then ", stays at \($f.version | ver)" else "" end)
              elif $held[$p].condition == "paused" then "paused"
              elif $held[$p].condition == "rolled-back" then "rolled back, held"
              elif $moves and $pushed then "delivered"
              elif $moves then "not delivered"
              elif $a != null then "unchanged"
              elif ($legacy | index($p)) != null then "composed; fleet-infra delivers it"
              else "composed" end),
            from: (if $f != null then commit($f.repository; $f.sourceSha) else "" end)
          } ] as $rows

    | ($rows | map(select(.moves and .project != "_estate"))) as $moving
    | ($rows | map(select(.refused))) as $refused
    | ($moving | map("\(.project) \(.release | gsub("\\*"; ""))") | join(", ")) as $what

    # The headline: what changed in production, in one line.
    | (if ($moving | length) == 0 and ($rows | map(select(.moves)) | length) == 0 then "nothing to deliver, every pin stays"
       elif $pushed then "delivered \(if $what == "" then "the estate-scoped artifact" else $what end)"
       elif $allowed == "true" then "**not delivered**: \(if $what == "" then "the estate-scoped artifact" else $what end)"
       else "would deliver \(if $what == "" then "the estate-scoped artifact" else $what end)" end) as $headline
    | "## \($cluster[0:1] | ascii_upcase)\($cluster[1:]): \($headline)",
      "",
      (if ($refused | length) > 0
       then "**\($refused | length) Project\(if ($refused | length) == 1 then " was" else "s were" end) refused** and stay\(if ($refused | length) == 1 then "s" else "" end) where \(if ($refused | length) == 1 then "it was" else "they were" end): \($refused | map(.project) | join(", ")). The run fails once everything else is delivered."
       else "No Project was refused." end),
      "",
      "| Project | Release | Pin | Outcome | Released from |",
      "|---|---|---|---|---|",
      ($rows[] | "| \(.project) | \(.release)\(if .notes != "" then "<br>\(.notes)" else "" end) | \(.pin) | \(.state) | \(.from) |"),
      "",
      "- Composed from [\($estate)@\($base | short)](\($server)/\($estate)/commit/\($base)) with deploy-kit \($lock.spec.toolkitVersion | ver), on the cluster `\($cluster)`.",
      (if $pushed then "- The pin commit, which is the deploy: [\($estate)@\($delivered | short)](\($server)/\($estate)/commit/\($delivered)). Flux applies it on its next poll."
       else "- No pin commit was pushed." end),
      (if ($lockDigest | test("^sha256:[0-9a-f]{64}$")) then "- The lock: `ghcr.io/jorisjonkers-dev/composed@\($lockDigest)`." else empty end),
      "- [The run](\($run))."
    ' "$composition"
}

record() {
  local toolkit snapshot
  toolkit="$(yq '."deploy-kit" // ""' toolkit.yml 2>/dev/null || true)"
  snapshot="$(yq '.capturedAt // ""' cluster-state.yml 2>/dev/null || true)"

  if [ ! -f "$composition" ] || [ ! -f "$lock" ]; then
    jq -n --arg toolkit "$toolkit" --arg snapshot "$snapshot" '
      def safe($re): if type == "string" and test($re) then . else null end;
      {refused: true, toolkit: ($toolkit | safe("^[0-9]+\\.[0-9]+\\.[0-9]+$")),
       snapshotAt: ($snapshot | safe("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$")), moved: [], fragments: []}'
    return 0
  fi

  # The newest release each Project published, and when, whether or not it composed.
  local published='{}' fragment dir
  for fragment in platform-fragment/fragment.yml fragments/*/fragment.yml; do
    dir="$(dirname "$fragment")"
    published="$(jq --arg p "$(yq '.spec.project' "$fragment")" --arg v "$(yq '.spec.version' "$fragment")" \
      --arg at "$(head -n 1 "${dir}/published" 2>/dev/null || true)" '. + {($p): {version: $v, at: $at}}' <<<"$published")"
  done

  jq \
    --slurpfile lock "$lock" \
    --argjson published "$published" \
    --arg delivered "${DELIVERED:-}" \
    --arg lockDigest "${LOCK_DIGEST:-}" \
    --arg toolkit "$toolkit" \
    --arg snapshot "$snapshot" \
    --arg projectRe "$project_re" \
    --arg codeRe "$code_re" '
    def safe($re): if type == "string" and test($re) then . else "?" end;
    def maybe($re): if type == "string" and test($re) then . else null end;
    def ver: safe("^[0-9]+\\.[0-9]+\\.[0-9]+$");
    def time: maybe("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$");
    # Codes that say the fragment is too old, or absent, rather than refused.
    def stale: ["E_PARTICIPANT_STALE", "E_PARTICIPANT_MISSING"];

    $lock[0] as $lock
    | ($lock.spec.isolated // {}) as $isolated
    | (.artifacts | map({key: .name, value: .}) | from_entries) as $artifacts
    | (.conditions | map(select(.condition != "isolated")) | map({key: .project, value: .}) | from_entries) as $held
    | ($delivered | test("^[0-9a-f]{40}$")) as $pushed
    | ([$lock.spec.fragments | keys[]] + [$isolated | keys[]] + [$artifacts | keys[]] | unique
       | map(select(. != "_estate"))) as $projects
    | {
        refused: false,
        toolkit: ($lock.spec.toolkitVersion // $toolkit | maybe("^[0-9]+\\.[0-9]+\\.[0-9]+$")),
        snapshotAt: ($snapshot | time),
        lock: ($lockDigest | maybe("^sha256:[0-9a-f]{64}$")),
        moved: [$projects[] | select($pushed and ($artifacts[.].moves // false)) | safe($projectRe)],
        fragments: [ $projects[] as $p
          | ($isolated[$p].codes // []) as $codes
          | ($published[$p] // null) as $newest
          | ($artifacts[$p].moves // false) as $moves
          | {
              project: ($p | safe($projectRe)),
              version: (if $codes != [] and $newest != null then $newest.version
                        elif $lock.spec.fragments[$p] != null then $lock.spec.fragments[$p].version
                        elif $newest != null then $newest.version
                        else null end | if . == null then null else ver end),
              outcome: (if $codes != [] then (if any($codes[]; IN(stale[])) then "stale" else "isolated" end)
                        elif $held[$p] != null then "held"
                        elif $moves and $pushed then "moved"
                        else "unchanged" end),
              reason: (if $codes != [] then ([$codes[] | safe($codeRe)] | join(", "))
                       elif $held[$p].condition == "paused" then "paused"
                       elif $held[$p].condition == "rolled-back" then "rolled back, held"
                       elif $moves and ($pushed | not) then "not delivered: the run failed before the pin commit"
                       else null end),
              published: ($newest.at // null | time)
            } ]
      }' "$composition"
}

case "$mode" in
summary) summary ;;
verdict) verdict ;;
record) record ;;
*)
  echo "::error::usage: delivery-report.sh summary|verdict|record"
  exit 2
  ;;
esac
