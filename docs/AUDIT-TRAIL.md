# The audit trail

On 2026-09-15 the hub's `/root/harness` was deleted by one of our own test runs
(#388). The box came back, but nothing anywhere said which process did it, from
which working directory, or under which build. We had to reconstruct it from
what was missing.

The audit trail closes that. The kernel records every delete, rename and
truncate under the harness roots, and a cron lane reads those records every five
minutes and alerts on them. Two scripts:

| script | what it does | cron |
|---|---|---|
| `bin/audit-install.sh` | writes the auditd rules (syscall rules per existing root, key `harness`), keeps auditd running and proves it records | daily, per box |
| `bin/audit-tail.sh` | reads `ausearch -k harness`, collapses events into bursts, logs and alerts | `*/5` on every live box |

This doc is about the whole trail. The installer half is a separate slice and
lands in its own PR; what it writes is described here because that is what the
tailer reads. Until it lands, a box has no `harness` audit rules and the tailer
says so once a day (see "audit is BLIND" below) rather than going quiet.

## What is watched

Syscall rules, not watches (BH-9173). The kernel records only the classes the
tailer reads: delete (`unlink`, `unlinkat`, `rmdir`), rename (`rename`,
`renameat`, `renameat2`) and truncate (`truncate`, `ftruncate`). One rule per
root that exists, tagged with the key `harness`. For `/root/harness`
(`HARNESS`) the rules file starts with `never` rules, which the kernel matches
first:

```
-a never,exit -F arch=b64 -S rename,renameat,renameat2 -F dir=/root/harness/state
-a never,exit -F arch=b64 -S rename,renameat,renameat2 -F dir=/root/harness/logs
-a never,exit -F arch=b64 -S rename,renameat,renameat2 -F dir=/root/harness/locks
-a never,exit -F arch=b64 -S rename,renameat,renameat2 -F dir=/root/harness/tmp
-a never,exit -F arch=b64 -S unlink,unlinkat,rmdir -F dir=/root/harness/locks
-a never,exit -F arch=b64 -S unlink,unlinkat,rmdir -F dir=/root/harness/tmp
-a never,exit -F arch=b64 -S unlink,unlinkat -F dir=/root/harness/state/gh-etag
-a always,exit -F arch=b64 -S unlink,unlinkat,rmdir,rename,renameat,renameat2,truncate,ftruncate -F dir=/root/harness -k harness
-a always,exit -F arch=b64 -S unlink,unlinkat,rmdir,rename,renameat,renameat2,truncate,ftruncate -F dir=/root/orchestrator -k harness
-a always,exit -F arch=b64 -S unlink,unlinkat,rmdir,rename,renameat,renameat2,truncate,ftruncate -F dir=/etc/harness -k harness
-a always,exit -F arch=b64 -S unlink,unlinkat,rmdir,rename,renameat,renameat2,truncate,ftruncate -F dir=/root/.ssh -k harness
```

Why the `never` rules. The BH-443 rules were `-w <root> -p wa`: every write and
attribute change. On 2026-11-06 the hub's 1G cap held only 2 hours. The top
paths were atomic tmp+mv writes under `state/` and lock churn under `locks/` and
`tmp/`. None of it was a wipe. So renames under `state/`, `logs/`, `locks/` and
`tmp/`, and deletes under `locks/` and `tmp/`, are not recorded. Deletes under
`state/`, `logs/`, `builds/`, `bin/`, `env/`, `prompts/` and `cron/` stay
recorded: a wipe ends in the `rmdir` of each top-level dir. A `never` rule is
rendered only for a subdir that exists.

Unlinks under the cache dirs of `state/` (BH-9363). After BH-9173 the hub still
filled one 50M file in about 45 minutes: 45,913 of its 46,080 events were
`unlinkat`, most of them routine cache evictions under `state/`. So the render
adds one `-a never,exit ... -S unlink,unlinkat -F dir=/root/harness/state/<path>`
line for each path that the composed catalog (`catalog/state-paths.d/`) classes
`cache`, plus `gh-rest-ledger` and `lane-runs` when the catalog classes them
`box-local`. These lines come after the other `never` lines and before every
`always` line. A line is rendered only for a path that is a real directory (not
a file and not a symlink) with a plain name (no `.` or `..` segment). `rmdir`
stays recorded, so a wipe of `state/` still leaves the `rmdir` of each dir.
Nothing under `flags/` is excluded: a deleted pause flag is a security event.
A new `cache` fragment is excluded at the next daily install with no edit to
the installer. If the catalog cannot be composed (no builder, no `jq`, a
refused fragment), the render has no such line and the trail records more.

What is no longer recorded: an open with `O_TRUNC` (`> file`). The tailer still
classes one as `truncate` if a record has one, but the rules do not ask for
`open`/`openat`, which would bring back most of the noise. A rename from a
`never` dir to another place (`mv /root/harness/state /tmp/x`) is not recorded.

The roots are `AUDIT_ROOTS` (default `/root/harness /root/orchestrator
/etc/harness /root/.ssh`). Both scripts read the same variable, so the reader
watches what the writer installed. A trailing slash on a root is stripped before
anything is matched, so `/root/harness/` and `/root/harness` mean the same thing.
A root that does not exist is not rendered: the kernel refuses `-F dir=` on a
missing path (`Error sending add rule data request (No such file or
directory)`, project-3-2). With no root at all, the installer alerts once and writes
no rules file.

auditd.conf bounds the log at `max_log_file = 50` x `num_logs = 5` (250M), and
`admin_space_left_action`, `disk_full_action` and `max_log_file_action` are all
`ROTATE`. The old `disk_full_action = SUSPEND` stopped project-3-2 from recording for
2 days with no alert.

A dead trail is never "healthy". The installer and `--check` read the age of
`audit.log` first (STALE after `AUDIT_STALE_H`, default 6 hours, while rules are
loaded). Then they write and remove one probe file (`.audit-probe.<pid>.<n>`)
under the first root and ask `ausearch -k harness -f <probe> -ts recent` for its
record. A miss sends `auditctl --signal resume` and probes once more. A second
miss is `audit trail DEAD` and one alert a day. The probe's delete reaches the
tailer as one `class=delete n=1 sev=info` line.

## Where the logs are

| file | what is in it |
|---|---|
| `/var/log/audit/audit.log` | the kernel's own record, rotated by auditd |
| `logs/audit-tail.log` | one line per burst, plus this lane's own status lines |
| `logs/audit-install.log` | what the installer did, or why it could not |
| `logs/ALERTS.log` | the BLIND alert, the installer's denied alert, and every burst that reached `lane-alert.sh` |
| `state/audit-tail.checkpoint` | how far `ausearch` has read (owned by ausearch; `.prev` is our copy) |

## How to read a burst line

A burst is every event with the same pid, command and class. `rm -rf` of a tree
is thousands of kernel records and one thing that happened, so it is one line:

```
AUDIT class=delete n=1 path=/root/harness/env/global.env more=0 root=/root/harness syscall=unlinkat pid=4242 ppid=4100 comm=rm exe=/usr/bin/rm cwd=/root/worktrees/cromford-bh-405 auid=root ses=3 lane=build:cromford/BH-405 first=09/15/2026_12:00:01.123:4567 last=09/15/2026_12:00:01.123:4567 sev=critical claim=/root/harness/state/claims/cromford/BH-405
```

(That line comes from `tests/fixtures/audit/single-unlink.txt`, so you can
reproduce it without waiting for a real deletion. The suite drives it against a
scratch claims directory, so the `claim=` it prints there points into the
scratch tree; on a box it is the real `state/claims` path shown above.)

Field by field:

| field | meaning |
|---|---|
| `class` | `delete`, `rename` or `truncate` |
| `n` / `more` | events in the burst, and `n-1` |
| `path` | the first path the burst touched |
| `root` | which watched root it fell under |
| `syscall` | the first syscall of the burst (`unlinkat`, `renameat2`, `openat`, ...) |
| `pid` `ppid` `comm` `exe` `cwd` | who did it, and from where |
| `auid` `ses` | the login uid and audit session — these survive `su` and `sudo` |
| `lane` | `build:<project>/<KEY>`, `cron:<script>`, or `unresolved` |
| `first` / `last` | `<timestamp>:<serial>` of the first and last event |
| `sev` | `critical` (paged) or `info` (logged, no page) |
| `claim` / `session` | the claim file or the `pipeline.log` that proves the lane |

Two shapes to know:

- **spaces are `%20`.** A path, cwd or exe with a space in it is written with
  `%20` so the line stays parseable as space-separated `key=value` pairs.
- **timestamps are strings, with `_` where a space was.** `ausearch -i` renders
  dates in the box's locale. We never parse them and never re-render them, so
  what you read is exactly what the kernel record said.
- **a missing field is `-`.** An event with no cwd record reads `cwd=-`, never
  an empty value.

`lane=unresolved` means exactly that: the burst could not be tied to a build or
a cron lane. It is never a guess. A worktree named `<project>-slot<n>` and a
directory nobody has a claim for both stay unresolved.

## Severity: what pages and what does not

`sev=critical` when any of these is true:

- the burst touched a protected prefix: `<root>/env`, `<root>/bin`,
  `<root>/prompts`, `<root>/cron`, `<root>/fleet.conf`, or `/root/.ssh`,
  `/root/orchestrator/bin`, `/etc/harness`;
- the burst removed a directory (`rmdir`, `unlinkat` with `AT_REMOVEDIR`, or a
  PATH item that was a directory);
- the burst is at least `AUDIT_PAGE_MIN` events;
- `AUDIT_PAGE_ALL=1`.

Otherwise `sev=info`: a line in `logs/audit-tail.log` and an `info` alert, which
reaches `logs/ALERTS.log` and the beat, and pages nobody. A build deleting its
own claim file and a log file being truncated are the two everyday cases, and
they are pinned as negatives in `tests/audit-tail-test.sh`.

Directory removal is always critical, which includes `bin/disk-clean.sh` pruning
a stale build directory. We would rather hear about that one than miss the wipe
it looks like.

## Alert ids

Every alert carries a stable id, so `bin/lane-alert.sh`'s state machine counts a
repeat instead of sending it again:

| id | from |
|---|---|
| `audit:<box>:<pid>:<serial>` | a burst, where `<serial>` is the audit serial of its first event |
| `tz:<box>` | the timezone check (its own slice) |

The box id comes from `state/box-id`, or `hostname`, or `unknown-box` if neither
answers. Serial numbers restart when a box reboots, so a collision is possible
in theory; it is only visible while the earlier id is still open.

## Knobs

All in the `global.env` selected by `bin/lib/env-path.sh`, normally
`/etc/harness/env/global.env` on fleet boxes. `HARNESS_ENV_DIR` overrides the
directory; a real harness-local `env/` directory is supported for scratch trees.
The pure `--parse` mode reads no env file.

| knob | default | owned by | what it does |
|---|---|---|---|
| `AUDIT_ROOTS` | `/root/harness /root/orchestrator /etc/harness /root/.ssh` | both | which roots are watched and read |
| `AUDIT_MAX_BURSTS_PER_TICK` | `5` | tailer | most `lane-alert.sh` calls in one tick |
| `AUDIT_PAGE_MIN` | `25` | tailer | burst size that makes a burst critical on its own |
| `AUDIT_PAGE_ALL` | unset | tailer | `1` makes every burst critical |
| `AUDIT_LOG_MB`, `AUDIT_LOG_KEEP` | `50`, `5` | installer | how much `/var/log/audit` keeps (250M) |
| `AUDIT_STALE_H` | `6` | installer | hours without a write before audit.log is STALE |
| `AUDIT_PROBE_WAIT_S` | `5` | installer | seconds the probe waits for its record |
| `AUDIT_LOG_PATH` | `log_file` of auditd.conf | installer | the audit log the stale check reads |
| `TZ_CHECK` | see that slice | timezone check | not this lane |

Over the cap, the extra bursts are still logged and one line says how many:
`+N more bursts this tick, see logs/audit-tail.log`. Nothing is dropped
silently.

The cap is spent **critical first**. Everything is logged in the order it was
seen; only the alerting is re-ordered. Without that, a tick holding five log
truncations and one deleted `env/global.env` pages about the log files and
reports the wipe as `+1 more bursts`.

## What the lane does not watch

The tailer and `bin/lane-alert.sh` write under a watched root every time they
run: the lock file `locks/audit-tail.lock` is opened with `O_TRUNC` each tick,
`state/audit-tail.checkpoint` is copied and rewritten, and every alert renames
a fresh file into `state/alerts/`. Each of those is a different pid, so a
different burst and a different `--id`, so nothing dedupes them. Counted, the
harness watching itself would fill the cap on every box, every five minutes.

So three paths under each root never become a burst:

- `<root>/locks/` — this lane's lock and the ~50 other `bin/*.sh` locks
- `<root>/state/alerts/` — `bin/lane-alert.sh` writing its own alert state
- `<root>/state/audit-tail.checkpoint*` — this lane's checkpoint and its `.prev`

Nothing else is excluded. `state/claims/`, `logs/`, `builds/` and the rest of
the tree are still watched, and a wipe of the whole root still trips `env`,
`bin`, `prompts` and `cron`. If you are chasing a deletion in one of the three
excluded paths, `ausearch -k harness -i` still has every record; only the
burst lane skips them.

## Kill switches

| switch | stops |
|---|---|
| `AUDIT_TAIL=0` in the resolved `global.env` | the tailer, before it writes anything at all |
| `flags/audit-off` | the tailer, same |
| `AUDIT_INSTALL=0` | the installer |

The tailer also takes `locks/audit-tail.lock` with `flock -n`. A tick that finds
the lock held exits 0 and writes nothing: the lock is dedupe, never a queue, so
nothing here ever waits for another run.

## The two alerts, and what to do about them

**`[audit-tail] audit is BLIND on this box: <reason>`** — either `ausearch` is
not installed or `auditd` is not running, so deletions under the harness roots
are not being recorded at all. One line per box per UTC day (the marker is
`state/audit-tail-blind-YYYYMMDD`), not one every five minutes. Fix it by
running `bin/audit-install.sh` on that box, or installing auditd there. A box
that cannot see must not be quiet about it.

**`[audit-install] ... denied`** — the installer could not write the rules or
start auditd, usually because the container has no `CAP_AUDIT_CONTROL`. That is
the installer slice's alert; the tailer will report BLIND on the same box until
it is resolved.

## Forensic commands

Run these on the box itself:

```sh
# everything the harness key caught in the last ten minutes, interpreted
# (`recent` is ausearch's own word for ten minutes ago)
ausearch -k harness -i -ts recent

# from a specific time (the format ausearch accepts, local to the box)
ausearch -k harness -i -ts 09/15/2026 12:00:00

# what the tailer itself saw
tail -n 50 /root/harness/logs/audit-tail.log

# re-run the parser over a saved capture, changing nothing
ausearch -k harness -i -ts today > /tmp/cap.txt
/root/harness/bin/audit-tail.sh --parse < /tmp/cap.txt
```

`--parse` is pure: stdin in, burst lines out. It opens no lock, reads no env
file and writes nothing, so it is safe to run on a box mid-incident.

The `--checkpoint` file is how the cron lane avoids re-reading what it has
already seen. If it is invalid or the log it pointed into has rotated away,
the lane removes it, says so in `logs/audit-tail.log`, and re-reads a bounded
window. If `ausearch` fails for any other reason, the previous checkpoint is put
back and nothing is consumed: the next tick reads the same events again.
