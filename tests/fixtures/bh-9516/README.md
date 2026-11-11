# tests/fixtures/bh-9516

Fixtures for `tests/main-red-queue-attr-red-line.bh-9516-test.sh` (BH-9516).

PROVENANCE. These files are RECONSTRUCTED, not raw `gh` bytes. The build box
had no GitHub egress, so `gh run view --log-failed` and `gh api
…/pulls/<n>/files` could not run. The planning session read the real runs on
2026-11-11 and recorded their failure lines. Each `RED: <path> has …` text up
to the base sha, and each `--- tests/no-state-files.bh-4159-test.sh rc=1`
line, is copied verbatim from that record. The ` — <hint>` tail of each `RED:`
line is the suite's `$FIX` text, as `delta_check` prints it. The context
lines, the timestamps and the job/step prefix follow the S1 output of
tests/no-state-files.bh-4159-test.sh and the `gh` log shape of
tests/fixtures/bh-3886/attr/.

| file | real source |
|---|---|
| log-42986242197.txt | batch #9508 (also run 42990892795, 42991554158) |
| log-42983086513.txt | batch #9509 |
| log-42977073139.txt | batch #8761 + #9487 |
| files-9508.txt, files-9509.txt, files-9487.txt | the failing file(s) each PR changes, as the plan recorded |
| files-8761.txt | a stand-in: the plan recorded only that #8761 does not change bin/lib/gh-cache.sh |

The PR file lists are reduced to the files that matter for attribution. A
refresh from the real runs replaces each file whole.
