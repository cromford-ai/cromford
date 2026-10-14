# Headless session profile (P1)

Every claude call through `bin/agent-call.sh` can run under a per-stage
**session profile** built by `bin/lib/session-profile.sh`. The profile exists
to cut prompt-cache WRITES, which were 60-82% of each sampled hub call's cost
(70-115K tokens written per fresh session) on a fleet spending ~$47.5K a week
notional, almost all on Opus 5.5.

## What the profile does

| Piece | Mechanism | Why |
|---|---|---|
| Cache TTL per stage | `CLAUDE_CODE_PROMPT_CACHE_TTL=5m\|1h` in the child env | On a Claude subscription within plan usage, a `-p` run's main conversation requests the 1-hour TTL, and a 1h write bills at 2x the prompt rate against 1.25x for 5m. One-shot lanes (triage, review, preplan) never idle past five minutes, so the 1h rate buys them nothing. Execute, fix and chat can idle through a long build step and keep 1h. |
| Strict MCP | `--strict-mcp-config --mcp-config <file>` | The file holds only the user MCP servers the stage keeps (default: `codegraph` for plan/execute/fix, none elsewhere), copied verbatim from `~/.claude.json`. The CodeGraph shell CLI still works in a stage without its server. |
| User plugins off | an `enabledPlugins: {<plugin>: false}` settings file, merged BEFORE the iron-law guard | `rules/settings.json` enables the Vercel plugin on every box, and headless triage was loading it. A flag-scope setting outranks user and project settings. The guard stays last, so it still wins every key collision. |
| One prefix across worktrees | `--exclude-dynamic-system-prompt-sections` | cwd, env info, memory paths and git status move from the system prompt into the first user message, so two builds in two worktrees can read one cached prefix. |
| One model, one effort | `--model` as today; `--effort` at most once, at session start, only when `SESSION_PROFILE_EFFORT_MAP` names the stage | A model or effort switch mid-session re-writes the whole prefix. |

`--strict-mcp-config` also drops the servers in a target repo's own
`.mcp.json`. If a lane needs one of those, add its name to that stage's
`SESSION_PROFILE_MCP_MAP` entry and configure the server at user scope on the
box. The map only copies servers from `~/.claude.json`.

**Account routing.** On a routed call, the account's `CLAUDE_CONFIG_DIR` comes
from `ACCT_EXPORTS` and exists only inside the child's subshell.
`agent-call.sh` resolves it there and passes it in, so the plugins forced off
and the MCP servers kept are the routed account's. With a config dir, only
`<dir>/.claude.json` is read for MCP, because that is the only file the CLI
reads.

**A knob flip breaks the cache for resumed sessions.** When the ladder retries
a timed-out attempt with `--resume`, the resumed session gets the profile as
it stands NOW. If a row changed in between (the stage turned on or off, a new
MCP set, a new TTL), the resumed session has a different tool set and cache
key from the one it started with. Its first request re-writes the whole prefix
once. This is expected, and it is one reason to flip rows at a quiet moment
rather than in the middle of a train of builds.

What it deliberately does NOT do: pass `--setting-sources`. The `user` source is
where `/root/.claude/CLAUDE.md` (the fleet rules), the rtk hook and the
codegraph hook live. `SESSION_PROFILE_SETTING_SOURCES` exists for a measured
experiment and defaults to empty.

## Flags verified to exist

Every flag was read off `claude --help` on **2.1.280**, the fleet floor in
`catalog/cli-min-versions.json` (the Opus 5.5 floor): `--strict-mcp-config`,
`--mcp-config`, `--setting-sources`, `--exclude-dynamic-system-prompt-sections`,
`--effort`, `--settings`. The TTL env vars need 2.1.242
(code.claude.com/docs/en/prompt-caching).

## Measured (claude 2.1.282, claude-haiku-4-5, `-p "say ok"`, this repo)

| Run | Cache write | Cache read | Cost |
|---|---|---|---|
| Default | 39,942 at **1h** | 13,856 | $0.082 |
| Profiled, first | 28,855 at **5m** | 17,713 | $0.038 |
| Profiled, second within 5 min | **0** | 46,568 | $0.005 |

## Cost rows

