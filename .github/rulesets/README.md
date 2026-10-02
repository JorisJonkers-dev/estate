# Rulesets

[`main.json`](main.json) is the ruleset on `main`, committed for review. GitHub
does not read it from here: a repository admin applies it, and re-applies it
after any change to this file.

```bash
gh api -X POST repos/JorisJonkers-dev/estate/rulesets --input .github/rulesets/main.json
# or, once it exists, update it in place:
gh api -X PUT repos/JorisJonkers-dev/estate/rulesets/<id> --input .github/rulesets/main.json
# composition's pin pull requests merge themselves:
gh api -X PATCH repos/JorisJonkers-dev/estate -F allow_auto_merge=true -F allow_squash_merge=true
```

Everything reaches `main` by a squash-merged pull request, including
composition's pin commits, which it opens and auto-merges. The only bypass
actors are the two GitHub Apps ([`bootstrap/`](../../bootstrap/README.md)):

| actor_id | App | why it bypasses |
|---|---|---|
| 5165539 | `estate-dispatch` | holds `contents: read` only, so its bypass can push nothing; listed because the issue that set this repository up names both Apps |
| 5165602 | `estate-collector` | commits `cluster-state.yml` directly, as the Collector does on every changed snapshot |

There are no required status checks yet: this repository has no CI until
composition lands.
