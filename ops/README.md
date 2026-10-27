# Operations

What a person runs against the live cluster when something is wrong, or before
a risky step: unsealing Vault, recovering a wedged control plane, proving a
backup restores, restoring one, and taking a handover dump. Each script says at
its top what it changes, checks its own outcome rather than trusting an exit
code, and, where it can, undoes itself on a failed check. Run them from the
repository root.

These moved here from JorisJonkers-dev/fleet-infra's `scripts/ops/`,
`scripts/restore/` and `docs/runbooks/` on 2026-10-23, so the estate keeps
them when fleet-infra retires. What a person writes to Vault is
[`../bootstrap/secrets.sh`](../bootstrap/README.md), not this directory.

| script | when | changes |
|---|---|---|
| [`unseal-vault.sh`](unseal-vault.sh) | Vault is sealed; check it first when unrelated pods hang in `Init` | unseals `data-system/vault-0`, one hidden key share at a time |
| [`recover-wedged-apiserver-cache.sh`](recover-wedged-apiserver-cache.sh) | a node is `Ready` but runs nothing, or removed `unreachable` taints come back ([runbook](runbooks/apiserver-watch-cache-wedge.md)) | nothing by default; `--fix` restarts k3s on the control plane, `--install-dns-fallback` places [`break-glass/adguard-static-pod.yaml`](break-glass/adguard-static-pod.yaml) |
| [`verify-backup-restore.sh`](verify-backup-restore.sh) | to prove the nightly Postgres dump restores ([runbook](runbooks/backup-coverage.md)) | a scratch database, dropped again |
| [`dump-database.sh`](dump-database.sh) | before handing a Project's database over ([record](runbooks/handover-dumps.md)) | writes one dump to Garage's `handover-dumps` bucket |
| [`resume-mail-provisioner.sh`](resume-mail-provisioner.sh) | after `apps-mail` was suspended | resumes it and verifies Stalwart; re-suspends and rolls back on a failed check |
| [`restore/restore-vault-raft-snapshot.sh`](restore/restore-vault-raft-snapshot.sh) | restoring Vault from a raft snapshot | Vault's whole state |
| [`restore/restore-rabbitmq-definitions.sh`](restore/restore-rabbitmq-definitions.sh) | restoring RabbitMQ's definitions export | the broker's definitions |
| [`restore/restore-pvc-archive.sh`](restore/restore-pvc-archive.sh) | restoring a tar archive into a claim | the claim's contents |
| [`restore/restore-hostpath-archive.sh`](restore/restore-hostpath-archive.sh) | restoring a tar archive into a node directory, over SSH | that directory |

`restore-vault-raft-snapshot.sh`, `restore-pvc-archive.sh` and
`restore-hostpath-archive.sh` call the scripts of the same name in
JorisJonkers-dev/flux-modules, at the tag `FLUX_MODULES_VERSION` names (`v1.4.0`
by default), through [`lib/flux-modules.sh`](lib/flux-modules.sh).

`unseal-vault.sh`, `recover-wedged-apiserver-cache.sh`, `dump-database.sh` and
`resume-mail-provisioner.sh` read the kubectl context from `KUBE_CONTEXT`
(default `personal`); the others use the current context.

## Checks

```bash
shellcheck -x -P SCRIPTDIR ops/*.sh ops/restore/*.sh ops/lib/*.sh
node --test ops/test-dump-database.mjs   # dump-database.sh against a faked kubectl and S3
```
