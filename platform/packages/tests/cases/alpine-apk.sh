# apk through the gate: the Alpine v3.24 main index and the git package it lists arrive with
# the key and are refused without it.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

repo=$GATE/apk/alpine/v3.24/main/x86_64
index=$repo/APKINDEX.tar.gz
expect 200 "$(status -H "$(bearer "$KEY")" "$index")" "APKINDEX with a key"
expect 401 "$(status "$index")" "APKINDEX without a key"

package=$(curl -s --max-time 120 -H "$(bearer "$KEY")" "$index" | python3 -c '
import gzip, io, sys, tarfile
# The file is two gzip streams, the signature and the index, so it is read whole.
index = tarfile.open(fileobj=io.BytesIO(gzip.decompress(sys.stdin.buffer.read())))
text = index.extractfile("APKINDEX").read().decode("utf-8", "replace")
for block in text.split("\n\n"):
    fields = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
    fields = {name: value.strip() for name, value in fields.items()}
    if fields.get("P") == "git":
        # An Alpine repository serves each package flat, as <name>-<version>.apk.
        print(fields["P"] + "-" + fields["V"] + ".apk")
        break
')
[ -n "$package" ] || { echo "cannot find git in the Alpine index" >&2; exit 1; }

expect 200 "$(status -H "$(bearer "$KEY")" "$repo/$package")" "git package with a key"
expect 401 "$(status "$repo/$package")" "git package without a key"
