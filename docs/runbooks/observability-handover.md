# Handing `observability` over to the estate path

Moves the Project `observability` from fleet-infra's old path to its pin here,
in the three changes of deploy-kit
`spec/v1/60-setup.md#handing-over-one-project-at-a-time`. The Project holds
the telemetry collector, the log collector (Alloy), Prometheus and its
operator, kube-state-metrics, Alertmanager, Grafana and its operator, Loki,
Tempo, Pyroscope and Gatus. Tracking: JorisJonkers-dev/deploy-kit#660.

Unlike mail, this Project is **not adopted in place**. The old path runs it in
`observability`; the render puts it in `observability-system`. So the estate
path starts a second, empty stack beside the old one, and the old one keeps
running, applied by nothing, until it is deleted by hand. The stores start
fresh, decided 2026-10-27 on deploy-kit#660. No Move is derived, because no
store's data is carried. A live step is the maintainer's go-ahead, never an
agent's.

**No bridge** (decided 2026-10-30): the estate's own Prometheus, Alertmanager
and Grafana take over at the flip, and the old stack stops alerting in the same
step. That needs the deploy-kit release after 1.5.0, which renders them as the
operators' objects (JorisJonkers-dev/deploy-kit#722, #723) and scrapes k3s
(#724). Compose with it before the window (W0).

## What it waits on

| | what | where |
|---|---|---|
| W0 | `toolkit.yml` on the deploy-kit release that holds #722, #723 and #724 (the one after 1.5.0) | the main session's toolkit bump; this change is composed and checked against it |
| W1 | `node` handed over first, its node-exporter out of `metrics-stack` | done: estate#261, released in 0.35.0. node-exporter was a DaemonSet of the kube-prometheus-stack release, so suspending `metrics-stack` (O2) would also have orphaned node's agent. Pre-check 7 reads it back |
| W2 | the bootstrap set's CRDs | #259 (`cluster.sh` and `bootstrap.crds`), merged and run before O2 |

Not needed for the window, and left open with a comment each: the worked
example's Gatus (JorisJonkers-dev/deploy-kit#725; this file works around all
three points) and a blue-green Process's Services carrying one port (#728;
the collector and Alloy are `interrupted` here, which also keeps Flagger out
of their first rollout).

## The changes, in order

| # | where | what | when | outage |
|---|---|---|---|---|
| A | estate, #259 | `cluster.sh` applies the monitoring stack's CRDs; `bootstrap.crds` lists `monitoring.coreos.com/v1alpha1` and `grafana.integreatly.org/v1beta1` | before the window | none |
| O1 | JorisJonkers-dev/fleet-infra#563 | prune marks on the namespace `observability`, `gatus-data`, `observability-backups` and the three routes; the loki chart keeps its claim, the grafana chart tells Helm to keep its | before the window | none |
| P | a person | PersistentVolumes to `Retain` (below) | before the window | none |
| O2 | JorisJonkers-dev/fleet-infra#564 | every object of `apps-observability`, `apps-observability-rules` and `apps-grafana-dashboards` marked; the seven HelmReleases suspended; the three Kustomizations `prune: false` | window step 1 | none |
| O3 | JorisJonkers-dev/fleet-infra#566 | the manifests and the three Kustomizations go; the namespace, the backup CronJobs and dcgm-exporter stay under `apps-observability-namespace`; the grafana, gatus and faro routes move unchanged to `apps-edge` | window step 2 | none |
| B | estate, #260, then its release | the ledger moves `observability` to `estate` and drops its `serving` statement; the Platform document gains `bootstrap.k3s.metrics`, `bootstrap.flux.metrics`, `telemetry.dashboards`, `monitoring` with its `stores`, and the six API holders | window step 3 | auth-api rolls once; the old stack stops alerting as the new one starts |
| O4 | JorisJonkers-dev/fleet-infra#568 | the routes serve `observability-system`; both Traefiks trace to the new collector; the old Grafana's and Alertmanager's VaultStaticSecrets go | after the flip, once the units are Ready | both Traefiks restart |

O3's `apps-observability` must be gone, not only emptied, before B: the
estate's unit is also `flux-system/apps-observability`.

