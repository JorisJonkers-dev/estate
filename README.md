# estate

The estate's delivery state: what composition reads and what it records, and
nothing rendered. The model and its rules live in
[JorisJonkers-dev/deploy-kit](https://github.com/JorisJonkers-dev/deploy-kit);
this repository's shape is deploy-kit's `spec/v1/60-setup.md#the-estate-repository`.

| path | what it is | who writes it |
|---|---|---|
| [`platform.intent.yml`](platform.intent.yml) | the Platform document: what the estate offers, and the handover ledger | a human, by pull request |
| [`platform/`](platform/) | the platform's own project files, `<project>.project.yml`: `edge`, `observability`, `secrets` | a human, by pull request |
| [`node-contract.yml`](node-contract.yml) | what each node offers a placement, which the Platform document pins by digest | copied from JorisJonkers-dev/nix-config, which generates it from its node files |
| [`images.lock.yml`](images.lock.yml) | every image the platform's own projects and policies name, by digest and user | a human, by pull request |
| [`participants.yml`](participants.yml) | every Project composition expects a fragment from, and how stale each may be | a human, by pull request |
| [`package.json`](package.json) and its lockfile | the exact deploy-kit release that validates, packs and composes | a human or Renovate, by pull request |
| [`cluster-state.yml`](cluster-state.yml) | the ClusterState snapshot | the Collector |
| the composition lock | the inputs the last composition rendered from | the composition workflow, from its first run |
| [`projects/<project>/source.yaml`](projects/) | one pin per Project on the estate path | the composition workflow |
| [`bootstrap/`](bootstrap/) | the scripts that create the GitHub Apps and a cluster's credentials, which git cannot hold | a human, by pull request |

**A rendered tree is never committed here.** Each Project's render is a signed
OCI artifact at `ghcr.io/jorisjonkers-dev/render/<project>`, and a deploy is a
commit that moves the digest its pin names.

**The Platform publishes like any Project.** Each release of this repository
publishes the Platform document's Intent Fragment, `intent-jorisjonkers.dev`,
and one for each Project in [`platform/`](platform/), through
JorisJonkers-dev/github-workflows' `publish-fragment`
([`release.yml`](.github/workflows/release.yml)). A change to the platform
reaches composition only by a release.

## Reading a delivery

[`compose.yml`](.github/workflows/compose.yml) shows in the Actions tab as
**Deliver to production**, after the cluster the Platform document names. Its
file keeps the name `compose.yml` because that path on `main` is the identity
every render is signed as and Flux verifies against; renaming it is a signer
migration, not a rename.

- **The run title** says why the run started: the release that published, a
  rollback, a resume, or the nightly safety net.
- **The job summary** has one row per Project: the release it ran before the
  run and the one it runs after, whether its pin moved, and, for a Project
  composition refused, the `E_` codes that say what to fix. A composition that
  refused the estate as a whole says what it refused on.
- **The pin commit** names each Project it moves and the release it delivers,
  `chore(deploy): delivery 0.4.0`, with the repository and commit that
  released it in the body.
- **A run fails** when composition isolated any Project (a refused, missing
  or stale fragment), on its last step, so everything else was delivered
  first. Each repository's commit then carries the `estate/production` status,
  and the condition's issue is open here.

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
| `estate-collector` | `contents: write`, on this repository only | the Collector, to commit `cluster-state.yml`; composition, to commit the moved pins and the pin sources it rewrites; and the pause, resume and rollback workflows, to commit a hold. Its key is in Vault, and also the secret `ESTATE_COLLECTOR_APP_PRIVATE_KEY` of this repository's `production` environment, which only `main` deploys to; its id is the variable `ESTATE_COLLECTOR_APP_ID` |

Everything else reaches `main` by pull request. Both Apps, and every
credential a cluster needs to read this repository, are created by
[`bootstrap/`](bootstrap/README.md), which is also what a cluster move reruns.

## Holding a Project

Three workflows, run by hand from the Actions tab on `main`, hold one Project
still, or take it back to an earlier release, without touching its repository
([deploy-kit chapter 55](https://github.com/JorisJonkers-dev/deploy-kit/blob/main/spec/v1/55-delivery.md#pause-and-rollback)).
Pause and resume are one commit each to `projects/<project>/source.yaml`; a
rollback is two.

- [`pause.yml`](.github/workflows/pause.yml) records who paused the Project,
  when and why. Composition still checks its newest fragment and reports what
  it finds, and moves no pin for it.
- [`resume.yml`](.github/workflows/resume.yml) removes the record, a
  Rollback's with it, and starts a delivery, which moves the pin to the
  Project's newest fragment.
- [`rollback.yml`](.github/workflows/rollback.yml) takes a version, and
  refuses it before anything runs unless it is earlier than the pinned release
  and, where that release carries a Migration Proof, the one the proof names
  (found by walking every composition's lock). Its first commit pauses the
  Project and asks for a backup; composition renders one-shot backup Jobs, and
  the run waits up to 45 minutes for the Collector to report in
  `cluster-state.yml` that every Job the render holds succeeded. Only then does
  its second commit record the release, and composition moves the pin there. A
  failed, unexpected or late Job stops it with the pin where it was. Either
  way the Project stays paused until a resume. The dump of the Project's own
  database is not rendered yet (JorisJonkers-dev/deploy-kit#423), so a
  Project with no backed-up volume rolls back with no backup at all.

## Handover

[`platform.intent.yml`](platform.intent.yml)'s `handover` block is the ledger of
which Projects this repository delivers (`estate`) and which `fleet-infra`
still does (`legacy`). A Project moves in three changes, in order: fleet-infra
orphans it, fleet-infra drops it, and only then does the ledger move it here
(deploy-kit `spec/v1/60-setup.md#handing-over-one-project-at-a-time`). The
first to move is home-portal, in the `app` Project.
