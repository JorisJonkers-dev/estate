# shellcheck shell=bash
# Which kubectl context a script that writes to the cluster uses. Sourced, never run.
#
# A workstation has two contexts per cluster (agent-kit's scripts/workstation-kube.py):
# `<cluster>` is a read-only ServiceAccount (view, no Secrets, no port-forward or
# exec), and `<cluster>-admin` is cluster-admin behind an exec credential that
# runs `sudo cat` on a root-only token file, so every use needs the sudo password
# and a terminal. A script that writes, port-forwards or execs needs the second.
#
#   ESTATE_KUBE_CONTEXT   use exactly this context
#   <base>                a script's own default (KUBE_CONTEXT, DRILL_CONTEXT) or,
#                         with none, kubectl's current context: use `<base>-admin`
#                         when that context exists, else the base itself

# kube_context [BASE] prints the context to use.
kube_context() {
  local base=${1:-} contexts
  if [[ -n "${ESTATE_KUBE_CONTEXT:-}" ]]; then
    printf '%s\n' "$ESTATE_KUBE_CONTEXT"
    return 0
  fi
  [[ -n "$base" ]] || base=$(kubectl config current-context 2>/dev/null) || true
  contexts=$(kubectl config get-contexts -o name 2>/dev/null) || true
  if [[ "$base" != *-admin ]] && grep -qxF -- "$base-admin" <<<"$contexts"; then
    printf '%s\n' "$base-admin"
  else
    printf '%s\n' "$base"
  fi
}

# KUBE_STDIN is what a backgrounded kubectl reads: the admin credential's exec
# plugin refuses to run unless its stdin is a terminal, even with sudo cached.
# kube_prime sets it to /dev/tty for an admin context; a port-forward starts with
# `<"$KUBE_STDIN"`.
KUBE_STDIN=/dev/null

# KUBE_TTY names the terminal (default /dev/tty); a test points it at a file.

# kube_prime CONTEXT runs one kubectl call in the foreground, so the admin
# credential's sudo asks for the password now, on the terminal, and caches it
# for the port-forward a script then starts in the background (which has no
# terminal to ask on). Stops with the reason when the call fails. A context that
# is not an `-admin` one has no sudo to prime.
kube_prime() {
  local ctx=$1 err
  [[ "$ctx" == *-admin ]] || return 0
  if ! { : <"${KUBE_TTY:-/dev/tty}"; } 2>/dev/null; then
    printf '\n  ✗ %s needs a terminal (sudo password, and a tty for the credential), and there is none.\n' "$ctx" >&2
    printf '    Run the port-forward yourself in another terminal and point the script at it, e.g. for Vault:\n' >&2
    printf '      kubectl --context %s -n secrets-system port-forward svc/vault 8200:8200\n' "$ctx" >&2
    printf '      ESTATE_VAULT_ADDR=http://127.0.0.1:8200 ...\n\n' >&2
    return 1
  fi
  KUBE_STDIN=${KUBE_TTY:-/dev/tty}
  printf '  %s needs sudo for its admin token; enter the password if asked\n' "$ctx" >&2
  err=$(kubectl --context "$ctx" --request-timeout=30s version -o json 2>&1 >/dev/null <"$KUBE_STDIN") || {
    printf '\n  ✗ kubectl --context %s failed, so nothing was started: %s\n' "$ctx" "$err" >&2
    printf '    Run it from a terminal (sudo prompts there), or set ESTATE_KUBE_CONTEXT to a context that needs none.\n\n' >&2
    return 1
  }
}
