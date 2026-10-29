#!/usr/bin/env bash
#
# Drill JorisJonkers-dev/deploy-kit#372: how long DNS goes unanswered when the
# node announcing one pool address fails, with two replicas behind it.
#
# Two DNS responders on two Enschede nodes stand behind one LoadBalancer
# Service with the Local traffic policy. Each is k3s's own CoreDNS image,
# already on every node, answering `version.bind` (class CHAOS) with its
# node's name. This machine asks ten times a second, so the log says who
# answered, and when nobody did. The gap is measured twice: when the pod on the
# announcing node is deleted, and when that node drops off the network.
#
# Run it from a machine on the Enschede LAN:
#
#   ./drills/pool-address-failover.sh           the drill
#   ./drills/pool-address-failover.sh --check   its preflight alone
#
# DRILL_NODES="a b" picks the two nodes, DRILL_ADDRESS the Service's address,
# DRILL_CONTEXT the kubectl context.

source "$(dirname "${BASH_SOURCE[0]}")/lib/drill.sh"

TOTAL_STAGES=8
NS=drill-372
LAN_POOL=${DRILL_POOL:-enschede-lan}
POOL=""
ADDRESS=""
OWN_POOL=""
IMAGE=""
ANNOUNCER=""
PROBE_LOG=""
FAILED_NODE=""
NOT_READY_AT=""
CLIENT=""

probe() { python3 -I "$DRILLS/lib/probe.py" "$@"; }

# ── Checks ────────────────────────────────────────────────────────────────

speaker_on() {
  kc -n metallb-system get pods -l app.kubernetes.io/component=speaker \
    --field-selector "spec.nodeName=$1" -o json \
    | jq -e 'any(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' >/dev/null
}

# lan_answers succeeds when one of the LAN pool's addresses answers DNS from
# here: proof this machine is on the LAN, not merely on a network that uses
# the same range.
lan_answers() {
  local address
  for address in $(lb_addresses); do
    if [[ "$(dig +time=1 +tries=1 +short "@$address" "$ESTATE_LAN_NAME" A 2>/dev/null)" =~ ^[0-9.]+ ]]; then
      HINT="$address answers"
      return 0
    fi
  done
  HINT="no LAN address answers from here"
  return 1
}
ESTATE_LAN_NAME=${DRILL_LAN_NAME:-jorisjonkers.dev}

