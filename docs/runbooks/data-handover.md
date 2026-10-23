# Handing the data Project over to the estate path

The `data` Project is the shared Postgres (`platform-postgres`), RabbitMQ
(`platform-rabbitmq`) and Valkey (`platform-valkey`) in `data-system`. Today
fleet-infra's `apps-data` Kustomization delivers them. This runbook moves them
to the estate path on deploy-kit 0.31.0, using the three changes in deploy-kit
`spec/v1/60-setup.md#handing-over-one-project-at-a-time`.

- Tracking: JorisJonkers-dev/homelab-collections#15, under the handovers epic
  estate#204 and the umbrella epic estate#202.
- Decision (2026-10-23): hand data over before deploy-kit 1.0, against
  deploy-kit#373's order. It runs in a maintenance window, after the dumps and
  the restore drill below.
- The cutover is run by the operator, at the keyboard. Every step that writes
  to the cluster or to Vault is marked **(write)**.

Every Postgres client drops its connections once. **Expect 2 to 4 minutes
without Postgres, RabbitMQ and Valkey.** The new pods cannot start until the
data Project's own Vault policy Job has written their roles (54 to 89 s per run
so far) and VSO has synced their Secrets.

## What changes

Each change is a pull request. Merge only in the order of
[The cutover](#the-cutover).

| # | repository | pull request | merges |
|---|---|---|---|
| F0 | fleet-infra | fleet-infra#536, scrape the ServiceMonitors deploy-kit renders | before the window |
| A | estate | estate#215, the project file (this file comes with it) | before the window, then an estate release |
| F1 | fleet-infra | fleet-infra#537, orphan (handover change 1) | before the window, once A is released |
| F2 | fleet-infra | fleet-infra#538, drop and rename (handover change 2) | in the window |
| B | estate | estate#216, the ledger (handover change 3) | in the window, then an estate release |
| F3 | fleet-infra | fleet-infra#539, retire `rabbitmq-definitions-backup` | after verification |

### Why the fleet-infra Kustomization is renamed

The estate path names a Project's unit `apps-<project>`. For data that is
`apps-data`, the name of fleet-infra's Kustomization today. Two Kustomizations
cannot share a name in `flux-system`.

If the estate's `apps-data` were applied while fleet-infra's still existed, the
two sources would rewrite one object. The first time the estate's spec won, a
pruning Kustomization would garbage-collect everything its old inventory held
that the new path does not hold: Vault, Garage, Mongo and the namespace.

So the renaming happens in two fleet-infra changes:

1. **F1** sets `prune: false` on fleet-infra's `apps-data`.
2. **F2** deletes `apps-data` and creates `apps-data-leftovers` on the same
   path. Because of F1, deleting `apps-data` removes nothing. The new
   Kustomization adopts Vault, Garage, Mongo, the priority classes and the
   RabbitMQ route.

`apps-latex`, `apps-utility-system` and `apps-knowledge-platform` follow the
new name.

### Why `projects/_estate/source.yaml` is deleted by hand

While `data` is legacy, the estate-scoped artifact `_estate` holds one unit,
`estate-vso-secrets`, with the Postgres catalog and its policy job, in
`data-system`. Once `data` is `estate`, deploy-kit 0.31 puts the catalog in
data's own unit (deploy-kit#482, #561), and `_estate` holds nothing. In that
case composition publishes no `_estate` artifact.

Composition also does not remove the committed `projects/_estate/source.yaml`
(checked with a local composition). Left in place, it would keep applying the
old catalog, with the old admin login, beside data's own catalog. The two would
rewrite the same `CronJob/postgres-catalog`, `ServiceAccount/postgres-catalog`
and `CronJob/vault-policy` back and forth.

Change B therefore deletes the file. Flux then deletes `estate-vso-secrets`. Its
garbage collection skips every object that data's unit has relabelled.

## The render, against the live objects

Composed locally with deploy-kit 0.31.0, built from tag `v0.31.0`. The inputs
were every participant's real `latest` fragment, the previous composed lock,
the committed pins and `cluster-state.yml`, plus Platform and data fragments
published from these branches:

- `main`: no pin moves, which reproduces production.
- A alone: no pin moves. `data` is still legacy, so A is safe to release.
- A and B: `pins move for: data`. The first pin source carries the
  Deployment `force` patch. Eight consumers' sources are rewritten with
  `dependsOn: apps-data`, and that deploys nothing. There is no `_estate`
  artifact.

The rendered pod shapes were booted locally with the same image digests.
Each data directory was first initialised by the image's own root
entrypoint, as live:

- Postgres ran as 999:999 on a read-only root, with `postgresql.conf` mounted
  over the data directory's own copy. It reported `max_connections` 150,
  `pg_stat_statements` and `idle_session_timeout` 1h, so the tuned config is
  read.
- The exporter Process served `pg_up 1` and `pg_database_collation_drifted`.
- RabbitMQ ran as 100:101 and Valkey as 999:1000, each on a read-only root.
  Both started on the existing data, and Valkey read its existing key.

| object | live (fleet-infra) | render (estate path) | consequence |
|---|---|---|---|
| Service names | `postgres`, `rabbitmq`, `valkey` | the same | every alias `platform-*` → `*.data-system.svc` keeps resolving |
| Service ports | postgres `db:5432`, `metrics:9187`; valkey `db:6379`, `metrics:9121`; rabbitmq `amqp`, `management`, `metrics` | postgres `postgres:5432` only; `postgres-exporter` Service `metrics:9187`; valkey `redis:6379`, `metrics:9121`; rabbitmq unchanged | port numbers unchanged; port names change; nothing selects by port name |
| Service selector | `app.kubernetes.io/name` | `app.kubernetes.io/instance` | applied with the Deployments; old pods leave the endpoints at once |
| Deployment selector | `app.kubernetes.io/name` | `name` + `instance` | immutable: the first pin recreates all three (`force: Enabled`) |
| Claims | `postgres-data` 20Gi, `rabbitmq-data` 10Gi, `valkey-data` 5Gi, RWO, local-path | same names and sizes, plus `prune: disabled` | adopted in place, data kept |
| New claims | none | `postgres-data-backup` 20Gi, `rabbitmq-data-backup` 10Gi | bound on frankfurt-contabo-1 at the first backup run |
| Pod security | none set: each entrypoint starts as root and drops to the image user | `runAsNonRoot`, uid/gid from the images lock: postgres 999/999, rabbitmq 100/101, valkey 999/1000; `fsGroup` the same; RuntimeDefault seccomp; read-only root; all capabilities dropped | on-disk owners must already be those uids; checked in pre-check 4 |
| Placement | `nodeSelector platform.jorisjonkers.dev/site: frankfurt` | node affinity `kubernetes.io/hostname: frankfurt-contabo-1`, the node the claim is bound to | the same node |
| Priority | `priorityClassName: platform-data` | none | **gap**, deploy-kit#390 |
| Resources | postgres 1536Mi/4Gi, cpu 300m/1500m; rabbitmq 768Mi/1Gi, 200m/800m; valkey 256Mi/768Mi, 150m/500m; exporters 64Mi and 32Mi | request = limit: postgres 4Gi, rabbitmq 1Gi, valkey 768Mi, postgres-exporter 128Mi, valkey-exporter 96Mi; cpu requests kept, no cpu limit | +3.4Gi requested on frankfurt (14.5Gi → about 17.9Gi of 23.5Gi allocatable) |
| Postgres config | `-c config_file=/etc/postgresql/postgresql.conf` | the same file mounted at `/var/lib/postgresql/data/postgresql.conf` | a Process authors no command; the file shadows initdb's copy |
| Postgres init script | `/docker-entrypoint-initdb.d/init-databases.sh` | absent | runs only on an empty data directory; the catalog creates the estate databases; a rebuild is a restore |
| Postgres env | Vault Agent template: `POSTGRES_DB`, `POSTGRES_USER/PASSWORD`, `AUTH_DB_*`, `AGENTS_DB_*`, `KB_DB_*` | VSO Secret, `envFrom` keys: `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | the `AUTH/AGENTS/KB` pairs fed only the init script and are not delivered |
| Postgres probes | `exec pg_isready` (startup 60×10s, liveness 30s×10) | tcp 5432 (startup 120×5s, liveness 10s×3) | **gap**: tcp passes for a wedged postmaster; `PostgresDown` still fires |
| Exporter | sidecar, `localhost:5432`, `--extend.query-path` | Process `postgres-exporter` on frankfurt, `DATA_SOURCE_URI=postgres:5432/…`, `PG_EXPORTER_EXTEND_QUERY_PATH`, queries as an Asset | the collation-drift query survives; job label becomes `postgres-exporter` (no rule or dashboard reads it) |
| RabbitMQ env | template: `RABBITMQ_DEFAULT_USER/PASS` | the same two keys, from VSO | unchanged |
| Valkey env | `VALKEY_EXTRA_FLAGS` | the same, also handed to the exporter sidecar | harmless |
| Vault | injector init container, roles `postgres` and `rabbitmq` | VSO `VaultStaticSecret`, roles `data-system-postgres`, `-postgres-exporter`, `-rabbitmq`, written by data's own `vault-policy` Job | the old roles stay in Vault, unused |
| ServiceMonitors | `postgres`, `rabbitmq`, `valkey`, labelled `release: metrics-stack` | `postgres-exporter`, `rabbitmq`, `valkey`, no `release` label, `scrapeTimeout: 10s` | F0 makes Prometheus select them; without F0 every data alert goes silent |
| Namespace | applied by fleet-infra | applied by data's unit, label `managed-by: deploy-kit` | **hazard**: see [Rollback](#rollback) |
| Catalog | `estate-vso-secrets`, admin `secret/data/platform/postgres` (`postgres.user`, `postgres.password`) | data's unit, admin `secret/data/data/postgres/catalog` (`user`, `password`) | same 7 databases and roles; the document must exist first (pre-check 2) |
| Backups | `observability/postgres-logical-backup` (pg_dumpall 02:30, 30 days), `observability/rabbitmq-definitions-backup` (03:00, failing since 2026-08-27) | `postgres-data-backup` (02:45, 90 copies, off-cluster requested), `rabbitmq-data-backup` (03:15, 14 copies) | **gap**: the postgres method fails every run (see below); the old postgres backup stays |
| Network policy | none in data-system | rendered, not applied (render-only) | fleet-infra's consumer egress policies select `app.kubernetes.io/name`, which the render keeps |
| Route | fleet-infra `IngressRoute rabbitmq` → `rabbitmq:15672` | none while any Project is legacy | stays in `apps-data-leftovers`; the port matches the `management` surface |
| revisionHistoryLimit | 3 (fleet-infra patch) | the default, 10 | a few more ReplicaSets |

### Gaps, and what is done about each

1. **No priority class** (deploy-kit#390). The data tier loses
   `platform-data`, so under CPU pressure on frankfurt it can no longer preempt
   application pods. The PriorityClass objects stay in `apps-data-leftovers`
   for Vault. Accepted until #390.
2. **Exporter custom queries.** An Asset mounts into its Process's own
   container, never into a sidecar. The exporter therefore becomes its own
   Process with the queries as an Asset, which keeps the
   `PostgresCollationDrift` alert (#480).
3. **`pg_isready` probes.** Not expressible. `PostgresDown` (`pg_up == 0`)
   reports a wedged postmaster, but nothing restarts it.
4. **Postgres `config_file`.** No command field, so the config is mounted where
   Postgres reads it by default. On an empty data directory initdb would refuse
   the non-empty directory. A rebuild is therefore a restore from a dump, never
   a fresh initdb.
5. **The static logins in `secret/platform/postgres`** (`auth.*`, `agents.*`,
   `kb.*`) stay data in Vault and are no longer delivered. auth-api and
   agents-api keep reading them where they do today. The `knowledge-platform`
   keys stay until the maintainer decides (HANDOVER section 2, item 11).
6. **Derived ServiceMonitors carry no `release: metrics-stack` label.** Fixed
   on the Prometheus side by F0, which also fixes n8n. That Project has been
   unscraped since its handover.
7. **The derived Postgres backup cannot succeed.** `irreplaceable` requests an
   off-cluster copy. delivery's backup method (0.9.2, still so on main) writes
   the local copy, then exits with `an off-cluster copy is not made yet`. With
   `restartPolicy: OnFailure`, each night re-dumps up to the default
   `backoffLimit` and ends in a Failed Job.
   - `postgres-logical-backup` stays in fleet-infra until delivery copies
     off-cluster.
   - Operator decision: keep `irreplaceable`, which is honest about the data
     but noisy, or declare `recoverable` until delivery implements the copy.
8. **The catalog's admin login moves** to `secret/data/data/postgres/catalog`.
   Nobody has written it yet (pre-check 2). Without it the catalog Job fails,
   `apps-data` never becomes Ready, and the eight consumer units that now
   follow it stop reconciling. Their running pods are not affected.
9. **Composition leaves `projects/_estate/source.yaml` in place** when the
   estate-scoped artifact empties. B deletes it by hand. This is worth a
   deploy-kit issue.
10. **`dump-database.sh` refuses hyphenated database names**
    (`^[a-z_][a-z0-9_]*$`). `estate-dashboard_db` and `findability-explorer_db`
    cannot be dumped with it; pre-check 1 covers them with `pg_dumpall`.
11. **RabbitMQ's node name follows the pod name.** Every new pod starts in a
    fresh `mnesia/rabbit@<pod>` directory, so queues and messages never
    survived a restart, and do not survive this one. This is unchanged from
    today.
12. **The namespace is the estate's** once B lands, and it also holds Vault,
    Garage and Mongo. Anything that would delete data's pin source with
    pruning on would delete the namespace. See [Rollback](#rollback).

## Pre-checks (before the window)

Run from `JorisJonkers-dev/fleet-infra` unless a step says otherwise.
`kubectl` means `kubectl --context personal`.

### 1. Dumps

Take one dump per database to Garage's `handover-dumps` bucket. The script
dumps one snapshot, uploads it, reads it back by size and SHA-256, restores it
into a scratch database and compares row counts. **(write: a scratch database
in the production Postgres, dropped afterwards)**

```bash
for db in auth_db agents_db grimoire_db hindsight_db n8n_db outline_db tribelt_db; do
  scripts/ops/dump-database.sh run "$db"
done
```

`estate-dashboard_db` and `findability-explorer_db` do not fit the script's
name check (gap 10). `pg_dumpall` covers them, and every role:

```bash
job=postgres-logical-backup-handover-$(date -u +%Y%m%d%H%M%S)
kubectl -n observability create job --from=cronjob/postgres-logical-backup "$job"   # (write)
kubectl -n observability wait --for=condition=complete "job/$job" --timeout=10m
```

Record each object, its byte count and SHA-256 in fleet-infra
`docs/handover-dumps.md`, as for `n8n_db`. Copy the `pg_dumpall` output off the
`observability-backups` claim: the 02:30 run overwrites `postgres.sql`.

List every database, in case one exists that neither list names. This is a
read-only query, so run it yourself with `!`:

```bash
kubectl -n data-system exec deploy/postgres -c postgres -- psql -U postgres -At \
  -c "select datname from pg_database where not datistemplate order by 1"
```

### 2. Vault documents the estate path reads (write)

Write these through the port-forward and OIDC sign-in in the deploy-kit
HANDOVER, section 6. Each value goes over stdin and is never printed.

| path (KV v2, mount `secret`) | keys | value |
|---|---|---|
| `data/postgres/catalog` | `user`, `password` | the catalog method's login: a copy of the superuser in `platform/postgres` (`postgres.user`, `postgres.password`), the login it uses today |
| `data/postgres/backup` | `PGUSER`, `PGPASSWORD` | `pg_dumpall` needs the superuser: the same copy |
| `data/rabbitmq/backup` | `RABBITMQ_USERNAME`, `RABBITMQ_PASSWORD` | the broker administrator in `platform/rabbitmq` |
| `platform/backup/off-cluster` | (exists?) | read only: check it exists; gap 7 |

```bash
vault kv get -format=json -mount=secret platform/postgres \
  | jq '.data.data | {user: .["postgres.user"], password: .["postgres.password"]}' \
  | vault kv put -mount=secret data/postgres/catalog -
vault kv get -format=json -mount=secret platform/postgres \
  | jq '.data.data | {PGUSER: .["postgres.user"], PGPASSWORD: .["postgres.password"]}' \
  | vault kv put -mount=secret data/postgres/backup -
vault kv get -format=json -mount=secret platform/rabbitmq \
  | jq '.data.data | {RABBITMQ_USERNAME: .["rabbitmq.user"], RABBITMQ_PASSWORD: .["rabbitmq.password"]}' \
  | vault kv put -mount=secret data/rabbitmq/backup -
# Read back the key names, never the values:
for p in data/postgres/catalog data/postgres/backup data/rabbitmq/backup platform/backup/off-cluster; do
  printf '%s: ' "$p"; vault kv get -format=json -mount=secret "$p" | jq -c '.data.data | keys'
done
```

### 3. Restore drill on a scratch instance

The script's own check restores into the production Postgres. Prove the dumps
also restore on a Postgres that shares nothing with production. Use the same
image digest, in a scratch namespace that nothing else uses. **(write: a
throwaway namespace)**

```bash
kubectl create namespace data-restore-drill
kubectl -n data-restore-drill run pg --restart=Never \
  --image=docker.io/pgvector/pgvector@sha256:feb68f4f15446397d8cac7f4fe48fe4586de83160d1fc48b46283312d1a33966 \
  --env=POSTGRES_PASSWORD=drill \
  --overrides='{"spec":{"nodeSelector":{"platform.jorisjonkers.dev/site":"frankfurt"}}}'
kubectl -n data-restore-drill wait --for=condition=ready pod/pg --timeout=2m
# For each dump fetched from Garage (docs/handover-dumps.md#restoring):
kubectl -n data-restore-drill exec -i pg -- createdb -U postgres tribelt_db
kubectl -n data-restore-drill exec -i pg -- pg_restore -U postgres --no-owner -d tribelt_db < tribelt_db.dump
# Compare the row counts with the dump's: the COUNTS_SQL in scripts/ops/dump-database.sh.
kubectl delete namespace data-restore-drill
```

Record the comparison per database in homelab-collections#15.

### 4. Owners of the data on disk (read-only, on the node)

The rendered pods run as the image users and cannot change ownership. Postgres
also refuses a data directory it does not own:

```bash
ssh root@100.108.144.93 'cd /var/lib/rancher/k3s/storage &&
  stat -c "%u:%g %a %n" pvc-fa71b712-8d2d-4a38-9991-113bec4c242c_data-system_postgres-data \
                        pvc-08a85d74-c3ba-430a-9f8a-304ce14dce74_data-system_rabbitmq-data \
                        pvc-32687017-2986-4f1d-85cd-c699400104ba_data-system_valkey-data &&
  find pvc-fa71b712-8d2d-4a38-9991-113bec4c242c_data-system_postgres-data \! -uid 999 | head &&
  find pvc-08a85d74-c3ba-430a-9f8a-304ce14dce74_data-system_rabbitmq-data \! -uid 100 | head &&
  find pvc-32687017-2986-4f1d-85cd-c699400104ba_data-system_valkey-data \! -uid 999 | head'
```

Expected:

- Postgres `999:999 700`, RabbitMQ owned by `100`, Valkey by `999`.
- The three `find`s print nothing, apart from the top-level directories if
  local-path created them as root. Those need only be writable by the user:
  check their mode.

Anything else gets fixed before the window, never in it:
`chown -R 999:999 …` with the pod stopped.

### 5. Reclaim policy (write, recommended)

All three volumes are `reclaimPolicy: Delete`. One mistaken claim deletion would
erase the data. Set them to `Retain` for the handover:

```bash
for pv in pvc-fa71b712-8d2d-4a38-9991-113bec4c242c pvc-08a85d74-c3ba-430a-9f8a-304ce14dce74 pvc-32687017-2986-4f1d-85cd-c699400104ba; do
  kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
done
```

### 6. Every consumer

Each of these loses its connections once, in the window:

| consumer | path | reaches |
|---|---|---|
| auth-api (`auth-system`) | old path | postgres `auth_db` (static `auth.*` login), valkey (HTTP sessions), rabbitmq |
| agents-api, agents-api enschede-ws | old path | postgres `agents_db` (static `agents.*`), valkey, rabbitmq |
| tribelt, grimoire, outline, n8n, hindsight (api, worker), estate-dashboard, findability-explorer | estate path, alias `platform-postgres` | their `<project>_db` with Vault dynamic `<project>-owner` logins |
| outline, immich | estate path, alias `platform-valkey` | valkey |
| Vault database engine | connection `postgres` → `postgres.data-system.svc:5432` | issues every dynamic login |
| gatus | old path | tcp checks on 5432, 5672, 6379 |
| `observability/postgres-logical-backup`, `rabbitmq-definitions-backup` | old path | pg_dumpall; management API |

Pick a time when no n8n workflow or tribelt import is due.

### 7. Before the window, merged and checked

1. **F0** merged and published, and Prometheus reloaded. Check that n8n is now
   a target: `up{namespace="n8n-system"}` returns 1.
2. **A** merged, and the estate release that follows merged. The "Deliver to
   production" run reports `pins move for: none`, or only Projects that moved
   for other reasons, and never `data`.
3. **F1** merged and published (workspace CLAUDE.md: wait for
   `deploy/production`). Then check that each mark reached the live objects:

   ```bash
   kubectl -n flux-system get kustomization apps-data -o jsonpath='{.spec.prune}'   # false
   for o in deploy/postgres deploy/rabbitmq deploy/valkey svc/postgres pvc/postgres-data; do
     kubectl -n data-system get $o -o jsonpath="{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{'\n'}"
   done                                                                               # disabled ×5
   kubectl get ns data-system -o jsonpath="{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}"  # disabled
   ```

## The cutover

The steps are strictly in order. Each one names what to read back before going
on.

1. **Merge F2** (fleet-infra), wait for `deploy/production` to publish, then
   `flux reconcile kustomization flux-system --with-source`. Check:
   - `kubectl -n flux-system get kustomization apps-data` is `NotFound`, and
     `apps-data-leftovers` is Ready.
   - `kubectl -n data-system get sts vault -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}'`
     reads `apps-data-leftovers`.
   - `kubectl -n data-system get deploy postgres rabbitmq valkey` still shows
     three Available Deployments, now applied by nothing.

   If `apps-data` is still there, stop: its finalizer is running. Read
   `kubectl -n flux-system describe kustomization apps-data`.
