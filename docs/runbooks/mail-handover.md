# Handing `mail` over to the estate path

Moves the Project `mail` (Stalwart and its provisioner sidecar, namespace
`mail-system`, on `frankfurt-contabo-1`) from fleet-infra's old path to its pin
here, on deploy-kit 1.2.0, in the three changes of deploy-kit
`spec/v1/60-setup.md#handing-over-one-project-at-a-time`. Tracking:
JorisJonkers-dev/deploy-kit#656 and #205 here, under the handovers epic #204.

Stalwart is declared whole and adopted in place: same namespace, same Service
name and ports, same claim `stalwart-data`, same images by digest. Inbound
SMTP, IMAP and submission are down while the Deployment is recreated, about a
minute plus Stalwart's start; sending servers queue and retry. Run it with the
maintainer present, at a quiet hour. A live step is the maintainer's go-ahead,
never an agent's.

## What it waits on

| | what | where |
|---|---|---|
| W1 | `delivery`, `_canary` and `_estate` republished on 1.0.0 | JorisJonkers-dev/deploy-kit#380 |
| W2 | the handover runbook this file follows | JorisJonkers-dev/deploy-kit#381 |
| W3 | this repository's releases publish with deploy-kit 1.2.0: the mail fragment names the sidecar's `command` (1.1.0) and the Asset it mounts (1.2.0), which an older toolkit refuses, so the Publish Fragment release `release.yml` calls runs 1.2.0 | this repository |
| W4 | `stalwart.recovery_admin` in `secret/platform/mail`: `bootstrap/secrets.sh --only mail` writes it from the admin login | a person |

## The changes, in order

| # | where | what | outage |
|---|---|---|---|
| M1 | fleet-infra, PR "orphan the mail Project" | every object `cluster/flux/apps/mail/` applies gets `kustomize.toolkit.fluxcd.io/prune: disabled`, the namespace and the claim `stalwart-data` above all: the claim's volume reclaims `Delete`, so a prune would destroy every mailbox | none |
| M2 | fleet-infra, PR "drop the mail Project's manifests" | the manifests and the Flux Kustomization `apps-mail` leave fleet-infra; `ingressroute-stalwart.yaml` moves unchanged to `apps-edge`, beside the redirect Middleware it already uses, since routes flip only with the edge's own handover | none |
| P | a person | `bootstrap/secrets.sh --only mail` (W4); it also restarts `auth-api-primary` one pod at a time, since auth reads `secret/platform/mail` too | none |
| B | this repository, this change, then its release | the ledger moves `mail` to `estate`, and the Platform document gains the L4 Address `mail-node` | the recreate |
| C | fleet-infra | the drift check's entry for `stalwart-provisioner`, and the `mail-system` binding of the old `vso` role in `bootstrap-auth.sh` | none |

M2's Kustomization must be gone, not only emptied, before B: the estate's unit
is also `flux-system/apps-mail`.

## The render against the old path

Rendered with deploy-kit 1.2.0 from this change (`deploy-kit compose` over
every participant's newest fragment, this branch's Platform and mail
fragments, `participants.yml` and `cluster-state.yml`), against `kubectl
kustomize cluster/flux/apps/mail` of fleet-infra `main` and the live objects,
read 2026-10-29.

