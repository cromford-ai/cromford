# Archie's earned autonomy (BH-4067, wave 6 of #3966)

Doc: DB-COORDINATION-SPEC, OPERATOR-SETUP

## What changed

Every escalation Archie sends is now a row in the jobs DB table
`archie_decisions`: the initiative, the decision class, the recommendation,
whether it was asked or handled (`mode` ask|auto), and the operator's answer once he
gives it (`choice`, `choice_key`). The check prompt
(`catalog/prompts/archie-check.md`) asks the model for a first line
`CLASS: <slug>` from a fixed list; `archie_split_class` in `bin/lib/archie.sh`
splits it off, and a missing or malformed line is `unclassified`.

Classes live in `archie_classes` (seeded, all `ask_first`):

- delegable: `watch-continue`, `watch-cadence`, `watch-stop`, `ticket-file`,
  `hold-resume`
- never delegable: `client-board`, `spend`, `production`, `merge`, `deploy`,
  `unclassified`

The flow:

1. `Archie approve I<n>` on an escalation adds one to its class's streak. At
   `ARCHIE_DELEGATE_AFTER` in a row (settings row
   `lane.archie.archie_delegate_after`, seeded 5) the reply offers:
   `Say: Archie delegate <class>, or Archie ask first <class>.`
2. `Archie delegate <class>` moves the class to `delegated`. This is the only
   way a class gets there. The worker refuses a protected class, an unknown one,
   one below the streak, and any call with actor `archie`.
3. A due check in a delegated class is handled: in the same D1 batch as the
   ledger row the worker writes Archie's approve (`initiative_events`
   `reply:<id>:auto-<sha1(due_at)>`, actor `archie`, and
   `initiatives.last_decision`). The beat is then the after-report:
   `Handled under your standing OK for <class>: <recommendation>`, with an
   `Overrule:` line.
4. `Archie change I<n> …` or `Archie drop I<n>` is an overrule: streak 0, and
   a delegated class goes back to `ask_first`. The reply says so.
   `Archie ask first <class>` does the same on purpose.

## The floor that does not move

A class is protected when its `never_delegable` column says so (a CHECK pins
it to 1 for the six seeded protected slugs, and another keeps any
never-delegable class `ask_first`), or when its name matches the worker's
`PROTECTED_RE`, or (per escalation) when `archie_sensitive` matches the class,
goal or recommendation against `ARCHIE_SENSITIVE_RE` (clients, money,
production, merges, deploys and their usual words). A sensitive escalation is
never auto-handled and never counts toward a streak. Both lists are code
constants on purpose: a settings row would let a settings write widen
Archie's authority without the operator.

## Failure direction

A ledger write that fails is one warn line in `logs/archie.log` and the
ordinary ask beat. A choice write that fails adds nothing to the reply; the
"Recorded" line stays true because the initiative reply did land. A delegation
write that fails says "Nothing changed".

## Naming

The plan called the stop-watching class `watch-drop`. It is `watch-stop`,
because `worker/jobs/test/schema-deploy-queue.bh-1026.test.js` refuses the
word DROP anywhere in `schema.sql`.

Tests: `tests/archie-autonomy.bh-4067-test.sh` (the shipped tick and intercept
over a jq model of the routes, with mutations) and
`worker/jobs/test/archie-autonomy.bh-4067.test.js` (the real worker over the
real schema).
