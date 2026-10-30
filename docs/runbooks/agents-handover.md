# Handing `agents` over to the estate path

Moves the Project `agents` (hermes and kubernetes-mcp-server, with agents-api
and agents-ui parked, namespace `agents-system`) from fleet-infra's old path to
its pin here, on deploy-kit 1.3.0, in the three changes of deploy-kit
`spec/v1/60-setup.md#handing-over-one-project-at-a-time`. Tracking:
JorisJonkers-dev/deploy-kit#658.

Both running Applications are adopted in place: same namespace, same Service
names and ports, same claim `hermes-data`, same images by digest. hermes is
down while its Deployment is recreated, about a minute plus its start; the MCP
server is replaced by Flagger's primary without an outage. The claims
`claude-credentials` and `codex-credentials`, the retired runners' logins, are
no Process's: they stay where they are, with their data, applied by nothing. A
live step is the maintainer's go-ahead, never an agent's.

## Decisions for the maintainer

| | decision | recommendation |
|---|---|---|
| D1 | **Which `config.yaml` hermes runs with: decided 2026-10-30, the live file.** The seeded Asset replaces `/opt/data/config.yaml` before every start, so what this repository ships is what hermes runs. `platform/agents/config/hermes/config.yaml` is fleet-infra's live `config.yaml` (the `hermes-config` ConfigMap on its `main`, identical to the cluster's), with its three `@VAR@` markers rewritten as `${GITHUB_PAT}`, `${HINDSIGHT_API_TOKEN}` and `${OVERLEAF_SESSION}` and nothing else changed. It holds no secret value; each of the three reaches hermes through `env/hermes/base.env`. Its comments still describe the old path's seed step and `.env` | decided |
| D2 | **The old `/opt/data/.env`.** The old path's seed step writes the provider keys and `GITHUB_PERSONAL_ACCESS_TOKEN` into `/opt/data/.env` on every start. Nothing writes it on the estate path, where the same values are the process's own environment; the stale file stays on the volume, and whether hermes lets it override its environment was not checked | Move it aside once hermes runs on the estate path (cutover step 5), so a key rotated in Vault is the one hermes uses |
| D3 | **agents-api and agents-ui stay declared, parked.** The worked example keeps them so unparking is deleting a line; fleet-infra#531 retires them on the old path (2026-10-23). Parked, they render two zero-replica Deployments, their Services, ServiceAccounts, agents-api's Role and their NetworkPolicies | Keep them for this handover, which copies the example; delete both blocks in a later change if the retirement is final |
| D4 | **hermes's memory request rises from 1Gi to 3Gi** (2Gi for the Process plus its 1Gi in-memory `/dev/shm`; request equals limit). `enschede-gtx-960m-1` has 2096Mi unrequested today, so the new pod fits by 48Mi once the old one is gone. Live, hermes works at 1069Mi and peaked at 1.4Gi | Delete the orphaned `auth-bootstrap` pod (128Mi, retired by fleet-infra#531) before the flip, and read the margin again at pre-check 5 |

## What it waits on

| | what | where |
|---|---|---|
| W1 | the utility handover, before this one in the order | JorisJonkers-dev/deploy-kit#657, JorisJonkers-dev/estate#248 |
| W2 | D2 to D4 decided | above |
| W3 | fleet-infra#531, if it goes first: these changes were checked to merge after it | JorisJonkers-dev/fleet-infra#531 |

Nothing needs a Vault write. `secret/data/agents/hermes` holds `github-pat`,
`hindsight-api-token` and `openrouter-api-key` (and two unused dashboard keys),
read from the Secret VSO syncs today. Every key the render reads is optional, so
the four that are absent (`memory-api-key`, `overleaf-session`,
`anthropic-api-key`, `openai-api-key`) disable only their tools, as live.

## The changes, in order

