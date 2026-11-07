# The auditd watcher (installer + rules on every box)

**What it is:** `bin/audit-install.sh` — the lane that makes the KERNEL record
every delete, rename and truncate under the harness roots. Incident #388 (hub wipe, 2026-09-15): at
16:50Z `/root/harness/{env,bin,prompts,logs,builds}` vanished and nothing on the
box could say who did it. This installs auditd, writes one rules file of syscall
rules on each existing root under key `harness` (with `never` rules for the
harness churn first, BH-9173), bounds the log rotation, loads the rules,
VERIFIES the load against `auditctl -l` and proves a record with a live probe. The tailer that reads those records
is the sibling slice (BH-444) and is not called from here.

**How an operator reaches it:** it is not a screen. Two callers, both on every
box:

| caller | when |
|---|---|
| `bin/update-runners.sh` (right after the `harness-sync.sh` call) | every `cron/<box>.cron`, 05:17Z daily |
| `bin/bootstrap-machine.sh` (`== packages ==`, after the cron/supervisord block) | once, when a box is bootstrapped |

Both call it guarded and fail-open: the script exits 0 from every path, so
neither caller's exit-code contract changes.

**How to drive it:**

| what | how |
|---|---|
| the rules file it would write | `bin/audit-install.sh --render` — 3 `#` header lines, the `-a never,exit` lines for `HARNESS`, then one `-a always,exit ... -k harness` line per existing root; byte-stable across runs |
| this box's state | `bin/audit-install.sh --check` — rc 0 when everything is in place and a probe is recorded, rc 1 otherwise; with rules loaded it writes and removes one probe file and alerts once on a stale or dead trail |
| a bad argument | `bin/audit-install.sh bogus` — 3-line usage on stderr, rc 2, nothing written |
| the whole lane, stubbed | `HARNESS_TEST_SANDBOX=1 bash tests/audit-install.bh-443-test.sh` and `HARNESS_TEST_SANDBOX=1 bash tests/audit-install.bh-9173-test.sh` |

`--check` prints these lines, in this order (`audit.log:` only when rules are
loaded):

```
auditctl: installed | NOT installed
harness roots: N of M exist | none exist (AUDIT_ROOTS=...)
harness rules: present (N always, M never) | absent | DIFFERS from --render
daemon (systemd|supervisord|bare): running | not running
loaded harness rules: N (expected M)
audit.log: written Nh ago | STALE Nh (AUDIT_STALE_H=6) | STALE (<path> absent, ...)
probe: recorded | recorded after resume | NOT recorded | could not write <root> | skipped (<why>)
kill switch: none | AUDIT_INSTALL=0 | flags/audit-off
```

**Files on a live box:**

| thing | where |
|---|---|
| the rules | `/etc/audit/rules.d/harness.rules` — rewritten only when it differs from `--render` |
| the rotation knobs | `/etc/audit/auditd.conf` — `max_log_file`, `num_logs`, `max_log_file_action = ROTATE`, `space_left_action = SYSLOG`, `admin_space_left_action = ROTATE`, `disk_full_action = ROTATE` (never SUSPEND) |
| the supervisord program (no-systemd boxes) | `/etc/supervisor/conf.d/auditd.conf` — `[program:auditd]`, `command=/sbin/auditd -n` |
| its own log | `logs/audit-install.log`: `rules loaded, n=N, daemon=<mode>` / `no change (…)` / `rules NOT loaded: expected=N loaded=M` / `auditd was suspended; resumed (probe recorded)` / `trail DEAD (probe not recorded after resume): …` / a classed failure line. N is the number of existing roots |
| the alert | `logs/ALERTS.log`, one line a day, `[audit-install] … NEEDED FROM OPERATOR/OPS: …` |
| the dedupe marker | `state/audit-install-denied-YYYYMMDD` — written before the ALERTS line, same shape as `bin/clock-sync.sh` |

**Knobs** (`env/global.env`; every one is listed in
`env-templates/global.env.example` at its real default):

| knob | default |
|---|---|
| `AUDIT_INSTALL` | `1` (0 = off) |
| `AUDIT_ROOTS` | `/root/harness /root/orchestrator /etc/harness /root/.ssh` |
| `AUDIT_LOG_MB` | `50` |
| `AUDIT_LOG_KEEP` | `5` |
| `AUDIT_STALE_H` | `6` |
| `AUDIT_PROBE_WAIT_S` | `5` |
| `AUDIT_LOG_PATH` | empty (`log_file` of auditd.conf) |
| `AUDIT_RULES_FILE` | `/etc/audit/rules.d/harness.rules` |
| `AUDITD_CONF` | `/etc/audit/auditd.conf` |
| `AUDIT_SUPERVISOR_DIR` | `/etc/supervisor/conf.d` |
| `AUDIT_SYSTEMD_DIR` | `/run/systemd/system` |

Kill switches: `AUDIT_INSTALL=0` or `flags/audit-off` (shared with the tailer
slice). Both stop the install path before it writes anything; `--render` and
`--check` still answer and name the switch that is on, because a silent rc 0
from `--check` would read as a healthy box.

**Preconditions:** the container needs `CAP_AUDIT_CONTROL` (and a kernel audit
socket no other auditd already owns) for the rules to LOAD. Without it the
install half still completes and the script says so — one ALERTS line a day
naming what is needed — and never claims the rules are loaded.

**Verify it works:** on a box, `bin/audit-install.sh --check` answers rc 0 with
`loaded harness rules: N (expected N)` (N = the roots that exist, 4 on the hub)
and `probe: recorded`, `auditctl -l` lists the `never` rules before the
`always` rules, and `logs/audit-install.log` ends in
`rules loaded, n=N, daemon=<mode>` (or `no change (…)` on every later day).

**Manual-only / not automatable here:** the real apt install, the real auditd
start and the real kernel rule load cannot be exercised in a build — the builder
box must not install auditd or load rules, so every path the suite drives is
redirected into a scratch tree with stubs on PATH. The live witness is the FIRST
post-merge `bin/fleet-propagate.sh` run plus `logs/audit-install.log` on each
box. This entry is written at rung BUILT, not LIVE.
