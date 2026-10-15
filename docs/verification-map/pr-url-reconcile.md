# PR-url reconcile (a build record re-linked to the PR it actually opened)

**What it is:** the hub lane that repairs the link between a build record and its
pull request after `gh pr create` failed on the builder, plus the create LADDER
that stops most of those failures happening in the first place.

BH-848: `gh pr create` is GraphQL, and a pool machine runs on an App installation
token whose GraphQL budget is chronically exhausted (`GraphQL: API rate limit
already exceeded for installation ID 161623167.`). The create returned no URL,
the adopt fallback was `gh pr list` — GraphQL again, same bucket — and the build
wrote `PR_CREATE_FAILED` as line 1 of its RESULT. `bin/merge-sweep.sh` and
`bin/pipeline-health.sh` walk ONLY records whose line 1 reads `PR_CREATED
https://`, so ten CI-green `VERDICT: APPROVE` PRs were invisible to the sweep in
one day, and the only symptom was that merges had flatlined. Two more records
carried the PARENT's URL from a `STACKED on …` note as if it were their own.

**How an operator reaches it:** no UI. The lane is a cron line on the hub; its
observable surfaces are files.

**Primary lanes / scripts:**
- `bin/pr-url-reconcile.sh` — `cron/hub.cron`, `3,13,23,33,43,53` (three minutes
  ahead of each `bin/merge-sweep.sh` tick, so a relinked record is swept next).
- `bin/lib/gh-pr-create.sh` — the create ladder, sourced by the
  `# >>> pr create ladder` block inside `# >>> pr create call` in
  `bin/run-build.sh`. Rungs, in order: `graphql` (`gh pr create`),
  `graphql-adopt` (`gh pr list --head <branch> --state open` — the adopt
  `bin/run-build.sh` has always done, moved into the ladder, not dropped),
  `rest-adopt` (`GET repos/<slug>/pulls?head=<owner>:<branch>&state=open`),
  `rest` (`POST repos/<slug>/pulls`), then `rest:default-pat` and
  `rest:admin-pat` for any OTHER identity this machine holds. A pool machine
  holds exactly one, and the log says `no second identity on this machine`
  rather than pretending. The identity rungs read `github-admin.env` through
  `bin/lib/env-path.sh`, never a spelled `$HARNESS/env`. An identity rung's
  adopt read always runs (the PR it finds was authored by whoever opened it, not
  by the token reading it); its create runs ONLY if its login (`gh api user`,
  read once per identity) is in `HARNESS_PR_AUTHORS` (`bin/lib/gh-pr-list.sh`'s
  `harness_pr_author_match`, the same matcher `bin/merge-sweep.sh` filters on):
  a PR authored by a login the sweep drops is not a success, it is the same
  invisibility one layer over. A login that reads as an outsider skips the
  create with the reason and the set in `pipeline.log`; a login that would not
  read at all is UNKNOWN, and the create runs, logged as such.
- The reconciler asks about the branch THE RECORD NAMES, not the one its
  directory name implies: a rebuild runs on `ticket/<key>-rN` while the build dir
  carries no suffix, so `bin/pr-url-reconcile.sh` reads
  `pr create failed and no open PR exists on <BRANCH>:` (or the last exact
  `ticket/<key>` / `ticket/<key>-rN` name) from the record's own `pipeline.log`,
  which every pool record ships, and falls back to the stem only when the record
  carries no branch of its own. A parent's `STACKED on ticket/…` name is never
  accepted as this record's branch. gh's stderr for the lane's reads lands in
  `logs/pr-url-reconcile.stderr.log`; when a read produces no HTTP status at all,
  the UNKNOWN log line quotes the last line THAT read wrote — the byte offset is
  taken before the call, because the log is shared by every record and quoting
  its tail would attribute some other record's failure to this one.
- `bin/lib/result-pr-url.sh` — `result_own_pr_url` / `result_parent_pr_url`, used
  by `fly/builder-runner.sh` (`# >>> result assemble`), `bin/fly-results-ingest.sh`
  and `bin/fly-pool.sh` instead of grepping the first URL on a record.

