# The overlap schedule releases a dead claim from another harness (BH-3951, slice 4 of BH-3943)

Doc: SCHEDULER

## What changed

`bin/overlap-schedule.sh` source 3 puts a key the jobs ledger lists as `claimed`,
with no plan file list on this box, into `OVERLAP_UNJUDGED`. That key is in
INFLIGHT, so the candidate loop skipped it. When the build behind the claim had
died on another harness, the ticket stayed out of every schedule for good. project-4
logged `OVERLAP_UNJUDGED TK-2020` on every tick.

New `bin/lib/claim-age.sh`:

- `claim_ages <project>` makes one `GET /api/queue?project=<p>&status=claimed` and
  prints `key<TAB>claimed_by<TAB>claimed_at<TAB>updated_at<TAB>age_min`, first row
  per key wins. rc 2 (no `_jobs_req`, a failed request, a body that is not
  `{queue:[...]}`) is unreadable, never "no claims".
- `claim_age_min <iso>` gives whole minutes since a stamp (0 for a future one),
  rc 1 when it does not parse. `CLAIM_AGE_NOW` pins the clock for tests.

`bin/overlap-schedule.sh` (new block 3b), only when there is an unjudged key and
the mode is not `--hot-for`:

- The stderr line gains ` (age <n>m by <box>)` when an age was read. With no age
  it is byte for byte what it was.
- A key is RELEASED for this run only when all of these hold: the TTL is above 0;
  `claimed_by` is not `${JOBS_BOX:-$(hostname)}`; `claimed_at` and `updated_at`
  are both at least TTL minutes old; `bin/fleet-conf.sh <p> repo` gives a slug;
  and `open_pr_for_key <slug> <K>` (`bin/lib/open-pr-precheck.sh`, BH-3948) returns
  rc 1. In `--key` mode only the asked key is judged.
- Released means it leaves INFLIGHT, the candidate loop places it like any
  unplanned ticket, and stderr says
  `OVERLAP_RELEASED <K> claim by <box> <n>m, no PR, no heartbeat`.
- The marker `state/overlap-released/<p>/<K>.<claimed_at, alphanumerics only>` is
  created noclobber, and only the run that created it calls
  `bin/lane-alert.sh --id overlap-released-<p>-<K> --severity warn`. No marker, no
  alert. A full run with a ledger answer deletes markers whose key is no longer
  claimed.

The knob is `OVERLAP_CLAIM_TTL_MIN` (lib `overlap-claim-ttl`, settings row
`lib.overlap-claim-ttl.overlap_claim_ttl_min`, then env, then `env/global.env`,
default 360 minutes, 0 = off).

## Why it is safe

Nothing is written to `build_queue` and nothing is locked. The release is
recomputed every run, so if the other harness opens a PR or heartbeats again, the
next run keeps the key UNJUDGED. `bin/overlap-guard.sh` at launch is unchanged and
still the backstop. Every unreadable answer (no ledger rows, an unparseable
stamp, no slug, a PR read rc 2, a missing lib) keeps today's behaviour. The
common path, with no unjudged key, makes no new request.

`bin/plan-overlap.sh`'s launch-time OVERLAP_UNJUDGED line is not changed: it never
defers on that key, so it does not keep a ticket stuck.

Suite: `tests/overlap-claim-ttl.bh-3943-test.sh`.
