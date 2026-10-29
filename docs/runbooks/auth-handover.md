# Handing `auth` over to the estate path

Moves the Project `auth` (auth-api and auth-ui, namespace `auth-system`) from
fleet-infra's old path to its pin here, on deploy-kit 0.31, in the three changes of
deploy-kit `spec/v1/60-setup.md#handing-over-one-project-at-a-time`. Tracking:
JorisJonkers-dev/auth-api#80, under the handovers epic #204.

The decision behind it (2026-10-23): auth-api is handed over as it is, now, before
deploy-kit 1.0, without the gate-run migration auth-api#80 first described
(`migration: self` stays) and without waiting for identity to replace it.

Every sign-in, and every route behind forward-auth, goes through auth-api. Run this
with the operator present, at a quiet hour.

## The changes, in order

| # | where | what | outage |
|---|---|---|---|
| A1 | fleet-infra, PR "orphan the auth Project" | every auth object gets `prune: disabled`; the auth-ui Service gains port 8080 and the route names it | none |
| A2 | fleet-infra, PR "drop the auth Project's manifests" | the manifests leave `apps-stateless`; the three routes move unchanged to `apps-edge` | none |
| A3 | auth-ui PR, then its release | the unprivileged nginx on 8080, uid 101 | none (nothing deploys it yet) |
| A4 | auth-api PR, then its release | env files, non-root image (uid 65532), auth-ui on 8080; publishes the fragment | none (`auth` is still `legacy`) |
| B | this repository, PR "hand auth over", then its release | the ledger moves `auth` to `estate`; the collector's `serving` location | see [Expected outage](#expected-outage) |
| C | fleet-infra, PR "grant the old auth-api role only what auth-api reads itself" | drops the injector-only paths from the `auth-api` Vault policy | none |

A1 and A2 must land, and be reconciled, **before** A3 and A4 release anything:
fleet-infra's auto-bump merges first-party image pins on its own, and the new
auth-ui image listens on 8080 while the old path's Deployment declares 80.
A3 must release before A4: auth-api's publish locks auth-ui's latest release,
and it now refuses a root image.

## Pre-checks

Run each; each must print what it says. Nothing here writes.

