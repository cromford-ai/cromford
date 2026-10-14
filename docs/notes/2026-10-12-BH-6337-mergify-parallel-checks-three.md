# Mergify builds 3 speculative batches at once, not 8 (BH-6337)

Doc: MERGIFY

`max_parallel_checks` for this repo's own queue went from 8 to 3.
The value is in `config/mergify/repos/cromford.conf`. `.mergify.yml` is its render, and `bin/mergify-template.sh --check` keeps the two equal.
No settings row feeds the renderer. Mergify reads only the committed `.mergify.yml`.

Why: a failed or dequeued lower batch restarts every batch above it.
On 2026-10-12 #5920 failed 4 batches.
One manual dequeue (#6039, 22:32Z) restarted #6327 (#5443 + #5454). The restart cost about 25 min.
Most batches ran the full corpus, 25 to 30 min each. With 8 in flight, each restart threw away up to 7 of those runs.
the operator approved the change on 2026-10-12. The trade is lower peak merge throughput for fewer discarded corpus runs.

The template ceiling stays at 8 (`INTS["max_parallel_checks"]` in `bin/mergify-template.sh`).
`scope_default_capacity` is 1, so it stays at or below the new value.

Revisit rule: review the value again after #5454 (the batch runs only changed-fingerprint suites) and the pre-queue learned-suite gate merge.
If a batch then costs about 10 min and the batch failure rate is below 20%, raise the value again.

Rollback:
1. Set `max_parallel_checks=8` in `config/mergify/repos/cromford.conf`.
2. Run `bin/mergify-template.sh render config/mergify/repos/cromford.conf` and copy the value into `.mergify.yml`.
3. Run `bin/mergify-template.sh --check`. It must print `ok: cromford.conf renders and matches .mergify.yml`.
4. Change the pins in `tests/mergify-template.bh-1673-test.sh` A11 and `tests/mergify-config.bh-6337-test.sh` C1/C2.
