# A new `gh` subcommand in the harness is now red until the census covers it

Doc: GH-REST

## What changed

Four files carry the change, none of them product code.

**`tests/fixtures/gh-shim-census.txt`** (new) — 45 lines, one `gh` argv per
line after the word `gh`, covering every `pr|issue|run|repo` subcommand and
flag form the harness writes, with the `--json` field sets its callers really
read. `#` and blank lines are ignored. A leading `!` marks a verb the shim
deliberately does not translate.

**`tests/gh-passthrough-budget.bh-791-test.sh`** (new) — the ratchet, in two
halves.

The budget half drives every census line through the real `bin/gh-rest-shim`
with the real `bin/lib/gh-shim/*.sh` handlers behind it, over the shared
stub, and asserts per line that `$HARNESS/logs/gh-passthrough.log` is empty,
that at least one `api` call was actually recorded, and that no `HTTP 404` came
back. The last two exist because an empty log is satisfiable by a line that
reached nothing: a census entry that 404s its way to a clean budget proves the
opposite of what it looks like.

The subset half scans `bin/**/*.sh`, `catalog/` and `skills/` for
`gh <group> <verb>` at command position — the comment-stripping, separator-
splitting, `timeout`/`NAME=value`-peeling technique
`tests/gh-app-ratchet-test.sh` already uses — and asserts that verb set is a
SUBSET of the census. An empty scan result is a failure, not a pass. So a new
`gh` subcommand entering the harness turns this suite red until somebody adds
it to the census, where the shim must then prove it translates it.

**`docs/GH-REST.md`** (new) — the contract doc: the census table with call-site
counts, what each verb becomes, the rules callers depend on (`mergeCommit` is
null on an open PR; `state` is MERGED by `merged_at`; `id` is the node id;
`issue list` drops `.pull_request` rows before `--limit`), what the sub-fetches
cost, the exit codes, the kill switch, the pass-through log format and why the
caller's command line is not in it, and the operator installation procedure.

**`rules/topics/09-token-discipline.md`** — one rule line, re-rendered into
`rules/CLAUDE.md` by `bin/render-rules.sh --write`.

`docs/verification-map/gh-rest-shim.md` was refreshed from the #787-era text
(it still described the handler directory and the install logic as
forthcoming) to the merged shim, with a table naming which suite proves which
claim. Every suite name in it was checked against the tree first; four names
the ticket listed do not exist and are not there.

## Why

#769 shipped the shim in five chunks and the first four are merged. Nothing
stops a sixth verb arriving in the harness next week with no handler, passing
through to GraphQL, and rebuilding the #768 exhaustion one call at a time. The
census plus the subset scan is the mechanism that makes that arrival loud.

## The two verbs that are never translated

`gh pr checks --required --watch --fail-fast` (`bin/hotfix-migrate.sh:72`) and
`gh run watch --exit-status` (`bin/lib/hotfix-migrate-workflow.sh:342`). Both
block until a check set settles. A long-poll watch is not one REST call and no
handler will make it one, so both stay in the census marked `!` — the subset
ratchet reads that file as the whole set of verbs the harness may call — and
the suite asserts the OPPOSITE of the budget for them: each must log exactly
one pass-through line, at `depth=1`, every time. A pass-through that says
nothing is the failure this half exists to catch.

## Still not installed

The shim is on no box's PATH. Nothing in `bin/update-runners.sh`,
`bin/bootstrap-machine.sh`, `bin/harness-sync.sh` or any `cron/` fragment
references it, and #790 closed without landing install logic. Everything in
this change is a test and four documents; nothing in it runs on a box. The
docs say so in the same words rather than describing an install that does not
exist.