```sh
# 1. Flux is healthy, and auth runs where the old path put it.
flux get kustomizations -A | grep -v -E 'True' || echo "all Ready"
kubectl -n auth-system get deploy,pods -o wide

# 2. A1 reached the live objects: every auth object carries the mark.
kubectl -n auth-system get deploy,svc,pdb,sa,servicemonitor -o json \
  | jq -r '.items[] | "\(.kind)/\(.metadata.name) \(.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] // "UNMARKED")"'
kubectl -n edge-system get ingressroute auth-api auth-api-well-known auth-ui -o json \
  | jq -r '.items[] | "\(.metadata.name) \(.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] // "UNMARKED")"'
kubectl get ns auth-system -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}'
#    every line says "disabled".

# 3. A2 landed: apps-stateless no longer lists them, they still run, and apps-edge
#    owns the routes.
kubectl -n flux-system get kustomization apps-stateless -o json \
  | jq -r '.status.inventory.entries[].id' | grep -c auth-system   # 0
kubectl -n edge-system get ingressroute auth-ui -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{" "}{.spec.routes[0].services[0].port}{"\n"}'
#    "apps-edge 8080"

# 4. The fragment composed: the last "Deliver to production" run after A4 lists
#    auth at the new release with no E_ code, and the auth-ui image in its lock is
#    not root.
gh run list -R JorisJonkers-dev/estate --workflow compose.yml --limit 3
oras pull ghcr.io/jorisjonkers-dev/intent-auth:latest --output /tmp/intent-auth \
  && yq '.images[] | [.repository, .version, .uid] | join(" ")' /tmp/intent-auth/images.lock.yml
#    auth-api <new> 65532, auth-ui <new> 101

# 5. Vault holds every key the render reads (names only, never values). Port-forward
#    and log in as in deploy-kit HANDOVER.md, "Vault from the Mac".
for p in auth-api platform/postgres platform/rabbitmq platform/mail; do
  echo "$p: $(vault kv get -format=json secret/$p | jq -c '.data.data | keys')"; done
#    secret/auth-api lists all eight auth.clients.<client>.secret keys: estate-dashboard,
#    findability-explorer, grafana, grimoire, n8n, outline, tribelt, vault. A key that is
#    missing fails the pod at start (the render reads each with secretKeyRef, not
#    optional), where the injector rendered it empty.
vault read -format=json auth/kubernetes/role/auth-api | jq -c '.data | {bound_service_account_names, bound_service_account_namespaces, token_policies}'
vault policy read auth-api | grep -E 'transit/keys/auth-api-jwt|database/creds/auth-api'
#    the old role still binds auth-api in auth-system: auth-api keeps logging in with it.

# 6. The catalog can adopt auth_db (deploy-kit derives an auth_db entry with owner
#    auth-owner once auth is on the estate path). Run in your own terminal with `!`:
kubectl -n data-system exec deploy/postgres -c postgres -- psql -U postgres -At -c "
select d.datname, pg_get_userbyid(d.datdba) as owner,
       (select count(*) from pg_database o where o.datdba = d.datdba and o.datname <> d.datname) as other_dbs,
       r.rolsuper or r.rolcreaterole or r.rolcreatedb or r.rolreplication or r.rolbypassrls as privileged
from pg_database d join pg_roles r on r.oid = d.datdba where d.datname = 'auth_db';"
#    owner auth_user (or whatever secret/platform/postgres#auth.user names), other_dbs 0,
#    privileged f. Anything else: the catalog Job refuses auth_db and estate-vso-secrets
#    stays not Ready; stop here.

# 7. Room for the new pods. Each auth-api pod requests 4Gi now (2Gi on the old path),
#    and the first apply runs the target and Flagger's primary side by side: four
#    new 4Gi pods on frankfurt-contabo-1, enschede-t1000-1 and enschede-gtx-960m-1.
kubectl describe node frankfurt-contabo-1 enschede-t1000-1 enschede-gtx-960m-1 \
  | grep -E '^Name:|^  memory'
#    at least 16Gi of unrequested memory across the three.
```

## Cutover

Set a terminal per watcher first:

```sh
kubectl -n auth-system get pods -w -o wide
kubectl -n auth-system get canary -w
while sleep 5; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code}\n' https://auth.jorisjonkers.dev/.well-known/openid-configuration; done
```

1. **Keep the old pods serving through the recreate.** The first pin marks every
   Deployment `kustomize.toolkit.fluxcd.io/force: Enabled`, because the render's
   selector (`name` + `instance`) differs from the old one (`name`), so Flux deletes
   and recreates each Deployment, and by default its pods with it. Delete the two
   Deployments now, without their ReplicaSets:

   ```sh
   kubectl -n auth-system delete deployment auth-api auth-ui --cascade=orphan
   kubectl -n auth-system get rs,pods -l 'app.kubernetes.io/name in (auth-api,auth-ui)'
   ```

   Both ReplicaSets keep their pods; the Services still select them. Nothing applies
   these objects since A2, so nothing recreates the Deployments until the pin does.
   The new Deployments' selectors do not match the orphaned ReplicaSets (no
   `instance` label), so they never adopt them.

2. **Merge B** (this repository), then the release PR release-please opens for it.
   The release publishes the Platform document and dispatches composition. Watch it:

   ```sh
   gh run watch -R JorisJonkers-dev/estate "$(gh run list -R JorisJonkers-dev/estate --workflow compose.yml --limit 1 --json databaseId -q '.[0].databaseId')"
   git -C <estate checkout> pull && ls projects/auth/source.yaml
   flux reconcile kustomization estate-pins -n flux-system --with-source
   flux get kustomization apps-auth -n flux-system --watch
   ```

