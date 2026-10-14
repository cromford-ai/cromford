# Break-risk score routes risky PRs to a size-1 solo queue (BH-5430)

Doc: MERGIFY, MERGE-CONDUCTOR

## What changed

- New `bin/lib/queue-risk.sh`: `qr_score` sums cheap signals (shared libs, CI config,
  registries, generated files, the share mirror, schema, new tests, diff size, prior culprit
  verdicts, a prior pre-queue red) into a break-risk score. `qr_enqueue_step` runs inside
  `mc_enqueue_mergify` (marked block `# >>> queue risk (BH-5430)`), after the partition block
  and before the `merge-queue` label. rc 0 always: it never holds a PR.
- Every weight, glob set, size limit, the threshold and the mode are `queue_risk.*` settings
  rows, seeded in `worker/jobs/schema.sql`. `queue_risk.mode` is seeded `shadow`.
- `bin/mergify-template.sh` takes an optional `solo_label=` conf key. It renders a `solo` queue
  (batch_size 1) between `hotfix` and `default`, a rule routing the label to it, and a
  `-label=<solo_label>` on the default rule. The order lint now requires hotfix, solo, default.
  `cromford.conf` sets `solo_label=queue-solo`; `.mergify.yml` carries the blocks.
- New D1 table `queue_risk_scores` (upsert per repo+pr+head) behind `POST`/`GET /api/queue-risk`,
  and a BREAK RISK column on Mission Control's MERGE QUEUE table.

## Why

On 2026-10-08 one risky PR failed its batch of 8 and every speculative batch stacked behind it,
and Mergify's bisect held all merges for more than 1.5 hours.

## Not in this change

Disjoint-impact batching (BH-4979 / #5373), culprit ejection without a bisect (#5110, #5372,
#5373) and the wasted/saved batch minutes view (#5374) are other tickets.
