# Trace safety runner (dynamic scan: what a test actually deleted)

> **Since the CI cost cut (2026-09-24)** CI no longer runs this as its own matrix: one traced run per shard (`tests-shard`, `bin/test-trace-safety.sh --gate`) feeds both required checks, sized by `bin/ci-plan.sh`. See [ci-cost-lanes.md](ci-cost-lanes.md). What follows is the history and the runner contract, which still holds.

**What it is:** `bin/test-trace-safety.sh`, the dynamic half of the answer to the
2026-09-15 hub wipe (#388, root cause #404, scope #394). It RUNS every
`tests/*.sh` with `HARNESS`, `H`, `HARNESS_CHECKOUT`, `SCRATCH` and `T` unset,
captures a trace of the test and of every child bash, and reports every deletion
and every literal redirect whose target lands outside the allowed temp roots.

`checks/tests-scratch-only/check.sh` ([tests-scratch-only.md](tests-scratch-only.md))
reads the TEXT of a test. This lane reads the RUN. The incident needed both: the
text of `tests/auth-probe-classify-test.sh` was fine, and the clobber happened
at run time, one `source` away, when a `bin/` script reassigned `H` in the
sourcing shell and the EXIT trap removed the live install.

**Detection only.** The runner executes the suite and writes stdout. The only
path it ever deletes is its own `mktemp -d` work dir.

**How an operator reaches it:** one command, from a checkout. CI runs it on
every PR as four parallel shards — `harness-safety-shard`, named
`Tests cannot touch a real harness (shard i/8)` — behind the fan-in job that
keeps the name `Tests cannot touch a real harness`
(`.github/workflows/harness-ci.yml`, and see
[ci-shard-split.md](ci-shard-split.md)). The static lane is not sharded and
runs once, in that fan-in job. Every shard carries
`TRACE_SAFETY_TEST_TIMEOUT=300` so one hung suite cannot spend its budget
before the `TRACE:` line is reached. The measured whole-suite run was about 28
minutes for 375 suites and 40–45 for 513; a quarter of that is 10–12, and each
shard allows 25. No cron lane calls it: it runs the whole suite, which is a
PR-time cost, not a per-tick one. Locally, `bin/test-trace-safety.sh .` still
scans everything and `--shard i/4` reproduces one CI shard.
`tests/README.md` is the operator-facing version of this page.

```sh
bin/test-trace-safety.sh                  the tree this script lives in
bin/test-trace-safety.sh /path/to/tree    any checkout
bin/test-trace-safety.sh --list           just the tests it would run
bin/test-trace-safety.sh --help           the header, including the known gaps
```

On a watcher box, as root next to a live `/root/harness`, it refuses (rc 2)
unless `HARNESS_TEST_SANDBOX=1` — the same guard `tests/lib/scratch.sh` makes,
for the same reason: the runner executes tests bare, including any that never
ported to the scratch library.

**Reading the output:**

```
HIT <test> <verb> <resolved target> (<src>:<line>, cwd <pwd>)  <trace line>
HIT <test> created /nonexistent (existence probe: absent before the test, present after)
CHECK-NOTE test-trace-safety: /nonexistent already exists, creation probe cannot attribute   (stderr, rc unchanged)
EXIT <rc> <test>            a test exited nonzero
TIMEOUT <test> (killed after <n>s)
TIMEOUT <test> (killed after <n>s, shard budget)   --gate: cut at the time the shard budget left
NOTRUN <path> (shard budget <B>s spent)            --gate: the budget was spent, the test never started
BUDGET: <k> of <m> tests not run (shard budget <B>s)   only when k > 0, just before TRACE:
TRACE: <n> tests, <f> nonzero exit(s), <h> hit(s)
```

`<verb>` is one of `rm`, `find-delete`, `truncate`, `git-clean`, `redirect`,
and (BH-2210) `mkdir`, `touch` and `created`, which are hits ONLY when the target
is `/nonexistent` or below it: a `mkdir`/`touch` anywhere else is never a hit, and
`created` is the per-test existence probe that catches a creation xtrace never
shows (a plain `>`, git, python). rc
is **0 clean / 1 hits / 2 could not run**, and "could not run" means: no such
root, no `tests/*.sh`, a work dir or trace fd that could not be created, a test
that produced an EMPTY trace, a dead parser, a bad `TRACE_SAFETY_TEST_TIMEOUT`,
or root next to a live harness. rc 2 prints `CHECK-ERROR test-trace-safety: …`
on stderr and NO `TRACE:` line, so a caller that greps `TRACE:` and a caller
that reads rc agree.

A test that exits nonzero is counted and named, and never a hit: whether the
suite passes is CI's job, this lane's verdict is hits.

**How the trace is taken:** the runner opens fd 199 on a per-test trace file and
hands the test a `BASH_ENV` file that sets
`PS4='+ ${BASH_SOURCE-}:${LINENO}|${PWD}| '`, `BASH_XTRACEFD=199` and `set -x`
in every non-interactive bash that is not already tracing. So the test and every
`bash -c` child land in one file, `$(… 2>&1)` captures stay clean, each line
carries the working directory the command ran in (which is what makes
`cd /; rm -rf ./x` resolvable), and a child started with an explicit `bash -x`
keeps its own stderr trace. The runner reads the test's captured output (stderr,
or stdout+stderr under `--gate`) for the default-PS4 `rm` lines of such a child.
After a traced `PS4=` reassign, the runner also reads the unstamped lines that
follow, with src, line and cwd `-`, and it skips a relative target on such a
line (BH-5541).

