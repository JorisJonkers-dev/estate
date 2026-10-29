#!/usr/bin/env bash
#
# Drill JorisJonkers-dev/deploy-kit#371: whether Flagger promotes a blue-green
# Process spread across nodes, with as many replicas as eligible nodes.
#
# A two-replica Deployment is held to two nodes, one pod each, by a required
# anti-affinity term on the hostname with `matchLabelKeys: [pod-template-hash]`
# (the term deploy-kit derives for `across: node`), and a Canary in the
# blue-green shape. The drill reads the term Flagger writes on its `-primary`
# copy, then follows one promotion pod by pod, recording where every pod ran
# and whether any could not be scheduled.
#
#   ./drills/flagger-spread-promotion.sh           the drill
#   ./drills/flagger-spread-promotion.sh --check   its preflight alone
#
# DRILL_NODES="a b" picks the two nodes, DRILL_CONTEXT the kubectl context.

source "$(dirname "${BASH_SOURCE[0]}")/lib/drill.sh"

TOTAL_STAGES=7
NS=drill-371
IMAGE=""
PHASE=""
STARTED=""
declare -A SEEN=() UNSCHEDULABLE_SINCE=() UNSCHEDULABLE_FOR=() UNSCHEDULABLE_WHY=() UNSCHEDULABLE_DONE=()
PLACEMENTS=()   # one row per Canary phase: where every pod was

# ── Checks ────────────────────────────────────────────────────────────────

flagger_ready() {
  kc -n delivery-system get deploy flagger -o json | jq -e '(.status.readyReplicas // 0) >= 1' >/dev/null
}

canary_phase() { kc -n "$NS" get canary drill -o jsonpath='{.status.phase}' 2>/dev/null; }

initialized() {
  PHASE=$(canary_phase)
  HINT="Canary ${PHASE:-has no phase yet}"
  [[ "$PHASE" == Initialized || "$PHASE" == Succeeded ]]
}

