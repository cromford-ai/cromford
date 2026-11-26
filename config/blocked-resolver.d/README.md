# config/blocked-resolver.d/ — the fragments of bin/blocked-resolver.sh (BH-10227)

`bin/blocked-resolver.sh` is target #4 of BH-9704: a large hub file that becomes
a committed render of a fragment folder. The file is 529 KB, more than one
review can read, so the split lands in two PRs. This folder is the first one.

## Adoption state

HEAD ONLY (BH-10227 C0). Not registered. Edit the resolver script as today.

- No row in `catalog/splits.d/` names `bin/blocked-resolver.sh`, so
  `bin/render-split.sh` does not read this folder, and nothing renders the
  script from it yet.
- Do not edit these fragments for a resolver change. C1 re-syncs them from
  main and registers the folder.
- After C1, a new block is a new fragment numbered between its neighbours:
  `1350-<slug>.txt` goes between `1300-...` and `1400-...`. Then edit the
  fragment, run `bin/render-split.sh --write`, and commit both.
- After C1, a BH-1176 module move (a block moved out of the resolver into its
  module folder) deletes lines from a fragment, not from the script.

## Format

- Each fragment is verbatim shell bytes from the script. There is no banner
  and nothing is trimmed.
- The fragments end in `.txt`, the same as `config/rb-plan.d/`. A `.txt` file
  is not a script to the state-paths guard, and the share mirror reads it as
  text.
- A fragment name must match `^[0-9]{4}-[a-z0-9][a-z0-9-]*\.txt$`. `README.md`
  is the only other file allowed here. No dotfile, subdirectory or symlink.
- Each fragment is non-empty, ends in a newline, holds no CR byte and no
  merge marker line, and passes `bash -n` alone.
- The concatenation of the fragments in `LC_ALL=C` name order is a byte
  prefix of the script at the commit that last wrote this folder. After C1 it
  is the whole script. `tests/blocked-resolver-split.bh-10227-test.sh` checks
  this (S3), and the renderer's `--check` once a registry row exists (S6).

## The cut rule

The head was cut once from `bin/blocked-resolver.sh` at main `49c4d60c`.

1. A boundary is a column-0 `# >>> ` marker line, or the first line of the
   column-0 `#` comment block directly above a column-0 `name() {` line (the
   `name() {` line itself when no comment block is above it). A `# <<< `
   closing line never starts a boundary.
2. A new fragment starts at a boundary only when the current fragment already
   holds at least 250 lines.
3. The head ends at the last boundary at or before byte 285,000. At
   `49c4d60c` that is line 4,767, the comment block above `br_findings`
   (280,027 bytes). Everything from there to the end of the file is C1's tail.
4. Fragment k is `<k*100, 4 digits>-<slug>.txt`: `0100-head.txt` first, then
   the slug of the marker text or of the first function name.
5. C1 numbers the tail fragments from 5000, so no head fragment is renamed.

## Fragments

| fragment | holds |
|---|---|
| `0100-head.txt` | lines 1-481: the shebang, the file header and the top-level setup |
| `0200-br-queue-enq.txt` | `br_queue_enq`, `br_rebuild_inflight`, `br_job_for_enq`, `br_rebuild_wait`, `br_enqueue_dup_race` |
| `0300-stamp.txt` | `STAMP`, `br_model`, `br_count`, `br_knob_num`, `flag_on`, the resolver cron single-flight, the resolver modules |
| `0400-br-note-conflict-lines.txt` | conflict notes, recurring paths, fix-round files (`br_round_begin`, `br_round_end`), `br_yield_request` |
| `0500-br-prov-promote.txt` | `br_prov_promote`, the conductor handoff (`br_conductor_emit`, `br_handoff_rows`, `br_from_conductor`) |
| `0600-br-rank-rows.txt` | `br_rank_rows`, the br-reviews block (`br_review_verdict`, `br_lead_pick`) |
| `0700-br-lead-review.txt` | `br_lead_review`, `br_open_prs`, `br_from_reviews`, `br_round_robin` |
| `0800-br-finished.txt` | `br_finished`, `br_cost_rank`, `br_record_index`, `br_prepass` |
| `0900-br-epoch-or-zero.txt` | the visited ledger, `br_starved_alert`, the br-token block, the start of the br-rest block |
| `1000-br-pr-ref.txt` | `br_pr_ref`, `br_close_pr`, `br_hold_issue`, `br_hold_gate` |
| `1100-br-board-status.txt` | `br_board_status`, the board-done and rung hold gates, `br_needs_human_park` |
| `1200-br-resolve-merged.txt` | `br_resolve_merged`, `br_park_time`, the merged-PR checks, `br_ticket_id` |
| `1300-br-enqueue-fresh.txt` | `br_enqueue_fresh`, CI reruns, the queue batch reads, `br_mechanical` |
| `1400-br-is-sha.txt` | the supersede guard (BH-1642): `br_is_sha`, `br_judged_head`, `br_supersede_guard` |
| `1500-br-rebuild-fresh.txt` | `br_rebuild_fresh`, `br_rebuild_settle` |
| `1600-br-rebuild-retry.txt` | `br_rebuild_retry`, `br_setup_blocked` |