| object | difference | why |
|---|---|---|
| Namespace `mail-system` | gains `app.kubernetes.io/managed-by: deploy-kit` | every rendered namespace carries it; consumers' policies select on it |
| Deployment `stalwart` | selector `name` becomes `name` + `instance` | the fixed label set; a selector is immutable, so the first pin recreates the Deployment (`force: Enabled`) |
| | `nodeSelector` site `frankfurt` becomes node affinity on `frankfurt-contabo-1` | derived from `mail-node`, a node address; the same node today |
| | the eight mail ports stay host ports, `993` named `imaps` (was `imaptls`) | the surface's name |
| | pod runs as 2000:2000, `fsGroup` 2000, `RuntimeDefault` seccomp; each container read-only root, no privilege escalation, every capability dropped; `/tmp` an emptyDir | `hardening: restricted`. Stalwart's image user is already `stalwart` (2000) and its listeners bind below 1024 as that user today; the provisioner ran as root and now runs as 2000, writing only `/tmp` |
| | memory request 1536Mi becomes 3Gi, the CPU limit of 2 goes | request equals limit; `frankfurt-contabo-1` has about 7Gi unrequested |
| | probes: a startup probe (TCP 8080, 62 × 5s) holds the 310s budget; readiness `/admin/` and liveness TCP 8080 every 10s, no initial delay | `startupBudget` and the platform's probe cadence replace the hand-written delays |
| | both containers receive all nine variables: the server held only `STALWART_RECOVERY_ADMIN`, the sidecar the rest | a Process's environment reaches every container of its pod |
| | `STALWART_RECOVERY_ADMIN` reads `stalwart.recovery_admin`, one key | a value is one placeholder; the old path templated `user:password` from two keys |
| | the sidecar runs `stalwart-provisioner-apply`, as the old path's command names it, and mounts the manifest at `/etc/stalwart-provisioner/manifest.json`, the path the script reads by default (the old path mounted the directory); the server's container mounts it too, and never reads it | the sidecar's `command` and `assets`; the manifest is the Process's Asset so the sidecar can name it |
| | `revisionHistoryLimit` 3 becomes the default | fleet-infra's patch on `apps-mail`; the render sets none |
| Service `stalwart` | selector `name` becomes `instance`; port `imaptls` named `imaps` | same ports and targets; Gatus probes the ports by number |
| PVC `stalwart-data` | adopted: gains the label set and `prune: disabled` | `durability: irreplaceable` |
| ConfigMaps | `stalwart-config-json` and `stalwart-provisioner-manifest` become `stalwart-config-json-6faa238f1c` and `stalwart-manifest-json-04fbd3d7f0`, byte-identical content | Assets are content-hashed; the old two are deleted by hand |
| VaultStaticSecrets | `stalwart-mail`, `stalwart-edge`, `stalwart-auth-mail`, `stalwart-notes-mail`, `stalwart-latex-mail` become `stalwart-platform-mail`, `stalwart-platform-edge`, `stalwart-auth-api`, `stalwart-platform-outline`, `stalwart-platform-overleaf` | one per grant, named for its path; the old five, their Secrets and the `vault-secrets-operator` ServiceAccount are deleted by hand |
| | no version pin, `refreshAfter` 24h becomes 10m, `hmacSecretData` on, no templates: each Secret holds the document's own keys | the pins existed because VSO restarted Stalwart on every refresh; the estate path's VSO objects carry `hmacSecretData` and restart on a change of content: overleaf, which reads `secret/platform/overleaf` the same way, has run one ReplicaSet since 2026-10-22. Every pinned value equals the path's current value today (compared by fingerprint) |
| | log in as `mail-system-stalwart`, not `vso-system/default` | identity per Process; the Vault policy job writes the role and its policy |
| new | `VaultConnection secret-store`; the `vault-policy` CronJob, Job, ConfigMap and ServiceAccount | how every estate Project reaches Vault |
| new | CronJob `stalwart-data-backup` (02:45 daily, 90 kept, `file-backup`), claim `stalwart-data-backup` 20Gi, ServiceAccount, VaultAuth and the grant on `secret/platform/backup/off-cluster` | `irreplaceable`: the old path backs the volume up only from the host. Mail is the first Project to read the off-cluster credential |
| new | `flux-system` Alert `rollouts-mail` and Provider `reporter-mail` | rollout events to the Reporter |
| rendered, not applied | NetworkPolicies `default-deny`, `stalwart`, `stalwart-backup`, `vault-policy` | render-only on this substrate (`networkPolicyController: embedded`); the old path has none either |
| not rendered | IngressRoute `edge-system/stalwart`, Middleware `edge-system/stalwart-root-to-admin` | while edge is `legacy` no Project's share carries a route; M2 keeps both under `apps-edge`. The redirect is declared, so the edge's handover renders it |
| not rendered | the `mail.jorisjonkers.dev` A record (167.86.79.203) and the MX | a node address publishes no DNS; both stay as they are in Cloudflare |
| other units | `apps-auth`, `apps-outline` and `apps-overleaf` gain `dependsOn: apps-mail` | they reach `stalwart`'s `submission` surface |

## Pre-checks

Each must print what it says. Nothing here writes.

