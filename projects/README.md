# Pins

One directory per Project on the estate path, each holding one file,
`source.yaml`: an `OCIRepository` naming the Project's Rendered artifact by
`ref.digest` and verifying its keyless signature against the composition
workflow, and one `Kustomization` per Reconcile Unit applying its path
(deploy-kit `spec/v1/55-delivery.md#rendered-artifacts-and-pins`).

Flux reads this directory through the `flux-system/platform` GitRepository and
applies every manifest under it. Composition writes a Project's file whole
whenever its pin moves, naming the new `ref.digest`; that commit is the deploy.
It also writes the file while the pin stays, at the digest it already names,
when the committed one no longer says what composition derives: the Platform
document's repository, signer or pull Secret changed, or a unit it follows
joined the estate path. That commit deploys nothing
(deploy-kit `spec/v1/55-delivery.md#what-a-pin-source-holds`). Pause and
Rollback annotate the `OCIRepository`; nothing else edits these files by hand.

`_canary/` is the bootstrap's proof of the signature check, not a Project:
the underscore keeps it from ever naming one, as it does for `_estate`.

A rendered tree never lands here: the Rendered artifact is the render.