3. **What happens, in order** (each step is a watch, not an action):
   - `vault-policy` Job in auth-system completes: the policy and role
     `auth-system-auth-api` exist.
     `kubectl -n auth-system get job -l app.kubernetes.io/name=vault-policy`
   - VSO syncs four Secrets: `auth-api-auth-api`, `auth-api-platform-mail`,
     `auth-api-platform-postgres`, `auth-api-platform-rabbitmq`.
     `kubectl -n auth-system get vaultstaticsecret,secret`
   - Deployments `auth-api` (2 pods, cold start 150–300 s) and `auth-ui` start. Their
     pods carry `app.kubernetes.io/name: auth-api`, so the Service sends them traffic
     beside the old pods once they are Ready.
   - Flagger initialises each Canary: it creates `auth-api-primary` and
     `auth-ui-primary`, waits for them Ready (another cold start), then points the
     Services `auth-api` and `auth-ui` at `<name>-primary` (it rewrites the selector
     and ports of a Service it did not create) and scales the target to 0.
     `kubectl -n auth-system get svc auth-api auth-ui -o jsonpath='{range .items[*]}{.metadata.name} {.spec.selector} {.spec.ports}{"\n"}{end}'`
     shows `app.kubernetes.io/name: auth-api-primary` on 8081 and `auth-ui-primary` on 8080.
   - `apps-auth` goes Ready. The units that follow it (`apps-grimoire`, `apps-n8n`,
     `apps-outline`, `apps-tribelt`, `apps-estate-dashboard`) gain `dependsOn: apps-auth`
     in the same composition; until `apps-auth` is Ready they hold their next change,
     but nothing they run stops.

4. **Remove what the old path left**, once both Canaries are `Initialized` and the
   Services select the primaries:

   ```sh
   kubectl -n auth-system get rs -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,READY:.status.readyReplicas
   #   the two with OWNER <none> are the old ones
   kubectl -n auth-system delete rs <old auth-api rs> <old auth-ui rs>
   kubectl -n auth-system delete servicemonitor auth-api   # the PodMonitor scrapes now
   kubectl -n auth-system delete pdb auth-ui               # protected one old pod; the render has none for auth-ui
   kubectl -n auth-system delete secret ghcr-creds         # only if nothing references it: kubectl -n auth-system get pods -o json | jq '[.items[].spec.imagePullSecrets] | flatten'
   ```

5. **Merge C** (fleet-infra), and confirm the bootstrap Job re-ran.

## Expected outage

- **With step 1:** none expected. The old pods serve until Flagger switches each
  Service to a Ready primary, and only then are they deleted. The Service never has
  zero Ready endpoints.
- **Without step 1** (Flux recreated the Deployments first): from the deletion until
  the new `auth-api` pods are Ready, which is the vault-policy Job (about 1 min), the
  VSO sync, and a JVM cold start (150–300 s): **3 to 6 minutes** in which sign-in, the
  OIDC endpoints and every forward-auth route fail. auth-ui recovers in under a
  minute. Nothing else in deploy-kit's model shortens it: the selector is immutable,
  the force mark is the model's, and Flagger keeps the old Service only as long as
  something it selects is Ready.

## Verification

```sh
# OIDC discovery, anonymously, and the issuer it names
curl -s https://auth.jorisjonkers.dev/.well-known/openid-configuration | jq -r .issuer   # https://auth.jorisjonkers.dev
curl -s https://auth.jorisjonkers.dev/api/oauth2/jwks | jq '.keys | length'            # >= 1: the transit key was read

# forward-auth: anonymous is sent to sign in, a session passes
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://bazarr.jorisjonkers.dev/    # a forward-auth host: 302 to auth.jorisjonkers.dev/login
#   then, in a browser signed in, the same host answers 200

# No injector on the auth pods, and the new posture
kubectl -n auth-system get pods -o json | jq -r '.items[] | "\(.metadata.name) inject=\(.metadata.annotations["vault.hashicorp.com/agent-inject"] // "none") uid=\(.spec.securityContext.runAsUser) containers=\([.spec.containers[].name]|join(","))"'
#   inject=none, uid 65532 (auth-api) / 101 (auth-ui), no vault-agent container

# auth-api read Vault itself: no 403 on transit or the database login
kubectl -n auth-system logs deploy/auth-api-primary | grep -E '403|permission denied|Started AuthApi' | grep -v 'secret/application'
#   only "Started AuthApiApplicationKt"; the two secret/application 403s are as today
```

Sign in through each OIDC client in a browser:

