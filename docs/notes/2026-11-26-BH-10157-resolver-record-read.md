# BH-10157: the resolver's discovery reads on the PR record (C1 of BH-9937)

Part of #9926 (wave 5 of 7), slice C1 of #9937. Refs #9937.

Doc: OPERATING

## What changed

- New knob `GH_SOURCE` for lane `blocked-resolver`
  (`catalog/lanes.d/blocked-resolver.knobs.d/GH_SOURCE.json`). Settings row
  `lane.blocked-resolver.gh_source`. Default `shadow`.
- The seam `bin/lib/prr-shadow.d/blocked-resolver.sh` is no longer empty. It
  defines `brs_open_record`, `brs_open_norm`, `brs_state_record` and
  `brs_state_norm`. It makes no GitHub call.
- New fragment `bin/blocked-resolver.d/bh-10157-record-discovery.sh`. It pins
  the step once per run (`prr_pin blocked-resolver`) and holds the GitHub side
  of each read.
- `br_open_prs` (`bin/blocked-resolver.sh`) reads the open list through
  `brd_open_read` when the fragment is loaded. The answer shape and the
  per-tick file cache do not change.
- The bh-9369 closed-PR retire (`bin/blocked-resolver.d/bh-9369-closed-pr-retire.sh`):
  - `bcr_load_one` reads no closed-list page in step `record`. The stored set
    and the watermark stay. The store is rewritten only when a row is past
    the `BR_CLOSED_PR_KEEP_DAYS` cut.
  - `bcr_is_closed` gets the state word from `brd_row_word`, after the open
    veto and the `rebuild-*` check. Only a url of a repo this run loaded is
    peeked. A row already said keeps its stored word with no peek.
  - `$BCR_RETIRED_OUT` lines are `<url>\t<word>\t<at>`. An old url-only line
    still reads. `bcr_commit_one` adds a store row `<n> <word> <at> 1` for a
    record retire that no closed page listed. The next tick then skips the
    row in discovery (BH-9029, `retired_skipped`).

## The three steps for this lane

| step | open list (`br_open_prs`) | row state (`bcr_is_closed`) | closed pages |
|------|---------------------------|-----------------------------|--------------|
| `off` | GitHub | this tick's closed pages | read |
| `shadow` | GitHub; the record is compared | closed pages; one peek per row is compared | read |
| `record` | the record; a miss reads GitHub | the record; a miss reads `pulls/<n>` once | not read |

In `shadow`, a difference writes one line to `logs/prr-shadow.log`:

- `PRR_SHADOW lane=blocked-resolver key=<owner/repo>#open ...` for the open list.
- `PRR_SHADOW lane=blocked-resolver key=<owner/repo>#<n>@state ...` for a row.

A record `open` and "no closed page lists the PR" are the same answer, not a
mismatch.

In `record`, a miss writes `PRR_MISS lane=blocked-resolver key=<k> why=<word> fallback=github`.
The record step also writes one lane-log line per repo per tick:
`closed-PR read for <slug>: record step — no pages read, each row's state comes from the PR record`.

## What GitHub still serves in step `record`

- The open list, when the record list misses (`stale`, `no-sync`,
  `truncated`, `unknown`, `field:<f>`, `unreadable`).
- One `pulls/<n>` read for a row whose record peek misses.
- The per-PR reviews read in `br_from_reviews`, and every read in `br_one`
  and the fix-round path.

## Not in this slice

- The per-PR wake gate (`bin/lib/prr-seen.sh`) on the reviews read of
  `br_from_reviews`. The ticket names only `br_open_prs` and the
  `bcr_load_one` closed list. So in step `record`, a tick over unchanged PRs
  still makes one reviews read per open PR. #9937 can file this as one more
  slice.

## Operator steps

1. Wait 48 hours after the deploy in step `shadow` (the default).
2. Count the mismatches on the hub:
   `grep -c 'PRR_SHADOW lane=blocked-resolver' logs/prr-shadow.log`
3. Post the count on #9937.
4. If the count is 0, set the settings row `lane.blocked-resolver.gh_source`
   to `record`. Otherwise keep `shadow`.

To turn the slice off with no settings change, add
`bh-10157-record-discovery` to `BR_OPT_OFF`. Every hook then does today's read.
