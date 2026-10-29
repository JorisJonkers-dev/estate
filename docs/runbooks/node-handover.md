# Handing `node` over to the estate path

Moves the Project `node` from fleet-infra's old path to its pin here, on
deploy-kit 1.2.0, in the three changes of deploy-kit
`spec/v1/60-setup.md#handing-over-one-project-at-a-time`. `node` is MetalLB's
speaker and controller, the NVIDIA device plugin, dcgm-exporter and
node-exporter. Tracking: JorisJonkers-dev/deploy-kit#659, the first of the
foundation's handovers.

`node` declares nothing. Every object it holds is derived from
`platform.intent.yml`'s `nodeAgents`, the node contract and the pool-kind L4
Addresses. All of it lands in a new namespace, `node-system`, as one Reconcile
Unit, `apps-node`. So unlike an Application's handover, nothing is adopted in
place: every agent is a new DaemonSet, and each old one is deleted by hand, in
the window, in an order that keeps each gap to seconds.

Run it with the maintainer present. A live step is the maintainer's go-ahead,
never an agent's.

## What it waits on

| | what | where |
|---|---|---|
| W1 | `delivery`, `_canary` and `_estate` on 1.0 | JorisJonkers-dev/deploy-kit#380, closed |
| W2 | the handover runbook | JorisJonkers-dev/deploy-kit#381 |
| W3 | utility's window is done: `adguard-lan-dns` holds .98 from the pool `lan-dns`, the router names .98 alone, and `utility-system/adguard-ha-b` (.97) is deleted. JorisJonkers-dev/estate#248 is merged and this branch is updated from `main`, so the render holds `lan-dns` too: without it the new controller clears .98, and the LAN loses DNS | JorisJonkers-dev/deploy-kit#657 |
| W4 | **the rendered `l4-speaker` and `l4-controller` start.** On MetalLB 0.15.3 they do not: the speaker lacks `METALLB_POD_NAME` and exits, and both lack reads that 0.15.3 always watches. Reproduced on a local k3s. Then a deploy-kit release, and `toolkit.yml` moved to it | JorisJonkers-dev/deploy-kit#729 |
| W5 | **the rendered `gpu-device` names GPUs the way the hosts' CDI specification does** (`index`), or nix-config switches the specification to `uuid`. Until then, a GPU pod that starts after the handover is refused its card, `gpu-metrics` first | JorisJonkers-dev/deploy-kit#730 |
| W6 | decided: memberlist for the speaker, or the slower failover on a lost node accepted | JorisJonkers-dev/deploy-kit#733 |

Bridged rather than waited on:

