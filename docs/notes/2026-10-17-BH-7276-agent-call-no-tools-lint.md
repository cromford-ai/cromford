# A new bin/agent-call.sh call must turn tools off or say why (BH-7276)

Doc: TESTING

## Why

A classifier prompt that carries a job log, a PR body or a fetched page is attacker
text. Without `AGENT_CALL_NO_TOOLS=1`, `bin/agent-call.sh` starts claude with the full
tool set and `--dangerously-skip-permissions` as root. The UNTRUSTED fence is not a
control. PR #6862 shipped a classifier like that. Sibling classifiers set the flag by
habit, and nothing enforced the habit. Ten lead-review BLOCKs in 14 days had this cause.

## What changed

`bin/agent-call-no-tools-lint.sh` is a new delta lint. It is the `agent-call-no-tools`
row in `catalog/rules-pack.tsv`, so the CI `lint` job and the lead review run it on
every PR. Each finding line carries the text `auth-bypass`, so the ALWAYS-BLOCK table
keeps it a BLOCK.

The lint reads the lines a diff adds under `bin/**/*.sh` (not `bin/agent-call.sh`
and not the lint itself). An added line that calls `/agent-call.sh <argument>` is red
unless one of these is true:

1. `AGENT_CALL_NO_TOOLS=1` is in the same command: the call line, or an earlier line
   of the same command that ends in `\`.
2. An `export ... AGENT_CALL_NO_TOOLS=1` line is earlier in the same function. For a
   top-level call, the `export` is at column 0 earlier in the file.
3. The line directly above the command is the marker, with a reason of 10 characters
   or more:

```bash
# agent-call-tools: lane edits files in its own worktree
out=$("$H/bin/agent-call.sh" --stage x < "$prompt")
```

A diff is also red when it removes more `AGENT_CALL_NO_TOOLS=1` tokens from a file than
it adds there, and adds no valid marker in that file.

A line that is already on the fork is never judged. The 85 existing call sites do not
change.

Run it by hand: `bin/agent-call-no-tools-lint.sh --base origin/main .` (rc 0 clean,
rc 1 findings, rc 2 bad args or no git).

## Blind spots

- An indirect call through a variable (`"$AC" x`, `$AGENT_CALL x`) is not judged.
- An untracked file is not in `git diff`, so it is not judged.
- Function scope comes from a text walk-back, not a shell parser.
- A string with a `/` before the name and an argument after it
  (`echo "$H/bin/agent-call.sh x"`) reads as a call.
