# Archie, factory manager: stacks of three, the cap by action, killed ticks (BH-4784)

Doc: MERGE-CONDUCTOR, DB-COORDINATION-SPEC

Follows [2026-10-05-BH-4583-archie-fm-tracer.md](2026-10-05-BH-4583-archie-fm-tracer.md).
Where the two disagree, this note is the current behaviour: its day-cap row
("mode on, outcome done or requested") and its known gap ("a no-op spends
cap") are superseded below.

## What changed

**A stack of three (I2).** Restacking a middle PR B (on a merged A) rewrites
B's head, so B's child C no longer carries B's head once B merges, and step b
("the parent's pre-merge head must be in the child's history") used to close C
`done / noop`, a terminal row with no alert: C sat on a merged branch forever.
Now:

- A push records the branch's open children in the row's evidence,
  `children: [{pr, head}]` (at most 20), read from the open-PR list the tick
  already read (no extra GitHub call), and logs one line per child:
  `<slug>#<k> is stacked on <br>; it replays from <old_head> when #<n> merges`.
- When C's parent head is not in C's history, `afm_fork_point` reads B's own
  ledger (`GET /api/archie/actions?repo=<slug>&pr=<B>&playbook=...`, across
  days) and takes the `old_head` of an `on / restack / done` row that IS in C's
  history (the nearest one, if B was restacked twice). C is replayed with
  `git rebase --onto origin/<target> <that head>`; the row's evidence says
  `fork_point` and `fork_from: ledger` (`parent_head` on the ordinary path).
- No such row (B was rebased by the conductor, a fix round or a person): C is
  closed `failed` (action `restack`) with ONE alert telling a human to find the
  commit C was cut from and `git rebase --onto origin/<target>` it. Never noop.
- The ledger cannot be read: `deferred`, retried on the usual ladder.

**The day cap counts by action (N2).** `afm_cap_ok` asks
`GET ...?day=&playbook=&limit=1&count_by=action` and sums today's mode-`on`
rows whose action is `restack` or `fix_round`, any outcome. A `noop` close
rewrites the action to `noop`, so it no longer spends cap; a `failed` restack
(which may have retargeted) now does; a `deferred` row is one attempt and
counts once however many retries it takes. The worker echoes
`count_by: "action"`; an answer without the echo (a worker older than this
change ignores the param) is read as unreadable, and the lane does nothing.

**The cap is read once per tick once reached (N3).** `AFM_CAP_FULL` remembers
"reached" for the rest of the tick: no second GET, no second `cap reached`
line. An unreadable count is not remembered.

**A push with no local suites is on the row (N4).** When the repo has neither a
package.json test script nor `bin/test-impact-gate.sh`, the row's evidence
carries `local_suites: false` and the log line ends `no local suites ran, CI is
the gate`. `summary=1` answers `no_local_suites` (on / restack / done rows with
`evidence.local_suites` false), and the digest's Factory manager line adds
`, <n> pushed with no local suites` only when it is above 0.

**A tick killed between the retarget and the push (N5).** `timeout -k` can
KILL a tick after `mc_retarget_base` and before the push or the TERM trap: the
row stays `started` and the PR sits on `<target>` with the parent's pre-squash
commits, which `afm_classify` no longer sees. Every row now records
`child_base` (the base before the retarget). In mode `on` the lane reads today's
and yesterday's ledger for the project once (`afm_recover_load`), and a PR
`afm_classify` leaves unclassified is matched against the `started` /
`deferred` restack rows: still on the row's `onto`, still at its `old_head`.
It then goes through the ordinary claim (stale `started` closes `deferred`,
the next tick past `ARCHIE_FM_RETRY_S` reclaims and replays it; a refused push
puts the base back on `child_base`). `requested` rows (a deliberate retarget
without a push, parked for the resolver) and `failed` rows are not recovered.

## Routes

| route | change |
|---|---|
| `GET /api/archie/actions?repo=&pr=` | one PR's rows across days (`day` optional with both; `repo` alone is 400 `pr`, `pr` alone 400 `repo`) |
| `GET /api/archie/actions?count_by=action` | `counts[playbook][mode][action]` and `count_by: "action"`; any other value is 400 `count_by` |
| `GET /api/archie/actions?summary=1` | adds `no_local_suites` |

No schema change, no new knob, no new env var.

## Known gaps

- A stale `started` row whose push DID land (the head moved) is not matched and
  stays `started`; nothing proves the push was ours, so nothing acts on it.
- GitHub's own retarget of children when a merged branch is deleted leaves the
  same "base main, pre-squash commits" state with no ledger row. Not covered.
- A killed tick older than the previous UTC day is not recovered.

## Turning it on

`archie.manage` stays `observe` (the seed). After this merges and the worker
deploys: probe `count_by=action` echoes, `repo=&pr=` answers 200 and
`summary=1` carries `no_local_suites`; read at least a day of observe rows;
then `bin/jobs-client.sh setting-set archie.manage on "<why>"` and read it back.
