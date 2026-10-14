# Sentry reporter for bash lanes (BH-5617)

**What it is:** `bin/lib/sentry-report.sh` defines
`sentry_report <level> <lane> <reason> <message> [extra-json] [tags-json]`.
`tags-json` adds string tags; the five standard tags win on a clash. It sends one
event to the Sentry project of `HARNESS_SENTRY_DSN` (`cromford-harness`) when a
lane fails in a way that was only a log line before. It always returns 0 and
prints nothing.

**How it is reached:** three call sites, each behind `command -v sentry_report`:
- `_ae_gates` in `bin/lib/autoenqueue.sh`, on the G2 `ledger` skip
  (lane `merge-conductor`, reason `autoenqueue-ledger-unreadable`);
- `bin/review-prs.sh`, after `rpool_init`, when `RPOOL_CAP_BY=tmp` and
  `RPOOL_K` is below 3 (lane `review-prs`, reason `review-prs-tmp-capped`).
  `rp_tmp_capped_report` in `bin/lib/review-prs-tmp.sh` decides and measures;
  the lane sends at most once per box per
  `REVIEW_TMP_CAPPED_REPORT_S` (default 86400, marker
  `state/review-prs-tmp-capped.last` = `<epoch> <concurrency>`, shared by
  every project on the box). Inside the window it sends once more when the cap
  drops below the last reported concurrency; the same or a higher cap is not
  sent (BH-6132). `extra` holds `free_mb`, `tmp_min_mb`, `worker_tmp_mb` (knob
  `REVIEW_WORKER_TMP_MB`, default 256), `threshold_mb`, `tmp_path`, `fstype`,
  `top` (the three largest entries at the top of the tmp path, `{path, mb}`),
  `concurrency`, `project` (BH-6130), `trigger` (`window` or `cap_lowered`) and
  `previous_concurrency` (the last reported cap, null when unknown, BH-6132);
- `mc_fanin_outcome` in `bin/lib/fanin.sh`, once per (PR, head) on a
  `WORKER_DEADLINE` kill (lane `merge-conductor`, reason
  `conductor-worker-deadline`). `bin/merge-conductor.sh` sources the lib.
  The event carries a `step` tag and the extra fields `step`, `step_s` and
  `earlier`, the worker's step trail at the kill (BH-6346).

**Preconditions:** `HARNESS_SENTRY_DSN` in `env/global.env` (a secret, never a
knob). `SENTRY_MAX_PER_FP_HOUR` resolves through `lib_env_apply sentry-report`
(settings row `lib.sentry-report.sentry_max_per_fp_hour`, registry default 6,
0 = off). Kill switch: `flags/lane-off-sentry-report` or its `pause_flags` row;
`all-off` stops it too.

**Drive it:** `HARNESS_TEST_SANDBOX=1 bash tests/sentry-report.bh-5617-test.sh`
(fake curl, no network). On the hub, an operator probe:
`. bin/lib/lane-gate.sh; . bin/lib/sentry-report.sh; sentry_report info manual bh-5617-probe probe`
with the env of `env/global.env` loaded.

**Verify it works:**
- `state/sentry-report/<key>.sends` gains one epoch per attempt (key = the
  first 16 hex of `sha1sum` of `lane|project|reason`);
- the Sentry Issues list of `cromford-harness` shows one issue per fingerprint,
  tagged `lane`, `project`, `box`, `harness_sha`, `reason`;
- `logs/sentry-report.log` holds only the exceptions: `dsn-malformed`,
  `cap-unresolved`, `capped`, `ledger-unwritable`, `send-failed` (with the
  HTTP code, the curl rc and the first 300 bytes of Sentry's answer).

**What usually lies:**
- A quiet log is not proof of a send: an HTTP 200 writes no line. Read the
  `.sends` ledger or the Sentry issue list.
- A capped fingerprint writes one `capped` line an hour and is silent after it.
- An attempt is counted before curl runs, so a `.sends` line is an attempt, not
  an accepted event. A `send-failed` line in the same second says which.

**Manual-only:** the live Sentry issue list needs the Sentry UI (org
`operator`). No suite sends to the real project: `tests/lib/scratch.sh`
unsets `HARNESS_SENTRY_DSN`.
