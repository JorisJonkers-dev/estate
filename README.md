# estate

The estate's delivery state: what composition reads and what it records, and
nothing rendered. The model and its rules live in
[JorisJonkers-dev/deploy-kit](https://github.com/JorisJonkers-dev/deploy-kit);
this repository's shape is deploy-kit's `spec/v1/60-setup.md#the-estate-repository`.

| path | what it is | who writes it |
|---|---|---|
| [`platform.intent.yml`](platform.intent.yml) | the Platform document: what the estate offers, and the handover ledger | a human, by pull request |
| [`platform/`](platform/) | the platform's own project files, `<project>.project.yml`: `edge`, `observability`, `secrets` | a human, by pull request |
| [`cluster-state.yml`](cluster-state.yml) | the ClusterState snapshot | the Collector |
| the composition lock | the inputs the last composition rendered from | the composition workflow, from its first run |
| [`projects/<project>/source.yaml`](projects/) | one pin per Project on the estate path | the composition workflow |
| [`bootstrap/`](bootstrap/) | the scripts that create the GitHub Apps and a cluster's credentials, which git cannot hold | a human, by pull request |

**A rendered tree is never committed here.** Each Project's render is a signed
OCI artifact at `ghcr.io/jorisjonkers-dev/render/<project>`, and a deploy is a
commit that moves the digest its pin names.

## How Flux reads it

Flux's controllers are still owned by `JorisJonkers-dev/fleet-infra`, which
delivers every Project not yet handed over. Its `flux-system` declares one more
source, `GitRepository flux-system/platform`, reading this repository's `main`
with a read-only deploy key, and a Kustomization, `estate-pins`, applying
[`projects/`](projects/) and nothing else. Each pin is an `OCIRepository` that
verifies its artifact keyless against
[`compose.yml`](.github/workflows/compose.yml) on `main` before anything
applies, pulled with the `flux-system/render-pull` credential.

## Who can write

Two GitHub Apps reach this repository, each through short-lived installation
tokens, and they are the only actors that bypass `main`'s ruleset:

| App | permissions | used by |
|---|---|---|
| `estate-dispatch` | `actions: write`, `contents: read`, `statuses: write`, on every repository | an application repository's publish workflow, to start composition; composition, to report a commit status |
| `estate-collector` | `contents: write`, on this repository only | the Collector, to commit `cluster-state.yml`; its key is in Vault |

Everything else reaches `main` by pull request. Both Apps, and every
credential a cluster needs to read this repository, are created by
[`bootstrap/`](bootstrap/README.md), which is also what a cluster move reruns.

## Handover

[`platform.intent.yml`](platform.intent.yml)'s `handover` block is the ledger of
which Projects this repository delivers (`estate`) and which `fleet-infra`
still does (`legacy`). A Project moves in three changes, in order: fleet-infra
orphans it, fleet-infra drops it, and only then does the ledger move it here
(deploy-kit `spec/v1/60-setup.md#handing-over-one-project-at-a-time`). The
first to move is home-portal, in the `app` Project.