2. **Hold the estate path (write):**
   `flux suspend kustomization estate-pins -n flux-system`. Nothing the pins
   name is applied until step 6, so the pin and the removal of `_estate` land
   together, after the old pods are down.
3. **Merge B** (estate), then **merge the release-please PR** it opens. The
   release publishes the Platform and data fragments and starts "Deliver to
   production". Wait for that run, the one whose `headSha` is the release
   commit:
   - Its summary says `pins move for: data`, plus any other Project's own
     release.
   - Its pin commit on `main` adds `projects/data/source.yaml`, with a
     `patches` entry targeting `Deployment` with `force: Enabled`.
4. **Record the row counts (read-only, `!`).** For each database, run the
   `COUNTS_SQL` from `scripts/ops/dump-database.sh` and save the output
   locally as `before-<db>.txt`.
5. **Stop the old datastores (write)**, so that no two Postgres processes ever
   share the data directory while Flux recreates the Deployments. **The outage
   starts here.**

   ```bash
   kubectl -n data-system scale deploy postgres rabbitmq valkey --replicas=0
   kubectl -n data-system wait --for=delete pod -l 'app.kubernetes.io/name in (postgres,rabbitmq,valkey)' --timeout=2m
   ```
6. **Resume (write):**
   `flux resume kustomization estate-pins -n flux-system`, then
   `flux reconcile kustomization estate-pins -n flux-system --with-source`. Flux:
   - deletes `estate-vso-secrets` and the `estate` OCIRepository;
   - creates `project-data` and `apps-data`;
   - recreates the three Deployments, and the exporter's.

   Watch:

   ```bash
   flux get kustomizations -n flux-system | grep -E 'apps-data|estate'
   kubectl -n data-system get pods -w
   kubectl -n data-system get job -l app.kubernetes.io/name=vault-policy
   ```

   In order: `vault-policy-<hash>` completes, the VSO Secrets appear, then
   postgres, valkey, rabbitmq and postgres-exporter become Ready, then
   `postgres-catalog-<hash>` completes. **The outage ends at postgres Ready.**