- **Scraping.** The render scrapes neither metrics agent (JorisJonkers-dev/deploy-kit#731). F2 adds two PodMonitors on the old path's Prometheus, under the old job names.
- **The textfile collector.** node-exporter's textfile collector is gone until #731 lands, and with it the three NVIDIA CDI alerts.
- **The `nvidia-cdi` RuntimeClass.** It stays applied by fleet-infra's `apps-core` (JorisJonkers-dev/deploy-kit#732).

## The changes, in order

| # | where | when | what | outage |
|---|---|---|---|---|
| F0 | fleet-infra, "keep traefik-lan's address by the address alone" | any time before the window | traefik-lan's Service stops naming the pool `enschede-lan` and asks for its address alone. Otherwise the estate path's controller clears it: the render's pool is named `lan-edge` | none |
| F1 | fleet-infra, "orphan the node Project" | before the window, after utility's | every object fleet-infra applies for the agents and both pools is marked `prune: disabled`; the three HelmReleases are suspended; `apps-metallb-config` and `apps-metallb-lan-dns` are set to `prune: false`; node-exporter's four kube-prometheus-stack objects get `helm.sh/resource-policy: keep` | none |
| F2 | fleet-infra, "drop the node Project's manifests" | window, step 2 | the manifests and both pool Kustomizations go; kube-prometheus-stack turns node-exporter off; the RuntimeClass moves under the same name; two PodMonitors scrape `node-system` | none: every object stays |
| B | this repository, this change, then its release | window, step 6 | `metallb.io/v1beta1` joins `bootstrap.crds`, and `cluster.sh` adopts MetalLB's CRDs; `nodeAgents` memory sized to live use; `node` moves to `estate` | the swap below |

## The render against the old path

Rendered with deploy-kit 1.2.0 from this branch. The run was `deploy-kit compose` over every participant's newest fragment, this branch's Platform and estate fragments, `participants.yml` and `cluster-state.yml`. It was compared with the live objects, read 2026-10-29 with `kubectl --context personal`. `kubectl kustomize` of fleet-infra's paths holds only Namespaces, HelmRepositories, HelmReleases, the RuntimeClass and the pools, so each agent is compared against what its chart installed. Every image matches the live pods' imageID by digest, so no node pulls anything.

| object | difference | why |
|---|---|---|
| Namespace `node-system` | new; it carries `managed-by: deploy-kit`. The agents leave `metallb-system`, `nvidia-device-plugin` and `observability` | the `node` Project's namespace. Every DaemonSet is a new object, so the selector change needs no recreate. The old ones are deleted by hand (Cutover) |
| DaemonSet `l4-speaker` (was `metallb-speaker`) | **does not start** on 0.15.3: no `METALLB_POD_NAME`, and no read on `configurationstates`, `secrets`, `configmaps` or `servicebgpstatuses` | W4, JorisJonkers-dev/deploy-kit#729 |
| | no memberlist (no bind address, labels or key) | W6, #733: failover on a lost node waits for the API server, not 6.6s |
| | runs on the five Enschede nodes by hostname, not all six | the nodes of the pools' site. `frankfurt-contabo-1` announces nothing: its Service `ingress-system/traefik` names a pool, `frankfurt-unused`, that exists on neither path |
| | native L2 mode: no `frr`, `reloader` or `frr-metrics` containers, no `metallb-frr-startup` | the estate announces no BGP |
| | no `metallb-excludel2` ConfigMap, so the speaker answers ARP on every interface, `cni0` and `flannel.1` included | not rendered. The pool addresses are only asked for on the LAN segment |
| | 128Mi request and limit, 20m CPU (live: none); `system-node-critical`; seccomp `RuntimeDefault`; no control-plane tolerations; `revisionHistoryLimit` back to the default | the catalog. The speaker peaks at 73Mi |
| Deployment `l4-controller` (was `metallb-controller`) | **does not start**, as above (also no `nodes` read) | #729 |
| | `--webhook-mode=disabled`: no ValidatingWebhookConfiguration, webhook Service or certificate Secret; no memberlist Secret | no webhook is rendered (chapter 14) |
| | `Recreate`; placed on an Enschede node (live: `frankfurt-contabo-1`); 128Mi request and limit (live: 61Mi in use, no limit); `system-cluster-critical`; runs as 65534 | the catalog |
| IPAddressPools | `lan-edge` (.99/32) and `lan-dns` (.98/32), each `autoAssign: false`, in `node-system`. Live: `enschede-lan` (.97/32 and .99/32, auto-assigning) and `lan-dns` in `metallb-system` | one pool per L4 Address. .97 retired with utility (W3). The new controller reads `node-system` alone, so the old pools stay invisible to it until they are deleted |
| L2Advertisements | per pool, nodes by hostname. Live: `enschede-lan` on every node; `lan-dns` by the site label | the same five nodes |
| Service `ingress-lan-system/traefik-lan` | F0: names no pool, keeps its address request | an address request is served from an `autoAssign: false` pool, checked on a local k3s. A Service naming `enschede-lan` stays `<pending>` under the new controller |
| DaemonSet `gpu-device` (was `nvidia-device-plugin`) | **its config sets no `deviceIDStrategy`**, so it hands out `uuid` ids, which the hosts' CDI specification does not name | W5, #730 |
| | one container and a static ConfigMap (time-slicing, 4 replicas). There is no `config-manager` sidecar and no MPS mounts. The `mps-control-daemon` DaemonSet goes; it runs on 0 nodes | the catalog |
| | `hostPID`; seccomp `RuntimeDefault`; 64Mi (22Mi in use); no ServiceAccount API access (the sidecar read node labels); no `nvidia.com/gpu` toleration (no node carries the taint) | the catalog |
| DaemonSet `gpu-metrics` (was `dcgm-exporter`) | 1Gi request and limit, 50m CPU (live: 256Mi requested, 1Gi limit, 200m CPU limit) | request equals limit. It holds 407-415Mi and was OOM-killed at 256Mi |
| | the image's own `default-counters.csv`, not the chart's ConfigMap: two more counters, `DCGM_FI_DEV_FB_RESERVED` and `DCGM_FI_DRIVER_VERSION` | not rendered |
| | no `NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES`, `NODE_NAME` or web timeouts | the share it is granted names its node's one card |
| | no Service and no ServiceMonitor | #731. F2's PodMonitor `gpu-metrics` keeps `job="dcgm-exporter"` |
| DaemonSet `node-metrics` (was `metrics-stack-prometheus-node-exporter`) | no `--collector.textfile.directory`, so `NvidiaCdiSpecMissing`, `NvidiaCdiStateStale` and the module-mismatch alert go silent | #731 |
| | no `--path.udev.data`; no probes; no tolerations (live: every `NoSchedule`; a DaemonSet still tolerates `unschedulable`, so the cordoned `enschede-pi-1` keeps its copy) | the catalog |
| | runs as the image's 65532 (live: 65534); every capability dropped; seccomp; 64Mi (11Mi in use) | the catalog |
| | no Service and no ServiceMonitor | #731. F2's PodMonitor `node-metrics` keeps `job="node-exporter"`, which the chart's rules name 72 times |
| CRDs `*.metallb.io` | adopted by `bootstrap/cluster.sh` (field manager `estate-bootstrap`); `bgppeers` loses its conversion webhook | the bootstrap set (chapter 14). The estate holds no BGPPeer |
| RuntimeClass `nvidia-cdi` | not rendered: stays in fleet-infra's `apps-core`, moved to `core/runtime-classes/` | #732 |
| not rendered | HelmReleases, HelmRepositories and Helm Secrets; VWC `metallb-webhook-configuration`; Secrets `metallb-memberlist` and `metallb-webhook-cert`; ClusterRoles `metallb:*` and `nvidia-device-plugin-role`; dcgm's Role and ConfigMap | deleted by hand after the flip |
| other units | none gains `dependsOn: apps-node`; `apps-node` follows nothing | chapter 14: an agent needs only its node |

## Pre-checks

Each must print what it says. Nothing here writes.

```sh
# 1. F1 reached the live objects.
kubectl get ns metallb-system nvidia-device-plugin -o custom-columns='NAME:.metadata.name,PRUNE:.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune'
kubectl get helmrelease,helmrepository -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend,PRUNE:.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune' \
  | grep -E 'metallb|nvidia|dcgm'
kubectl -n metallb-system get ipaddresspool,l2advertisement -o custom-columns='KIND:.kind,NAME:.metadata.name,PRUNE:.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune'
kubectl -n flux-system get kustomization apps-metallb-config apps-metallb-lan-dns -o custom-columns='NAME:.metadata.name,PRUNE:.spec.prune'
kubectl -n observability get ds,svc,sa,servicemonitor metrics-stack-prometheus-node-exporter \
  -o custom-columns='KIND:.kind,POLICY:.metadata.annotations.helm\.sh/resource-policy'
#    every PRUNE is disabled, every SUSPEND true, both Kustomizations false, every POLICY keep.

# 2. F0 is live, and every LoadBalancer Service the new pools must serve names
#    lan-dns or nothing.
kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer")
  | "\(.metadata.namespace)/\(.metadata.name) \(.status.loadBalancer.ingress[0].ip // "-") pool=\(.metadata.annotations["metallb.io/address-pool"] // "none")"'
#    traefik-lan pool=none, adguard-lan-dns pool=lan-dns, no adguard-ha-a or -b.

# 3. The render has both pools and a speaker that starts (W3, W4).
yq '.metadata.name' <rendered>/apps/node/l4-speaker/pools.yaml          # lan-edge, lan-dns (each twice)
yq '.spec.template.spec.containers[0].env[].name' <rendered>/apps/node/l4-speaker/workload.yaml  # METALLB_POD_NAME among them
```

## Cutover

The order is set by who announces .98 and .99. The old speakers keep announcing on their last configuration with no controller running. The new speakers cannot start on a node until the old one there has released host port 7472, and node-metrics waits the same way on 9100. So each gap lasts only from deleting an old DaemonSet to its successor's start, and the image is already on every node.

Set the watchers first, from a LAN machine:

```sh
kubectl get pods -n node-system -o wide -w
while sleep 2; do printf '%s ' "$(date +%T)"; dig +short +time=1 +tries=1 @192.168.0.98 example.com >/dev/null && printf 'dns:up ' || printf 'dns:DOWN '; curl -sk -o /dev/null -m 2 -w 'lan:%{http_code}\n' https://192.168.0.99/; done
```

1. **Pre-checks**, above.
2. **Merge F2**, wait for fleet-infra's publish to `deploy/production`, then reconcile:

   ```sh
   flux reconcile kustomization flux-system -n flux-system --with-source
   flux reconcile kustomization apps-core -n flux-system
   flux reconcile kustomization apps-observability -n flux-system
   ```

   `apps-metallb-config` and `apps-metallb-lan-dns` are gone; every speaker, the controller, both pools, the device plugin, dcgm-exporter and node-exporter still run; `metrics-stack` is at a new revision without node-exporter, whose four objects stay.
3. **Stop the old controller and its webhook.** The webhook fails closed, and would refuse the render's pools with no controller behind it:

   ```sh
   kubectl -n metallb-system delete deploy metallb-controller
   kubectl delete validatingwebhookconfiguration metallb-webhook-configuration
   ```

   Addresses stay announced; no Service changes.
4. **The bootstrap set:** run `bootstrap/cluster.sh` from this branch, and keep both Secrets when it asks. Its stage 5 drops `bgppeers`' conversion webhook, adopts the nine CRDs and reads back that none is converted by a webhook.
5. **Stop the old device plugin,** so two plugins never share `nvidia-gpu.sock` on one node. Running GPU pods keep their cards. A GPU pod that starts before step 7 waits:

   ```sh
   kubectl -n nvidia-device-plugin delete ds nvidia-device-plugin nvidia-device-plugin-mps-control-daemon
   ```

6. **Merge B**, then the release PR release-please opens for it. Composition publishes `node`'s first artifact and writes `projects/node/source.yaml`:

   ```sh
   flux reconcile kustomization estate-pins -n flux-system --with-source
   ```

   `apps-node` applies. `l4-controller` starts and leaves both addresses where they are, and `gpu-device`, `gpu-metrics` start. `l4-speaker` and `node-metrics` wait `Pending` on every node, for the host ports.
7. **Hand the addresses over:** `kubectl -n metallb-system delete ds metallb-speaker`. Every new speaker starts within seconds. The watcher may miss a probe or two. A client's ARP cache usually bridges the gap.
8. **Hand the host metrics over:** `kubectl -n observability delete ds metrics-stack-prometheus-node-exporter`.
9. **Once `gpu-metrics` is Ready on both nodes:** `kubectl -n observability delete ds dcgm-exporter`.
10. `flux get kustomization apps-node -n flux-system` reports Ready.

## Proof

Read each value; a Ready condition alone proves nothing.

1. `apps-node` is Ready, and every pod in `node-system` is Running with no restarts.
2. **Each GPU node advertises its card:**
   `kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'` shows `4` on `enschede-gtx-960m-1` and `enschede-t1000-1`. `gpu-metrics` itself started under `nvidia-cdi` with a share, so the CDI naming holds (W5).
3. **Every node's metrics are scraped:** in Prometheus, `count(up{job="node-exporter"} == 1)` is 6, and `count(up{job="dcgm-exporter"} == 1)` is 2. The node dashboards show data after step 8.
4. **The addresses answer** from the LAN: DNS on .98, and the LAN routes through .99. `kubectl get svc -A` shows .99 on `traefik-lan` and .98 on `adguard-lan-dns`, each `ip-allocated-from-pool` naming the new pool.
5. jellyfin still transcodes. Its running pod kept its card; a restart now proves the new plugin.

## Left to delete by hand

After the proof, the suspended releases first (helm-controller skips the uninstall), then the rest:

```sh
kubectl -n metallb-system delete helmrelease metallb && kubectl -n metallb-system delete helmrepository metallb
kubectl -n nvidia-device-plugin delete helmrelease nvidia-device-plugin && kubectl -n nvidia-device-plugin delete helmrepository nvidia
kubectl -n observability delete helmrelease dcgm-exporter && kubectl -n observability delete helmrepository nvidia-dcgm
kubectl delete ns metallb-system nvidia-device-plugin       # the old pools, Secrets, ConfigMaps and ServiceAccounts with them
kubectl -n observability delete svc,servicemonitor dcgm-exporter metrics-stack-prometheus-node-exporter
kubectl -n observability delete sa dcgm-exporter metrics-stack-prometheus-node-exporter
kubectl -n observability delete role dcgm-exporter-read-cm; kubectl -n observability delete rolebinding dcgm-exporter
kubectl -n observability delete cm exporter-metrics-config-map
kubectl -n observability delete secret -l owner=helm,name=dcgm-exporter
kubectl delete clusterrole,clusterrolebinding metallb:controller metallb:speaker
kubectl delete clusterrole nvidia-device-plugin-role; kubectl delete clusterrolebinding nvidia-device-plugin-role-binding
```

The CRDs stay: they are the bootstrap set's now. Their Helm labels and annotations are harmless and can be removed at leisure. fleet-infra's drift check holds no entry for any agent, so no change C follows. The RuntimeClass and the two PodMonitors leave fleet-infra with #732 and #731.

## Rollback

The generic runbook's steps (deploy-kit `docs/runbooks/handover.md#rollback`), with one order that matters: the old speakers and node-exporter need their host ports back.

1. Mark `projects/node/source.yaml`'s Kustomization `prune: false`, move `node` back to `legacy`, and delete `projects/node/`.
2. Delete `node-system`'s `l4-speaker` and `node-metrics` DaemonSets, the `l4-controller` Deployment, and `gpu-device`.
3. Revert F2, then F1. The HelmReleases resume, and helm-controller's upgrade recreates every object deleted above: the speakers, the controller and its webhook, the device plugin, dcgm-exporter and node-exporter. The chart also puts `bgppeers`' conversion stanza back.
4. Delete `node-system` once the old agents are Ready. F0 may stay: the address request serves under either controller.