| # | where | what | when | outage |
|---|---|---|---|---|
| A | JorisJonkers-dev/fleet-infra#559, "mark agents-system and its three claims never to be pruned" | the namespace, in both copies, and `hermes-data`, `claude-credentials`, `codex-credentials` get `kustomize.toolkit.fluxcd.io/prune: disabled`. By hand: the three volumes to `Retain` | before the window | none |
| B | JorisJonkers-dev/fleet-infra#560, "orphan the agents Project" | `apps-agents` and `apps-stateless` mark every object they apply through `commonMetadata`; `apps-agents` stops pruning | in the window, step 1 | none |
| C | JorisJonkers-dev/fleet-infra#561, "drop the agents Project's manifests" | `cluster/flux/apps/agents/`, `stateless/agents-api/`, `stateless/agents-ui/` and `flux-system/apps-agents` go. hermes's two routes move unchanged to `apps-edge`, and its NetworkPolicy to `apps-stateless`, now also admitting the MCP server's Flagger primary | in the window, step 2 | none |
| D | JorisJonkers-dev/estate#258, then its release | the ledger moves `agents` to `estate`; the Platform document gains the seeder, `dns.direct` on the public tier and the two API holders | in the window, step 3 | hermes's recreate |
| E | fleet-infra | `agents-system` leaves the old `vso` role's bound namespaces in `bootstrap-auth.sh`; the drift check needs no entry, since both images are third-party | after the flip | none |

C must land before D: the estate's unit is also `flux-system/apps-agents`.

## The render against the old path

Rendered with deploy-kit 1.3.0, which the estate's `toolkit.yml` pins (`deploy-kit compose` over every participant's
newest fragment, this branch's Platform and Project fragments,
`participants.yml` and `cluster-state.yml`), against `kubectl kustomize` of
fleet-infra `main` (72a449c) `cluster/flux/apps/agents` and
`cluster/flux/apps/stateless`, and the live objects, read 2026-10-29. 1.3.0
adds two ConfigMaps to what 1.2.0 rendered, `hermes-external-checks` and
`agents-ui-external-checks`, for Gatus.

### hermes

