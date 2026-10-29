#!/usr/bin/env bash
#
# Drill JorisJonkers-dev/deploy-kit#369: rotate a RabbitMQ dynamic credential
# under a consumer that holds an open connection, and record what it sees.
#
# Vault Secrets Operator delivers a credential from a RabbitMQ secrets engine to
# a consumer that holds one AMQP connection open and logs every connection
# event. The engine's lease is short, so within minutes VSO renews it, then
# replaces it and restarts the consumer, and Vault deletes the old user. The
# drill follows all of it and records whether the consumer was on the new user
# before the old one was deleted, and what the old connection saw.
#
# The drill mounts an engine of its own, `rabbitmq-drill`, against the same
# broker. The live `rabbitmq` mount still issues agents-api's credential, and a
# short lease set on it would reach that consumer on its next restart, so the
# drill only reads the live mount, before and after.
#
#   ./drills/rabbitmq-rotation.sh           the drill
#   ./drills/rabbitmq-rotation.sh --check   its preflight alone
#
# DRILL_TTL and DRILL_MAX_TTL set the drill engine's lease (60 s and 240 s),
# DRILL_CONTEXT the kubectl context.

source "$(dirname "${BASH_SOURCE[0]}")/lib/drill.sh"

TOTAL_STAGES=7
NS=drill-369
MOUNT=rabbitmq-drill
VHOST=drill-369
VAULT_NAME=drill-369-consumer # its policy and its Kubernetes auth role
TTL=${DRILL_TTL:-60}
MAX_TTL=${DRILL_MAX_TTL:-240}
PYTHON_IMAGE=${DRILL_PYTHON_IMAGE:-python:3.13-alpine}
PIKA_VERSION=1.3.2

SECRET_USER=""
LEASE_ID=""
RENEWED_AT=""
RENEWALS=0
OLD_USER=""
NEW_USER=""
REPLACED_AT=""
OLD_GONE_AT=""
OBSERVED=0
declare -A FOLLOWED=() LINES=() TERMINATING=() POD_USER=() CONNECTED=()
TIMELINE=()
ANOMALIES=()
ALL_USERS=()

# ── Reads ─────────────────────────────────────────────────────────────────

rmq() { kc -n data-system exec deploy/rabbitmq -c rabbitmq -- rabbitmqctl -q --formatter json "$@"; }

vault_json() { vault read -format=json "$1" 2>/dev/null </dev/null; }

# vault_absent PATH: Vault answers that nothing is at PATH. A read that fails
# any other way is never taken for "absent".
vault_absent() {
  local out
  out=$(vault read "$1" 2>&1 </dev/null) && return 1
  grep -q -e 'No value found' -e 'Code: 404' <<<"$out"
}
mount_present() { vault secrets list -format=json </dev/null | jq -e --arg m "$MOUNT/" 'has($m)' >/dev/null; }
mount_absent() {
  local mounts
  mounts=$(vault secrets list -format=json </dev/null) || return 1
  jq -e --arg m "$MOUNT/" 'has($m) | not' <<<"$mounts" >/dev/null
}
policy_present() { vault policy read "$VAULT_NAME" >/dev/null 2>&1 </dev/null; }
policy_absent() {
  local out
  out=$(vault policy read "$VAULT_NAME" 2>&1 </dev/null) && return 1
  grep -q -e 'No policy named' -e 'Code: 404' <<<"$out"
}
lease_set() {
  local lease
  lease=$(vault_json "$MOUNT/config/lease") || return 1
  HINT=$(jq -r '"ttl \(.data.ttl), max_ttl \(.data.max_ttl)"' <<<"$lease")
  jq -e --argjson t "$TTL" --argjson m "$MAX_TTL" '(.data.ttl | tonumber) == $t and (.data.max_ttl | tonumber) == $m' <<<"$lease" >/dev/null
}
vhost_present() { rmq list_vhosts | jq -e --arg v "$VHOST" 'any(.[]; .name == $v)' >/dev/null; }
vhost_absent() {
  local vhosts
  vhosts=$(rmq list_vhosts) || return 1
  jq -e --arg v "$VHOST" 'any(.[]; .name == $v) | not' <<<"$vhosts" >/dev/null
}
# rmq_has_user USER: a failed read counts as present, never as gone.
rmq_has_user() {
  local users
  users=$(rmq list_users) || return 0
  jq -e --arg u "$1" 'any(.[]; .user == $u)' <<<"$users" >/dev/null
}
drill_users_gone() {
  local users user
  users=$(rmq list_users) || return 1
  for user in "${ALL_USERS[@]}"; do
    jq -e --arg u "$user" 'any(.[]; .user == $u)' <<<"$users" >/dev/null && { HINT="$user is still there"; return 1; }
  done
  return 0
}

