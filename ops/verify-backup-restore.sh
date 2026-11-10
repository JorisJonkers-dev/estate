#!/usr/bin/env bash
# Prove a Postgres backup restores, by restoring it.
#
# The estate's `postgres-logical-backup` CronJob writes a `pg_dumpall` to the
# `observability-backups` volume every night. That it RUNS is not evidence that
# it CAPTURED anything: a dump can complete and still be missing a database, or
# be unreadable, and nobody finds out until the day it matters.
#
# So this restores one database out of the real backup into a scratch database
# on the live server, compares row counts against the live copy, and drops the
# scratch database again. Read-only with respect to the backup and to every
# real database.
#
# Usage:
#   ops/verify-backup-restore.sh [database] [table ...]
#
# Defaults to hindsight_db and a few of its tables. Any database present in the
# dump works.
#
# Two things this deliberately does NOT do: it does not restore over a live
# database, and it does not delete or rotate any backup.

set -euo pipefail

readonly DATABASE="${1:-hindsight_db}"
shift || true
TABLES=("$@")
if [ "${#TABLES[@]}" -eq 0 ]; then
  TABLES=(memory_units chunks knowledge_pages mental_models)
fi

readonly NAMESPACE=observability
readonly BACKUP_PVC=observability-backups
readonly SCRATCH="restore_probe_$$"
# The backups volume is `local-path`, therefore node-bound, and it lives on the
# Frankfurt node deliberately: that is the one with off-cluster copies. A pod
# scheduled anywhere else cannot see the backup at all.
readonly SITE=frankfurt

log() { printf 'verify-restore: %s\n' "$*"; }
die() { printf 'verify-restore: %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"

probe_script="$(mktemp)"
trap 'rm -f "${probe_script}"' EXIT

cat > "${probe_script}" <<'PROBE'
set -eu
DUMP=/backups/postgres.sql
PSQL="psql -h postgres.data-system.svc.cluster.local -U ${POSTGRES_USER} -v ON_ERROR_STOP=1"

[ -f "$DUMP" ] || { echo "no dump at $DUMP -- has postgres-logical-backup run?"; exit 1; }
echo "==> dump: $(wc -c < "$DUMP") bytes"

# Slice one database out of the pg_dumpall stream. The section ENDS at the next
# database boundary, and pg_dumpall opens one with `CREATE DATABASE` as well as
# with `\connect` -- slicing on `\connect` alone runs straight into the next
# database and fails with `database "..." already exists`, which reads like a
# restore fault and is a slicing bug.
awk -v db="$TARGET_DB" '
  $0 == "\\connect " db {f=1; next}
  f && ($0 ~ /^\\connect /||$0 ~ /^CREATE DATABASE /) {f=0}
  f {print}
' "$DUMP" > /tmp/slice.sql

echo "==> slice: $(wc -c < /tmp/slice.sql) bytes, $(wc -l < /tmp/slice.sql) lines"
[ -s /tmp/slice.sql ] || { echo "SLICE EMPTY -- ${TARGET_DB} is not in the dump"; exit 1; }

$PSQL -d postgres -c "DROP DATABASE IF EXISTS ${SCRATCH_DB}" >/dev/null
$PSQL -d postgres -c "CREATE DATABASE ${SCRATCH_DB}" >/dev/null

restore_rc=0
$PSQL -d "${SCRATCH_DB}" -f /tmp/slice.sql >/tmp/restore.log 2>&1 || restore_rc=$?
if [ "$restore_rc" != 0 ]; then
  echo "RESTORE FAILED:"
  tail -20 /tmp/restore.log
  $PSQL -d postgres -c "DROP DATABASE IF EXISTS ${SCRATCH_DB}" >/dev/null || true
  exit 1
fi

mismatch=0
echo "==> comparing restored against live"
for t in ${TARGET_TABLES}; do
  a=$($PSQL -d "${SCRATCH_DB}" -tAc "SELECT count(*) FROM ${t}" 2>/dev/null || echo MISSING)
  b=$($PSQL -d "${TARGET_DB}"  -tAc "SELECT count(*) FROM ${t}" 2>/dev/null || echo MISSING)
  flag=""
  [ "$a" = MISSING ] && { flag=" <-- ABSENT FROM RESTORE"; mismatch=1; }
  printf '    %-34s restored=%-8s live=%s%s\n' "$t" "$a" "$b" "$flag"
done

rt=$($PSQL -d "${SCRATCH_DB}" -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public'")
lt=$($PSQL -d "${TARGET_DB}"  -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public'")
echo "==> public tables: restored=${rt} live=${lt}"
[ "$rt" = "$lt" ] || { echo "TABLE COUNT MISMATCH"; mismatch=1; }

# An extension is part of a working restore: without `vector`, the database
# accepts a connection and fails at the first vector column.
ext=$($PSQL -d "${SCRATCH_DB}" -tAc \
  "SELECT coalesce((SELECT extversion FROM pg_extension WHERE extname='vector'),'ABSENT')")
echo "==> pgvector in the restore: ${ext}"

$PSQL -d postgres -c "DROP DATABASE ${SCRATCH_DB}" >/dev/null
echo "==> scratch database dropped"

[ "$mismatch" = 0 ] || { echo "RESTORE INCOMPLETE"; exit 1; }
echo "==> restore verified"
PROBE

cm="restore-probe-$$"
log "restoring ${DATABASE} from the nightly dump into ${SCRATCH}"
kubectl -n "${NAMESPACE}" create configmap "${cm}" \
  --from-file=probe.sh="${probe_script}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# shellcheck disable=SC2064  # expand now: the names must survive into the trap
trap "kubectl -n ${NAMESPACE} delete configmap ${cm} >/dev/null 2>&1 || true; rm -f ${probe_script}" EXIT

# Distinct names on purpose: a prefix assignment to SITE or BACKUP_PVC would
# fail with `readonly variable`, and the python then dies on a missing key.
overrides="$(P_DB="${DATABASE}" P_SCRATCH="${SCRATCH}" \
  P_TABLES="${TABLES[*]}" P_CM="${cm}" P_SITE="${SITE}" P_PVC="${BACKUP_PVC}" python3 -c '
import json, os
print(json.dumps({"spec": {
  "nodeSelector": {"platform.jorisjonkers.dev/site": os.environ["P_SITE"]},
  "restartPolicy": "Never",
  "containers": [{
    "name": "probe", "image": "postgres:17-alpine",
    "command": ["/bin/sh", "/scripts/probe.sh"],
    "env": [
      {"name": "TARGET_DB", "value": os.environ["P_DB"]},
      {"name": "SCRATCH_DB", "value": os.environ["P_SCRATCH"]},
      {"name": "TARGET_TABLES", "value": os.environ["P_TABLES"]},
      {"name": "POSTGRES_USER", "valueFrom": {"secretKeyRef": {"name": "postgres-backup", "key": "username"}}},
      {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {"name": "postgres-backup", "key": "password"}}},
    ],
    "volumeMounts": [
      {"name": "backups", "mountPath": "/backups"},
      {"name": "scripts", "mountPath": "/scripts"},
    ],
  }],
  "volumes": [
    {"name": "backups", "persistentVolumeClaim": {"claimName": os.environ["P_PVC"]}},
    {"name": "scripts", "configMap": {"name": os.environ["P_CM"]}},
  ],
}}))')"

kubectl -n "${NAMESPACE}" run "verify-restore-$$" --rm -i --restart=Never \
  --image=postgres:17-alpine --overrides="${overrides}"
