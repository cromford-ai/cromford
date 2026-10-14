# The lead review builds on the builder review of the same head (BH-5355)

Doc: LEAD-REVIEW

## What changed

- `bin/lead-review.sh` reads the builder review of the head it is about to
  review. The builder review is the review `bin/review-prs.sh` posts on GitHub,
  with the footer `_Automated harness review (Fable) of <sha>. ..._`.
- The reader is `br_fetch` in the new `bin/lib/builder-review.sh`. It makes one
  REST read, `repos/<r>/pulls/<n>/reviews?per_page=100`. It uses a review only
  when GitHub's `commit_id` is the head, the footer names the head, and the
  author is a verdict author (`harness_verdict_author_match`). If several
  match, it uses the newest. The verdict comes from the body's final block
  (`verdict_parse`), then from the review state.
- When it finds one, the lead prompt changes in two places:
  1. `prompts/lead-review-builds-on.md` comes right after the checklist. It
     tells the lead to spot-check the builder's claims, then to judge what the
     builder cannot: intent and thread, iron laws, cross-PR risk, verify
     honesty, deferred work. It must still read every part of the diff that
     the builder review did not cover or got wrong.
  2. `## Builder review (same head)` comes right before `## Diff`. It holds
     `verdict:`, `reviewed sha:`, `reviewer:` and the review body as posted.
- The full diff stays in the prompt. The model route (`lead.review`) and the
  verdict rules do not change. The verdict is the lead's own.
- The report header gets `- review mode: builds on builder review <V> at <sha12>`
  only when the prompt carried the section.
- The new prompt is a lead protected path (`catalog/lead-protected-paths.tsv`).

## When the lead does a full review, as before

The prompt is byte-identical to the old prompt in each of these cases. The
lane log says which one, as `<key>: full review (<reason>)`:

- the knob is `off`, or has a value that is not `on|off`;
- no builder review on the head (`no builder review on <sha12>`), including a
  review of an older push, a footer that names another sha, a review by the
  builders App, and the trivial-route advisory read;
- the reviews read failed (`reviews read failed: rc <n>, HTTP <code>`), or it
  returned 100 reviews (`reviews list may be cut at 100`);
- the newest matching review has no readable verdict;
- `bin/lib/builder-review.sh` or `prompts/lead-review-builds-on.md` is missing.

A delta review (BH-5294) never gets the section. Its prior lead report has the
same role.

## The knob

`LEAD_REVIEW_BUILDS_ON_BUILDER`, settings row
`lane.lead-review.lead_review_builds_on_builder`, registered in
`catalog/lanes.d/lead-review.json`. Values: `on` (default) or `off`. The lane
reads it once at the start of each tick, so `off` takes effect on the next tick.

## Reading the cost before and after

Each lead agent call now sets `AGENT_CALL_ROW_NOTE`. `bin/agent-call.sh`
already writes input and output tokens on every row, and it adds this tag to
the row's note:

- `lead-mode=build-on`: the prompt carried the builder review;
- `lead-mode=full`: a full review;
- `lead-mode=delta`: a delta review.

To compare, take the rows of lane `lead-review` and group them by the
`lead-mode=` tag in the note. Compare input and output tokens per row between
`build-on` and `full`. Rows written before this change have no tag.

## Verdict agreement

`tests/lead-builds-on-builder.bh-5355-test.sh` has an opt-in live mode:

    LEAD_BUILDS_ON_EVAL_MODEL=<model> HARNESS_TEST_SANDBOX=1 bash tests/lead-builds-on-builder.bh-5355-test.sh

It sends each fixture case in `tests/fixtures/lead-builds-on.bh-5355/`
through `bin/agent-call.sh` twice, once with the builder review and once with
the knob off. Every case is a known-bad PR. Two of the three builder reviews
APPROVE wrongly. The build-on answer must be BLOCK. The suite prints a
per-case table and `agreement: <n>/<total> build-on vs full`. It costs money,
so CI does not run it.

The live mode needs the harness credentials. Without them `bin/agent-call.sh`
answers "Not logged in" and every verdict reads `unknown`. Source the env
first:

    set -a; . /root/harness/env/global.env; . /root/harness/env/cromford.env; set +a

Live run, 2026-10-11, head a5bc9b60, model alias `opus` (the `lead.review`
route lookup answered rc 75 on the build box), PASS=76 FAIL=0:

    case                   want     builder          build-on   full
    fail-as-success        BLOCK    REQUEST_CHANGES  BLOCK      BLOCK
    test-proves-nothing    BLOCK    APPROVE          BLOCK      BLOCK
    hardcoded-model        BLOCK    APPROVE          BLOCK      BLOCK
    agreement: 3/3 build-on vs full

## Protected paths

`catalog/lead-protected-paths.tsv` lists `prompts/lead-review-builds-on.md`
and `bin/lib/builder-review.sh`. The lib decides which review text enters the
lead prompt and with which verdict. A builder PR that edits either file needs a
human lead verdict.
