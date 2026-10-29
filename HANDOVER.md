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
  AdGuard's configuration as a seeded Asset (`config/AdGuardHome.yaml`, the
  old path's ConfigMap with the web UI on 3000 and DNS on 5353), copied onto
  its `conf` directory before each start, as the old path's `seed-config`
  init container copies it; its `work` directory held in memory at 128Mi; and
  headlamp's env file (`env/headlamp/base.env`, the flags the old chart
  passed, as `HEADLAMP_CONFIG_*`).
- **`platform.intent.yml`**:
  - `l4Addresses.lan-dns`, a pool of one address, 192.168.0.98, announced by
    the `l4-speaker` Node Agent the edge's `lan-edge` pool already declares.
  - `apiAccess.holders` gains `utility/headlamp`.
  - `humanGrants`: the `oidc:k8s-admin` grant to `cluster-admin`, which the old
    path holds as `headlamp-oidc-admin` beside headlamp.
  - `seeder`: busybox, 16Mi and 10m, the image every seeded Asset is copied
    with.
  - The ledger moves `utility` from `legacy` to `estate`.
- **`images.lock.yml`**: adguard and headlamp, by the digests the live pods
  run, and the seeder's busybox 1.37.0, pinned as deploy-kit's worked example
  pins it.
- **`participants.yml`** and **`release.yml`**: utility publishes with the
  Platform document, on this repository's releases.

`substrate.upstreamNameservers` was already here (JorisJonkers-dev/deploy-kit#634).

### Before it merges

- JorisJonkers-dev/deploy-kit#380: the estate path runs 1.0.
- **This repository's releases publish with deploy-kit 1.2.0.** The fragments
  carry `seedAt` and `seeder`, which 1.1.0 added, so the Publish Fragment
  release `release.yml` calls has to run 1.1.0 or later.
- **fleet-infra, before the third change:**
  - MetalLB has an `IPAddressPool` named `lan-dns`, holding 192.168.0.98/32
    with `autoAssign: false`, and an `L2Advertisement` for it; `enschede-lan`
    no longer holds .98. MetalLB refuses two pools that overlap, and the old
    `adguard-ha-a` Service loses .98 when it leaves `enschede-lan`, so this
    lands in the cut-over window, while .97 still answers.
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
