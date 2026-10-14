#!/usr/bin/env bash
# test-deployments.sh: run deployments.sh against fixtures, with `gh` and
# `cosign` replaced by fakes that record every call and answer as GitHub and
# the registry would. Exits non-zero on the first expectation that fails.
#
# Run from the repository root: bash .github/scripts/test-deployments.sh
set -euo pipefail

root="$(pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/projects/delivery" "$work/projects/app"

# The fake GitHub: deployments listed per repository from $work/listed.json,
# each Deployment's latest status from $work/states.json, ids from a counter.
cat > "$work/bin/gh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=""
[[ " $* " == *" --input - "* ]] && input="$(jq -c .)"
printf '%s\t%s\n' "$*" "$input" >> "$FAKE/calls.log"
path=""; jqf=""; method=GET
while [ $# -gt 0 ]; do
  case "$1" in
    api) ;;
    -X) method="$2"; shift ;;
    --jq) jqf="$2"; shift ;;
    --silent | --input | -) ;;
    -f) shift ;;
    *) [ -z "$path" ] && path="$1" ;;
  esac
  shift
done
answer='{}'
case "$method $path" in
  "GET repos/"*"/deployments?"*)
    repository="${path#repos/}"; repository="${repository%/deployments*}"
    answer="$(jq -c --arg r "$repository" '.[$r] // []' "$FAKE/listed.json")" ;;
  "GET repos/"*"/statuses?"*)
    id="${path%/statuses*}"; id="${id##*/}"
    answer="$(jq -c --arg id "$id" 'if .[$id] then [{state: .[$id]}] else [] end' "$FAKE/states.json")" ;;
  "POST repos/"*"/deployments")
    n="$(cat "$FAKE/next")"; echo $((n + 1)) > "$FAKE/next"; answer="{\"id\": $n}" ;;
esac
if [ -n "$jqf" ]; then jq -r "$jqf" <<< "$answer"; fi
EOF
# The fake registry: a fragment's signature names the repository and commit
# $work/signed.json maps its reference to.
cat > "$work/bin/cosign" << 'EOF'
#!/usr/bin/env bash
ref="$2"
jq -c --arg ref "$ref" '[.[$ref] // empty | {optional: .}]' "$FAKE/signed.json"
EOF
chmod +x "$work/bin/gh" "$work/bin/cosign"

A="$(printf 'a%.0s' $(seq 40))"
B="$(printf 'b%.0s' $(seq 40))"
C="$(printf 'c%.0s' $(seq 40))"
for project in delivery app; do
  printf 'apiVersion: source.toolkit.fluxcd.io/v1\nkind: OCIRepository\nspec:\n  url: oci://ghcr.io/jorisjonkers-dev/render/%s\n  ref:\n    digest: sha256:%s\n' \
    "$project" "$(printf 'd%.0s' $(seq 64))" > "$work/projects/${project}/source.yaml"
done
cat > "$work/lock.json" << EOF
{"spec": {"composedDigest": "sha256:$(printf 'e%.0s' $(seq 64))", "fragments": {
  "delivery": {"ref": "ghcr.io/jorisjonkers-dev/intent-delivery@sha256:1"},
  "app": {"ref": "ghcr.io/jorisjonkers-dev/intent-app@sha256:2"},
  "edge": {"ref": "ghcr.io/jorisjonkers-dev/intent-edge@sha256:3"}}}}
EOF

run() { # run <composition.json body>: deployments.sh in $work, with the fakes
  printf '%s' "$1" > "$work/composition.json"
  : > "$work/calls.log"
  echo 100 > "$work/next"
  (cd "$work" && PATH="$work/bin:$PATH" FAKE="$work" DEPLOY_TOKEN=token OWNER=jorisjonkers-dev \
    FRAGMENT_SIGNER=x RUN=https://github.com/JorisJonkers-dev/estate/actions/runs/1 \
    GITHUB_STEP_SUMMARY="$work/summary.md" bash "$root/.github/scripts/deployments.sh" composition.json lock.json)
}
calls() { grep -c "$1" "$work/calls.log" || true; }
expect() { # expect <description> <actual> <wanted>
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1: got '$2', wanted '$3'"
    exit 1
  fi
  echo "ok: $1"
}

