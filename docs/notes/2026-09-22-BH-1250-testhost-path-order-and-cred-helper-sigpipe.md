# BH-1250 — the test host's red suites were a PATH order and a SIGPIPE race, not a /root/harness leak

Doc: REMOTE-GATE, TEST-DETERMINISM

## What was reported

`tests/review-rescue-test.sh` (22 fails) and `tests/gh-default-identity-test.sh`
were red as root with `HOME=/root` on the Fly test host, green everywhere else.
The ticket's diagnosis was that the suites resolve a real `/root/harness` path
when `HOME` is `/root` — the same class as the `HARNESS_TEST_SANDBOX` guard in
`tests/lib/scratch.sh`. That diagnosis is wrong, and both defects are elsewhere.

## The probe that refuted it

Host-shaped run on `pool-cromford-8d5206feee6028`, root, `HOME=/root`,
inside a mount namespace with a real checkout at `/root/harness`: a marker file
was stamped, both suites ran, then `find /root/harness -anewer <marker>`.

    --- files under /root/harness accessed since marker ---
    --- (end; empty above = nothing touched) ---

Empty at base and at head. Neither suite reads or writes a byte under
`/root/harness`, and `HOME=/root` versus a fake `HOME` makes no difference.
`tests/lib/scratch.sh` is not touched by this ticket.

## Defect 1 — `bin/review-rescue.sh` put `/usr/local/bin` ahead of the caller's PATH

Same namespace, with `/usr/local/bin` a tmpfs holding one symlink to the host's
`gh`:

    ########## BASE ##########
    FAIL: RESULT becomes PR_CREATED with the real URL: got 'REVIEW_BLOCKED test-tamper: TAMPER_COUNT: 1 ...'
    review-rescue-test: 42 pass, 13 fail
    /root/.cache/gh WAS created
    ########## HEAD (with fix) ##########
    review-rescue-test: 55 pass, 0 fail
    /root/.cache/gh not created

13 fails here; the ticket's 22 is the same shape on a host whose `gh` is
authenticated and answers `issue view` / `pr list` for real. The `/root/.cache/gh`
directory is the proof of what happened: the lane's line 123
`export PATH="/usr/local/bin:$PATH"` put `/usr/local/bin` AHEAD of whatever PATH
the caller chose, so the suite's fake `gh` in its scratch tree was never reached
and the HOST's `gh` ran instead, with the host's own config, against
`example-org/project-5`.

The line exists because cron's PATH lacks `/usr/local/bin` — the twin line at
`bin/lane-reaper.sh:59` says so in its comment. So the fix keeps the directory
and appends it: `export PATH="$PATH:/usr/local/bin"`. Cron still finds `claude`
(via `bin/agent-call.sh`), `codegraph` and `rtk`; the only behaviour change is on
a box where the same name exists in BOTH `/usr/bin` and `/usr/local/bin`, where
`/usr/bin` now wins. On the fleet image `rtk` is the same file in both, and
`gh`/`flock`/`timeout` are apt-installed under `/usr/bin` only.

`tests/review-rescue.bh-1250-test.sh` pins it as CI can run it (no namespace, no
root): it drives the whole lane with a PATH that deliberately omits
`/usr/local/bin`, and the fake `gh` records the PATH it was reached with.
Assertion 2 pins the order, assertion 3 pins that the directory is still added,
so neither reverting the fix nor deleting the line passes.

## Defect 2 — `gh-default-identity-test.sh` 10c/10d lost a SIGPIPE race under load

Not a host env var. A 22-variable matrix over every `${VAR:-}` the identity libs
read (planning probe, 2026-09-22) found only the fixture's own knobs
(`MINT_FAILS`, `_GHAA_LOADED`, `_GHRT_LOADED`, `_GHLL_LOADED`) flip the suite,
and no lane exports any of them. What the suite IS sensitive to is CPU load.

`gitcred()` piped the credential request into the inline helper. The helper's
`store`/`erase` arm exits without reading stdin (by design — git ignores SIGPIPE
around its own write), so under `set -o pipefail` a writer that loses the race
dies of SIGPIPE and 10c/10d report `rc=141`. Measured on this box, 24 concurrent
loops x 400 iterations:

    pipe form (what the suite did):  nonzero-rc total: 967 of 9600
    file form (the fix):             nonzero-rc total: 0 of 9600

The test host runs a dozen suites in parallel on one machine, which is exactly
that load — and is why one agent saw red and another green on the same tree. The
fix writes the request to a file under `$T` and redirects it in. Identical input
for 10a/10b, which do read stdin. 16 concurrent suite runs at head: all
`117 passed, 0 failed`, zero `FAIL:` lines.

`bin/ensure-box-gh-app-default.sh` is NOT changed. Production has no defect here:
git is the only writer and it ignores SIGPIPE; teaching the helper to drain stdin
would rewrite every box's git config to fix a test race.

## Left for a follow-up

`bin/lane-reaper.sh:59` carries the identical prepend. Nothing is red from it
today — that lane's suite fakes no binary — but it is the same latent shadowing
and deserves its own ticket rather than a widened diff here.