7. If no postgres pod is Ready within 5 minutes, read its events and logs, and
   go to [Rollback](#rollback). Common causes:
   - `CreateContainerConfigError`: the Secret is missing. Read
     `kubectl -n data-system describe vaultstaticsecret postgres-platform-postgres`.
   - `data directory has wrong ownership`: pre-check 4 was wrong.

## Verification

Every item reads a value, not an exit code:

1. **Flux.**
   - `apps-data` is Ready at the pinned revision.
   - `kubectl -n flux-system get kustomization estate-vso-secrets` is
     `NotFound`.
   - The eight consumer units are Ready.
2. **Pods.**
   - Each pod is labelled `app.kubernetes.io/managed-by=deploy-kit` and
     `app.kubernetes.io/version` with the release.
   - No pod has a `vault-agent-init` container.
   - `kubectl -n data-system get pod -l app.kubernetes.io/instance=postgres -o jsonpath='{.items[0].spec.securityContext.runAsUser}'`
     reads `999`.
3. **Config read (read-only, `!`).**
   `psql -U postgres -Atc "show max_connections; show shared_preload_libraries"`
   returns `150` and `pg_stat_statements`.
4. **Row counts.** Run step 4's query again into `after-<db>.txt` and `diff`
   each pair. A table with *fewer* rows is a stop. A table with more rows took
   writes after the count.
5. **Canaries.** `kubectl get canary -A` shows every canary `Succeeded`. A
   `Failed` one gets a `kubectl rollout restart` of its target (HANDOVER
   section 6).
6. **Vault dynamic credentials still issue.**
   - Every `VaultDynamicSecret` (`kubectl get vaultdynamicsecret -A`) stays
     Healthy.
   - Within one renewal (≤ 40 min) each shows a newer `.status.lastRenewalTime`
     or a new lease.
   - Read only the role's name, never a password, with the sessions query from
     HANDOVER section 6: each Project still has a live `v-kubernet-<project>…`
     login.
7. **Catalog.** `postgres-catalog-<hash>` is Complete, and so is the next
   hourly run. Its log names all 7 databases as present, with nothing adopted.
8. **Old-path consumers.**
   - auth-api login works, which needs Postgres, Valkey sessions and RabbitMQ.
   - agents-api answers its own health endpoint, and its pods are Ready.
   - The gatus checks for 5432, 5672 and 6379 are green.
9. **Metrics.** In Prometheus, each returns a value:
   - `pg_up == 1`;
   - `pg_database_collation_drifted`, one series per database;
   - `redis_up == 1`;
   - `rabbitmq_identity_info`.

   No `*MetricsMissing` alert fires after 15 minutes.
10. **Backups, run once now (write).**

    ```bash
    kubectl -n data-system create job --from=cronjob/rabbitmq-data-backup rabbitmq-data-backup-handover
    kubectl -n data-system create job --from=cronjob/postgres-data-backup postgres-data-backup-handover
    ```

    - The rabbitmq Job completes, with a definitions file on
      `rabbitmq-data-backup`.
    - The postgres Job writes its copy, then fails with
      `an off-cluster copy is not made yet` (gap 7). **The first derived backup
      does not land off-cluster with delivery 0.9.2.** Record that on
      homelab-collections#15, and delete the Job so it stops retrying.
    - `postgres-logical-backup` still runs at 02:30 and is the restore point.
11. **Orphans the render does not produce.** They carry `prune: disabled` and
    no source applies them. Delete them once 1 to 10 hold **(write)**:

    ```bash
    kubectl -n data-system delete servicemonitor postgres
    kubectl -n data-system delete configmap postgres-config postgres-exporter-queries postgres-init-script rabbitmq-config rabbitmq-enabled-plugins
    kubectl -n data-system delete job postgres-agents-rename
    ```

12. Merge **F3** (fleet-infra), which retires `rabbitmq-definitions-backup`.
    Set the PV reclaim policy back to `Delete` only if you want to.

## Rollback

The claims are never touched, so a rollback is a delivery rollback. Only a
damaged data directory needs a dump (pre-check 1).

**Before the release in cutover step 3** nothing has changed for the
datastores. Revert F2 (and F1 if wanted), and resume `estate-pins` if it was
suspended.

**After step 6**, undo the three changes in reverse
(`60-setup.md#handing-over-one-project-at-a-time`). **Never delete the
`project-data` source or the `apps-data` Kustomization while it prunes: it owns
the `data-system` namespace, and pruning it deletes Vault, Garage and Mongo
too.**

1. **(write)** `flux suspend kustomization estate-pins -n flux-system`, then
   `kubectl -n flux-system patch kustomization apps-data --type merge -p '{"spec":{"prune":false}}'`.
   Read back `.spec.prune` = `false`.
2. In the estate repository, revert B:
   - put `data` back under `legacy`, and the `serving` entry for
     `platform-postgres` with its `admin`;
   - restore `projects/_estate/source.yaml` from the commit before B;
   - delete `projects/data/source.yaml`.

   Merge it and its release.
3. **(write)** Resume `estate-pins`. Flux deletes the `apps-data` Kustomization
   without pruning (step 1), and `estate-vso-secrets` returns.
4. **(write)** Scale the estate-rendered Deployments to 0:
   `kubectl -n data-system scale deploy postgres rabbitmq valkey postgres-exporter --replicas=0`.
   Then delete `postgres`, `rabbitmq` and `valkey`: their selector differs from
   the old path's, which cannot change it in place.
5. Revert F2 in fleet-infra. `apps-data-leftovers` is replaced by `apps-data`,
   still `prune: false` from F1, and the old manifests, with injector and old
   selectors, come back. Then reconcile.
6. Verify as above, without the catalog and backup items. Then decide whether
   to revert F1.

Clearing the orphaned estate objects (`postgres-exporter`, the backup
CronJobs, VSO objects and `vault-policy` in `data-system`) is a separate
decision, made after the old path serves again.
