# Bootstrap

What the estate needs that git cannot hold: three GitHub Apps, their keys,
every secret a person puts in Vault, and the credentials a cluster reads the
estate with. Three scripts, split by what a cluster move repeats, and a fourth
that removes from Vault what nothing uses any more. Each walks
you through each step, asks before every write, reads back what it wrote, and
is safe to re-run.

| script | run | does |
|---|---|---|
| [`github-apps.sh`](github-apps.sh) | once per organization | creates the dispatch, Collector and Reporter GitHub Apps, puts the dispatch App's id and key in an org variable and secret every repository reads, hands the Collector's and the Reporter's new keys to `secrets.sh` for Vault, and puts the Collector key in the estate repository's `production` environment, which only `main` deploys to and no administrator bypasses, for composition's pin commit |
| [`secrets.sh`](secrets.sh) | once per cluster, after a restore, and whenever a value is added or replaced | every secret a person writes to Vault, one section each: the roles fleet-infra's `vault-bootstrap-auth` Job and deploy-kit's Vault policy job log in as, the metrics token, the Discord webhook, the Collector and Reporter keys, the OIDC client secrets (estate-dashboard, tribelt, grimoire, findability-explorer) in both the copy auth-api reads and the app's own, the keys of Overleaf, Hermes, Hindsight and Karakeep, Stalwart's recovery admin, and the off-cluster backup credential. It checks each, skips what is already right, and stops only where a value is missing or wrong; after a client secret changes it restarts auth-api once and proves every client at the token endpoint |
| [`cluster.sh`](cluster.sh) | once per cluster, and after every move | writes Flux's read access to this repository and its pull access to the render packages, applies Flagger's and MetalLB's CRDs, and proves Flux sees the estate |
| [`retire.sh`](retire.sh) | once per retirement an issue decides | deletes what Vault still holds for something nothing uses: today the `downloads` role and policy (#227). It checks again, read-only and live, that nothing uses them, shows what it deletes, asks, and reads back that it is gone; a retirement already done is skipped |

## On a new cluster

1. Install Flux and unseal Vault, restoring it if there is a backup:
   `JorisJonkers-dev/fleet-infra`'s `cluster/bootstrap/flux-bootstrap-playbook.md`
   and the Vault playbooks beside it.
2. Run `./bootstrap/secrets.sh` against the new cluster's kubectl context. On a
   Vault initialised minutes ago there is no OIDC sign-in yet, so paste the
   root token when it asks. It writes the role the Vault policy job logs in as
   before the first render arrives.
3. Run `./bootstrap/cluster.sh`.
4. Once auth-api runs, run `./bootstrap/secrets.sh` again: everything it wrote
   is skipped, and it proves each OIDC client against auth-api.

The GitHub Apps live on GitHub, so a move does not touch them. A restored Vault
already holds the keys and client secrets, and `secrets.sh` only checks them; a
fresh Vault gets newly generated Collector and Reporter keys and newly minted
client secrets.

## secrets.sh

```bash
./bootstrap/secrets.sh                                   # check everything, fix what is missing
./bootstrap/secrets.sh --list                            # the sections
./bootstrap/secrets.sh --only findability-explorer       # one section (comma-separate several)
./bootstrap/secrets.sh --only tribelt --rotate           # a new client secret; restarts auth-api
./bootstrap/secrets.sh --only hermes --replace           # rewrite the document, dropping what is not offered
./bootstrap/secrets.sh --only overleaf --rollback        # back to an earlier KV version
./bootstrap/secrets.sh --only mail                       # Stalwart's user:password pair, from its admin login
./bootstrap/secrets.sh --only data                       # the data Project's catalog and backup logins, copied
./bootstrap/secrets.sh --only backup-off-cluster         # the S3 key pair irreplaceable backups copy off-cluster with
./bootstrap/secrets.sh --only grimoire --rerun-garage-bootstrap
./bootstrap/secrets.sh --only discord-webhook --rotate --test-alert
```

`--rotate` replaces values that are present; it never touches a key whose
rotation breaks stored state (a session key, a VAPID or S3 pair), which is
only ever minted where missing. `--restart-auth-api` restarts auth-api even
when no secret changed, for a client registered by an auth-api release after
its secret was written. The `garage-keys`, `agents-github-app` and
`agents-deploy-key` sections are optional: a full run reports them, and only
`--only` acts on them.

Keys deploy-kit generates (a `generate:` key in a project file, written once by
the Vault policy job) are never written here; `secrets.sh` only reports
whether they exist yet: tribelt's `secret/tribelt-system/keys`
(`session_key`, `visitor_hmac_key`) and the Findability Explorer's
`secret/findability-explorer-system/session` (`key`, its `SESSION_KEY`).

**Vault sign-in.** `secrets.sh` port-forwards to `svc/vault` in `data-system`
on a free local port and points the local `vault` CLI at it. It then uses a
`VAULT_TOKEN` already in the environment if Vault accepts it; otherwise it
signs in with OIDC (`vault login -method=oidc`): a browser opens on auth-api,
and the CLI catches the callback on `localhost:8250`, which auth-api's `vault`
client allows. The token stays in the process and is revoked on exit. Without
OIDC (a Vault initialised minutes ago) it takes a valid `~/.vault-token`, or a
token you paste. `ESTATE_VAULT_OIDC_ROLE` and `ESTATE_VAULT_OIDC_PATH` name a
role and mount other than Vault's default role on `oidc/`.

**A dry run.** `ESTATE_VAULT_ADDR` points at a Vault directly and skips every
cluster step and every live check, for a throwaway `vault server -dev`:

```bash
vault server -dev -dev-root-token-id=root -dev-listen-address=localhost:18299 &
VAULT_ADDR=http://localhost:18299 VAULT_TOKEN=root vault auth enable kubernetes
printf x | VAULT_ADDR=http://localhost:18299 VAULT_TOKEN=root vault kv put -mount=secret auth-api placeholder=-
ESTATE_VAULT_ADDR=http://localhost:18299 VAULT_TOKEN=root ESTATE_ENV_FILE=/tmp/estate.env ./bootstrap/secrets.sh
```

## retire.sh

```bash
./bootstrap/retire.sh --list         # the retirements
./bootstrap/retire.sh downloads      # one
```

Not a `secrets.sh` section: `secrets.sh` puts values in a Vault and reruns on
every new cluster, and a fresh Vault never holds what is retired. A retirement
deletes only what is still exactly what its issue found. It refuses a role that
binds anything more, a policy that grants anything more, a policy anything
else in Vault hands out (any auth role, token role, identity group or entity),
and anything the cluster could still log in with. A read that fails stops the
run and never passes for "absent". It signs in to Vault the way `secrets.sh`
does, and `ESTATE_VAULT_ADDR` gives it the same dry run.

## What they need

`kubectl` on the target cluster, `flux`, `gh` signed in (with `admin:org` for
`github-apps.sh`, which asks for it), `jq`, `curl`, `openssl`, the `vault`
CLI, and bash 4 or newer (`brew install bash` on macOS). Every secret reaches
Vault on stdin, never as an argument, and is shown only as a 12-character
SHA-256 fingerprint. The App ids, which are not secret, are kept in
`~/.config/estate-bootstrap.env` (`ESTATE_ENV_FILE` overrides); no key is ever
written to disk outside a temporary file the script removes.

`lib/wizard.sh` is the shared wizard library, kept verbatim;
[`lib/estate.sh`](lib/estate.sh) is what the scripts share above it: the Vault
connection and sign-in, and the KV reads and writes.
