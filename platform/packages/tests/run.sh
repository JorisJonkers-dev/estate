#!/usr/bin/env bash
# Runs the packages proxy and its gate on this machine, from this directory's config, and checks
# them with every case in cases/ (or the cases named on the command line).
#
# The pod's layout is kept: the proxy on 127.0.0.1:8080, the gate on :8081, the cargo-config
# sidecar on 127.0.0.1:8082. Those ports must be free. The keys are test keys made up for the run;
# no real key is read.
#
# Needs: the proxy binary (PROXY_BIN, default `proxy` on PATH), built from
# JorisJonkers-dev/packages-proxy so it carries the estate's patches; traefik (TRAEFIK_BIN); busybox
# (BUSYBOX_BIN); curl. The cases reach the public registries, so the machine needs the internet.
#
# Usage: platform/packages/tests/run.sh [case.sh ...]
#
# Each case is a bash script that exits 0 when it passes. It gets:
#   GATE        the gate's URL, http://127.0.0.1:8081
#   KEY         a key the gate accepts (the first in config/gate.yml's $keys)
#   KEYS        every accepted key, space-separated, in $keys order
#   PROXY_LOG   the proxy's log file, to check which requests reached it
#   CASE_TMP    a directory of its own
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
config=$here/../config
proxy_bin=${PROXY_BIN:-proxy}
traefik_bin=${TRAEFIK_BIN:-traefik}
busybox_bin=${BUSYBOX_BIN:-busybox}

for tool in "$proxy_bin" "$traefik_bin" "$busybox_bin" curl; do
  command -v "$tool" >/dev/null || { echo "run.sh: $tool is not on PATH" >&2; exit 2; }
done

work=$(mktemp -d)
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# The keys config/gate.yml requires, by name, from its `$keys := list ...` line.
# shellcheck disable=SC2016 # the $ is sed's literal, not a shell expansion
mapfile -t key_names < <(sed -n 's/.*\$keys := list \(.*\) }}.*/\1/p' "$config/gate.yml" | tr -d '"' | tr ' ' '\n' | grep .)
[ "${#key_names[@]}" -gt 0 ] || { echo "run.sh: no \$keys list in config/gate.yml" >&2; exit 2; }
keys=()
for name in "${key_names[@]}"; do
  value=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  export "$name=$value"
  keys+=("$value")
done

# The proxy's own config, with its data paths moved into the work directory.
mkdir -p "$work/data"
sed -e "s|file:///data/|file://$work/data/|g" -e "s|\"/data/|\"$work/data/|g" "$config/proxy.yaml" >"$work/proxy.yaml"
cp "$config/gate.yml" "$work/gate.yml"
sed "s|filename: /etc/traefik/gate.yml|filename: $work/gate.yml|" "$config/traefik.yml" >"$work/traefik.yml"
mkdir -p "$work/cargo"
cp "$config/cargo-config.json" "$work/cargo/config.json"

PROXY_BASE_URL=http://127.0.0.1:8081 "$proxy_bin" serve -config "$work/proxy.yaml" >"$work/proxy.log" 2>&1 &
pids+=($!)
"$busybox_bin" httpd -f -p 127.0.0.1:8082 -h "$work/cargo" &
pids+=($!)
"$traefik_bin" --configFile="$work/traefik.yml" >"$work/traefik.log" 2>&1 &
pids+=($!)

ready=false
for _ in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/.gate/ready)" = 200 ]; then ready=true; break; fi
  sleep 0.5
done
if [ "$ready" != true ]; then
  echo "run.sh: the gate never became ready" >&2
  tail -20 "$work/proxy.log" "$work/traefik.log" >&2
  exit 1
fi

export GATE=http://127.0.0.1:8081 KEY=${keys[0]} KEYS="${keys[*]}" PROXY_LOG=$work/proxy.log

if [ "$#" -gt 0 ]; then cases=("$@"); else cases=("$here"/cases/*.sh); fi
failed=0
for case in "${cases[@]}"; do
  name=$(basename "$case" .sh)
  CASE_TMP=$(mktemp -d "$work/case.XXXX")
  export CASE_TMP
  if out=$(bash "$case" 2>&1); then
    echo "PASS $name"
  else
    echo "FAIL $name"
    printf '%s\n' "$out" | sed 's/^/    /'
    failed=$((failed + 1))
  fi
done
echo "${#cases[@]} case(s), $failed failed"
[ "$failed" -eq 0 ]