| live | render | why |
|---|---|---|
| Deployment selector `name` | `name` + `instance` | the fixed label set; a selector is immutable, so the first pin recreates the Deployment (`force: Enabled`) |
| `nodeSelector` node-id `enschede-gtx-960m-1` | node affinity on `enschede-gtx-960m-1` | derived from the claim's node in the ClusterState snapshot; the same node |
| starts as root with `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`, writable root filesystem; s6 drops hermes to 10000 | pod and every container run as 10000:10000, `fsGroup` 10000, every capability dropped, read-only root, seccomp `RuntimeDefault`; `/run` and `/tmp` emptyDirs of 64Mi; `S6_YES_I_WANT_A_WORLD_WRITABLE_RUN_BECAUSE_KUBERNETES=1` | `hardening: restricted`; shown to run in JorisJonkers-dev/deploy-kit#692. Pre-check 6 reads the volume's ownership, because local-path applies no `fsGroup` |
| init `seed-config` (alpine, sed of `@VAR@`, writes `config.yaml` and `.env`, warns on missing keys) | init `seed` (busybox, 16Mi), copies the content-hashed ConfigMap `hermes-config-yaml-868e18008f` onto `/opt/data/config.yaml` with mode 0600, keeping `config.yaml.superseded` | a seeded Asset ([0124](https://github.com/JorisJonkers-dev/deploy-kit/blob/main/docs/adr/model/0124-a-seeded-asset-is-copied-onto-a-volume-before-each-start.md)); hermes expands `${VAR}` itself. The contents are the live file's (D1); `.env` is D2's |
| init `sync-skills` (alpine as root, git clones from `sources.conf`) | none | RENDER-GAPS A8, JorisJonkers-dev/deploy-kit#706, open: hermes runs with the skills its image bundles, the maintainer's decision. The last sync's copy stays in `/opt/data/skills-vendored`, which the live config still names in `skills.external_dirs`, so hermes keeps reading that frozen copy |
| env from Secret `hermes-credentials` (VSO, `vso-system/default`, 1h refresh) | env from `hermes-agents-hermes` (own `VaultAuth` as `agents-system-hermes`, 10m refresh, `hmacSecretData`), every key optional; `GITHUB_PERSONAL_ACCESS_TOKEN` from `github-pat`, as the old `.env` carried it | identity per Process; the policy job writes the role and its read policy on `secret/data/agents/hermes` and its metadata |
| issuer `https://auth.jorisjonkers.dev`, client `hermes`, public URL `https://hermes.jorisjonkers.dev` | the same values, from `${exposure:auth.public#url}` and `${exposure:hermes.public#url}` | the Platform document names no sign-in provider, so no `client` block (`E_NO_SIGN_IN_PROVIDER`); hermes keeps signing in against auth-api, whose registered redirect URI is unchanged |
| requests 250m/1Gi, limits 2 CPU/4Gi | 250m/3Gi, limit 3Gi, no CPU limit | request equals limit, and the in-memory `/dev/shm` counts toward it: D4 |
| `/dev/shm` emptyDir, Memory, 1Gi | the same | `{path: /dev/shm, memory: 1Gi}` |
| probes `/api/status`: readiness delay 20s × 6 of 10s, liveness delay 60s × 4 of 30s | startup 24 × 5s (the 120s budget), readiness and liveness every 10s × 3, no delay | `startupBudget` and the platform's cadence |
| `progressDeadlineSeconds` 900, `revisionHistoryLimit` 3, Reloader annotation | 660, default, none | derived from the budget; the 900 covered the first 950MiB pull, which the node has cached. VSO restarts hermes on a change of content |
| ServiceAccount `default`, no token | ServiceAccount `hermes`, no token | the same: hermes reaches the cluster only through the MCP server |
| Service `hermes` 9119, selector `name` | Service `hermes` 9119, selector `instance` | same name and port; Gatus's probe and both routes keep working |
| PVC `hermes-data` 10Gi | adopted, with the label set and `prune: disabled` | `durability: recoverable` |
| no backup | CronJob `hermes-data-backup` (03:15, 14 kept, `file-backup`), claim `hermes-data-backup` 10Gi, ServiceAccount | `recoverable`; on the same node and disk, since the job mounts the RWO claim |
| NetworkPolicy `hermes` (old path, enforced) | rendered `hermes` and `hermes-backup`, not applied | render-only on this substrate. The old policy stays applied by fleet-infra (change C), now admitting `kubernetes-mcp-server-primary` too, so hermes keeps its RFC1918 exclusion |
| IngressRoutes `hermes` (public, grey-cloud to 167.86.79.203) and `hermes-lan` | not rendered | no Project carries routes while edge is legacy; both move to `apps-edge` (C). `proxied: false` and the tier's new `dns.direct` render the same record at the edge's handover |

### kubernetes-mcp-server

| live | render | why |
|---|---|---|
| image by tag `v0.0.66` | the same image by digest `sha256:6d650f4b…` | the images lock; the digest is the live pod's |
| Deployment selector `name`, 1 replica, RollingUpdate 25% | Deployment plus Canary (Flagger's `kubernetes-mcp-server-primary`), surge 1, unavailable 0 | `cutover: continuous`. Flagger takes over the Service `kubernetes-mcp-server` and points it at the primary, as with auth's |
| any node (runs on frankfurt-contabo-1) | affinity on all six nodes | no placement constraint |
| 1000:1000, read-only root, caps dropped | the same, plus seccomp `RuntimeDefault` | the lock's uid; the image names 65532 |
| requests 50m/64Mi, limits 200m/256Mi | 50m/256Mi, limit 256Mi | request equals limit; it peaked at 216Mi |
| probes `/healthz` delay 5s, timeout 1s | startup 4 × 5s, readiness and liveness every 10s, timeout 5s | budget and cadence |
| ClusterRole `kubernetes-mcp-server-read-only` (`traefik.io` and `traefik.containo.us`) | ClusterRole `agents-system-kubernetes-mcp-server`, the same rules without `traefik.containo.us` | the declared groups; the old Traefik group serves nothing on this cluster. The old ClusterRole and binding are deleted by hand |
| no priority class | none | the estate's Platform document declares no `priority` block, unlike the worked one |
| — | ConfigMap `kubernetes-mcp-server-release-gate` | the Release Gate's inputs |

### agents-api and agents-ui (parked)

| live | render | why |
|---|---|---|
| Deployments `agents-api`, `agents-api-ws`, `agents-ui` at 0 | `agents-api` and `agents-ui` at 0, recreated with the label set | parked; `agents-api-ws` is not modelled and is deleted by hand |
| Services `agents-api`, `agents-api-ws`, `agents-ui` | `agents-api`, `agents-ui`, selector `instance` | `agents-api-ws` deleted by hand |
| Role and ClusterRole of agents-api, the runner SA, `runner-default` policy | Role `agents-api` (ConfigMaps in its namespace), its spawn template's policy, render-only | `apiAccess.namespaceHolders`; the cluster-wide node read is not declared |
| PDBs, ServiceMonitor, claim `agents-api-agent-home` (Pending, no data), five IngressRoutes | none | parked processes get no budget; deleted by hand, as fleet-infra#531 lists |

### The namespace, and what only the render has

- **Namespace `agents-system`** is taken over in place. The estate's apply drops
  the old path's `pod-security.kubernetes.io/*` labels (both paths apply as
  `kustomize-controller`) and its `prune: disabled` mark, so from then on
  deleting the estate's `apps-agents` would delete the namespace and every claim
  in it. Without the labels the cluster's default admission applies; every pod
  the render emits passes `restricted`.
- **Only in the render:** `VaultConnection secret-store`; the `vault-policy`
  CronJob, Job, ConfigMap and ServiceAccount; the `hermes-data-backup` CronJob
  and claim; `flux-system` Alert `rollouts-agents` and Provider
  `reporter-agents`.

### Left to delete by hand after the cut-over

- **In `agents-system`:** VaultStaticSecrets `hermes-credentials`,
  `agents-github-deploy-key`, `github-app` and their Secrets; ConfigMaps
  `hermes-config`, `hermes-skills`, `hermes-bootstrap`, `agents-mcp-servers`;
  ServiceAccounts `vault-secrets-operator`, `agent-runner`, `agents-api` (the
  render's replaces it); Pod `auth-bootstrap`; CronJob `agents-refresh-ping`;
  Role and RoleBinding `agents-api-runner-controller`; NetworkPolicy
  `runner-default`; Deployment and Service `agents-api-ws`; PDBs `agents-api`,
  `agents-ui`; ServiceMonitor `agents-api`; claim `agents-api-agent-home`; the
  runner leftovers fleet-infra#531 lists.
- **Cluster-wide:** ClusterRoles and bindings `kubernetes-mcp-server-read-only`
  and `agents-api-node-reader`.
- **In `edge-system`:** IngressRoutes `agents-api`, `agents-api-health`,
  `agents-ui`, `agents-ws`, `agents-ws-lan`.
- **Kept:** `claude-credentials`, `codex-credentials`, until you decide.

## Pre-checks

Each must print what it says. Nothing here writes.

```sh
# 1. A and B reached the live objects: every object of both units, the namespace and the claims, carry the mark.
kubectl -n agents-system get deploy,svc,pvc,cm,sa,secret,vaultstaticsecret,networkpolicy,role,rolebinding,pdb,cronjob,pod -o json \
  | jq -r '.items[] | select(.metadata.labels["kustomize.toolkit.fluxcd.io/name"] != null) | "\(.kind)/\(.metadata.name) \(.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] // "UNMARKED")"'
kubectl get ns agents-system -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}'
kubectl -n flux-system get kustomization apps-agents -o jsonpath='{.spec.prune}{"\n"}'   # false
#    every line says "disabled".

# 2. The three volumes are Retain.
kubectl get pv pvc-5c74926a-7a67-49eb-a2f9-73751d817dce pvc-d38b6be1-46e7-42eb-9c1b-9628a86c2128 \
  pvc-23b9cd34-7179-4fc0-8832-7c58e01e9790 -o jsonpath='{range .items[*]}{.spec.claimRef.name} {.spec.persistentVolumeReclaimPolicy}{"\n"}{end}'

# 3. C landed: fleet-infra's apps-agents is gone, apps-edge owns both routes, apps-stateless the policy.
kubectl -n flux-system get kustomization apps-agents 2>&1          # NotFound
kubectl -n edge-system get ingressroute hermes hermes-lan -o jsonpath='{range .items[*]}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}{end}'   # apps-edge twice
kubectl -n agents-system get networkpolicy hermes -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}'   # apps-stateless

# 4. Vault holds the keys hermes reads (names only).
kubectl -n agents-system get secret hermes-credentials -o json | jq -r '.data | keys[]'
#    github-pat, hindsight-api-token, openrouter-api-key at least; the rest are optional.

# 5. hermes fits on its node: unrequested memory, plus the old pod's 1Gi, must exceed 3Gi.
kubectl describe node enschede-gtx-960m-1 | sed -n '/Allocated resources/,/Events/p'

# 6. The volume is hermes's: nothing under /opt/data owned by anyone but 10000.
kubectl -n agents-system exec deploy/hermes -c hermes -- sh -c 'find /opt/data -xdev ! -user 10000 | head'
#    prints nothing. Anything it prints is chowned to 10000:10000 before the flip, or hermes cannot write it.
```

## Cutover

```sh
kubectl -n agents-system get pods -w -o wide
while sleep 5; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code}\n' https://hermes.jorisjonkers.dev/api/status; done
```

1. **Stop the old hermes, so two gateways never share `/opt/data`.** Once C
   has landed: `kubectl -n agents-system scale deploy hermes --replicas=0`, and
   wait for its pod to go. hermes is down from here until step 3.
2. **Merge D**, then the release PR release-please opens for it. The release
   publishes the Platform document and the agents fragment and dispatches
   composition; reconcile `estate-pins` once its pin lands.

   ```sh
   flux reconcile kustomization estate-pins -n flux-system --with-source
   flux get kustomization apps-agents -n flux-system --watch
   ```

3. **What happens, in order** (each a watch, not an action): the `vault-policy`
   Job writes policy and role `agents-system-hermes`; VSO syncs
   `hermes-agents-hermes`; Flux deletes and recreates `hermes`,
   `kubernetes-mcp-server`, `agents-api` and `agents-ui`; hermes's `seed` init
   copies the config and hermes starts; Flagger initialises
   `kubernetes-mcp-server-primary` and moves the Service onto it.
4. **Repoint nothing.** Both routes keep naming `agents-system/hermes:9119`.
5. **D2:** move the stale `.env` aside, then restart hermes once:
   `kubectl -n agents-system exec deploy/hermes -c hermes -- mv /opt/data/.env /opt/data/.env.old-path`.

## Proof

1. `flux get kustomization apps-agents` is Ready; `hermes-data-backup` is
   `Pending` with no selected node until 03:15, which counts as healthy.
2. `https://hermes.jorisjonkers.dev/` signs in through auth-api, and
   `/api/status` reports the gateway running.
3. hermes lists the cluster's pods through the `kubernetes` MCP server: the
   request crosses the old NetworkPolicy to `kubernetes-mcp-server-primary`.
4. hermes answers one chat turn, so its model key reached it.
5. hermes's log shows the playwright, drawio and overleaf MCP servers started.
   Each runs through `npx`, which writes its package cache under the home
   directory: under the read-only root it works only if that is on the
   volume or `/tmp`. If one fails, the rest of hermes runs without it; declare
   the path it needs as a writable path in a follow-up.

Then change E, and the deletions above.

## Rollback

The generic runbook's steps (deploy-kit `docs/runbooks/handover.md#rollback`):
mark `projects/agents/source.yaml`'s Kustomization `prune: false`, move
`agents` back to `legacy` and delete `projects/agents/`, then revert C and B.
Scale the render's `hermes` to 0 first, for the single writer. The claims are
never touched: the render marks `hermes-data` `prune: disabled`, and A's marks
stay.
