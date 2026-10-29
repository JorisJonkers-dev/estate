# Handing `data` over to the estate path

Moves the Project `data` (Postgres, RabbitMQ, Valkey and Garage, namespace
`data-system`, on `frankfurt-contabo-1`) from fleet-infra's old path to its pin
here, on deploy-kit 1.3.0, in the three changes of deploy-kit
`docs/runbooks/handover.md`. Tracking: JorisJonkers-dev/deploy-kit#661, under
the handover epic JorisJonkers-dev/deploy-kit#373.

Every datastore is adopted in place: same namespace, same Service names and
ports, same claims (`postgres-data`, `rabbitmq-data`, `valkey-data`,
`garage-data`), same images by digest. Garage's volume splits in the window
(decided 2026-10-27): its metadata moves onto a new claim, `garage-meta`, and
the data blocks stay on `garage-data`. Each datastore is down while its
Deployment is recreated, and every consumer reconnects once. Run it with the
maintainer present, at a quiet hour. A live step is the maintainer's go-ahead,
never an agent's.

MongoDB, Overleaf's document store in the same namespace, stays on the old path
for now: see W5.

## What it waits on

| | what | where |
|---|---|---|
| W1 | the observability handover, the one before this in the order | JorisJonkers-dev/deploy-kit#660 |
| W2 | three Vault documents the render reads and nobody has written: `secret/data/data/postgres/catalog` (`user`, `password`), `secret/data/data/postgres/backup` (`PGUSER`, `PGPASSWORD`) and `secret/data/data/rabbitmq/backup` (`RABBITMQ_USERNAME`, `RABBITMQ_PASSWORD`), each a copy of a login in `platform/postgres` or `platform/rabbitmq`; and `secret/data/platform/backup/off-cluster`, which mail reads first | a person, [pre-check 3](#pre-checks) |
| W3 | the namespace keeps its prune mark once the render applies it. The render writes `data-system` without one, and server-side apply by the same `kustomize-controller` field manager drops the mark fleet-infra put there. After the flip, one prune of the namespace (a rollback that skips its step 1, a render that drops it) deletes Vault and MongoDB with it | a deploy-kit change, or the maintainer accepting it with every volume on `Retain` |
| W4 | Garage's split: the window, and who runs the copy | the maintainer, [cutover](#cutover) step 3 |
| W5 | platform-mongo: deploy-kit has the `mongo` engine (JorisJonkers-dev/deploy-kit#403), but delivery publishes no `mongo-backup` image, so a declaration is refused `E_NO_ENGINE_POLICY`. Until then MongoDB stays on the old path, in `apps-data-leftovers`. Its handover then also needs the replica set's member host moved from `mongo-0.mongo.data-system.svc.cluster.local`, a StatefulSet name the render does not make | JorisJonkers-dev/delivery, then a change here |

## The changes, in order

| # | where | what | merges | outage |
|---|---|---|---|---|
| D0 | fleet-infra#562 | marks `data-system` and every claim `apps-data` applies `prune: disabled` | now | none |
| P0 | a person | every `data-system` volume reclaims `Retain`: seven read `Delete` (commands in D0) | now | none |
| A | JorisJonkers-dev/estate#215, then its release | this file; the project file declares Garage; the images lock gains `mongo`, `garage` and `garage-catalog`; the Platform document gains `engines.s3` and Garage's `serving` location | before the window | none: every artifact composes byte for byte as on `main` |
| P1 | a person | the Vault documents of W2 | before the window | none |
| D1 | fleet-infra#537 | every object of postgres, rabbitmq and valkey, and Garage's server, claim, Service and monitor, `prune: disabled`; `apps-data` stops pruning | before the window, or window step 1 | none |
| D2 | fleet-infra#538 | those manifests leave fleet-infra; `apps-data` is deleted and `apps-data-leftovers` adopts what stays: Vault, MongoDB, Garage's bootstrap Job, asset sync and assets route, the priority classes and the rabbitmq route | window step 2 | none |
| G | a person | Garage's split | window step 3 | Garage |
| B | JorisJonkers-dev/estate#216, then its release | the ledger moves `data` to `estate`; the `platform-postgres` and `platform-garage` serving statements go | window step 4 | the recreate |
| D3 | fleet-infra#539 | retires `observability/rabbitmq-definitions-backup` | after the proof | none |

D2's `apps-data` must be gone before B: the estate's unit is also
`flux-system/apps-data`.

## The render against the old path

Rendered with deploy-kit 1.3.0, the version `toolkit.yml` pins, from A with B's
ledger change: `deploy-kit compose` over every participant's newest fragment,
this branch's Platform and estate fragments, `participants.yml`,
`cluster-state.yml` and the committed sources. Compared against `kubectl
kustomize cluster/flux/apps/data` of fleet-infra `main` and the live objects,
read 2026-10-29. Every image matches the live pod by digest, and every Asset is
byte-identical to the ConfigMap it replaces. deploy-kit 1.2.0 renders the same
tree less the one external-checks ConfigMap below.

| object | difference | why |
|---|---|---|
| Namespace `data-system` | gains `managed-by: deploy-kit`; loses the prune mark | every rendered namespace carries the label; the mark is W3 |
| Deployments `postgres`, `rabbitmq`, `valkey`, `garage` | selector `name` becomes `name` + `instance` | the fixed label set; a selector is immutable, so the first pin recreates each (`force: Enabled`) |
| | `nodeSelector` site `frankfurt` becomes node affinity on `frankfurt-contabo-1` | the node each claim is bound to; the same node |
| | `priorityClassName: platform-data` is gone | the Platform document declares no `priority`; adding it also moves `auth` and the foundation, so it is a change of its own |
| | `runAsNonRoot`, uid and gid from the lock (postgres 999:999, rabbitmq 100:101, valkey 999:1000, garage 1000:1000), `fsGroup` the gid, `RuntimeDefault` seccomp, read-only root, every capability dropped | `hardening: restricted`. Each image but Garage's already drops to that user. kubelet applies `fsGroup` to a `local` volume at each mount, so every file on the claim becomes group-writable (read on `immich-postgres`, 2026-10-29) |
| | memory request equals limit: postgres 4Gi, its exporter 128Mi, rabbitmq 1Gi, valkey 768Mi, its exporter 96Mi, garage 1Gi; no CPU limit | about 4.1Gi more requested on `frankfurt-contabo-1`: 12.6Gi becomes 16.7Gi of 23.5Gi |
| | `revisionHistoryLimit` 3 becomes the default | fleet-infra's patch on `apps-data` |
| `postgres` | the server runs the image's entrypoint with `-c config_file=/etc/postgresql/postgresql.conf`, the file the old path's shell wrapper names; the exporter sidecar reads its queries from the same path through `--extend.query-path`, as live | `args`, and the sidecar's `assets` |
| | probes: TCP 5432 (startup 120 × 5s), where live runs `pg_isready` | the model has TCP and HTTP probes; a wedged postmaster that keeps its listener reads as healthy, and `PostgresDown` still reports it |
| | the environment: `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` and the exporter's `DATA_SOURCE_*`, in both containers; the init script's `AUTH_DB_*`, `AGENTS_DB_*` and `KB_DB_*` are not delivered | a Process's environment is its pod's; the init script runs only on an empty data directory and is not rendered |
| | the data directory is group-writable after the mount | the image's entrypoint resets it to 0700 before Postgres checks it, as `immich-postgres` shows |
| `rabbitmq` | `HOME=/tmp`, a writable path | Erlang refuses a cookie file anyone but its owner can read. On a copy of its volume made group-writable as kubelet leaves it, the live image exits with `Cookie file /var/lib/rabbitmq/.erlang.cookie must be accessible by owner only`; with `HOME` on `/tmp` it writes a fresh owner-only cookie and starts, every plugin enabled (Docker, 2026-10-29) |
| `garage` | the claim `garage-data` mounts at `/var/lib/garage/data`, and `data_dir` names `data/` on it, where the old path wrote the blocks; the metadata is on the new `garage-meta`; snapshots every 6h onto the new `garage-snapshots` | the split |
| | the RPC secret and admin token come from the environment (`GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN`), read from the live keys `rpc_secret` and `admin_token` | an Asset holds nothing secret |
| | readiness `GET /health` on 3903; liveness TCP 3900 | a Garage without its metadata answers 503, so an empty `garage-meta` holds the unit not-Ready rather than serving an empty store |
| | runs as 1000:1000, where live runs as root | the split's copy chowns both claims |
| Services | selector `name` becomes `instance`; port names `db` become `postgres` and `redis`; Garage's RPC port 3901 is not on the Service | same names and port numbers; nothing selects by port name; a single node dials no peer |
| claims `postgres-data`, `rabbitmq-data`, `garage-data` | adopted, plus labels and `prune: disabled` | `irreplaceable` or `recoverable` |
| claim `valkey-data` | adopted, with no prune mark: the render's apply drops D0's | `reconstructible`: a cache its readers rebuild |
| new claims | `garage-meta` 2Gi (no mark), `garage-snapshots` 4Gi; backup claims `postgres-data-backup` 20Gi, `rabbitmq-data-backup` 10Gi, `garage-data-backup` 20Gi, `garage-snapshots-backup` 4Gi | the split, and one backup claim per backed-up volume |
| ConfigMaps | `postgres-config`, `postgres-exporter-queries`, `rabbitmq-config` and `rabbitmq-enabled-plugins` become content-hashed Assets; `postgres-init-script` is not rendered | the old five are deleted by hand |
| Vault | one `VaultStaticSecret` per grant (`postgres-platform-postgres`, `rabbitmq-platform-rabbitmq`, `garage-platform-garage`), each logging in as its own Process (`data-system-postgres` and the rest), refreshing every 10m; the injector annotations and the roles `postgres` and `rabbitmq` go | identity per Process; the old roles stay in Vault until deleted by hand |
| Postgres catalog | moves from `_estate`'s `estate-vso-secrets` into `apps-data`, and signs in with `secret/data/data/postgres/catalog` instead of `platform/postgres` | the `serving` statement leaves with B. The same eight databases: `auth_db`, `estate-dashboard_db`, `findability-explorer_db`, `grimoire_db`, `hindsight_db`, `n8n_db`, `outline_db`, `tribelt_db`. The `postgres-catalog` and `vault-policy` CronJobs, ServiceAccounts and policies keep their names and pass from one unit to the other in one composition |
| Garage catalog | none rendered | no edge names a bucket yet, so Garage's buckets and keys stay with fleet-infra's `garage-bootstrap` Job |
| backups | `postgres-data-backup` 02:45, 90 copies, off-cluster; `rabbitmq-data-backup` 03:15, 14 copies; `garage-data-backup` and `garage-snapshots-backup` 03:15, 14 copies | the durability classes. `observability/postgres-logical-backup` stays until the first derived run is read back; D3 retires the RabbitMQ definitions job |
| ServiceMonitors | `postgres`, `rabbitmq`, `valkey`, `garage`, same names, adopted | Prometheus selects every ServiceMonitor (fleet-infra#536) |
| new | the `vault-policy` CronJob, Job and ConfigMap; `VaultConnection secret-store`; the `flux-system` Alert and Provider for rollout events | how every estate Project reaches Vault and reports |
| new | ConfigMap `platform-rabbitmq-external-checks`: one Gatus endpoint, `https://rabbitmq.jorisjonkers.dev/`, healthy below 500 | deploy-kit 1.3.0 derives an external check from each exposure |
| rendered, not applied | the NetworkPolicies | render-only on this substrate |
| not rendered | IngressRoutes `rabbitmq` and `garage-assets` | no Project carries routes while edge is `legacy`; both stay in `apps-data-leftovers` |
| not rendered | Garage's `garage-bootstrap` Job, `garage-asset-sync` CronJob, their VaultStaticSecrets and `garage-config` | the bootstrap imports each consumer's key and makes its buckets, which a bucket catalog does only once a consumer names its buckets on an edge. The asset sync publishes agent-kit's latest release to the assets bucket every 15 minutes: a scheduled Process covers it, but its logic is a shell script, never an Asset, and no image carries it yet |
| other units | `apps-auth`, `apps-estate-dashboard`, `apps-findability-explorer`, `apps-grimoire`, `apps-hindsight`, `apps-immich`, `apps-n8n` and `apps-tribelt` gain `dependsOn: apps-data` | their edges into the data Project; the sources change, the artifacts do not |
| `_estate` | its `estate-vso-secrets` unit goes; `estate-stable-addresses` stays | composition rewrites the committed source |

## Pre-checks

Each must print what it says. Nothing here writes, save step 3.

```sh
# 1. D0 and P0 reached the live objects.
kubectl get ns data-system -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}'   # disabled
kubectl get pv -o json | jq -r '.items[] | select(.spec.claimRef.namespace=="data-system")
  | "\(.spec.claimRef.name) \(.spec.persistentVolumeReclaimPolicy)"'                                         # every line Retain

# 2. D1 reached the live objects.
kubectl -n data-system get deploy,svc,pvc,cm,sa,servicemonitor -o json | jq -r '.items[]
  | "\(.kind)/\(.metadata.name) \(.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] // "UNMARKED")"'
kubectl -n flux-system get kustomization apps-data -o jsonpath='{.spec.prune}{"\n"}'                        # false
#    Every object of postgres, rabbitmq and valkey, and Garage's Deployment, Service, claim and
#    monitor, read disabled. UNMARKED is expected for Vault's, MongoDB's and Garage's support objects.

# 3. (write, a person) The documents of W2, through the port-forward and OIDC sign-in
#    bootstrap/secrets.sh uses. Each value goes over stdin and is never printed.
vault kv get -format=json -mount=secret platform/postgres \
  | jq '.data.data | {user: .["postgres.user"], password: .["postgres.password"]}' \
  | vault kv put -mount=secret data/postgres/catalog -
vault kv get -format=json -mount=secret platform/postgres \
  | jq '.data.data | {PGUSER: .["postgres.user"], PGPASSWORD: .["postgres.password"]}' \
  | vault kv put -mount=secret data/postgres/backup -
vault kv get -format=json -mount=secret platform/rabbitmq \
  | jq '.data.data | {RABBITMQ_USERNAME: .["rabbitmq.user"], RABBITMQ_PASSWORD: .["rabbitmq.password"]}' \
  | vault kv put -mount=secret data/rabbitmq/backup -

# 4. Vault holds every key the render reads (names only).
for p in platform/postgres platform/rabbitmq platform/garage data/postgres/catalog data/postgres/backup \
         data/rabbitmq/backup platform/backup/off-cluster; do
  echo "$p: $(vault kv get -format=json -mount=secret "$p" | jq -c '.data.data | keys')"; done
#    platform/garage holds rpc_secret and admin_token; the three data/ documents the keys above;
#    platform/backup/off-cluster the S3 endpoint and key pair. A key the render reads and Vault
#    lacks fails the pod at start. Without the catalog login the catalog Job fails, and every unit
#    that follows apps-data holds its next change until it succeeds.

# 5. A dump of every database, as the restore point: the 02:30 job, run now.
kubectl -n observability create job --from=cronjob/postgres-logical-backup \
  postgres-logical-backup-handover-$(date -u +%Y%m%d%H%M)
```

## Cutover

Watch in separate terminals:

```sh
kubectl -n data-system get pods -w -o wide
flux get kustomizations -n flux-system --watch
```

1. **Merge D1** if it is not live yet, and wait for pre-check 2.
2. **Merge D2**, and wait until `deploy/production` publishes and reconciles:
   `apps-data` is NotFound, `apps-data-leftovers` is Ready, and
   `kubectl -n data-system get sts vault -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}'`
   reads `apps-data-leftovers`. The four datastores still run, applied by
   nothing.
3. **Split Garage (G).** Garage is down from here until step 4 has recreated
   it. The copy leaves `meta/` on `garage-data` in place, so the old Garage can
   start on it again until the new one has taken a write.

   ```sh
   kubectl -n data-system scale deploy/garage --replicas=0
   kubectl -n data-system wait --for=delete pod -l app.kubernetes.io/name=garage --timeout=2m
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata: {name: garage-meta, namespace: data-system}
   spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 2Gi}}}
   EOF
   kubectl -n data-system run garage-split --restart=Never --image=alpine:3.24 \
     --overrides='{"spec":{"nodeName":"frankfurt-contabo-1","containers":[{"name":"garage-split","image":"alpine:3.24",
       "command":["sh","-ec","cp -a /old/meta/. /new/ && chown -R 1000:1000 /new /old/data && sync && du -s /old/meta /new && find /old/meta -type f | wc -l && find /new -type f | wc -l"],
       "volumeMounts":[{"name":"old","mountPath":"/old"},{"name":"new","mountPath":"/new"}]}],
       "volumes":[{"name":"old","persistentVolumeClaim":{"claimName":"garage-data"}},{"name":"new","persistentVolumeClaim":{"claimName":"garage-meta"}}]}}'
   kubectl -n data-system wait --for=jsonpath='{.status.phase}'=Succeeded pod/garage-split --timeout=10m
   kubectl -n data-system logs garage-split    # the two sizes agree, and so do the two file counts
   kubectl -n data-system delete pod garage-split
   ```

4. **Merge B**, then the release PR release-please opens for it. The release
   publishes the Platform document and the data fragment and dispatches
   composition; reconcile `estate-pins` once its pin lands.

   ```sh
   flux reconcile kustomization estate-pins -n flux-system --with-source
   flux get kustomization apps-data -n flux-system --watch
   ```

   What happens, in order (each a watch, not an action): the `vault-policy` Job
   completes; VSO syncs `postgres-platform-postgres`,
   `rabbitmq-platform-rabbitmq` and `garage-platform-garage`; Flux deletes and
   recreates each of the four Deployments, and the old pods are
   garbage-collected (a new Postgres that starts before its old pod has gone
   exits on the old one's `postmaster.pid` and restarts once it is free); the
   new pods start on the same claims; `postgres-catalog` runs once Postgres
   answers; `apps-data` goes Ready, and the eight units that follow it hold
   their next change until it does.

## Proof

Read each; a Ready condition alone proves nothing.

1. `flux get kustomization apps-data` is Ready. The four backup claims are
   `Pending` with no selected node until their first run, which counts as
   healthy.
2. Every consumer reads its database: auth signs in at `auth.jorisjonkers.dev`,
   n8n and Outline open, and the catalog Job completes.
3. Every consumer reads its queue: auth-api's log shows its RabbitMQ listeners
   connected, and `rabbitmq.jorisjonkers.dev` lists them.
4. Every consumer reads its bucket: an Outline attachment and an Overleaf
   project open, `https://assets.jorisjonkers.dev/` answers, and
   `garage-bootstrap`'s next run ends `reconcile complete`.
5. Valkey answers: an auth session survives a page reload.
6. `pg_database_collation_drifted`, the series `PostgresCollationDrift` reads,
   is present in Prometheus.

Then, by hand: the five old ConfigMaps, the old ReplicaSets, the Job
`postgres-agents-rename` and the Vault roles `postgres` and `rabbitmq`. Once
the first derived Postgres backup has been read back off the cluster,
`postgres-logical-backup` retires too.

## Rollback

The generic runbook's steps (deploy-kit `docs/runbooks/handover.md#rollback`),
in this order and no other, because the render's namespace carries no mark
(W3):

1. Set `spec.prune: false` on `apps-data` in `projects/data/source.yaml`,
   reconcile `estate-pins`, and read the value back.
2. Move `data` back to `legacy`, restore both `serving` statements, and delete
   `projects/data/`.
3. Revert D2, then D1. Garage starts on the old `meta/` on `garage-data`; an
   object written since cutover step 4 is lost from its listing, though its
   blocks stay on disk.

No claim is touched: the render marks every backed-up claim `prune: disabled`,
and every volume reclaims `Retain` since P0.