**What the lane decides, per record:**

| record state | GitHub answers | what happens |
|---|---|---|
| line 1 `PR_CREATE_FAILED`, no own `PR:` | 200 + a PR | line 1 rewritten `PR_CREATED <url> \| RECONCILED <ts> …`, original kept as `RECONCILED_FROM:`, `PR: <url>` appended, `.pr-url-reconciled` touched |
| line 1 `PR_CREATE_FAILED`, `PR:` already the branch's PR | 200 + the same PR | the same rewrite, minus the `PR:` line it already carries. A hand backfill left line 1 saying the create failed, and the sweep never reads past line 1 — marking it terminal without the rewrite would lose the record for good |
| same | 200 + `[]`, review says APPROVE, `state=all` says MERGED | one log line, `.pr-url-reconciled` touched (terminal: nothing owed, and nothing about a merged PR can change, so it stops costing two REST reads a tick). "Open it by hand" about a PR already in main is worse advice than none |
| same | 200 + `[]`, review says APPROVE, `state=all` says CLOSED unmerged | ONE `logs/ALERTS.log` line saying the PR was closed without merging, naming it, `.pr-url-reconcile-alerted` touched. No write |
| same, line 1 carries `STACKED on <parent> (<parent PR>)` | 200 + `[]`, review says APPROVE, the parent PR is MERGED and `branches/<parent>` answers 404 (BH-1904) | the restack arm: `git rebase --onto <base> <parent's pre-merge head>` through `mc_restack`, pushed with a lease, the sha written to `.pr-url-reconcile-restacked` BEFORE the create, then `POST pulls` against the project base (`BASE_BRANCH`, default `main`). Line 1 becomes `PR_CREATED <url> \| RECONCILED …`, with a `RESTACKED: <parent url> <parent head> -> <new head> onto <base>` line, `RECONCILED_FROM:` and `PR:`, then the ledger hand-off below. No page |
| same, restack arm | the replay conflicts | ONE ALERTS line naming the files (`conflicts in: …`, "Nothing pushed"), `.pr-url-reconcile-restack-gaveup` touched. Terminal for the arm: no retry, and the ordinary "open it by hand" page is not sent as well. `bin/blocked-resolver.sh` rebuilds it after its 90-minute floor |
| same, restack arm | the parent head is not in the child's history (the parent was rewritten after the child was cut, `mc_restack` rc 6) | ONE ALERTS line saying so, gaveup marker touched, nothing pushed. Never guessed at with a merge-base |
| same, restack arm | the push lease is refused, setup fails, or the create is refused | one log line and `.pr-url-reconcile-restack-tries` counts it. A pushed restack is not rebased again: only the create is retried. The 3rd failed try is ONE ALERTS line (`failed 3 times`) and the gaveup marker |
| same, restack arm | the child is already on the base but no marker says so (a crash between the push and the marker) | two `compare` reads prove it (`<parent head>...<child>` diverged, `<base>...<child>` `behind_by` 0), the marker is written and the PR opened. No second rebase, which would be a false rc 6 page |
| same, restack arm | the parent PR is open or closed unmerged, `branches/<parent>` answers 200, the child branch 404s, or the conductor is not armed (`flags/merge-conductor-actions` absent or `MC_REREVIEW_ON_MOVE=0`, logged as `would restack`) | not the arm's case: the page below, exactly as before |
| same, restack arm | any of its reads answers 403 / 5xx / no status | UNKNOWN: one log line, no write, no page |
| same | 200 + `[]`, review says APPROVE, no PR ever | ONE `logs/ALERTS.log` line naming the fix command (`--base` is the stack's parent branch where line 1 carries a `STACKED on …` note, else `main`), `.pr-url-reconcile-alerted` touched. No write |
| same | 200 + `[]`, review says BLOCK (or none) | one log line. Nothing owed, nothing written, no second read. Deliberately NOT terminal: a resolver fix round can open its PR later, and that PR must link. The "APPROVE, no PR" alerted record stays re-readable for the same reason (a hand-opened PR must link), and still takes the `state=all` read: a hand-opened PR that was then MERGED marks it terminal with `.pr-url-reconciled` instead of costing a read a tick forever. It is never paged twice |
| same | 403 / 429 / 5xx / no status | UNKNOWN: one log line, no write, no alert. A failed read is never "no PR" (BH-709) |
| has a `PR:` that differs from the branch's PR | 200 + a PR | ONE mislink ALERTS line, record left untouched — a correct link is never overwritten. `.pr-url-reconcile-mislinked` touched (terminal: a human edit is the only exit; `rm` the marker after fixing the `PR:` line to re-arm one read, which does not page again). The page has its OWN dedupe marker, `.pr-url-reconcile-mislink-alerted`, never `alert()`'s shared one: a record paged earlier for anything else must still get told it is mislinked before the terminal marker seals it |
| line 1 `PR_CREATED <url> \| RECONCILED …` with no `.verdict-handoff-done` | the branch is not re-read (the url is on line 1); the PR itself is read once, and only on the path that would otherwise page | the LEDGER half only — see below. No rewrite |
| line 1 `PR_CREATED …` the builder wrote / `PLAN_BLOCKED` / anything else | — | not walked at all |

**The ledger half of the link (BH-858).** Rewriting line 1 repairs the readers
that read FILES. It does nothing for the lanes that ask the ledger:
`/api/verdict?pr=` resolves through the `pr_url` artifact, and a build whose
create died never wrote one — so the conductor and the merge queue stay blind to
that PR, and the verdict its reviewer wrote is bound to nothing anybody can look
up. After each successful relink (and on a later tick for a record this lane
already relinked but could not finish), `verdict_handoff` walks this order and
stops at the first step that answers:

1. `job_for_record <project> <record>` — the job id, from the `result` artifact
   feed's `build_dir`. rc 1 (outage) logs and marks nothing.
2. `job_artifact_put pr_url <url>` on that job. This is the write that makes the
   PR resolvable at all.
3. `job_verdict_state <job>` — settled OR provisional means a judgement exists
   and nothing more is owed. A provisional row counts on purpose:
   `bin/review-rescue.sh`'s backfill settles those within a tick or two, and
   handing it to re-review would buy a Fable read for a judgement the ledger
   already holds.
4. No verdict at all, and the record was relinked on an EARLIER tick: one REST
   read of the PR itself. Merged or closed means nothing is owed — one log line,
   no hand-off, no page. This read exists only on this arm, because the
   first-tick path reads `state=open` before it links anything; an outage answers
   UNKNOWN and falls through.
5. No verdict at all: if `flags/merge-conductor-actions` is present and
   `MC_REREVIEW_ON_MOVE` is not 0, ONE log line records the hand-off — the
   conductor's own `mc_classify` answers `HEAD_MOVED … fresh detached review` for
   a PR with no verdict bound to its head and buys the read under its budget,
   daily cap, CI-green debounce and per-(PR, head) dedupe. THIS LANE SPAWNS
   NOTHING.
6. Conductor not armed, but the record's own `review.md` ends `VERDICT: APPROVE`
   and a job row owns it: ONE log line and no page. That is precisely the shape
   `bin/review-rescue.sh`'s `verdict_backfill` settles at tier 2 on its next
   tick, so "nothing can produce one" would be a false sentence about a record
   that carries a real judgement.
7. Nothing left: ONE `logs/ALERTS.log` line says the PR owes a verdict no path
   can produce, and names the fix.

Then, and only then, `.verdict-handoff-done` is touched. Any rc 1 along the way
marks nothing, so the record comes back on the next tick — an outage is not "no
verdict". A box with no `bin/jobs-client.sh` skips all of it and behaves exactly
as this lane did before BH-858. See
[verdict-ledger.md](verdict-ledger.md) for what `settled` means and who reads it.

**Knobs** (`env/global.env`, each with a flag-file twin; documented in
`env-templates/global.env.example`):
- `PR_URL_RECONCILE=0` or `flags/pr-url-reconcile-off` — the lane exits before the walk.
- `PR_URL_RECONCILE_MAX` — records asked about per tick, default 50.
- `PR_URL_RECONCILE_DEADLINE_SECS` — wall-clock budget per tick, default 240.
- `PR_CREATE_REST_FALLBACK=0` or `flags/pr-create-rest-fallback-off` — the create
  ladder stops after rung `graphql-adopt`, which is the pre-#848 behaviour byte
  for byte: `gh pr create`, then `gh pr list --head … --state open`. The flag
  switches off the REST rungs #848 ADDED; it must never switch off the adopt
  #848 replaced, or the rollback lever re-creates the bug it rolls back from.

**How to drive it:**
- `bash tests/pr-create-ladder-test.sh` — the ladder against a stub `gh`
  (rate-limited GraphQL + REST 201; REST 403 on the App identity and 201 on the
  PAT; the admin PAT read through the resolved env dir; the GraphQL adopt, with
  and without the kill flag; every rung failing; a 403 read that must not read as
  "no PR"; a 201 with no `html_url`; a 422 "already exists"; an admin login
  outside `HARNESS_PR_AUTHORS` skipped with the reason logged and no POST on it,
  then the same login creating the PR once it is in the set; the same outsider
  still ADOPTING the open PR on the head, because the adopt read runs ahead of
  the login gate; a login that would not read running the rung as UNKNOWN), and the two
  `bin/run-build.sh` blocks extracted VERBATIM as the production entry point —
  including the case main answers by adopting (`gh pr list` names the PR, REST is
  403), under default flags and under the kill flag.
- `bash tests/result-parent-pr-test.sh` — the RESULT ratchet's URL redaction and
  the extracted `# >>> result assemble` block writing `PARENT_PR:`, never `PR:`.
- `bash tests/pr-url-reconcile-test.sh` — the lane itself against a scratch
  `$HARNESS`: link, idempotent second run, 403, never-overwrite, a record that
  already carries the right `PR:` line, non-candidate records, the cap and its
  `unwalked=` count, every alert shape (none / merged / closed unmerged /
  mislinked), the stacked base in the fix command, the kill switch; a REBUILD
  record whose `pipeline.log` names `ticket/<key>-r2` is asked about -r2 and the
  r1 PR still open on the stem is NOT linked to it (and the alert and fix command
  name -r2); a log carrying only the taken-name bump line still resolves -r2 off
  the last exact `<stem>-rN` name; a log naming only a STACKED parent falls back
  to the stem, and the log says so; the merged and mislink paths mark the record
  terminal so the next tick reads nothing, removing the mislink marker re-arms
  one read without re-paging, a record already paged for a missing PR still gets
  its mislink page, a record already paged for a missing PR whose PR was merged
  by hand goes terminal on the `state=all` read without a second page (and one
  whose PR is still nowhere stays re-readable), and the UNKNOWN line quotes the
  stderr THIS read wrote and never another record's.
- `HARNESS_TEST_SANDBOX=1 bash tests/pr-url-reconcile-restack.bh-1904-test.sh` — the
  restack arm, driving the real lane against a real bare origin: the parent
  squash-merged and its branch deleted (restacked, pushed, PR opened against
  main, record linked), a conflict (one page naming the file, and a second tick
  adds nothing), a parent still open or closed unmerged, a parent branch still
  alive, a 403 branch read, the conductor unarmed, a push that landed with a
  refused create (the next tick creates without a second rebase), a 502 parent
  read, a rewritten parent (rc 6), the 3-try ceiling, a BLOCK verdict, the crash
  window, and a record with no stack note.
- `bash tests/pr-url-reconcile.bh-858-test.sh` — the ledger half against a stub
  worker that records every request: the `pr_url` bind and a hand-off recorded
  once, a job that already owns a verdict, the unarmed-conductor alert, a worker
  outage that marks nothing and a later tick that finishes it, a box with no
  jobs-client behaving exactly as before, and the two records the lane must NOT
  page about — one whose `review.md` ends APPROVE (the backfill settles it) and
  one whose PR has since merged.

**On a live hub:**
```
grep -c 'PR_CREATE_FAILED' /root/harness/builds/*/RESULT | grep -v ':0' | head
tail -20 /root/harness/logs/pr-url-reconcile.log      # one line per record + a tick summary
grep pr-url-reconcile /root/harness/logs/ALERTS.log   # the loud half
```
A reconciled record reads:
```
PR_CREATED https://github.com/example-org/cromford/pull/834 | RECONCILED 2026-09-18T08:03:00Z by pr-url-reconcile: the create had failed on the builder
TIER: 2
RECONCILED_FROM: PR_CREATE_FAILED: GraphQL: API rate limit already exceeded …
PR: https://github.com/example-org/cromford/pull/834
```

**Preconditions / seed needs:** the hub's `builds/` tree, `fleet.conf` (the repo
slug per project) and a `gh` that can read `repos/<slug>/pulls` — the App token
through `gh_auth_for` where it is armed, the fleet PAT otherwise. No new env var
is required; all four knobs have documented defaults.