# No Rollout: nothing is called.
echo '{}' > "$work/listed.json"; echo '{}' > "$work/states.json"; echo '{}' > "$work/signed.json"
out="$(run '{"rollouts": []}')"
expect "a composition with no Rollout opens nothing" "$(wc -l < "$work/calls.log" | tr -d ' ')" 0
expect "and says so" "$out" "no pin moved for a Project: no Deployment to open"

# Two Rollouts. delivery has an earlier Deployment still in progress, and its
# repository also released another Project whose Deployment is in progress;
# app has a finished one. app's commit is signed, delivery's too.
cat > "$work/listed.json" << 'EOF'
{"JorisJonkers-dev/delivery": [{"id": 7, "payload": {"project": "delivery"}}, {"id": 8, "payload": {"project": "other"}}],
 "JorisJonkers-dev/home-portal": [{"id": 9, "payload": {"project": "app"}}]}
EOF
echo '{"7": "in_progress", "8": "in_progress", "9": "success"}' > "$work/states.json"
cat > "$work/signed.json" << EOF
{"ghcr.io/jorisjonkers-dev/intent-delivery@sha256:1": {"githubWorkflowRepository": "JorisJonkers-dev/delivery", "githubWorkflowSha": "$A"},
 "ghcr.io/jorisjonkers-dev/intent-app@sha256:2": {"githubWorkflowRepository": "JorisJonkers-dev/home-portal", "githubWorkflowSha": "$B"}}
EOF
run "{\"rollouts\": [
  {\"project\": \"delivery\", \"repository\": \"JorisJonkers-dev/delivery\", \"sha\": \"$A\", \"environment\": \"production\", \"version\": \"0.4.0\"},
  {\"project\": \"app\", \"repository\": \"JorisJonkers-dev/home-portal\", \"sha\": \"$B\", \"environment\": \"production\", \"version\": \"0.12.0\", \"url\": \"https://jorisjonkers.dev\"}]}" > /dev/null
expect "two Rollouts open two Deployments" "$(calls 'POST repos/[^ ]*/deployments --input')" 2
expect "delivery's at its release commit, in production, with no required contexts" \
  "$(grep 'POST repos/JorisJonkers-dev/delivery/deployments --input' "$work/calls.log" | cut -f2 | jq -c '[.ref, .environment, .required_contexts, .production_environment, .payload.version, .payload.artifact[0:44]]')" \
  "[\"$A\",\"production\",[],true,\"0.4.0\",\"ghcr.io/jorisjonkers-dev/render/delivery@sha\"]"
expect "the earlier delivery Deployment in progress is superseded" \
  "$(calls 'POST repos/JorisJonkers-dev/delivery/deployments/7/statuses -f state=inactive -f description=superseded by 0.4.0')" 1
expect "another Project's Deployment on the same repository is left alone" \
  "$(calls 'deployments/8/statuses -f state=inactive')" 0
expect "a finished Deployment is left alone" "$(calls 'deployments/9/statuses -f state=inactive')" 0
expect "each new Deployment's first status is in progress, pinned" \
  "$(grep '/statuses --input' "$work/calls.log" | cut -f2 | jq -sc 'map([.state, .description, .auto_inactive])')" \
  '[["in_progress","delivery 0.4.0 pinned",true],["in_progress","app 0.12.0 pinned",true]]'
expect "app's carries its URL, delivery's none" \
  "$(grep '/statuses --input' "$work/calls.log" | cut -f2 | jq -sc 'map(.environment_url)')" \
  '[null,"https://jorisjonkers.dev"]'

# A Rollout whose fragment was signed at another commit, one claiming a
# repository outside the owner, and one with no fragment in the lock open none.
run "{\"rollouts\": [
  {\"project\": \"delivery\", \"repository\": \"JorisJonkers-dev/delivery\", \"sha\": \"$C\", \"environment\": \"production\", \"version\": \"0.4.1\"},
  {\"project\": \"app\", \"repository\": \"someone-else/home-portal\", \"sha\": \"$B\", \"environment\": \"production\", \"version\": \"0.12.0\"},
  {\"project\": \"notes\", \"repository\": \"JorisJonkers-dev/notes\", \"sha\": \"$A\", \"environment\": \"production\", \"version\": \"1.0.0\"}]}" > "$work/out.txt"
expect "a commit the fragment was not signed at, a foreign repository, and no fragment open nothing" \
  "$(calls 'POST')" 0
expect "and each is a warning" "$(grep -c '::warning::' "$work/out.txt")" 3

echo "all deployments.sh expectations hold"
