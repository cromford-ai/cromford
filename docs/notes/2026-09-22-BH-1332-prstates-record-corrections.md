# BH-1079 record corrections: the -ge rationale, the gate's lookup, and the suite's count

Doc: EVENTS

Four things the BH-1079 record says that the code does not do. None of them is a
bug in the code — the code is right and unchanged — so this note corrects the
record and nothing else. Per D37 the 2026-09-19 note
(`docs/notes/2026-09-19-BH-1079-prstates-consume-and-epoch.md`) is left
byte-identical; this is the later note that supersedes the parts named below.

## 1. Why the ingest compares `-ge`, and what the tie actually is

**Superseded:** the 2026-09-19 note's "Not *strictly newer*" paragraph, the
matching sentence in `docs/verification-map/triage-shard-ticket-fp.md`'s "An
ingested pair carries the GATE's epoch" bullet, the comment above
`triage_prstates_ingest` in `bin/lib/triage-shards-lib.sh`, and the header of
case (B5) in `tests/triage-shards-prstates.bh-1079-test.sh`. All four said the
gate writes `queuefp` and "the tick's own REST refresh stamps the ledger inside
the same tick", so a fresh vector routinely carries the second it is replacing.

That is not the mechanism. `bin/run-triage.sh` stages `gate scope shards
launch`, and inside the shards stage `bin/lib/rt/shards.sh` calls
`triage_prstates_ingest`, then `triage_prstates_refresh`, then
`triage_prstates_prune`. The refresh runs AFTER the ingest and builds its
needs-a-lookup list by skipping `MERGED`/`CLOSED` and then skipping every row
whose stamp is younger than `TRIAGE_PRSTATES_TTL_S`. A row the ingest just
stamped with the gate's epoch is by definition younger than the TTL, so the same
tick's refresh never re-reads it and never re-stamps it. The refresh cannot
produce the tie it was credited with.

The tie is TWO GATE READS landing in the same wall-clock second. `queuefp` line
3 is written only on the gate's 45-minute lookup branch, with its own `date +%s`
on line 2; two such reads are 45 minutes apart on a box and back to back at test
speed. `tests/triage-shards-ticket-fp-test.sh` case (B) produces exactly that:
the t3 gate read ingests `12=OPEN` at one epoch, line 3 is erased, the stamp is
backdated, and the t5 gate read writes `12=MERGED` at an epoch that is the same
second — a strict `-gt` refuses the merge and the case goes red. (B5) in
`tests/triage-shards-prstates.bh-1079-test.sh` pins the same equality at the
library.

So the rule stands as written: an equal epoch is not an older one. Two reads of
the same GitHub in the same second carry no evidence of staleness, and letting
the later vector land costs one identical rewrite at worst, while a strict
compare drops a real merge and holds the stale value for the gate's whole
45-minute window. `-ge` is correct; only the explanation was wrong, and it is
rewritten in the lib comment, the map page and the (B5) header by this ticket.
The mechanism is asserted against the real library by
`tests/prstates-record.bh-1332-test.sh` cases (1) and (2).

## 2. The gate's lookup is `gh_rest_pr_state`, not `gh pr view`

The 2026-09-19 note's "Both PR lookups consult `bin/lib/gh-budget.sh` before
they spend" bullet calls the gate's side "the gate's own `gh pr view` loop". It
has not been one since BH-1015 review round 2: the queue branch of
`bin/triage-gate.sh` builds `PRV` from a loop over `$PRNUMS` calling
`gh_rest_pr_state` out of `bin/lib/gh-rest.sh`, upper-cased, with `ERR`
collapsing the whole vector to empty. That is the same reader the ledger's
refresh uses, and it is what `tests/gh-app-ratchet-test.sh` keeps raw `gh`
readers out of. The verification-map page already spells it correctly.

## 3. The prstates suite has 45 `ok` call sites, not 60

The BH-1079 rebase commit `777b541` closes with "all 60 assertions in the file
now exercise the real code path and pass". The file has 46 `ok` tokens, one of
which is the `ok()` definition, so 45 assertion sites. That commit message also
ends with a stray `EOF` line and a `)` — a heredoc artifact from how it was
written. Both are in immutable git history and are recorded here rather than
rewritten; the number is quoted nowhere else in the tree.

## 4. `ABSENT` is not terminal

Only `MERGED` and `CLOSED` are on the refresh's skip list. A cached 404
(`ABSENT`) is re-read once per `TRIAGE_PRSTATES_TTL_S` exactly like an `OPEN`,
so a queue line naming a PR before it exists heals on its own. That was true and
unsaid; it now has a line in the map page's "`MERGED` and `CLOSED` are terminal"
bullet so nobody adds `ABSENT` to the skip list by accident, and
`tests/prstates-record.bh-1332-test.sh` case (3) pins the behaviour.

**What it touches:** `bin/lib/triage-shards-lib.sh` (the comment above
`triage_prstates_ingest`, comment lines only),
`docs/verification-map/triage-shard-ticket-fp.md`, the (B5) header in
`tests/triage-shards-prstates.bh-1079-test.sh`, and the new suite
`tests/prstates-record.bh-1332-test.sh`. No behaviour changes: the comparator is
still `-ge` and no executable line moved.
