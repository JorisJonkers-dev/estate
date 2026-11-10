#!/usr/bin/env bash
# test-kube-context.sh: bootstrap/lib/kube.sh picks the admin context when one
# exists, honours ESTATE_KUBE_CONTEXT and a caller's KUBECTL, and stops with a
# message when the admin credential fails. kubectl is a fake on PATH.
#
# Run from the repository root: bash .github/scripts/test-kube-context.sh
set -euo pipefail

root="$(pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
  *"config current-context"*) echo "${FAKE_CURRENT:-personal}" ;;
  *"config get-contexts"*) printf '%s\n' ${FAKE_CONTEXTS:-personal personal-admin} ;;
  *version*) [[ -z "${FAKE_FAIL:-}" ]] || { echo "sudo: a terminal is required" >&2; exit 1; } ;;
esac
FAKE
chmod +x "$work/bin/kubectl"
export KUBE_TTY=/dev/null PATH="$work/bin:$PATH" FAKE_LOG="$work/log"
: > "$FAKE_LOG"

fail() { echo "FAIL: $1" >&2; exit 1; }
expect() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; }
resolve() { bash -c "source '$root/bootstrap/lib/kube.sh'; kube_context $*"; }

expect "current context gets its admin twin" "$(resolve)" personal-admin
expect "a base without a twin stays" "$(resolve blueshell)" blueshell
expect "an admin context stays" "$(FAKE_CURRENT=personal-admin resolve)" personal-admin
expect "no admin context: the current one" "$(FAKE_CONTEXTS=personal resolve)" personal
expect "explicit wins" "$(ESTATE_KUBE_CONTEXT=lab resolve)" lab

# estate.sh: KUBECTL carries the context, a caller's KUBECTL is kept.
chosen="$(bash -c "source '$root/bootstrap/lib/kube.sh'; KUBECTL=; export HOME='$work'; source '$root/bootstrap/lib/wizard.sh'; source '$root/bootstrap/lib/estate.sh'; echo \"\$KUBECTL|\$KUBE_CTX\"" 2>/dev/null)"
expect "estate.sh" "$chosen" "kubectl --context personal-admin|personal-admin"
chosen="$(KUBECTL=mykubectl bash -c "export HOME='$work'; source '$root/bootstrap/lib/wizard.sh'; source '$root/bootstrap/lib/estate.sh'; echo \"\$KUBECTL\"" 2>/dev/null)"
expect "caller's KUBECTL" "$chosen" "mykubectl"
chosen="$(KUBECTL=mykubectl ESTATE_KUBE_CONTEXT=lab bash -c "export HOME='$work'; source '$root/bootstrap/lib/wizard.sh'; source '$root/bootstrap/lib/estate.sh'; echo \"\$KUBECTL|\$KUBE_CTX\"" 2>/dev/null)"
expect "explicit context with a caller's KUBECTL" "$chosen" "mykubectl --context lab|lab"

# kube_prime runs one foreground call on an admin context, nothing otherwise.
: > "$FAKE_LOG"
bash -c "source '$root/bootstrap/lib/kube.sh'; kube_prime personal-admin" 2> /dev/null
grep -q -- '--context personal-admin .*version' "$FAKE_LOG" || fail "kube_prime did not call kubectl version"
: > "$FAKE_LOG"
bash -c "source '$root/bootstrap/lib/kube.sh'; kube_prime personal" 2> /dev/null
[[ ! -s "$FAKE_LOG" ]] || fail "kube_prime called kubectl on a non-admin context"
if out="$(FAKE_FAIL=1 bash -c "source '$root/bootstrap/lib/kube.sh'; kube_prime personal-admin" 2>&1)"; then
  fail "kube_prime passed a failing credential"
fi
grep -q 'a terminal is required' <<<"$out" || fail "kube_prime hid the reason"
if out="$(KUBE_TTY=/nonexistent bash -c "source '$root/bootstrap/lib/kube.sh'; kube_prime personal-admin" 2>&1)"; then
  fail "kube_prime passed without a terminal"
fi
grep -q 'ESTATE_VAULT_ADDR' <<<"$out" || fail "no manual fallback named"
echo "ok"
