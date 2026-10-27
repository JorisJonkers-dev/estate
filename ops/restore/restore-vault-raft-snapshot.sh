#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

# shellcheck source=../lib/flux-modules.sh
source "${repo_root}/ops/lib/flux-modules.sh"

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

has_namespace=false
has_pod=false
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --namespace) has_namespace=true ;;
    --pod) has_pod=true ;;
  esac
done
if [[ "${has_namespace}" == "false" ]]; then
  args+=(--namespace data-system)
fi
if [[ "${has_pod}" == "false" ]]; then
  args+=(--pod vault-0)
fi

run_platform_blueprints_script scripts/restore/restore-vault-raft-snapshot.sh "${args[@]}"