```sh
# 1. M1 reached the live objects: every mail object, the namespace and the claim carry the mark.
kubectl -n mail-system get deploy,svc,pvc,cm,sa,vaultstaticsecret -o json \
  | jq -r '.items[] | "\(.kind)/\(.metadata.name) \(.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] // "UNMARKED")"'
kubectl get ns mail-system -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}'
#    every line says "disabled".

# 2. M2 landed: fleet-infra's apps-mail is gone, and apps-edge owns the route.
kubectl -n flux-system get kustomization apps-mail -o jsonpath='{.spec.sourceRef.kind}{"\n"}' 2>&1
#    NotFound.
kubectl -n edge-system get ingressroute stalwart -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}'
#    apps-edge

# 3. Vault holds every key the render reads (names only). Port-forward to svc/vault in
#    data-system and sign in with OIDC, as bootstrap/secrets.sh does.
for p in platform/mail platform/edge auth-api platform/outline platform/overleaf platform/backup/off-cluster; do
  echo "$p: $(vault kv get -format=json secret/$p | jq -c '.data.data | keys')"; done
#    platform/mail holds stalwart.admin_user, stalwart.admin_password, stalwart.recovery_admin and
#    account.password; platform/edge cloudflare.dns_api_token; auth-api mail.password;
#    platform/outline and platform/overleaf smtp.password; platform/backup/off-cluster exists. A
#    missing key fails the pod at start. Nothing has read the off-cluster document yet: without
#    it the backup's VaultStaticSecret never syncs and the 02:45 Job cannot start.

# 4. The sidecar runs the apply script and mounts the manifest, in the render.
yq 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "stalwart-apply") | [.command, .volumeMounts[].mountPath]' \
  <rendered>/apps/mail/stalwart/workload.yaml
```

## Cutover

Set a terminal per watcher first:

```sh
kubectl -n mail-system get pods -w -o wide
kubectl -n mail-system logs -f deploy/stalwart -c stalwart-apply
while sleep 5; do printf '%s ' "$(date +%T)"; nc -z -w 3 mail.jorisjonkers.dev 25 && echo up || echo down; done
```

1. **Merge B**, then the release PR release-please opens for it. The release
   publishes the Platform document and the mail fragment and dispatches
   composition; reconcile `estate-pins` once its pin lands.

   ```sh
   flux reconcile kustomization estate-pins -n flux-system --with-source
   flux get kustomization apps-mail -n flux-system --watch
   ```

2. **What happens, in order** (each a watch, not an action):
   - the `vault-policy` Job completes: policy and role `mail-system-stalwart` exist;
   - VSO syncs the five `stalwart-platform-*` and `stalwart-auth-api` Secrets;
   - Flux deletes and recreates the Deployment `stalwart`. Its old pod goes
     with it. The new pod waits until the old one has released the host ports,
     then starts on `stalwart-data`: this is the outage;
   - the pod reports Ready once `/admin/` answers and the sidecar idles
     (`apply: reconcile complete`, then `apply: idling`);
   - `apps-mail` goes Ready, and `apps-auth`, `apps-outline` and
     `apps-overleaf` hold their next change until it does.

   Do not orphan the old ReplicaSet to keep a pod serving: two Stalwarts cannot
   share the host ports, nor one RocksDB directory.

## Proof

Read each; a Ready condition alone proves nothing.

1. `flux get kustomization apps-mail` is Ready, and the claim `stalwart-data-backup` is
   `Pending` with no selected node until 02:45, which counts as healthy.
2. From outside the cluster: a mail sent to `joris.jonkers@jorisjonkers.dev`
   arrives, a reply leaves and is delivered, and an IMAP login on 993 lists it
   (`openssl s_client -connect mail.jorisjonkers.dev:993`).
3. From inside: auth-api sends a password-reset mail and Outline sends a
   notification, both over `submission` 587.
4. `https://stalwart.jorisjonkers.dev/` redirects to `/admin/` behind
   forward-auth.
5. The sidecar's log ends `apply: reconcile complete` with no error.

Then change C, and by hand: the old five VaultStaticSecrets and their Secrets,
the two old ConfigMaps, the ServiceAccount `vault-secrets-operator` and the old
ReplicaSet.

## Rollback

The generic runbook's steps (deploy-kit `docs/runbooks/handover.md#rollback`):
mark `projects/mail/source.yaml`'s Kustomization `prune: false`, move `mail`
back to `legacy` and delete `projects/mail/`, then revert M2 and M1. The claim
is never touched: the render marks it `prune: disabled`.