lb_addresses() {
  kc get svc -A -o json | jq -r --arg pool "$LAN_POOL" '.items[]
    | select(.spec.type == "LoadBalancer")
    | select((.metadata.annotations["metallb.io/ip-allocated-from-pool"] // "") == $pool)
    | (.status.loadBalancer.ingress // [])[].ip'
}

# free_in_pool POOL prints the pool's addresses no Service holds or asks for.
free_in_pool() {
  local pools used
  pools=$(kc get ipaddresspools.metallb.io -A -o json) || return 1
  used=$(kc get svc -A -o json | jq -c '[.items[] | select(.spec.type == "LoadBalancer")
    | ((.status.loadBalancer.ingress // [])[].ip),
      ((.metadata.annotations["metallb.io/loadBalancerIPs"] // "") | split(",")[])]
    | map(select(. != ""))') || return 1
  python3 -I -c '
import ipaddress, json, sys
pools, used, name = json.loads(sys.argv[1]), set(json.loads(sys.argv[2])), sys.argv[3]
for pool in pools["items"]:
    if pool["metadata"]["name"] != name:
        continue
    for block in pool["spec"].get("addresses", []):
        if "-" in block:
            first, last = (ipaddress.ip_address(a.strip()) for a in block.split("-"))
            addresses = (ipaddress.ip_address(n) for n in range(int(first), int(last) + 1))
        else:
            addresses = ipaddress.ip_network(block, strict=False).hosts()
        for address in addresses:
            if str(address) not in used:
                print(address)
' "$pools" "$used" "$1"
}

pool_has_free() {
  local free
  free=$(free_in_pool "$LAN_POOL") || return 1
  [[ -n "$free" ]] || { HINT="$LAN_POOL has no free address yet"; return 1; }
  ADDRESS=$(head -n 1 <<<"$free")
}

# route_iface ADDRESS prints the interface this machine reaches ADDRESS on.
route_iface() {
  if command -v route >/dev/null 2>&1 && route -n get "$1" >/dev/null 2>&1; then
    route -n get "$1" | awk '/interface:/{print $2}'
  else
    ip route get "$1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p'
  fi
}

iface_address() {
  if command -v ipconfig >/dev/null 2>&1; then ipconfig getifaddr "$1"
  else ip -4 -o addr show dev "$1" | awk '{print $4}' | cut -d/ -f1 | head -n 1
  fi
}

arp_mac() {
  if command -v arp >/dev/null 2>&1; then
    arp -n "$1" 2>/dev/null | awk '/ at /{print $4; exit}'
  else
    ip neigh show "$1" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i+1)}'
  fi
}

responders_ready() {
  local pods node ready
  pods=$(kc -n "$NS" get pods -l app=responder -o json) || return 1
  ready=$(jq -r '.items[] | select(.metadata.deletionTimestamp | not)
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .spec.nodeName' <<<"$pods" | sort -u)
  HINT=$(jq -r '[.items[] | "\(.spec.nodeName // "unscheduled"): \(
      if any(.status.conditions[]?; .type == "Ready" and .status == "True") then "ready"
      else (.status.containerStatuses[0].state.waiting.reason // .status.phase) end)"] | join(", ")' <<<"$pods")
  for node in "${NODES[@]}"; do grep -qx "$node" <<<"$ready" || return 1; done
}

service_has_address() {
  local got
  got=$(kc -n "$NS" get svc responder -o jsonpath='{.status.loadBalancer.ingress[*].ip}' 2>/dev/null)
  HINT=${got:-no address yet}
  [[ " $got " == *" $ADDRESS "* ]]
}

announcer() {
  kc -n metallb-system get servicel2statuses.metallb.io -o json | jq -r --arg ns "$NS" '.items[]
    | select(.status.serviceNamespace == $ns and .status.serviceName == "responder") | .status.node' | head -n 1
}
announcer_known() { ANNOUNCER=$(announcer) && [[ -n "$ANNOUNCER" ]]; HINT=${ANNOUNCER:-none yet}; [[ -n "$ANNOUNCER" ]]; }

answers_here() { HINT=$(probe once "$ADDRESS" 2>/dev/null) && [[ -n "$HINT" ]]; }

steady() {
  local tail
  tail=$(probe tail "$PROBE_LOG" 10) || return 1
  HINT=$(jq -r '"\(.streak) in a row, last from \(.last_node // "nobody")"' <<<"$tail")
  (($(jq -r .streak <<<"$tail") >= $1))
}

watch_failed_node() {
  [[ -n "$FAILED_NODE" && -z "$NOT_READY_AT" ]] || return 0
  node_ready "$FAILED_NODE" && return 0
  NOT_READY_AT=$EPOCHSECONDS
  event "Kubernetes marks $FAILED_NODE NotReady"
}

# answers_stopped FROM_MS succeeds once a query after FROM_MS went unanswered.
answers_stopped() {
  local gap
  watch_failed_node
  gap=$(probe gap "$PROBE_LOG" "$1") || return 1
  HINT="every query answered so far"
  (($(jq -r .misses <<<"$gap") > 0))
}

# answers_back FROM_MS succeeds once a stretch of misses after FROM_MS has
# ended in a steady run of answers; with QUIET_OK set, also when 20 seconds
# passed with no miss at all.
answers_back() {
  local gap
  watch_failed_node
  gap=$(probe gap "$PROBE_LOG" "$1") || return 1
  if (($(jq -r .misses <<<"$gap") == 0)); then
    HINT="no query unanswered yet"
    [[ -n "${QUIET_OK:-}" ]] && ((EPOCHSECONDS - $1 / 1000 >= 20))
    return
  fi
  HINT="$(jq -r .misses <<<"$gap") unanswered"
  [[ "$(jq -r .open <<<"$gap")" == false ]] && steady 10
}

pod_going() {
  local out
  if out=$(kc -n "$NS" get pod "$1" -o jsonpath='{.metadata.deletionTimestamp}' 2>&1); then
    [[ -n "$out" ]]
  else
    grep -q NotFound <<<"$out"
  fi
}

address_silent() { ! probe once "$ADDRESS" >/dev/null 2>&1; }

no_l2_status() { [[ -z "$(announcer)" ]]; }

# measure LABEL FROM_MS records the longest gap after FROM_MS as GAP_<LABEL>.
measure() {
  local gap
  gap=$(probe gap "$PROBE_LOG" "$2")
  printf -v "GAP_$1" '%s' "$gap"
  event "$(jq -r '"no answer for \(.gap_ms / 1000 * 10 | floor / 10) s (\(.misses) queries): \(.before.node // "?") → \(.after.node // "nobody yet")"' <<<"$gap")"
}

# ── 1 ─────────────────────────────────────────────────────────────────────
drill_start 372 "the failover gap of one pool address" "$@"
stage "Preflight"
preflight_cluster
require_tools python3 dig
IMAGE=$(kc -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}') \
  || die "cannot read kube-system/coredns's image"
ok "responder image $IMAGE ${DIM}(k3s's own CoreDNS, already on every node)$RESET"
pick_nodes "platform.jorisjonkers.dev/site=enschede" enschede-pi-3 enschede-pi-2
for node in "${NODES[@]}"; do
  speaker_on "$node" || die "no Ready MetalLB speaker on $node"
done
ok "a MetalLB speaker is Ready on both"
kc get ipaddresspools.metallb.io -n metallb-system "$LAN_POOL" >/dev/null 2>&1 \
  || die "no IPAddressPool $LAN_POOL (DRILL_POOL names another)"
wait_until "this machine is on the Enschede LAN: a LAN address answers DNS" 15 lan_answers \
  || die "no address in $LAN_POOL answers DNS from here. Run the drill from the Enschede LAN; on macOS,
    also check System Settings › Privacy & Security › Local Network allows this terminal"
clear_leftovers "$NS"
check_only

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "An address for the drill"
if [[ -n "${DRILL_ADDRESS:-}" ]] && free_in_pool "$LAN_POOL" | grep -qx "$DRILL_ADDRESS"; then
  ADDRESS=$DRILL_ADDRESS
  POOL=$LAN_POOL
elif [[ -z "${DRILL_ADDRESS:-}" ]] && pool_has_free; then
  POOL=$LAN_POOL
else
  if [[ -z "${DRILL_ADDRESS:-}" ]]; then
    warn "every address in $LAN_POOL is taken: $(lb_addresses | tr '\n' ' ')"
    say "The drill needs one LAN address of its own. Either:"
    step "${BOLD}a${RESET}  grow $LAN_POOL by one address in fleet-infra; Flux applies it, and this drill"
    say "    waits for the free address and goes on. Nothing is applied by hand."
    step "${BOLD}b${RESET}  a pool of one address for the drill alone, which you apply now and the teardown"
    say "    removes. Quicker, but a MetalLB object written by hand for the drill's length."
    choose "Grow the pool (a) or a drill pool (b)?" a b
  else
    CHOICE=b
  fi
  if [[ "$CHOICE" == a ]]; then
    shout "Add one unused LAN address, outside the router's DHCP range, to $LAN_POOL in fleet-infra."
    need "a free address in $LAN_POOL" 0 pool_has_free || die "no free address in $LAN_POOL"
    POOL=$LAN_POOL
  else
    ADDRESS=${DRILL_ADDRESS:-}
    [[ -z "$ADDRESS" ]] && say "Pick an address on the LAN that nothing uses, outside the router's DHCP range."
    while :; do
      [[ -n "$ADDRESS" ]] || ask ADDRESS "Address for the drill:"
      if [[ ! "$ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "${ADDRESS:-nothing} is not an IPv4 address"
      elif lb_addresses | grep -qx "$ADDRESS"; then
        warn "$ADDRESS is a Service's address already"
      elif ping -c 1 -t 1 "$ADDRESS" >/dev/null 2>&1; then
        warn "$ADDRESS answers ping: something uses it"
      else
        break
      fi
      [[ -n "${DRILL_ADDRESS:-}" ]] && die "DRILL_ADDRESS=$DRILL_ADDRESS cannot be the drill's address"
      ADDRESS=""
    done
    ok "$ADDRESS answers nothing"
    POOL=drill-372
    OWN_POOL=yes
    cat >"$RUN_DIR/pool.yaml" <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: $POOL
  namespace: metallb-system
  labels:
    estate.jorisjonkers.dev/drill: "372"
spec:
  addresses: ["$ADDRESS/32"]
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: $POOL
  namespace: metallb-system
  labels:
    estate.jorisjonkers.dev/drill: "372"
spec:
  ipAddressPools: [$POOL]
EOF
    TEARDOWN="$KC -n metallb-system delete l2advertisement,ipaddresspool $POOL --ignore-not-found"
    hand "Create the drill's one-address pool" <<<"$KC apply -f $RUN_DIR/pool.yaml"
    need "IPAddressPool $POOL exists" 300 kc -n metallb-system get ipaddresspools.metallb.io "$POOL" \
      || die "no pool $POOL"
  fi
fi
CLIENT_IFACE=$(route_iface "$ADDRESS")
[[ -n "$CLIENT_IFACE" && "$CLIENT_IFACE" != utun* && "$CLIENT_IFACE" != tailscale* ]] \
  || die "this machine reaches $ADDRESS through ${CLIENT_IFACE:-nothing}, not the LAN"
CLIENT="$(iface_address "$CLIENT_IFACE") on $CLIENT_IFACE"
ok "the drill's address is $BOLD$ADDRESS$RESET from pool $POOL; this machine reaches it as $CLIENT"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "Two responders behind one address"
cat >"$RUN_DIR/setup.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    estate.jorisjonkers.dev/drill: "372"
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: responder
  namespace: $NS
data:
  Corefile: |
    .:1053 {
        chaos {\$NODE_NAME}
        ready :8181
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: responder
  namespace: $NS
spec:
  replicas: 2
  selector:
    matchLabels: {app: responder}
  template:
    metadata:
      labels: {app: responder}
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
                matchLabels: {app: responder}
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: coredns
          image: $IMAGE
          args: ["-conf", "/etc/coredns/Corefile"]
          env:
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
          ports:
            - {name: dns, containerPort: 1053, protocol: UDP}
          readinessProbe:
            httpGet: {path: /ready, port: 8181}
            periodSeconds: 2
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {memory: 64Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: config, mountPath: /etc/coredns}
      volumes:
        - name: config
          configMap: {name: responder}
---
apiVersion: v1
kind: Service
metadata:
  name: responder
  namespace: $NS
  annotations:
    metallb.io/address-pool: $POOL
    metallb.io/loadBalancerIPs: $ADDRESS
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector: {app: responder}
  ports:
    - {name: dns, port: 53, targetPort: dns, protocol: UDP}
EOF
TEARDOWN="$KC delete namespace $NS --ignore-not-found --wait=false${TEARDOWN:+$'\n'$TEARDOWN}"
hand "Create the responders and their Service" <<<"$KC apply -f $RUN_DIR/setup.yaml"
need "a responder Ready on each node" 600 responders_ready || die "the responders did not start"
need "the Service holds $ADDRESS" 180 service_has_address || die "MetalLB gave the Service no address"
need "MetalLB announces $ADDRESS" 180 announcer_known || die "no node announces $ADDRESS"
need "$ADDRESS answers here" 60 answers_here || die "$ADDRESS does not answer from this machine"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "Ask ten times a second"
PROBE_LOG="$RUN_DIR/probe.log"
python3 -I "$DRILLS/lib/probe.py" run "$ADDRESS" "$PROBE_LOG" 0.1 0.25 &
BG_PIDS+=($!)
need "answers steady: 30 in a row" 60 steady 30 || die "answers are not steady before any failure"
MAC_START=$(arp_mac "$ADDRESS")
event "$ANNOUNCER announces $ADDRESS; this machine has it at ${MAC_START:-no ARP entry}"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "Pod failure: delete the responder on the announcing node"
announcer_known || true
POD_ANNOUNCER=$ANNOUNCER
POD=$(kc -n "$NS" get pods -l app=responder --field-selector "spec.nodeName=$ANNOUNCER" -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || die "no responder on $ANNOUNCER"
hand "Delete the responder on $ANNOUNCER" <<<"$KC -n $NS delete pod $POD --wait=false"
need "pod $POD is going" 0 pod_going "$POD"
FROM=$(($(ms_now) - DRILL_POLL * 1000 - 1000))
QUIET_OK=yes need "answers back after the deletion" 180 answers_back "$FROM" || true
measure POD "$FROM"
need "the replacement responder Ready" 600 responders_ready || true
announcer_known || true
event "$ANNOUNCER announces $ADDRESS now"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "Node failure: take the announcing node off the network"
FAILED_NODE=$ANNOUNCER
note "$FAILED_NODE also runs: $(kc get pods -A --field-selector "spec.nodeName=$FAILED_NODE" -o json \
  | jq -r '[.items[] | .metadata.namespace] | group_by(.) | map("\(.[0]) (\(length))") | join(", ")')"
need "no release in flight, so a node going away interrupts none" 1800 no_release_in_flight || true
need "answers steady again: 30 in a row" 120 steady 30 || true
MAC_BEFORE=$(arp_mac "$ADDRESS")
shout "Take $FAILED_NODE off the network now: pull its cable, or power it off. Leave it off until this drill says."
FROM=$(ms_now)
need "queries go unanswered" 900 answers_stopped "$FROM" || die "no query went unanswered; was $FAILED_NODE taken off?"
need "answers back from the other node" 300 answers_back "$FROM" || true
measure NODE "$FROM"
MAC_AFTER=$(arp_mac "$ADDRESS")
event "ARP for $ADDRESS here: ${MAC_BEFORE:-none} → ${MAC_AFTER:-none}"
shout "Bring $FAILED_NODE back: plug it in, or power it on."
need "$FAILED_NODE Ready again" 0 node_ready "$FAILED_NODE" || true
need "both responders Ready again" 600 responders_ready || true

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "Teardown"
kill "${BG_PIDS[@]}" 2>/dev/null || true
BG_PIDS=()
hand "Remove the drill's workload${OWN_POOL:+ and pool}" <<<"$TEARDOWN"
LEFT=""
need "namespace $NS gone" 600 absent namespace "$NS" || LEFT+=" namespace $NS;"
need "no MetalLB announcement of the drill's Service" 120 no_l2_status || LEFT+=" a ServiceL2Status;"
if [[ -n "$OWN_POOL" ]]; then
  need "pool $POOL gone" 120 absent -n metallb-system ipaddresspools.metallb.io "$POOL" || LEFT+=" IPAddressPool $POOL;"
  need "L2Advertisement $POOL gone" 120 absent -n metallb-system l2advertisements.metallb.io "$POOL" || LEFT+=" L2Advertisement $POOL;"
fi
need "$ADDRESS answers no more" 120 address_silent || LEFT+=" $ADDRESS still answers;"
TEARDOWN_DONE=yes

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "Result"
gap_row() {
  jq -r --arg what "$1" '"| \($what) | \(.before.node // "?") → \(.after.node // "none within the wait") | \(.gap_ms / 1000 * 10 | floor / 10) s | \(.misses) |"' <<<"$2"
}
result_head "the failover gap of one pool address in front of two replicas"
res "Two CoreDNS responders on \`${NODES[0]}\` and \`${NODES[1]}\`, behind one LoadBalancer Service at \`$ADDRESS\` (pool \`$POOL\`) with \`externalTrafficPolicy: Local\`. A LAN client ($CLIENT) asked \`version.bind\` every 100 ms with a 250 ms timeout; every answer names the node that gave it." "" \
  "| failure | answered by, before → after | gap | unanswered queries |" \
  "|---|---|---|---|" \
  "$(gap_row "pod on \`$POD_ANNOUNCER\` deleted" "$GAP_POD")" \
  "$(gap_row "\`$FAILED_NODE\` off the network" "$GAP_NODE")" "" \
  "- The client's ARP entry for \`$ADDRESS\` went from \`${MAC_BEFORE:-none}\` to \`${MAC_AFTER:-none}\` across the node failure." \
  "- Kubernetes marked \`$FAILED_NODE\` NotReady $(if [[ -n "$NOT_READY_AT" ]]; then printf '%s after it was taken off' "$(_dur $((NOT_READY_AT - ${FROM:0:${#FROM}-3})))"; else printf 'not at all while it was off'; fi)." \
  "- The gap runs from the last answer before the failure to the first answer after it; the full log is \`probe.log\` in the run's record."
GAP_S=$(jq -r '.gap_ms / 1000 * 10 | floor / 10' <<<"$GAP_NODE")
say "The node failure left $ADDRESS unanswered for $BOLD$GAP_S s$RESET (the pod failure: $(jq -r '.gap_ms / 1000 * 10 | floor / 10' <<<"$GAP_POD") s)."
choose "Is that gap acceptable for the whole LAN's DNS on one address? (y/n)" y n
if [[ "$CHOICE" == y ]]; then
  res "" "**Verdict:** the gap is acceptable for DNS; one pool address in front of two replicas stands as failover."
else
  res "" "**Verdict:** the gap is not acceptable for DNS at $GAP_S s; this reopens the one-address decision."
fi
res "" "### Done when" \
  "- [x] The gap is recorded for a pod failure and for a node failure." \
  "- [x] The result is posted here." \
  "- [$([[ -z "$LEFT" ]] && printf x || printf ' ')] Nothing the drill created is left in the cluster.${LEFT:+ Left:$LEFT}"
show_result
finish
