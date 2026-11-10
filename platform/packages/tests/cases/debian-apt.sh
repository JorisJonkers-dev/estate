# apt through the gate: bookworm's InRelease, its main Packages index and the git .deb that
# index points to arrive with the key and are refused without it.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

repo=$GATE/debian
inrelease=$repo/dists/bookworm/InRelease
expect 200 "$(status -H "$(bearer "$KEY")" "$inrelease")" "InRelease with a key"
expect 401 "$(status "$inrelease")" "InRelease without a key"

index=$repo/dists/bookworm/main/binary-amd64/Packages.gz
expect 200 "$(status -H "$(bearer "$KEY")" "$index")" "Packages with a key"
expect 401 "$(status "$index")" "Packages without a key"

deb=$(curl -s --max-time 120 -H "$(bearer "$KEY")" "$index" | python3 -c '
import gzip, sys
text = gzip.decompress(sys.stdin.buffer.read()).decode("utf-8", "replace")
for block in text.split("\n\n"):
    fields = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
    fields = {name: value.strip() for name, value in fields.items()}
    if fields.get("Package") == "git":
        print(fields["Filename"])
        break
')
[ -n "$deb" ] || { echo "cannot find git in the Packages index" >&2; exit 1; }

expect 200 "$(status -H "$(bearer "$KEY")" "$repo/$deb")" "git .deb with a key"
expect 401 "$(status "$repo/$deb")" "git .deb without a key"

# The security archive is served at /debian/security/; other roots under /debian/ and other
# apk repositories are not open, with a key or without.
security=$repo/security/dists/bookworm-security/InRelease
expect 200 "$(status -H "$(bearer "$KEY")" "$security")" "security InRelease with a key"
expect 401 "$(status "$security")" "security InRelease without a key"
expect 401 "$(status -H "$(bearer "$KEY")" "$repo/indices/")" "/debian/indices/ with a key"
expect 401 "$(status -H "$(bearer "$KEY")" "$GATE/apk/other/v3.24/main/x86_64/APKINDEX.tar.gz")" "an unconfigured apk repository with a key"
