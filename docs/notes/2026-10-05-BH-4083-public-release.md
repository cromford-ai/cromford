# The public copy, cromford-ai/cromford, is built and armed by a secret (BH-4083)

Doc: MIRROR-NOTES, SELF-HOST

## What changed

- `bin/publish-share.sh` force-pushes to a `--repo` ending in `-share`, as
  before, or to a repo listed by exact line in the new
  `catalog/share-publish-targets.conf`. The list holds one line,
  `cromford-ai/cromford`. Any other name still exits 2 before the clone, and the
  "is a remote of this checkout" refusal applies to both shapes. The list is a
  repo file on purpose: adding a force-push target goes through a reviewed PR,
  never a settings write.
- `.github/workflows/publish-cromford.yml` runs that publisher against
  `cromford-ai/cromford` on every push to main. Its first step reads the
  `CROMFORD_DEPLOY_KEY` secret. With no secret it prints
  `CROMFORD_DEPLOY_KEY not set: not configured, nothing pushed`, exits 0, and
  every later step is skipped. Merging it publishes nothing; adding the secret
  is the decision to go public.
- The sanitized tree (the share mirror and the public copy use the same one)
  now carries `LICENSE` (Apache 2.0), `NOTICE`, issue forms under
  `.github/ISSUE_TEMPLATE/`, and its own `.github/workflows/ci.yml`: `bash -n`
  on every script, shellcheck through `bin/ci-shellcheck.sh` on the files
  upstream lints, the shipped leak guard, and pinned gitleaks. It needs no
  secrets and no repo variables.
- `harness-ci.yml`, `harness-nightly.yml`, `prequeue-gate.yml` and
  `publish-cromford.yml` are dropped from the sanitized tree: they need the
  `CI_RUNNER` fleet, the merge queue or secrets a fork doesn't have.
- The mirror's `CONTRIBUTING.md` gains a "CI on this copy" section through a
  sanitize `PATCHES` entry, not an overlay file, so upstream edits keep
  reaching it.
- `bin/share/mapping.py` rewrites the project-15 forms (`project-15-backstage`, the
  org-qualified repo, the joined handle and the research-org name) to
  `project-15` placeholders instead of only refusing them.

## Not in this change: watching the public issue board

The ticket also asks for a public issue board the harness watches. That is not
shipped here, because registering `cromford-ai/cromford` in `fleet.conf` today
would do more than watch it:

- `bin/review-prs.sh` reviews every open, non-draft PR from any author, fork
  PRs included (`gh_rest_pr_list_all`, "external PRs are the point"). It posts
  the review on the PR, and an APPROVE at tier 1 merges it. On a public repo
  that is a paid model review of a stranger's diff, posted in public, with a
  merge path.
- There is no per-project triage-only mode. "Never build here" would live only
  in a prompt. `trigger.actors.<project> = off` does not block builds: `off`
  means no allowlist, which falls back to allowing a human labeller, and an
  issue with no `ai-build` event passes as `no-trigger`.

The follow-up needs a mechanical watch-only switch, enforced by review-prs,
merge-queue and run-build, before the row is added.

## Still owed by a human

- Create a write deploy key on `cromford-ai/cromford` and add its private half
  as the `CROMFORD_DEPLOY_KEY` Actions secret here. That is the first public push.
- Confirm `cromford-ai/cromford` exists and its main can be overwritten.
- After the first push, check that the public repo's `CI` run is green.

## Suites

`tests/share-publish-clean.project-15.bh-4083-test.sh`,
`tests/publish-target-guard.bh-4083-test.sh`,
`tests/public-ci-green.bh-4083-test.sh`.
