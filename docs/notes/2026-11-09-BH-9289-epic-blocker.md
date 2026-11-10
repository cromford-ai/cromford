# BH-9289: a Blocked-by on a hand-written epic resolves with a question and a default

Doc: EVENTS

## What changed

`bin/decompose-parent-close.sh` closes only the masters `bin/run-decompose.sh`
filed. It reads the `ai-build` list and finds children by `Part of #N`. A
hand-written epic has no label, and its children can say "epic #N" or be linked
only as sub-issues. So a ticket with `Blocked-by: #<epic>` waited forever after
every child closed (project-6 #1008, TK-1055, TK-1057).

A new pass, the epic pass (`bin/lib/epic-blocker.sh`, `eb_pass`), runs inside
`bin/decompose-parent-close.sh` after its close loop. It shares that script's
cooldown, wake backstop, repo token, dry-run flag and kill switch
(`REVDEP_WAKE=0`).

1. Candidates: every `#N` on a `Blocked-by` line of an open ai-build issue,
   where #N is not in the ai-build list and no listed issue says `Part of #N`.
   At most `EPIC_BLOCKER_MAX` per pass, rotated after
   `state/epic-blocker/<project>/cursor`.
2. Per candidate, five REST reads: the issue, its comments, a search for
   `"Part of #N"`, a search for `"epic #N"`, and `issues/N/sub_issues`. A
   search hit is a child only when its body matches `Part of ... #N` or
   `epic #N` (no longer number), it is an issue, it is not #N, and its own
   `Blocked-by` line does not name #N. A failed read, or a search with more
   than one page, gives no verdict for that pass.
3. Verdicts:

| Verdict | When | Action |
|---|---|---|
| DECOMPOSE | a filer sentence is on the thread | none; the close path owns it |
| NO_CHILDREN | no confirmed child | remove `.met` |
| OPEN_CHILD | a child is open | remove `.met` |
| ASK | all children closed, no question yet | post the question; only after the POST succeeds, one alert and `EPIC_QUESTION_POSTED` |
| WAIT | question asked, window not over | remove `.met` |
| ANSWERED | a human comment after the question | remove `.met`; `EPIC_DEFAULT_STOPPED` once |
| MET | question older than `EPIC_BLOCKER_DEFAULT_H`, no reply | write `state/epic-blocker/<project>/<N>.met`; `EPIC_DEFAULT_MET` once |

   An epic read as closed, as a pull request or with `ai-build` also loses its
   `.met`.
4. `bin/unblocked-children.sh` reads the `.met` markers (`eb_met_list`). An
   open blocker fetched by number that has a marker counts as met. Its
   dependents come out as `board issues: UNBLOCKED <n> "<title>" (every blocker
   it names is CLOSED or met by default — #N is a hand-written epic ...)`.

The pass never closes the epic and never launches a build. The question is
the first line `<!-- harness: epic-close-question -->`, and its `created_at`
starts the window. A human reply is any comment after the question with no
`<!-- harness` marker and no `type: Bot` author. A failed POST adds `retry` to
`state/parent-close-<project>.keys`, so the next cooled pass tries again. Each
candidate number is a wake key, so a reply on the epic wakes the next pass.

Retention: a `.met` or `.stopped` file whose epic no open ai-build issue names
in `Blocked-by` is deleted by the next pass.

## Events (logs/<project>.log)

- `EPIC_QUESTION_POSTED #N` — the question landed on the thread.
- `EPIC_DEFAULT_MET #N` — the window ended with no reply; the marker exists.
- `EPIC_DEFAULT_STOPPED #N` — a human replied; the dependents keep waiting.
- `EPIC_DRY #N <verdict>` — a `--dry-run` pass; nothing written.

One alert per epic, `bin/alert-line.sh --id epic-blocker-<project>-<N>`, names
the epic, its children and its dependents.

## Knobs (catalog/lanes.d/_lib.epic-blocker.json)

| Knob | Fallback | Meaning |
|---|---|---|
| `EPIC_BLOCKER` | 1 | 0 = off: no read, no question, and no dependent is released by default |
| `EPIC_BLOCKER_DEFAULT_H` | 24 | hours after the question before the default applies |
| `EPIC_BLOCKER_MAX` | 5 | candidate epics looked up per pass |
| `EPIC_BLOCKER_COMMENTS_MAX` | 200 | comments read per epic thread; a thread longer than this (or a read shorter than the issue's `comments` count) gives no verdict for that epic |

## How to stop a default by hand

1. Reply on the epic. Any human comment after the question stops it.
2. Or close the epic. The dependents then release as an ordinary closure.
3. Or set `EPIC_BLOCKER=0` to stop the pass and every met-by-default release.
