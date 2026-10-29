# Handing `observability` over to the estate path

Moves the Project `observability` from fleet-infra's old path to its pin here,
on deploy-kit 1.3.0, in the three changes of deploy-kit
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

**It cannot run yet.** As deploy-kit 1.3.0 renders it, the estate's Prometheus
scrapes only itself, evaluates no rule and notifies no Alertmanager
(JorisJonkers-dev/deploy-kit#722). The estate's Grafana receives no dashboard
(JorisJonkers-dev/deploy-kit#723). Until both are released, a flip leaves the
estate's own stack blind. The bridge below keeps the old stack alerting, but it
is a bridge, not a handover.

## What it waits on

| | what | where |
|---|---|---|
| W1 | Prometheus and Alertmanager rendered as the operator's objects, with storage, retention and selectors | JorisJonkers-dev/deploy-kit#722 (**blocks**) |
| W2 | the Grafana instance the operator imports into | JorisJonkers-dev/deploy-kit#723 (**blocks**) |
| W3 | the kubelet, cAdvisor, API server and CoreDNS scraped | JorisJonkers-dev/deploy-kit#724 (degrades: see [Alerts](#alerts-across-the-cut)) |
| W4 | `node` handed over first, and its node-exporter taken out of `metrics-stack` | JorisJonkers-dev/deploy-kit#659: node-exporter is a DaemonSet of the kube-prometheus-stack release, so suspending `metrics-stack` (O2) also orphans node's agent |
| W5 | the bootstrap set's CRDs | #259 (`cluster.sh` and `bootstrap.crds`), merged and run before O2 |

Fixed in this file, not waiting: the worked example's Gatus cannot gather any
check (JorisJonkers-dev/deploy-kit#725), and a blue-green Process's Services
carry only one port (JorisJonkers-dev/deploy-kit#728). See the diff.

## The changes, in order

| # | where | what | when | outage |
|---|---|---|---|---|
| A | estate, #259 | `cluster.sh` applies the monitoring stack's CRDs; `bootstrap.crds` lists `monitoring.coreos.com/v1alpha1` and `grafana.integreatly.org/v1beta1` | before the window | none |
| O1 | JorisJonkers-dev/fleet-infra#563 | prune marks on the namespace `observability`, `gatus-data`, `observability-backups` and the three routes; the loki chart keeps its claim, the grafana chart tells Helm to keep its | before the window | none |
| P | a person | PersistentVolumes to `Retain` (below) | before the window | none |
| O2 | JorisJonkers-dev/fleet-infra#564 | every object of `apps-observability`, `apps-observability-rules` and `apps-grafana-dashboards` marked; the seven HelmReleases suspended; the three Kustomizations `prune: false` | window step 1 | none |
| O3 | JorisJonkers-dev/fleet-infra#566 | the manifests and the three Kustomizations go; the namespace, the backup CronJobs and dcgm-exporter stay under `apps-observability-namespace`; the grafana, gatus and faro routes move unchanged to `apps-edge` | window step 2 | none |
| B | estate, #260, then its release | the ledger moves `observability` to `estate` and drops its `serving` statement; the Platform document gains `bootstrap.flux.metrics`, `telemetry.dashboards`, `monitoring` and the five API holders | window step 3 | auth-api rolls once |
| O4 | JorisJonkers-dev/fleet-infra#568 | the routes serve `observability-system`; both Traefiks trace to the new collector; the old Grafana's and Alertmanager's VaultStaticSecrets go | after the flip, once the units are Ready | both Traefiks restart |

O3's `apps-observability` must be gone, not only emptied, before B: the
estate's unit is also `flux-system/apps-observability`.

## The data, claim by claim

Every old claim is on `frankfurt-contabo-1`, `local-path`, reclaim `Delete`
(read 2026-10-29). None is carried. Each is kept, read-only, until its
retention would have run out, then deleted on the maintainer's go-ahead.

| old claim | holds | across the cut | old claim deleted |
|---|---|---|---|
| `prometheus-metrics-stack-prometheus-db-…-0` (20Gi) | 15 days of metrics | **lost from the estate's view.** The new TSDB starts empty. The old one stays queryable through the old Prometheus while the bridge runs | 15 days after the old Prometheus stops |
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

Rendered with deploy-kit 1.3.0 from this change. `deploy-kit compose` ran over
every other participant's newest fragment, this branch's Platform and
platform fragments, `participants.yml` and `cluster-state.yml`. The old side is
`kubectl kustomize` of fleet-infra `cluster/flux/apps/observability`,
`observability-rules` and `grafana-dashboards` at 72a449c, with what the seven
HelmReleases render live, read 2026-10-29. Images: each lock entry is the
digest the live pod runs.

### The metrics stack (`metrics-stack`, kube-prometheus-stack 90.0.0)

| live | render | why |
|---|---|---|
| `Prometheus` and `Alertmanager` objects; the operator runs each as a StatefulSet with a config-reloader | Deployments `prometheus` and `alertmanager` running the images' default configuration | **deploy-kit#722.** Blocks the handover |
| Prometheus selects every ServiceMonitor, PodMonitors and PrometheusRules labelled `release: metrics-stack`; Alertmanager reads every AlertmanagerConfig with matcher strategy `None` | nothing selects anything | deploy-kit#722 |
| TSDB claim 20Gi, `retention: 15d`, remote-write receiver, exemplar storage | `prometheus-data` 20Gi, the same three as arguments | declared; the flags work without a configuration |
| Alertmanager claim 5Gi | `alertmanager-data` 5Gi | declared |
| Alertmanager's own route: group by alert and namespace, `Watchdog` and `InfoInhibitor` to `null`, a critical inhibits the same warning | `estate-alerts`: the same grouping and severity routes; no inhibition | the model renders one routing and no inhibition: **a firing critical and its warning both reach Discord** |
| 149 default alert rules and 85 recording rules (`defaultRules.create`) | `prometheus-kube-prometheus`, the same groups vendored from live | the chart is not rendered; its rules are carried as a rules file |
| `platform-alerts`, 49 rules, `release: metrics-stack` | `prometheus-platform`, the same 49 rules, VaultSealed as fleet-infra#545 wrote it | carried; the label is deploy-kit#722's |
| ServiceMonitors for the kubelet (with cAdvisor and probes), the API server, CoreDNS and etcd | none | **deploy-kit#724**: k3s is no Process |
| node-exporter DaemonSet | not here | the node Project's `node-metrics` agent (W4) |
| operator admission webhooks (failure policy `Ignore`) and their certgen hook Jobs | none | no webhook is rendered (chapter 14); left behind, deleted by hand |
| kube-state-metrics: every default collector, and Flux's Ready conditions (`gotk_resource_ready`) | 15 collectors, the ones its rules read; the same CustomResourceState as an Asset; list and watch on Flux's five kinds | an `api` holder lists what it reads. FluxResourceNotReady and FluxSourceFailing keep their metric |
| `revisionHistoryLimit: 3` by postRenderer | the default | fleet-infra's patch |
| every pod `nodeSelector` site `frankfurt` (the operator, Prometheus, Alertmanager) | node affinity on `frankfurt-contabo-1` | `placement.site`; kube-state-metrics floats as live |

### Grafana and its operator

| live | render | why |
|---|---|---|
| `Grafana` object `observability/grafana` (external, chart admin login) | none | **deploy-kit#723.** No dashboard reaches the estate's Grafana. Blocks |
| 31 GrafanaDashboards in 14 thematic folders; 9 fetched from grafana.com at run time | 31 in one folder, `observability`; the 9 vendored at the revision live pins | a Project's dashboards go to a folder named for it; nothing is fetched. Each moves to its owning Project's file at that Project's handover (the file says which) |
| data sources by the chart's sidecar, from a labelled ConfigMap | the same file as an Asset at Grafana's provisioning path, at the new addresses, plus Alertmanager | chapter 10 derives them; nothing does yet (deploy-kit#723) |
| Grafana 12.3.1, sign-in against auth-api, secret from `secret/platform/observability#grafana.oauth_client_secret` through `grafana-oidc-client` | the same image, env and key; Secret `grafana-platform-observability`; Vault role `observability-system-grafana` | the estate runs no identity provider yet (no `signIn`, no Client CRD), so the worked example's native Client waits for it |
| plugins installed by the chart | `GF_PLUGINS_PREINSTALL`, `egress: internet` | the same four plugins |
| claim `grafana` 10Gi; requests none | `grafana-data` 10Gi; 512Mi | fresh, see the data |
| route `grafana.jorisjonkers.dev`, no forward-auth | exposure `public`, `anonymous`, rendered at the edge's handover | as live: Grafana signs people in itself. The route moves to `apps-edge` (O3) and to the new Service (O4) |
| grafana-operator chart, 96Mi | Process, 128Mi | |

### The stores

| live | render | why |
|---|---|---|
| Loki chart: single binary, gateway (nginx), memberlist Services, rules sidecar, `loki-canary` on every node | one Process with the live configuration less memberlist and runtime config; no gateway, no rules sidecar, no canary | one replica needs no ring. No Loki rule exists. **loki-canary is not rendered**: logs are read through the API, so a canary per node tests nothing per node (chapter 14) |
| Loki's StatefulSet deletes its claim with it | `loki-data`, never deleted by a Deployment | O1 also keeps the old claim |
| Tempo chart, `-mem-ballast-size-mbs=1024`, usage report on | Process with the live configuration; remote-write to the new Prometheus; no ballast; usage report off | Tempo 2 ignores the ballast. Tempo's egress admits no internet |
| Pyroscope chart: v2 storage with a raft metastore, its own pull-mode Alloy (`pyroscope-alloy`) | Process, single binary, default storage on `pyroscope-data` | the pull-mode agent profiled only Pyroscope itself; nothing pushes profiles today |

### Collectors and Gatus

| live | render | why |
|---|---|---|
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

## Alerts across the cut

- **O1 to O3:** nothing changes. The old stack alerts as today.
- **From B, without the bridge:** the estate's Prometheus evaluates no rule
  (deploy-kit#722), so stopping the old stack is a **total alert gap**, Vault
  sealed included. Do not stop it until #722 is released and the estate's
  Prometheus fires a test alert.
- **The bridge** (until deploy-kit#722 and #723 are released): the old
  Prometheus, Alertmanager and Grafana keep running in `observability`, driven
  by the estate's operators:
  1. Delete the old operators' Deployments, `metrics-stack-operator` and
     `grafana-operator`, as soon as the estate's are Ready. Both run the same
     releases as the estate's (v0.93.1, v5.25.0) and reconcile cluster-wide.
     Two of each would fight over the old `Prometheus`, `Alertmanager` and
     `Grafana`.
  2. The old Alertmanager reads every AlertmanagerConfig, so it now holds both
     `observability/alertmanager-discord` and the estate's
     `observability-system/estate-alerts`, and **every alert reaches Discord
     twice**. Delete the old one; the estate's routing then delivers through
     the old Alertmanager. That proves the estate's routing and its webhook
     Secret end to end.
  3. The old Prometheus loads only rules labelled `release: metrics-stack`, so
     it keeps evaluating the old `platform-alerts` and the chart's defaults,
     orphaned and unchanged. Do not delete them during the bridge.
  4. The estate's 31 dashboards select `dashboards: grafana`, the old Grafana's
     labels, so the estate's operator imports them into the old Grafana. They
     carry the same uids as the old ones, in the folder `observability`.
- **For good, even after #722:** until deploy-kit#724, nothing scrapes the
  kubelet or the API server. `PodOOMKilled`, `PersistentVolumeFillingUp` and
  `KubeletDown` cannot fire, and neither can the chart's kubelet, API server
  and etcd rules. A critical and its warning both notify, since no inhibition
  is rendered.

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
```

## Cutover

1. **Merge B**, then the release PR release-please opens for it. The release
   publishes the Platform document and the observability fragment and
   dispatches composition. Reconcile `estate-pins` once its pin lands:

   ```sh
   flux reconcile kustomization estate-pins -n flux-system --with-source
   flux get kustomization apps-observability -n flux-system --watch
   ```

2. **What happens, in order** (each a watch, not an action):
   - the `vault-policy` Job completes: roles `observability-system-grafana` and
     `-alertmanager` exist;
   - VSO syncs `grafana-platform-observability` and
     `alertmanager-platform-observability`;
   - the new claims bind on `frankfurt-contabo-1`, the stores start empty;
   - auth's pin moves too: auth-api rolls through its Canary onto the new
     collector address.
3. **The bridge**, steps 1 and 2 of [Alerts](#alerts-across-the-cut), by hand:
   ```sh
   kubectl --context personal -n observability delete deployment metrics-stack-operator grafana-operator
   kubectl --context personal -n observability delete alertmanagerconfig alertmanager-discord
   ```
4. Merge O4 once `apps-observability` is Ready. Both Traefiks restart once
   with the new tracing endpoint.

## Proof

Read each; a Ready condition alone proves nothing.

1. `flux get kustomization apps-observability` is Ready.
2. An alert reaches Discord through the estate's routing: with the bridge, from
   the old Alertmanager reading `estate-alerts`; once deploy-kit#722 lands,
   from the estate's own. Fire one with `amtool alert add` at severity warning.
3. Grafana at `https://grafana.jorisjonkers.dev` signs in through auth-api and
   shows live data: once deploy-kit#723 lands, on the estate's Grafana. Until
   then the route stays on the old Grafana (do not merge O4's route half).
4. Logs arrive: `{namespace="auth-system"}` in the new Loki returns lines newer
   than the flip; a trace from auth-api is in the new Tempo.
5. `https://status.jorisjonkers.dev` lists the estate's checks, grouped by
   Project.
6. Flux is scraped: `up{job="kustomize-controller"} == 1` in the new
   Prometheus.

## After the flip

By hand, once the bridge is no longer needed (deploy-kit#722 and #723
released, proof 2 and 3 on the estate's own stack):

- the old stack in `observability`: the HelmReleases (suspended, so deleting
  them uninstalls nothing), then the StatefulSets, Deployments, DaemonSets,
  Services, ConfigMaps and Secrets the charts left; the `Prometheus`,
  `Alertmanager` and `Grafana` objects; `platform-alerts` and the chart's
  rules; the GrafanaDashboards and GrafanaFolders; the HelmRepositories;
- the old PodMonitor `flux-system/flux-controllers`;
- cluster-scoped: the `metrics-stack-admission` webhook configurations, and
  the ClusterRoles and ClusterRoleBindings `alloy`, `grafana-clusterrole`,
  `grafana-operator`, `loki-clusterrole`, `metrics-stack-*` and
  `pyroscope-alloy`;
- the old claims, each when the table above says;
- the old Vault roles the old path's VSO used for these two documents, which
  the policy job never deletes.

## Rollback

The generic runbook's steps (deploy-kit `docs/runbooks/handover.md#rollback`):
mark `projects/observability/source.yaml`'s Kustomization `prune: false`, move
`observability` back to `legacy` with its `serving` statement and delete
`projects/observability/`, then revert O4, O3 and O2. Nothing of the old stack
was deleted, and its HelmReleases resume when O2 is reverted. The bridge's two
deletions come back with them: reverting O3 re-applies `alertmanager-discord`,
and `flux reconcile helmrelease metrics-stack grafana-operator -n observability
--force` re-creates the two operators once O2 is reverted (an unchanged
release is otherwise not upgraded). The new claims in `observability-system`
stay until deleted by hand; no data is touched either way.
