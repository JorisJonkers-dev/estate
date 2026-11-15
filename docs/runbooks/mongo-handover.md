# Handing MongoDB over to the estate path

Moves `platform-mongo`, Overleaf's MongoDB, from fleet-infra's
`apps-data-leftovers` into the estate path's `data` Project. It follows data's
own handover ([`data-handover.md`](data-handover.md)): `data` is already
`estate` on the ledger, so this window adds one Application to a Project that
is already delivered, and no ledger entry moves. Tracking:
JorisJonkers-dev/deploy-kit#748, under JorisJonkers-dev/deploy-kit#661.

The live MongoDB is a one-member replica set, `overleaf`, run by a StatefulSet
`mongo` on `frankfurt-contabo-1`, **without authentication**. The estate path
runs it as a Deployment with authentication on, on the same claim
`mongo-data-mongo-0`, under the same Service name `mongo`. Overleaf, its only
client, reconnects once. Run it with the maintainer present. A live step is the
maintainer's go-ahead, never an agent's.

## What was read (2026-10-30)

| | live |
|---|---|
| clients | Overleaf alone: `overleaf-system/overleaf`, `OVERLEAF_MONGO_URL=mongodb://mongo-0.mongo.data-system.svc.cluster.local:27017/sharelatex?replicaSet=overleaf`, a literal in the overleaf repository's `deploy/env/overleaf/base.env`. No Secret, VaultStaticSecret or other workload names MongoDB |
| replica set | `overleaf`, one member, host `mongo-0.mongo.data-system.svc.cluster.local:27017` (fleet-infra's `rs-init-job.yaml`, which initiated it 52 days ago). The StatefulSet's pod resolves that name through `/etc/hosts`, before any DNS |
| image | `mongo:8.0` at `sha256:02a0cc79…` (8.0.29), the digest the images lock already pins. It starts as root and its entrypoint drops to `mongodb`, 999:999 |
| args | `--replSet overleaf --bind_ip_all --wiredTigerCacheSizeGB 1` |
| resources | requests 200m and 512Mi, limit 2Gi; working set about 280Mi |
| volume | `mongo-data-mongo-0`, 20Gi `local-path` on `frankfurt-contabo-1`, PV `pvc-0847c439…`, reclaim **`Delete`**. Created by the StatefulSet's claim template, with no owner and `whenDeleted: Retain`, so deleting the StatefulSet keeps it. Its size on disk is not readable without exec: check `db.stats()` in pre-check 2 |
| Service | `mongo`, headless (`clusterIP: None`), selector `app.kubernetes.io/name: mongo` |
| policy | fleet-infra's `mongo` NetworkPolicy admits Overleaf's pods and the init Job. It is the only control in front of the unauthenticated set: the estate path's policies are rendered but not applied |
| node | `frankfurt-contabo-1` requests 17.8Gi of 23.5Gi; data's window adds about 4Gi |

## What it waits on

| | what | where |
|---|---|---|
| M1 | data's handover, done and proven | [`data-handover.md`](data-handover.md), JorisJonkers-dev/deploy-kit#661 |
| M2 | a deploy-kit release carrying #757 (a `mongo` resolves its own Service name to itself), and `toolkit.yml` on it | the release coordinator |
| M3 | delivery 0.17.0, which publishes `mongo-backup` (JorisJonkers-dev/delivery#109), and its digest in `images.lock.yml` in place of change A's placeholder | the release coordinator |
| M4 | the maintainer's decisions below | the maintainer |
| M5 | `secret/data/data/mongo/{admin,backup,membership}` and `secret/overleaf-system/mongo`, and the MongoDB users they name | a person: `bootstrap/secrets.sh --only mongo` (JorisJonkers-dev/estate#271) |
| M6 | MongoDB's PV reclaims `Retain` | data's P0 (fleet-infra#562's loop covers all seven `data-system` volumes) |

## Decisions for the maintainer

Each is open, with a recommendation. The drafts implement the recommendation.

**D1. How the member authenticates.** `mongod` refuses `--auth` on a replica
set without cluster authentication (`security.keyFile is required when
authorization is enabled with replica sets`). It also refuses a keyFile with any
group or other bit (`permissions … are too open`). A Secret mounted under the
render's `fsGroup` is always root-owned at 0440, so the model cannot deliver a
keyFile ([deploy-kit#761](https://github.com/JorisJonkers-dev/deploy-kit/issues/761)).
All four tested in Docker on `mongo:8.0`.

| option | cost | |
|---|---|---|
| **A. x.509 membership** (`--clusterAuthMode x509 --tlsMode preferTLS --tlsAllowConnectionsWithoutCertificates`), one self-signed PEM that is its own CA, in Vault, delivered `file` | a key and certificate to hold (100-year validity); mongod also offers TLS, which no client is made to use | **recommended**: works on today's model and was tested end to end. Clients keep plain connections and sign in with SCRAM |
| B. a keyFile, after deploy-kit learns to deliver an owner-only file (#761, option 2) | a model change, and an image to copy with | slower, and a mechanism for one consumer |
| C. a keyFile, through an estate wrapper image of `mongo` whose entrypoint copies it to 0400 | a new repository, its release and Renovate | the most moving parts |
| D. no authentication: delivery's method dumps without a login, and the policy stays | a delivery change; MongoDB stays open to any pod once fleet-infra, which applies the policy, retires | defers the problem to the retirement |

**D2. `--oplog`.** The method dumps without it. On this replica set,
`--oplog` makes the dump one point in time across collections. `mongorestore
--oplogReplay` replays it, and the `backup` role reads `local.oplog.rs`.
Tested: as `backup`, `mongodump --oplog --archive` dumps and captures the
oplog. On a standalone, `--oplog` fails.
Options: (a) **always add it** (recommended: every MongoDB the estate runs is a
replica set, because Overleaf needs one; a standalone failing loudly is the
right signal); (b) add it only where `hello` reports a set name (needs a client
the image does not carry); (c) never. A delivery change either way, after this
decision.

**D3. The claim's class.** (a) **`irreplaceable`** (recommended): 90 copies and
an encrypted off-cluster copy, as Postgres, since it holds every account and
every project's text. (b) `recoverable`: 14 copies, on the cluster only.

**D4. Memory.** The render's request is its limit. (a) **1Gi with a 0.25 GB
cache** (recommended: the live working set is about 280Mi, and frankfurt is
near full after data's window); (b) 2Gi with the live 1 GB cache, 1.5Gi more
than live requests today; (c) 1.5Gi with 0.5 GB.

**D5. The network policy.** The rendered one is not applied. (a) **Keep
fleet-infra's, moved beside Overleaf's in `apps-latex`** (recommended until the
estate path applies its policies): it admits Overleaf and the derived backup.
(b) Drop it, and rely on authentication, as Postgres does today.

**D6. Overleaf's roles.** (a) **`readWrite` and `dbAdmin` on `sharelatex`**
(recommended: its migrations create and change indexes and collections), (b)
`dbOwner` on `sharelatex`. Neither reaches another database. Before O, run the
overleaf repository's smoke test against a MongoDB with auth on and these
roles: today it runs one without auth.

## The changes, in order

| # | where | what | merges | outage |
|---|---|---|---|---|
| A | estate (draft, stacked on #216) | this runbook; `engines.mongo`; `mongo-backup` in the images lock | after M3, any time before the window | none: composes byte for byte as its base |
| S | JorisJonkers-dev/estate#271, then a person | `secrets.sh --only mongo`: the four documents, and MongoDB's users `admin`, `backup` and `overleaf`, made while auth is still off | before O | none: a user made now signs in at once, and nothing enforces it yet |
| O | overleaf (draft) | `OVERLEAF_MONGO_URL` from `secret/overleaf-system/mongo#url`, which signs in as `overleaf` at `mongo.data-system.svc.cluster.local`; the edge `platform-mongo.mongo` follows B | before the window | Overleaf's own restart (Recreate) |
| H | a person | the member's host becomes `mongo.data-system.svc.cluster.local:27017`, on the running primary | before the window | none |
| F1 | fleet-infra (draft) | MongoDB's StatefulSet, Service and policy `prune: disabled` | before the window | none |
| F2 | fleet-infra (draft, stacked on F1) | MongoDB leaves `apps-data-leftovers`; the init Job is pruned; the policy moves to `apps-latex` and admits the backup | before the window | none |
| B | estate (draft, stacked on A), then its release | `platform-mongo` declared in `platform/data/data.project.yml` | window step 1 | from step 2 until the new pod is ready |

H works because the live Service `mongo` is headless: its name already resolves
to the running pod, so the primary accepts the new host as itself. A Docker
rehearsal of S, H and B, including Overleaf-shaped transactions and change
streams under auth and a dump by the `mongo-backup` image, passed on
2026-10-30.

## The render against the old path

Rendered on deploy-kit `main` plus #757, from B on data's #216, composed as CI
composes. Compared with fleet-infra's `cluster/flux/apps/data/mongo` and the
live objects.

| object | difference | why |
|---|---|---|
| workload | the StatefulSet `mongo` becomes a Deployment `mongo`, `Recreate`, beside it; the person deletes the StatefulSet | the model has one workload kind; a member needs no per-pod name once its own Service name resolves to itself |
| | `hostAliases`: `mongo.data-system.svc.cluster.local` at `127.0.0.1` | deploy-kit #757 |
| | args gain `--auth --clusterAuthMode x509 --tlsMode preferTLS --tlsCertificateKeyFile /etc/mongo/membership.pem --tlsCAFile /etc/mongo/membership.pem --tlsAllowConnectionsWithoutCertificates`; the cache goes 1 to 0.25 GB | D1, D4 |
| | runs as 999:999 from the start, `fsGroup` 999, read-only root with `/tmp` and `/data/configdb` writable, every capability dropped, `HOME=/tmp` | `hardening: restricted`; the live files are already 999's |
| | memory 1Gi request and limit, cpu 200m with no limit | D4 |
| | probes TCP 27017 (startup 24 × 5s), where live runs `mongosh` ping | the model has TCP and HTTP probes |
| | `nodeSelector` site `frankfurt` becomes affinity on `frankfurt-contabo-1` | the node the claim is bound to |
| | `priorityClassName: platform-data` once the branches carry estate 0.34.0's `priority` block | a Process whose engine derives a backup |
| Service `mongo` | selector `name` becomes `instance`; same port 27017, port name `mongo` | the fixed label set. Applied by the same field manager without `clusterIP`, so it keeps `None` and stays headless; the alias makes the member's check independent of that |
| claim `mongo-data-mongo-0` | adopted, with labels and `prune: disabled` | `irreplaceable` (D3) |
| new | claim `mongo-data-mongo-0-backup` 20Gi; CronJob `mongo-data-mongo-0-backup` at 02:45, 90 copies, off-cluster to `data/mongo/mongo-data-mongo-0`; ServiceAccounts `mongo` and `mongo-backup`; VaultAuth and VaultStaticSecrets for `data/mongo/membership`, `data/mongo/backup` and `platform/backup/off-cluster`; policies `data-system-mongo` and `data-system-mongo-backup` | the class's backup, and identity per Process |
| not rendered | Job `mongo-rs-init` | the set is initiated; F2 prunes it |
| rendered, not applied | the NetworkPolicies | render-only on this substrate; D5 keeps fleet-infra's |

## Pre-checks

Each must print what it says. Nothing here writes, save 3 and 4.

```sh
# 1. M6: the PV reclaims Retain.
kubectl get pv "$(kubectl -n data-system get pvc mongo-data-mongo-0 -o jsonpath='{.spec.volumeName}')" \
  -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'                      # Retain

# 2. The set is healthy, and how big it is (read-only; auth is still off).
kubectl -n data-system exec mongo-0 -- mongosh --quiet --eval \
  'print(rs.status().members[0].stateStr, rs.conf().members[0].host); printjson(db.getSiblingDB("sharelatex").stats(1024*1024))'
#    PRIMARY mongo-0.mongo.data-system.svc.cluster.local:27017, and dataSize/storageSize in MiB

# 3. (write, a person) S: the documents and the users. It asks before each write, shows every
#    value as a 12-character fingerprint, and proves each login signs in.
./bootstrap/secrets.sh --only mongo

# 4. (write, a person) A dump as the restore point, before anything changes.
kubectl -n data-system exec mongo-0 -- sh -c 'mongodump --oplog --archive --gzip' > mongo-$(date -u +%Y%m%dT%H%MZ).archive.gz
ls -l mongo-*.archive.gz                                                          # not empty
```

## Cutover

Before the window, in this order, checking each:

1. **O.** Merge the overleaf change and let its release roll out. Overleaf
   restarts once. Check that an Overleaf project opens and saves, and that
   MongoDB logged its login:
   `kubectl -n data-system logs mongo-0 --since=10m | grep -c '"Successfully authenticated".*"user":"overleaf"'`
   is above zero.
2. **H.** Move the member's host, on the running primary:

   ```sh
   kubectl -n data-system exec -i mongo-0 -- mongosh --quiet --file /dev/stdin <<'EOF'
   const c = rs.conf();
   c.members[0].host = "mongo.data-system.svc.cluster.local:27017";
   printjson(rs.reconfig(c).ok);
   EOF
   kubectl -n data-system exec mongo-0 -- mongosh --quiet --eval \
     'print(rs.status().members[0].stateStr, rs.conf().members[0].host)'
   #    PRIMARY mongo.data-system.svc.cluster.local:27017
   ```

   Overleaf still opens a project.
3. **F1**, then **F2.** After F1: `kubectl -n data-system get sts,svc,netpol mongo -o
   jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}{end}'`
   reads `disabled` three times. After F2: `mongo-rs-init` is NotFound, the
   StatefulSet's pod is still `mongo-0` with no restarts, and NetworkPolicy
   `mongo`'s `kustomize.toolkit.fluxcd.io/name` label reads `apps-latex`.

The window, watched in two terminals
(`kubectl -n data-system get pods -l app.kubernetes.io/name=mongo -w -o wide`,
`flux get kustomization apps-data -n flux-system --watch`):

1. **Merge B**, then the release PR release-please opens for it. Reconcile
   `estate-pins` once the pin lands:
   `flux reconcile kustomization estate-pins -n flux-system --with-source`.
   Flux adopts the Service and the claim, and creates the Deployment. Its pod
   starts on the same claim and exits with `DBPathInUse` while the old mongod
   holds the lock: that is the guard, not a fault. Overleaf keeps its open
   connections to the old pod.
2. **Stop the old member** once `vault-policy` has run and VSO has synced
   `mongo-data-mongo-membership` (`kubectl -n data-system get secret
   mongo-data-mongo-membership` exists). MongoDB is down from here:

   ```sh
   kubectl -n data-system delete sts mongo                     # its claim stays: whenDeleted Retain
   kubectl -n data-system wait --for=delete pod/mongo-0 --timeout=2m
   kubectl -n data-system delete pod -l app.kubernetes.io/instance=mongo   # skip the crash backoff
   kubectl -n data-system wait --for=condition=Ready pod -l app.kubernetes.io/instance=mongo --timeout=3m
   ```

## Proof

Read each; a Ready condition alone proves nothing. `$ADMIN` stands for the
password at `secret/data/mongo/admin`, typed into mongosh's prompt, never put
in an argument.

1. The member is itself, with auth on:
   `kubectl -n data-system exec -it deploy/mongo -- mongosh -u admin --authenticationDatabase admin --eval 'print(rs.status().members[0].stateStr, rs.conf().members[0].host)'`
   prints `PRIMARY mongo.data-system.svc.cluster.local:27017`, after the password prompt.
2. Nothing signs in without a login:
   `kubectl -n data-system exec deploy/mongo -- mongosh --quiet --eval 'try { db.getSiblingDB("sharelatex").projects.countDocuments() } catch (e) { print(e.codeName) }'`
   prints `Unauthorized`.
3. Overleaf opens and saves a project, and its log shows no `MongoServerError`.
4. The derived backup's first generation reads back:

   ```sh
   kubectl -n data-system create job --from=cronjob/mongo-data-mongo-0-backup mongo-backup-handover
   kubectl -n data-system wait --for=condition=complete job/mongo-backup-handover --timeout=10m
   kubectl -n data-system logs job/mongo-backup-handover | tail -3     # a generation written, copied off-cluster
   ```

   Then restore it into a throwaway mongod beside the backup claim, and compare
   counts with the live set:

   ```sh
   kubectl -n data-system run mongo-restore-check --restart=Never --image=mongo:8.0 \
     --overrides='{"spec":{"nodeName":"frankfurt-contabo-1","containers":[{"name":"c","image":"mongo:8.0",
       "command":["sh","-ec","f=$(ls -t /backup/*.archive.gz | head -1); mongod --dbpath /tmp/db --bind_ip 127.0.0.1 --fork --logpath /tmp/log >/dev/null; mongorestore --quiet --gzip --archive=$f; mongosh --quiet --eval \"print(db.getSiblingDB(\\\"sharelatex\\\").projects.countDocuments(), db.getSiblingDB(\\\"sharelatex\\\").users.countDocuments())\""],
       "volumeMounts":[{"name":"b","mountPath":"/backup","readOnly":true},{"name":"t","mountPath":"/tmp"}]}],
       "volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"mongo-data-mongo-0-backup","readOnly":true}},{"name":"t","emptyDir":{}}]}}'
   kubectl -n data-system wait --for=jsonpath='{.status.phase}'=Succeeded pod/mongo-restore-check --timeout=10m
   kubectl -n data-system logs mongo-restore-check     # the same two counts as the live set
   kubectl -n data-system delete pod mongo-restore-check
   ```

Then, by hand: the StatefulSet's ControllerRevisions if any remain, and the
fleet-infra `mongo` README row in `apps/latex/overleaf/README.md` (F2 updates
it).

## Rollback

Before window step 2, the old member still serves: revert B (step 1 below) and
nothing else has changed for Overleaf. After it:

1. Set `spec.prune: false` on `apps-data` in `projects/data/source.yaml`,
   reconcile `estate-pins`, and read the value back, so removing
   `platform-mongo` deletes no Service.
2. Revert B, release it, and delete the Deployment `mongo` by hand, which frees
   the lock.
3. In fleet-infra, revert F2, then F1. `apps-data-leftovers` re-applies the
   StatefulSet, the Service and the policy, and the StatefulSet's pod
   `mongo-0` starts on the same claim. It starts without `--auth`, and its
   member host, the Service's name, resolves to it once it is ready. Overleaf's
   login still signs in, since a user authenticates whether auth is enforced
   or not.
4. Set `apps-data`'s prune back once the old path serves.

The claim is never touched: the render marks it `prune: disabled`, the
StatefulSet keeps it on delete, and its PV reclaims `Retain` (M6).