## The data, claim by claim

Every old claim is on `frankfurt-contabo-1`, `local-path`, reclaim `Delete`
(read 2026-10-29). None is carried. Each is kept, read-only, until its
retention would have run out, then deleted on the maintainer's go-ahead.

| old claim | holds | across the cut | old claim deleted |
|---|---|---|---|
| `prometheus-metrics-stack-prometheus-db-…-0` (20Gi) | 15 days of metrics | **lost.** The new TSDB starts empty. The old claim stays, unread, once cutover step 2 deletes the old Prometheus | 15 days after the old Prometheus stops |
| `storage-loki-0` (20Gi) | every log since Loki started: no retention is configured, only a 7-day ingest window | **lost.** New logs only | maintainer's call: no retention would ever run out |
| `storage-tempo-0` (20Gi) | 7 days of traces (`block_retention: 168h`) | **lost** | 7 days after the cut |
| `data-pyroscope-0` (20Gi) | profiles, Pyroscope itself only (nothing else pushes or is pulled) | **lost**, nothing of value | at the cut |
| `grafana` (10Gi) | Grafana's database: users, preferences, annotations, anything made in the UI | **lost.** Users return at sign-in, dashboards are re-imported. Export anything made in the UI first (pre-check 5) | after the export |
| `alertmanager-metrics-stack-alertmanager-db-…-0` (5Gi) | silences and the notification log | **lost.** Re-create any active silence (pre-check 6) | at the cut |
| `gatus-data` (2Gi) | 191 days of uptime history | **lost** | maintainer's call |
| `observability-backups` (50Gi) | the Vault raft snapshots and the Postgres and RabbitMQ dumps | **not observability's: untouched.** Stays in `observability` with its CronJobs, under `apps-observability-namespace` | never, here |

Before the window, set every one of these volumes to `Retain`, so no deleted
claim takes its data with it. The PVs are not Flux's, so the setting survives:

```sh
for pv in pvc-53e44001-228d-45cd-9b86-aecd50d96156 pvc-32ce73f8-07d1-4318-8a5c-8a6fe5d749ad \
          pvc-69f7b727-32d2-4f20-b9bd-81be9d920c45 pvc-41bac145-e6fc-4599-a12d-3051f6a18764 \
          pvc-d341f5b7-61e7-4513-a3bd-32b6f2309642 pvc-e974544d-ba98-4ff8-9d18-2f2e12a41faf \
          pvc-37ea66a1-41da-45b9-8012-62183f5140b5 pvc-0306b7ad-9a17-4cd5-bcfe-1efc7a671fbb; do
  kubectl --context personal patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
done
kubectl --context personal get pv -o json | jq -r '.items[] | select(.spec.claimRef.namespace=="observability") | "\(.spec.claimRef.name) \(.spec.persistentVolumeReclaimPolicy)"'
#   every line ends Retain
```

## The render against the old path

Rendered from this change on deploy-kit main after #722, #723 and #724 (the
release after 1.5.0), composed 2026-10-30. `deploy-kit compose` ran over
every other participant's newest fragment, this branch's Platform and
platform fragments, `participants.yml` and `cluster-state.yml`. The old side is
`kubectl kustomize` of fleet-infra `cluster/flux/apps/observability`,
`observability-rules` and `grafana-dashboards` at 72a449c, with what the seven
HelmReleases render live, read 2026-10-29. Images: each lock entry is the
digest the live pod runs.

### The metrics stack (`metrics-stack`, kube-prometheus-stack 90.0.0)

