# The gh_rest ETag counter file is swept, trapped, and the byte cap counts bytes

Doc: MERGE-CONDUCTOR, ACCOUNT-ROUTING

## Why

BH-1295 left the ETag counter file as a known follow-up: `_gh_etag_count`
appended `fetched`/`cached` lines to `${TMPDIR:-/tmp}/gh-etag-count.<lane>.$$`,
and `gh_rest_etag_report` was the ONLY thing that ever removed one. A reporting
lane killed between arming and reporting — a tick deadline, a SIGTERM on
deploy, an OOM kill — never reached its report, so its file stayed in `/tmp`
for ever. On a box that hits its deadline every tick that is one file per tick,
on a `/tmp` cleaned at boot only.

The same round's delta review found a second defect in the store path:
`GH_ETAG_MAX_BYTES` was enforced with `${#body}`, a CHARACTER count under a
UTF-8 locale. A diff with non-ASCII could be well over the 1 MiB cap on disk
and still be cached, which is the exact bound the cap exists to hold.

## What changed

- **The counter file moved** to `$HARNESS/state/gh-etag/counts/<lane>.<pid>`
  (`_gh_etag_counts_dir`). `_gh_etag_count` tries the append first and only
  pays for a `mkdir -p` + one retry when the directory is not there yet, so no
  arming site has to pre-create it.
- **Each arming lane installs `trap 'rm -f "$GH_ETAG_COUNT_FILE"' EXIT`** —
  `bin/reconcile-prs.sh`, `bin/merge-conductor.sh` (the parent shell, plus a
  separate trap inside each per-project subshell, whose file is keyed on
  `$BASHPID` so the parent's trap can never remove a child's), and
  `bin/merge-sweep.sh`, which already owned the only EXIT trap in that file and
  so removes the counter file as the first statement of `_sweep_finish` rather
  than by a second `trap … EXIT` that would have replaced the job-lane close.
  Bash runs an EXIT trap on SIGTERM and on any normal exit; it does not run one
  on SIGKILL.
- **`_gh_etag_counts_sweep` is the SIGKILL backstop**, called from
  `gh_rest_etag_report` on every report (before the hourly entry sweep). It
  removes a counts file whose name has no numeric pid suffix, whose pid is no
  longer alive (`/proc/<pid>` first so a non-root run never misreads EPERM as
  dead, `kill -0` as the fallback), or that is older than the same
  `GH_ETAG_TTL_H` cutoff the entry sweep uses — the age rule is what bounds a
  file whose pid was recycled by an unrelated live process. So a killed tick
  leaves at most one file, and the next report from any lane on the box removes
  it. A killed tick's partial counts are dropped, never logged under the lane's
  name as if they were a whole tick.
- **`_gh_etag_bytes` measures bytes.** `local LC_ALL=C` scopes the measure to
  the helper (bash restores the caller's locale on return) and the answer comes
  back in `GH_ETAG_BYTES` rather than a `$( )` capture, so a 2xx costs no extra
  fork. `_gh_etag_on_2xx` compares that instead of `${#body}`.
- The entry sweep's size-cap loop only removes regular files now: `ls -1t`
  lists the new `counts` directory, and the count it is compared against is a
  `find -type f`.

`gh_rest_etag_report` stays the normal path: it still writes the lane's
`gh-etag lane=… fetched=… cached=…` line to `logs/gh-rate.log` and clears its
own file. Nothing about the cache format, the key, or the 304 path changed, and
no new env var is introduced (`GH_ETAG_TTL_H` and `GH_ETAG_MAX_BYTES` are the
existing knobs).

## Supersedes

`docs/notes/2026-09-21-BH-1295-gh-rest-etag.md` closes with "the counter file
(`$TMPDIR/gh-etag-count.<lane>.$$`) is removed only by `gh_rest_etag_report`,
so a lane killed before its own report leaves one file, bounded by pid
recycling — low severity, not fixed here." That paragraph is superseded by this
note: the file no longer lives in `$TMPDIR`, the lane's EXIT trap removes it on
a normal exit or SIGTERM, and the counts sweep removes it after a SIGKILL. The
1295 note itself is left untouched, per the dated-note rule.

## Verified

`tests/gh-rest-etag.bh-1322-test.sh` — the killed-before-report row (arm, one
`gh_rest` GET through the stub `gh`, `kill -KILL`, report → no file left), a
parent/child pair where the child's kill leaves the parent's file alone, the
EXIT-trap idiom under a real SIGTERM with no sweep involved, the sweep's
pid/junk/TTL rules, a source pin on the three lanes' arming lines, the byte cap
on a 5-character/10-byte body under `GH_ETAG_MAX_BYTES=8` (and an 8-byte body
that must still be cached, since the cap is inclusive), and two mutants — the
liveness test forced true, and the byte helper's locale put back to UTF-8 —
each of which must turn the suite red.
