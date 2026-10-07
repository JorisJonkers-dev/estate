# Rulesets

[`main.json`](main.json) is the ruleset on `main`, committed for review. GitHub
does not read it from here: a repository admin applies it, and re-applies it
after any change to this file.

```bash
gh api -X POST repos/JorisJonkers-dev/estate/rulesets --input .github/rulesets/main.json
# or, once it exists, update it in place:
gh api -X PUT repos/JorisJonkers-dev/estate/rulesets/<id> --input .github/rulesets/main.json
```

Everything a human changes reaches `main` by a squash-merged pull request.
The only bypass actors are the two GitHub Apps ([`bootstrap/`](../../bootstrap/README.md)):

| actor_id | App | why it bypasses |
|---|---|---|
| 5165539 | `estate-dispatch` | holds `contents: read` only, so its bypass can push nothing; listed because the issue that set this repository up names both Apps |
| 5165602 | `estate-collector` | commits `cluster-state.yml` directly, as the Collector does on every changed snapshot, and composition's pin commit, marked `[ci skip]` (deploy-kit `spec/v1/55-delivery.md#rendered-artifacts-and-pins`) |

There are no required status checks: this repository's only workflows are
its release and composition, neither of which runs on a pull request.
