# Every box now installs, loads and verifies a kernel audit watch on the harness roots

Doc: OPERATOR-SETUP

Incident #388 (2026-09-15, 16:50Z): `/root/harness/{env,bin,prompts,logs,builds}`
vanished from the hub and nothing on the box could say who did it — no record of
the unlink, no pid, no argv. Deliverable (1) of #395 is that a deletion leaves a
line. This is the half that makes the KERNEL write that line. The half that reads
the records is the tailer slice (BH-444) and lands separately.

## What changed

**`bin/audit-install.sh` (new).** Three modes:

    bin/audit-install.sh            install/repair: apt, rules file, auditd.conf knobs, daemon, load, verify
    bin/audit-install.sh --render   print the rules file to stdout; byte-stable, writes nothing
    bin/audit-install.sh --check    print this box's state; rc 1 when something is off; writes nothing

It is idempotent (the rules file is rewritten only when `cmp` says it differs
from a fresh render) and it **exits 0 from every path**. apt refusing, the daemon
refusing to start, or a kernel that will not take the rules is a classed line in
`logs/audit-install.log` plus ONE `logs/ALERTS.log` line a day naming what is
needed and from whom — marker `state/audit-install-denied-YYYYMMDD`, the same
shape `bin/clock-sync.sh` uses, written BEFORE the alert line so a crash between
them costs a line and never a duplicate.

Success is derived from the kernel's own answer, never forward-written: step 6
counts `auditctl -l` by KEY (`-k harness` / `key=harness`, never by path —
`/root/harness` is itself a watched root) and a count short of the roots is
`rules NOT loaded: expected=N loaded=M`, never "installed".

**`bin/update-runners.sh`** calls it right after the `harness-sync.sh` call.
`bin/` and `cron/` already ride harness-sync; the audit rules file and the auditd
package do not, and this is the leg that carries them to every box. The script's
exit-code contract (non-zero ONLY when the crontab reconcile refuses) is
unchanged.

**`bin/bootstrap-machine.sh`** gains two steps in `== packages ==`: the box
timezone is set to UTC (systemd branch via `timedatectl`, everything else via the
`/etc/localtime` symlink — Orgo boxes have no systemd, PID 1 is `init.sh`), and
then the installer runs with `HARNESS` pinned to the live tree.

## Knobs, and where they live

`AUDIT_INSTALL`, `AUDIT_ROOTS`, `AUDIT_LOG_MB`, `AUDIT_LOG_KEEP`,
`AUDIT_RULES_FILE`, `AUDITD_CONF`, `AUDIT_SUPERVISOR_DIR`, `AUDIT_SYSTEMD_DIR` —
every one is in `env-templates/global.env.example`, commented out at the code's
real default. Kill switches: `AUDIT_INSTALL=0` or `flags/audit-off`, both of
which stop the install path before it writes anything while leaving `--render`
and `--check` answering (a silent rc 0 from `--check` would read as healthy).

`AUDIT_SBIN_PATH` is deliberately NOT in the template: it is the test seam that
lets a suite drive the "auditctl is not installed" box on a machine that has
auditd, and it is documented in the script's own header.

## Rung: BUILT, not LIVE

The real apt install, the real auditd start and the real kernel rule load are
not exercised by this build — the builder box must not install auditd or load
rules, so every path the suite drives is redirected into a scratch tree with
stubs on PATH. A container also needs `CAP_AUDIT_CONTROL` for the load to
succeed at all. The live witness is the first post-merge `fleet-propagate` run
plus `bin/audit-install.sh --check` on each box.

## Commands

    # what would be written, and this box's state
    bin/audit-install.sh --render
    bin/audit-install.sh --check

    # the suite
    HARNESS_TEST_SANDBOX=1 bash tests/audit-install.bh-443-test.sh
