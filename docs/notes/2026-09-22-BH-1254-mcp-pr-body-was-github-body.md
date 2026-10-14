# BH-1254: the hub MCP `pr` tool served #1212's real GitHub body; the body itself had been overwritten

**What happened.** The delta review of #1212 posted at 2026-09-21T14:35:45Z reported that
`mcp__harness__pr` returned a fix-main-red PR's body when asked for #1212: the body started
"Main of `example-org/cromford` is red on `tests/blocked-resolver-test.sh`..." while the
checks block was #1212's own. It was filed as BH-1254, a hub-side bug, with the worker's PR
cache as the suspect (keyed on the head branch prefix, or a D1 row two PRs share). The tool
was not the bug. GitHub's stored body for #1212 IS that text, and has been since
2026-09-21T12:27:24Z. The tool returned what GitHub held.

**Cause.** A by-hand edit to #1212's body carrying #1233's text. `userContentEdits` on #1212
has `totalCount` 8, every one by `operator`. Node 0 is `2026-09-21T12:27:24Z`, and its `diff`
field `cmp`-equals the live body today, 5278 bytes. Node 1 is `2026-09-21T05:38:25Z`, 16884
bytes, starting "Closes #1203 / > **Review round 3 (head `6336d498`, rebased o...". That is
#1212's real body. The text that replaced it belongs to #1233 (`fix-main-red/contested-1229`,
created 2026-09-21T10:03:11Z, merged 10:23:01Z), whose own body has `lastEditedAt` null and
`userContentEdits.totalCount` 0, so #1233 was the source and never the victim. The two bodies
are byte-identical today, 5278 bytes each, `cmp` rc 0.

The timing names the moment. #1212's `head_ref_force_pushed` events are all by `operator`:
04:39:49Z to `58e0e414`, 05:37:56Z to `6336d498`, 12:27:06Z to `09ca9462`, 14:41:36Z to
`da02fd36`. The body rewrite landed 18 seconds after the 12:27:06Z push, from the same
identity. That push is the by-hand rebase onto train #1234 that the delta review describes,
done by hand because the fleet review lane was out of Claude quota. The shape that fits is a
`gh pr edit 1212 --body-file` run in that session against a body file left over from the
#1233 work. The review read the body two hours later and saw exactly what was stored.

No harness lane can have written it. The only in-repo PR-body writer is
`bin/run-build.sh:5881`, `gh pr edit "$PR_URL" --body "$(PR_BODY_FOR "$EVIDENCE_SECTION")"`,
which composes the build's OWN body and cannot emit fix-main-red text.
`bin/lib/gh-shim/pr-write.sh` sends a `body` field only when a caller passes `--body` or
`--body-file` (`gshim_prw_has_body` guards it). `grep -rln "is red on" bin/ prompts/ skills/`
returns `bin/main-red-detector.sh` and `bin/batch-resolve.sh`: the first is the flag message
`main is red on ${RSHA:0:8}`, the second is conductor console text about a PR's own CI
(`#$NUM own CI is red on ${HEAD:0:12}`). Neither is a PR-body template, and neither string
appears in the overwritten body.

**Where the suspected cache is not.** This repo holds no PR-body store, so the ticket's
suspect does not exist here to key wrongly.
`grep -rn "pr_body\|pulls/\|api.github.com" worker/jobs/src worker/jobs/schema.sql` returns rc
1, no hits. `pr_owners` is `(repo, number, project, state, since, reason, key, url, author,
draft, dirty_since, closed_at, actor, updated_at)` with `PRIMARY KEY (repo, number)`: no body
column, and already keyed on exactly the pair the ticket worried was missing. The only `body`
column anywhere in `worker/jobs/schema.sql` is `job_transcripts.body`, which holds rendered
agent transcript text. The MCP server and the console worker live in the private
`example-org/cromford-console`, 404 from this box, same as BH-667 found. Nothing in this
note claims anything about that server's internals. It does not need to: whatever it does, it
served the live GitHub body, and the live GitHub body was the wrong text.

