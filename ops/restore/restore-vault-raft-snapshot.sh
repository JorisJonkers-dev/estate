#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

# shellcheck source=../lib/flux-modules.sh
source "${repo_root}/ops/lib/flux-modules.sh"
# shellcheck source=../lib/vault.sh
source "${repo_root}/ops/lib/vault.sh"

args=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --vault-token)
      shift
      [[ "$#" -gt 0 ]] || {
        echo "Missing value for --vault-token" >&2
        exit 64
      }
      token_file="$(mktemp)"
      trap 'rm -f "${token_file:-}"' EXIT
      printf '%s' "$1" > "${token_file}"
      args+=(--vault-token-file "${token_file}")
      ;;
    *)
      args+=("$1")
      ;;
  esac
  shift
done

# The namespace and pod default to wherever Vault runs now, found by label
# (lib/vault.sh), not to a name that was true once. Either flag still wins, and
# naming one narrows the search for the other.
k() { kubectl ${KUBE_CONTEXT:+--context "${KUBE_CONTEXT}"} "$@"; }
has_namespace=false
has_pod=false
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --namespace) has_namespace=true; VAULT_NS="${args[$((i + 1))]:-}" ;;
    --pod) has_pod=true; VAULT_POD="${args[$((i + 1))]:-}" ;;
  esac
done
if [[ "${has_namespace}" == "false" || "${has_pod}" == "false" ]]; then
  vault_locate || exit 1
  echo ">> vault pod: ${VAULT_NS}/${VAULT_POD}" >&2
fi
if [[ "${has_namespace}" == "false" ]]; then
  args+=(--namespace "${VAULT_NS}")
fi
if [[ "${has_pod}" == "false" ]]; then
  args+=(--pod "${VAULT_POD}")
fi

run_platform_blueprints_script scripts/restore/restore-vault-raft-snapshot.sh "${args[@]}"
