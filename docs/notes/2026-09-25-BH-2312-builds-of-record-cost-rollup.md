# cost-rollup binds a build dir to its PR from the ledger (BH-2312.4)

Doc: COST, JOBS

`bin/cost-rollup.sh` (BH-2351) is the first lane that reads `bin/lib/builds-of-record.sh`.

- A new block, `# >>> ledger pr binding`, runs before the fleet row union. It sources
  `bin/jobs-client.sh` and the lib, sibling-first. It then calls `bor_list <project> <45 days ago>`
  once for every project in `fleet.conf` (blank, `#` and `*redirect*` lines skipped) plus every
  `BOXPROJ` project. The rows go to a per-run temp TSV that the per-PR python reads through
  `COST_ROLLUP_BOR_TSV`. The file is removed after python, including on the crash path.
- PR for a build dir: the ledger's `pr_url` column, else a URL in its `result_line`. The dir name is
  matched with its `pool-`/`fly-` prefix stripped, the same way the lib strips it. A dir the ledger
  names without any URL gets no row. Its RESULT is not read. A dir the ledger does not name is
  bound from its RESULT exactly as before. This applies to hub dirs and mirrored dirs alike.
- The remote tar drops `-name RESULT` only when every project answered rc 0 or 2 and no feed hit
  its row cap (`BOR_TRUNCATED`). An rc 1 anywhere, a capped feed, or no reader at all keeps today's
  find command byte for byte. One `agent-rules.log` line per run says which way it went and names
  the projects that did not answer.
- Known consequence: while RESULT is dropped, a new remote dir that the ledger does not name
  has no RESULT in the mirror, so it gets no row. RESULT files mirrored earlier stay under
  `state/cost/remote-builds/` and still count.
- The empty `cost-per-pr.csv` alert now says "a PR binding (ledger or RESULT)".

Unchanged: the `cost_rows` read and the ssh collection of `cost.csv` (BH-1032), and the
`cost-per-pr.csv` shape.

Tests: `tests/cost-rollup-db-first.bh-2312-test.sh` runs the real script against a stub feed and a
stub ssh.
