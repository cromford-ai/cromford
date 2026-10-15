# 2026-10-13 — BH-5373: the impact map's two fixes (the culprit flip waits)

Doc: MERGIFY, MERGE-CONDUCTOR

## What shipped

BH-4980 (`docs/notes/2026-10-07-BH-4980-eject-culprit.md`) shipped the impact
map with two switches off. This change ships the two defects that made the map
useless, and it leaves both switches off:

| switch | where | value |
|---|---|---|
| `MC_BATCH_IMPACT` | lane knob, `catalog/lanes.d/merge-conductor.json` | `1` shadow (log only), unchanged |
| `batch_failure_attempts` | `config/mergify/repos/cromford.conf` | unset: Mergify still bisects a red batch on the default queue |

The first build of this PR flipped both. the operator's replay (#5373 comment
6167883368) and the lead review of 2026-10-14 13:54Z held the flip back. The
enforce flip waits for #6688.

## The two fixes

1. `bin/lib/flaky.sh` `_flaky_strip_gh_prefix`. The log GitHub serves spells
   the colour escape as the two characters `^[`, not the escape byte, and it
   echoes each step's `run:` script in that colour. The comment
   `# A failed install must FAIL the job` in `harness-ci.yml` then parsed as a
   failing test. The strip now removes both spellings and drops the script echo
   lines.
2. `bin/lib/mc-batch-impact.sh` `bim_candidates`. `test-impact.sh select`
   skips a changed `tests/` path, so a PR that ADDS the failing suite reached
   nothing. A member now reaches a suite its own file list holds.

## Replay result (16 red drafts, in-draft heads, comment 6167883368)

| result | main `723c80ba3` | this branch `b5902412d` |
|---|---|---|
| units readable | 0 | 10 |
| script echo read as a test (fix 1) | 11 | 0 |
| decision `eject` | 0 | 0 |
| decision `bisect several` | 0 | 10 |
| decision `bisect unknown` | 16 | 6 |

- Fix 2 adds #6515, the PR the conductor ejected for draft #6555, to that
  draft's candidate set.
- On all 7 decided drafts that had an ejected member, the ejected PR is inside
  the candidate set. The map named exactly one PR on 0 of 16 drafts.
- The `full` reach fires for 17 of 20 members (a changed `catalog/lanes.d/*`,
  `catalog/*.tsv`, `.github/workflows/harness-ci.yml`,
  `bin/run-tests-in-docker.sh` or `tests/lib/*` path). That is why the map does
  not eject on this traffic.

## Why the flip waits

With `batch_max_failure_resolution_attempts: 0`, an `unknown` answer (6 of 16
drafts: 4 log-unreadable, 2 non-suite names) leaves no culprit finder. Every
member, culprit included, is re-queued as a bystander. With bisect on, Mergify's
bisect names the culprit, and that PR keeps the culprit path
(`tests/queue-culprit-flip.bh-5373-test.sh` U1-U2). The shadow eject proof the
ticket asks for is NOT MET.

## The later flip (no deploy)

1. Set the settings row `lane.merge-conductor.cromford.mc_batch_impact=2`
   (test K2).
2. Add `batch_failure_attempts=0` to the conf and re-render `.mergify.yml`.

Do step 1 only after the shadow log shows `BATCH_IMPACT_EJECT` lines that name
the same PR as Mergify, and after #6688 lowers the `full` reach rate.

## What to watch now

The shadow lines in `logs/merge-conductor.log` on the hub, on the first red
batch after the merge:

    grep -h 'BATCH_IMPACT_' /root/harness/logs/merge-conductor.log | tail -20

Before this change every line was `unknown`. After it, a red draft with
readable units logs `eject`, `several` or `none` with `mode=1`.

## Not flipped: parallel lanes

`queue_mode` stays `serial`. The flip needs `MERGIFY_CI_KEY` on the hub and a
live 2xx scopes PUT (`docs/MERGIFY.md` section 6). On 2026-10-14 the hub had no
value for the key.

## Tests

`tests/queue-culprit-flip.bh-5373-test.sh`: T1 (the catalog default is shadow
and decides as mode 0), T1e (enforce by env ejects the one PR), T2 and N1-N5
(enforce negatives), K1-K2 (env and settings-row switches), T3 (bisect stays
on), U1-U2 (an `unknown` answer keeps Mergify's culprit), E1-E3 (the script
echo is not a test), A1 (a member that adds the failing suite reaches it).
