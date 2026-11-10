# The proxy names its storage limits at startup: the cache's max size, and retention covering
# the container ecosystem (oci), whose image layers are large. The startup log lists the
# ecosystems retention covers but not each rule's term, so the config is checked for the
# container rule too.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

config=$(dirname "$0")/../../config/proxy.yaml
# An ecosystem rule for oci under storage.retention.ecosystems.
awk '/^storage:/{s=1;next} /^[a-z]/{s=0} s&&/^    ecosystems:/{e=1;next} e&&/^      oci: "[0-9]+d"/{f=1} END{exit !f}' "$config" \
  || { echo "storage.retention.ecosystems has no oci rule" >&2; exit 1; }

startup=$(head -200 "$PROXY_LOG")
printf '%s\n' "$startup" | grep 'retention enabled' | grep -q '"oci"\|oci' \
  || { echo "the startup log does not show retention covering oci" >&2; exit 1; }
printf '%s\n' "$startup" | grep 'cache eviction enabled' | grep -q '85GB' \
  || { echo "the startup log does not show the 85GB max size" >&2; exit 1; }
