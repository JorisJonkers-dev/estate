# Handovers: what each one changes here

Each Project that leaves fleet-infra for the estate path is recorded here: the
changes this repository makes for it, what has to be true before they merge,
and what is left to delete by hand afterwards. The steps themselves are
deploy-kit's (`spec/v1/60-setup.md#handing-over-one-project-at-a-time`); the
render's diff against the old path's objects is in each handover's pull
request.

## utility: adguard and headlamp

JorisJonkers-dev/deploy-kit#657. Both stay in `utility-system`, and neither
holds data.

### What this repository changes

- **`platform/utility/`**: the project file, from deploy-kit's worked example;
  AdGuard's configuration as an Asset (`config/AdGuardHome.yaml`, the old
  path's ConfigMap with the web UI on 3000 and DNS on 5353); and headlamp's
  env file (`env/headlamp/base.env`, the flags the old chart passed, as
  `HEADLAMP_CONFIG_*`).
- **`platform.intent.yml`**:
  - `l4Addresses.lan-dns`, a pool of one address, 192.168.0.98.
  - `nodeAgents.l4-speaker`, MetalLB as fleet-infra runs it. Composition
    refuses a pool without it (`E_NO_NODE_AGENT_POLICY`); `validate` does not.
  - `apiAccess.holders` gains `utility/headlamp`.
  - `humanGrants`: the `oidc:k8s-admin` grant to `cluster-admin`, which the old
    path holds as `headlamp-oidc-admin` beside headlamp.
  - The ledger moves `utility` from `legacy` to `estate`.
- **`images.lock.yml`**: adguard, headlamp, metallb-speaker and
  metallb-controller, by the digests the live pods run.
- **`participants.yml`** and **`release.yml`**: utility publishes with the
  Platform document, on this repository's releases.

`substrate.upstreamNameservers` was already here (JorisJonkers-dev/deploy-kit#634).

### Before it merges

- JorisJonkers-dev/deploy-kit#380: the estate path runs 1.0.
- **AdGuard's configuration has to be a seeded Asset**
  (JorisJonkers-dev/deploy-kit#693), and `toolkit.yml` has to pin a release
  that has it. AdGuard rewrites its configuration on every start and exits
  when it cannot, so the read-only mount deploy-kit 1.0.1 renders stops it.
  Without any configuration it starts its setup wizard and answers no DNS.
- **headlamp needs its in-cluster credentials.** Its in-cluster mode reads the
  ServiceAccount token and CA from the mounted token, and the render mounts
  none (`api` with no rules). The ServiceAccount holds no binding, so mounting
  its token grants nothing; whether the model mounts it is deploy-kit's to
  settle.
- **AdGuard's query log fits in 64Mi only on a quiet day.** The `work`
  directory holds 66MB on instance b today; the render's writable paths take
  the platform's 64Mi `ephemeral.size`, and the pod is evicted past it. Either
  the platform's size rises or the query log is kept in memory
  (`querylog_file_enabled: false`).
- **fleet-infra, before the third change:**
  - MetalLB has an `IPAddressPool` named `lan-dns`, holding 192.168.0.98/32
    with `autoAssign: false`, and an `L2Advertisement` for it; `enschede-lan`
    no longer holds .98. MetalLB refuses two pools that overlap.
  - The old headlamp Service also exposes 4466, and the IngressRoute
    `edge-system/headlamp` names 4466 rather than 80: Flagger's `headlamp`
    Service exposes 4466 alone.
  - fleet-infra's first two changes: orphan `utility-system`, then remove it.
    The HelmRelease is suspended before it is deleted, so its chart's objects
    stay.

### The cut-over

1. Merge, then merge the release. Composition delivers `apps-utility`; the new
   Deployment `adguard` starts beside `adguard-ha-a` and `adguard-ha-b`, and
   `adguard-lan-dns` waits for 192.168.0.98, which `adguard-ha-a` holds.
2. Delete Service `adguard-ha-a`. MetalLB hands .98 to `adguard-lan-dns`;
   while it moves, the router's second server, .97 on `adguard-ha-b`, answers.
3. Check DNS on 192.168.0.98, and point the router at it alone.
4. Point the IngressRoute `edge-system/adguard` at Service `adguard`, port
   3000 (a fleet-infra commit while the edge is legacy).
5. Delete what is left (below), and check headlamp signs in.

### Left to delete by hand

`utility-system`: Deployments `adguard-ha-a` and `adguard-ha-b`, Services
`adguard-ha-b` and `adguard-ha-ui`, ConfigMap `adguard-ha-config`, HelmRelease
and HelmRepository `headlamp`, Secret `oidc` and the `sh.helm.release.v1.headlamp.*`
Secrets. Cluster-wide: ClusterRoleBinding `headlamp-oidc-admin`, once
`human:oidc:k8s-admin:cluster-admin` exists.
