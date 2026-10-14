# findings-log stops logging review scaffolding as findings

Doc: FINDINGS-LOG

## What was wrong

`bin/findings-log.sh` logged any bullet, numbered item or `##` sub-header of 30+
characters as a finding. The review format's own scaffolding passes that test
on every build, so it recurred like a real finding. In the 2026-08-26 bootstrap,
four of the top five families were boilerplate: `Validation trace (plan tasks vs
validate.txt)`, `` `npx tsc --noEmit` — clean ``, `` `semgrep.txt` does not exist
— nothing to triage `` and `Findings (all minor, none blocking)`. The real #1
family, unsafe trust of client-supplied ids, ranked below them.

## What it does now

`is_scaffold()` in the harvester's python drops two shapes. Everything else is
logged as before.

1. **Section opener.** Once emphasis and a trailing `:` are stripped, the text is
   one of a closed set of labels, optionally followed by a parenthetical:
   `validation trace`, `requirements coverage [vs (the) ticket]`,
   `system invariants`, `findings`, `blocking findings`,
   `non-blocking findings|notes`, `verdict`, `summary`, `test honesty`,
   `mechanical gates`, `tool status`. Only a `Validation trace` heading or fully
   bold line can also carry `— text`, `– text`, `- text` or `: text` after the
   label, because that heading is structural by position and the bootstrap
   counted its variants. Every other label has to match exactly, so
   "## Summary — the PATCH route never re-checks org ownership" and the bullet
   "Findings from the refuter are still unaddressed" are both kept.
2. **Tool-clean status line.** One backticked tool name, then one of these:
   - `clean`, `green`, `pass(es|ed)`, `ok` or `exit(s|ed) 0`, followed by
     nothing or only a no-new-information tail like `, zero errors on HEAD` or
     `, 0 warnings`. The tail is a closed grammar, not a free-text allowance with
     a disqualifier list: "`tsc` ok, the new route leaks every org's clients" and
     "`validate.txt` exit 0 while harness-suite.txt says HARNESS_EXIT: 1" are
     findings, and they are kept.
   - `empty`, `does not exist` or `not present`, but only when the line ends in
     `nothing to triage`. "`validate.txt` is empty" on its own is a blocking
     finding under the review prompt, so it is kept.

**Keep-override.** A line that cites a D-rule, carries a known `FRAUD:` class, or
has an uppercase `BLOCK`/`BLOCKING` is never dropped, whatever its shape.
Lowercase "none blocking" doesn't count. There's no positive filter because the
review prompt (`bin/lib/rb/review.sh`, REVIEW/SECURITY/REFUTE) doesn't require a
severity tag or numbering on each finding. Any error inside the filter keeps the
line.

The label list is a closed code constant, like `FRAUD_CLASSES`. An editable
deny-list would be a way to mute findings silently.

## Existing rows: left to age out

The harvester stays append-only and never rewrites rows that are already in
`logs/findings.log`. Old scaffold rows age out:

- The bootstrap rows are stamped 2026-08-26, so they leave rule-miner source
  (e)'s 30-day window on 2026-09-25. `bin/repeat-family.sh` reads 14 days.
- Rewriting the file wouldn't stick. The rows are mirrored to the coordination
  DB (`findings_put`, BH-436), and `log_rehydrate` refills a wiped file from
  that mirror. Cleaning them for real would take a coord-DB delete, and nobody
  authorized that.

`tests/findings-log-scaffold.bh-123-test.sh` pins this: a pre-seeded
bootstrap-shaped scaffold row survives a harvest byte for byte as line 1.
