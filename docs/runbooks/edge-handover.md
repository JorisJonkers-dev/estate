# Handing `edge` over to the estate path

Moves the Project `edge` (the public Traefik, the LAN Traefik and external-dns)
from fleet-infra's old path to its pin here, on the deploy-kit release that carries
JorisJonkers-dev/deploy-kit#756 and #762 (the first after 1.4.0; `toolkit.yml` moves to it first), in the three
changes of deploy-kit `spec/v1/60-setup.md#handing-over-one-project-at-a-time`.
Tracking: JorisJonkers-dev/deploy-kit#662.

The edge holds no data, so nothing is adopted in place: the three start fresh
in `edge-system`, beside the old ones in `ingress-system`, `ingress-lan-system`
and `external-dns`. What has to move is each **address**: a pool address is
held by one Service at a time, and a host port is bound once per node. So for
each address the old holder lets go and the new one takes it, and the time in
between is that address's outage. Once the edge is on the estate path, every
routed Project's artifact gains its routes too, so its pin moves once.

The maintainer decided the shape (2026-10-30): one window of about 45
minutes, the LAN pass first; cert-manager retires with the edge rather than
staying behind; every route's Project declares its exposure first, so there is
no `apps-edge-legacy`. A live step is still the maintainer's go-ahead, never an
agent's.

## What it waits on

