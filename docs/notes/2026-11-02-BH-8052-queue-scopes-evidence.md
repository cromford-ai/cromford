# BH-8052: live evidence for the Mergify scopes upload (slice C0)

Doc: MERGIFY, OPERATING

## What changed
- `worker/jobs/schema.d/202611021411-bh-8052-queue-partition-enforce.sql` seeds the settings
  row `queue_partition.mode=enforce` (`INSERT OR IGNORE`). Before this, prod had no row, so the
  conductor ran the code fallback `shadow` and uploaded nothing.
- `qp_enqueue_step` (`bin/lib/queue-partition.sh`) logs one line after each upload with rc 0:
  `PARTITION <slug>#<n>: scopes uploaded on <head12> (HTTP <code>)`, or `(already uploaded)`
  on a ledger hit. The failure line on a serial conf did not change.
- New read-only probe `bin/queue-scopes-evidence.sh <repo>`. It reads the conf, the conductor
  log and the ledger file count. It prints
  `queue-scopes <slug>: queue_mode=<m> ok=<n> failed=<k> ledger=<j> newest=<ok|ok-unproven|failed|none>`
  and the result lines. Exit 0 only when the newest result is an upload, and a 2xx line exists.
- `catalog/live-probes.tsv` row `queue-scopes-uploads` runs it for `cromford`.

## Why
The ticket asks for `queue_mode=parallel`, `queue_partition.mode=enforce` and a live PUT probe.
The flip gates every cromford enqueue, so the BH-1000 rule needs live proof before that
merge. A pool box has no `MERGIFY_CI_KEY`, and the live-probe lane runs GET-only probes. So the
conductor on the hub makes the real PUT, on the serial conf where a failed PUT holds nothing,
and the probe reports what it got.

## What this does not do
- The conf stays `queue_mode=serial`. `.mergify.yml` is unchanged. Queue behavior is unchanged.
- Slice C1 flips `config/mergify/repos/cromford.conf` to `parallel`, re-renders
  `.mergify.yml` from main's conf as it is then, and declares `probe: queue-scopes-uploads`.
  It merges only when the probe says `newest=ok`.
- On a parallel conf, `qp_enqueue_step` writes no `scopes not uploaded` line (the hold reason
  goes to its caller), so after C1 the probe counts successes and the caller logs the holds.

Rollback: `bin/jobs-client.sh setting-set queue_partition.mode off`.
