# BH-2652 (BH-2613.4): account, model, fan-in and record libs have no literal root

Doc: LIB-ROOT-RESOLUTION

Part 5 of 5 of #2613. It applies the contract in
`docs/notes/2026-09-26-BH-2613-lib-root-resolution.md` (rules 1-6) to ten libs
and deletes their ten baseline files under `tests/fixtures/root-fallback-baseline/`.
Their 23 counted sites are now 0. `tests/lib-root-records.bh-2613-test.sh` pins it.

The root is `${HARNESS:-${H:-}}`. `builds-of-record` and `restore-drill-orgo`
already read H first and keep `${H:-${HARNESS:-}}` (rule 1), and
`backup-freshness` keeps its positional root first. On a box every entry point
sets H or HARNESS before it sources these libs, so the answers there are
unchanged.

## What each lib answers with no root

| Lib | No-root answer |
|---|---|
| `pool-account` | `_pa_h`, `_pa_quotadir`, `pool_account_tokens_dir` and `pool_account_lease_dir` print "" (`QUOTA_DIR` and `POOL_TOKENS_DIR` still win). Max leases is the default 4, the lease count is 0, and cooldown, prune, release, unpin and the lease's pin and lease files write nothing (rc 0). `pool_account_armed` answers `no_tokens_dir` rc 1 (unarmed). With no root and no `POOL_TOKENS_DIR` it answers before it asks the routing switch, because the switch cannot arm anything there. With `POOL_TOKENS_DIR` set the switch is still asked. `harness_env_dir` is never called with an empty root. |
| `session-profile` | No log line. `session_profile_build` still applies the profile (rc 0, same TTL and args) but writes no MCP or plugin override file, which is the "could not write, MCP left as the box configures it" branch an unwritable state dir already takes. |
| `lane-model` | model-route.sh is loaded from the sibling copy only. When it cannot load, the answer is rc 75 as before, with no ALERTS line. |
| `fanin` | `fanin_begin` opens no ledger (`FANIN_FILE` unset, the same as a failed mkdir), so enumerate and account are no-ops. `_fanin_report` still writes its summary to the caller's `$log` and sends no lane alert. |
| `fc-board` | `fc_file_board` reads no env file, so it finds no token and files nothing (`fc_board_base` has already refused before that point). |
| `file-children` | fleet-conf.sh and the fc modules are loaded from the sibling copy only. `fc_board_base` returns 1 (missing base) before it reads any env dir, so `file_children` files nothing. |
| `builds-of-record` | `bor_local_dir` returns 2 (not found). `bor_union` prints the DB rows only. |
| `backup-freshness` | `bf_facts_local` gives the unreadable-tree line (no stamp, no switch, no marker), which `bf_state_age` reads as `missing`, never `ok`. `bf_rows` prints only the hub row, `missing`. The `lane_switch` stub it defines when lane-switch.sh cannot load reads `flags/` under HARNESS, then H, and answers "off is not set" with no root. |
| `restore-drill-orgo` | `remote` still makes the Orgo call and returns the same rc. It writes no `logs/restore-drill.log` line. |
| `verdict-parse` | `verdict_window` reads lane-gate.sh from the lib's own install root. The catalog default is the same, so every parse is identical. `_vp_alert_unresolved` sends no alert and stamps no flag, and an unresolved window still reads `unknown`. |

## file-children dedupe with no root

The filed-child ledgers are `$FC_BUILD/children.txt` and
`$FC_BUILD/children-board.tsv` (read at `bin/lib/fc-board.sh:96` and `:110`,
and `$FC_BUILD/children.txt` at `bin/lib/fc-issues.sh:108`). Both live in the
caller's build dir, never under the root. So no root changes nothing about
"files nothing twice". The suite seeds a filed ledger and checks that neither a
no-root run nor an H-only run refiles or rewrites it.

## Entry points (rule 4)

- `bin/file-health-ticket.sh` now sets `H="${HARNESS:-/root/harness}"` before it
  sources file-children.
- `bin/lane-probe.sh` is not edited. It already sets
  `H="${HARNESS:-/root/harness}"` (line 21) before it sources lane-model (line 36).
  The suite pins that order.

## Left for other slices

- The `B=/root/harness` in `bf_remote_probe`'s heredoc is the path on the remote
  box, and the ratchet does not count heredoc bodies.
- `bin/lib/lane-gate.sh` (`_lg_h`), which `verdict_window` and the routing
  switch load, and `bin/jobs-client.sh`, which the fleet cooldown row loads,
  still have their own literal defaults.
