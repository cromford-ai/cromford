# Archie's soul is section files (BH-5244, BH-5235.0)

Doc: OPERATOR-SETUP

## What changed

`prompts/archie-soul.md` is gone. Its 75 lines now live, byte for byte, in
eight files under `prompts/archie-soul.d/`:

| file | lines of the old file |
|---|---|
| `00-identity.md` | 1-14 |
| `10-authority.md` | 15-27 |
| `20-initiatives.md` | 28-33 |
| `30-follow-ups.md` | 34-38 |
| `40-earned-autonomy.md` | 39-45 |
| `50-memory.md` | 46-59 |
| `60-corrections.md` | 60-69 |
| `70-skill-proposals.md` | 70-75 |

Every reader loads them with `cat "$H"/prompts/archie-soul.d/*.md`:
`bin/archie.sh` (the check prompt), `bin/archie-research.sh` (both prompts),
and `bin/orchestrate.sh` (`compose_v2_prompt` and `run_survival`). The concat
has the old file's sha256 (`dbca3d33…294530`), so every composed prompt is
byte-identical. The `=== WHO YOU ARE (prompts/archie-soul.md) ===` label in
`compose_v2_prompt` is unchanged on purpose.

## Why

Two tickets that each touched the soul edited the same file, and often the
same lines. Now a new soul section is a new `NN-<slug>.md`, so it never
conflicts with a sibling. Keep the prefixes two digits and distinct; glob order
is the prompt order.

## Rules

- No `shopt -s nullglob` in a reader. With no match, `cat` with no arguments
  reads stdin. Without it, a missing directory makes `cat` fail quietly and the
  soul is dropped, which is what a missing file did before.
- Every fragment ends in a newline. `tests/prompt-sections.bh-5235-test.sh`
  pins the names, the order, the trailing newline and the concat sha.

## Deploy

`bin/harness-sync.sh` rsyncs `prompts/` without `--delete`, so the old
`/root/harness/prompts/archie-soul.md` stays on the hub. Nothing reads it.
