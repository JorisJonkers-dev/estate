# Bootstrap

What the estate path needs that git cannot hold: two GitHub Apps, their keys,
and the credentials a cluster reads the estate with. Two scripts, split by what
a cluster move repeats. Both walk you through each step, ask before every
write, read back what they wrote, and are safe to re-run.

| script | run | does |
|---|---|---|
| [`github-apps.sh`](github-apps.sh) | once per organization | creates the dispatch and Collector GitHub Apps, puts the dispatch App's id and key in an org variable and secret every repository reads, and the Collector key in Vault |
| [`cluster.sh`](cluster.sh) | once per cluster, and after every move | writes Flux's read access to this repository and its pull access to the render packages, restores the Collector key and the estate-dashboard's OIDC client secret to a fresh Vault, and proves auth and Flux both see them |

## On a new cluster

1. Install Flux and unseal Vault, restoring it if there is a backup:
   `JorisJonkers-dev/fleet-infra`'s `cluster/bootstrap/flux-bootstrap-playbook.md`
   and the Vault playbooks beside it.
2. Run `./bootstrap/cluster.sh` against the new cluster's kubectl context.

The GitHub Apps live on GitHub, so a move does not touch them. A restored Vault
already holds both keys and the client secret, and `cluster.sh` only checks
them; a fresh Vault gets a newly generated Collector key and a newly minted
client secret.

## What they need

`kubectl` on the target cluster, `flux`, `gh` signed in (with `admin:org` for
`github-apps.sh`, which asks for it), `jq`, `curl` and `openssl`, and a Vault
token: Vault is reached through `kubectl exec` into `vault-0`, so no
port-forward. The App ids, which are not secret, are kept in
`~/.config/estate-bootstrap.env` (`ESTATE_ENV_FILE` overrides); no key is ever
written to disk outside a temporary file the script removes.

`lib/wizard.sh` is the shared wizard library, kept verbatim;
[`lib/estate.sh`](lib/estate.sh) is what the two scripts share above it.
