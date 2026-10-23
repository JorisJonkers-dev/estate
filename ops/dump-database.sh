#!/usr/bin/env bash
# Dump one platform-postgres database to Garage's handover-dumps bucket: the
# rollback point recorded before fleet-infra hands an application to deploy-kit.
#
# Usage:
#   ops/dump-database.sh run <database>
#
# Shows the plan, asks once, then:
#   - takes a pg_dump -Fc and the table row counts in one snapshot, so a database
#     that keeps writing still has counts that describe the dump;
#   - writes it to s3://handover-dumps/<database>/<database>-<UTC time>.dump with
#     its SHA-256 as metadata, and reads it back by size and checksum;
#   - restores it into a scratch database whose row counts must match, then
#     drops the scratch database whatever the outcome.
#
# The bucket and its key (`handover-dumps`) are created if missing. The key's
# secret goes to `aws` through the environment only, never a command line, and is
# never printed. Restoring later needs only the Garage CLI to read the key again.
set -euo pipefail

CTX="${KUBE_CONTEXT:-personal}"
BUCKET=handover-dumps
KEY_NAME=handover-dumps

k() { kubectl --context "$CTX" "$@"; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
garage() { k -n data-system exec deploy/garage -- /garage "$@"; }
pg() { k -n data-system exec -i deploy/postgres -c postgres -- "$@"; }
s3() { aws --endpoint-url "$ENDPOINT" --region garage "$@"; }

confirm() {
  local answer=""
  printf '%s [y/N] ' "$1"
  read -r answer || true
  [ "$answer" = y ]
}

# Table row counts, one "schema.table|count" line each.
COUNTS_SQL="select table_schema || '.' || table_name,
    (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
  from information_schema.tables
  where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')
  order by 1;"

# Writes the dump to $2 and the row counts of the same snapshot to $3.
dump_with_counts() {
  pg psql -U postgres -d "$1" -Atq -v ON_ERROR_STOP=1 > "$2" 2> "$3" <<SQL
begin isolation level repeatable read;
select pg_export_snapshot() as snap \gset
\setenv SNAP :snap
\! pg_dump -U postgres -Fc --snapshot="\$SNAP" $1
\o /dev/stderr
$COUNTS_SQL
commit;
SQL
}

garage_bucket() {
  garage bucket info "$BUCKET" >/dev/null 2>&1 || garage bucket create "$BUCKET" >/dev/null
}

# Reads the bucket key into the environment, creating and granting it first.
garage_login() {
  local info
  info=$(garage key info "$KEY_NAME" --show-secret 2>/dev/null) || {
    garage key create "$KEY_NAME" >/dev/null
    info=$(garage key info "$KEY_NAME" --show-secret)
  }
  garage bucket allow --read --write "$BUCKET" --key "$KEY_NAME" >/dev/null
  AWS_ACCESS_KEY_ID=$(sed -n 's/^Key ID: *//p' <<< "$info")
  AWS_SECRET_ACCESS_KEY=$(sed -n 's/^Secret key: *//p' <<< "$info")
  [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || die "could not read Garage key $KEY_NAME"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

open_endpoint() {
  if [ -n "${GARAGE_ENDPOINT:-}" ]; then ENDPOINT="$GARAGE_ENDPOINT"; return; fi
  k -n data-system port-forward svc/garage 13900:3900 >/dev/null 2>&1 &
  PF=$!
  ENDPOINT=http://127.0.0.1:13900
  for _ in $(seq 1 20); do curl -s -o /dev/null "$ENDPOINT" && return; sleep 0.5; done
  die "Garage's S3 API did not answer on $ENDPOINT"
}

upload() {
  local file="$1" key="$2" sha size head
  sha=$(shasum -a 256 "$file" | cut -d' ' -f1)
  size=$(wc -c < "$file" | tr -d ' ')
  s3 s3 cp "$file" "s3://$BUCKET/$key" --metadata "sha256=$sha" >/dev/null
  head=$(s3 s3api head-object --bucket "$BUCKET" --key "$key")
  [ "$(jq -r '.ContentLength' <<< "$head")" = "$size" ] || die "$key: Garage holds a different size than the $size bytes uploaded"
  [ "$(jq -r '.Metadata.sha256' <<< "$head")" = "$sha" ] || die "$key: Garage holds a different checksum"
  printf 'Written (key, bytes, sha256):\n  %s  %s  %s\n' "$key" "$size" "$sha"
}

restore_check() {
  local dump="$1" counts="$2" scratch_counts
  SCRATCH_DB="${DATABASE}_handover_check"
  pg dropdb -U postgres --if-exists "$SCRATCH_DB" >/dev/null 2>&1
  pg createdb -U postgres "$SCRATCH_DB" >/dev/null
  pg pg_restore -U postgres --no-owner -d "$SCRATCH_DB" < "$dump" || true
  scratch_counts=$(pg psql -U postgres -d "$SCRATCH_DB" -Atc "$COUNTS_SQL")
  pg dropdb -U postgres "$SCRATCH_DB" >/dev/null
  SCRATCH_DB=""
  [ "$(cat "$counts")" = "$scratch_counts" ] || die "scratch restore row counts differ from $DATABASE's snapshot"
  printf '  %s: scratch restore row counts match (%s tables)\n' "$DATABASE" "$(grep -c . "$counts")"
}

cleanup() {
  if [ -n "${SCRATCH_DB:-}" ]; then pg dropdb -U postgres --if-exists "$SCRATCH_DB" >/dev/null 2>&1 || true; fi
  [ -z "${PF:-}" ] || kill "$PF" 2>/dev/null || true
  [ -z "${WORK:-}" ] || rm -rf "$WORK"
}

cmd_run() {
  local key file counts
  key="$DATABASE/$DATABASE-$(date -u +%Y%m%dT%H%M%SZ).dump"
  printf 'Dump to Garage:\n  %s -> s3://%s/%s\n' "$DATABASE" "$BUCKET" "$key"
  confirm "Dump $DATABASE?" || { echo "nothing dumped"; return 0; }
  WORK=$(mkdir -p "${WORK_DIR:-${TMPDIR:-/tmp}}" && mktemp -d "${WORK_DIR:-${TMPDIR:-/tmp}}/dump.XXXXXX")
  trap cleanup EXIT
  garage_bucket
  garage_login
  open_endpoint
  file="$WORK/$(basename "$key")"
  counts="$WORK/counts"
  dump_with_counts "$DATABASE" "$file" "$counts" || die "pg_dump of $DATABASE failed: $(cat "$counts")"
  upload "$file" "$key"
  restore_check "$file" "$counts"
}

sub="${1:-}"
DATABASE="${2:-}"
[ -n "$sub" ] && [ -n "$DATABASE" ] || die "usage: $0 run <database>"
[[ "$DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]] || die "$DATABASE is not a plain database name"
case "$sub" in
  run) cmd_run ;;
  *) die "unknown command $sub" ;;
esac
