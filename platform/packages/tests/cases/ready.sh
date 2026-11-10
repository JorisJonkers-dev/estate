# The probes' route answers without a key, and reaches the proxy's /health.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
expect 200 "$(status "$GATE/.gate/ready")" "/.gate/ready"
