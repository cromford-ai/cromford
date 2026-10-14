# 2026-09-19 — BH-1066: review-autopilot honours the agent-call rc, and stops posting twice

Doc: MERGE-CONDUCTOR

Follow-ups from the head-bound review of PR #1050 (BH-1018, `598ce87a`). Four
defects, all in `bin/review-autopilot.sh`, all of the same family: the lane
recorded outcomes it had not checked.

## 1. The agent-call rc was thrown away

`"$H/bin/agent-call.sh" … || true`, and the very next line charged the daily cap.
`bin/agent-call.sh` exits **75/76/77/78/79** when *nothing was called and nothing
was billed* — a lock, no account with headroom, the hub refusing agent build work,
a no-tools refusal, an argv-only or cliff-routed refusal — and leaves a one-line
marker in the out file. That marker is not empty, so the lane treated it as the
review: it POSTED it to the PR, stamped the key `reviewed … verdict=UNPARSED`, and
counted a spend that never happened. The head could then never be reviewed again.

Now the rc is the first fact about the call:

- **75/76/77/78/79** — no key, no cap charge, nothing posted. One log line
  (`agent-call returned before billing (rc=… : <marker>)`, the marker being what
  tells rc 79's two meanings apart), and the next tick buys what was never bought.
- **any other nonzero rc** — it died, billed or unknowable. Counted, parked as
  `failed <stamp> n=<k> rc=<rc>` for `REVIEW_AUTOPILOT_FAIL_TRIES` attempts
  (default 3) then `failed-terminal`, and the out file is **never posted**: a
  partial review or a `CONTEXT KILL:` truncation is a verdict on code nobody
  finished reading.
- **rc 0 with empty output** is untouched — billed, `empty`, terminal on the
  second. "Nothing was called" and "it was called and said nothing" are different
  facts and must not share an arm.

## 2. An unreadable key was silent

A zero-byte or corrupt key fell into a bare `*) continue`. That disabled the lane
for that head for ever and looked exactly like "already reviewed". The known
terminal shapes are now enumerated explicitly (`reviewed`, `skipped`,
`empty-terminal`, `unposted-terminal`, `failed-terminal`) and everything else logs
one line per key per tick naming the key path and the words `unreadable state`.
It still spends nothing — an unreadable guard is not permission to spend.

## 3. A post that LANDED and exited nonzero was posted again every tick

`gh pr comment` can put the comment up and still exit nonzero (a 502 reading the
response, a token that died after the write); the rc cannot tell that from "it
never landed". Probed: three identical reviews on one PR in three ticks. `ap_post`
now makes **one** REST read of `repos/<slug>/issues/<num>/comments?per_page=100`
before any RE-post and looks for `<!-- harness-review-autopilot <head12> -->`:

- present → the key is promoted to `reviewed <stamp> verdict=<V>`, the `.body` is
  dropped, nothing is posted;
- absent → it posts, as before;
- endpoint unreadable → it does **not** post blind. The tick counts as a try, so
  `REVIEW_AUTOPILOT_POST_TRIES` still bounds it. Delivery delayed by an hour beats
  a duplicate.

The FIRST post makes no REST call — nothing can have landed yet, and the happy
path must not buy an extra call. It reads the first 100 comments; one call is the
bound the ticket set, and a PR past 100 comments behaves as it did before.

## 4. `unposted-terminal` told nobody, and the sweep ate the evidence

The state existed so an operator could post a paid-for review by hand, and nothing
ever said so — while the 90-day `find … -delete` removed the `.body` along with
the money. Now the transition writes one `logs/ALERTS.log` line and fires one
`fleet_alert` beat (akey `review-autopilot-unposted:<slug>#<num>:<head12>`), both
naming the literal `gh pr comment … --body-file <key>.body` command. `*.body` is
exempt from the sweep and is dropped instead when its PR is no longer open. The
delete is earned by a positive per-PR read through `gh_rest_pr_state`, never by
absence from a list: `harness_pr_list` can return rc 0 and a short list (REST page
cap, or a partial `gh pr list` fallback), and what it drops first is the oldest
harness PRs — exactly the heads that own a cached body. The list only ever
short-circuits "still open, skip"; a read that returned 44 or 75 keeps the body.
The key is untouched by the drain and still ages out at 90 days.

## What this touches

- State: `state/review-autopilot/<slug>-<num>-<head12>` gains two first-line
  shapes, `failed <stamp> n=<k> rc=<rc>` and `failed-terminal <stamp> n=<k> rc=<rc>`.
  Neither parses in `mc_autopilot_verdict` (`bin/lib/merge-conductor-lib.sh`),
  which still reads `reviewed … verdict=` only — pinned by the suite.
- Knob: `REVIEW_AUTOPILOT_FAIL_TRIES`, default 3. It has a default, so no
  environment needs it set.
- Suite: `tests/review-autopilot.bh-1066-test.sh` (81 assertions, all on what a
  run did). `tests/review-autopilot-post-retry-test.sh` stays green unchanged.
- Map: `docs/verification-map/review-autopilot-ledger.md`.
