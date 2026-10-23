#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

# shellcheck source=../lib/flux-modules.sh
source "${repo_root}/ops/lib/flux-modules.sh"

args=("$@")
has_image=false
for arg in "${args[@]}"; do
  if [[ "${arg}" == "--image" ]]; then
    has_image=true
    break
  fi
done
if [[ "${has_image}" == "false" ]]; then
  args+=(--image "${RESTORE_PVC_IMAGE:-debian:bookworm-slim}")
fi

run_platform_blueprints_script scripts/restore/restore-pvc-archive.sh "${args[@]}"