**How to drive it:**

| what | how |
|---|---|
| every rule, both refusal shapes, the env hygiene, the allow-list mutation | `bash tests/tests-trace-safety-test.sh` |
| the whole ported tree, on a box, without letting the suite reach the live install | copy the tree, then run the copy inside a private mount namespace where everything but `/tmp` is read-only: `unshare -m bash -c 'for d in /root /usr /etc /var /home /data; do mount --bind $d $d && mount -o remount,ro,bind $d; done; HARNESS_TEST_SANDBOX=1 TMPDIR=<copy>/tmp HOME=<copy>/home <copy>/bin/test-trace-safety.sh <copy>'` |
| every shape the retired trap-target guard asserted (S1-S8), bad and good | `bash tests/test-trace-safety-shapes.bh-5541-test.sh` |
| the suite reads no clock and no network | `bin/test-determinism-lint.sh tests/tests-trace-safety-test.sh` |

**Shapes the retired trap-target guard asserted (BH-5541).** The guard
`tests/trap-target-safety-test.sh` re-traced about 190 suites under `bash -x`
(a median 842 s a batch). The shard tracer catches each shape it read:

- S1: the 2026-09-15 incident, `trap 'rm -rf "$H"' EXIT`, then a sourced bin lib sets `H="${HARNESS:-<bad>}"`.
- S2: `rm -r` without `-f`.
- S3: rm inside `$( … )` and inside `( … )`.
- S4: rm inside a `bash -c` child.
- S5: a sourced lib's EXIT trap function removes a variable the suite reassigns.
- S6: the suite sets `PS4="+ "`, then runs rm.
- S7: a subshell runs `export PS4="+ "`, then runs rm.
- S8: a `bash -x <script>` child whose stderr reaches the suite's stderr runs rm.

A `bash -x` child whose stderr goes to `/dev/null` or to a file the suite owns
is not read. The retired guard did not read it either.

**Not as `nobody`.** The obvious sandbox — copy the tree, `chown -R
nobody:nogroup`, `setpriv --reuid=65534` — does not work: `tests/lib/scratch.sh`
chmods its scratch dir `555`, so a non-root test cannot write into `$T` at all.
Every test then fails at its first write, and a test whose scratch variable is
empty by that point computes absolute paths — that run really did execute
`rm -f /bin/jobs-client.sh`, and the runner reported it. The runner was right;
the sandbox was wrong. Run as root with the filesystem read-only instead.

Every fixture in the suite is built from a heredoc under `$T`, never as a file in
the repo, because `bin/repro-gate.sh` globs added test files and runs them; every
fixture that must be a hit aims at `/dev/null/no-such-harness…`, which cannot be
created, so the fixtures are inert by construction.

**Files it names on a live box:** none. No state file, no ledger, no lock. The
work dir is a `mktemp -d` under `${TMPDIR:-/tmp}`, removed on exit unless there
were hits or `TRACE_SAFETY_KEEP=1`, in which case its path is printed on stderr
so the trace behind a hit can be read.

