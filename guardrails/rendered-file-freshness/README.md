# Guardrail: rendered-file freshness

**Principle:** a file that is *rendered* from fragments is edited through its
fragments, in the same diff. A hand edit to the rendered file survives until the
next render and then disappears without a trace, and until then the repo holds
two spellings of the same thing — the one in the diff is the one that loses.

**What it catches:** a PR that changes a rendered registry file (`cron/*.cron`,
`env-templates/global.env.example`, `rules/CLAUDE.md`, `docs/PR-OWNERSHIP.md` in this repo) and none of
that file's inputs. Deleting a rendered file with no input change counts too.

**Tool:** shell (`check.sh`). The rendered paths, their input dirs and their
render commands are **one spelling**, owned by `bin/lib/render-fragments.sh`'s
`rf_registry()`. The default map in `check.sh` lives between
`# >>> rff default map` / `# <<< rff default map`, and
`tests/guardrails-test.sh` extracts that block and diffs it against
`rf_registry` — the pack cannot invent a fourth spelling of the registry.

```bash
guardrails/rendered-file-freshness/check.sh origin/main            # CI form
RFF_FILES=list.txt guardrails/rendered-file-freshness/check.sh     # testable form
```

**Configuration (env):**

| var | default | what |
|---|---|---|
| `RFF_MAP` | the four `rf_registry` rows | rows `<rendered glob>\|<input paths>\|<renderer command>`, newline separated; blank lines and `#` comments skipped |
| `RFF_MAP_FILE` | — | a file of the same rows — a target repo's own registry. Wins over `RFF_MAP`, which wins over the default |
| `RFF_FILES` | — | a file holding the changed-file list; set it and no git call is made |
| `RFF_ROOT` | `.` | the checkout adoption is judged in |

**The renderer script counts as an input of its row.** A rendered file may
legitimately change because a fragment changed, because a listed input changed,
*or* because the renderer itself changed — so `bin/render-rules.sh` in a diff
licenses a `rules/CLAUDE.md` change. Only the first word of the command field is
read as a path; flags never appear in a diff.

**Honest no-ops, each printed rather than silent, all rc 0:** no rendered file in
the diff, no row adopted, a row skipped as not adopted, `RFF_FILES` or
`RFF_MAP_FILE` unreadable, the base ref could not be diffed, a row with fewer
than three fields. A check that cannot run must never look like a check that
passed — and the strong side of this is each renderer's own `--check`, which
this pack does not replace.

**Adoption reads the CHECKOUT, and is per row.** A row whose first input path
does not exist under `RFF_ROOT` is reported not adopted and skipped; the other
rows are still checked. Reading adoption off the diff instead would mean a PR
that deletes the fragment dir reports "not adopted" and passes — the exact PR
this exists to stop. A row whose first input is a file rather than a directory
(only reachable through `RFF_MAP_FILE`) is tested with `-e` on that path.

**Glob note:** the rendered field is a shell `case` pattern, so `cron/*.cron`
also matches `cron/x/y.cron` — `*` crosses `/`. That is the same behaviour as
the sibling pack's route globs and is deliberate: a nested rendered file is
still a rendered file.

**Applicability:** cromford today, where the four rows above are rendered
by `bin/render-crontab.sh --from-fragments`, `bin/render-env-example.sh`,
`bin/render-rules.sh` and `bin/render-doc-sections.sh` as those land. On this checkout the fragment dirs do not
exist yet, so every row reports not adopted and the step is green — the pack
turns itself on, row by row, as each renderer merges. Any other repo whose
committed files are generated from fragments adopts it by pointing
`RFF_MAP_FILE` at its own rows (see `fixtures/map.txt` for the shape).

**Escape hatch:** the `skip-guardrail` label **and** a
`Guardrail-Justification: <at least 20 characters>` line in the PR body (see
`../README.md`). The label alone fails loudly. On a Mergify batch draft the
hatch reads each source PR and exempts only the rendered files a hatched source
PR changed (the four `GUARDRAIL_*`/`GH_TOKEN` env lines below; see
`../README.md`, "On a Mergify batch draft").

**CI form** — extract the marker line, never wire the raw PR body (a bare body
would make any PR a justification, which is the shape the catalog refuses):

```yaml
      - name: rendered files are edited through their fragments
        if: github.event_name == 'pull_request'
        env:
          PR_LABELS: ${{ join(github.event.pull_request.labels.*.name, ',') }}
          PR_BODY: ${{ github.event.pull_request.body }}
          GUARDRAIL_HEAD_REF: ${{ github.head_ref }}
          GUARDRAIL_PR_AUTHOR: ${{ github.event.pull_request.user.login }}
          GUARDRAIL_DRAFT_BODY: ${{ github.event.pull_request.body }}
          GH_TOKEN: ${{ github.token }}
        run: |
          GUARDRAIL_JUSTIFICATION=$(printf '%s\n' "$PR_BODY" | grep -i '^guardrail-justification:' || true)
          export GUARDRAIL_JUSTIFICATION
          guardrails/rendered-file-freshness/check.sh "origin/${{ github.base_ref }}"
```

The checkout needs `fetch-depth: 0` — `origin/main...HEAD` has no merge base on
a shallow clone.