| | what | where |
|---|---|---|
| W1 | every handover before it in the runbook's order, `secrets` and `data` excepted; above all `node` (the `l4-speaker` and the pool `lan-edge` then come from the render) and `observability` | JorisJonkers-dev/deploy-kit#659, #660 |
| W2 | `CF_DNS_API_TOKEN` at `secret/data/platform/cloudflare` | JorisJonkers-dev/estate#229 (closed) |
| W3 | the deploy-kit release carrying a tier's proxy API access (#727) and a tier's certificate source (#726), and `toolkit.yml` moved to it. This change validates only on it: `certificateFrom` is a field 1.4.0 refuses | JorisJonkers-dev/deploy-kit#756, #762 |
| W4 | every routed Project declares its exposures: the six media Projects' changes merged, **released**, and composed, so their pins carry the declarations before B | jellyfin#26, jellyseerr#13, qbittorrent#13, prowlarr#13, arr#32, immich#23 |
| W5 | the LAN tier's wildcard at `secret/data/platform/tls/jorisjonkers-dev` (`tls.crt`, `tls.key`), copied once from cert-manager's last issue: `bootstrap/secrets.sh --only tls-wildcard` | this change |
| W6 | an issuer that renews that path from frankfurt, before the copy expires (2026-12-16; renew by 2026-12-01). Not a blocker for the window; a blocker for the copy's expiry | follow-up issue in this repository |

## The changes, in order

| # | where | when | what | outage |
|---|---|---|---|---|
| F1 | JorisJonkers-dev/fleet-infra#555 (merged) | any time before the window | the five default-deny policies the old path applies (hermes, hindsight, immich, karakeep, overleaf) also admit `edge-system`'s `traefik-public` and `traefik-lan` | none |
| F2 | JorisJonkers-dev/fleet-infra#556 | before `node`'s handover | `enschede-lan` gives up .99 and a new pool `lan-edge` holds it alone; the old `traefik-lan` Service already asks for .99 by address, naming no pool (#565) | .99 for the gap between two Flux applies |
| F3 | JorisJonkers-dev/fleet-infra#557 | window step 1 | every object of external-dns, both Traefiks and `apps-edge` gets `prune: disabled`; the three HelmReleases are suspended; `apps-edge` stops pruning | none |
| F4 | JorisJonkers-dev/fleet-infra#558 | window step 2, once F3's marks are read back | external-dns and both Traefiks leave `apps-core`, and `cluster/flux/apps/edge` and the Kustomization `apps-edge` leave whole, with no legacy copy: every route, the default TLS store, the wildcard Certificate and its ClusterIssuer stay live, marked and applied by nothing | none |
| B | this repository, this change, then its release | window step 3 | the ledger moves `edge` to `estate`; the edge file gains external-dns; the proxies' API access is derived (no `api`, no holder entry); the Platform document admits external-dns, gains `dns.direct`, and the LAN tier reads its certificate from W5's path | the two passes below |
| C | fleet-infra and by hand, after the flip | once every check holds | the old `ingress-system`, `ingress-lan-system`, `external-dns` and `edge-system` objects (by hand); cert-manager, its ClusterIssuer and the wildcard Certificate (JorisJonkers-dev/fleet-infra#573, the secrets runbook's R4) | none |

F4's `apps-edge` must be gone, not only emptied, before B.

## The two passes

The window is about 45 minutes at a quiet hour, the maintainer present, LAN
pass first. The gap of each pass is bounded by one mechanism, and the passes
are taken one at a time, minutes apart, so each outage is that pass's alone:

| order | address | old holder | new holder | the gap is | expected |
|---|---|---|---|---|---|
| 1 | `192.168.0.99`, pool `lan-edge` | Service `ingress-lan-system/traefik-lan` | Service `edge-system/traefik-lan-lan-edge` | MetalLB reprocessing the pending Service after the old one is deleted, and the speaker's gratuitous ARP | a few seconds, LAN clients only, and jellyfin's public name, which the router forwards to .99 |
| 2 | host ports 80 and 443 on `frankfurt-contabo-1` (`edge-frankfurt`, 167.86.79.203) | pod of `ingress-system/traefik` | pod of `edge-system/traefik-public` | the old pod's graceful stop (its `terminationGracePeriodSeconds` is 60; Traefik stops sooner), then the new pod's scheduling and start, image already on the node | 15 to 60 seconds, every public host (Cloudflare answers 521/522) |

**Why the LAN goes first.** Both new proxies run the same rendered
configuration: the same provider flags, the API access this change declares,
cross-namespace routes, the derived API access, the default TLS store the LAN
tier's certificate derives, the rendered `forward-auth`.
The LAN pass has the shorter gap and the smaller audience, and the new LAN
proxy is already Running before it, so it can be checked with a port-forward
before it takes any traffic. The public proxy cannot be checked that way: it
stays Pending until the old one frees the host ports. So the LAN pass proves the
shared configuration on real traffic before the public pass, whose gap is
longer and whose audience is everyone.

**Why both in one window.** The estate's `apps-edge` waits for every
Deployment, and `traefik-public` is Pending until pass 2. Until then `apps-edge`
is not Ready, and every unit that follows the edge holds its next change.

**Why not zero.** A pool address is held by one Service, and a node's port by
one pod. The only way to a shorter public gap is a shorter stop of the old pod,
which drops requests in flight; the window keeps the graceful stop.

## The render against the old path

Rendered with deploy-kit `main` plus #756 and #762 (2026-10-30), the release
this change waits on: `deploy-kit compose` over every participant's newest
fragment with the six media Projects' exposure changes (W4) published in
place of theirs, this branch's Platform and platform fragments (edge moved to
`estate`), `participants.yml`, `cluster-state.yml` and the committed sources.
Compared with the same inputs composed on deploy-kit `main` with the edge
`legacy`, with `kubectl kustomize` of fleet-infra `main` (594ba93)
`cluster/flux/apps/{core/external-dns,core/ingress-controller,core/lan-ingress-controller,edge}`
and the live objects, read 2026-10-29 and 2026-10-30. NetworkPolicies are rendered but not
applied (`networkPolicyController: embedded`), so they are left out.

### The proxies

| object | old path | render | why |
|---|---|---|---|
| where | HelmReleases `traefik` (`ingress-system`) and `traefik-lan` (`ingress-lan-system`), chart 41.4.0 | Deployments `traefik-public` and `traefik-lan` in `edge-system` | no chart is rendered; the namespace is the Project's |
| image | `traefik:v3.7.12` | the same digest (`sha256:9c2a54d8…`) | images lock |
| selector | `name: traefik` + `instance: traefik-<release>-<ns>` | `name` + `instance` = the Process | the fixed label set |
| public placement | `nodeSelector` site `frankfurt` | node affinity on `frankfurt-contabo-1` | derived from `edge-frankfurt`, a node address; the same node |
| LAN placement | `capability-lan-ingress` | node affinity on `enschede-t1000-1`, `enschede-gtx-960m-1` | derived from the capability; the same two nodes |
| public ports | `web` 8000 → host 80, `websecure` 8443 → host 443, `metrics` 9100, `traefik` 8080 | `tcp-80` → 8000 and `tcp-443` → 8443 as host ports, `web`, `websecure`, `admin` 8080; no 9100 | the tier's listener derives 80 and 443; metrics move to the `traefik` entry point |
| LAN address | Service `traefik-lan`, LoadBalancer, `enschede-lan`, `loadBalancerIPs: .99`, `Local` | Service `traefik-lan-lan-edge`, LoadBalancer, `metallb.io/address-pool: lan-edge`, `Local`, 80 → 8000, 443 → 8443 | the address is the Platform document's; the one-address pool is the pin |
| public Service | `traefik`, LoadBalancer on the non-existent pool `frankfurt-unused` (never assigned), with `external-dns` hostname `ingress.jorisjonkers.dev` | `traefik-public`, ClusterIP | no load balancer on a node address. The record `ingress.jorisjonkers.dev` (proxied) stays in Cloudflare: external-dns runs upsert-only and never deletes it |
| provider | CRD and Ingress providers, class `traefik-public`/`traefik-lan`, cross-namespace, empty services allowed | CRD provider only, same class, cross-namespace, empty services allowed | the render enables no Ingress provider; the cluster holds no Ingress object |
| API access | chart ClusterRoles `traefik-ingress-system`, `traefik-lan-ingress-lan-system` | ClusterRoles `edge-system-traefik-public` and `edge-system-traefik-lan` the tiers derive: the chart's rules less the Ingress provider; token mounted | a tier's proxy derives the access its provider reads routes with (JorisJonkers-dev/deploy-kit#727); it needs no `api` and no place in `apiAccess.holders` |
| TLS | `websecure` TLS on; every route `tls: {}`, the default TLS store `edge-system/default`, cert-manager's wildcard `jorisjonkers-dev-tls` | `websecure` TLS on; public resolver `public-frankfurt` (DNS-01 at Cloudflare, `CF_DNS_API_TOKEN` from `secret/data/platform/cloudflare`, state on the claim `acme`, 16Mi); the LAN proxy has none | `acme` on the public tier, `none` on the LAN tier. A rendered public route names the resolver; a LAN route, every route still on the old path, and a public host until its certificate is issued take the default store's wildcard |
| default TLS store | `TLSStore edge-system/default` → `jorisjonkers-dev-tls`, cert-manager's | `TLSStore edge-system/default` → `traefik-lan-platform-tls-jorisjonkers-dev`, synced by `traefik-lan`'s VSO grant from `secret/data/platform/tls/jorisjonkers-dev`, no restart on change | the LAN tier's `certificateFrom` (JorisJonkers-dev/deploy-kit#726). The same object, taken over by name at B; both proxies serve it. W5 must hold the path first, or every route that names no certificate serves Traefik's self-signed one |
| `--api.dashboard` | on: `traefik.jorisjonkers.dev` serves `api@internal` | off | not modelled: the `traefik-dashboard` route stops resolving (`api@internal` unknown) and that host answers 404 |
| tracing | OTLP to `alloy.observability:4318`, sample 1.0 (public) and 0.1 (LAN) | none | a proxy has no Runtime Profile; traces from the edge stop |
| access log | JSON, headers dropped except `User-Agent`, `Referer`, `X-Forwarded-For` | JSON, Traefik's defaults (every header dropped) | not modelled; the three headers leave the log |
| metrics | PodMonitors `traefik`, `traefik-lan` (`release: metrics-stack`), `job` = `traefik`, `instance_kind` public/lan, entry point `metrics` 9100, router/service/entrypoint labels | ServiceMonitor per proxy on `admin` 8080 `/metrics`, from the declared `scrape`; `job` per proxy; Traefik's default labels (entry points and services, no routers) | the observability handover's monitors; the Traefik dashboard's queries on `job="traefik"`, `instance_kind` and router labels need adjusting |
| resources | none requested | 50m / 256Mi, limit 256Mi | request equals limit. Live use 88Mi (public) and 129Mi (LAN): the worked example's 128Mi would kill the LAN proxy |
| posture | 65532, read-only root, all capabilities dropped, seccomp | the same, plus `fsGroup` 65532 for the claim | `hardening: restricted` |
| rollout | Deployment, `maxSurge: 0`, `maxUnavailable: 1` | the same | delivery machinery: a rolling switchover, never two copies |
| probes | `/ping` on 8080 | `/ping` on 8080, plus a startup probe (4 × 5s) | `startupBudget: 20s` |
| `forward-auth` | Middleware `edge-system/forward-auth` → `auth-api.auth-system:8081/api/v1/auth/verify`, the same three response headers | Middleware `edge-system/forward-auth` → `auth-http.estate-system:8081/api/v1/auth/verify`, the same headers | the same object, taken over by name. `auth-http` is the ExternalName auth's unit renders for `auth-api.auth-system`, so the backend is the same |
| new | Middlewares `security-headers`, `-strict`, `-admin`, `-workflow` in `edge-system` | | what each rendered route's audience and exposure derive |
| new | `edge-system` VaultConnection, `vault-policy` CronJob, Job, ConfigMap, ServiceAccount; VaultAuth and VaultStaticSecret for `traefik-public` and `external-dns`; Alert `rollouts-edge` and Provider `reporter-edge` | | how every estate Project reaches Vault and reports rollouts |
| left behind | IngressClasses `traefik-public` (default) and `traefik-lan`; the two ClusterRoles and bindings; Services, Deployments, ServiceAccounts, PodMonitors, HelmRepositories and `sh.helm.release.*` Secrets in both old namespaces | | the suspended releases keep them; deleted by hand after the flip |

### external-dns

| object | old path | render | why |
|---|---|---|---|
| where | HelmRelease `external-dns` in `external-dns`, chart 1.21.1 | Deployment `external-dns` in `edge-system` | no chart; the edge owns the DNS controller |
| image | `external-dns:v0.21.0` | the same index digest (`sha256:f53faaf7…`), uid 65532 | images lock; the image names root, and both run it as 65532 |
| flags | `--source=service --source=traefik-proxy --policy=upsert-only --registry=txt --provider=cloudflare --annotation-filter=kubernetes.io/ingress.class=traefik-public --domain-filter=jorisjonkers.dev --txt-owner-id=edge-system-external-dns`, interval 1m, log info/text | the same words, as `args` | the owner id is the one every record's TXT carries, so it takes the records over |
| token | `CF_API_TOKEN` from Secret `cloudflare-api-token`, VSO from `secret/platform/edge` `cloudflare.dns_api_token`, as `vso-system/default` | `CF_API_TOKEN` from `secret/data/platform/cloudflare` `CF_DNS_API_TOKEN`, as `edge-system-external-dns` | one token for the resolver and the DNS controller (JorisJonkers-dev/estate#229). It answers only from Frankfurt's address |
| placement | `nodeSelector` site `frankfurt` | `site: frankfurt`: node affinity on `frankfurt-contabo-1` | the token's IP restriction |
| RBAC | nodes, pods, services, endpointslices, traefik.io and traefik.containo.us IngressRoute kinds | the same, traefik.io only | the old API group is served by nothing here |
| resources | none | 10m / 128Mi | live use 58Mi |
| priority | none | `platform-critical-app` | a cluster-scope reader is a privileged role |
| rollout | RollingUpdate | Recreate | `cutover: interrupted`: two copies would race on the same records |

### Routes

While the edge is `legacy`, no Project's share carries a route. With this
change composed, 31 routes render in 19 Projects' shares: 23 public (auth,
estate-dashboard, findability-explorer, grimoire, hindsight (3), home-portal,
immich, jellyseerr, karakeep, mail, n8n, outline, overleaf, prowlarr,
qbittorrent, tribelt, utility (2), and sonarr, radarr and bazarr in arr) and 8
LAN (immich, jellyfin, jellyseerr, prowlarr, qbittorrent, sonarr, radarr,
bazarr). A public one carries the tier's class, `websecure`, the external-dns
target `ingress.jorisjonkers.dev` proxied and `tls.certResolver:
public-frankfurt`; a LAN one the class `traefik-lan` and `tls: {}`; each an
explicit priority of 997 to 999 and the security-headers baseline. No routed
Project's workload changes, so nothing restarts; each media Project also gains
its `-external-checks` ConfigMap.

| old path route (`edge-system`) | rendered route | differences |
|---|---|---|
| `home-portal`, `tribelt`, `n8n`, `outline`, `overleaf`, `findability-explorer`, `jellyseerr` | `<project>-system/<app>-public` | `PathPrefix(/)` added; `security-headers` (findability-explorer: `security-headers-strict`, `default-src 'self'`) added; resolver instead of `tls: {}` |
| `grimoire`, `immich`, `karakeep`, `hindsight`, `estate-dashboard`, `adguard`, `headlamp` (`dashboard.`), `qbittorrent`, `prowlarr`, `sonarr`, `radarr`, `bazarr` | the same, behind `forward-auth` | as above; estate-dashboard gets `security-headers-strict`. The media ones and utility's take forward-auth from the audience (no Client yet, the transitional rule) |
| `<app>-lan` for immich, jellyfin, jellyseerr, prowlarr, qbittorrent, sonarr, radarr, bazarr | `<project>-system/<app>-lan`, class `traefik-lan` | `PathPrefix(/)` and `security-headers` added; the same backend and port; `tls: {}` |
| `hindsight-api`, `hindsight-private` | `hindsight-system/hindsight-api`, `hindsight-private` | the old single rule with `||` becomes three rules by priority; the same paths |
| `auth-api`, `auth-api-well-known`, `auth-ui` | `auth-system/auth-public`, three rules | negative path matches become priorities (`/.well-known/` 999, `/api/` 998, `/` 997); the same backends |
| `stalwart` and Middleware `stalwart-root-to-admin` | `mail-system/stalwart-admin`, with its own `stalwart-admin-1-redirect` | the redirect is mail's declared `redirectTo`; behind forward-auth as before |
| `jellyfin` (public, grey-cloud, A record 130.89.174.190) | none | the public route only makes external-dns write the record; the router forwards the home address to .99, where `jellyfin-lan` serves it. The record stays: external-dns never deletes one. Modelling it is JorisJonkers-dev/deploy-kit#711 |
| `traefik-dashboard` and its redirect | none | `api@internal` is not rendered: `traefik.jorisjonkers.dev` answers 404 |
| new | security headers on every rendered route: `X-Frame-Options: DENY`, `nosniff`, a referrer and permissions policy, HSTS one year with subdomains, and a CSP on the strict and admin kinds | derived. **Check** estate-dashboard and findability-explorer under `default-src 'self'`, and jellyfin's and immich's apps on the LAN, at the live step |

Both routes of each host exist from the flip until the old one is deleted. The
rendered one wins on priority (997 to 999 against the old rule length, at most
about 160), and both publish the same record, so neither DNS nor the request
path changes when the old one goes.

**What still serves from the old path after the flip**, through the new
proxies, which admit both classes, name the rendered `forward-auth` and serve
the default store: the routes of the Projects that hand over after the edge,
in their own directories, `data` (`rabbitmq`, `garage-assets`, `vault`) and
`agents` (`hermes`, `hermes-lan`, `agents-ui`, `agents-api`,
`agents-api-health`, `agents-ws`, `agents-ws-lan`; deprecated), and
`observability`'s three if it has not handed over. Each leaves with its own
Project.

### The namespace, and what only the render has

- **Namespace `edge-system`** is taken over in place: today `apps-edge` applies
  it, F3 marks it, F4 stops applying it, and the render applies it with
  `app.kubernetes.io/managed-by: deploy-kit` and `prune: disabled`
  (JorisJonkers-dev/deploy-kit#746), so deleting the estate's `apps-edge`
  never deletes it or the orphaned routes still in it.
- **Taken over by name:** `TLSStore default` and `Middleware forward-auth`.
- **Only in the render:** the claim `acme`, the security-header Middlewares, the
  ServiceMonitors, the certificate's VaultStaticSecret, and the Vault, rollout
  and policy objects above.

## Pre-checks

Each must print what it says. Nothing here writes.

```sh
# 1. F1 is live: the five policies admit edge-system's proxies.
kubectl get networkpolicy -A -o json | jq -r '.items[] | select(tostring | test("ingress-system|ingress-lan-system"))
  | "\(.metadata.namespace)/\(.metadata.name) \(tostring | test("edge-system"))"'
#    every line ends in true.

# 2. F2 is live: .99 sits in lan-edge alone, and the old Service holds it.
kubectl -n metallb-system get ipaddresspool -o custom-columns=NAME:.metadata.name,ADDR:.spec.addresses
kubectl -n ingress-lan-system get svc traefik-lan -o jsonpath='{.status.loadBalancer.ingress[0].ip} {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}'
#    192.168.0.99 lan-edge

# 3. F3 reached the live objects.
for ns in ingress-system ingress-lan-system external-dns edge-system; do
  kubectl -n "$ns" get all,cm,sa,podmonitor,helmrelease,helmrepository,middleware,ingressroute,tlsstore,certificate,vaultstaticsecret -o json \
    | jq -r '.items[] | select(.metadata.labels["kustomize.toolkit.fluxcd.io/name"]) | "\(.kind)/\(.metadata.name) \(.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] // "UNMARKED")"'
done
kubectl get ns ingress-system ingress-lan-system external-dns edge-system -o custom-columns=NAME:.metadata.name,PRUNE:.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune
kubectl get helmrelease -A -o custom-columns=NAME:.metadata.name,SUSPEND:.spec.suspend | grep -E 'traefik|external-dns'
#    every object Flux applied says disabled; the three releases say true.

# 4. F4 landed: apps-edge is gone with no legacy copy, the old pods and routes still serve.
kubectl -n flux-system get kustomization apps-edge apps-edge-legacy 2>&1   # both NotFound
for ns in ingress-system ingress-lan-system external-dns; do kubectl -n "$ns" get pods; done
kubectl -n edge-system get ingressroute,tlsstore,certificate --no-headers | wc -l

# 5. Vault holds the token the render reads (names only), signed in as bootstrap/secrets.sh does.
vault kv get -format=json secret/platform/cloudflare | jq -c '.data.data | keys'
#    ["CF_DNS_API_TOKEN"]

# 6. W5: the wildcard the LAN tier will read is in Vault (names only), and has time left.
vault kv get -format=json secret/platform/tls/jorisjonkers-dev | jq -c '.data.data | keys'
#    ["tls.crt","tls.key"]
vault kv get -field=tls.crt secret/platform/tls/jorisjonkers-dev | openssl x509 -noout -subject -ext subjectAltName -enddate
#    *.jorisjonkers.dev and jorisjonkers.dev, notAfter at least 14 days out

# 7. W3: the toolkit renders the derived access and the certificate source.
grep deploy-kit toolkit.yml
```

## Cutover

Set a terminal per watcher first:

```sh
kubectl -n edge-system get pods,svc -o wide -w
while sleep 2; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 https://jorisjonkers.dev/; done
while sleep 1; do printf '%s ' "$(date +%T)"; curl -sk -o /dev/null -w '%{http_code}\n' --max-time 2 --resolve jellyfin.jorisjonkers.dev:443:192.168.0.99 https://jellyfin.jorisjonkers.dev/; done   # from the LAN
```

1. **Merge B**, then the release PR release-please opens for it. The release
   publishes the Platform document and the edge fragment and dispatches
   composition; reconcile `estate-pins` once the pin lands.

   ```sh
   flux reconcile kustomization estate-pins -n flux-system --with-source
   ```

   What follows: `edge`'s `vault-policy` Job writes `edge-system-traefik-public`,
   `edge-system-traefik-lan` and `edge-system-external-dns`; VSO syncs the two
   token Secrets and the wildcard; `TLSStore default` now names the synced
   wildcard, which both old proxies serve at once (the same certificate, from
   another Secret); `traefik-lan` starts and its Service `traefik-lan-lan-edge`
   stays `<pending>`;
   `traefik-public` stays Pending (host ports taken); `external-dns` starts.
   The 19 routed Projects' pins move and their routes appear. Nothing that
   serves changes yet.

   ```sh
   kubectl -n edge-system get secret traefik-lan-platform-tls-jorisjonkers-dev -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate
   kubectl -n edge-system get tlsstore default -o jsonpath='{.spec.defaultCertificate.secretName}{"\n"}'
   ```

2. **Retire the old external-dns.** Two copies with one owner id write the same
   records, which is harmless, but only one should:

   ```sh
   kubectl -n edge-system logs deploy/external-dns | tail -5   # "All records are already up to date"
   kubectl -n external-dns scale deploy external-dns --replicas=0
   ```

3. **Check the new LAN proxy before it takes traffic.**

   ```sh
   kubectl -n edge-system port-forward deploy/traefik-lan 18443:8443 &
   curl -sk -o /dev/null -w '%{http_code}\n' --resolve jellyfin.jorisjonkers.dev:18443:127.0.0.1 https://jellyfin.jorisjonkers.dev:18443/
   kubectl -n edge-system logs deploy/traefik-lan | grep -ci 'forbidden\|error'
   ```

   A 200 or 302, and no `forbidden`: it reads the routes, the store and the
   Services. Otherwise stop here and roll back.

4. **Pass 1, the LAN address.** Save the old Service, then delete it:

   ```sh
   kubectl -n ingress-lan-system get svc traefik-lan -o yaml > traefik-lan-svc.yaml
   kubectl -n ingress-lan-system delete svc traefik-lan
   kubectl -n edge-system get svc traefik-lan-lan-edge -w     # EXTERNAL-IP 192.168.0.99
   ```

5. **Pass 2, the public host ports.**

   ```sh
   kubectl -n ingress-system scale deploy traefik --replicas=0
   kubectl -n edge-system get pods -l app.kubernetes.io/instance=traefik-public -w   # Running, then Ready
   kubectl -n edge-system logs deploy/traefik-public -f | grep -i acme               # one certificate per rendered host
   ```

   `apps-edge` goes Ready, and the units that follow it continue.

## Proof

Read each; a Ready condition alone proves nothing.

1. `flux get kustomization apps-edge` is Ready; the claim `acme` is Bound.
2. Every public host answers over TLS from outside, and the 23 rendered hosts
   show a certificate issued for that host by Let's Encrypt (`openssl s_client
   -connect <host>:443 -servername <host>`, behind Cloudflare: check
   `traefik-public`'s ACME log instead). hermes and agents-ws, grey-cloud,
   answer on 167.86.79.203 directly.
3. Every LAN route answers on 192.168.0.99 with the wildcard read from Vault
   (`openssl s_client -connect 192.168.0.99:443 -servername jellyfin.jorisjonkers.dev`
   shows its fingerprint), and jellyfin answers from outside on its public name.
4. A gated host (`grimoire.jorisjonkers.dev`) redirects to auth's sign-in, and
   after it, serves: the rendered `forward-auth`.
5. `dig +noall +answer @amber.ns.cloudflare.com <host>` is unchanged for every
   public host, and external-dns's log shows no change planned.
6. estate-dashboard and findability-explorer render fully under their new
   Content Security Policy.

## After the flip

Change C. In fleet-infra, cert-manager, its ClusterIssuer and the wildcard
Certificate leave (JorisJonkers-dev/fleet-infra#573): the LAN tier and every
route that names no certificate already serve the copy in Vault. Then by hand:

- `edge-system`: every IngressRoute the old path applied there, now replaced
  (`home-portal`, `tribelt`, `n8n`, `outline`, `overleaf`,
  `findability-explorer`, `grimoire`, `immich`, `immich-lan`, `karakeep`,
  `hindsight`, `hindsight-api`, `hindsight-private`, `estate-dashboard`,
  `auth-api`, `auth-api-well-known`, `auth-ui`, `adguard`, `headlamp`,
  `stalwart`, `jellyfin`, `jellyfin-lan`, `jellyseerr`, `jellyseerr-lan`,
  `qbittorrent`, `qbittorrent-lan`, `prowlarr`, `prowlarr-lan`, `sonarr`,
  `sonarr-lan`, `radarr`, `radarr-lan`, `bazarr`, `bazarr-lan`,
  `traefik-dashboard` and its redirect), Middleware `stalwart-root-to-admin`,
  the ConfigMaps `edge-catalog` and `edge-route-catalog`, Certificate
  `wildcard-jorisjonkers-dev` and Secret `jorisjonkers-dev-tls` (all marked, so
  nothing prunes them). Deleting `jellyfin` leaves its A record: external-dns
  never deletes one;
- namespaces `ingress-system`, `ingress-lan-system` and `external-dns`, with
  everything left in them;
- cluster-wide: IngressClasses `traefik-public` and `traefik-lan`, ClusterRoles
  and bindings `traefik-ingress-system`, `traefik-lan-ingress-lan-system`,
  `external-dns` and `external-dns-viewer`, ClusterIssuer
  `letsencrypt-cloudflare`;
- the `cloudflare.dns_api_token` key in `secret/platform/edge`, once mail reads
  the Cloudflare token from where the estate keeps it.

Before 2026-12-01: the issuer (W6) writes a renewed wildcard to
`secret/data/platform/tls/jorisjonkers-dev`; VSO resyncs it within 10 minutes
and the proxies reload it without a restart.

## Rollback

Per pass, inside the window:

- **Pass 2:** `flux suspend kustomization apps-edge -n flux-system`, `kubectl -n
  edge-system scale deploy traefik-public --replicas=0`, then `kubectl -n
  ingress-system scale deploy traefik --replicas=1`.
- **Pass 1:** with `apps-edge` suspended, `kubectl -n edge-system delete svc
  traefik-lan-lan-edge`, then `kubectl apply -f traefik-lan-svc.yaml` (drop its
  `resourceVersion`, `uid` and `clusterIP` first); MetalLB hands .99 back.

The whole handover: the generic runbook's steps (deploy-kit
`docs/runbooks/handover.md#rollback`): mark `projects/edge/source.yaml`'s
Kustomization `prune: false`, move `edge` back to `legacy` and delete
`projects/edge/`, then revert F4 (it restores `apps-edge` and its files) and
F3. Reverting F4 re-applies the old `TLSStore default` naming cert-manager's
Secret, so do it before cert-manager retires. Keep F1 and F2: both hold either way.
Nothing here holds data; the `acme` claim only saves a reissue.
