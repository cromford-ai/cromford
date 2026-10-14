# A reviewed, green tier-2 PR on a Mergify repo enqueues itself

Doc: MERGE-CONDUCTOR, TRUST-PROGRAM

## What was wrong

On 2026-09-23, at 11:30Z and again at 17:00Z, the project-5 board had 12 and then 20
harness PRs sitting at Mergify's "tick the box to add this pull request to the merge
queue" prompt. Every one had a harness APPROVE at tier 2 and `Build + Unit tests` green
on its head. Nothing merged until a person posted `@mergifyio queue` on each one. The
conductor logged `merges=0` the whole time.

Two things kept them there. The conductor's own READY enqueue (`mc_enqueue_mergify`)
adds the `merge-queue` label and posts `@mergifyio queue` under the token it armed for
the repo, which is the App installation token wherever one can be minted, and Mergify
refuses the command from that sender ("sender needs write permission"). The label rule
in `.mergify.yml` has never queued a PR either (docs/MERGIFY.md section 2).

## What changed

`bin/lib/tier2-autoenqueue.sh` adds `ae_project`, which the conductor calls once per
project per tick after every PR worker has answered. It uses the rows the tick already
listed. It considers only a row whose PR worker reached the READY arm's enqueue point that
same tick, so every hold the conductor already applies (provenance, the iron-law scan,
a tightened repo, pre-arm guards, the main-red freeze, an open declared dependency)
stops it exactly as it stops the conductor's own enqueue. The first review of this
change caught a version that re-decided on its own, smaller set of gates. On a Mergify
repo that comment is a merge, so that version was a second, weaker route to main.
A row that passes every gate gets one `@mergifyio queue` comment per (PR, head),
posted with a PAT through the new `gh_repo_use_pat` in `bin/lib/gh-repo-token.sh`
(the default PAT, then the admin PAT, never the App token). The gates and the
write-then-send-then-confirm ledger are in docs/MERGE-CONDUCTOR.md section 4.

It keeps its own record: `ledgers(kind=autoenqueue, key=<pr-url>@<head>)`, with
`state/tier2-autoenqueue.txt` as the write-through copy. It is read when the worker is
down or has no row, because it only ever holds this step's own writes. The build row gets an `enqueued` artifact carrying `enqueued_at` and
`enqueued_head`. Four settings rows on the `merge-conductor` lane control it:
`MC_AUTOENQUEUE`, `MC_AUTOENQUEUE_CAP`, `MC_AUTOENQUEUE_CHECK` and
`MC_AUTOENQUEUE_HOLD_LABELS`.

## What it does not prove yet

The root cause was read from the ticket and the docs. It was not reproduced, because
the build box cannot see example-org/project-5. If the real blocker is something else
(for example `mergeable_state=blocked`, or the hub's `merge-conductor-merge` flag being
absent), the step refuses too, and it says so. Each refusal writes one
`AUTOENQUEUE … not enqueued at <head8>: <gate>` line per (PR, head), so the first real
tick on the hub names the gate that holds.
