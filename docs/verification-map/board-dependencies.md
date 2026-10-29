# In-app ticket dependencies (blocked / parentId / dependsOn / children)

**What it is:** the read side of the in-app boards' dependency primitive
(`docs/BOARD-API-CONTRACT.md`, "Dependencies"). A board that serves it gives
every ticket a `parentId`, a `dependsOn: [{id,key,status}]`, a
`children: [{id,key,status}]` and a derived `blocked: boolean`. Several places
in the harness act on those, and nothing writes them.

**What has landed.** The contract and the fingerprint are BH-899 (this page's
first row, plus the document and the shared fixtures). The gate refusal, the
release line, the parent-close lane and the prompt wording are #900, #901, #902
and #903 — the four siblings of #815 that read the shape this slice defines.
The rows below describe the whole feature so the page does not have to be
re-edited five times; the "how to drive it" table names each lane's own suite,
and a lane whose suite does not exist yet has not landed yet.

**Feature detection is per ticket, on the TYPE of `blocked`.** Only a JSON
boolean counts. Absent, `null` and the string `"true"` all read as "this board
has not adopted dependencies", which is every in-app board on the fleet until
its own contract ticket deploys. That rule is load-bearing rather than tidy: an
un-adopted board's fingerprint must stay byte-identical, or the release that
shipped this would re-fingerprint every board on the fleet and buy one full
session per project for nothing.

**How an operator reaches it:** not a screen. It is the per-project triage cron
line (`cron/<box>.cron`, offsets from `fleet.conf`), and the lanes below all run
inside that tick.

