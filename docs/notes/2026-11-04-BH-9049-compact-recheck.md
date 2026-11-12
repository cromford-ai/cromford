# The iron-law re-check after context compaction (BH-9049)

Doc: SESSION-PROFILE, OPERATING

## Why

Long execute and fix sessions hit context compaction. The summary can drop the
iron rules (additive-only schema, RLS on new tables, no hardcoded model
strings, every limit is a knob, no secrets). The session then writes code
without them. We find out at review or at the merge iron-law scan, and that
costs a fix round.

## What changed

1. `bin/agent-call.sh` adds one more file to the claude runner's `--settings`
   merge, before the act-time iron-law guard (the guard stays last). The file
   is `$HARNESS/state/compact-recheck-settings.json`:
   `{hooks:{SessionStart:[{matcher:"compact",hooks:[{type:"command",command:"$HARNESS/bin/compact-recheck.sh",timeout:<timeout_s>}]}]}}`.
   `compact_recheck_settings` (`bin/lib/compact-recheck.sh`) writes it only
   for the stages `plan`, `execute` and `fix`, and only when the row
   `build.compact_recheck.<project>.enabled` reads `1`. Codex and grok lanes
   get no hook.
2. The CLI pin is `2.1.318` (row `cli.claude_code.version`, read at round 2).
   The pool box that built round 4 ran `2.1.312`. On 2.x a `SessionStart` hook fires with `source: "compact"` after a compaction
   and can return `hookSpecificOutput.additionalContext`. `PreCompact` cannot
   add context, so it is not used.
3. The hook `bin/compact-recheck.sh` calls no model. After each compaction it:
   - puts the iron-law block back into the context. It reads the block at hook
     time from `rules/topics/01-iron-guardrails.md` (whole file) and the
     `### Data & config iron laws` part of `rules/topics/04-building-software.md`.
     If a topic file is missing, it reads the same two parts of
     `~/.claude/CLAUDE.md`.
   - scans the working-tree diff (committed, uncommitted and untracked files)
     against `merge-base(HEAD, origin/$BASE_BRANCH)` (default `main`). The scan
     is `mc_iron_law_lines` (new in `bin/lib/mc/classify.sh`: the merge-sweep
     literal scan with new-file line numbers), `bin/checks-run.sh`, and
     `cr_rls_hits` (an added `CREATE TABLE` in a `.sql` file with no added
     `ALTER TABLE <same name> ENABLE ROW LEVEL SECURITY`; `worker/`, tests and
     docs are skipped, because D1 has no RLS).
   - prints each hit as `iron-law scan after compaction: <file:line> <class>`.
     The classes are `model-id`, `native-dialog`, `vercel-url`, `rls-missing`
     and `check:<slug>`. A check's reason text is not printed, because a
     `secret-literals` reason can quote the secret.
4. `mc_iron_law_names` and `mc_iron_law_scan` did not change. The merge-time
   scan stays the real gate.

## Knobs

| Row | Seed | Code fallback | What it does |
|---|---|---|---|
| `build.compact_recheck.<project>.enabled` | `1` for `cromford` only | off | install the hook |
| `build.compact_recheck.timeout_s` | `30` | `30` | CLI hook timeout; each of the 4 bounded steps gets a quarter |
| `build.compact_recheck.max_hits` | `50` | `50` | hit lines put in the context; the rest is one "N more" line |

Rollback: set `build.compact_recheck.cromford.enabled` to `0`.

The env `COMPACT_RECHECK_ENABLED`, when set, decides instead of the row (`1` = on,
any other value = off). Tests and a canary box use it. It never opens a stage
other than plan, execute and fix.

## The log line

One line per compaction in `$HARNESS/logs/compact-recheck.log`, and the same
line in `<build dir>/compact-recheck.log` when the session runs for a build
dir (a pool machine's `logs/` is lost with the machine; the build dir comes
back):

    <iso> compact-recheck job=<build dir> phase=<stage> project=<p> session=<id> compaction=<n> hits=<n> rules=<ok|missing> scan=<ok|missing:<why>|skipped:<why>|failed:<why>> [checks=could-not-run] [rls=missing] [out=plain]

`compaction` is 1 + the earlier lines of the same session in the box log.

## Fail open

The hook exits 0 every time. A missing scanner is `scan=missing:<why>`, a cwd
outside git or with no base is `scan=skipped:<why>`, and a step that hits its
bound or an abort is `scan=failed:<why>`. The rules block still goes into the
context. A harness tree with no `checks/` (the pool box of round 4 had none
in `/root/harness`) adds `checks=could-not-run`; the literal scan and the RLS
check still run. One path is silent: if the CLI kills the hook at its own timeout, the
session continues and no log line is written.

## The 2-week measure

Compactions per build, sessions, and scan hits after compaction, per job:

```bash
LOG=/root/harness/logs/compact-recheck.log
awk '{ delete f; for (i = 3; i <= NF; i++) { k = $i; sub(/=.*/, "", k); v = $i; sub(/^[^=]*=/, "", v); f[k] = v } j = f["job"]; n[j]++; h[j] += f["hits"]; if (!((j SUBSEP f["session"]) in s)) { s[j SUBSEP f["session"]] = 1; ns[j]++ } } END { for (j in n) print j, n[j], ns[j], h[j] }' "$LOG"
```

Each output line is `<job> <compactions> <sessions> <hits>`. On a pool build,
read `builds/<dir>/compact-recheck.log` with the same awk. The comparison with
review iron-law BLOCKs per 100 builds is an operator step after deploy.
