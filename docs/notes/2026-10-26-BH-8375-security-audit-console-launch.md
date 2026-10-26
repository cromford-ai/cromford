# Security audit: a console start with no ssh; the pilot numbers are still owed (BH-8375)

Doc: OPERATING

## Why

The pilot of `bin/security-audit.sh` (BH-7910) must run on the box that owns
`project-2` (`box-project-2-1`). A build box cannot read the target
repo (`git ls-remote` rc 128). The 2026-10-21 note gave an ssh command. Nobody
ran it. This change gives the start a path through the console, with no ssh.

## What changed

- `bin/security-audit-launch.sh <project>` starts one `bin/security-audit.sh <project>
  --out $HARNESS/state/security-audit` in its own session, with `BUILD` unset. It
  returns at once with one JSON line: `started` (with the runner pid), or
  `already-running` when the runner's lock `<out>/.<project>.lock` is held. The
  detached run writes `logs/security-audit-launch.log`.
- It refuses (rc 3) a name that is not a fleet.conf project, and a start on a box
  with no `/root/repos/<project>/.git`. Any other argv is rc 2, so a console
  command cannot raise the caps. The caps stay the settings rows
  `security_audit.cap_usd` (60) and `security_audit.cap_minutes` (240).
- `bin/security-audit-launch.sh --status <project>` prints the numbers of
  `latest-summary.json`: run, sha, stopped, cost_usd, duration_min, sandbox,
  counts, validators. It prints no finding. No summary is `none`. An unreadable
  summary is `failed`, rc 1.
- `bin/cmd-run-script.sh` reads its allowlist as `catalog/run-script-allowlist.json`
  plus every `catalog/run-script-allowlist.d/*.json` fragment. One bad fragment
  refuses everything. This ticket's fragment is
  `catalog/run-script-allowlist.d/bh-8375-security-audit.json`. The main file is
  unchanged.
- No cron line and no lane entry.

## Operator step: run the pilot

1. Insert a console `commands` row: type `run_script`, project `project-2`,
   payload `{"script":"security-audit-launch.sh","args":["project-2"]}`.
   The hub forwards it to the box that owns the project (BH-6737, `## run_script`).
2. Read the box's answer. The `tail` must hold `"result":"started"`.
3. After the run ends (at most `security_audit.cap_minutes`, 240 minutes), send
   the same command with args `["--status","project-2"]`. Read the line with
   `fetch_log` `which:"run_script"`.
4. Slice C1 records those numbers in a new note, for the pilot table of
   `docs/notes/2026-10-21-BH-7910-security-audit-pilot.md`.

The pilot numbers are OWED (C1). No number exists until step 3 runs.
