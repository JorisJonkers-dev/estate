# Handing `secrets` over to the estate path

Moves the Project `secrets` (Vault and the Vault Secrets Operator) from
fleet-infra's old path to its pin here, on deploy-kit 1.3.1, in the three
changes of deploy-kit `spec/v1/60-setup.md#handing-over-one-project-at-a-time`.
It is the last handover: after it `legacy` is empty. Tracking:
JorisJonkers-dev/deploy-kit#663 and #209 here.

Unlike every other handover, Vault is **not adopted in place**. It moves from
`data-system` to `secrets-system` by raft snapshot and restore in a planned
window, never a Move (decided 2026-10-27). The old Vault is never deleted in
the window: it is sealed, kept untouched, and is the rollback until the new
one is proven. Vault is down from the moment the old one is sealed until the
new one is unsealed, about 35 minutes. Run it with the maintainer present, at
a quiet hour, with the unseal key in hand. A live step is the maintainer's
go-ahead, never an agent's.

## What it waits on

| | what | where |
|---|---|---|
| W1 | every other handover done: utility, `node`, observability, edge, data (mail is done; agents is never ported and stays on the old path until it is retired there) | JorisJonkers-dev/deploy-kit#657 and #659 to #662 |
| W2 | the four retirements live, in order: the Vault CSI provider, the Vault Agent injector, Reloader, cert-manager | fleet-infra #570, #571, #572, #573 |
| W3 | no pod asks the injector for an agent: Postgres and RabbitMQ (data's drop, fleet-infra #538), agents-api and the agents rename Job (fleet-infra #531) gone | live check in [Pre-checks](#pre-checks) |
| W4 | `VaultSealed` reads `secrets-system`, wherever the rule lives by then: fleet-infra #575 carries the expression, which the observability Project's `alertRules` take if observability has handed over | [The alert](#the-alert) |
| W5 | the estate's `ops/unseal-vault.sh` (from #212) reaches `secrets-system/vault` | until then, [the inline unseal](#unseal) |
| W6 | decisions D1 to D7 below: D1 to D6 accepted as proposed on 2026-10-30, D7 with the edge | done |
| W7 | auto-unseal stays deferred (#210): the person running the window holds the one unseal key (Shamir, 1 of 1) | the maintainer |
| W8 | the Platform document's `priority` block released and composed (D6), after fleet-infra stopped applying the two classes | #266; fleet-infra #577 (live), #578 |
| W9 | the old path's `immich-system/immich-postgres` policy, which is enforced, admits Vault from `secrets-system` as well as `data-system`, so Vault's database engine still reaches immich's Postgres after the flip | fleet-infra #574 |
| W10 | auth-api's release that points its `VAULT_ADDR` at `secrets-system`, approved and held for step 9 | JorisJonkers-dev/auth-api#132 |

## Decisions

D1 to D6 were accepted as proposed on 2026-10-30. D7 is decided with the edge.

| | question | decided | why |
|---|---|---|---|
| D1 | which Vault runs in `secrets-system` | **1.21.4**, the lock's `vault` | vault-0 runs **1.21.2** (`vault status`, 2026-10-29). Its StatefulSet already names 2.0.4, which it takes only on a pod delete (`OnDelete`). Restoring 1.21.2's snapshot into 1.21.4 is a patch forward, rehearsed; 2.x is its own change, later |
| D2 | VSO's client cache | **not persisted**, accepted until deploy-kit#735 | the model renders no VaultAuth for the cache's transit key. Each VSO restart re-issues the nine dynamic database credentials (1h leases) and restarts their Processes; the window does that once anyway |
| D3 | Vault's metrics | **scraped without a token** (`unauthenticated_metrics_access = true` in `config/vault.hcl`) | the model renders a scrape with no credential. This retires the metrics token, fleet-infra's renewal CronJob, its VSO copy and `secrets.sh --only metrics-token` (a later `retire.sh` entry). The metrics carry no secret; the alternative is no Vault metrics, and `VaultMetricsUnreachable` deleted |
| D4 | Vault's backup | **`files` on the raft volume**, plus the raft snapshot below by hand, until deploy-kit#734 | `file-backup` copies the raft files while Vault writes them (02:45, off-cluster, 90 kept); a copy can be torn. fleet-infra's six-hourly `observability/vault-raft-snapshot` addresses `vault.data-system` and fails after the flip. Either re-point that job (if observability still runs it) or accept `files` alone until #734 |
| D5 | Vault's own configuration (auth methods, engines, DB connections, transit keys, roles of what is not a Project) | **frozen in the snapshot**; fleet-infra's `bootstrap-auth.sh` leaves with fleet-infra #575 | it is carried by the restore, and nothing maintains it afterwards: deploy-kit#736. A new connection or key meanwhile is a person's `vault write`, recorded on its issue. Decide before #575 merges |
| D6 | Vault's priority | **the Platform document's `priority` block, first**, as its own change: #266 | without it, Vault renders with no priority class (live: `platform-data`). Evicted under memory pressure on `frankfurt-contabo-1`, Vault comes back sealed. With it, Vault renders `platform-data` (its `files` engine derives a backup) and VSO `platform-critical-app` (it holds API access). Adding `priority` re-renders every Project once, so it is not folded into this change. The live classes are fleet-infra's: #577 marks them never to be pruned and #578 drops them from apps-data, so the estate release adopts them |
| D7 | the LAN tier's certificate once cert-manager retires | **with the edge**: deploy-kit#726 gives the LAN tier a certificate source before the edge's flip, and cert-manager retires with the edge | `edge-system/jorisjonkers-dev-tls` is the default TLSStore's, issued by cert-manager, valid to 2026-12-16; the LAN tier (`certificates: none`) cannot issue its own. fleet-infra #573 waits on it |

## The changes, in order

| # | where | what | when | outage |
|---|---|---|---|---|
| R1 | fleet-infra #570 | the Vault chart stops rendering the CSI provider, which serves nothing | before the window | none |
| R2 | fleet-infra #571 | the Vault chart stops rendering the Agent injector and its fail-closed webhook; the sample reader goes | before, after W3 | none |
| R3 | fleet-infra #572 | Reloader is uninstalled | before, after the agents handover drops hermes | none |
| R4 | fleet-infra #573 | cert-manager, its ClusterIssuer and the wildcard Certificate go | before, after the edge handover and D7 | none |
| S1 | fleet-infra #574 | every Vault and VSO object marked `prune: disabled`, both HelmReleases suspended | window step 1, after R1 and R2 are live | none |
| S2 | fleet-infra #575 | the Vault and VSO manifests and `bootstrap-auth.sh` leave the old path; `VaultSealed` watches `secrets-system` | window step 2 | none |
| B | this repository, this change | the ledger moves `secrets` to `estate` and drops the `vault` serving statement; the secrets file gains VSO; Vault and VSO are admitted to the API | window step 3: merged before the seal | none |
| P | this repository, the release PR release-please opens for B | publishes the Platform document and the secrets fragment, and dispatches composition | window step 6: merged after the seal | **Vault is down from step 5** |
| C | by hand, after the proof | the old Vault, VSO, their claims and leftovers | after the hold | none |

R1 and R2 must be live before S1: a suspended release takes no further
upgrade. S1 and S2 restart nothing, so the maintainer may merge them ahead of
the window.

## The render against the old path

Rendered with deploy-kit 1.3.1 (deploy-kit `main` on 2026-10-30, which is 1.3.1) from this change (`deploy-kit compose` over
every participant's newest fragment, this branch's Platform and platform
fragments, `participants.yml`, `cluster-state.yml` and the committed pin
sources), against fleet-infra `main` (`helm get manifest` of both releases,
`kustomize build` of `apps/data/vault`, `apps/core/vso` and
`vso-secrets/vault-prometheus-token.yaml`) and the live objects, read
2026-10-29. Re-rendered on 2026-10-30 against estate `main` and every
participant's newest fragment: outside `secrets`, only VSO objects, Canaries,
`VaultConnection`s, policy jobs and render-only policies change, and no
workload, so the flip itself restarts no other Process.

### Vault

| object | difference | why |
|---|---|---|
| namespace | `data-system` becomes `secrets-system`, a new namespace | the move; nothing is adopted |
| StatefulSet `vault` | becomes Deployment `vault`, `Recreate`, one replica | no Process is a StatefulSet; one server on one RWO claim |
| | image `vault:1.21.2` (pod) / `2.0.4` (template) becomes `vault@sha256:4e33b126…` 1.21.4 | D1 |
| | the chart's shell wrapper (copies and `sed`s the config, then `docker-entrypoint.sh`) becomes `command: [vault]`, `args: [server, -config=/vault/config/vault.hcl]` | the image's own arguments are `server -dev`; the entrypoint tries `setcap` and `chown` |
| | env `VAULT_K8S_*`, `VAULT_API_ADDR`, `VAULT_CLUSTER_ADDR`, `VAULT_RAFT_NODE_ID=vault-0`, `SKIP_*`, `HOST_IP`, `POD_IP` become `VAULT_ADDR=http://127.0.0.1:8200`, and `HOME=/tmp`, which deploy-kit 1.3.1 sets for a writable `/tmp`, so the CLI keeps its token there | `api_addr` and `cluster_addr` are in the config; the raft node id is Vault's own, kept in `node-id` on the volume (rehearsed across a restart) |
| | `nodeSelector` site frankfurt becomes node affinity `frankfurt-contabo-1` | `placement.site: frankfurt`; one node there |
| | pod anti-affinity dropped; `priorityClassName: platform-data` kept, once #266 is released | one replica; D6 |
| | pod 100:1000, `fsGroup` 1000 (unchanged), plus seccomp, read-only root, all capabilities dropped, no privilege escalation; a `/tmp` emptyDir (64Mi) | `restricted`. A snapshot restore stages in `/tmp` and fails on a read-only one (rehearsed) |
| | no `IPC_LOCK`: `disable_mlock = true` in `config/vault.hcl`, as live | restricted Pod Security never grants it. The 1.21.4 image's `/bin/vault` carries no file capability (its layers, read with `crane` on 2026-10-30), so it execs under drop-ALL; only the skipped entrypoint would `setcap` it |
| | requests none, becomes 512Mi/100m, limit 512Mi | 132Mi in use; a restore holds the snapshot in memory |
| | readiness `exec vault status` every 5s becomes HTTP `/v1/sys/health` every 10s; liveness none becomes TCP 8200; a TCP startup probe (6 × 5s) | sealed answers 503: not ready, still alive, so a sealed Vault is not restarted under the person unsealing it |
| | ports 8201 (`https-internal`) and 8202 (`http-rep`) not declared | one server: no raft peer and no replication to reach it; 8201 is still bound on the pod |
| | `automountServiceAccountToken` default (on) stays on | `api` declared: the kubernetes auth method reviews each login with Vault's own token |
| ConfigMap `vault-config` | becomes `vault-vault-hcl-9415d528d4` (`config/vault.hcl`) | content-hashed Asset. Same listener, raft path, telemetry and `disable_mlock`; `service_registration "kubernetes"` dropped; `api_addr` and `cluster_addr` added; `unauthenticated_metrics_access` true (D3) |
| PVC `data-vault-0` 10Gi | new claim `vault-data` 10Gi, `prune: disabled`, filled by the restore | the old claim is the rollback; deleted in C |
| PVC `audit-vault-0` 10Gi | not rendered | `/vault/audit` is empty: no file audit device is enabled |
| Services `vault`, `vault-active`, `vault-standby`, `vault-internal`, `vault-ui` | one Service `vault`, port 8200, selector `instance` | `vault-active`/`-standby` need service registration, `vault-internal` a StatefulSet, `vault-ui` nothing selects |
| ClusterRoleBinding `vault-server-binding` (`system:auth-delegator`) | ClusterRole and binding `secrets-system-vault`: `create` on `tokenreviews` | what auth-delegator grants that Vault uses |
| Role/RoleBinding `vault-discovery-*` | not rendered | service registration is gone |
| PodDisruptionBudget `vault` | not rendered | one replica |
| ServiceMonitor `data-system/vault` | `secrets-system/vault`: no bearer token, no `format=prometheus` param, no `vault-active` relabel; job label from `instance` (still `vault`) | D3. Vault answers Prometheus format to an `Accept` that names `text/plain`, which Prometheus sends; read the series back after the flip |
| CronJob `vault-metrics-token-renewal`, VSS `vault-prometheus-token`, SA `vault-metrics-renewer` | not rendered | D3 |
| Job `vault-bootstrap-auth`, its SA, CRB and ConfigMap | not rendered | D5 |
| Deployment `sample-reader`, SA `platform-vault-sample` | not rendered | retired with the injector (R2) |
| injector and CSI provider objects | not rendered | R1, R2 |
| IngressRoute `edge-system/vault` → `data-system/vault:8200` | `vault.jorisjonkers.dev`, `authenticated`, declared as the `ui` exposure | rendered once the edge is on the estate path; the old route is deleted by hand right after the flip, since it points at the sealed Vault |
| HelmRepository `data-system/hashicorp` | not rendered | no chart |
| new | CronJob `vault-data-backup` (02:45, 90 kept, `file-backup`, off-cluster to `secrets/vault/vault-data`), claim `vault-data-backup` 10Gi, SA, VaultAuth and VSS on `secret/platform/backup/off-cluster` | `irreplaceable`, D4 |
| new | `VaultConnection secret-store`, `vault-policy` CronJob, Job, ConfigMap, SA, and the policy and role `secrets-system-vault-backup` | every estate Project has them |
| new | `Service platform-rabbitmq` (ExternalName to its Stable Address) | the optional edge Vault's rabbitmq engine reaches |
| new | `flux-system` Alert `rollouts-secrets`, Provider `reporter-secrets` | rollout events |
| rendered, not applied | NetworkPolicies `default-deny`, `vault`, `vault-secrets-operator`, `vault-backup`, `vault-policy` | render-only on this substrate, so the egress to both Postgres servers they miss (deploy-kit#737) blocks nothing yet. What is enforced is the old path's own `immich-system/immich-postgres`, which admits Vault from `data-system` alone: W9 |

### The Vault Secrets Operator

| object | difference | why |
|---|---|---|
| namespace | `vso-system` becomes `secrets-system` | the Project's namespace |
| Deployment `vault-secrets-operator-controller-manager` | becomes `vault-secrets-operator`, one container | the `kube-rbac-proxy` sidecar is dropped: metrics are served plain on 8080 |
| | `vault-secrets-operator:1.5.1` stays, now by digest (`sha256:458c842a…`) | same image |
| | args: `--leader-elect` dropped; `--client-cache-persistence-model=direct-encrypted` dropped; `--metrics-bind-address` 127.0.0.1:8080 becomes `:8080`; the rest as live | one replica elects nothing, and the lease is what lost VSO its leadership on the Pis; D2 |
| | node affinity "not the Pis" becomes every node | without leader election the reason is gone; the persisted cache that wrote to disk is gone too (D2) |
| | 64Mi/10m request, 128Mi/500m limit becomes 128Mi/50m, limit 128Mi; probes `/readyz` and `/healthz` on 8081 as live, cadence the platform's | request equals limit |
| | no priority class becomes `platform-critical-app`, once #266 is released | it holds API access, a privileged role |
| | pod `runAsNonRoot` becomes 65532:65532, seccomp, read-only root, all capabilities dropped | `restricted`; the image's own user |
| ClusterRole `vault-secrets-operator-manager-role` | `secrets-system-vault-secrets-operator`: the same rules, less `deletecollection` on Secrets and Argo `rollouts` | the model's verbs have no `deletecollection`; no Rollouts run |
| ClusterRoles `*-editor-role`, `*-viewer-role`, `metrics-reader`, `proxy-role`; Role `leader-election-role` | not rendered | aggregation helpers for people, the proxy, and the lease |
| ConfigMap `vault-secrets-operator-manager-config` | not rendered | chart-internal |
| VaultConnection `vso-system/default`, VaultAuth `vso-system/default` and `vault-secrets-operator-default-transit-auth` | not rendered | every estate VSO object names its own `secret-store` connection and its Process's VaultAuth. An old-path object still naming `vso-system/default` is re-pointed by hand ([step 10](#the-window)) |
| Service `vault-secrets-operator-metrics-service` (8443) | `vault-secrets-operator`: `metrics` 8080, `health` 8081 | no proxy |
| CRDs `secrets.hashicorp.com/v1beta1` | not rendered, stay | the Platform document's `bootstrap.crds`; the chart's `crds/` were never Helm-owned and the release is never uninstalled |
| hooks `upgrade-crds`, `pdcc` (pre-delete `--uninstall`) | not rendered | the suspended release never runs them |

### Every other estate Project

The flip removes the `vault` serving statement, so each Project's render
follows Vault: `VaultConnection secret-store` and each `vault-policy` Job's
`VAULT_ADDR` become `http://vault.secrets-system.svc.cluster.local:8200`
(15 connections), and each render-only
egress rule to Vault names `secrets-system`. Every unit that holds a
grant gains `dependsOn: apps-secrets`, 16 of them, so none applies its new
revision until Vault in `secrets-system` is unsealed and Ready. auth-api's
`VAULT_ADDR` is its own literal and does not follow: W10. The render
moves for `_estate`, auth, delivery, estate-dashboard, findability-explorer,
grimoire, hindsight, immich, karakeep, mail, n8n, outline, overleaf, prowlarr,
qbittorrent, tribelt and secrets (read 2026-10-30).

## Pre-checks

Each must print what it says. Nothing here writes.

```sh
# 1. The retirements are live: no CSI provider, no injector, no Reloader, no cert-manager.
kubectl -n data-system get daemonset/vault-csi-provider deployment/vault-agent-injector 2>&1 | grep -c NotFound   # 2
kubectl get mutatingwebhookconfiguration vault-agent-injector-cfg 2>&1 | grep -c NotFound             # 1
kubectl get ns reloader-system cert-manager 2>&1 | grep -c NotFound                                   # 2

# 2. No pod asks for an agent or for Reloader.
kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.annotations["vault.hashicorp.com/agent-inject"]=="true") | .metadata.name'   # nothing

# 3. S1 reached the live objects: both releases suspended, every object marked.
kubectl -n data-system get helmrelease vault -o jsonpath='{.spec.suspend}{"\n"}'                      # true
kubectl -n vso-system get helmrelease vault-secrets-operator -o jsonpath='{.spec.suspend}{"\n"}'     # true
kubectl get ns vso-system -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}'   # disabled

# 4. Which old-path VSO objects still name vso-system/default: each is re-pointed at step 10, or is empty.
kubectl get vaultstaticsecret,vaultdynamicsecret -A -o json | jq -r '.items[] | select((.spec.vaultAuthRef // "") | startswith("vso-system/")) | "\(.kind) \(.metadata.namespace)/\(.metadata.name)"'

# 5. Vault is healthy and on 1.21.x, and the unseal key opens it: the person holding it confirms.
kubectl -n data-system exec vault-0 -- vault status -format=json | jq -c '{version, sealed, t, n, raft_committed_index}'
#    {"version":"1.21.2","sealed":false,"t":1,"n":1,...}

# 6. Sign in, as bootstrap/secrets.sh does, and check the token can snapshot and seal.
ESTATE_VAULT_NAMESPACE=data-system   # bootstrap/lib/estate.sh reaches the old Vault with this
kubectl -n data-system port-forward svc/vault 18200:8200 &   export VAULT_ADDR=http://127.0.0.1:18200
vault login -method=oidc
vault token capabilities sys/storage/raft/snapshot   # includes read
vault token capabilities sys/seal                    # includes sudo and update

# 7. Every lease is fresh: VSO renewed each dynamic credential within the last 20 minutes.
kubectl get vaultdynamicsecret -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) \((now - (.status.lastRenewalTime|tonumber))/60|floor)min"'

# 8. The estate change B is approved with CI green, and nothing else is queued on main.
```

## The window

Start at five past an hour, so no `vault-policy` CronJob (`@hourly`) fires
into the outage. Keep these watchers open:

```sh
kubectl -n secrets-system get pods -w -o wide
flux get kustomizations -n flux-system --watch
while sleep 5; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code}\n' https://vault.jorisjonkers.dev/v1/sys/health; done
```

1. **S1**: merge fleet-infra #574, reconcile `apps-data`, `apps-core` and
   `apps-vso-secrets`, and run pre-check 3.
2. **S2**: merge fleet-infra #575, reconcile the same three. Read back that
   `data-system/vault-0`, `vso-system`'s Deployment and the claims are still
   there.
3. **B**: merge this change. Nothing is published yet: the release PR
   release-please opens for it is step 6.
4. **Stop the old VSO**, so nothing renews or issues against the old Vault
   from here on. The Secrets it wrote stay, and every pod keeps reading them.

   ```sh
   kubectl -n vso-system scale deploy/vault-secrets-operator-controller-manager --replicas=0
   ```

5. **Snapshot, then seal the old Vault.** Vault is down from here.

   ```sh
   vault operator raft snapshot save secrets-handover-$(date -u +%Y%m%dT%H%MZ).snap
   shasum -a 256 secrets-handover-*.snap        # recorded on #663
   vault status -format=json | jq .raft_committed_index   # recorded on #663
   vault operator seal
   kubectl -n data-system exec vault-0 -- vault status | grep Sealed   # true
   ```

   Keep the snapshot on the maintainer's machine and on one more medium until
   C. Never delete `vault-0`'s pod: its StatefulSet would start Vault 2.0.4.
   `VaultSealed` no longer watches `data-system` (W4), so nothing pages.

6. **P**: merge the release PR. The release publishes the Platform document and
   every platform fragment and dispatches composition. Once its pin commit
   lands:

   ```sh
   flux reconcile kustomization estate-pins -n flux-system --with-source
   flux get kustomization apps-secrets -n flux-system --watch
   ```

   `apps-secrets` applies `secrets-system`: Vault starts uninitialised
   (`/v1/sys/health` 501, not ready), VSO starts and finds nothing it can sync.
   Every other unit holds its new revision behind `dependsOn: apps-secrets`.

7. **Restore.** With a port-forward to the new Vault:

   ```sh
   kubectl -n secrets-system port-forward svc/vault 18300:8200 &   export VAULT_ADDR=http://127.0.0.1:18300
   vault operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/temporary-init.json   # a throwaway: void after the restore
   vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /tmp/temporary-init.json)"
   VAULT_TOKEN="$(jq -r .root_token /tmp/temporary-init.json)" vault operator raft snapshot restore -force secrets-handover-*.snap
   vault status | grep Sealed    # true: the restore installs the old keyring and seals
   rm /tmp/temporary-init.json   # its key and root token no longer open anything (rehearsed)
   ```

8. <a id="unseal"></a>**Unseal with the original key.**

   ```sh
   kubectl -n secrets-system exec -it deploy/vault -- vault operator unseal   # paste the one key
   vault status -format=json | jq -c '{version, sealed, raft_committed_index}'   # 1.21.4, false, >= the recorded index
   vault login -method=oidc        # people sign in as before: the oidc mount and its role came with the snapshot
   vault operator raft list-peers  # one voter, this node, at 127.0.0.1:8201 (not vault-0)
   vault auth list                 # kubernetes/ and oidc/ as before
   vault read -field=kubernetes_host auth/kubernetes/config   # https://10.43.0.1:443, unchanged
   ```

   **Vault is up from here.** If a peer other than this node is listed, Vault
   cannot elect itself; follow Vault's `peers.json` recovery on the
   `vault-data` volume, then unseal again.

9. **Every Project follows.** `apps-secrets` goes Ready once Vault reports
   ready; reconcile the rest rather than wait for their interval:

   ```sh
   for k in $(flux get kustomizations -n flux-system --no-header | awk '/^apps-/{print $1}'); do flux reconcile kustomization "$k" -n flux-system & done; wait
   ```

   Each unit's `VaultConnection` moves to `secrets-system`, its policy job runs
   against the restored Vault, VSO logs in as each Process and syncs. The nine
   dynamic database credentials are issued anew and their Deployments restart
   once (D2). The leases the snapshot holds expire within the hour and Vault
   revokes them; their Processes have moved by then.

   **auth-api is the exception**: its `VAULT_ADDR` is a literal in its own env
   file, so the render leaves it on the sealed Vault. Merge
   JorisJonkers-dev/auth-api#132 now, and its release PR, so its Canary
   analyses a copy that reaches the unsealed Vault (not before step 8: against
   a sealed or absent Vault the Canary fails and rolls back). Sign-in, which
   signs with Vault's transit key, works again once it promotes.

10. **What the render does not re-point, by hand:**

    ```sh
    # An old-path VSO object still on vso-system/default (pre-check 4): point its connection at the new Vault.
    kubectl -n vso-system patch vaultconnection default --type merge -p '{"spec":{"address":"http://vault.secrets-system.svc.cluster.local:8200"}}'
    # The old route, which sends vault.jorisjonkers.dev to the sealed Vault, once the edge renders the new one.
    kubectl -n edge-system get ingressroute -o json | jq -r '.items[] | select(.spec.routes[].match | test("vault.jorisjonkers.dev")) | "\(.metadata.name) \(.spec.routes[0].services[0].namespace)"'
    kubectl -n edge-system delete ingressroute vault   # the one whose service is in data-system
    ```

    And D4: re-point or stop `observability/vault-raft-snapshot` if it still
    runs.

The window is two hours. Vault is down from step 5 to step 8: about 10 minutes
for the release, 5 for composition and Flux, 10 for the restore and unseal, so
about 35 minutes with no slack. Steps 9 and 10, and the proof, take the rest.

**While Vault is down:** no Secret is written or refreshed, and every pod keeps
the Secret it has. auth-api cannot sign a token, so nobody can sign in. A pod
that starts and reads Vault itself (auth-api, the policy jobs) fails until
step 8. Nothing that already runs stops.

### The alert

`VaultSealed` (critical) is the only thing that says to unseal. From S2 it
watches `kube_pod_status_ready{namespace="secrets-system",
pod=~"vault-[a-z0-9]+-[a-z0-9]{5}"}`, the Deployment's pod alone. If the
observability Project carries the rule by then, its `alertRules` take the same
expression before the window (W4). The old, sealed `vault-0` is deliberately
unwatched until C.

## Proof

Read each; a Ready condition alone proves nothing.

1. `flux get kustomization apps-secrets` is Ready, and the claim
   `vault-data-backup` is `Pending` with no selected node until 02:45, which
   counts as healthy.
2. **A Secret VSO syncs refreshes after its value changes in Vault.** Add a key
   to the backup credential's document and watch the estate's own copy gain it
   within `refreshAfter` (10m), then remove it:

   ```sh
   before=$(vault kv metadata get -format=json -mount=secret platform/backup/off-cluster | jq .data.current_version)
   vault kv patch -mount=secret platform/backup/off-cluster handover-probe="$(date -u +%FT%TZ)"
   kubectl -n secrets-system get secret vault-backup-platform-backup-off-cluster -o jsonpath='{.data.handover-probe}' | base64 -d   # within 10m
   vault kv rollback -mount=secret -version="$before" platform/backup/off-cluster   # a new version equal to the old one
   ```

3. **Every Project's policy job succeeds**:
   `kubectl get jobs -A -o json | jq -r '.items[] | select(.metadata.name | startswith("vault-policy-")) | "\(.metadata.namespace) \(.status.succeeded // 0)"'`
   prints 1 for every namespace.
4. **A dynamic credential renews**: each `VaultDynamicSecret`'s
   `.status.lastRenewalTime` moves within the hour, and its Process reads its
   database (outline, n8n and tribelt load).
5. **Service accounts and people log in**: a policy job's login above, and
   `vault login -method=oidc` from the CLI and `https://vault.jorisjonkers.dev`
   in a browser.
6. `up{job="vault"}` is 1 and `vault_core_unsealed` has a series (D3).
7. Every consumer that restarted is Ready, and nothing in any namespace sits
   in `CreateContainerConfigError` on a missing key.

## After the hold

Keep the old Vault sealed and untouched for **seven days**, through one
`vault-data-backup` run that reaches the off-cluster bucket and one restore of
that copy into a throwaway Vault. Then, change C, by hand:

- `data-system`: the suspended HelmRelease `vault` (`kubectl delete` runs no
  uninstall while suspended), StatefulSet `vault`, its Services, ConfigMap,
  SA, Roles and PDB, the ClusterRoleBinding `vault-server-binding`, the
  orphaned bootstrap Job, CronJob, ServiceMonitor, SAs, VSS
  `vault-prometheus-token` and its Secret, and the claims `data-vault-0` and
  `audit-vault-0` after a last copy of the raft directory.
- `vso-system`: the suspended HelmRelease, then the namespace.
- In Vault: the roles that bind `data-system` or `vso-system` and nothing
  else (`vso-client-cache`, `vault-metrics-renewer`, `platform-sample`,
  `vault-bootstrap`), through `bootstrap/retire.sh`, each by its own issue.
- fleet-infra's drift check entries for anything of `secrets`, and
  `secrets.sh`'s `metrics-token` and `vault-bootstrap` sections (D3, D5).

## Rollback

**Before step 6** (the old Vault sealed, nothing published): unseal it and
start its VSO. Nothing else moved.

```sh
kubectl -n data-system exec -it vault-0 -- vault operator unseal
kubectl -n vso-system scale deploy/vault-secrets-operator-controller-manager --replicas=1
```

Then revert B, S2 and S1, in that order.

**After step 6**, the generic runbook's steps (deploy-kit
`docs/runbooks/handover.md#rollback`), with Vault's own first:

1. Mark `projects/secrets/source.yaml`'s Kustomization `prune: false`,
   reconcile `estate-pins`, and read the value back.
2. One estate change moves `secrets` back to `legacy`, restores the `vault`
   serving statement (`namespace: data-system`), and deletes
   `projects/secrets/`. Its release re-renders every Project against
   `data-system`.
3. Stop the new VSO, now applied by nothing:
   `kubectl -n secrets-system scale deploy/vault-secrets-operator --replicas=0`.
4. Unseal the old Vault and start its VSO, as above. Each unit re-points as
   its pin moves.
   If auth-api#132 has released, revert it in auth-api and release that, so
   auth-api reaches `data-system` again.
5. Revert S2, then S1.

**What a rollback after step 8 loses:** every write to the new Vault since the
restore, the policy jobs' among them (they run again, hourly), and the
dynamic credentials it issued: their logins stay in Postgres, unknown to the
old Vault, and are dropped by hand. The claim `vault-data` is never pruned
and keeps the new Vault's state for a second attempt.