**Knobs:** `TRACE_SAFETY_TEST_TIMEOUT` (per-test seconds, default 600),
`TRACE_SAFETY_SHARD_BUDGET_S` (`--gate` only: whole seconds for the whole run,
default 0 = no budget; CI passes the repo variable of that name, fallback 2400)
and `TRACE_SAFETY_T0` (epoch seconds the budget counts from, default the
script's start; CI passes the clock step's `SHARD_T0`) (BH-9465),
`TRACE_SAFETY_KEEP=1`, `HARNESS_TEST_SANDBOX=1`, `HARNESS_ROOT_OVERRIDE`,
`TMPDIR` / `RUNNER_TEMP` (extra allowed temp roots when set),
`TRACE_SAFETY_CREATE_ROOT` (the root no test may create, default `/nonexistent`;
absolute and not `/`, else rc 2). Nothing here is a
new required env var.

**Known gaps, stated rather than papered over:**

- `#!/bin/sh` children on dash read no `BASH_ENV`, and `env -i …` children lose
  it: those are untraced. Their command text still shows in the parent's trace,
  which is what the redirect rule reads.
- The redirect rule is read only against arguments handed to a shell on THIS
  machine (`bash -c`, `sh -c`, `eval`, `su -c`, and `declare`/`typeset`/`local`
  with a `NAME="(…)"` operand, which re-parses its string the way eval does —
  `is_interpreter` in the parser). A backslash in a redirect target is read the
  way that inner shell reads it (BH-5266): `printf %q` spells
  `2>/dev/null || x` as `2\>/dev/null\ \|\|\ x`, so an escaped space or
  terminator ends the target and any other escaped character is itself. An
  escaped space between the operator and the target (`2\>\ /dev/null`) is
  skipped, like any target that does not start with `/`. `ssh host '… cat > /root/x'` is not read: those paths are another
  box's, and in the suite `ssh` is a stub.
  This repo's tests print command strings for a living, and the first full-tree
  run flagged 106 assertion messages that merely quote
  `cat >/root/harness/state/x.json` or spell `batch/<project>/<stamp>`. A
  redirect the shell really performed is invisible to xtrace anyway unless it is
  inside one of those arguments, so the narrowing costs no real coverage — but a
  redirect inside `python -c` or `xargs sh -c` is not read. Adding an
  interpreter is one more name in that function.
- A redirect target that is relative or still an unexpanded `$var` in the traced
  text cannot be resolved honestly, so it is skipped rather than guessed at.
- A traced command whose text spans lines is read only as far as its first line.
- A path containing `|` breaks the stamp. No path in this repo has one.

**What must never regress:**

- **The allow-list is one `case` block.** `safe_target` holds `/tmp`,
  `/private/tmp`, `/var/folders`, `/private/var/folders`, `/dev/shm`, `$TMPDIR`
  and `$RUNNER_TEMP` — strictly UNDER each, never the root itself. `/dev/shm` is
  there because the harness keeps short-lived secrets on that tmpfs rather than
  on disk (`bin/gh-token-rotate.sh`, the fly env staging) and those scripts
  remove their own `mktemp` files; the ticket's list did not name it and the
  first full-tree run reported 15 of them. It is the only place a path is
  excused, and `safe_redirect` adds exactly the device names
  (`/dev/null`, `/dev/stdout`, `/dev/stderr`, `/dev/tty`, `/dev/fd/*`).
  `/dev/null/<anything>` stays a HIT — that is what keeps the suite's fixtures
  both inert and detectable. Section M of the suite copies the runner, seds
  `/tmp/*` out of that block, and fails unless the clean fixture goes red.
- **It fails CLOSED.** An empty trace, a dead `awk`, a missing root, no tests, a
  bad knob value: rc 2 with a `CHECK-ERROR` line and no `TRACE:` line. A scan
  that did not happen never reads as a clean tree. Section L proves it with a
  fake `awk` that exits 3 and with a shell that emits no trace at all.
- **Nonzero test exits never become hits, and never set rc 1.** Section K.
- **No `{n}` quantifiers in any awk pattern.** `/usr/bin/awk` is mawk on Debian
  and on Ubuntu runners; a pattern that quietly matches nothing is the vacuous
  green this lane exists to refuse.
- **The runner deletes only its own work dir.** Nothing else, ever.
