#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

# shellcheck source=../lib/flux-modules.sh
source "${repo_root}/ops/lib/flux-modules.sh"

run_platform_blueprints_script scripts/restore/restore-hostpath-archive.sh "$@"