**Verify it works:** the three suites above report `0 fail`, and on the hub the
tick summary line (`tick: walked=… links=… alerts=… skipped=… unwalked=…`)
appears in `logs/pr-url-reconcile.log` within ten minutes of the cron line
landing.

**Manual-only / not automatable:** the cron line reaches the hub through the
repo's normal cron propagation (`bin/fleet-propagate.sh` / `update-runners.sh`) —
until it does, the lane exists but nothing calls it. Re-LINKING a record whose PR
is CLOSED or MERGED rather than open is deliberately out of scope: the link
decision is made on the `state=open` read only, because `.[0]` of a `state=all`
list can be a closed PR and linking a record to one is the mislink this lane
exists to prevent. The `state=all` read happens only for an APPROVE record with
no open PR, and only to choose the WORDS: merged means nothing is owed and the
lane says so in its log instead of paging.

**Superseded records are skipped (BH-614).** A record carrying
`.blocked-resolver-superseded` is counted under `skipped=` and never walked:
`bin/blocked-resolver.sh` has already replaced it with a fresh build of the same
ticket, and re-linking it would hand the merge sweep a second PR for that ticket.
The lane also walks a second line-1 shape now — `RESULT_MALFORMED PR_CREATED …`,
which is what `bin/fly-pool.sh`'s url-shape gate writes for a url-less claim from
an older pool image — and re-links it on exactly the same terms, keeping the
original as `RECONCILED_FROM:`. See
[pr-create-failed-owned.md](pr-create-failed-owned.md).

