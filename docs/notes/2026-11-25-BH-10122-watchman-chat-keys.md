# BH-10122: watchman flags keys pasted into the Archie chat

C1 of BH-9423. Several keys were pasted into the Telegram chat with Archie
between 2026-10-05 and 2026-10-08. Watchman now finds a key-shaped value in
the chat and files it for rotation, as it does for a secret in git history.

## Source

`WM_CHAT_LOG` (lib knob of `staff-watchman`, default
`/root/orchestrator/conversation-log.md`). This is the record file that
`bin/orc-context.sh append` writes for every Telegram, Slack and dash turn
(`bin/orchestrate.sh`). The inbox message file is deleted after it is read, so
this log is the only chat text the hub keeps.

A record is a valid header line `### <iso> · <lane>` up to its last non-blank
line before the next valid header. A `### ` line that is not a valid header
stays in its record. Text before the first valid header is skipped (one log
line).

## Scan

`bin/staff/watchman-collect.sh` runs `wm_chat_scan` once a tick, before the
history scans:

1. Each record not in `state/staff/watchman/chat/scanned` (sha256 of the
   record) is copied, without its header line, to a private temp dir.
2. One pinned gitleaks run: `gitleaks dir <tmp> --redact=100`. The run limit
   is the history scan limit (`WM_SCAN_TIMEOUT_S`, inside the tick budget).
3. Only `RuleID`, `File` and `StartLine` are read from the report. `Secret`,
   `Match` and `Message` are never read.
4. A new location goes to `chat/leaks.jsonl`. Then ONE beat at
   `WM_PAGE_SEVERITY` (`staff-watchman-chat-<epoch>`). Then the records are
   marked scanned. `scanned` keeps only records still in the log.
5. A failed run (gitleaks rc, timeout, a report that is not a list, a cache
   write) marks nothing. The `WM_SCAN_FAIL_ALERT`-th failure in a row is one
   warn beat `staff-watchman-scanfail-_chat-<epoch>`.

## Finding

Class `chat-secret`. Item:
`{check:"chat-secret", at:<record iso>, record:<sha12>, part:"message"|"reply", line:<n>, rule}`.
`line` counts from the first line of the part (`OPERATOR:` or `REPLY:`). The
title names the time, the part, the line, the rule and the record. It never
names the value. The lines share the claim window with history-secret lines.
The allowlist does not apply to them.

The soul (`prompts/staff/watchman-soul.md`) points the issue body to the same
six-line rotation checklist, plus one line: delete or edit the chat message
where the chat allows it.

## Metric

`bin/staff/watchman-metric.sh` adds C, the live chat locations (an open
finding, or never printed), to `live_unrotated_secrets`. The detail gets
` chat=<C>` only when `chat/leaks.jsonl` exists.

## The October gap

The chat log is rolling (`ORC_CONTEXT_MAX_BYTES`, 400 KB). The records of
2026-10-05..10-08 are found only if the hub log still holds them. The
orchestrator's Claude transcripts are not scanned: a turn prompt embeds the
log tail, so one paste would be many locations, and a dedupe by value would
need the value.

## Turn it off

Set `WM_CHAT_LOG` to empty in the env file of the box. The cached findings
still print until their issues close.

Test: `tests/staff-watchman-chat.bh-10122-test.sh`.
