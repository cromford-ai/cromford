# BH-6192: the rules pack refuses every new NNNN schema fragment

Doc: VERIFICATION-MAP

## What changed

1. Rules pack row `schema-fragment-name` (delta, `rp_schema_fragment_name` in
   `bin/lib/rules-pack-checks.sh`): a new `worker/<w>/schema.d/NNNN-*.sql`
   fragment is a finding on a free number too. This applies to a fragment that
   is added, renamed into place or untracked. A free number gets the generic
   "never a picked number" line. A number the base already has keeps the
   "already taken at the base by <fragment>" line. Each fragment is one finding.
2. The self-check row `body-schema-stamp` (`catalog/pr-self-check.tsv`) is in
   mode `off`. The pack refuses now, so the note has no use.
3. NNNN fragments that exist at the base are not judged. An edit, a delete and
   a rename of a base NNNN fragment to the stamp form are clean.

## Why

BH-5788 let a free-number NNNN fragment pass while the open NNNN PRs drained.
A free number is still a picked number: the next build picks it too. The only
name for a new fragment is `<yyyymmddhhmm>-<ticket-key>-<name>.sql`.

## Tests

`tests/schema-fragment-name.bh-6192-test.sh` (F1-F9).
`tests/schema-fragment-name.bh-5788-test.sh` N5 and N9 changed (TEST-CHANGE).
