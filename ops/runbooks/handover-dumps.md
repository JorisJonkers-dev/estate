# Handover dumps

Before fleet-infra hands an application's database to deploy-kit, the database
is dumped to Garage with `ops/dump-database.sh run <database>`. That
dump is the handover's recorded rollback point.

The script takes the dump and the table row counts in one snapshot, so a
database that keeps writing during the dump still has counts that describe it.
It reads the object back by size and SHA-256, and restores it into a scratch
database whose row counts must match before the scratch database is dropped.

Bucket: `handover-dumps` (private, S3 API only), key `handover-dumps`. Objects
are `<database>/<database>-<UTC time>.dump`, in `pg_dump -Fc` format.

| ticket | database | object | bytes | sha256 |
|---|---|---|---|---|
| #464 | `n8n_db` | `n8n_db/n8n_db-20261019T084455Z.dump` | 996300 | `dfabb990a0c23a4c92a14431e9a8eb215af015fa9c6ffae545b10757ced6f075` |

The `n8n_db` dump was taken on 2026-10-19 while n8n ran. Its scratch restore
matched the snapshot's row counts in all 136 tables, and was then dropped.

## Restoring

Read the key with the Garage CLI, fetch the object over the S3 API, then
restore it with `pg_restore`:

```bash
kubectl -n data-system exec deploy/garage -- /garage key info handover-dumps --show-secret
kubectl -n data-system port-forward svc/garage 13900:3900 &
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… aws --endpoint-url http://127.0.0.1:13900 \
  --region garage s3 cp s3://handover-dumps/<object> db.dump
kubectl -n data-system exec -i deploy/postgres -c postgres -- \
  pg_restore -U postgres --no-owner --clean --if-exists -d <database> < db.dump
```

Read the restored database back (its row counts, or the application's own
view of it) before you rely on it.
