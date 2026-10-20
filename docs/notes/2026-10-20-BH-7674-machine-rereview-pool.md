# A Fly conductor run queues its re-review on the pool (BH-7674, slice C2 of #7635)

Doc: MERGE-CONDUCTOR, FLY-POOL

## Problem

On a lane-run machine, `mc_rereview_spawn` had one answer: write the word
`rereview` to `MC_PR_DEFERRED_FILE` and return rc 3. Slice C0 turned that
word into a keyed hub tick of the PR, so the hub still ran the re-review of
every project-6-os PR that a Fly run reached. Slice C1 taught the pool to run
an `RR-<pr>-<head8>` row, but nothing put one.

## What changed

1. Producer. With `conductor_remote_spawn.<project>` on and a pool app
   (`mc_remote_on`, the switch the pool rebase uses), `mc_rereview_spawn` on a
   machine runs the same checks as on the hub (`rrjob ... done`, the
   `noverdict` and `prov` reasons). Then it calls
   `mc_remote_rereview_spawn` (`bin/lib/mc/spawn-remote.sh`) and writes no job
   file. With the switch off, the machine path is the same as before: the
   word `rereview` and rc 3.
2. The row. Key `RR-<pr>-<head8>`, target `fly`, meta
   `{kind:"rereview",slug,url,pr,reviewed,head,reason,dedup,by:"machine"}`.
   The url is built from the conductor's slug, so the hub apply names the job
   file that `headbound_review` reads. `reviewed` is 40 hex or `-`.
3. The row word map (`mc_remote_rereview_row`, one queue read):

   | Row | Outcome | Spawn answer |
   |---|---|---|
   | no row | none | put, rc 0 |
   | queued or claimed, younger than `MC_REBASE_POOL_TIMEOUT_SECS` (5400 s) | running | rc 0, no put |
   | queued or claimed, older, or no `enqueued_at` | stale | hand back, rc 3 |
   | done + `REREVIEWED` or `REREVIEW_NOVERDICT`, same meta reason | ok | rc 4, no put |
   | done + `REREVIEWED` or `REREVIEW_NOVERDICT`, another reason | ok | put (a new read of the same key) |
   | done + `REREVIEW_LANE_FAILED`, `REREVIEW_SETUP_FAILED`, `REREVIEW_DEFERRED`, or status failed | failed | put while attempt < `conductor_remote_retry_max` (3), else hand back |
   | done + an empty reason or another first word | empty | hand back |
   | dropped, ready, any other status | defer | hand back |

   A queue read failure, a put failure, a head that is not 40 hex or no jobs
   client also hands back. A hand-back writes `rereview` and the PR key, so
   C0 runs a keyed hub tick of that PR.
4. Consume. The hub job files `state/merge-conductor/rereview/$repokey_*`
   ride in the `merge-conductor` snapshot (`.rw`), so the next Fly tick reads
   the verdict that the C1 reap wrote. The deletes of the `lanefail` and
   `failed` arms ride back under compare-and-set. The `done` arm uses the
   `.out` beside the job file when the hub `out_file` path does not exist on
   the machine.
5. No second spend. On a machine, a job file in state `none` and a row that
   reads `running` make `headbound_review` take the `running` arm. It takes
   no daily cap unit and puts nothing.

## Log lines (`logs/merge-conductor.log`)

- `<slug>#<n> remote rereview queued <dedup> as RR-<n>-<head8> (attempt <a>)`
  (after `queue_put` answered rc 0 only).
- `<slug>#<n> remote rereview <dedup> in flight (<status>)`.
- `<slug>#<n> remote rereview <dedup> result on record (<word>)`.
- `<slug>#<n> remote rereview <dedup> deferred to the hub (<why>)`, before
  the C0 route line names the keyed hub tick.
- `<slug>#<n> REREVIEWING <head8> — pool row RR-<n>-<head8> <status>; nothing waits on it`.

## A hub job file on the machine

The `.rw` snapshot carries the hub's `running` job files too. Their pid is a
hub pid, so on a machine (`MC_ON_MACHINE=1`) `mc_rr_state` does not check it
with `kill -0`. A non-terminal file reads as `running` by age only, until
`MC_REREVIEW_TIMEOUT_SECS`. Without this, the machine failed a live hub job,
spent the PR's one `rereviewretry` and bought a second read of the head.

## Turn it off

Set `conductor_remote_spawn.<project>=0`. That also turns off the pool rebase.

## Tests

`tests/mc-remote-rereview.bh-7674-test.sh` (M1-M18, C1-C6, RT1-RT3, AC1,
AC2). AC1: a Fly run that hits a rebase and a re-review puts 2 pool rows
(`RB-*`, `RR-*`), writes no deferred word, and the C0 gate takes no hub tick.
`tests/mc-spawn-remote.bh-6888-test.sh` S19 now expects the RR row.

## Not verified here

A live project-6-os Fly tick that puts an `RR-*` row, and a pool machine that
answers it. That needs the hub, the pool and a real HEAD_MOVED PR.