**Per project (BH-6894).** The cron line runs `bin/pr-url-reconcile.sh
--dispatch`. It calls `pl_dispatch` (`bin/lib/project-lanes.sh`), which starts
one `--project <p>` run per project at a stable offset inside
`PR_URL_RECONCILE_DISPATCH_SPREAD_SECS` (default 120 s), or enqueues a
`lane_runs` row per project when `lane_placement.pr-url-reconcile` is `fly`
(seeded `hub`). A `--project <p>` run walks only `<p>`'s records, holds
`locks/pr-url-reconcile-<p>.lock` plus a shared `locks/pr-url-reconcile.lock`,
and ends its summary line with ` project=<p>`. With no flag the run is the
fleet walk, as before. The run-inputs manifests are
`catalog/lane-run-inputs.d/pr-url-reconcile.ro` and `.rw`. Drive it with
`HARNESS_TEST_SANDBOX=1 bash tests/pr-url-reconcile-per-project.bh-6894-test.sh`;
on the hub, `grep 'pr-url-reconcile dispatch' logs/pr-url-reconcile.log` shows
one dispatch line per tick and `grep 'project=' logs/pr-url-reconcile.log` one
summary line per project. See
[the BH-6894 note](../notes/2026-10-15-BH-6894-pr-url-reconcile-per-project.md).
