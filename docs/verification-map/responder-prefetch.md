# Watchdog responder: prefetched evidence

**What it is:** `bin/watchdog-responder.sh` gathers, in bash, the evidence its
prompt used to send the model looking for — each persisted owed-stale ticket's
thread (through `bin/board-fetch.sh`), its live decision fields, and the state of
any open PR matching the key (`gh pr list` then `gh pr view --json
state,mergeStateStatus,headRefOid`) — caps the whole rendered prompt, and then
spends TWO calls instead of one open-ended investigation:

1. a DECISION call with `AGENT_CALL_NO_TOOLS=1`, 900s, answering one
   `DECISION: <project>:<key> :: <class> :: none|act :: why` line per item into
   `logs/responder-decide.txt`;
2. today's tooled ACT call (same invocation, same 2400s, same playbook steps
   2-5, same `logs/responder-run.txt`) — only when a parsed decision says `act`.

Zero parsable decisions fails OPEN to call 2: the lane exists because silence
under a watchdog page is the failure, so a broken decision step must degrade to
today's cost, never to quiet. On that path call 2 gets a DIFFERENT step 1 — no
DECISIONS block is rendered, so it is told to classify and act on every item
itself instead of being pointed at decision lines that are not there. This is
not a rare branch: `bin/agent-call.sh` refuses `AGENT_CALL_NO_TOOLS=1` on any
runner but claude, so every pass on a hub whose triage runner fell back to
`codex` takes it. BH-654; the lane was carrying a median 4.27M input tokens per
call ($559 over 68h) before this.

**How an operator reaches it:** `cron/hub.cron` `*/20` on the hub, and on demand
through `bin/watchdog-poll.sh` command type `respond`. Nothing sources this
script as a library and nothing parses its stdout.

**How to drive it:**

| what | how |
|---|---|
| the whole lane, fixtures and all | `bash tests/responder-prefetch-test.sh` (8 sections; section 8 runs the shipped file under `HARNESS=<scratch>`, which is cron's shape) |
| the rendered prompt, by eye | `RESPONDER_DRY=1 /root/harness/bin/watchdog-responder.sh` — prints the DECISION prompt and exits before the cooldown write and before any agent call. It is NOT side-effect-free on the hub: it still runs `bin/stale-owed-tickets.sh` and can refresh `state/responder/stale-history.json`, which resets the 90-minute persist window. Point `HARNESS` at a scratch tree (what section 8 of the suite does) to read a prompt without touching the live lane |
| its size | `RESPONDER_DRY=1 /root/harness/bin/watchdog-responder.sh \| wc -c` — under `RESPONDER_EVIDENCE_CAP_BYTES` (60000 by default) |
| today's behaviour, for comparison | `touch /root/harness/flags/responder-prefetch-off` then the same dry run: one tooled call, today's prompt, byte for byte |
| the no-tools contract this lane depends on | `bash tests/agent-call-notools-test.sh` |
| the fetcher it calls | `bash tests/board-fetch-trim-test.sh` |

**Files it owns on a live box:**

- `state/responder/stale-history.json` — the previous `state/stale-owed.json`
  snapshot plus its epoch; the 90-minute persist window is evaluated against it.
- `state/responder/handled.json` — the 12h spend cooldown, keyed
  `<project>:<key>`. Written AFTER both calls, on every pass including a failed
  one, so a crashing session burns the cooldown instead of retry-looping.
- `logs/responder.log` — one line per pass, then one line per parsed decision
  (`<utc> <project>:<key> <class> -> none|act <why>`), plus one per ignored line.
- `logs/responder-decide.txt` — the decision call's output. **The only text the
  decision parser reads.** A ticket comment or title containing
  `DECISION: x:y :: e :: act :: …` can never buy a tooled session, and rendered
  client text is flattened to one line so it cannot reach the start of one.
- `locks/responder.lock` — `flock -n`, dedupe only: a slow pass is SKIPPED, never
  queued.
- a `mktemp -d` evidence cache per pass, removed on EXIT. No cross-run state is
  added by the prefetch.

**Knobs** (all optional, documented in `env-templates/global.env.example`):
`RESPONDER_THREAD_COMMENTS` (10), `RESPONDER_EVIDENCE_CAP_BYTES` (60000),
`RESPONDER_PR_CALLS_MAX` (12). Kill switches: `flags/responder-disabled` (the
whole lane), `flags/responder-prefetch-off` (back to today's single tooled call).

**What must never regress:**

- **MISSING is not empty.** A failed board list, a 500 on a thread, a project
  with no board API prefix, a gh read that could not run: each renders
  `EVIDENCE MISSING for <project>:<key> — <reason>` and never a THREAD block with
  no comments in it. A session on partial evidence must not read like one on full
  evidence.
- **"None found" is not "we did not look."** `PRs: none open matching <KEY>` only
  when the search ran; `PR state: MISSING (gh budget low | rc=N | repo not in
  fleet.conf | gh call cap …)` otherwise.
- **The cap cuts the OLDEST comments.** Thread recency is law, so the end of the
  thread is what survives, and every drop says so (`[capped: …]`).
- **A MISSING item escalates, it does not go quiet.** The decide prompt routes
  an item whose evidence could not be fetched to `act`, because the action owed
  is the "evidence unavailable" escalation. Deciding `none` on it would skip
  call 2 and stamp its 12h cooldown, so a page nobody could read would go silent
  for half a day.
- **The act paths are untouched.** Call 2 keeps its tools, its timeout, its
  playbook and its beat; this change only changes what the model is given. The
  "do not re-read" sentence covers ONLY what the prefetch actually fetched —
  ticket threads and board lists. Step 2d's live PR check (review decision, who
  it waits on) and step 2e's duplicate check before a launch (branches, the
  build queue, the pool, the owning box's running builds) read state the prefetch
  never touches and are still owed. 2e is the dedup-before-spend guard in front
  of `run-build.sh`; a prompt that forbids it buys duplicate build sessions.
