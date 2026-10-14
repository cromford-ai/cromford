# Enforce mode stops lead-token "human" rows standing; an unreadable mode fails closed (BH-3849)

Doc: MERGE-CONDUCTOR

## What was wrong

BH-3831 made `enforce` refuse a new `source=human` post that carried only the
lead token. Rows already recorded that way in shadow (`auth='lead-token'`) kept
standing on `GET /api/verdicts&head=`, so flipping to enforce left every one of
them able to clear or block a merge. And a settings read that threw read as
shadow, so a D1 hiccup after the flip quietly reopened the same hole for new
posts.

## What changed

- **GET `&head=` under `enforce`**: `standing` skips `source='human' AND auth IS
  'lead-token'`. Human rows with `auth` NULL (written before BH-3831) or
  `human-token` still stand, and so do lead rows. Under `shadow` (the seed, a
  missing row, junk) the query is the same as before. The history `rows` are
  never filtered.
- **An unreadable `human_verdict_mode`** (the settings SELECT throws) is no
  longer shadow. A `source=human` POST gets 503 and nothing is written, even with
  the human token, because the worker can't tell which rule applies. Box and lead
  posts still go through, and their 201 says `human_verdict_mode: null`. A GET
  with `&head=` gets 503, which `vd_standing` reads as rc 2, a hold in every
  consumer (`la_decide`, `mc_hv_override`, the block gate, merge-conductor,
  blocked-resolver). A GET without a head doesn't read the mode.
- **`bin/lead-verdict.sh`** prints one stderr warning when the human token file
  is not mode 600: `lead-verdict: warning: <path> is mode <m>, not 600 — chmod
  600 it`. The post still goes out and the rc doesn't change. It prints the path
  and mode, never the token.
- **The edge we accept.** In enforce, if the newest row on a head is a
  lead-token human BLOCK and an older lead MERGE exists, the lead MERGE stands.
  A lead-token holder could post a newer lead MERGE anyway, and a lead row still
  goes through `la_decide` with no human waiver.

## Operator steps (these replace step 1 of the BH-3831 note)

1. Set the worker secret with `printf`, never `echo`. `echo` adds a trailing
   newline, the stored secret no longer matches the header, and every human post
   is 403:

   ```
   printf '%s' "$TOKEN" | wrangler secret put HUMAN_VERDICT_TOKEN
   printf '%s\n' "$TOKEN" > ~/.config/cromford/human-verdict-token
   chmod 600 ~/.config/cromford/human-verdict-token
   ```

2. **Pre-flip check**, before the PUT to `enforce`. List every lead-token human
   row:

   ```
   wrangler d1 execute <jobs db> --remote --command "SELECT id, repo, pr, head_sha, verdict, reviewer, created_at FROM verdicts WHERE source='human' AND auth='lead-token' ORDER BY id DESC"
   ```

   For each repo/pr it lists, run `gh pr view <pr> -R <repo> --json
   state,headRefOid`. A row whose `head_sha` equals an OPEN PR's `headRefOid`
   stops standing at the flip. If a person really wrote it, re-post it from the
   Mac with the human token
   (`bin/lead-verdict.sh post <repo> <pr> <head> <verdict> --source human`).

3. Flip from the Mac as the BH-3831 note says (`PUT /api/settings` with the
   bearer and `x-human-verdict-token`).

## The lead override, stated exactly

BH-3814 (`mc_hv_override`, `bin/lib/mc/classify.sh`) lets a `lead` MERGE
override the conductor's re-review BLOCK only where `la_decide <slug> <pr>
<head> lead` returns rc 0. rc 1 means no override, rc 2 means hold. The lead
token is readable on the hub, so a hub process can post `source=lead`. That is
why `lead` never gets the human waiver in `la_decide`.
