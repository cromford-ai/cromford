# config/rb-plan.d/ — the fragments of bin/lib/rb/plan.sh

`bin/lib/rb/plan.sh` (the PLAN-stage lib) is a committed render of this
directory (BH-9704). Its registry row is `catalog/splits.d/bh-9704-rb-plan.tsv`.

- The render is the `NNNN-<slug>.txt` files concatenated verbatim in LC_ALL=C
  name order. This README is not part of it.
- Fragments end in `.txt` on purpose: the share mirror reads only the
  extensions in `TEXT_EXT` (`bin/share/mapping.py`) and refuses any other
  file. Do not rename them to `.sh` or `.part`; `bin/render-split.sh`
  refuses those names.
- Edit a fragment, then run `bin/render-split.sh --write`, and commit both.
  Never edit `bin/lib/rb/plan.sh` by hand: `bin/render-split.sh --check` and
  CI refuse the drift, and the conductor's regenerate refuses to write over it.
- A new block is a new fragment numbered between its neighbours:
  `1350-<slug>.txt` goes between `1300-...` and `1400-...`.
- A fragment must be non-empty and end in a newline. The render must pass
  `bash -n`; one fragment alone need not.

## Re-cut (only when main moved before this split merged)

```bash
rm config/rb-plan.d/*.txt
bin/render-split.sh --cut bin/lib/rb/plan.sh --min-lines 60
bin/render-split.sh --check
```

## Fragments

| fragment | first marker |
|---|---|
| `0100-head.txt` | the file header, then branch artifact (BH-1033) |
| `0200-lane-checkpoints-tests-run-build-checkpo.txt` | lane checkpoints (tests/run-build-checkpoint-test.sh drives this block) |
| `0300-defer-top.txt` | defer top |
| `0400-stage-lane-verdict-bh-1853.txt` | stage lane verdict (BH-1853) |
| `0500-plan-ambiguity-rule.txt` | plan ambiguity rule |
| `0600-reopen-reason-bh-6159.txt` | reopen reason (BH-6159) |
| `0700-untrusted-input-gate-bh-4491.txt` | untrusted input gate (BH-4491) |
| `0800-pr-body-requires-note-bh-7378.txt` | pr-body-requires note (BH-7378) |
| `0900-spec-trace-note-bh-6485.txt` | spec trace note (BH-6485) |
| `1000-preplan-adopt.txt` | preplan adopt |
| `1100-preplan-outcome-event-bh-2543.txt` | preplan outcome event (BH-2543) |
| `1200-ticket-fingerprint.txt` | ticket fingerprint |
| `1300-plan-launch.txt` | plan launch |
| `1400-ticket-fingerprint-write.txt` | ticket fingerprint write |
| `1500-plan-empty-output-verdict.txt` | plan empty-output verdict |
| `1600-cross-repo-read-gate-bh-5910.txt` | cross-repo-read gate (BH-5910) |
| `1700-plan-malformed-terminal.txt` | plan malformed terminal |
| `1800-replan-comment-bh-3955.txt` | replan comment (BH-3955) |
| `1900-size-enforce-switch.txt` | size enforce switch |
| `2000-size-gate.txt` | size gate |
| `2100-live-emit-plan.txt` | live emit plan |
| `2200-split-child-check.txt` | split child check |
| `2300-test-reroute-tests-run-build-test-home-b.txt` | test reroute (tests/run-build-test-home.bh-580-test.sh drives this block) |
| `2400-hotspot-claim.txt` | hotspot claim |
