# Three count pins become invariants, and the jobs-client map becomes fragments

Doc: OPERATOR-SETUP

## What changed

- `tests/jobs-client-modules.bh-1194-test.sh`: the ownership map was one
  heredoc with ONE LINE PER MODULE, so every PR that added a queue verb edited
  the same line as every other (19 commits, 2026-09-21 to 09-24, and four
  re-pins of "owns each of the N functions" in the header). The rows are now
  `tests/jobs-client-modules.d/*.tsv`, `module<TAB>function` per line: the base
  in `00-base.tsv`, one `NN-<TICKET-KEY>.tsv` (NN 10-99) per later change. The suite
  assembles them back into the same one-line-per-module map (module order =
  first appearance, which must still equal the shim's literal `JC_MODULES`), so
  every assertion runs unchanged; a malformed row is a new finding.
- `tests/agent-call-knobs.bh-1636-test.sh` K1: `.knobs|length = 17` is gone.
  It was re-pinned by three PRs in four days, and two sibling PRs that each add
  a knob both write the same N+1, merge clean, and are red together. It now
  asserts what the count stood for: knob envs are unique, every REGISTERED knob
  (not just the named ones) has exactly one `${VAR:-literal}` in
  `bin/agent-call.sh` equal to its registry default, and every named knob is
  still registered.
- `tests/conductor-limited-read.bh-784-test.sh` section 10: "marked files: 10"
  is computed from the list of files the section itself scans (re-pinned
  6 → 11 → 10), with a floor of ten.

## Adding a jobs-client function or an agent-call knob

Write `tests/jobs-client-modules.d/10-BH-1234.tsv` with `module<TAB>function`
rows (a stray, symlinked or unprefixed file, or a second `00-` file, is
refused). For a new agent-call knob, write `tests/agent-call-knobs.d/BH-1234.txt`
naming its env. Never edit either `00-base` file.
