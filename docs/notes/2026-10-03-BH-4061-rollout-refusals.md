# Rollout refusals: the documented heading parses, refusals reach the master, and the pool stops calling them deaths (BH-4061)

Doc: run-rollout, SKILL

## What changed

- `bin/run-rollout.sh` strips `Wave:` with an optional number from a `###`
  heading (`### Wave: a`, `### Wave 2: a`, `### wave 3 : a` all title `a`).
  `skills/harness/SKILL.md` has always taught the unnumbered form. The parser
  only stripped `Wave <digits>:`, so the title stayed `Wave: a` and every
  `after: a` refused.
- The unknown-dependency refusal names the missing title and the known ones:
  `unknown dependency "x" (known: "a", "b")`. Same rc (17).
- A wave title with a comma refuses as `comma in wave title` (rc 26) when any
  wave has an `after:` line, since `after:` splits on commas.
- New `bin/lib/rollout-refusal.sh`. On the issues lane, a parse refusal posts
  one comment on the master (reason verbatim plus a fix line) and removes
  `ai-build`. Dedup is a hidden marker in the comment keyed on
  sha256(slug/issue/reason), so the next tick with the same reason posts
  nothing. An unreadable comment list posts and parks nothing. Fetch, filer and
  partial failures never comment.
- `bin/result-prefix-ok.sh` accepts `ROLLOUT_`. A live pool machine's
  `ROLLOUT_FAILED` is reaped within one tick instead of being skipped as a
  mexec miss.
- `bin/fly-pool.sh` takes a `ROLLOUT_FILED`/`ROLLOUT_FAILED` pool-result row for
  a stopped machine as the job's result (`QROW done`). Before, it went through
  the dead path and was requeued, and two of those parked the ticket as
  `pool-died-twice`.

## Why

On 2026-10-03, #3966 and #3979 were rebuilt about 12 times between them and
never filed a child. Each build refused in about 20 s, idled 600 s, autostopped,
and was counted as a death.

## Not changed

The watchers' `ROLLOUT_FAILED → one ALERTS line, no comment` rule in
`prompts/*.md` stays. The lane posts now, so a watcher comment would be a
duplicate. The in-app board lane comments nothing and moves nothing on a
refusal, same as before.
