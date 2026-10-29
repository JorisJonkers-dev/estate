# Handing `edge` over to the estate path

Moves the Project `edge` (the public Traefik, the LAN Traefik and external-dns)
from fleet-infra's old path to its pin here, on deploy-kit 1.3.0 (`toolkit.yml`), in the three
changes of deploy-kit `spec/v1/60-setup.md#handing-over-one-project-at-a-time`.
Tracking: JorisJonkers-dev/deploy-kit#662.

The edge holds no data, so nothing is adopted in place: the three start fresh
in `edge-system`, beside the old ones in `ingress-system`, `ingress-lan-system`
and `external-dns`. What has to move is each **address**: a pool address is
held by one Service at a time, and a host port is bound once per node. So for
each address the old holder lets go and the new one takes it, and the time in
between is that address's outage. Once the edge is on the estate path, every
routed Project's artifact gains its routes too, so its pin moves once.

**The order of the two passes and the window below are a proposal for the
maintainer, not a decision.** A live step is the maintainer's go-ahead, never
an agent's.

## What it waits on

| | what | where |
|---|---|---|
| W1 | every handover before it in the runbook's order, `secrets` excepted; above all `node` (the `l4-speaker` and the pool `lan-edge` then come from the render) | JorisJonkers-dev/deploy-kit#659 and its predecessors |
| W2 | `CF_DNS_API_TOKEN` at `secret/data/platform/cloudflare` | JorisJonkers-dev/estate#229 (closed) |
| W3 | a decision: cert-manager, its ClusterIssuer, the wildcard and the default TLS store stay on the old path after the flip (proposed), or the LAN tier gets a certificate source first | JorisJonkers-dev/deploy-kit#726 |
| W4 | a decision on the routes no Project renders yet (below): they stay on the old path under `apps-edge-legacy` (proposed), or their Projects declare their exposures first | the media Projects' repositories; JorisJonkers-dev/deploy-kit#711 for jellyfin |

## The changes, in order

| # | where | when | what | outage |
|---|---|---|---|---|
| F1 | JorisJonkers-dev/fleet-infra#555 | any time before the window | the five default-deny policies the old path applies (hermes, hindsight, immich, karakeep, overleaf) also admit `edge-system`'s `traefik-public` and `traefik-lan` | none |
| F2 | JorisJonkers-dev/fleet-infra#556 | before `node`'s handover; proposed in utility's window, right after its `lan-dns` pool (JorisJonkers-dev/fleet-infra#551) | `enschede-lan` gives up .99, a new pool `lan-edge` holds it alone, and the old `traefik-lan` Service asks for .99 by address, naming no pool | .99 for the gap between two Flux applies |
| F3 | JorisJonkers-dev/fleet-infra#557 | window step 1 | every object of external-dns, both Traefiks and `apps-edge` gets `prune: disabled`; the three HelmReleases are suspended; `apps-edge` stops pruning | none |
| F4 | JorisJonkers-dev/fleet-infra#558 | window step 2, once F3's marks are read back | external-dns and both Traefiks leave `apps-core`; the Namespace `edge-system` and Middleware `forward-auth` stop being applied (the render owns both names); `apps-edge` becomes `apps-edge-legacy`, since the estate's unit is also `flux-system/apps-edge` | none |
| B | this repository, this change, then its release | window step 3 | the ledger moves `edge` to `estate`; the edge file gains external-dns and the proxies' API access; the Platform document admits them and gains `dns.direct` | the two passes below |
| C | fleet-infra, after the flip | once every check holds | the replaced route files, the old `ingress-system`, `ingress-lan-system` and `external-dns` objects (by hand), the fragment drift entries | none |

F4's `apps-edge` must be gone, not only emptied, before B.

## The two passes (proposal)

The window is about 45 minutes at a quiet hour, the maintainer present. The
gap of each pass is bounded by one mechanism, and the passes are taken one at a
time, minutes apart, so each outage is that pass's alone:

| order | address | old holder | new holder | the gap is | expected |
|---|---|---|---|---|---|
| 1 | `192.168.0.99`, pool `lan-edge` | Service `ingress-lan-system/traefik-lan` | Service `edge-system/traefik-lan-lan-edge` | MetalLB reprocessing the pending Service after the old one is deleted, and the speaker's gratuitous ARP | a few seconds, LAN clients only |
| 2 | host ports 80 and 443 on `frankfurt-contabo-1` (`edge-frankfurt`, 167.86.79.203) | pod of `ingress-system/traefik` | pod of `edge-system/traefik-public` | the old pod's graceful stop (its `terminationGracePeriodSeconds` is 60; Traefik stops sooner), then the new pod's scheduling and start, image already on the node | 15 to 60 seconds, every public host (Cloudflare answers 521/522) |

