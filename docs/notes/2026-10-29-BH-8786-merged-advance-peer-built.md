# BH-8786: merged-ticket advance for tickets a peer fleet built

Doc: VERIFICATION-MAP

## Why

On 2026-10-29, 42 project-2 tickets were shipped work that sat in
`in_progress` with `waitingOn=team`. Their PRs merged between 2026-10-06 and
2026-10-22. A peer fleet (partner) built them, so this box had no build dir for
them. `bin/merged-ticket-advance.sh` dropped each one with a silent
`[ -n "$newest" ] || continue`, and its log line said `moved=0` with every
counter at 0.

## What changed

- `bin/merged-ticket-advance.sh`: a ticket with no local build dir takes the
  peer path. Build fact: the newest thread comment with a PR URL on the
  fleet.conf repo. Merge fact: `gh_rest GET repos/<slug>/pulls/<n>`
  (`bin/lib/gh-rest.sh`), with the credential `gh_repo_use_token` picks
  (`bin/lib/gh-repo-token.sh`). Deploy fact: one read per run of the prod
  version route (`VERSION_URL`, else `<prod-url>/api/internal/version`, with
  `VERSION_AUTH` or the board bearer); the live sha is the merge, or GitHub
  compare answers `ahead` or `identical`. A 404 there means no version route:
  the ticket waits `MERGED_ADVANCE_DEPLOY_GRACE_S` after `merged_at`, and the
  comment says "merged, deploy not confirmed from here". Unknown is never yes.
- Dedupe token on the peer path: `pr-<n>-<merge sha8>`. The holds
  (`client-spoke` after `merged_at`, `moved-back`, `move-gave-up`) and the
  write order (comment, marker, move) are unchanged.
- After an echoed move to `review`, on both paths, the lane posts
  `POST /tickets/<id>/turn {"to":"client"}`. A failed turn is one
  `MERGED_ADVANCE_TURN_FAILED <KEY> HTTP <code>` line.
- The `MERGED_ADVANCE` line gains six fields at its end: `no-local-build`,
  `no-pr-in-thread`, `pr-open`, `deploy-behind`, `peer-unread`,
  `pr-ambiguous`. The old prefix does not change.
- Knob `MERGED_ADVANCE_DEPLOY_GRACE_S` (default 1800 s) in
  `catalog/lanes.d/_lib.merged-advance.json`.
- A repo no credential can see is one `gh_repo_invisible_alert` line a day
  (lane `merged-advance`), and its peer tickets count `peer-unread`.

## How to check it

- `bash tests/merged-ticket-advance.peer-built-test.sh`
- On a box: `bin/merged-ticket-advance.sh <project> --dry-run`, then read the
  last `MERGED_ADVANCE` line in `logs/<project>.log`.
