# 2026-09-22 — BH-1248: race-sigpipe reaches bin/, and reads a continued pipe

Doc: TEST-DETERMINISM

## What changed

**1. Eighteen `git … | grep -q/-m/head` sites under `bin/` are gone.** One
commit per script: `review-rescue.sh`, `qa-personas.sh`, `test-tamper-scan.sh`,
`context-gate.sh`, `harness-sync.sh`, `blocked-resolver.sh`, `disk-clean.sh`,
`run-build.sh`, `lib/mc/rebase.sh`, `lib/wake-class-push.sh`, `lib/evidence.sh`.
Three shapes, all semantics-preserving:

- capture first, then `grep -q … <<<"$captured"` (where the rc feeds an `if`);
- `git log -N` where the pipe only truncated a one-line-per-commit format;
- bash string ops (`${v%%$'\n'*}`, `${v##*refs/heads/}`, `${v:0:N}`) where the
  pipe only took the first line or the first N bytes.

Four of the eighteen were live wrong-branch bugs, not latent ones — their rc
fed an `if`, and under `set -o pipefail` a 141 from git read as "no match":

| site | what the 141 did |
| --- | --- |
| `bin/test-tamper-scan.sh:535` | dropped a real `TEST-CHANGE:` justification, so a justified build blocked for tampering |
| `bin/lib/mc/rebase.sh:1286-1287` | took THEIRS on a generated per-ticket file the branch had its own work in |
| `bin/lib/wake-class-push.sh:24` | classified a `prompts/` push as not one, so `prompt-eval` never launched |
| `bin/lib/evidence.sh:350` | read a deleted test as not deleted, so INCONCLUSIVE became a scored verdict |

`bin/harness-sync.sh:166` was a false positive (the pipe on that line is
`tr | head`, git is a closed `$(…)`). It was resolved by hoisting the
`git rev-parse` into a variable rather than by a waiver: same bytes in the log
line, and no waiver sentence to rot.

**2. `catalog/determinism-lint.conf` gained a `scope` directive.**
`scope <rule-name> <ERE>` gives ONE rule a path the `file` lines do not cover. A
file matched only by `scope` lines runs only the rules that name it; a test file
still runs all of them. The shipped line is
`scope race-sigpipe (^|/)bin/.*\.sh$`, plus
`skip (^|/)checks/[^/]+/fixtures/.*/bin/` so the tests-scratch-only check's
fixture trees are not read as product code.

A wider `file` line was rejected: it fires 24 `race-sleep`, 3 `rand-bash` and 5
`clock-rolling-window` errors and 441 warnings on today's `bin/`, none of which
the ticket asks anyone to fix, and turns `race-sleep` red on every cron lane's
bounded poll.

**3. The lint joins a pipeline split over physical lines.** `git log … |` with
`grep -q …` on the next line is the same race and used to pass. Lines are now
joined forward across a pipe boundary only (`|` at end of line, `| \`, or `\`
with the next line starting `|`), bounded at four continuation lines, and the
finding is reported once at the line the pipeline starts on. `||` is NOT a pipe
boundary — reading it as one moved four existing `clock-date-cmd` warnings onto
the wrong line in the first draft, and the `[^|]` guards are what stop that.

The join is what FOUND the eighteenth site: `bin/lib/evidence.sh:350` splits
`… </dev/null \` from `| grep -q .`, so the shipped one-line rule could never
see it. The ticket said 18 and the plan's inventory could only find 17.

**4. The rule ERE learned grep's long spellings.** `--max-count`, `--quiet` and
`--silent` are the same short circuit as `-m` and `-q`. `--count` is not — it
reads to EOF — and neither is `-e --max-countish`.

## Where it bites

`bin/test-determinism-lint.sh .` now scans 1098 files instead of 709: 709 test
files plus 390 `bin/**.sh`, of which exactly one —
`bin/share/overlay/tests/no-client-identifiers-test.sh` — both selectors match,
and it is read as a test file (all rules run). It is still seconds. The CI job is
`.github/workflows/harness-ci.yml` → **Test determinism lint**, whole tree, no
args. From now on a PR that adds a `git … | grep -q` under `bin/` fails there.

## The waiver mechanism is unchanged

`# determinism: ok <reason>` and `# determinism: ok-file [<rule>] <reason>` work
on a scoped file exactly as on a test file, and a reasonless waiver is still a
`waiver-no-reason` finding. On a joined pipeline the waiver is accepted on any
line of the span. Nothing in the tree needed one: every site was converted.

## Version skew both ways

A box's `flags/determinism-lint.conf` may be older or newer than the script.
New script + old conf: no `scope` lines, so `SCOPE_RE` is empty and the file
list is exactly today's. Old script + new conf: `scope` is an unknown directive
kind, the awk falls through every `else if` and the shell's `FILE_RE` awk only
reads `file` lines. Both directions degrade to the previous behaviour.
