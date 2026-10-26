# Security audit runner (cloudflare/security-audit-skill), capped; the pilot is owed (BH-7910)

Doc: OPERATING

## What shipped (slice C0)

- `bin/security-audit.sh <project> [--out <dir>] [--cap-usd <n>] [--cap-minutes <n>] [--again]`.
  It runs one whole-repo audit with the cloudflare/security-audit-skill, in a scratch clone of the
  target's `main`. The live checkout is only read for its origin url.
- The skill is pinned. `catalog/security-audit.conf` names `skill_sha`
  (`c1c8a8c1471069fb0e188eeaff69b8e8db6564a8`, the same sha as BH-7911's
  `prompts/security-classes/PROVENANCE.md`). The runner checks out that sha, refuses (rc 3) when
  HEAD is another sha and names the sha it found, installs with
  `npx skills@<skills_cli_version> add <verified clone> --skill security-audit -a claude-code -y --copy`,
  and refuses (rc 4) when the installed `SKILL.md` is not the verified file.
- Before the install, the runner removes the target's `.claude/`, `.mcp.json`, `CLAUDE.md` and
  `CLAUDE.local.md` from the clone, so no hook, MCP server or instruction file of the target runs in
  the session. `neutralized.txt` lists each removed path.
- The session goes through `bin/agent-call.sh` stage `audit`. The model comes from the route
  `stage.audit` (seeded from `stage.execute` rung 0, no model literal).
- Caps: settings rows `security_audit.cap_usd` (60) and `security_audit.cap_minutes` (240). A flag
  wins over the row, and the row wins over the conf. The runner polls every `poll_s` (30 s). The cost
  is the larger of the audit rows in `logs/cost.csv` (this project, this host, since the start) and
  the live transcript cost (`bin/transcript-cost.sh`). The ledger row lands only when the call
  ends, so the live transcript is the meter that stops a session. The runner finds it the way the
  CLI names it: `projects/<slug>`, where every non-alphanumeric character of the clone's physical
  path is `-` (so `.scratch-<pid>` is `--scratch-<pid>`), under the caller's config root and under
  every `CLAUDE_CONFIG_DIR` in `env/accounts.d/*.env` (account routing can run the child there).
  A capped run keeps that live cost in `summary.json`. At either cap it stops every process of the
  session (TERM, then KILL after 30 s). A stopped run keeps the `findings.json` and
  `coverage-ledger.json` already on disk. `AGENT_CALL_BUDGET_USD_AUDIT=<cap-usd>` is a second bound.
- Dedup before spend: a completed run with the same target sha and skill sha makes no call
  (`SKIP already-audited`). A capped or failed run does not block a new run. `--again` overrides.
- Sandbox: `bin/security-audit-sandbox.sh --detect` picks `docker`, else `unshare-n`, else `none`.
  `unshare-n` uses `unshare -n`, else `unshare -rn` when the box's root has no CAP_SYS_ADMIN in its
  own namespace (the pool builder of this build: `unshare -n` failed, `unshare -rn` worked). It does
  not make the rest of the filesystem read-only, and the prompt says so. With `none`, the skill keeps
  leads at `needs_validation` and executes nothing; a valid pilot outcome, not a failure.
- `summary.json`: project, run, sha, skill_sha, started, ended, duration_min, cost_usd, cost_source,
  stopped (`completed | cap-usd | cap-minutes | failed`), failed_reason, sandbox, counts
  (confirmed, needs_validation, rejected), counts_note, validators (findings, ledger), agent_rc, caps.
  A count is `null` when `findings.json` is missing or is not a findings list. A validator is `null`
  when its input file is absent. `cost_usd` is `null` when no cost source answered.
- Output: `<out>/<project>/run-<N>/`, default `$BUILD/security-audit` (a build artifact that
  `bin/fetch-artifact.sh --path` reaches), else `$HARNESS/state/security-audit`. `security-audit/` is
  git-ignored. No finding is filed anywhere.
- The lane is a draft and OFF: `catalog/context-budgets.d/7910-security-audit.json` (stage `audit`,
  placeholder ceiling, no `context_kill_tokens`) and no cron line.
- The iron law SECURITY AUDIT (2026-10-21) is in `rules/topics/16-security-audit.md` and
  `prompts/iron-laws.d/20261021-security-audit.md`, byte-identical to BH-7911's copies.

Assumed, to verify on the pilot: the skill's `findings.json` is a list of records with a `verdict`
field (or an object that carries the list as `.findings`), and its validators take the file path as
their first argument. `counts_note` names any verdict that is not one of the three.

## The pilot (OWED to slice C1)

This build ran on a pool machine that cannot read `example-org/project-2` (`git ls-remote` rc 128)
or `github.com/cloudflare/security-audit-skill` (CONNECT 403). The pilot runs on
`box-project-2-1`, which owns `/root/repos/project-2`. Start it from the console, with
no ssh (BH-8375): a `run_script` command, project `project-2`, payload
`{"script":"security-audit-launch.sh","args":["project-2"]}`. Read the numbers with args
`["--status","project-2"]` after the run ends. The steps are in
`docs/notes/2026-10-26-BH-8375-security-audit-console-launch.md`.

| item | value |
|---|---|
| cost USD | OWED (C1) |
| duration (minutes) | OWED (C1) |
| confirmed / needs_validation / rejected | OWED (C1) |
| sandbox used | OWED (C1) |
| validators (findings, ledger) | OWED (C1) |
| stopped | OWED (C1) |

Share of `confirmed` findings a reader would act on: the operator: <to fill>

Top 3 `confirmed` findings (attack class, file:line, one plain sentence): OWED (C1).

## Lane cadence

The recommendation needs the measured cost per run, so it is OWED (C1). The formula, per project:

- weekly additive: 4.3 x (cost per run) per month
- monthly: 1 x (cost per run) per month

The pilot measures the first full run only. The cost of a later additive run is not measured.
