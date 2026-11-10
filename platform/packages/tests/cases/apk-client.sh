#!/usr/bin/env bash
# The real apk client through the gate, as a Dockerfile `apk add` runs it: the key comes from
# ~/.netrc (a BuildKit secret mount in the image build), never from the URL, and the signatures
# are checked against alpine-keys. Without the netrc the same command must fail.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

repo=$GATE/apk/alpine/v3.24/main/x86_64
tools=$CASE_TMP/tools
mkdir -p "$tools"

# fetch_package <name> <dir> downloads the newest <name> .apk the index lists and unpacks it.
fetch_package() {
  local file
  file=$(curl -s --max-time 120 -H "$(bearer "$KEY")" "$repo/APKINDEX.tar.gz" | python3 -I -c '
import gzip, io, sys, tarfile
index = tarfile.open(fileobj=io.BytesIO(gzip.decompress(sys.stdin.buffer.read())))
text = index.extractfile("APKINDEX").read().decode("utf-8", "replace")
for block in text.split("\n\n"):
    fields = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
    if fields.get("P") == sys.argv[1]:
        print(fields["P"] + "-" + fields["V"].strip() + ".apk")
        break
' "$1")
  [ -n "$file" ] || { echo "cannot find $1 in the Alpine index" >&2; exit 1; }
  mkdir -p "$2"
  curl -sf --max-time 120 -H "$(bearer "$KEY")" -o "$2.apk" "$repo/$file" || { echo "cannot fetch $file" >&2; exit 1; }
  python3 -I -c '
import sys, tarfile
# An .apk is gzipped tar streams (signature, control, data); tarfile reads them in turn.
tarfile.open(sys.argv[1]).extractall(sys.argv[2], filter="tar")
' "$2.apk" "$2"
}

fetch_package apk-tools-static "$tools/static"
fetch_package alpine-keys "$tools/keys"
apk=$tools/static/sbin/apk.static
[ -x "$apk" ] || chmod +x "$apk"
keys=$tools/keys/usr/share/apk/keys
[ -d "$keys" ] || { echo "alpine-keys has no $keys" >&2; exit 1; }

# A home whose netrc names the gate (127.0.0.1 here, packages.jorisjonkers.dev in the image).
home=$CASE_TMP/home
mkdir -p "$home"
printf 'machine 127.0.0.1 login packages password %s\n' "$KEY" >"$home/.netrc"
chmod 600 "$home/.netrc"
nohome=$CASE_TMP/nohome
mkdir -p "$nohome"

# add_busybox <home> <root> runs the Dockerfile's apk add against the gate, verifying signatures.
add_busybox() {
  env -u NETRC HOME="$1" "$apk" --usermode --root "$2" --initdb --keys-dir "$keys" --repositories-file /dev/null \
    --repository "$GATE/apk/alpine/v3.24/main" --no-scripts --no-cache add busybox
}

if ! out=$(add_busybox "$home" "$CASE_TMP/root-ok" 2>&1); then
  echo "apk add with the netrc failed:" >&2
  echo "$out" >&2
  exit 1
fi
[ -e "$CASE_TMP/root-ok/bin/busybox" ] || { echo "busybox is not under the root after apk add" >&2; exit 1; }

if out=$(add_busybox "$nohome" "$CASE_TMP/root-no" 2>&1); then
  echo "apk add without the netrc succeeded; the netrc is not what authenticates" >&2
  exit 1
fi
[ ! -e "$CASE_TMP/root-no/bin/busybox" ] || { echo "busybox was installed without a key" >&2; exit 1; }
