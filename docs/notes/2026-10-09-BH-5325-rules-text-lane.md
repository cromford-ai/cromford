# The risk tier signs off rules-text-only PRs (BH-5325)

Doc: MERGE-CONDUCTOR

## What changed

`bin/lib/risk-tier.sh` has a new rule 2b, the rules-text lane. A PR head is
low when all of these are true:

- Every changed path, and each rename's `previous_filename`, is
  `rules/CLAUDE.md` or `rules/topics/<name>.md` (one directory level).
- `rules/CLAUDE.md` is in the diff.
- `bin/render-rules.sh --check` passed on the head. The hub runs this check
  itself (`rrh_check` in the new `bin/lib/rules-render-head.sh`).
- Additions plus deletions are less than `risk_tier.rules_low_lines`.
- `rules/topics/01-iron-guardrails.md` has 0 deletions, and the diff does not
  remove it or rename it away.

The low reason starts with `rules-text:`. A rules diff that fails one of these
conditions goes on to rules 3 and 4. That gives medium, or high when the diff
is over `high_lines` or `high_files`. `rules/settings.json` is a lead protected
path, so it is always high. `rules/RTK.md` is not rules text, so it is never low.

`rrh_check <git-dir> <head> <renderer>` fetches the head into the hub's clone
with `--no-write-fetch-head`. It writes no ref and no FETCH_HEAD. It extracts
`rules/` from the head with `git archive` into a scratch dir and runs the hub's
own renderer with `--root <scratch> --check`. It never runs the head's own
scripts. It prints `ok`, `drift` or `unread`, then a tab and the detail. Only
`ok` can give low. Each git and render call has a timeout.

`bin/lead-review-enqueue.sh`:

- runs `rrh_check` only when `rt_rules_shape` says the compare is rules text.
- classifies a lead-authored PR. Only a low rules-text answer goes on. Any
  other answer posts no `/api/risk-tiers` row, writes one `lead` line in
  `risk.tsv`, and requests the lead review as before (`risk_lead`). The
  `lead` line stops later ticks from reading the compare again.
- signs a rules-text low with `--reviewer risk-tier:rules-text:<box>`. The
  note is `low risk: rules-text: ...`.
- does not apply the BH-5630 "no reviewer approved this head" refusal to a
  lead-authored rules-text low. The lead wrote it, and green CI and the hub's
  render check are its proof. Every other low keeps the refusal, a non-lead
  rules-text head included: no human and no reviewer read that diff.

`to_lead_merge_hold` (`bin/lib/ticket-ownership.sh`) clears a lead PR on a
standing risk-tier MERGE row only when the row's reviewer starts with
`risk-tier:rules-text:`. Every other risk-tier row still holds a lead PR.

## Settings

- `risk_tier.rules_low_lines` (int). Code fallback 80. A value over 300 is
  capped at 300 (`RT_LOW_LINES_MAX`). The row is in `RT_RULES_SIG`, so a change
  reclassifies every cached head.
- **Off switch:** set `risk_tier.rules_low_lines` to `0`. Then no rules diff is
  low.

## Warning: enforce is already on

`worker/jobs/schema.sql` seeds `risk_tier.mode.example-org.cromford =
enforce`. So this lane signs rules-text heads on the first hub tick after
deploy. This change does not touch the mode row.

## Limits

- With `LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1`, a head with no builder APPROVE
  never gets to the risk block. So a Mac-session rules PR is not signed under
  that setting.
- `bin/inbuild-lead-review.sh` calls `rt_classify` with no render result. There,
  a rules diff is medium. It never signs.
- No hub clone, a failed fetch or a renderer timeout gives `unread`. The head
  is then medium, cached under the same rules sig. A new push reclassifies it.

## Test

`tests/risk-tier-rules-lane.bh-5325-test.sh`.
