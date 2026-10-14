# The public repo appends releases and reads as Cromford (BH-4901)

Doc: OPERATOR-SETUP, SELF-HOST

## What changed

- `bin/publish-share.sh` no longer force-pushes. It clones the published main,
  and when the sanitized tree differs from the published head's tree it commits
  that tree with the published head as the only parent, then runs a plain
  `git push`. An unchanged tree still makes no commit. An empty target gets a
  root commit. A real publish that cannot read the published head (auth,
  network, missing repo) now refuses with rc 1 instead of pushing a commit with
  no parent. `--dry-run` keeps going in that case, because
  `tests/public-ci-green.bh-4083-test.sh` runs it with a dummy token. A push
  that is not a fast-forward is refused by git, and the next run appends to the
  new head. This applies to every target, the `-share` mirror included.
- `--force` now means "commit and push even when the tree is unchanged". The
  result is a new commit with the same tree, still a fast-forward.
- The release commit message comes from the new `bin/share/release_message.py`:
  `Cromford <YYYY.MM.DD> (upstream <sha12>)`, plus an optional one-line
  `--summary`. It refuses any word in `mapping.RELEASE_MESSAGE_FORBIDDEN`
  ("sanitized", "mirror", "private", "client", "upstream history") and any
  `NAME_TOKENS` entry, and names only the class in its refusal. The publisher
  then runs `leakcheck.py` and `gitleaks-gate.py` over the message.
- Branding: `mapping.BRANDING` is a fail-loud `(path, old, new)` table applied
  after `PATCHES`. The README is titled `# Cromford` and links
  https://cromford.dev, and the console title and `docs/SELF-HOST.md` heading
  say Cromford. Paths, script names, env vars and the `cromford` project
  id are unchanged.
- `sanitize.py` refuses a tree whose README heading is not `# Cromford`, that
  still has `docs/MIRROR-NOTES.md`, or whose `PUBLIC_DOC_FILES` carry a
  `PUBLIC_DOC_FORBIDDEN` phrase. The refusal names the file.
- Overlay: `docs/MIRROR-NOTES.md` is replaced by `docs/ABOUT.md`, and a new
  `CONTRIBUTING.md` replaces the upstream one in the public tree (so patch 0d
  is gone). `NOTICE`, the overlay CI header and the shipped guard's header no
  longer describe the repo as a copy of a private one.
- `docs/OPERATOR-SETUP.md` says the console backend is not in the repository
  yet and will be published as its own repository.

## Why

the operator wants `cromford-ai/cromford` ready to go public. The old commit message
was on every file in GitHub's file view and described the repo as a copy of a
private one. The force-push left the repo with no history, and forks broke on
every update.

## Console backend

Decision: a follow-up ticket publishes the Mission Control backend
(`cromford-console`) as its own repository through the same sanitize and
guard pipeline. It is not folded into this publish. The workflow has no
credential that can read a second repo, the backend carries identifiers
`mapping.py` has never been reviewed against, and it has its own history. The
follow-up could not be filed from the build box (no GitHub API access), so the
PR carries it as a `NEEDS_HUMAN` with the full issue body.

## Commands

```bash
HARNESS_TEST_SANDBOX=1 bash tests/publish-cromford-append.bh-4901-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/publish-cromford-message.bh-4901-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/publish-cromford-brand.bh-4901-test.sh
python3 bin/share/release_message.py "$(git rev-parse origin/main)" --summary "Faster triage"
```
