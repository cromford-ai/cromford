# BH-8884: the console project row shows `prod: red since <time>`

Doc: VERIFICATION-MAP

## What changed

1. `bin/fleet-status-push.sh` adds the field `prod` to each project row of the
   fleet snapshot, in the block `# >>> prod red (BH-8884)`. The block runs on
   the whole-fleet aggregate (`PROJECTS`), not in `fsp_project_row`. So a row
   that a per-project run writes does not change.
2. The console QUEUE cell on `/` (`ProjectsTable` in
   `console-ui/src/screens/Fleet.js`) shows a tag after the depth and its
   held/failed tail. `console-ui/src/lib/prod-red.js` `prodMarker` makes the
   tag. The sort key of the cell does not change.
3. The legend under PROJECTS does not change: `fleet-legibility.bh-3571`
   pins its 4 terms. The tag's title explains the tag.

## The field contract: `projects[<p>].prod`

| State | Value | Tag |
|---|---|---|
| red | `{"state":"red","since":"<iso>","sha":"<sha8>","id":"<vercel id>"}` | red `prod: red since Oct 27 19:10Z`; the title names the commit and the Vercel id |
| unknown | `{"state":"unknown","generated_at":"<ga or none>"}` | faint `prod: unknown` |
| green | key absent | none |

- Only a project that `vercel.conf` names can get the key. Other projects have
  no production deploy on Vercel.
- `unknown` means the snapshot `state/vercel-deploy-status.json` is missing,
  not JSON, or older than `MC_PROD_RED_MAX_AGE_S`. The conductor does not hold
  in that state, so the page does not say red. It also does not say green.
- If the conductor fragment is not there, or jq fails, the block leaves the
  rows as they were. The push still goes out.

## Why the conductor's reader

The block calls `mc_prod_red_state` from
`bin/merge-conductor.d/bh-8781-prod-red-hold.sh`. That is the function the
merge conductor holds on. The block also uses the same staleness knob,
`MC_PROD_RED_MAX_AGE_S`. So the page says red exactly while the queue holds
the project's READY PRs. `bin/lib/prod-red-defer.sh` sources the same fragment
the same way. This change adds no knob and no table.

## Live probe (hub, after deploy)

1. Run `jq '.projects|map_values(.prod_red)' /root/harness/state/vercel-deploy-status.json`.
2. If a project shows a record, open `/` and find its row in PROJECTS.
3. Look for `[data-testid=prod-red]` in the QUEUE cell.

## Tests

- `tests/fleet-status-push-prod-red.bh-8884-test.sh` (P1-P7): the push field.
- `console-ui/tests/fleet-prod-red.bh-8884.test.js` (R1-R6): the tag.
