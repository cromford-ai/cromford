# `guardrails/` — portable checks for the iron laws

## What this is

Our engineering rules live almost entirely in the **soft tier**: prompts,
`CLAUDE.md`, `prompts/build-discipline.md`, review checklists. A model can
forget every one of them. The **strong tier** — a check that runs in the target
repo's CI and goes red — was empty: the harness shipped zero tooling into
project repos.

This catalog is the strong tier. Each subdirectory is one portable check
encoding a law we have until now enforced only by asking a reviewer to notice:

| check | law | tool |
|---|---|---|
| [`hardcoded-model-ids/`](hardcoded-model-ids/) | model selection is DB-driven, resolved per agent at runtime | semgrep |
| [`native-dialogs/`](native-dialogs/) | never `window.confirm/alert/prompt` in app code | semgrep |
| [`metered-vendor-choke/`](metered-vendor-choke/) | metered vendors are called only through the ledger-guarded client | semgrep |
| [`rls-on-create-table/`](rls-on-create-table/) | every migration that CREATEs a table enables RLS | shell |
| [`verification-map-freshness/`](verification-map-freshness/) | a PR that changes routes updates `docs/verification-map/` | shell |
| [`doc-monolith-edit/`](doc-monolith-edit/) | what changed goes in a dated note, not appended to a contract doc | shell |
| [`rendered-file-freshness/`](rendered-file-freshness/) | a PR that edits a rendered registry file edits its fragments in the same diff | shell |

Each subdir carries the rule/script, a short doc, an **applicability note**
(which repos it fits and what must exist before adopting it), and
`fixtures/` — a seeded violation and a clean file.

**Every check is proven on every CI run** by `tests/guardrails-test.sh`: it must
FIRE on its seeded violation and stay silent on its clean fixture. A rule that
matches nothing looks exactly like a repo with nothing to find, so "it ran and
was quiet" is not evidence of anything on its own.

## How a pack gets applied to a project

Not by the harness copying files in. By a normal `ai-build` ticket on that
project's board:

> **adopt guardrail pack: `<check>`, `<check>`**

The harness then builds its own guardrails through its own pipeline — planned,
executed, adversarially reviewed, PR'd, merged like any other change. That is
deliberate: a check that arrives outside the pipeline has never been reviewed
against the repo it is about to start failing, and the first thing it does is
turn someone's CI red.

The adoption PR does four things, and the ticket's acceptance tests should name
all four:

1. copies the check into the repo (convention: `.guardrails/<check>/`),
2. wires it into CI as its own step, with the escape hatch honored,
3. **fixes or excludes every existing violation** — a check that lands red is a
   check that gets disabled by Friday,
4. proves it fires: a seeded-violation commit shown failing CI, then reverted.

`guardrails/PILOT-TICKET.md` is the drafted body for the first one
(project-2). Later checks arrive the same way, including the ones the rule
miner drafts automatically (see below).

## The escape hatch

Every check can be skipped. Skipping costs a label **and** a written reason:

- PR label `skip-guardrail`, **and**
- a line in the PR body reading
  `Guardrail-Justification: <at least 20 characters of actual reason>`,
  which stays in the PR record where a reviewer sees it.

**The label alone does not skip anything** — it fails loudly instead. "I said
skip" is not a reason, and a label-only hatch makes the label the whole gate.

**Two things the hatch deliberately refuses**, both found in review:

- **Whitespace.** An earlier version counted characters, so twenty-five spaces
  disabled a security check. The marker payload is stripped before measuring.
- **The whole PR body.** The natural CI wiring is
  `GUARDRAIL_JUSTIFICATION: ${{ github.event.pull_request.body }}` — which makes
  *any* body a justification, and it is the line every drafted check copies. A
  bare blob is not accepted: the text must carry the explicit
  `Guardrail-Justification:` marker, which someone has to type on purpose.
  `bin/guardrail-promote.sh` refuses to open a PR for a drafted step that wires
  the raw body at all.

Shell checks get this from `lib/escape-hatch.sh` (sourced). Semgrep steps get it
by wrapping the step in the same condition — see any check's README for the CI
form.

### On a Mergify batch draft (BH-9965)

Mergify tests a batch on its own draft PR (`mergify/merge-queue/*`), and that
draft carries neither the source PRs' labels nor their bodies. So on a batch
draft the hatch reads each **source** PR instead (`lib/batch-hatch.sh`):

- The run is a batch draft only when `GUARDRAIL_HEAD_REF` starts with
  `mergify/merge-queue/` **and** `GUARDRAIL_PR_AUTHOR` is exactly
  `mergify[bot]`. A hand-pushed branch with that name is an ordinary PR.
- The source PR numbers come from the draft body's `Metadata for CI tooling`
  block (`pull_requests:` / `- number: <n>`; sample in
  `lib/fixtures/mergify-draft-body.md`). The draft's own label is ignored.
- Each source PR is judged by the ordinary rule: label **and** a
  `Guardrail-Justification:` line in that PR's body. A label with no usable
  line prints the usual refusal under `batch source PR #<n>:`.
- **The check still runs.** It drops only the files that hatched source PRs
  changed and no other PR in the batch changed. A hatch on one PR never skips
  the check for another PR's files.
- Anything it cannot read (no metadata block, an API error, no
  `GITHUB_REPOSITORY`, an incomplete file list of a non-hatched PR) prints
  `could not read source PR(s) (<why>); no file is exempt.` and the check runs
  on every file.

Add these four lines to each guardrail step's `env:`. With them unset the hatch
is byte for byte as before. `GUARDRAIL_DRAFT_BODY` is parsed only for PR
numbers and is never a justification.

```yaml
          GUARDRAIL_HEAD_REF: ${{ github.head_ref }}
          GUARDRAIL_PR_AUTHOR: ${{ github.event.pull_request.user.login }}
          GUARDRAIL_DRAFT_BODY: ${{ github.event.pull_request.body }}
          GH_TOKEN: ${{ github.token }}
```

A semgrep step adds the exempt files as `--exclude` flags and scans from the
repo root (`.`): semgrep anchors a path exclude at the scan root, so
`--exclude=src/a.ts` with a target of `src` excludes nothing.

```yaml
        run: |
          . guardrails/lib/escape-hatch.sh
          JUST=$(printf '%s\n' "$PR_BODY" | grep -i -m1 '^[[:space:]]*Guardrail-Justification:' || true)
          GUARDRAIL_JUSTIFICATION="$JUST" guardrail_escape_hatch <check> && exit 0
          mapfile -t EX < <(guardrail_semgrep_excludes)
          semgrep scan --config guardrails/<check>/rule.yml --error "${EX[@]}" .
```

A guardrail with no way out gets deleted the first time it is wrong. A guardrail
with a silent way out is decoration. This is the middle.

## Where new checks come from

`bin/rule-miner.sh` reads `logs/findings.log` (written by `bin/findings-log.sh`
after every review lens) and builds a 30-day frequency table by root-cause
family. A family recurring `PROMOTE_MIN` times or more is, by definition, a
review comment we keep writing — which is a bug in the guardrails, not in that
week's build.

The miner then classifies each recurring family against the **objectivity
test**: a promotable rule needs a *measurable observation*, a *named tool*, and
an *explicit threshold*. Fail it and the lesson stays prose in
`prompts/build-discipline.md` (the existing lane, unchanged). Pass it and the
miner drafts the concrete check and opens a **second PR on the target repo**.
It never merges either one.