This is TK-113 again. A symptom was attributed to the component that reported it. The
component was reading correctly and the record it read was wrong.

**How to check next time.** Before filing a hub bug for a PR tool that "returns another PR's
body", ask GitHub what it actually stores, and ask who last edited it.

```bash
# 1. is the served body actually GitHub's body? (substitute the two PR numbers)
diff <(gh pr view 1212 -R example-org/cromford --json body -q .body) \
     <(gh pr view 1233 -R example-org/cromford --json body -q .body) && echo BODIES-IDENTICAL

# 2. who last edited the body, and when? totalCount > 0 means a human retyped it
gh api graphql -f query='{repository(owner:"example-org",name:"cromford"){pullRequest(number:1212){lastEditedAt userContentEdits(first:2){totalCount nodes{editedAt editor{login}}}}}}' \
  -q '.data.repository.pullRequest'

# 3. what happened on the branch just before that edit?
gh api repos/example-org/cromford/issues/1212/timeline --paginate \
  -q '.[]|select(.event=="head_ref_force_pushed")|[.created_at,.actor.login,.commit_id[0:12]]|@tsv'

# 4. does this repo even have a PR-body store? (rc 1 = no hits = no store)
grep -rn "pr_body\|pulls/\|api.github.com" worker/jobs/src worker/jobs/schema.sql
```

If step 1 prints `BODIES-IDENTICAL`, the tool is innocent and the GitHub record is the defect.
Go to step 2 for the identity and timestamp, then step 3 for what that identity was doing.

Two things to know about these commands. `userContentEdits.nodes[].diff` is not a unified
diff, it is the FULL post-edit body, verified here: node 0's `diff` `cmp`-equals the current
body at 5278 bytes. And the REST timeline's `head_ref_force_pushed` events carry the sha in
`.commit_id`, with `.sha` null, so a `jq` expression reading `.sha[0:12]` prints an empty
column and looks like missing data.

**Repair, not done here.** Restoring #1212's body is a write to a merged PR outside any
reviewed diff, made against an edit the operator's own identity performed, so whether the record
matters is the operator's call. The source is #1212's own 05:38:25Z body, the text at reviewed head
`6336d498`, round 3. It predates the `09ca9462` and `da02fd36` rebases, so its "Review round
3" preamble is slightly stale, but it is #1212's own text, and nothing after 12:27:24Z touched
the body (`lastEditedAt` is 12:27:24Z).

```bash
gh api graphql -f query='{repository(owner:"example-org",name:"cromford"){pullRequest(number:1212){userContentEdits(first:2){nodes{editedAt diff}}}}}' \
  -q '.data.repository.pullRequest.userContentEdits.nodes[1]' > /tmp/pr1212-edit1.json
jq -r .editedAt /tmp/pr1212-edit1.json          # must print 2026-09-21T05:38:25Z
jq -r .diff /tmp/pr1212-edit1.json > /tmp/pr1212-round3.body
head -c 60 /tmp/pr1212-round3.body              # must start "Closes #1203"
gh pr edit 1212 -R example-org/cromford --body-file /tmp/pr1212-round3.body
diff <(gh pr view 1212 -R example-org/cromford --json body -q .body) /tmp/pr1212-round3.body && echo RESTORED
```

The two `must` lines are the guard. If either differs, stop, the edit list has moved.

Every reader of #1212's body re-reads GitHub, so one restore fixes all of them at once. The
readers are the hub MCP `pr` tool in the console repo, `bin/review-autopilot.sh:483` and
`bin/review-prs.sh:940` (`gh pr view --json body`, 4000-byte head), `bin/pr-owner-sweep.sh:252`,
`bin/launch-fastpath.sh:185` and `bin/pipeline-health.sh:416`. The last three read open PRs
only and #1212 is merged, so they were never affected. None of them cache the body.

The ticket's suggested acceptance test, a worker test that stores two PR bodies and reads each
back by number, is not written. There is no PR-body store in this worker to test, and a test
over a store invented for the test proves nothing (D4).

Doc: MERGE-CONDUCTOR
