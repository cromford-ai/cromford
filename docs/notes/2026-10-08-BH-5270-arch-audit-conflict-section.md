# The architecture audit gains a conflict section

Doc: ARCH-AUDIT

## What changed

`bin/conflict-hotspots.sh` (BH-4986) says which files collide. BH-5270 (wave 4
of #5248) adds `bin/arch-conflict-scan.sh`, which says why, from the shape of
each file at a ref, and proposes one structural fix per file:

| finding | rule (defaults, all flags) | proposed fix |
|---|---|---|
| generated-committed | declared in the repo's generated table without a `committed` cell, or `@generated` / `do not edit` / `auto-generated` in the first 5 lines | generation |
| derived-index | an append registry whose content names >= 5 tracked files | generation |
| append-registry | >= 10 commits that only added lines, >= 80% of its commits | fragments |
| giant-file | >= 1000 lines | module-map |

It reads the hotspot TSV by column name (`--hotspots`), sorts findings by
measured conflicts, lists measured hotspots it cannot explain without
proposing anything for them, and prints a `## Conflict shape` markdown section
(or `--tsv`). Binaries, lockfiles and `--exclude` globs are never findings. It
reads local git only and writes nothing under the repo.

The audit brief (`prompts/arch-audit.md`) gains discovery question 6 and
required output 3: paste the section into `AGENT_ARCHITECTURE.md` as printed,
list its proposed tickets in the PR body, never file or apply them. The
template gains a `## Conflict shape` section; the ticket body names it as a
deliverable and puts filing the proposals out of scope.

## Command

```bash
bin/conflict-hotspots.sh -C <repo> --ref origin/main > hotspots.tsv
bin/arch-conflict-scan.sh -C <repo> --hotspots hotspots.tsv
```

## Not done here

Re-auditing existing projects is an operator act once a week of hotspot rows
exists (BH-5267). `bin/load-project.sh --arch-ticket` dedupes on the exact
title, so a re-run is a hand-filed ticket with a new title.