**Why the LAN goes first.** Both new proxies run the same rendered
configuration: the same provider flags, the API access this change declares,
cross-namespace routes, the default TLS store, the rendered `forward-auth`.
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
which drops requests in flight; this proposal keeps the graceful stop.

## The render against the old path

Rendered with deploy-kit 1.3.0, the version `toolkit.yml` pins, from this change (1.2.0, which Publish Fragment v0.37.0 packs with, renders the edge's share byte for byte the same): `deploy-kit compose` over every
participant's newest fragment, this branch's Platform and platform fragments
(edge moved to `estate`), `participants.yml`, `cluster-state.yml` and the
committed sources. Compared with `kubectl kustomize` of fleet-infra `main`
(72a449c) `cluster/flux/apps/{core/external-dns,core/ingress-controller,core/lan-ingress-controller,edge}`
and the live objects, read 2026-10-29. NetworkPolicies are rendered but not
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
| API access | chart ClusterRoles `traefik-ingress-system`, `traefik-lan-ingress-lan-system` | ClusterRoles from the `api` this change declares, admitted in `apiAccess.holders`; token mounted | without it the render mounts no token and binds nothing, and the proxy serves nothing (JorisJonkers-dev/deploy-kit#727) |
| TLS | `websecure` TLS on; every route `tls: {}`, the default TLS store `edge-system/default`, cert-manager's wildcard | `websecure` TLS on; public resolver `public-frankfurt` (DNS-01 at Cloudflare, `CF_DNS_API_TOKEN` from `secret/data/platform/cloudflare`, state on the claim `acme`, 16Mi); the LAN proxy has none | `acme` on the public tier, `none` on the LAN tier. A rendered route names the resolver; until each certificate is issued, and for every route still on the old path, the proxy serves the default store's wildcard |
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
change composed, 14 routes render, in 12 Projects' shares: auth, estate-dashboard,
findability-explorer, grimoire, hindsight (3), home-portal, immich, karakeep, n8n,
outline, overleaf and tribelt. Each carries the tier's class, `websecure`, the
external-dns target `ingress.jorisjonkers.dev` proxied, `tls.certResolver:
public-frankfurt`, and an explicit priority of 997 to 999.

| old path route (`edge-system`) | rendered route | differences |
|---|---|---|
| `home-portal`, `tribelt`, `n8n`, `outline`, `overleaf`, `findability-explorer` | `<project>-system/<app>-public` | `PathPrefix(/)` added; `security-headers` (findability-explorer: `security-headers-strict`, `default-src 'self'`) added; resolver instead of `tls: {}` |
| `grimoire`, `immich`, `karakeep`, `hindsight`, `estate-dashboard` | the same, behind `forward-auth` | as above; estate-dashboard gets `security-headers-strict` |
| `hindsight-api`, `hindsight-private` | `hindsight-system/hindsight-api`, `hindsight-private` | the old single rule with `||` becomes three rules by priority; the same paths |
| `auth-api`, `auth-api-well-known`, `auth-ui` | `auth-system/auth-public`, three rules | negative path matches become priorities (`/.well-known/` 999, `/api/` 998, `/` 997); the same backends |
| new | security headers on every rendered route: `X-Frame-Options: DENY`, `nosniff`, a referrer and permissions policy, HSTS one year with subdomains, and a CSP on the strict and admin kinds | derived. **Check** estate-dashboard and findability-explorer under `default-src 'self'` at the live step: inline scripts or styles would break |

Both routes of each host exist from the flip until the old one is deleted. The
rendered one wins on priority (997 to 999 against the old rule length, at most
about 160), and both publish the same record, so neither DNS nor the request
path changes when the old one goes.

**Routes no Project renders yet**, which stay on the old path in
`apps-edge-legacy` (W4) and keep serving through the new proxies, which admit
their class:

- `jellyfin` (unproxied, record at the home address 130.89.174.190,
  JorisJonkers-dev/deploy-kit#711), `jellyfin-lan`, `jellyseerr`,
  `jellyseerr-lan`, `qbittorrent`, `qbittorrent-lan`, `prowlarr`,
  `prowlarr-lan`, `sonarr`, `sonarr-lan`, `radarr`, `radarr-lan`, `bazarr`,
  `bazarr-lan`: their Projects are on the estate path and declare no
  `exposure`;
- `immich-lan`: immich declares its public exposure only;
- `traefik-dashboard` and its redirect: `api@internal` is not rendered, so it
  stops answering either way;
- `stalwart-root-to-admin`, the Middleware mail's route uses until mail's
  exposure renders it.

The routes other Projects' directories apply (agents, observability, data,
utility, mail) leave with their own handovers, which come first in the order.

### The namespace, and what only the render has

- **Namespace `edge-system`** is taken over in place: today `apps-edge` applies
  it, F3 marks it, F4 stops applying it, and the render applies it with
  `app.kubernetes.io/managed-by: deploy-kit`. From then on, deleting the
  estate's `apps-edge` with pruning on would delete it, and with it every route
  `apps-edge-legacy` still holds there.
- **Only in the render:** the claim `acme`, the security-header Middlewares, the
  ServiceMonitors, and the Vault, rollout and policy objects above.

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

# 4. F4 landed: apps-edge is gone, apps-edge-legacy is Ready, the old pods still serve.
kubectl -n flux-system get kustomization apps-edge 2>&1        # NotFound
flux get kustomization apps-edge-legacy
for ns in ingress-system ingress-lan-system external-dns; do kubectl -n "$ns" get pods; done

# 5. Vault holds the token the render reads (names only), signed in as bootstrap/secrets.sh does.
vault kv get -format=json secret/platform/cloudflare | jq -c '.data.data | keys'
#    ["CF_DNS_API_TOKEN"]

# 6. The wildcard the LAN and the old routes serve has time left.
kubectl -n edge-system get secret jorisjonkers-dev-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate
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

   What follows: `edge`'s `vault-policy` Job writes `edge-system-traefik-public`
   and `edge-system-external-dns`; VSO syncs both token Secrets; `traefik-lan`
   starts and its Service `traefik-lan-lan-edge` stays `<pending>`;
   `traefik-public` stays Pending (host ports taken); `external-dns` starts.
   The 12 routed Projects' pins move and their routes appear. Nothing that
   serves changes yet.

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
2. Every public host answers over TLS from outside, and the 12 rendered hosts
   show a certificate issued for that host by Let's Encrypt (`openssl s_client
   -connect <host>:443 -servername <host>`, behind Cloudflare: check
   `traefik-public`'s ACME log instead). hermes and agents-ws, grey-cloud,
   answer on 167.86.79.203 directly.
3. Every LAN route answers on 192.168.0.99 with the wildcard.
4. A gated host (`grimoire.jorisjonkers.dev`) redirects to auth's sign-in, and
   after it, serves: the rendered `forward-auth`.
5. `dig +noall +answer @amber.ns.cloudflare.com <host>` is unchanged for every
   public host, and external-dns's log shows no change planned.
6. estate-dashboard and findability-explorer render fully under their new
   Content Security Policy.

## After the flip

Change C in fleet-infra: drop the 16 replaced route files from
`cluster/flux/apps/edge/`, the edge's fragment drift entries, and the route
tests that read them. Then by hand:

- `edge-system`: IngressRoutes `home-portal`, `tribelt`, `n8n`, `outline`,
  `overleaf`, `findability-explorer`, `grimoire`, `immich`, `karakeep`,
  `hindsight`, `hindsight-api`, `hindsight-private`, `estate-dashboard`,
  `auth-api`, `auth-api-well-known`, `auth-ui` (marked, so nothing prunes them);
- namespaces `ingress-system`, `ingress-lan-system` and `external-dns`, with
  everything left in them;
- cluster-wide: IngressClasses `traefik-public` and `traefik-lan`, ClusterRoles
  and bindings `traefik-ingress-system`, `traefik-lan-ingress-lan-system`,
  `external-dns` and `external-dns-viewer`;
- the `cloudflare.dns_api_token` key in `secret/platform/edge`, once mail reads
  the Cloudflare token from where the estate keeps it.

cert-manager, `letsencrypt-cloudflare`, the wildcard and the default store stay
until JorisJonkers-dev/deploy-kit#726 is decided (W3).

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
`projects/edge/`, then revert F4 and F3. Keep F1 and F2: both hold either way.
Nothing here holds data; the `acme` claim only saves a reissue.