| thing | where |
|---|---|
| the fingerprint (BH-899) | `bin/triage-gate.sh` `fetch_fingerprint` — adds `{key, blocked, parentId, dependsOn: [ids]}` per ticket, inside `if (.blocked \| type) == "boolean"` |
| the buildable gate (#900) | `bin/triage-gate.sh` `buildable_gate` — prints `BLOCKED dependencies <keys>` **before** the waitingOn / triageVerdict checks; `dependsOn[].key`, falling back to `.id`, falling back to the word `unlisted` |
| the release (#901) | `bin/run-triage.sh` and its twin `bin/lib/rt/scope.sh` — turns a `true → false` flip in the fingerprint diff into an `UNBLOCKED` scope line |
| the parent close (#902) | `bin/decompose-parent-close.sh` — closes a parent whose every `children[]` entry is `done` and whose children's own records confirm it. A parent filed by a client (`reporter.userId` set and not `system`) moves to `review` instead of `done`; no reporter keeps `done` (BH-3927) |
| the merged-ticket advance (BH-3927) | `bin/merged-ticket-advance.sh` — called from `inapp_released_lines` right before the parent close. An `in_progress`/`review` ticket whose newest build's PR has a `PASS` or `NOT_COVERED_NO_QA_ENV` line in `state/postmerge-qa-done.txt` gets one comment, then a move: `done` if `system` filed it, `review` if a client did. A client ticket already in `review` is left alone. Knobs `MERGED_ADVANCE_MAX` / `MERGED_ADVANCE_COOLDOWN_S` (`lib.merged-advance`), kill switch `flags/merged-advance-off` |
| the prompts (#903) | the triage prompt wording plus the webhook note that says which board events wake a tick |
| what it writes | `state/<project>.gate.json` / `.gate.pending` and `state/<project>.keymap.json` (the gate already wrote all three; this slice changes only what goes INTO them) |
| the release line's shape | `board <bid>: UNBLOCKED <id> "<title>" (<KEY> — dependency <DEPKEY> done: …)` — gate-diff shape, so `triage_shard_key` parses it and the TICK SCOPE prompt text needs no edit |

**Peer-built tickets (BH-8786).** A peer fleet can build a ticket on this
board. Then this box has no build dir for it, and no post-merge audit line. The
merged-ticket advance does not drop that ticket. It reads the newest thread
comment with a PR URL on the project repo (`https://github.com/<repo>/pull/<n>`,
the fleet.conf repo), the PR's `merged_at` and merge sha from GitHub REST, and
the prod version sha. The ticket moves only when that sha is the merge or GitHub
compare says it is `ahead` of it or `identical`. With no version route (a 404),
it moves `MERGED_ADVANCE_DEPLOY_GRACE_S` (default 1800) after the merge, and the
comment says "merged, deploy not confirmed from here". The dedupe token is
`pr-<n>-<merge sha8>`. A move to `review`, on either path, also gives the turn to
the client (`POST /tickets/<id>/turn {"to":"client"}`), because a move does not.
Each skip has a counter in the `MERGED_ADVANCE` line: `no-local-build` (every
peer candidate), `no-pr-in-thread`, `pr-open`, `deploy-behind`, `peer-unread`
and `pr-ambiguous`.

**How to drive it:**

| what | how |
|---|---|
| the fingerprint: the four keys, the negatives, and the gate-diff release line | `bash tests/triage-gate-fingerprint-deps.bh-899-test.sh` |
| the byte-for-byte regression guard on an un-adopted board | same suite, `cmp` against `tests/fixtures/triage-gate-dependencies/oldboard-fingerprint.json` (generated from the pre-change script) |
| regenerating that oracle | `S=$(mktemp); git show origin/main:bin/triage-gate.sh > "$S"` then `HARNESS_TEST_SANDBOX=1 TRIAGE_GATE_UNDER_TEST="$S" bash tests/triage-gate-fingerprint-deps.bh-899-test.sh --dump-oldboard` — only ever against a checkout that predates BH-899 |
| the document carrying the rule | `bash tests/board-contract-doc.bh-899-test.sh` |
| the gate refusal | `bash tests/*.bh-900-test.sh` |
| the release reaching a real prompt | `bash tests/*.bh-901-test.sh` |
| the parent close, POST bodies and all | `bash tests/*.bh-902-test.sh` |
| the merged-ticket advance, and a split closing in one tick through it | `bash tests/merged-ticket-advance.bh-3921-test.sh` |
| the merged-ticket advance of a peer-built ticket (no local build dir), and the turn to the client | `bash tests/merged-ticket-advance.peer-built-test.sh` |
| the prompts and the webhook note | `bash tests/*.bh-903-test.sh` |
| the prompt bytes did not move | `bash tests/rt-split-layout-test.sh` (goldens, no regen) |
| one ticket by hand | `HARNESS=/root/harness bin/triage-gate.sh <project> --buildable <ticket-id>` |

**On a live box:**

- `jq '.[][0]' state/<project>.gate.json` — a ticket carrying `blocked` means
  that board has deployed the contract. No `blocked` key means it has not, and
  every lane here is a no-op for it. As of 2026-09-18 no board has, so this is
  what every project's fingerprint looks like.
- `HARNESS=/root/harness bin/triage-gate.sh <project> --seed` still answers
  `SEEDED N tickets` — the projection is additive, and on an un-adopted board
  the bytes it writes do not move.
- the release lines appear in the tick's prompt, not in a log of their own; the
  tick that produced one is the one whose scope names `UNBLOCKED <id>`.

**What must never regress:**

- **An un-adopted board's fingerprint bytes.** Absent and `null` `blocked` add
  nothing to the projection. The `cmp` case in the fingerprint suite is the
  guard, and jq's `//` must never be used for this test: `false // x` falls
  through, which would read an unblocked ticket on an adopted board as an
  un-adopted one.
- **Absent is not `false`.** Only a boolean `true → false` flip between the
  consumed and the live fingerprint releases a ticket. `true → absent` (a board
  that dropped the field), a ticket new this tick, and `null → false` all
  release nothing.
- **`dependsOn` is projected to plain ids.** A dependency's own `status` moving
  inside `dependsOn` must not churn the child's fingerprint — the child's own
  `blocked` flip is the signal, and the blocker's row carries the status move.
- **The gate stays fail-open.** Any fetch or parse failure prints `OK`. Blocking
  silently is worse than one extra triage shard.
- **`blocked` is checked before `waitingOn` and `triageVerdict`,** because it is
  the block that clears itself and the reason a human reads should name it.
- **Unreadable is not done.** The parent close refuses on any child whose own
  `GET /tickets/{id}` is not 200 with `status: done`, even when the parent's
  `children[]` said `done`. A status that says "done" is the client's record.
- **No prompt text changed by the fingerprint slice.** The release line rides the
  existing `UNBLOCKED` class, so `tests/rt-split-layout-test.sh`'s goldens must
  not need a regen.
- **No model call.** Every lane here is shell, jq and curl.
