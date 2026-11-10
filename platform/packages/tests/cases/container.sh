# The container registry through the gate: the OCI distribution API's ping, the
# library/busybox:1.37.0 manifest and one of its blobs arrive with the key and are refused
# without it, and the proxy logs the requests.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

# Every manifest type a registry client names, so the manifest answers whatever shape 1.37.0
# has: docker and OCI, single-arch and a multi-arch list.
accept='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

expect 200 "$(status -H "$(bearer "$KEY")" "$GATE/v2/")" "/v2/ with a key"
expect 401 "$(status "$GATE/v2/")" "/v2/ without a key"

manifest=$GATE/v2/library/busybox/manifests/1.37.0
expect 200 "$(status -H "$(bearer "$KEY")" -H "$accept" "$manifest")" "manifest with a key"
expect 401 "$(status -H "$accept" "$manifest")" "manifest without a key"

body=$(curl -s --max-time 120 -H "$(bearer "$KEY")" -H "$accept" "$manifest")
digest=$(printf '%s' "$body" | python3 -c '
import json, sys
manifest = json.load(sys.stdin)
print(manifest["manifests"][0]["digest"] if "manifests" in manifest else "")
')
if [ -n "$digest" ]; then
  # busybox publishes a multi-arch list, so the blob belongs to the arch manifest it names.
  manifest=$GATE/v2/library/busybox/manifests/$digest
  expect 200 "$(status -H "$(bearer "$KEY")" -H "$accept" "$manifest")" "arch manifest with a key"
  body=$(curl -s --max-time 120 -H "$(bearer "$KEY")" -H "$accept" "$manifest")
fi
blob=$(printf '%s' "$body" | python3 -c '
import json, sys
print(json.load(sys.stdin)["config"]["digest"])
')
[ -n "$blob" ] || { echo "cannot read a blob digest from the busybox manifest" >&2; exit 1; }

expect 200 "$(status -H "$(bearer "$KEY")" "$GATE/v2/library/busybox/blobs/$blob")" "blob with a key"
expect 401 "$(status "$GATE/v2/library/busybox/blobs/$blob")" "blob without a key"

# v0.11.0 logs "container manifest request" at debug level only, and the proxy runs at info. At
# info it logs the manifest's request line and the upstream fetch of the blob, which show the
# pull went through the proxy.
grep '"msg":"request"' "$PROXY_LOG" | grep -q '"path":"/v2/library/busybox/manifests/' \
  || { echo "no request for the busybox manifest in the proxy's log" >&2; exit 1; }
grep '"msg":"fetching from upstream"' "$PROXY_LOG" | grep -q '"ecosystem":"oci"' \
  || { echo "no oci upstream fetch in the proxy's log" >&2; exit 1; }

# A named upstream: BuildKit and containerd name the original registry in the ns parameter. The
# estate's own packages-proxy image is public on ghcr.io.
ghcr="$GATE/v2/jorisjonkers-dev/packages-proxy/manifests/v0.11.0-jj.2?ns=ghcr.io"
expect 200 "$(status -H "$(bearer "$KEY")" -H "$accept" "$ghcr")" "ghcr.io manifest with a key"
expect 401 "$(status -H "$accept" "$ghcr")" "ghcr.io manifest without a key"