# rolled DEPLOYMENT REPLICAS: every replica of DEPLOYMENT updated and ready.
rolled() {
  local d
  d=$(kc -n "$NS" get deploy "$1" -o json 2>/dev/null) || return 1
  HINT=$(jq -r '"\(.status.updatedReplicas // 0) updated, \(.status.readyReplicas // 0) ready of \(.spec.replicas)"' <<<"$d")
  jq -e --argjson n "$2" '.spec.replicas == $n and (.status.updatedReplicas // 0) == $n
    and (.status.readyReplicas // 0) == $n and (.status.replicas // 0) == $n
    and .status.observedGeneration == .metadata.generation' <<<"$d" >/dev/null
}

primary_on_both() {
  local nodes
  nodes=$(kc -n "$NS" get pods -l app=drill-primary -o json | jq -r '.items[]
    | select(.metadata.deletionTimestamp | not) | .spec.nodeName // empty' | sort -u)
  HINT="primary on: ${nodes//$'\n'/, }"
  grep -qx "${NODES[0]}" <<<"$nodes" && grep -qx "${NODES[1]}" <<<"$nodes"
}

pods_tsv() {
  kc -n "$NS" get pods -o json | jq -r '.items[] | [
      .metadata.name,
      (.metadata.labels.app // "-"),
      (.metadata.labels["pod-template-hash"] // "-"),
      (.spec.nodeName // "-"),
      (if .metadata.deletionTimestamp then "Terminating" else .status.phase end),
      (if any(.status.conditions[]?; .type == "Ready" and .status == "True") then "ready" else "not ready" end),
      ((.status.conditions // []) | map(select(.type == "PodScheduled" and .status == "False")) | .[0].message // "")
    ] | @tsv'
}

placement() {
  pods_tsv | awk -F'\t' '$5 != "Terminating" {printf "%s%s %s@%s (%s)", sep, $2, $3, $4, $6; sep = ", "}'
}

# follow_promotion reports every change to the Canary's phase and to every
# pod, and succeeds once the promotion has finished either way.
follow_promotion() {
  local now rows name app hash node phase ready why state key
  now=$EPOCHSECONDS
  rows=$(pods_tsv) || return 1
  local -A current=()
  while IFS=$'\t' read -r name app hash node phase ready why; do
    [[ -n "$name" ]] || continue
    current[$name]=1
    state="$app $hash on $node: $phase, $ready"
    if [[ "${SEEN[$name]:-}" != "$state" ]]; then
      if [[ -z "${SEEN[$name]:-}" ]]; then event "new pod $name · $state"; else event "pod $name · $state"; fi
      SEEN[$name]=$state
    fi
    if [[ -n "$why" ]]; then
      if [[ -z "${UNSCHEDULABLE_SINCE[$name]:-}" ]]; then
        UNSCHEDULABLE_SINCE[$name]=$now
        UNSCHEDULABLE_WHY[$name]=$why
        event "${RED}cannot schedule$RESET $name: $why"
      fi
      UNSCHEDULABLE_FOR[$name]=$((now - UNSCHEDULABLE_SINCE[$name]))
    elif [[ -n "${UNSCHEDULABLE_SINCE[$name]:-}" && "$node" != - && -z "${UNSCHEDULABLE_DONE[$name]:-}" ]]; then
      UNSCHEDULABLE_FOR[$name]=$((now - UNSCHEDULABLE_SINCE[$name]))
      UNSCHEDULABLE_DONE[$name]=1
      event "$name scheduled onto $node after $(_dur "${UNSCHEDULABLE_FOR[$name]}")"
    fi
  done <<<"$rows"
  for key in "${!SEEN[@]}"; do
    [[ -n "${current[$key]:-}" ]] && continue
    event "pod $key gone"
    unset "SEEN[$key]"
  done
  phase=$(canary_phase)
  if [[ "$phase" != "$PHASE" ]]; then
    PHASE=$phase
    event "Canary ${BOLD}$PHASE$RESET"
    PLACEMENTS+=("| $(since) | $PHASE | $(placement) |")
  fi
  HINT="Canary $PHASE"
  case "$PHASE" in
    Succeeded) rolled drill-primary 2 && rolled drill 0 ;;
    Failed) return 0 ;;
    *) return 1 ;;
  esac
}

started() {
  PHASE=$(canary_phase)
  HINT="Canary $PHASE"
  [[ "$PHASE" != Initialized && "$PHASE" != Succeeded && -n "$PHASE" ]]
}

# term_of KIND NAME: the pod anti-affinity a Deployment's template or a pod
# carries, as one line of JSON.
term_of() {
  local path='.spec.affinity.podAntiAffinity'
  [[ "$1" == deploy ]] && path='.spec.template.spec.affinity.podAntiAffinity'
  kc -n "$NS" get "$1" "$2" -o json | jq -c "$path // null"
}

keeps_keys() { jq -e '[.. | objects | select(has("matchLabelKeys")) | .matchLabelKeys[]] | index("pod-template-hash") != null' <<<"$1" >/dev/null; }

# ── 1 ─────────────────────────────────────────────────────────────────────
drill_start 371 "a Flagger promotion of a Process spread across nodes" "$@"
stage "Preflight"
preflight_cluster
wait_until "Flagger is running in delivery-system" 30 flagger_ready || die "Flagger is not Ready"
kc get crd canaries.flagger.app >/dev/null 2>&1 || die "no Canary CRD"
SERVER=$(kc version -o json 2>/dev/null | jq -r .serverVersion.minor | tr -cd '0-9')
((SERVER >= 31)) || die "matchLabelKeys on pod affinity needs Kubernetes 1.31 or newer; the server is 1.$SERVER"
ok "Kubernetes 1.$SERVER: matchLabelKeys on pod affinity is on by default"
IMAGE=$(kc -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}') \
  || die "cannot read kube-system/coredns's image"
ok "workload image $IMAGE ${DIM}(k3s's own CoreDNS, already on every node)$RESET"
pick_nodes "" enschede-pi-3 enschede-pi-2
clear_leftovers "$NS"
check_only

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "A two-replica Process, one pod per node, under a blue-green Canary"
cat >"$RUN_DIR/setup.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    estate.jorisjonkers.dev/drill: "371"
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: drill
  namespace: $NS
data:
  Corefile: |
    .:1053 {
        chaos {\$NODE_NAME}
        health :8080
        ready :8181
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: drill
  namespace: $NS
spec:
  replicas: 2
  selector:
    matchLabels: {app: drill}
  template:
    metadata:
      labels: {app: drill}
    spec:
      automountServiceAccountToken: false
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - {key: kubernetes.io/hostname, operator: In, values: [${NODES[0]}, ${NODES[1]}]}
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels: {app: drill}
              matchLabelKeys: [pod-template-hash]
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: server
          image: $IMAGE
          args: ["-conf", "/etc/coredns/Corefile"]
          env:
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
          ports:
            - {name: http, containerPort: 8080}
          readinessProbe:
            httpGet: {path: /ready, port: 8181}
            periodSeconds: 2
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {memory: 64Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL], add: [NET_BIND_SERVICE]}
          volumeMounts:
            - {name: config, mountPath: /etc/coredns}
      volumes:
        - name: config
          configMap: {name: drill}
---
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: drill
  namespace: $NS
spec:
  provider: kubernetes
  targetRef: {apiVersion: apps/v1, kind: Deployment, name: drill}
  progressDeadlineSeconds: 300
  service: {port: 8080, portName: http, targetPort: http}
  analysis: {interval: 15s, iterations: 2, threshold: 2}
EOF
TEARDOWN="$KC delete namespace $NS --ignore-not-found --wait=false"
change "Create the Deployment and its Canary" <<<"$KC apply -f $RUN_DIR/setup.yaml"
need "Flagger initialises the Canary" 900 initialized || die "Flagger did not initialise the Canary"
need "drill-primary rolled out: 2 of 2 ready" 600 rolled drill-primary 2 || die "drill-primary did not roll out"
need "one primary pod on each of ${NODES[0]} and ${NODES[1]}" 120 primary_on_both || die "the primary is not spread across both nodes"
need "Flagger scaled the drill Deployment to 0" 300 rolled drill 0 || true
PLACEMENTS+=("| $(since) | Initialized | $(placement) |")

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "The term Flagger writes on the primary"
term_of deploy drill | jq . >"$RUN_DIR/term-source.json"
TERM_PRIMARY=$(term_of deploy drill-primary)
PRIMARY_POD=$(kc -n "$NS" get pods -l app=drill-primary -o jsonpath='{.items[0].metadata.name}')
TERM_POD=$(term_of pod "$PRIMARY_POD")
printf '%s\n' "$TERM_PRIMARY" | jq . >"$RUN_DIR/term-primary.json"
printf '%s\n' "$TERM_POD" | jq . >"$RUN_DIR/term-primary-pod.json"
if keeps_keys "$TERM_PRIMARY"; then
  ok "drill-primary keeps matchLabelKeys: [pod-template-hash]"
else
  bad "drill-primary dropped matchLabelKeys: Flagger's copy lost it"
fi
note "selector on drill-primary: $(jq -c '[.requiredDuringSchedulingIgnoredDuringExecution[]?.labelSelector]' <<<"$TERM_PRIMARY")"
note "selector on pod $PRIMARY_POD: $(jq -c '[.requiredDuringSchedulingIgnoredDuringExecution[]?.labelSelector]' <<<"$TERM_POD")"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "Promote a new revision"
change "Change the template, so Flagger analyses and promotes it" <<<"$KC -n $NS patch deployment drill --type merge -p '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"drill.estate.jorisjonkers.dev/revision\":\"$RUN_ID\"}}}}}'"
need "Flagger starts the analysis" 600 started || die "Flagger did not start an analysis"
STARTED=$EPOCHSECONDS
PLACEMENTS+=("| $(since) | $PHASE | $(placement) |")
wait_until "the promotion finishes" 1200 follow_promotion || true
FINAL_PHASE=$PHASE
DURATION=$((EPOCHSECONDS - STARTED))

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "After the promotion"
TERM_AFTER=$(term_of deploy drill-primary)
printf '%s\n' "$TERM_AFTER" | jq . >"$RUN_DIR/term-primary-after.json"
if [[ "$TERM_AFTER" == "$TERM_PRIMARY" ]]; then
  ok "the primary's term is the same after the promotion"
else
  warn "the primary's term changed in the promotion (term-primary-after.json)"
fi
FINAL_PLACEMENT=$(placement)
FINAL_AT=$(since)
note "now: $FINAL_PLACEMENT"
UNSCHEDULED_ROWS=()
for name in "${!UNSCHEDULABLE_SINCE[@]}"; do
  outcome="and never was"
  [[ -n "${UNSCHEDULABLE_DONE[$name]:-}" ]] && outcome="before it was"
  UNSCHEDULED_ROWS+=("- \`$name\` could not be scheduled for $(_dur "${UNSCHEDULABLE_FOR[$name]}") $outcome: $(tr '\n' ' ' <<<"${UNSCHEDULABLE_WHY[$name]}")")
done

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "Teardown"
change "Remove the drill's namespace" <<<"$TEARDOWN"
LEFT=""
need "namespace $NS gone" 600 absent namespace "$NS" || LEFT=" namespace $NS"
TEARDOWN_DONE=yes

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "Result"
result_head "a Flagger promotion of a Process spread across nodes"
res "A two-replica Deployment held to \`${NODES[0]}\` and \`${NODES[1]}\`, with a required anti-affinity term on \`kubernetes.io/hostname\` carrying \`matchLabelKeys: [pod-template-hash]\`, under a blue-green Canary (\`provider: kubernetes\`, 2 iterations of 15 s, no webhooks, so the Release Gate took no part)." "" \
  "### The term on the primary" "" \
  "Flagger's \`drill-primary\` $(keeps_keys "$TERM_PRIMARY" && printf 'keeps' || printf '**drops**') \`matchLabelKeys\`$( [[ "$TERM_AFTER" == "$TERM_PRIMARY" ]] && printf ', and the promotion left it unchanged' || printf '; the promotion changed it')." "" \
  '```json' "$(jq . <<<"$TERM_PRIMARY")" '```' "" \
  "On its pod \`$PRIMARY_POD\`, after admission:" "" \
  '```json' "$(jq . <<<"$TERM_POD")" '```' "" \
  "### The promotion" "" \
  "It ended **$FINAL_PHASE** after $(_dur "$DURATION"). Where every pod was at each phase (\`app hash@node\`):" "" \
  "| time | Canary | pods |" "|---|---|---|" "${PLACEMENTS[@]}" "| $FINAL_AT | after | $FINAL_PLACEMENT |" ""
if ((${#UNSCHEDULED_ROWS[@]})); then
  res "Pods that could not be scheduled:" "" "${UNSCHEDULED_ROWS[@]}" ""
else
  res "No pod was ever unschedulable." ""
fi
if [[ "$FINAL_PHASE" == Succeeded ]] && ((${#UNSCHEDULED_ROWS[@]} == 0)) && keeps_keys "$TERM_PRIMARY"; then
  VERDICT="the promotion is clean: Flagger keeps the revision key on the primary, and the surge pod placed beside the old one."
else
  VERDICT="the promotion is not clean (phase $FINAL_PHASE, ${#UNSCHEDULED_ROWS[@]} unschedulable pod(s)); the timeline above is what to choose between the revision key and a rollout without surge on."
fi
res "**Verdict:** $VERDICT" "" "### Done when" \
  "- [x] The term Flagger writes on the primary is recorded." \
  "- [$([[ "$FINAL_PHASE" == Succeeded || "$FINAL_PHASE" == Failed ]] && printf x || printf ' ')] One promotion is observed from start to finish, with pod placement at each step." \
  "- [x] The result is posted here." \
  "- [$([[ -z "$LEFT" ]] && printf x || printf ' ')] Nothing the drill created is left in the cluster.${LEFT:+ Left:$LEFT}"
say "Verdict: $VERDICT"
show_result
drill_done