| client | check |
|---|---|
| grafana | `https://grafana.jorisjonkers.dev`: "Sign in with" auth, lands signed in |
| n8n | `https://n8n.jorisjonkers.dev`: its SSO sign-in completes |
| outline | `https://notes.jorisjonkers.dev`: sign-in completes |
| tribelt | `https://tribelt.jorisjonkers.dev/stats`: OIDC flow returns to /stats |
| estate-dashboard | `https://estate.jorisjonkers.dev`: signed in |
| findability-explorer | `https://digital-strategy.jorisjonkers.dev`: signed in |

And the mail path: register a throwaway address on `https://auth.jorisjonkers.dev`
(or request a password reset for a test account) and see the confirmation mail
arrive; `kubectl -n auth-system logs deploy/auth-api-primary | grep -i mail` shows no
`AuthenticationFailed`.

Then: traces for `service.name=auth-api` appear in Tempo again (through alloy's
OTLP gRPC receiver on 4317), `up{job="auth-api"}` is 1 for two targets in
Prometheus, and the GitHub Deployment on auth-api for the release is `success`.

## Rollback

deploy-kit chapter 60 reversed. Only the old path's objects come back; data is never
touched. The catalog's adoption of `auth_db` is not undone and does not need to be:
`auth_user` stays a member of `auth-owner`, so it keeps every privilege.

1. **Stop the estate path from pruning auth.** In this repository, a commit setting
   `spec.prune: false` on the `apps-auth` Kustomization in `projects/auth/source.yaml`
   (the one hand edit of a pin file, which only an undo makes). Reconcile
   `estate-pins` and confirm `kubectl -n flux-system get kustomization apps-auth -o jsonpath='{.spec.prune}'` is `false`.
2. **Remove it from the estate path.** One commit: delete `projects/auth/`, and move
   `auth` back from `estate` to `legacy` in `platform.intent.yml` (the collector's
   `serving` location may stay). Reconcile `estate-pins`; `apps-auth` is deleted and,
   with prune off, deletes nothing.
3. **Return it to the old path.** Revert C first if it merged (the injector needs
   platform/mail, platform/postgres and platform/rabbitmq again). Then, to keep a pod
   serving:
   - `kubectl -n auth-system delete deployment auth-api auth-ui --cascade=orphan`
     (the primaries' pods keep serving through the Flagger-managed Services; the
     targets are at 0);
   - revert A2 in fleet-infra. `apps-stateless` recreates the old Deployments and
     Services: the Services' selectors go back to `app.kubernetes.io/name: auth-api`
     at once, so sign-in is down for one cold start (3 to 5 min) unless the revert is
     split, Deployments first and Services after their pods are Ready;
   - revert A1 once the old pods are Ready.
4. **Clean up what the estate path left**, all orphaned by step 1:
   `kubectl -n auth-system delete canary,hpa,vaultauth,vaultstaticsecret,vaultconnection,podmonitor,cronjob,job --all`,
   the Deployments `auth-api-primary` and `auth-ui-primary` (`--cascade=orphan` until
   the old pods are Ready), the Services `*-primary`, `*-canary` and the four
   ExternalName aliases. The Vault policy and role `auth-system-auth-api` may stay.

## Gaps this handover works around

- **Root images are rendered beside `runAsNonRoot`.** deploy-kit 0.31 renders the
  lock's uid 0 as `runAsUser: 0` with `runAsNonRoot: true`, which the kubelet refuses.
  Both images now run non-root, and auth-api's publish refuses a root image.
- **No transit read.** deploy-kit declares `sign|verify|encrypt|decrypt|rotate`, but
  auth-api reads `transit/keys/auth-api-jwt` for its JWKS. auth-api keeps logging in
  to Vault as the old role `auth-api`, which fleet-infra's bootstrap still writes.
- **No collector on the estate path.** `telemetry.collector` names
  `observability/otel-collector`, which runs nowhere; the `serving` location points it
  at alloy, and auth-api exports over gRPC.
- **The forward-auth address in the Platform document** (`/api/auth/forward`) is not
  the live one (`/api/v1/auth/verify`, estate#200). It changes nothing here: the
  Middleware stays in fleet-infra until `edge` is handed over.
