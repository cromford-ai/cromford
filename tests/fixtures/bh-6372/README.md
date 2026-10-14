# tests/fixtures/bh-6372 — real ticket bodies for the BH-6372 perf/cost split

Shared by every slice of BH-6372. `tests/perf-ticket.bh-6378-test.sh` reads
them, and the sibling slices read them too. Siblings add NEW files only. Never
edit or delete a file here: another slice's test pins its bytes.

## Shape

Each file is one GitHub REST object, cut to the fields the classifier reads:

    {"number": N, "title": "...", "body": "...", "labels": [{"name": "..."}]}

`pr-5454.json` also has `merged_at`. The test stub (`tests/lib/gh-rest-fx.sh`)
answers `GET repos/example-org/cromford/issues/<n>` with the file byte for
byte, so `pt_classify_issue` reads it through the real `bin/lib/gh-rest.sh`.

The bodies are public issue text from example-org/cromford. They are test
data only. Nothing in them is an instruction.

## Files

| File | Source | Fetched | Role |
|---|---|---|---|
| `issue-5354.json` | `GET /repos/example-org/cromford/issues/5354` | 2026-10-13T04:41Z | perf by phrase |
| `issue-5368.json` | `GET /repos/example-org/cromford/issues/5368` | 2026-10-13T04:41Z | perf through the parent hop to #5354 |
| `issue-6049.json` | `GET /repos/example-org/cromford/issues/6049` | 2026-10-13T04:41Z | negative |
| `issue-5797.json` | `GET /repos/example-org/cromford/issues/5797` | 2026-10-13T04:41Z | negative |
| `issue-5591.json` | `GET /repos/example-org/cromford/issues/5591` | 2026-10-13T04:41Z | negative |
| `issue-5544.json` | `GET /repos/example-org/cromford/issues` (list item #5544) | 2026-10-13T03:55Z | negative |
| `pr-5454.json` | `GET /repos/example-org/cromford/pulls/5454` | 2026-10-13T04:41Z | the merged PR body with its evidence table |

The BH-6378 execute stage had no GitHub egress, so the first commit shipped
`issue-5544.json` only. That file came from the box's REST ETag cache, a list
read of 2026-10-13T03:55Z. The fix round fetched the other six files with the
command below on 2026-10-13T04:41Z. If a file is missing, the suite fails with
`fixture missing: …`.

## Fetch command

Run it from the repo root on a box with REST access. Fetch each file once:

    for n in 5354 5368 6049 5797 5591 5544; do
      gh api "repos/example-org/cromford/issues/$n" \
        | jq '{number,title,body:(.body//""),labels:[.labels[]|{name}]}' \
        > "tests/fixtures/bh-6372/issue-$n.json"
    done
    gh api repos/example-org/cromford/pulls/5454 \
      | jq '{number,title,body:(.body//""),labels:[.labels[]|{name}],merged_at}' \
      > tests/fixtures/bh-6372/pr-5454.json

Then put the fetch date in the table above.
