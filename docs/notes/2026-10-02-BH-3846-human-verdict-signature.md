# A human verdict, and the switches that trust one, are signed by the worker (BH-3846)

Doc: MERGE-CONDUCTOR

## What was wrong

BH-3831 made `POST /api/verdicts` prove a `source=human` row with the human
token. That proves who POSTed, not who wrote the D1 row. A credential that can
run `wrangler d1 execute` against the jobs database can insert
`source='human', auth='human-token'` itself, or flip `human_verdict_mode` back
to `shadow`, and every merge lane reading `vd_standing` would trust it.

## What changed

- **A worker-only signing key, `HUMAN_VERDICT_SIG_KEY`.** When a row is written
  with the human token, the worker signs it before the INSERT. The signature is
  stored in the new column `verdicts.human_sig`: HMAC-SHA256 over
  `bh-verdict-v1\n<repo>\n<pr>\n<head_sha>\n<verdict>\n<created_at>`. The 201
  body says `human_signed`.
- **`GET /api/verdicts` judges proof.** Every row in `rows[]` and `standing`
  gets `human_proven`. It is `null` for a non-human row and `true` only when the
  signature verifies under the key AND the row is the first one in its PR
  carrying that signature. A NULL sig, a bad sig, a sig moved onto a row with
  different fields, or a missing key all read `false`. So does a whole-row
  replay: `INSERT ... SELECT` of an old signed MERGE copies a signature that
  verifies on its own fields, but an earlier row already carries it, so the
  copy reads unproven. `created_at` is whole seconds, so two genuine posts with
  identical fields in the same second (a retry) also collide: the second reads
  unproven, which is the safe direction, and a post a second later is signed
  fresh.
- **A new switch, `human_verdict_sig_mode` (seeds `shadow`).** In `shadow`, an
  unproven standing human MERGE is logged (`[verdicts] BH-3846 shadow: ...`)
  and stands as before. In `enforce`, `standing` answers `source: lead` with
  `source_recorded: human`, so a forged human MERGE has a lead MERGE's
  authority. The hub can already write one of those, so the forgery gains
  nothing. A BLOCK is never downgraded, and `rows[]` and the stored row are
  never rewritten, so the precision scorer still reads the truth. No `bin/`
  reader changed: they all reach the row through this GET.
- **The two switches are signed settings.** `PUT /api/settings` of
  `human_verdict_mode` or `human_verdict_sig_mode` needs the human token, and
  in the same batch it writes `<key>.sig` = HMAC over
  `bh-setting-v1\n<key>\n<value>`. The response says `signed`. A PUT of a
  `.sig` key is refused 400. `GET /api/settings` and `GET /api/settings/<key>`
  answer a protected `.sig` row with `value: null, redacted: true`. On read (`protectedMode` in
  `worker/jobs/src/routes/verdicts.js`):
  1. The worker secret `HUMAN_VERDICT_ENFORCE=1` forces `enforce`.
  2. A value of `enforce` is `enforce`.
  3. A `.sig` that does not verify, or one the worker has no key to check,
     reads `enforce` and logs `[settings] BH-3846 <key> signature mismatch`.
  4. A verified `.sig` reads `shadow`.
  5. No `.sig` row reads `shadow`. That is the unsigned seed, and it has to
     stay `shadow` so the deploy doesn't flip BH-3831 to enforce. It also means
     a D1 writer can delete the `.sig` row and write `shadow`. Only the floor
     in rule 1 closes that, which is why rollout step 5 is required.
  6. A settings read that throws reads `shadow` (BH-3831's rule).
- **Key unset.** A human-token post is written unsigned and logged, or refused
  503 under `human_verdict_sig_mode=enforce`, because that row could never read
  as proven. A protected PUT is written unsigned and answers `signed: false`.

## Operator rollout

1. `openssl rand -hex 32 | wrangler secret put HUMAN_VERDICT_SIG_KEY` on
   harness-jobs, from the operator's Mac, never from the hub. Store the value nowhere
   else.
2. Merge. `bin/harness-sync.sh` deploys the worker and applies the seed. The
   column lands through `ensureColumns` on the first verdicts POST.
3. Shadow: re-PUT `human_verdict_mode` with its current value and the human
   token, so it gains a `.sig` row. Watch `wrangler tail` for `BH-3846 shadow`
   lines. A human MERGE posted before step 1 on a still-open head has to be
   re-posted to be signed.
4. Enforce: PUT `human_verdict_sig_mode=enforce` with the human token.
5. Required, and part of enforce: `wrangler secret put HUMAN_VERDICT_ENFORCE`
   with the value `1`. Steps 1-4 alone do NOT hold against a D1 writer. It can
   delete a switch's `.sig` row and write `shadow` (rule 5), or write back a
   signed `shadow` it saved earlier (below), and either way an unsigned human
   MERGE stands again. The floor lives outside D1, so nothing a D1 write does
   can lift it. Until step 5 is done, call the protection shadow-only.

## What this does not close

- **Replay of a signed setting.** A setting signature covers only the key and
  value, with no version or nonce, so it is the same every time that value is
  signed. Once `shadow` has been signed for a switch, step 3 included, a D1
  writer that read that `.sig` can write `shadow` plus the saved sig over a
  later signed `enforce`. It verifies under rule 4 and logs no mismatch. The
  redacted GET keeps the sig from plain `HARNESS_SECRET` holders, but a D1
  reader can just SELECT it. D1 has no monotonic state the worker can trust, so
  the floor (step 5) is the real control for both switches, and the signed
  settings only make tampering show up when the floor isn't set.
- **A D1 writer that drops the append-only triggers** can delete the original
  of a signed row and then replay it as the only copy. That same writer could
  just delete the newer human BLOCK, so it is the D1 credential itself (child
  slice C1 below) that has to close this, not a signature.

- A credential that can `wrangler deploy` the worker can ship code that reads
  the worker's secrets. No worker-side secret is proof against the deploy
  credential itself.
- The hub's `CLOUDFLARE_API_TOKEN` was NOT narrowed here. It is still used for
  `wrangler pages deploy` (`bin/console-pages-deploy.sh`), a Pages read
  (`bin/pipeline-health.sh`), `wrangler d1 execute --remote` for every
  `worker/*/schema.sql` statement (`d1_exec` in `bin/harness-sync.sh`), and
  `wrangler deploy` of every worker (`bin/harness-sync.sh`). Taking D1 edit off
  it first needs the schema apply moved behind a worker route, then a
  Cloudflare dashboard edit and a scope probe. That is the child slice C1 of
  #3846 (ticket scope 1 and 2, acceptance test 3).
