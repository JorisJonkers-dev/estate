# Pins

One directory per Project on the estate path, each holding one file,
`source.yaml`: an `OCIRepository` naming the Project's Rendered artifact by
`ref.digest` and verifying its keyless signature against the composition
workflow, and one `Kustomization` per Reconcile Unit applying its path
(deploy-kit `spec/v1/55-delivery.md#rendered-artifacts-and-pins`).

Flux reads this directory through the `flux-system/platform` GitRepository and
applies every manifest under it. Composition writes a Project's file the first
time the Project composes and afterwards moves only its `ref.digest`; that
commit is the deploy. Pause and Rollback annotate the `OCIRepository`; nothing
else edits these files by hand.

`_canary/` is the bootstrap's proof of the signature check, not a Project:
the underscore keeps it from ever naming one, as it does for `_estate`.

A rendered tree never lands here: the Rendered artifact is the render.
