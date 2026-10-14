# A source=human verdict is proven by its own token, not the shared lead token (BH-3831)

Doc: MERGE-CONDUCTOR

## What was wrong

`POST /api/verdicts` accepted `source=human` from anything holding the bearer
and the lead verdict token. The lead token is on the operator's Mac AND the hub, where
`bin/lead-review-land.sh` and `bin/lead-review-enqueue.sh` read it to post
`source=lead`. So anything that could read that file on the hub could write a
human row, and the worker could not tell the two apart. BH-3683 named this as a
known limit and deferred a separate human token.

## What changed

- **A second worker secret, `HUMAN_VERDICT_TOKEN`**, sent as
  `x-human-verdict-token`. It lives only on the Mac
  (`~/.config/cromford/human-verdict-token`, mode 600).
  `bin/lead-verdict.sh post … --source human` reads it from
  `HUMAN_VERDICT_TOKEN_FILE` into the same 0600 header file as the other two
  credentials. Without it, the post still goes out with one stderr line, and
  after a 201 that is not `human_verified` it prints an UNVERIFIED line.
- **`verdicts.auth`** (additive, `ADDED_COLUMNS` widens a live table on the
  first post): `secret` for box rows, `lead-token` for lead rows and for human
  rows without the human token, `human-token` for proven human rows. Old rows
  read `NULL`. The 201 body gains `human_verified` and `human_verdict_mode`.
- **`human_verdict_mode`** settings row, seeded `shadow`. In shadow, an
  unproven human row is recorded and logged. In `enforce`, it is refused 403
  and nothing is written. Any value other than exactly `enforce` reads as shadow.
  A PUT of this one key needs the human token.
- The decision is reject, not downgrade: an unproven `human` is never rewritten
  to `lead` (the `validateVerdict` rule, and a rewrite would be scored as lead
  output by `lead-review-precision.sh`).
- `tests/mc/hv-override-source.bh-3831-test.sh` pins `mc_hv_override`'s source
  filter: a `box`, unknown, empty or wrong-case source never overrides a BLOCK.

## Operator steps

1. `wrangler secret put HUMAN_VERDICT_TOKEN` on harness-jobs, then write the
   same value to the Mac's `~/.config/cromford/human-verdict-token` and
   `chmod 600` it.
2. After deploy (shadow), check that no new `source='human' AND auth='lead-token'`
   rows come from the Mac.
3. Flip from the Mac: `PUT /api/settings {"key":"human_verdict_mode","value":"enforce"}`
   with both `authorization: Bearer …` and `x-human-verdict-token: …`.

## Where each credential is readable (scope item 1)

Names only, checked against this tree on 2026-10-01.

| credential | where it is readable | how it gets there |
|---|---|---|
| `HARNESS_SECRET` (jobs bearer) | every fleet box including the hub (`/etc/harness/env/global.env` via `bin/lib/env-path.sh`); every Fly builder (`bin/fly-envbundle.sh` bundles it, `fly/builder-runner.sh` posts the console beat with it); the console Pages project env; every agent session those boxes launch inherits it | env bundle / `bin/harness-sync.sh` |
| `LEAD_VERDICT_TOKEN` | the operator's Mac and the hub (`~/.config/cromford/lead-verdict-token`, read by `bin/lead-verdict.sh`, `bin/lib/lead-reviews.sh`, `bin/lead-review-land.sh`, `bin/lead-review-enqueue.sh`); the worker secret | hand-installed, never in `env/global.env` (MERGE-CONDUCTOR §17) |
| `HUMAN_VERDICT_TOKEN` (new) | the operator's Mac only (`~/.config/cromford/human-verdict-token`, mode 600); the worker secret | `wrangler secret put HUMAN_VERDICT_TOKEN` plus the hand-installed file. Never on the hub, a box or in a bundle |
| `CLOUDFLARE_API_TOKEN` | the hub (`env/cloudflare.env`, read by `bin/console-pages-deploy.sh` and `bin/pipeline-health.sh`) | hand-installed on the hub |

Nothing that ships to builders references the new file:

```
$ grep -rn 'config/cromford\|human-verdict-token' fly/ bin/fly-envbundle.sh bin/harness-sync.sh
(no output, rc 1)
```

**Out of scope here: the D1 path.** `CLOUDFLARE_API_TOKEN` can write D1
directly. A hub process holding it can insert a `source='human',
auth='human-token'` row or set `human_verdict_mode` back to `shadow`, and
neither worker check sees that write. This PR closes the worker API path only.
Narrowing the hub token and signing proven human rows is #3846.

**The lead lane can still override a re-review BLOCK.** `mc_hv_override`
(`bin/lib/mc/classify.sh`, BH-3814) clears a BLOCK on a `lead` MERGE the same
way as a `human` one, as long as lead authority stands (`la_decide`). The lead
token lives on the hub, so the hub's lead lane can do that on its own. The
ticket allows this. The human token proves a row came from a person. It does
not stop the lead lane overriding.

## New secret, and every place it is set

- `HUMAN_VERDICT_TOKEN`: worker secret on `harness-jobs` (`wrangler secret put`).
- The same value in `~/.config/cromford/human-verdict-token` on the operator's Mac
  (mode 600), or wherever `HUMAN_VERDICT_TOKEN_FILE` points.
- Nowhere else: not Vercel, not CI, not `env/global.env`, not the Fly bundle.
  CI's worker tests set it on their fake env.
