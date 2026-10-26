# Triage intake on the tracker contract, slice C0 (BH-7920)

Doc: tracker-adapter

## What changed

Wave 2 of #7916, slice C0. Two changes.

- `tracker_list` (`bin/lib/tracker.sh`) takes `--state open|all`,
  `--label <name>` and `--since <iso>`. Each adapter narrows its server query
  with them (GitHub params, Jira JQL, Linear GraphQL filter; the board has
  none). Then one shared check applies them to every row. With no flag every
  adapter sends the request it sent before. Every list row gains `updatedAt`
  (UTC ISO or null), `state` (`open|closed`) and `commentCount` (integer or
  null). `tracker_read` is unchanged.
- `bin/triage-gate.sh` reads a Jira or Linear project through the contract in
  every mode: plain, `--seed`, `--pending`, `--thread`, `--signal`,
  `--buildable` and `--buildable-strict`. Before, only `--buildable` on Jira
  did, and every other mode read the project as a GitHub Issues board. The
  GitHub and board arms are unchanged.

## Why

A Linear or Jira project has fleet.conf column 4 `-`. The gate read it as a
GitHub repo and never saw its tickets, so triage never woke for them.

## What it touches

- New settings row `tracker_linear.<project>.list_comment_cap` (1..50, no
  row = 25): the comment ids one Linear list row asks for.
- The gate asks `tracker_kind` only when the env file sets `JIRA_BASE` or
  `LINEAR_API_KEY`. A context that does not load writes one ALERTS line per
  project per day and gives the token-unresolved answer for the mode.
- `state/<project>.gate.json` and `.gate.pending` of a Jira or Linear project
  are `{"jira"|"linear": [rows]}`. `bin/lib/rt/scope.sh` does not read that
  shape yet (slice C1).

## Not in this slice

C1: wake-loop and scope on the contract, self-write absorption for Jira and
Linear comments, the webhook secrets. C2: `bin/trk` and the prompt render. C3:
the lane ports and their ratchet lines.
