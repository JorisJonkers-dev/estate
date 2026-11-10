# Cargo's config.json comes from the cargo-config sidecar, with auth-required, and needs a key.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
body=$(curl -s --max-time 30 -H "$(bearer "$KEY")" "$GATE/cargo/config.json")
case "$body" in *'"auth-required":true'*|*'"auth-required": true'*) ;; *) echo "config.json has no auth-required: $body" >&2; exit 1 ;; esac
expect 401 "$(status "$GATE/cargo/config.json")" "config.json without a key"
