# Helpers for the cases in cases/. Source it: . "$(dirname "$0")/../lib.sh"

# status [curl args...] prints the HTTP status of a GET to the gate.
status() { curl -s -o /dev/null -w '%{http_code}' --max-time 120 "$@"; }

# expect <want> <got> <what> fails the case when got differs from want.
expect() {
  if [ "$1" != "$2" ]; then
    echo "$3: want $1, got $2" >&2
    exit 1
  fi
}

# bearer and basic are the two ways the gate accepts a key.
bearer() { printf 'Authorization: Bearer %s' "$1"; }
basic() { printf 'packages:%s' "$1"; }
