#!/usr/bin/env bash
# Where Vault is running, found rather than remembered. Sourced, never run.
#
# Vault has moved before (data-system/vault-0, a StatefulSet pod, became a
# Deployment pod in secrets-system whose name carries a hash), and a script that
# names the pod points at nothing the day it moves again. So the pod is found by
# label, in any namespace.
#
#   VAULT_NS        pin the namespace (and narrow the search to it)
#   VAULT_POD       pin the pod; with VAULT_NS, nothing is searched
#   VAULT_SELECTOR  the label to find it by (default app.kubernetes.io/name=vault)
#
# The caller defines `k`, its kubectl with the right context.

# vault_locate sets VAULT_NS and VAULT_POD, or says what it found and returns 1.
# Exactly one running pod must match: unsealing or restoring the wrong one of
# two is worse than stopping.
vault_locate() {
  local selector="${VAULT_SELECTOR:-app.kubernetes.io/name=vault}" found count scope=(-A)
  if [[ -n "${VAULT_NS:-}" && -n "${VAULT_POD:-}" ]]; then
    return 0
  fi
  [[ -n "${VAULT_NS:-}" ]] && scope=(-n "$VAULT_NS")
  found="$(k get pods "${scope[@]}" -l "$selector" --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  count="$(printf '%s' "$found" | grep -c . || true)"
  if [[ "$count" -ne 1 ]]; then
    {
      echo "!! expected exactly 1 running Vault pod, found $count (selector $selector):"
      [[ -n "$found" ]] && printf '   %s\n' "$found"
      echo "   Set VAULT_NS and VAULT_POD to name it, or VAULT_SELECTOR to find it another way."
    } >&2
    return 1
  fi
  VAULT_NS="${found%% *}"
  VAULT_POD="${found##* }"
}
