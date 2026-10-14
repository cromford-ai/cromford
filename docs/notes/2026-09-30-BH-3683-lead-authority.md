# The hub lead-review lane is the verdict authority; protected paths need a human (BH-3683)

Doc: MERGE-CONDUCTOR, MERGIFY

## The rule

`lead-verdict` is the commit status Mergify's `queue_conditions` require on
cromford (BH-3348). Since BH-3683, who may publish `success` is one
decision, `la_decide` in `bin/lib/lead-authority.sh`:

- **The hub lane is the authority.** `bin/lead-review-land.sh` promotes a done
  lead review with `bin/lead-verdict.sh post … --source lead --reviewer box:<hub>`,
  and on a normal PR that post publishes `lead-verdict: success` from the hub.
  The lead's Mac is optional: nothing on the Mac is needed for a normal PR to
  reach the queue.
- **Protected paths need a human.** A repo is governed when it has at least one
  line in `catalog/lead-protected-paths.tsv` (`<owner/repo>\t<glob>`; `**` reads
  as `*`, and `*` crosses `/`). The settings row
  `lead_protected_paths_extra.<owner>.<name>` adds space-separated globs; it can
  never remove one. Removing a committed glob takes a PR to the catalog, and the
  catalog is itself protected. For a governed repo, a PR whose files (filename or
  previous_filename, so renames and deletes count) match any glob gets no
  `success` from the lane or the conductor. Only a `--source human` post
  publishes it.
- **The lane's authority can be revoked.** The row `lead_authority.<owner>.<name>`
  reads `lane` (or is absent) by default. `human` (set by an operator) or
  `human:precision` (set by the precision lane) makes every lead MERGE on the
  repo advice, protected or not.
- **Undecidable is withheld.** A files read that fails or hits GitHub's 3000-file
  cap, a head that moved during the read, an unreadable row, an unknown row value
  or a missing catalog: nothing publishes `success`.
- A BLOCK always publishes `failure`, from any writer. A repo with no catalog line
  is not governed and costs no read.

## The two writers

1. `bin/lead-verdict.sh post --source lead` with MERGE / MERGE-WITH-NOTES asks
   `la_decide … lead`. Withheld: the row is still recorded (precision scoring
   reads it) with the note token `authority:human-required`, stderr says
   `status withheld on <sha12>: <reason>; a --source human verdict publishes it`,
   and the exit is **5**. `LV_CLIENT_LEVEL` is now 3.
2. `mc_enqueue_mergify` (`bin/lib/mc/queue.sh`) asks `la_decide … conductor`
   before its own `vs_publish`. A standing human MERGE on the head clears it.
   rc 1: no status, one `lead-human-needed-*` warn beat, and the label plus the
   `@mergifyio queue` ask go out as before, so Mergify parks the PR on
   `queue_conditions` until the human's post. rc 2: nothing published or asked,
   rc 3, the BH-2199 hold.

The land lane reads post rc 5 as a promotion: steps 2b/2d and the stamp run,
the spot-check (BH-3547) does not, and `la_human_needed` sends one warn beat per
head (marker `state/lead-authority/human-needed-<owner_name>-<pr>-<sha12>`,
shared with the conductor, written only after the send). A beat that could not be
sent leaves the request unstamped, and the next tick's stamp-only pass asks again.

## Precision revokes and restores

`bin/lead-review-precision.sh` (daily 05:40Z) now ends with an authority gate for
each governed repo with no error, a precision, and `lead_merge >=
LEAD_REVIEW_PRECISION_MIN_N`:

- precision under `LEAD_REVIEW_AUTHORITY_MIN_PRECISION` (settings row
  `lane.lead-review-precision.lead_review_authority_min_precision`, default 0.8,
  below the 0.9 warn line so the digest leads and the page follows) and the row
  reads `lane`: set `human:precision`, then ONE critical page
  `lead-authority-revoked-<owner_name>-<day>`. A failed row write pages nobody. A
  written row whose page failed leaves `authority-page-owed-<owner_name>`, sent
  first by the next run.
- precision back at or above it and the row reads `human:precision`: set `lane`,
  one warn beat `lead-authority-restored-<owner_name>-<day>`.
- a row reading `human` is never touched.

## Operator commands

```bash
bin/lead-verdict.sh authority example-org/cromford              # the rule in force
bin/lead-verdict.sh authority example-org/cromford <pr> <head>  # the answer for one head
bin/lead-verdict.sh post example-org/cromford <pr> <head> MERGE --source human
bin/jobs-client.sh setting-set lead_authority.example-org.cromford human   # revoke by hand
bin/jobs-client.sh setting-set lead_authority.example-org.cromford lane    # restore
bin/jobs-client.sh setting-set lead_verdict_min_client 3   # after deploy: refuse pre-BH-3683 clients
```

## Known limits

1. `source=human` is a claim made with the shared lead token. The hub's code never
   sends it (`tests/lead-review-land-authority.bh-3683-test.sh` L4), but anyone
   holding the token file could. A human-only token is a follow-up.
2. `HARNESS_SECRET` can PUT settings rows, and every builder box has it, so a
   builder could write `lead_authority.*=lane` to undo a revocation. The extras
   row cannot remove protection. Moving the authority row behind the lead token
   is a follow-up.
3. The conductor still publishes `success` on a builder APPROVE for unprotected
   PRs without waiting for the lead lane. That is the behaviour from before this
   change, and a revocation now covers it.
4. `bin/lib/mc/queue.sh` is deliberately not a protected path: it is a hot shared
   file, and listing it would route most conductor PRs to a human. Open follow-up.
5. A checkout whose `bin/lib/lead-authority.sh` is missing publishes as before
   (both writers only ask when the lib loaded). The lib is itself protected, and
   `lead_verdict_min_client 3` refuses a pre-BH-3683 lead-verdict client.