| live | render | why |
|---|---|---|
| `Prometheus` and `Alertmanager` objects; the operator runs each as a StatefulSet with a config-reloader | the same two kinds, `observability-system/prometheus` and `/alertmanager`, carrying each Process's pod; the operator runs `prometheus-prometheus` and `alertmanager-alertmanager` | deploy-kit#722 |
| Prometheus selects every ServiceMonitor, and PodMonitors and PrometheusRules labelled `release: metrics-stack`; Alertmanager reads every AlertmanagerConfig with matcher strategy `None` | every ServiceMonitor and PodMonitor of every namespace (the estate names no `monitors.labels`), every `ScrapeConfig` and `PrometheusRule` the render writes and no other; Alertmanager reads `estate-alerts` with matcher strategy `None` | deploy-kit#722. The old stack's own monitors in `observability` would be selected too: cutover step 2 deletes them |
| TSDB claim 20Gi, `retention: 15d`, remote-write receiver, exemplar storage | `prometheus-data` 20Gi mounted at the operator's `/prometheus`; `retention: 15d`, `enableRemoteWriteReceiver`, `enableFeatures: [exemplar-storage]` | the arguments become the object's fields |
| Alertmanager claim 5Gi | `alertmanager-data` 5Gi | declared |
| Alertmanager's own route: group by alert and namespace, `Watchdog` and `InfoInhibitor` to `null`, a critical inhibits the same warning | `estate-alerts`: the same grouping and severity routes; no inhibition | the model renders one routing and no inhibition: **a firing critical and its warning both reach Discord** |
| 149 default alert rules and 85 recording rules (`defaultRules.create`) | `prometheus-kube-prometheus`, the same groups vendored from live | the chart is not rendered; its rules are carried as a rules file |
| `platform-alerts`, 49 rules, `release: metrics-stack` | `prometheus-platform`, the same 49 rules, VaultSealed as fleet-infra#545 wrote it | carried; selected as the render's own |
| ServiceMonitors for the kubelet (with cAdvisor and probes), the API server, CoreDNS and etcd | `k3s-monitors.yaml`: three `ScrapeConfig`s of every node's kubelet (job `kubelet`, the chart's cAdvisor drops), a `ServiceMonitor` of `default/kubernetes` (job `apiserver`), a `PodMonitor` of CoreDNS (job `coredns`); token Secret `prometheus-token` and one ClusterRole of nodes, `nodes/metrics` and `/metrics`. No etcd | deploy-kit#724, `bootstrap.k3s.metrics`. This k3s runs on sqlite: the chart's etcd monitor selected nothing |
| node-exporter DaemonSet | not here | the node Project's `node-metrics` agent (W4) |
| operator admission webhooks (failure policy `Ignore`) and their certgen hook Jobs | none | no webhook is rendered (chapter 14); left behind, deleted by hand |
| kube-state-metrics: every default collector, and Flux's Ready conditions (`gotk_resource_ready`) | 15 collectors, the ones its rules read; the same CustomResourceState as an Asset; list and watch on Flux's five kinds | an `api` holder lists what it reads. FluxResourceNotReady and FluxSourceFailing keep their metric |
| `revisionHistoryLimit: 3` by postRenderer | the default | fleet-infra's patch |
| every pod `nodeSelector` site `frankfurt` (the operator, Prometheus, Alertmanager) | Prometheus and Alertmanager on `frankfurt-contabo-1`; the operator and kube-state-metrics on `enschede` | capacity, see [Capacity](#capacity): Frankfurt cannot hold the whole stack's requests |
| the operator's config-reloader image, `quay.io/prometheus-operator/prometheus-config-reloader:v0.93.1` by tag | the same, by the operator's own default | not in the images lock: the operator names it, not a Process |

### Grafana and its operator

| live | render | why |
|---|---|---|
| `Grafana` object `observability/grafana` (external, chart admin login) | `observability-system/grafana`, external, labelled `dashboards: grafana`, at `http://grafana.observability-system:3000`; admin `user` and `password` generated by the policy job at `secret/data/observability-system/grafana-admin`, read by Grafana (`GF_SECURITY_ADMIN_*`) and the operator alike | deploy-kit#723 |
| 31 GrafanaDashboards in 14 thematic folders; 9 fetched from grafana.com at run time | 31 in one folder, `observability`; the 9 vendored at the revision live pins | a Project's dashboards go to a folder named for it; nothing is fetched. Each moves to its owning Project's file at that Project's handover (the file says which) |
| data sources by the chart's sidecar, from a labelled ConfigMap | derived from Grafana's five edges and `monitoring.stores`: Prometheus (default), Loki, Tempo, Pyroscope, Alertmanager, with the same uids and links (exemplars and `trace_id` to Tempo, traces to logs, metrics, service map and profiles) | deploy-kit#723. **Lost:** Tempo's three Spring `tracesToMetrics` queries and its custom logs query (Grafana's defaults apply), and Loki's `span_id` field. Re-add in Grafana if missed |
| Grafana 12.3.1, sign-in against auth-api, secret from `secret/platform/observability#grafana.oauth_client_secret` through `grafana-oidc-client` | the same image, env and key; Secret `grafana-platform-observability`; Vault role `observability-system-grafana` | the estate runs no identity provider yet (no `signIn`, no Client CRD), so the worked example's native Client waits for it |
| plugins installed by the chart | `GF_PLUGINS_PREINSTALL`, `egress: internet` | the same four plugins |
| claim `grafana` 10Gi; requests none | `grafana-data` 10Gi; 512Mi | fresh, see the data |
| route `grafana.jorisjonkers.dev`, no forward-auth | exposure `public`, `anonymous`, rendered at the edge's handover | as live: Grafana signs people in itself. The route moves to `apps-edge` (O3) and to the new Service (O4) |
| grafana-operator chart, 96Mi, on Frankfurt | Process, 128Mi, on `enschede` | capacity |

### The stores

| live | render | why |
|---|---|---|
| the three stores on Frankfurt | on `enschede`, fresh claims there | capacity, see [Capacity](#capacity) |
| Loki chart: single binary, gateway (nginx), memberlist Services, rules sidecar, `loki-canary` on every node | one Process with the live configuration less memberlist and runtime config; no gateway, no rules sidecar, no canary | one replica needs no ring. No Loki rule exists. **loki-canary is not rendered**: logs are read through the API, so a canary per node tests nothing per node (chapter 14) |
| Loki's StatefulSet deletes its claim with it | `loki-data`, never deleted by a Deployment | O1 also keeps the old claim |
| Tempo chart, `-mem-ballast-size-mbs=1024`, usage report on | Process with the live configuration; remote-write to the new Prometheus; no ballast; usage report off | Tempo 2 ignores the ballast. Tempo's egress admits no internet |
| Pyroscope chart: v2 storage with a raft metastore, its own pull-mode Alloy (`pyroscope-alloy`) | Process, single binary, default storage on `pyroscope-data` | the pull-mode agent profiled only Pyroscope itself; nothing pushes profiles today |

### Collectors and Gatus

| live | render | why |
|---|---|---|
| the collectors float, mostly on the Pis | `otel-collector` and `alloy` on `enschede` | the Pis are cordoned; capacity |
| Alloy DaemonSet, six copies: tails pod logs, OTLP receiver (4317, 4318), Faro receiver (12347) | Alloy, one copy: pod logs and Faro. A new `otel-collector` runs the OTLP pipeline, its processors copied statement for statement | chapter 14: the log collector holds no host privilege and runs one copy. Six copies each tailed every pod; Loki dropped the duplicates |
| OTLP consumers reach `alloy.observability:4317` (auth-api, through the ledger's `serving`) and `:4318` (both Traefiks) | auth-api is handed `otel-collector.observability-system:4317` at the flip; Traefik in O4 | the `serving` statement leaves the ledger. **auth's pin moves at B**: auth-api rolls once through its Canary |
| logs sent over OTLP reach Loki through Alloy's Loki exporter | the collector sends them to Loki's native OTLP endpoint | labels derive from resource attributes |
| Gatus with 43 hand-written endpoints (public hosts and in-cluster Services: postgres, rabbitmq, valkey, vault, garage, stalwart, the observability stores) | Gatus and its checks sidecar gather each Project's external checks: 23 checks from 16 Projects' ConfigMaps today | deploy-kit#725's fix: the sidecar is kiwigrid's k8s-sidecar, sharing `gatus-data`. **In-cluster checks are gone**: a datastore or Vault going down is seen only by its own alerts |
| `gatus-data` 2Gi; `status.jorisjonkers.dev` | `gatus-data` 2Gi; exposure `status` | fresh |
| `otel-collector` and `alloy` would be `continuous` in the worked example | `interrupted` | deploy-kit#728: Flagger's Service would carry only `otlp`, or only `http` and not `faro` |

### Everything else

| live | render | why |
|---|---|---|
| PodMonitor `flux-system/flux-controllers` on port `http-prom`, `job` = `flux-system/flux-controllers` | PodMonitor `observability-system/flux-controllers` on 8080, `job` = each controller's name | `bootstrap.flux.metrics`. No live alert filters on that job; the two Flux dashboards do not either |
| VaultStaticSecrets `alertmanager-discord`, `grafana-oidc-client` (as `vso-system/default`, templated keys) | `alertmanager-platform-observability`, `grafana-platform-observability`, each with its own VaultAuth; whole document, `hmacSecretData`, 10m refresh | one per grant; the policy job writes roles `observability-system-alertmanager` and `-grafana` |
| | new: `VaultConnection`, the `vault-policy` CronJob and Job, `rollouts-observability` Alert and Provider, Canary for kube-state-metrics, the external-checks ConfigMaps of grafana, gatus and alloy, Stable Addresses in `_estate` for every surface | the estate path's own objects |
| | NetworkPolicies: default-deny and one per Process | rendered, not applied (`networkPolicyController: embedded`) |
| routes `grafana`, `gatus`, `faro` in `edge-system`, in `apps-observability` | not rendered | no Project carries routes while edge is `legacy`; O3 and O4 |
| HelmRepositories `grafana`, `grafana-operator`, `prometheus-community` | none | left behind, deleted by hand |
| backup CronJobs, `observability-backups`, dcgm-exporter | not here | not observability's: they stay in fleet-infra (O3) |

## Capacity

The Pis are cordoned (failing USB storage), so every Deployment and StatefulSet
lands on `enschede-gtx-960m-1`, `enschede-t1000-1` or `frankfurt-contabo-1`.
Free requests, read 2026-10-30 (allocatable less requested):

| node | memory free | cpu free |
|---|---|---|
| `frankfurt-contabo-1` | 5.2Gi | 1620m |
| `enschede-gtx-960m-1` | 3.3Gi | 3570m |
| `enschede-t1000-1` | 8.4Gi | 440m |

The old stack requests almost nothing (about 1Gi on Frankfurt), and it keeps
running until cleanup, so it frees nothing at the flip. The whole new stack
requests about 8.1Gi and 900m. Pinned as the old one was, Frankfurt would need
6.7Gi, so it would not fit. This file therefore splits it:

- **Frankfurt** (stateful, and Gatus for its outside vantage): Prometheus 3Gi,
  Alertmanager 128Mi, Grafana 512Mi, Gatus 192Mi, plus the operator's two
  config-reloaders. That is about 4.0Gi and 350m, leaving about 1.2Gi.
- **Enschede**: Loki, Tempo and Pyroscope (2.5Gi, 300m, on fresh claims), and
  the operators, kube-state-metrics, the collector and Alloy (1.7Gi, 240m).
  Their 540m of CPU does not all fit on `enschede-t1000-1`, which has 440m
  free; the scheduler puts the rest on `enschede-gtx-960m-1`.

The stateless ones are pinned to Enschede for capacity, not locality, so the
floating pods cannot take Frankfurt's margin before Prometheus schedules. Drop
those pins once Frankfurt has room.

## Alerts across the cut

- **O1 to O3:** nothing changes. The old stack alerts as today.
- **At B:** the estate's Prometheus starts empty and evaluates the same rules
  (`prometheus-platform`, `prometheus-kube-prometheus`) through `estate-alerts`
  to the same Discord webhook. Cutover step 2 stops the old operators and
  deletes the old `Prometheus` and `Alertmanager`, so only one stack alerts.
  The gap is the new Prometheus's first scrape and rule evaluation: about a
  minute after it is Ready.
- **Rules that need history:** a `for:` clause waits out its own duration, and
  rate-based rules need two scrapes. Nothing fires falsely at the start, but
  a condition that was already true fires only after its `for:` again.
- **For good:** a critical and its warning both notify, since no inhibition is
  rendered. Silences are re-created by hand (pre-check 6).

## Pre-checks

Each must print what it says. Nothing here writes.

```sh
# 1. O2 reached the live objects: every object marked, every release suspended.
for ns in observability; do kubectl --context personal -n $ns get all,cm,pvc,sa,servicemonitor,podmonitor,prometheusrule,alertmanagerconfig,grafana,grafanadashboard,grafanafolder,helmrelease,helmrepository -o json \
  | jq -r '.items[] | select(.metadata.labels["kustomize.toolkit.fluxcd.io/name"] != null) | "\(.kind)/\(.metadata.name) \(.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] // "UNMARKED")"' | sort -u; done
kubectl --context personal -n observability get helmrelease -o custom-columns=NAME:.metadata.name,SUSPEND:.spec.suspend
#    every Flux-applied object says "disabled"; every release but dcgm-exporter says true.

# 2. O3 landed: fleet-infra's three Kustomizations are gone, the namespace has a new owner.
kubectl --context personal -n flux-system get kustomization apps-observability apps-observability-rules apps-grafana-dashboards 2>&1 | grep -c NotFound   # 3
kubectl --context personal get ns observability -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}'    # apps-observability-namespace
kubectl --context personal -n edge-system get ingressroute grafana gatus faro -o jsonpath='{range .items[*]}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}{end}'   # apps-edge x3

# 3. Vault holds every key the render reads (names only).
vault kv get -format=json secret/platform/observability | jq -c '.data.data | keys'
#    includes discord.alert_webhook_url and grafana.oauth_client_secret (both read 2026-10-29 from
#    the Secrets VSO projects today).

# 4. The CRDs are the bootstrap set's (change A ran).
kubectl --context personal get crd prometheuses.monitoring.coreos.com grafanadashboards.grafana.integreatly.org \
  -o jsonpath='{range .items[*]}{.metadata.managedFields[*].manager}{"\n"}{end}'   # each lists estate-bootstrap

# 5. Anything made in the old Grafana's UI, which the new one will not have.
kubectl --context personal -n observability port-forward svc/grafana 3000:80 &
admin_password=$(kubectl --context personal -n observability get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s --netrc-file <(printf 'machine localhost login admin password %s\n' "$admin_password") \
  'http://localhost:3000/api/search?type=dash-db' | jq -r '.[] | select(.folderTitle == null or .folderTitle == "General") | .uid + " " + .title'
#    each line is a dashboard no operator provisioned: export it, or accept it lost.

# 6. Active silences, to re-create on the new Alertmanager.
kubectl --context personal -n observability exec alertmanager-metrics-stack-alertmanager-0 -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 silence query

# 7. node went first: node-exporter is the node Project's, not metrics-stack's.
kubectl --context personal get ds -A | grep -E 'node-exporter|node-metrics'
#    node-system/node-metrics ready on every node. On 2026-10-30, after node's flip, the old
#    observability/metrics-stack-prometheus-node-exporter was still there with 0 ready (its values say
#    enabled: false); it is node's leftover to delete, and O2 must not resurrect it.
```

## Cutover

1. **Merge B**, then the release PR release-please opens for it. The release
   publishes the Platform document and the observability fragment and
   dispatches composition. Let Flux apply `estate-pins` on its interval once
   the pin lands, and watch:

   ```sh
   flux get kustomization apps-observability -n flux-system --watch
   ```

   In order (each a watch, not an action):
   - the `vault-policy` Job completes. Roles `observability-system-grafana`,
     `-alertmanager` and `-prometheus` exist, and `grafana-admin`'s two
     generated keys are in Vault;
   - VSO syncs `grafana-platform-observability`,
     `grafana-observability-system-grafana-admin` and
     `alertmanager-platform-observability`;
   - the new claims bind (Prometheus, Alertmanager, Grafana and Gatus on
     Frankfurt; the stores on Enschede), and the stores start empty;
   - the estate's operator creates `prometheus-prometheus-0` and
     `alertmanager-alertmanager-0`;
   - auth's pin moves too: auth-api rolls through its Canary onto the new
     collector address.

2. **One stack alerts.** As soon as the estate's two operators are Ready, the
   old ones go, then the old stack's objects that the new Prometheus or
   Alertmanager would read. Two operators of one release reconcile every
   `Prometheus` cluster-wide and fight over each. Both run v0.93.1 and v5.25.0:

   ```sh
   kubectl --context personal -n observability delete deployment metrics-stack-operator grafana-operator
   # The old Prometheus, Alertmanager and Grafana; each StatefulSet goes with its object, the claims stay.
   kubectl --context personal -n observability delete prometheus metrics-stack-prometheus
   kubectl --context personal -n observability delete alertmanager metrics-stack-alertmanager
   kubectl --context personal -n observability delete grafana grafana
   # Their monitors and routing. The new Prometheus selects every monitor of every namespace, so the old
   # kubelet, apiserver, coredns, node-exporter and kube-state-metrics ones would scrape twice.
   kubectl --context personal -n observability delete servicemonitor,podmonitor,alertmanagerconfig --all
   kubectl --context personal -n flux-system delete podmonitor flux-controllers
   ```

   Monitors in other namespaces stay: they are still-legacy Projects' (edge's
   Traefiks), and the new Prometheus scrapes them as the old one did.
3. Merge O4 once `apps-observability` is Ready. Both Traefiks restart once
   with the new tracing endpoint, and the three routes serve the new stack.

## Proof

Read each; a Ready condition alone proves nothing.

1. `flux get kustomization apps-observability` is Ready.
2. An alert reaches Discord through the estate's own Alertmanager: fire one at
   severity warning, from inside its pod:
   `kubectl -n observability-system exec alertmanager-alertmanager-0 -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 alert add estate-proof severity=warning`.
3. Prometheus reads what it should: `up{job="kubelet",metrics_path="/metrics/cadvisor"}`,
   `up{job="apiserver"}` and `up{job="kustomize-controller"}` are 1. A rule of
   `prometheus-platform` shows in `/api/v1/rules`, and `/api/v1/alertmanagers`
   lists `alertmanager`.
4. Grafana at `https://grafana.jorisjonkers.dev` signs in through auth-api and
   shows live data. The 31 dashboards are in the folder `observability`, and the
   Grafana object reads `NoMatchingInstances` nowhere:
   `kubectl -n observability-system get grafanadashboards -o custom-columns=NAME:.metadata.name,SYNCED:.status.conditions[0].reason`.
5. Logs arrive: `{namespace="auth-system"}` in the new Loki returns lines newer
   than the flip, and a trace from auth-api is in the new Tempo.
6. `https://status.jorisjonkers.dev` lists the estate's checks, grouped by
   Project.

## After the flip

By hand, once the proofs pass:

- the rest of the old stack in `observability`: the HelmReleases (suspended,
  so deleting them uninstalls nothing), then the StatefulSets, Deployments,
  DaemonSets, Services, ConfigMaps and Secrets the charts left;
  `platform-alerts` and the chart's rules; the GrafanaDashboards and
  GrafanaFolders; the HelmRepositories;
- cluster-scoped: the `metrics-stack-admission` webhook configurations; the
  ClusterRoles and ClusterRoleBindings `alloy`, `grafana-clusterrole`,
  `grafana-operator`, `loki-clusterrole`, `metrics-stack-*` and
  `pyroscope-alloy`; and the operator's old kubelet Service
  `kube-system/metrics-stack-kubelet` with its Endpoints, plus
  `kube-system/metrics-stack-coredns` and `metrics-stack-kube-etcd`;
- the old claims, each when the table above says;
- the old Vault roles the old path's VSO used for these two documents, which
  the policy job never deletes.

## Rollback

The generic runbook's steps (deploy-kit `docs/runbooks/handover.md#rollback`):
mark `projects/observability/source.yaml`'s Kustomization `prune: false`, move
`observability` back to `legacy` with its `serving` statement and delete
`projects/observability/`, then revert O4, O3 and O2. Nothing of the old stack
was deleted, and its HelmReleases resume when O2 is reverted. Cutover step 2's
deletions come back with them: reverting O3 re-applies `alertmanager-discord`
and the dashboards, and the two HelmReleases, once resumed, re-create the two
operators, the `Prometheus`, `Alertmanager` and `Grafana` objects and their
monitors on their next upgrade. A forced HelmRelease reconcile is the
maintainer's call, since an unchanged release is otherwise not upgraded. The new claims in `observability-system`
stay until deleted by hand; no data is touched either way.