`bin/agent-call.sh` reads the TTL the session's writes ACTUALLY used from the
CLI envelope's `usage.cache_creation` split and tags the row's note
`cache_ttl=5m|1h|mixed`. Observed, never the requested value. The three pricers
agree on one rule. The table's `cache_write` is the 5-minute rate. A 1h write
costs the row's `cache_write_1h` when the table carries one, else 2x the prompt
rate. The three pricers:

- `bin/transcript-cost.sh` already priced per message from the split. It now
  honours an explicit `cache_write_1h`.
- `cost_price_tokens` / `cost_row_price` in `bin/lib/cost-row.sh` take the TTL
  as an optional last argument. With no TTL the result is the same number as
  before.
- `row_cost` in `bin/cost-rollup.sh` reads the note tag.

Most claude rows carry dollars from the transcript, which was already correct.
The fix matters for rows re-priced from tokens, which used to price every write
at 5m.

## Cache-efficiency signal

`bin/cache-hit-report.sh` (hub, daily) now also reads
`state/cost/fleet-cost.csv`. For each stage it takes the last
`CACHE_WRITE_SHARE_CALLS` (20) claude rows and records the write share of the
dollars and the read hit ratio in `logs/cache-lane.csv`. It writes ONE ALERTS
line per stage per day when the write share is above `CACHE_WRITE_SHARE_MAX`
(0.85, which is above the pre-profile baseline). Once the profile is
fleet-wide, lower it toward 0.5. `0` turns the alert off. A built-in
`severity` rule in `bin/lib/alert-state.sh` routes the line at **warn**, so it
goes to the digest and never pages. It does not go through `lane-alert.sh`,
because that would put LLM triage in its path. Old
`flags/alerted-cache-lane-*` markers are pruned on every run. A
`CACHE_WRITE_SHARE_CALLS` value that is not a positive integer, or a reader
error, is logged to `logs/cache-hit-report.log`. This is a
deterministic check with no LLM involved.

## Knobs

Settings rows `lib.session-profile.<env lowercased>` are registered in
`catalog/lanes.d/_lib.session-profile.json`. `lib_env_apply session-profile` in
agent-call applies them. Env on a box works when no row is set.

| Env | Default | |
|---|---|---|
| `SESSION_PROFILE_STAGES` | *(empty = off)* | `all` or a stage list |
| `SESSION_PROFILE_TTL_MAP` | `triage=5m preplan=5m preplan-files=5m review=5m plan=5m eval=5m execute=1h fix=1h chat=1h default=5m` | |
| `SESSION_PROFILE_MCP_MAP` | `plan=codegraph execute=codegraph fix=codegraph default=` | |
| `SESSION_PROFILE_EFFORT_MAP` | *(empty)* | |
| `SESSION_PROFILE_PLUGINS_OFF` | `1` | |
| `SESSION_PROFILE_EXCLUDE_DYNAMIC` | `1` | |
| `SESSION_PROFILE_SETTING_SOURCES` | *(empty)* | |

## Rollout

The profile ships **dark**. With `SESSION_PROFILE_STAGES` empty, the argv and
env are byte-identical to before (`tests/agent-call-session-profile-test.sh`
section A). The tests can prove parity of the invocation, but not parity of
what a model does with fewer plugins or MCP servers loaded. So:

1. **Canary, one lane, one box.** Set `SESSION_PROFILE_STAGES=triage` in one
   box's `env/global.env`. Triage is short, high-volume and only reads.
2. **Watch for 24h.** Compare `logs/cache-lane.csv` for triage against the
   other boxes. The write share should fall and the hit ratio should rise. Also
   check that the cost rows carry `cache_ttl=5m`, that
   `logs/session-profile.log` is quiet, and that triage verdict quality holds
   (alert-triage / failovers).
3. **Fleet-wide short lanes.** Set the
   `lib.session-profile.session_profile_stages` row to
   `triage preplan preplan-files review`.
4. **Long lanes.** Add `plan execute fix`. These keep 1h and codegraph.
5. **Tighten the alert.** Lower `lane.cache-hit-report.cache_write_share_max`
   to the new baseline plus a margin.

Rollback at any step is to delete the row, or empty it. No deploy is needed.

Tests: `tests/agent-call-session-profile-test.sh`,
`tests/cache-ttl-pricing-test.sh`, `tests/cache-lane-efficiency-test.sh`.
