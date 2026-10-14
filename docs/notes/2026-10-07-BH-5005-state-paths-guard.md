# New scripts may not write row-backed state paths (BH-5005, wave 6 of #4951)

Doc: DB-COORDINATION-SPEC

## What changed

`bin/state-paths-guard.sh [<base-ref>]` runs on every pull request in the
`lint` job (step "new scripts do not write row-backed state paths"). It reads
the files the PR ADDS (`git diff --name-only --diff-filter=A <base>...HEAD`)
and fails when one of them writes a `state/<path>` that
`catalog/state-paths.json` classifies as `rows`.

| rc | meaning |
|---|---|
| 0 | clean, printed with how many new scripts were checked; or skipped through the escape hatch |
| 1 | a new script writes a rows path; each hit is printed as `<file>:<line>: writes state/<p> (class rows, authority: ...)` |
| 2 | could not check: the catalog is missing, not JSON, has an empty or invalid path, an unknown class or a duplicate path, or the git diff failed |

A file counts as a script when it is under `bin/`, `scripts/` or `cron/`, or
ends in `.sh .bash .py .js .mjs .cjs`. Files under `tests/`, `test/`, `docs/`,
`catalog/`, `guardrails/*/fixtures/` and any `*.md` never count.

A line is a hit when it is not a `#` or `//` comment, names `state/<p>` with
the next character outside `[A-Za-z0-9_.-]` (so `state/pool` does not match
`state/pool-stats` or `state/pool.lock`), and has one of: a stdout redirect
`>`/`>>` (not `2>`, `&>`, `>&2`, `=>`), a write verb (`tee touch mkdir mv cp ln
install rm truncate rsync`, `sed -i`), a file-write call (`open(..., "w"/"a"/"x")`,
`makedirs`, `write_text`, `write_bytes`, `writeFile*`, `appendFile*`), or a
shell assignment whose value names the path. The assignment arm also fires on a
variable that is only read; a new script reading the shadow file instead of the
row is the same regression.

Not checked: existing scripts, modified or renamed. The shadow writers waves
1-5 left in place keep working.

## The catalog

`catalog/state-paths.json` is `{"version":1,"paths":[{"path","class","authority","note"}]}`.
`path` is the name directly under `state/`. `class` is `rows`, `cache` or
`box-local`. `authority` is printed in the failure line and is not checked
against the schema. A path the catalog does not list passes.

To reclassify a path (it really is a local cache, or belongs to one box), edit
its `class` in the same PR that adds the script.

## Escape hatch

The shared one in `guardrails/lib/escape-hatch.sh`: the `skip-guardrail` label
AND a `Guardrail-Justification: <reason>` line in the PR body. The label alone
does not skip.

## Not in this change

The ticket's other two bullets, stop writing the shadow files and delete the
dead fallback paths, did not ship. They wait for a full week of every path on
rows with no fallback log lines, which cannot have happened yet: #5001 merged
on 2026-10-07 and #5003/#5004 are still open. #5005 stays open for them.
