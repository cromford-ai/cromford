# The Changes-region check reads an empty region when a marker is missing

Doc: MERGE-CONDUCTOR, BUILD-CONCURRENCY, RUN-BUILD-GRAPH, OPERATOR-SETUP, EVENTS

the operator reviewed the first BH-476 head (`e475c08`, PR #786) and asked for changes.
The train merged it before the fixes landed, so this note records the round that
answers the review.

## What changed

**`guardrails/doc-monolith-edit/check.sh` — a missing marker is an empty region.**
The two region bounds used to default independently (`B=0` if there is no begin
marker, `E=0` if there is no end marker). A PR that deleted only
`<!-- changes:begin -->` therefore left `B=0` and `E` at the end marker's line,
and the check read that as "the region is lines 1..E-1" — most of the doc. It
answered `Clean` on a diff that removed the guardrail's own marker. The bounds
are now decided together: no file, one marker, or an end above its begin all set
`B=E=0`, and the check reports `no Changes region in this checkout`.

**`check.sh` — a removed line is inside the region up to and including the end
bound.** Added lines are judged strictly between the bounds (`n > b && n < e`),
and removed lines were judged by the same rule. But a removed line is judged at
the new-side number it sat on, so deleting the region's last pointer line puts it
exactly where the end marker now is — and the check failed the one edit the
region exists to allow. Removed lines now use `judge_rm(n)`: `n > b && n <= e`.
`tests/guardrail-doc-monolith-test.sh` had one case that passed for the wrong
reason (it ran the delete-a-marker fixture against a checkout that still had both
markers); it now runs against the tree the deletion leaves behind, which is what
CI reads.

**`bin/render-doc-index.sh` — `export LC_ALL=C`.** The script's header promises
two runs over the same directory are byte-identical. Its two `sort` calls
collated in the caller's locale, and `…-a-b.md` against `…-ab.md` is exactly
where C and en_US.UTF-8 disagree — so the index could churn between boxes on a
file nobody edited.

**Wording: the guardrail is not armed yet.** The five docs' Changes lines, D37 in
`prompts/build-discipline.md`, and the contract-docs bullet in
`prompts/plan-contract.md` all said the guardrail "enforces" the rule, "fails a
PR", "is a red build". It is not referenced anywhere in
`.github/workflows/harness-ci.yml`, `bin/` or `cron/`, so nothing failed
anything. Those lines now say the check fails a PR **once armed**, and name the
arming work as a separate adoption PR.

## What is still owed

Arming is its own PR, the one `guardrails/doc-monolith-edit/README.md` already
prescribes: wire the copy-ready CI step into `harness-ci.yml` with
`fetch-depth: 0`, fix every doc that violates the rule today, and prove it with a
seeded violation. Until that lands the guardrail runs only in the test suites,
and a reviewer citing D37 is what stops an append.

## Commands

    # the check, against a diff you already have
    PR_TITLE='feat: x' DOC_MONOLITH_DIFF=/tmp/pr.diff guardrails/doc-monolith-edit/check.sh

    # the suites that pin the region math and the collation
    HARNESS_TEST_SANDBOX=1 bash tests/guardrail-doc-monolith.bh-476-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/render-doc-index.bh-476-test.sh
