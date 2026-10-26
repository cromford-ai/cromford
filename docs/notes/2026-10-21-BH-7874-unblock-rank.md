# The pool builds first the tickets that unblock the most open work (BH-7874)

Doc: FLY-POOL-RESPAWN-CAP

## What happened

On 2026-10-21 example-org/project-6 had 201 open `ai-build` tickets. 121 of them
waited on another open ticket through `Blocked-by:`. TK-1219 blocked 17
tickets, but `hotfix_first` in `bin/fly-pool.sh` walked every plain row in age
order. TK-1219 started planning only when the queue was 62 deep and the oldest
row had waited 448 minutes.

## The rule

`hotfix_first` prints, in this order:

1. hotfix rows;
2. conductor `RB-*` and `RR-*` rows;
3. dispatch-now rows;
4. the rest, by unblock count, highest first. Equal counts keep the age order.

The unblock count of ticket X is the number of distinct open `ai-build` issues
of the same repo that name X in a `Blocked-by:` or `Needs:` line, directly or
through a chain. The walk is cycle-safe, and X never counts itself. A chain
ends at an issue that is not in the open listing.

The line shapes are those of `te_edges_from_text` (`bin/lib/ticket-edges.sh`):
every `#N` on a `Blocked-by` line, the first `#N` on a `Needs` line. `DEPENDS:`
lines do not count. The suite pins this parity.

## The read

`pur_prime` (`bin/lib/pool-unblock-rank.sh`) runs once per tick, before the
REAP. It reads `repos/<slug>/issues?state=open&labels=ai-build&per_page=100`,
page by page, up to `POOL_UNBLOCK_RANK_MAX_PAGES` pages. It writes
`state/pool/<p>/unblock-rank.tsv`. Both `hotfix_first` callers read that file.
No row makes a read.

It does not read when `POOL_UNBLOCK_RANK=0`, when the project has no repo slug,
or when fewer than 2 queued rows (not failed, not RB/RR, not hot) have a
numeric ticket id.

## Knobs

| Knob | Default | Meaning |
|---|---|---|
| `POOL_UNBLOCK_RANK` | 1 | 0 keeps the age order and reads nothing. |
| `POOL_UNBLOCK_RANK_MAX_PAGES` | 10 | The most listing pages per tick (100 issues each). |

## The log line

One line per ranked tick in `logs/fly-pool.log`:

```
unblock rank <p>: issues=<n> pages=<n> read=<s>s rank=<s>s listing=<ok|truncated> top5: <KEY>=<n> ...
```

`top5: none` means no queued row has a count above 0.
`unblock rank <p>: off (listing unreadable: <code|body|parse>) — age order`
means the tick used the age order. The tick line `pool <p>: queued=...` does
not change.

## Fail-open cases

All of these give the age order, which is the order before BH-7874:

- a knob set to 0, or no repo slug;
- a page that answers other than 200, a `TIMEOUT`, or a body that is not a
  JSON array (the cache of an older tick is not used);
- a job file that is not JSON (it counts 0 and keeps its age slot);
- an order that does not hold exactly the input files.

## Cost

One jq and two awk processes for the whole listing. The suite ranks a
1,000-issue listing in about 30 ms on the build box. The read costs at most
`POOL_UNBLOCK_RANK_MAX_PAGES` x `POOL_GH_READ_TIMEOUT_S`, before the SPAWN
walk's budget clock starts.
