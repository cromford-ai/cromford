# Review pool cap counts vCPU and tmpfs; static resolv.conf after a reboot (BH-5337)

Doc: OPERATING

## What happened

On 2026-10-08 at 00:00Z the lead-review tick on box-small logged
`concurrency capped at 10 by memory (11231MB free, 1024MB a worker)` and started
10 pooled reviews on a 16 GB box with a 12 GB tmpfs `/tmp` (the ticket
records 4 vCPU; since its 00:23Z restart the box reports 8 vCPU). By 00:10Z
the box could not reach GitHub, and it was rebooted at 00:23Z. After the reboot
`/etc/resolv.conf` was a dangling link to `../run/systemd/resolve/stub-resolv.conf`,
so the box had no DNS.

## What changed

1. `rpool_init` (`bin/lib/review-pool.sh`) has a cpu term: vCPUs /
   `<P>_WORKER_CPUS` (default 1). The memory default `<P>_WORKER_MEM_MB` went
   from 1024 to 700 for lead-review (the measured 545 MB peak of one worker's
   process tree on box-small, 2026-10-12, plus 25%) and to 2048 for
   review-prs (not measured). The code fallback is 2048, used only when the
   registry cannot be read. When `/tmp` is tmpfs, the memory term is
   (MemAvailable - tmpfs used) / (`<P>_WORKER_MEM_MB` + `<P>_WORKER_TMP_MB`).
   The smallest of cpu, memory and tmp wins. The cap line is now
   `concurrency capped at N by cpu|memory|tmp (...)`; the tmp reason changed
   from `by /tmp (...)` to `by tmp (/tmp ...)`. `RPOOL_CAP_BY` has the new value
   `cpu`. `<P>` is `LEAD_REVIEW` or `REVIEW`; both knobs are registry knobs of
   both lanes, so a settings row changes them.
2. `bin/dns-guard.sh` is new. It runs first in `bin/update-runners.sh` and in
   `bin/bootstrap-machine.sh`. See OPERATING, "DNS after a reboot".
3. The settings refresh on lane entry was already on main
   (`_lg_env_apply` calls `_lg_settings_refresh`). It is now pinned by
   `tests/lane-env-refresh.bh-5337-test.sh`, which includes a row that is new
   since the stale cache was written. No code changed for it.

## Operating

- A box that must run more reviews than its vCPU count sets
  `LEAD_REVIEW_BOX_MAX` (a settings row). `lead_review_worker_cpus` has a
  minimum of 1, so it can only lower the cap.
- A box gets `bin/dns-guard.sh` through `harness-sync.sh`, which runs after the
  guard call in `update-runners.sh`. So the fix first runs on a box's second
  daily run after the merge, or on a new bootstrap.
