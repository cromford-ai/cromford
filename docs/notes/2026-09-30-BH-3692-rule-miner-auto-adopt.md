# Rule-miner auto-adopt: the evidence contract and the rule-recur stub (BH-3713, BH-3692.0)

Doc: TRUST-PROGRAM

## What changed

This PR lands the contract only. The three sibling slices of BH-3692 add the
behaviour on top of it.

- `bin/lib/rule-evidence.sh` (new, sourced). It sets `RE_DIR`
  (`prompts/rule-evidence`) and `RE_LINT_HEAD_RE`
  (`^rules/mined-[0-9]{8}-lint$`), and defines `re_write` and `re_field`. The
  JSON schema of a rule's evidence file is documented in the lib's header, and
  that header is the contract.
- `bin/rule-recur.sh` (new stub). Its signature is final:
  `rule-recur.sh <findings.log> <evidence-dir>`. Today it prints
  `rule-recur: measure not built yet` and exits 0.
- `bin/rule-miner.sh` calls `rule-recur.sh` once per run, after the findings
  feed and before the empty-week exit, so a quiet week still measures. Output
  goes to `logs/rule-miner.log`, or to stdout under `RULE_MINER_DRY=1`. A
  failing or missing `rule-recur.sh` never stops the miner.

## Where BH-3692 is going

None of this is built yet. It's the design the contract serves.

- **Two classes.** A mined rule is `lint-backed` when a script can decide it
  (the evidence names the check), or `judgement` when it takes a human. A
  `lint-backed` rule auto-adopts. A `judgement` rule stays a PR for the operator.
- **Two PRs per week.** The lint-backed rules go on `rules/mined-<date>-lint`,
  stacked under the judgement PR `rules/mined-<date>`. `RE_LINT_HEAD_RE` is how
  a lander tells them apart.
- **One evidence file per rule** at `prompts/rule-evidence/D<n>.json`, keyed by
  D-number. The miner writes it, the `rule-adopt` lane validates it, and
  `rule-recur` reads it. `re_write` writes a tmp file and moves it into place,
  so a reader never sees half a record.
- **The `rule-adopt` lane.** A lead review of the lint PR, a lead MERGE
  verdict, then `mc_enqueue` hands it to the merge conductor.
- **The 30-day recurrence warn.** When an adopted rule's family recurs within
  30 days, `rule-recur.sh` raises it through `lane-alert.sh --severity warn`.

## Touches

`bin/rule-miner.sh` (one call), `prompts/rule-evidence/` (the store, empty
until a sibling writes to it). No contract doc is edited.

## BH-3714 (BH-3692.1): classify, split, evidence

- `bin/lib/rule-class.sh` (new, sourced, pure). `rc_class` reads a drafted
  bullet's one `CLASS:` line and prints `lint-backed<TAB><path>` or
  `judgement<TAB><reason>`. A rule is lint-backed only when its path is
  relative, has no `..` and no glob, sits under `bin/`, `tests/`,
  `guardrails/`, `checks/` or `.github/workflows/`, is one exact file tracked
  on main, and appears in the rule's own text, not just on the CLASS line. The
  reasons are listed in the lib header. `rc_evidence` keeps only ids from this
  week's inventory and counts the dropped ones on stderr. `rc_families` maps
  ids to findings.log families. `rc_next` is 1 plus the highest D-number on
  main and on every origin `rules/mined-*` branch.
- `bin/rule-miner.sh`. The drafting prompt asks for `CLASS:` and `EVIDENCE:`
  lines under each bullet, with lint rules numbered first. NEXT counts open
  `rules/mined-*` branches, so two unmerged weeks can't mint the same D-number.
  After the draft validates, each rule is classified. A lint-backed rule whose
  evidence ids are all invented becomes `judgement` with reason `no evidence`.
  Each rule gets `prompts/rule-evidence/D<n>.json` through `re_write`, and the
  bullet loses its tag lines and gains `(Evidence: <ids>; check: <path|none>)`.
- Two PRs. Lint-backed rules go on `rules/mined-<date>-lint`, off main. The
  body says it lands through the lead lane and never says `harness build`.
  Judgement rules go on `rules/mined-<date>`, stacked on the lint branch when
  there is one, and still say the miner never merges. A week with no lint rule
  opens one PR, the same as before.
- seen.txt. Every digest id is marked once every PR that had rules opened. If
  the lint PR opens and the judgement PR fails, only the ids the lint rules
  cite are marked. If the lint PR fails, nothing is marked.
- Verified by `tests/rule-class.bh-3714-test.sh` and
  `tests/rule-miner-adopt.bh-3714-test.sh`. The second one runs the real miner
  against a local bare origin.