vso_ready() {
  kc -n vso-system get deploy vault-secrets-operator-controller-manager -o json \
    | jq -e '(.status.readyReplicas // 0) >= 1' >/dev/null
}

vds_ready() {
  local vds
  vds=$(kc -n "$NS" get vaultdynamicsecret consumer -o json 2>/dev/null) || { HINT="no VaultDynamicSecret yet"; return 1; }
  HINT=$(jq -r '[.status.conditions[]? | select(.status != "True") | "\(.type): \(.message)"] | first // "Ready"' <<<"$vds")
  jq -e 'any(.status.conditions[]?; .type == "Ready" and .status == "True")' <<<"$vds" >/dev/null
}

secret_user() {
  kc -n "$NS" get secret consumer-creds -o json 2>/dev/null | jq -r '.data.username // "" | @base64d'
}

consumer_ready() {
  local pods
  pods=$(kc -n "$NS" get pods -l app=consumer -o json) || return 1
  HINT=$(jq -r '[.items[] | "\(.metadata.name): \(
      if any(.status.conditions[]?; .type == "Ready" and .status == "True") then "ready"
      else (.status.containerStatuses[0].state.waiting.reason // .status.phase) end)"] | join(", ")' <<<"$pods")
  jq -e 'any(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' <<<"$pods" >/dev/null
}

consumer_connected() {
  follow_pods
  read_consumer_logs
  SECRET_USER=$(secret_user)
  HINT="waiting for a connection as ${SECRET_USER:-?}"
  [[ -n "$SECRET_USER" && -n "${CONNECTED[$SECRET_USER]:-}" ]]
}

broker_sees_connection() {
  local connections
  connections=$(rmq list_connections user vhost) || return 1
  jq -e --arg u "$SECRET_USER" --arg v "$VHOST" 'any(.[]; .user == $u and .vhost == $v)' <<<"$connections" >/dev/null
}

# ── Following the consumer ────────────────────────────────────────────────

tl() { event "$1"; TIMELINE+=("| $(since) | $1 |"); }

# follow_pods starts reading the log of every consumer pod once it runs.
follow_pods() {
  local pods name node running deleting
  pods=$(kc -n "$NS" get pods -l app=consumer -o json) || return 0
  while IFS=$'\t' read -r name node running deleting; do
    [[ -n "$name" ]] || continue
    if [[ -z "${FOLLOWED[$name]:-}" && "$running" == true ]]; then
      FOLLOWED[$name]=1
      "$KUBECTL" --context "$CTX" -n "$NS" logs -f "$name" >>"$RUN_DIR/consumer-$name.log" 2>/dev/null &
      BG_PIDS+=($!)
      tl "pod \`$name\` runs on $node"
    fi
    if [[ "$deleting" == true && -z "${TERMINATING[$name]:-}" ]]; then
      TERMINATING[$name]=1
      tl "pod \`$name\` is terminating"
    fi
  done < <(jq -r '.items[] | [.metadata.name, (.spec.nodeName // "-"),
      ((.status.containerStatuses // [])[0].state.running != null), (.metadata.deletionTimestamp != null)] | @tsv' <<<"$pods")
}

# read_consumer_logs turns every new line of every consumer's log, ticks
# aside, into a line of the timeline.
read_consumer_logs() {
  local file name total seen ts user ev detail
  for file in "$RUN_DIR"/consumer-*.log; do
    [[ -e "$file" ]] || continue
    name=${file##*/consumer-}
    name=${name%.log}
    total=$(wc -l <"$file" | tr -d ' ')
    seen=${LINES[$name]:-0}
    ((total > seen)) || continue
    while IFS=$'\t' read -r ts user ev detail; do
      consumer_event "$name" "$ts" "$user" "$ev" "$detail"
    done < <(sed -n "$((seen + 1)),${total}p" "$file" | jq -R -r 'fromjson? | select(.event != "tick")
      | [.ts, .user, .event, ([to_entries[] | select(.key | IN("ts", "pod", "user", "event") | not) | "\(.key)=\(.value)"] | join(" "))]
      | @tsv')
    LINES[$name]=$total
  done
}

consumer_event() {
  local pod="$1" ts="${2%.*}" user="$3" ev="$4" detail="$5" at
  at=$(printf '%(%H:%M:%S)T' "$ts")
  POD_USER[$pod]=$user
  case "$ev" in
    connected) [[ -n "${CONNECTED[$user]:-}" ]] || CONNECTED[$user]=$ts ;;
    refused | connect-failed | lost) ANOMALIES+=("$at \`$pod\` as \`$user\`: $ev${detail:+, $detail}") ;;
    closed) [[ "$detail" == *by=broker* ]] && ANOMALIES+=("$at \`$pod\` as \`$user\`: the broker closed the connection, $detail") ;;
  esac
  tl "$at \`$pod\` $ev${detail:+ ($detail)}, as \`$user\`"
}

# observe_rotation succeeds once the drill has seen a renewal, a replacement,
# the consumer connected as the new user, and the old user gone.
observe_rotation() {
  local vds lid duration renewed user
  vds=$(kc -n "$NS" get vaultdynamicsecret consumer -o json) || return 1
  lid=$(jq -r '.status.secretLease.id // ""' <<<"$vds")
  duration=$(jq -r '.status.secretLease.duration // ""' <<<"$vds")
  renewed=$(jq -r '.status.lastRenewalTime // ""' <<<"$vds")
  user=$(secret_user)
  if [[ -n "$user" && "$user" != "$SECRET_USER" ]]; then
    OLD_USER=$SECRET_USER
    NEW_USER=$user
    REPLACED_AT=$EPOCHSECONDS
    ALL_USERS+=("$user")
    tl "**credential replaced**: \`$OLD_USER\` → \`$NEW_USER\`, a ${duration}s lease"
  elif [[ -n "$renewed" && "$renewed" != "$RENEWED_AT" && "$lid" == "$LEASE_ID" ]]; then
    RENEWALS=$((RENEWALS + 1))
    tl "**lease renewed** (#$RENEWALS): ${duration}s on \`$lid\`"
  fi
  [[ -n "$user" ]] && SECRET_USER=$user
  LEASE_ID=$lid
  RENEWED_AT=$renewed
  follow_pods
  read_consumer_logs
  if [[ -n "$OLD_USER" && -z "$OLD_GONE_AT" ]] && ((OBSERVED++ % 3 == 0)) && ! rmq_has_user "$OLD_USER"; then
    OLD_GONE_AT=$EPOCHSECONDS
    tl "**RabbitMQ no longer has** \`$OLD_USER\`"
  fi
  HINT="$RENEWALS renewal(s) · ${REPLACED_AT:+replaced · }${OLD_GONE_AT:+old user gone · }lease ${duration}s"
  ((RENEWALS >= 1)) && [[ -n "$REPLACED_AT" && -n "${CONNECTED[$NEW_USER]:-}" && -n "$OLD_GONE_AT" ]]
}

# ── 1 ─────────────────────────────────────────────────────────────────────
drill_start 369 "a RabbitMQ credential rotation under a connected consumer" "$@"
stage "Preflight"
preflight_cluster
require_tools vault curl
wait_until "Vault Secrets Operator is running" 30 vso_ready || die "VSO is not Ready in vso-system"
kc get crd vaultdynamicsecrets.secrets.hashicorp.com >/dev/null 2>&1 || die "no VaultDynamicSecret CRD"
rmq list_vhosts >/dev/null || die "rabbitmqctl does not answer in data-system/rabbitmq"
ok "RabbitMQ answers rabbitmqctl in data-system"
VAULT_IN_CLUSTER=$(kc get vaultconnections.secrets.hashicorp.com -A -o json | jq -r '[.items[].spec.address] | first // empty')
[[ -n "$VAULT_IN_CLUSTER" ]] || die "no VaultConnection to copy Vault's in-cluster address from"
ok "VSO reaches Vault at $VAULT_IN_CLUSTER"
clear_leftovers "$NS"
if ! vhost_absent; then
  warn "vhost $VHOST is still there from an earlier run; it goes first"
  hand "Remove the earlier run's vhost" <<<"$KC -n data-system exec deploy/rabbitmq -c rabbitmq -- rabbitmqctl delete_vhost $VHOST"
  need "vhost $VHOST gone" 300 vhost_absent || die "vhost $VHOST is still there"
fi
check_only

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "Vault: what the live mount leases, read only"
vault_connect
LIVE_TUNE=$(vault_json sys/mounts/rabbitmq/tune | jq -c '.data | {default_lease_ttl, max_lease_ttl}') \
  || die "cannot read sys/mounts/rabbitmq/tune"
LIVE_LEASE=$(vault read -format=json rabbitmq/config/lease 2>&1 </dev/null | jq -c '.data // .' 2>/dev/null \
  || vault read rabbitmq/config/lease 2>&1 </dev/null | head -n 1)
LIVE_ROLE=$(vault_json rabbitmq/roles/app-consumer | jq -c '.data' || printf 'unreadable')
ok "the live mount's tune: $LIVE_TUNE"
ok "its rabbitmq/config/lease: $LIVE_LEASE"
note "its role app-consumer: $LIVE_ROLE"
# A drill role is built like a rendered one: the audience an existing VSO role
# binds, if it binds one.
EXAMPLE_ROLE=$(kc get vaultauths.secrets.hashicorp.com -A -o json | jq -r '[.items[].spec.kubernetes.role // empty] | first // empty')
AUDIENCE=""
if [[ -n "$EXAMPLE_ROLE" ]]; then
  AUDIENCE=$(vault_json "auth/kubernetes/role/$EXAMPLE_ROLE" | jq -r '.data.audience // ""') || AUDIENCE=""
  ok "the drill's Kubernetes role mirrors $EXAMPLE_ROLE: audience ${AUDIENCE:-none}"
fi
mount_absent || die "Vault already has a $MOUNT mount: remove it (vault secrets disable $MOUNT) and re-run"
policy_absent || die "Vault already has policy $VAULT_NAME: remove it (vault policy delete $VAULT_NAME) and re-run"
vault_absent "auth/kubernetes/role/$VAULT_NAME" \
  || die "Vault already has auth/kubernetes/role/$VAULT_NAME: remove it and re-run"
ok "nothing named $MOUNT or $VAULT_NAME in Vault yet"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "A drill engine with a ${TTL}s lease, and a vhost for it"
VAULT_LOGIN="export VAULT_ADDR=$VAULT_ADDR
vault token lookup >/dev/null 2>&1 || export VAULT_TOKEN=\"\$(vault login -method=oidc -path=$VAULT_OIDC_PATH -token-only)\""
TEARDOWN="$KC delete namespace $NS --ignore-not-found --timeout=180s
$VAULT_LOGIN
vault secrets disable $MOUNT
vault policy delete $VAULT_NAME
vault delete auth/kubernetes/role/$VAULT_NAME
$KC -n data-system exec deploy/rabbitmq -c rabbitmq -- rabbitmqctl delete_vhost $VHOST"
note "VAULT_ADDR is this drill's port-forward to Vault; it stays open while the drill runs."
hand "Mount the drill engine, its role, policy and vhost" <<EOF
$VAULT_LOGIN
vault secrets enable -path=$MOUNT rabbitmq
vault kv get -mount=secret -field=rabbitmq.password platform/rabbitmq | vault write $MOUNT/config/connection connection_uri=http://rabbitmq.data-system.svc.cluster.local:15672 username="\$(vault kv get -mount=secret -field=rabbitmq.user platform/rabbitmq)" password=- verify_connection=true
vault write $MOUNT/config/lease ttl=$TTL max_ttl=$MAX_TTL
vault write $MOUNT/roles/drill vhosts='{"$VHOST":{"configure":".*","write":".*","read":".*"}}'
vault policy write $VAULT_NAME - <<'POLICY'
path "$MOUNT/creds/drill" {
  capabilities = ["read"]
}
path "sys/leases/renew" {
  capabilities = ["update"]
}
POLICY
vault write auth/kubernetes/role/$VAULT_NAME bound_service_account_names=consumer bound_service_account_namespaces=$NS token_policies=$VAULT_NAME token_ttl=10m${AUDIENCE:+ audience=$AUDIENCE}
$KC -n data-system exec deploy/rabbitmq -c rabbitmq -- rabbitmqctl add_vhost $VHOST
EOF
need "Vault mounts $MOUNT" 900 mount_present || die "no $MOUNT mount"
need "its lease is ttl ${TTL}s, max ${MAX_TTL}s" 300 lease_set || die "the drill engine's lease is not set"
need "its role drill" 300 vault_json "$MOUNT/roles/drill" || die "no role $MOUNT/roles/drill"
need "policy $VAULT_NAME" 300 policy_present || die "no policy $VAULT_NAME"
need "Kubernetes auth role $VAULT_NAME" 300 vault_json "auth/kubernetes/role/$VAULT_NAME" || die "no Kubernetes auth role $VAULT_NAME"
need "RabbitMQ vhost $VHOST" 300 vhost_present || die "no vhost $VHOST"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "A consumer that holds one connection open"
{
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    estate.jorisjonkers.dev/drill: "369"
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: consumer
  namespace: $NS
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: secret-store
  namespace: $NS
spec:
  address: $VAULT_IN_CLUSTER
  skipTLSVerify: false
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: consumer
  namespace: $NS
spec:
  method: kubernetes
  mount: kubernetes
  vaultConnectionRef: secret-store
  kubernetes:
    role: $VAULT_NAME
    serviceAccount: consumer
    tokenExpirationSeconds: 600${AUDIENCE:+
    audiences: [$AUDIENCE]}
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata:
  name: consumer
  namespace: $NS
spec:
  vaultAuthRef: consumer
  mount: $MOUNT
  path: creds/drill
  renewalPercent: 67
  revoke: true
  destination:
    name: consumer-creds
    create: true
  rolloutRestartTargets:
    - {kind: Deployment, name: consumer}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: consumer
  namespace: $NS
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: 1, maxUnavailable: 0}
  selector:
    matchLabels: {app: consumer}
  template:
    metadata:
      labels: {app: consumer}
    spec:
      serviceAccountName: consumer
      automountServiceAccountToken: false
      nodeSelector:
        platform.jorisjonkers.dev/site: frankfurt
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: consumer
          image: $PYTHON_IMAGE
          command:
            - sh
            - -c
            - pip install --quiet --disable-pip-version-check --no-cache-dir --target /tmp/lib pika==$PIKA_VERSION && PYTHONPATH=/tmp/lib exec python -u /app/consumer.py
          env:
            - {name: HOME, value: /tmp}
            - name: POD_NAME
              valueFrom: {fieldRef: {fieldPath: metadata.name}}
            - {name: RABBITMQ_HOST, value: rabbitmq.data-system.svc.cluster.local}
            - {name: RABBITMQ_VHOST, value: $VHOST}
            - name: RABBITMQ_USERNAME
              valueFrom: {secretKeyRef: {name: consumer-creds, key: username}}
            - name: RABBITMQ_PASSWORD
              valueFrom: {secretKeyRef: {name: consumer-creds, key: password}}
          readinessProbe:
            exec: {command: [test, -f, /tmp/connected]}
            periodSeconds: 2
          resources:
            requests: {cpu: 20m, memory: 48Mi}
            limits: {memory: 160Mi}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: consumer, mountPath: /app}
      volumes:
        - name: consumer
          configMap: {name: consumer}
---
EOF
  "$KUBECTL" create configmap consumer -n "$NS" --from-file=consumer.py="$DRILLS/lib/rabbitmq-consumer.py" \
    --dry-run=client -o yaml
} >"$RUN_DIR/setup.yaml"
hand "Create the consumer and its dynamic secret" <<<"$KC apply -f $RUN_DIR/setup.yaml"
need "VSO syncs the credential" 600 vds_ready || die "the VaultDynamicSecret is not Ready"
SECRET_USER=$(secret_user)
ALL_USERS+=("$SECRET_USER")
ok "consumer-creds holds user $SECRET_USER"
need "the consumer is Ready" 600 consumer_ready || die "the consumer did not start"
need "the consumer connected as $SECRET_USER" 120 consumer_connected || die "the consumer has not connected"
need "RabbitMQ shows its connection on $VHOST" 60 broker_sees_connection || true
VDS=$(kc -n "$NS" get vaultdynamicsecret consumer -o json)
LEASE_ID=$(jq -r '.status.secretLease.id // ""' <<<"$VDS")
RENEWED_AT=$(jq -r '.status.lastRenewalTime // ""' <<<"$VDS")
tl "first lease \`$LEASE_ID\`, $(jq -r '.status.secretLease.duration' <<<"$VDS")s, user \`$SECRET_USER\`"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "Watch a renewal, a replacement, and the old user go"
note "VSO renews at 67% of each lease; the max_ttl of ${MAX_TTL}s forces a replacement. Expect about $(_dur $((MAX_TTL + TTL)))."
wait_until "a renewal, a replacement, the consumer on the new user, the old user gone" $((MAX_TTL * 3 + 300)) observe_rotation || true

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "Teardown"
kill "${BG_PIDS[@]}" 2>/dev/null || true
BG_PIDS=()
hand "Remove the namespace, the drill engine, its policy, role and vhost" <<<"$TEARDOWN"
LEFT=""
need "namespace $NS gone" 600 absent namespace "$NS" || LEFT+=" namespace $NS;"
need "Vault has no $MOUNT mount" 300 mount_absent || LEFT+=" mount $MOUNT;"
need "Vault has no policy $VAULT_NAME" 120 policy_absent || LEFT+=" policy $VAULT_NAME;"
need "Vault has no role $VAULT_NAME" 120 vault_absent "auth/kubernetes/role/$VAULT_NAME" || LEFT+=" role $VAULT_NAME;"
need "RabbitMQ has no vhost $VHOST" 120 vhost_absent || LEFT+=" vhost $VHOST;"
need "RabbitMQ has none of the drill's users" 120 drill_users_gone || LEFT+=" a drill user;"
LIVE_TUNE_AFTER=$(vault_json sys/mounts/rabbitmq/tune | jq -c '.data | {default_lease_ttl, max_lease_ttl}')
if [[ "$LIVE_TUNE_AFTER" == "$LIVE_TUNE" ]]; then
  ok "the live rabbitmq mount's lease is as it was"
else
  bad "the live rabbitmq mount's lease changed: $LIVE_TUNE → $LIVE_TUNE_AFTER"
  LEFT+=" a changed live lease;"
fi
TEARDOWN_DONE=yes

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "Result"
NEW_AT=${CONNECTED[$NEW_USER]:-}
OLD_SAW=()
for pod in "${!POD_USER[@]}"; do
  [[ "${POD_USER[$pod]}" == "$OLD_USER" && -n "$OLD_USER" ]] || continue
  OLD_SAW+=("$(jq -R -r 'fromjson? | select(.event != "tick") | "- \(.ts | floor | strftime("%H:%M:%S")) `\(.pod)` \(.event) \([to_entries[] | select(.key | IN("ts", "pod", "user", "event") | not) | "\(.key)=\(.value)"] | join(" "))"' \
    "$RUN_DIR/consumer-$pod.log" | tail -n 8)")
  OLD_SAW+=("$(jq -R -r 'fromjson? | select(.event == "tick") | "- last successful tick \(.ts | floor | strftime("%H:%M:%S"))"' "$RUN_DIR/consumer-$pod.log" | tail -n 1)")
done
if ((RENEWALS >= 1)) && [[ -n "$REPLACED_AT" && -n "$NEW_AT" && -n "$OLD_GONE_AT" ]] && ((NEW_AT <= OLD_GONE_AT)) && ((${#ANOMALIES[@]} == 0)); then
  VERDICT="the cycle is clean: the consumer ran on the new user $(_dur $((OLD_GONE_AT - NEW_AT))) before RabbitMQ dropped the old one, and no connection was refused or closed by the broker. The dynamic credential holds."
else
  VERDICT="the cycle is not clean"
  ((RENEWALS >= 1)) || VERDICT+="; no renewal was seen"
  [[ -n "$REPLACED_AT" ]] || VERDICT+="; no replacement was seen"
  [[ -n "$REPLACED_AT" && -z "$NEW_AT" ]] && VERDICT+="; the consumer never connected as the new user"
  [[ -n "$NEW_AT" && -n "$OLD_GONE_AT" ]] && ((NEW_AT > OLD_GONE_AT)) && VERDICT+="; the old user was deleted $(_dur $((NEW_AT - OLD_GONE_AT))) before the consumer was on the new one"
  ((${#ANOMALIES[@]})) && VERDICT+="; the consumer saw ${#ANOMALIES[@]} failure(s), listed below"
  VERDICT+=". That is the evidence for choosing between a dynamic and a static credential."
fi
result_head "a RabbitMQ dynamic credential rotated under a connected consumer"
res "### The live mount's lease" "" \
  "Read before the drill and unchanged after it: \`sys/mounts/rabbitmq/tune\` is \`$LIVE_TUNE\`, and \`rabbitmq/config/lease\` is \`$LIVE_LEASE\`. Role \`app-consumer\`: \`$LIVE_ROLE\`." "" \
  "### The drill" "" \
  "A separate engine, \`$MOUNT\`, on the same broker, leasing for ${TTL}s up to ${MAX_TTL}s, so the live mount and its consumer were never touched. VSO (\`$(kc -n vso-system get deploy vault-secrets-operator-controller-manager -o jsonpath='{.spec.template.spec.containers[-1].image}' 2>/dev/null || printf '?')\`) delivered it with a \`VaultDynamicSecret\` (\`renewalPercent: 67\`, \`rolloutRestartTargets\` naming the consumer) to one pika consumer holding one connection, with a 10 s heartbeat and a publish every 5 s." "" \
  "| time | what happened |" "|---|---|" "${TIMELINE[@]}" "" \
  "What the old connection (\`${OLD_USER:-none}\`) saw:" "" "${OLD_SAW[@]:-- nothing recorded}" ""
if ((${#ANOMALIES[@]})); then
  res "Failures the consumer logged:" "" "${ANOMALIES[@]/#/- }" ""
fi
res "**Verdict:** $VERDICT" "" "### Done when" \
  "- [x] The mount's real lease lifetime is recorded." \
  "- [$( ((RENEWALS >= 1)) && [[ -n "$REPLACED_AT" ]] && printf x || printf ' ')] One renewal and one replacement are observed, with the consumer's log of each." \
  "- [x] The result is posted here." \
  "- [$([[ -z "$LEFT" ]] && printf x || printf ' ')] Nothing the drill created is left in Vault, RabbitMQ or the cluster.${LEFT:+ Left:$LEFT}"
say "Verdict: $VERDICT"
show_result
finish
