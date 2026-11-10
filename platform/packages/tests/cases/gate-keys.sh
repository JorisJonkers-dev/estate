# The gate admits every key in either form, and nothing else.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
url=$GATE/npm/left-pad
for key in $KEYS; do
  expect 200 "$(status -H "$(bearer "$key")" "$url")" "Bearer key"
  expect 200 "$(status -u "$(basic "$key")" "$url")" "Basic key"
done
expect 401 "$(status "$url")" "no key"
expect 401 "$(status -H "$(bearer wrong)" "$url")" "wrong Bearer key"
expect 401 "$(status -u "nobody:$KEY" "$url")" "Basic key with another user name"
