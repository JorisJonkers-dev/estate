#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: restore-rabbitmq-definitions.sh --definitions <rabbitmq-definitions.json> --username <user> --password <pass> [options]

Imports RabbitMQ definitions into the running k3s broker through a local port-forward.

Options:
  --definitions <file>   Local rabbitmq-definitions.json file.
  --username <user>      RabbitMQ management username.
  --password <pass>      RabbitMQ management password.
  --namespace <ns>       Namespace containing the rabbitmq service. Default: data-system.
  --service <name>       Service name. Default: rabbitmq.
  --local-port <port>    Local forwarded port. Default: 15672.
EOF
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

DEFINITIONS=""
USERNAME=""
PASSWORD=""
NAMESPACE="data-system"
SERVICE="rabbitmq"
LOCAL_PORT=15672

while [[ $# -gt 0 ]]; do
  case "$1" in
    --definitions)
      DEFINITIONS="${2:?Missing value for --definitions}"
      shift 2
      ;;
    --username)
      USERNAME="${2:?Missing value for --username}"
      shift 2
      ;;
    --password)
      PASSWORD="${2:?Missing value for --password}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:?Missing value for --namespace}"
      shift 2
      ;;
    --service)
      SERVICE="${2:?Missing value for --service}"
      shift 2
      ;;
    --local-port)
      LOCAL_PORT="${2:?Missing value for --local-port}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

require_command kubectl
require_command curl

[[ -n "${DEFINITIONS}" ]] || usage
[[ -n "${USERNAME}" ]] || usage
[[ -n "${PASSWORD}" ]] || usage
[[ -f "${DEFINITIONS}" ]] || {
  echo "Definitions file not found: ${DEFINITIONS}" >&2
  exit 1
}

kubectl get service -n "${NAMESPACE}" "${SERVICE}" >/dev/null

port_forward_log="$(mktemp)"
cleanup() {
  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
  rm -f "${port_forward_log}"
}
trap cleanup EXIT

kubectl -n "${NAMESPACE}" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:15672" >"${port_forward_log}" 2>&1 &
PORT_FORWARD_PID=$!

for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${LOCAL_PORT}/api/overview" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "Importing RabbitMQ definitions from ${DEFINITIONS}"
curl -fsS \
  -u "${USERNAME}:${PASSWORD}" \
  -H 'content-type: application/json' \
  -X POST \
  --data-binary "@${DEFINITIONS}" \
  "http://127.0.0.1:${LOCAL_PORT}/api/definitions" >/dev/null

echo "RabbitMQ definitions import finished"
