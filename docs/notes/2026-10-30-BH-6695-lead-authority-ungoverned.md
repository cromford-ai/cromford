# A failed read of the protected paths holds only governed repos; one read per repo per process (BH-6695, with #6663 and #6665)

Doc: MERGE-CONDUCTOR

## Why

Before this change, `_la_db_globs` (`bin/lib/lead-authority.sh`) returned rc 2
for every repo when the GET of the `lead_protected_paths` rows failed and no
cache was younger than `lead_protected_paths_cache_max_s`. The rc 2 applied
also to a repo with no seed line and no row ever. Two results followed:

- `mc_enqueue_mergify` (`bin/lib/mc/queue.sh`) held every PR (rc 3). Lead
  merges stopped on every fleet repo during a jobs-worker outage.
- `bin/lib/risk-tier.sh` rule 1 capped every repo at medium ("protected paths
  unreadable").

## The rule

A failed read (outage, 404, a body whose `rows` is not an array, no jobs
client) is answered in this order:

| cache file `state/lead-authority/globs-<owner_name>.cache` | seed file `catalog/lead-protected-paths.seed.tsv` | seed line for the repo | answer |
|---|---|---|---|
| exists, fresh | any | any | rc 0 from the cache (as before) |
| exists, stale (any content, empty too) | any | any | rc 2, a hold (as before) |
| none | cannot be read | n/a | rc 2, a hold |
| none | readable | yes (case-folded match, a `#` line does not count) | rc 2, a hold |
| none | readable | no | rc 0, not governed |

The not-governed answer sets `LA_GLOBS=""` and
`LA_GLOBS_SRC="none (rows unreadable; no seed line, no cache)"`. It writes no
cache file. `la_scope` is rc 1, `la_globs` is rc 0 with no output, and
`la_decide` is rc 0 with the reason
`not governed (rows unreadable; no seed line, no cache)`.
`bin/lead-verdict.sh authority <repo>` prints
`globs (lead_protected_paths, from none (rows unreadable; no seed line, no cache)): 0`
and `in scope: no`.

The seed file is read under the harness root (`$HARNESS`, else `$H`). With no
root (the lead's Mac) it is read next to the lib, at `../../catalog/`.

What it changes: during an outage, `mc_enqueue_mergify` and `la_decide` free a
repo with no seed line and no cache file, and `risk-tier.sh` rule 1 reads its
globs as readable (none). A seeded repo, and any repo with a cache file, is
held as before.

The open window: a repo whose rows were added on SETTINGS -> PROTECTED PATHS,
with no seed line, on a host that has never read it (a fresh pool machine), is
not governed during an outage on that host. A repo that must stay held on
every host needs a seed line.

## The memo (#6665)

`_la_db_globs` keeps every answer (rc 0 and rc 2) for the rest of the process,
keyed by the lowercased slug (`_` -> `_5f`, `.` -> `_2e`, `-` -> `_2d`,
`/` -> `_2f`, prefix `_LA_MEMO_`). The read itself moved to `_la_read_globs`.
An illegal slug is rc 2 and makes no entry. `la_memo_reset` forgets every entry
of the shell.

- Scope: the shell that called `_la_db_globs`. A `$(...)` subshell reads the
  parent's memo but cannot write back. Nothing is exported, so a child process
  (`bin/lead-verdict.sh post`) reads fresh.
- Staleness bound: one process (one conductor tick, one CLI call). A row added
  in the console governs the next process. No TTL and no new knob.
- Reads saved: `ld_protected` 2 -> 1 GET; `la_scope` then `la_decide` in one
  shell 2 -> 1 GET. An rc 2 is kept too, so an outage costs one slow GET per
  repo per process.

## Console copy (#6663)

The PROTECTED PATHS note on `/settings` (hub tab) now says: the lead lane reads
these rows, and `catalog/lead-protected-paths.seed.tsv` only adds a glob that
has no row yet. The `DEFAULT_REPO` comment in `console-ui/src/ui/ProtectedPaths.js`
names the seed file, not the deleted TSV.

## Tests

- `tests/lead-authority-ungoverned.bh-6695-test.sh`: U1-U8 (the rule table and
  its near misses: a prefix name, mixed case, a commented line, no root), E1 (a
  lead MERGE post in an outage), A1 (the authority verb), R1 (risk-tier), M1-M7
  (the memo), B32 (Bash 3.2).
- `console-ui/tests/protected-paths-copy.bh-6695.test.js`: C1 (the rendered
  note), C2 (no `catalog/lead-protected-paths.tsv` under `console-ui/src`).
- `tests/lead-authority-db.bh-4148-test.sh` is unchanged and green: its D3 and
  D5 outage cases run with no seed file, so they stay rc 2.
