#!/usr/bin/env bash
set -euo pipefail

platform_blueprints_version="${FLUX_MODULES_VERSION:-v1.4.0}"
platform_blueprints_repo="${FLUX_MODULES_REPO:-https://github.com/JorisJonkers-dev/flux-modules.git}"
platform_blueprints_cache_root="${FLUX_MODULES_CACHE_ROOT:-${HOME:-/tmp}/.cache/estate/flux-modules}"

platform_blueprints_root() {
  if [[ -n "${FLUX_MODULES_ROOT:-}" ]]; then
    printf '%s\n' "${FLUX_MODULES_ROOT}"
    return 0
  fi

  local checkout="${platform_blueprints_cache_root}/${platform_blueprints_version}"
  if [[ ! -d "${checkout}/.git" ]]; then
    mkdir -p "${platform_blueprints_cache_root}"
    rm -rf "${checkout}.tmp"
    git clone --depth 1 --branch "${platform_blueprints_version}" "${platform_blueprints_repo}" "${checkout}.tmp" >/dev/null
    rm -rf "${checkout}"
    mv "${checkout}.tmp" "${checkout}"
  fi
  printf '%s\n' "${checkout}"
}

platform_blueprints_script() {
  local relative_path="$1"
  local root
  root="$(platform_blueprints_root)"
  local script="${root}/${relative_path}"
  if [[ ! -x "${script}" ]]; then
    echo "flux-modules script not found or not executable: ${script}" >&2
    return 1
  fi
  printf '%s\n' "${script}"
}

run_platform_blueprints_script() {
  local relative_path="$1"
  shift
  local script
  script="$(platform_blueprints_script "${relative_path}")"
  "${script}" "$@"
}
