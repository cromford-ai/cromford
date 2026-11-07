# The audit installer records only what the tailer reads, and never SUSPENDs (BH-9173)

Doc: AUDIT-TRAIL

## Why

Measured 2026-11-06. The BH-443 rules were `-w <root> -p wa -k harness`, so the
kernel recorded every write and attribute change under `/root/harness`. The
tailer keeps only deletes, renames and truncates. Every box sat at the 1G cap
(`num_logs=10` x `max_log_file=100`), and the hub's 1G held about 2 hours. The
top paths were atomic tmp+mv writes under `state/` and lock churn under
`locks/` and `tmp/`. On project-3-2 the audit log reached 979M, the disk reached 95%,
auditd hit `admin_space_left` with its default `SUSPEND`, and it recorded
nothing from 2026-11-04 21:31. On box-project-4-1 the last record was
2026-10-03. `--check` called both boxes healthy.

## What changed

- `bin/audit-install.sh --render` writes syscall rules. First the `-a
  never,exit` rules for `HARNESS` (renames under `state/ logs/ locks/ tmp/`,
  deletes under `locks/ tmp/`, no key), then one
  `-a always,exit -F arch=b64 -S unlink,unlinkat,rmdir,rename,renameat,renameat2,truncate,ftruncate -F dir=<root> -k harness`
  per root. No `-w`, no `-p wa`.
- Only roots that exist are rendered, trailing `/` stripped. The kernel refuses
  `-F dir=` on a missing path. `EXPECT` is the number of `-k harness` rules.
  With no root at all, the install path writes one alert and no rules file, and
  `--check` prints `harness roots: none exist` and answers rc 1.
- auditd.conf: `max_log_file = 50`, `num_logs = 5` (250M), and
  `max_log_file_action`, `admin_space_left_action`, `disk_full_action` all
  `ROTATE`. The installer no longer writes `SUSPEND`.
- A dead trail is never healthy. After the load is verified, the install path
  and `--check` read the age of the audit log (STALE after `AUDIT_STALE_H`
  hours). Then they write and remove one probe file under the first root and
  ask `ausearch -k harness -f <probe> -ts recent` for its record. A miss sends
  `auditctl --signal resume` and probes once more. A second miss is one
  `audit trail DEAD` alert a day, rc 1 from `--check`, and no `rules loaded`
  line from the install path. A probe file that cannot be written is its own
  class (`probe: could not write <root>`), never "dead".
- The `auditctl -R` fallback first runs `auditctl -D -k harness` and deletes
  each rendered never rule, so the old `-w` watches leave the kernel.
- `--check` now writes, when rules are loaded: one probe file (removed at once),
  maybe `auditctl --signal resume`, and an alert on a stale or dead trail. With
  no auditctl or no rules loaded it still writes nothing.

## Knobs

`env/global.env`, listed at their real default in
`env-templates/lanes/300-auditd-watcher.env.example`: `AUDIT_LOG_MB` (50),
`AUDIT_LOG_KEEP` (5), `AUDIT_STALE_H` (6), `AUDIT_PROBE_WAIT_S` (5),
`AUDIT_LOG_PATH` (empty = `log_file` of auditd.conf). `AUDIT_NOW` is a test
seam only.

## Not recorded any more

An open with `O_TRUNC`, and a rename out of a never dir (`mv
/root/harness/state /tmp/x`). A wipe still ends in `rmdir` of each top-level
dir, and deletes under `state/ logs/ builds/ bin/ env/ prompts/ cron/` stay
recorded.

## Tests

`tests/audit-install.bh-9173-test.sh` (render, conf, stale, probe, fallback
load), `tests/audit-tail-syscall-rules.bh-9173-test.sh` (an `rm -rf` of the new
rules' record shape is one critical delete burst), and
`tests/audit-install.bh-443-test.sh` moved to the new premise.
