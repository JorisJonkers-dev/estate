# The proxy's npm latest is never a prerelease when the cooldown holds latest back (packages-proxy's
# patch 0001). next publishes canaries daily and a stable release every few weeks.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
latest=$(curl -s --max-time 120 -H "$(bearer "$KEY")" "$GATE/npm/next" | python3 -c 'import json,sys; print(json.load(sys.stdin)["dist-tags"]["latest"])')
case "$latest" in ""|*-*) echo "next's latest is '$latest'" >&2; exit 1 ;; esac
