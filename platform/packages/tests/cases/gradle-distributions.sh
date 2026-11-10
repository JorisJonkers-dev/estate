# Gradle distributions through the gate: the 9.2.0 binary zip arrives with the key, matches the
# checksum services.gradle.org publishes, and is refused without it. Only distributions/ is
# served, and nothing else under /generic/ passes the gate.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

zip=$GATE/generic/gradle/distributions/gradle-9.2.0-bin.zip
expect 401 "$(status "$zip")" "distribution without a key"
file=$(mktemp)
trap 'rm -f "$file"' EXIT
code=$(curl -s -o "$file" -w '%{http_code}' --max-time 600 -H "$(bearer "$KEY")" "$zip")
expect 200 "$code" "distribution with a key"

want=$(curl -sL --max-time 120 https://services.gradle.org/distributions/gradle-9.2.0-bin.zip.sha256)
[ -n "$want" ] || { echo "cannot read the published checksum" >&2; exit 1; }
expect "$want" "$(sha256sum "$file" | cut -d' ' -f1)" "distribution checksum"

# Outside distributions/ the proxy answers 404 even with a key.
current=$GATE/generic/gradle/versions/current
code=$(status -H "$(bearer "$KEY")" "$current")
case $code in 403 | 404) ;; *) echo "versions/current with a key: want 403 or 404, got $code" >&2; exit 1 ;; esac
expect 401 "$(status "$current")" "versions/current without a key"

# No other generic upstream is open through the gate.
for path in /generic/github/ /generic/ /generic/gradle; do
  code=$(status -H "$(bearer "$KEY")" "$GATE$path")
  case $code in 401 | 404) ;; *) echo "$path with a key: want 401 or 404, got $code" >&2; exit 1 ;; esac
done
