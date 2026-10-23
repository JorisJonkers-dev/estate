# Backup coverage and restore proof

What is backed up, what is not, and how to prove a restore rather than assume
one. Written while taking the pre-migration backups for the memory platform.

## Proving a Postgres restore

```bash
ops/verify-backup-restore.sh                    # hindsight_db
ops/verify-backup-restore.sh auth_db oauth2_authorization service_tokens
```

It restores one database out of the **real** nightly dump into a scratch
database on the live server, compares row counts and table counts against the
live copy, checks the `vector` extension came across, and drops the scratch
database. It never restores over a live database and never touches a backup.

A live count above the restored one is **expected** for a table that is still
written to: the dump is from 02:30. A restore that matched exactly would mean
the source had stopped.

## What is covered

| Data | Mechanism | Off-cluster |
|---|---|---|
| every Postgres database | `postgres-logical-backup` CronJob, `pg_dumpall` daily 02:30, 30-day timestamped archive | yes |
| Vault | `vault-raft-snapshot` CronJob, every 6h | yes |
| RabbitMQ definitions | `rabbitmq-definitions-backup` CronJob, daily 03:00 | yes |

All three write to the `observability-backups` PVC. That volume is
`local-path`, therefore node-bound, and is pinned to **`frankfurt-contabo-1`
deliberately: that is the node with daily off-cluster copies.** A backup
written anywhere else sits on a disk nothing copies, which looks identical
until a restore is needed.

## What is NOT covered

This list named only the old knowledge stack's volumes
(`knowledge-vault-clone`, `data-obsidian-livesync-0`, `lightrag-workdir`,
`ollama-models`), and they left with that stack: [fleet-infra's old-stack-archive.md](https://github.com/JorisJonkers-dev/fleet-infra/blob/main/docs/old-stack-archive.md)
lists the verified copies, and why two of them were not archived.

A `ReadWriteOnce` volume already mounted by its own workload cannot be backed
up by mounting it from a CronJob. `kubectl exec ... tar czf -` streamed out is
the mechanism that works.

## Retention is not deletion policy

These snapshots answer disaster recovery. They are **not** the tombstone or
erasure policy for the knowledge platform, and conflating the two means a
deliberate deletion is quietly undone by a restore. Postgres archives are kept
30 days.

## The failure this guards against

A dump that runs is not a dump that captured anything. The
`postgres-logical-backup` job was once pinned at `postgres:16` against a 17.10
server, so `pg_dumpall` refused outright and **every run aborted** — the
backup could not have worked, and nothing said so until someone looked. That
is why the check here restores rather than inspecting a file size.
