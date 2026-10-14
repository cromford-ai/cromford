# Agent commits carry the box's git identity, and nothing else gets pushed

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

BH-1134. The fix round's commit `0cad3b30` on project-5 #2708 was authored and
committed as `Claude Fable 5.1 <noreply@anthropic.com>`. Build commits are
`operator <operator@example.com>`. The repo's ruleset requires author == pusher, so the
head got dequeued. The build lane never hit this because its pre-PR squash
re-authors everything with the global config. The fix round and the lander
push the agent's commits as they are.

- **One definition.** `bin/lib/git-identity.sh` has the gi_* functions.
  "The configured author" is `git config --global user.name/user.email`. It is
  never the effective config, because an agent that runs `git config user.email`
  inside a repo writes that repo's local config. Each missing half falls back to
  `operator` / `operator@example.com`, the same values `fly/builder-runner.sh` writes.
- **The pin.** `bin/agent-call.sh` exports `GIT_AUTHOR_*` / `GIT_COMMITTER_*`
  before it starts any runner. It overwrites whatever the caller passed in. The
  environment beats `user.*` config and `git -c user.*`, so every agent session
  commits as the box. `br_fix_round` also runs its own `merge origin/main` and
  the agent call under the same pin. The lander does the same for its own
  merge and commit.
- **The guard.** Only an explicit `--author` gets past the pin. Before it pushes,
  `br_fix_round` runs `gi_check` over the round's own commits (HEAD minus the PR
  head and origin/main, merge commits included). `bin/lander.sh` runs it over
  HEAD minus `origin/<branch>` and origin/main. Each commit's author email and
  committer email must both match the configured email, trimmed and lowercased.
  - rc 1 (mismatch): the fix round writes `AUTHOR_MISMATCH: <sha8> author=…
    committer=…` to `state/blocked-resolver/<p>/<key>.fix-verify.txt` and
    counts it as a failed round (`verify rc=1`). It also deletes the
    `brfix/<key>` checkpoint branch, so the next round doesn't reuse the
    foreign commit. The lander logs `commit author is not <email> (<shas>) —
    not pushed` and exits 1.
  - rc 3 (the check couldn't run: lib missing, or a ref didn't resolve): same
    refusal, recorded as `AUTHOR_CHECK: could-not-run`. It fails closed.
- **Set once.** `bin/bootstrap-machine.sh` calls `gi_ensure_global` right after
  the preflight block. It writes only a half that is unset and never
  overwrites an identity someone already configured.

## What did not change

The harness's own scripted commits that use fixed `-c user.email=harness@…`
identities are untouched: verification-map-retrofit, mc/rebase.sh, rule-miner,
qa-personas, and lane-checkpoint's fallback. The build lane's push has no guard
because its squash already re-authors. A mismatch is refused and never
rewritten with `--reset-author`.

## Operator check

After deploy, each new `FIX ROUND pushed` line in `logs/blocked-resolver.log`
should name a head whose `git log -1 --format='%ae %ce'` shows the box's global
email. An `AUTHOR_MISMATCH` line should only show up with a foreign sha listed
next to it. A box with no global identity still works: the pin and the check
both use the `operator` / `operator@example.com` fallback.

Tests: `tests/blocked-resolver-author.bh-1134-test.sh`, `tests/git-identity.bh-1134-test.sh`.
