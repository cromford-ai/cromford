# The post-checkout hook always exits 0, ignores file checkouts, and reaches a hub that already has it; the test image gets rsync

Doc: FLAKY-TESTS

Four small things, three of them in the hook `bin/harness-sync.sh` installs and
one in the container the shell suite runs in.

## The hook's rc was the log append's rc

The BH-1099 hook body ended on

    echo "… checkout moved off main to $new_branch …" >> "$h/logs/checkout-moves.log"

and nothing after it, so the hook's exit status was that redirect's. With
`$HARNESS/logs` absent — a fresh box, a lane with `HARNESS` unset on a machine
that has no `/root/harness` — `git checkout -b side` returned **1**:

    .git/hooks/post-checkout: line 8: …/nologs/logs/checkout-moves.log: No such file or directory
    rc=1

That rc is read. `bin/fleet-propagate.sh`'s 2b guard runs `git -C "$CHECKOUT"
checkout -q main` and decides `hub=ok` vs `hub=fail` on its status, so a hook
that failed on its own log file would have recorded `checkout main failed` for a
checkout that moved perfectly well, and the tick would have refused to propagate
a merge to the fleet. The hook is attribution, not a gate: it now ends on
`exit 0`. The append can still print a shell error on stderr when the directory
is missing; what it can no longer do is change the exit status of the checkout.

## A file checkout is not a move off main

git passes a post-checkout hook a third argument: `1` for a branch checkout, `0`
for a file checkout. The hook never read it, so on a side branch
`git checkout -- somefile` appended a line claiming the checkout had just moved
off main, with a `from=`/`to=` pair that were the same sha. The hook now returns
early unless `$3` is 1. A manual invocation with no flag at all (`"${3:-1}"`)
still counts as a branch move.

## The fix had to reach the hook that is already installed

`install_post_checkout_hook` returned on `[ -x "$hook" ]`, which means the hub —
the one machine that runs this in production, and the one that has had the hook
since BH-1099 — would never have received either fix. The rule is now: a hook
that does NOT carry `installed by bin/harness-sync.sh` is hand-written and is
left exactly as it is (the BH-1099 promise), a hook that carries the marker with
`(v2` is current and is left alone, and anything else of ours is rewritten. The
version token lives in the hook's own marker comment, so the next body change is
a `v3` and a one-line edit to the guard.

## The header's exit codes

`--check` and the deploy path have different exit codes and the header only
documented `--check`'s. Both lists are now written out, copied from the `exit`
statements in the file, including the side-branch refusal (`--check` prints
`refused branch=<b>` and writes nothing at all; only the deploy path stamps and
alerts). No exit code changed.

## rsync in the test image

`tests/harness-sync-branch-guard.bh-1099-test.sh`,
`tests/harness-sync-stamps-test.sh` and
`tests/harness-sync-catalog-reset.bh-1042-test.sh` all open with

    command -v rsync >/dev/null || { echo "… missing — skipping"; exit 0; }

because the script they drive deploys with rsync. The image
`bin/run-tests-in-docker.sh` builds installed no rsync, so on a Mac those three
suites printed one line each and exited 0 — green, having tested nothing.

`rsync` is now in the apt list, and the default tag moved to
`cromford-tests:trixie.2`. The tag is half the fix: the image is built once
and kept (`docker image inspect` short-circuits the build), so a package added to
the Dockerfile never reaches a machine that already holds the old tag. **The
suffix moves whenever the package list moves.** A machine that built the old
`cromford-tests:trixie` keeps it until someone removes it; the runner's
header says so.

The `MEASURED` pass/fail counts in that header are NOT updated — nobody has run
the full suite since rsync was added, and three suites that used to skip now run.
The header says that too.

## How it is proven

    HARNESS_TEST_SANDBOX=1 bash tests/harness-sync-hook.bh-1128-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/fleet-propagate.bh-1128-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/run-tests-in-docker.bh-1128-test.sh

The first drives real `git checkout` calls against a real clone with the hook
installed by a real deploy, including the re-install and foreign-hook cases. The
second is a pin, not a fix: `bin/fleet-propagate.sh` already enriched a failed
ff-only pull with the branch, the ahead/behind counts and git's first error line,
and now a suite fails if that is flattened. The third reads the runner's own
Dockerfile text, because without a docker daemon there is nothing else to read —
it fails loudly when the extraction is empty rather than passing on it.
