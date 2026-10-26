#!/bin/bash
# tests/run-build-rollout-hook.bh-985-test.sh — the rollout dispatch hook in
# bin/run-build.sh: a ticket whose BODY carries a `## Rollout` section files its
# waves and never buys a model call, and every absence falls back to the
# ordinary PLAN path.
#
# WHY IT EXISTS (BH-985, child .4 of #816). A rollout master is a ticket whose
# author already wrote the waves. Planning it is a model call for work that is
# already decided, and letting the size gate see it is a split of a thing that
# is already split. So the hook runs early, on the ticket meta the build already
# fetched, and it is the ONE place that decides. The cost of getting it wrong is
# asymmetric: a false positive files issues on a real repo under our App
# identity with no plan stage in between, which is why every uncertain shape
# here must fall through to the plan.
#
# WHAT THIS SUITE PINS:
#   A — `TICKET_META()` also selects the body, on BOTH lanes, in the SAME call
#       it already made (issues: `--json title,labels,body`; board:
#       `.description // .body`). No extra API call buys the hook.
#   B — the `# >>> rollout hook` block dispatches: the lane script is run with
#       this build's own arguments, the RESULT is the lane's own line, the build
#       exits 0, and neither the PLAN stage nor the size gate is reached.
#   C — the negatives: child-pattern titles, fenced and quoted headings, issue
#       #816's own body, and every absence (no meta, no body key, empty body, no
#       lane script, a non-executable one, a detector that crashed).
#   C' — failure shapes: a FAILED line, no line at all, a FILED line from a
#       run that exited non-zero (which is FAILED, never done), and a reason
#       carrying a double quote (which must survive the parser intact).
#   D — structure: the block sits after `# <<< ticket meta` and before the
#       pre-plan adoption, the PLAN launch, the kind flow and the size gate; its
#       child regex is byte-identical to the size gate's; it re-implements none
#       of the detector.
#   E — `_job_finish`: `ROLLOUT_FILED*` closes the job row `done`,
#       `ROLLOUT_FAILED` never does.
#   F — the seven prompt files carry the result-sweep rule.
#   G — the two statements the ticket routed to the PR BODY (the read-only
#       decompose-parent-close confirmation, the owed post-merge proof) survive
#       the render: the production assumptions-section block, run against the
#       spec this PR ships, emits them inside its 1500-byte lift.
#
# HOW IT DRIVES: the block, `TICKET_META` and `_job_finish` are EXTRACTED
# VERBATIM from the flattened pipeline (tests/lib/rb-all.sh) and executed, with
# the real `RESULT()` alongside them. `bin/run-rollout.sh` is a stub whose
# `--is-rollout` sources the REAL bin/lib/file-children.sh and runs the REAL
# `fc_has_rollout`, so the classifier under test is the shipped one. A sentinel
# after the block stands in for the plan path (`agent-call.sh`, `size-gate.txt`)
# and proves the fall-through actually happened. No network, no clock, no model.
#
# Run from anywhere: bash tests/run-build-rollout-hook.bh-985-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive these blocks"; exit 1; }

# ── the production blocks, lifted verbatim ───────────────────────────────────
marked() { # marked <start> <end> <file>
  awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"
}
HOOK="$T/hook.sh"; METAFN="$T/ticketmeta.sh"; JOBFIN="$T/jobfin.sh"; RESULTFN="$T/resultfn.sh"
marked '# >>> rollout hook' '# <<< rollout hook' "$RB" > "$HOOK"
awk '/^TICKET_META\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$RB" > "$METAFN"
awk '/^_job_finish\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$RB" > "$JOBFIN"
sed -n '/^RESULT() {/,/^}$/p' "$RB" > "$RESULTFN"

# A suite that extracted nothing must FAIL, not pass vacuously: deleting the
# block from bin/run-build.sh is red here, which is the ticket's own ask.
[ -s "$HOOK" ]     && ok || bad "extract: the '# >>> rollout hook' block is missing from bin/run-build.sh"
[ -s "$METAFN" ]   && ok || bad "extract: TICKET_META is missing from bin/run-build.sh"
[ -s "$JOBFIN" ]   && ok || bad "extract: _job_finish is missing from bin/run-build.sh"
[ -s "$RESULTFN" ] && ok || bad "extract: RESULT is missing from bin/run-build.sh"
bash -n "$HOOK" 2>/dev/null && ok || bad "extract: the rollout hook block is not valid bash on its own"

H="$T/h"
mkdir -p "$H/bin" "$H/env" "$T/fakebin"

# fleet-conf.sh: the two lane answers, switched by files the test writes.
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${2:-}" in
  prod)         cat "$HARNESS/fc-prod" 2>/dev/null ;;
  board_prefix) cat "$HARNESS/fc-prefix" 2>/dev/null ;;
  repo)         cat "$HARNESS/fc-repo" 2>/dev/null ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh"
# BH-7919: TICKET_META's GitHub arm now asks bin/lib/tracker.sh trk_gh_issue_number.
scratch_install_closure bin/lib/tracker.sh "$H" >/dev/null || exit 1
printf 'o/r\n' > "$H/fc-repo"

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_REC"
# BH-1649: TICKET_META reads through gh_rest, which wants the `gh api -i` envelope.
case "$*" in *"-i -X "*) printf 'HTTP/2 200\r\n\r\n' ;; esac
cat "$GH_OUT" 2>/dev/null
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_REC"
cat "$CURL_OUT" 2>/dev/null
SH
# The PLAN stage's own entry point. If this is ever touched by a rollout master,
# the hook bought a model call and the whole point of the lane is gone.
cat > "$T/fakebin/agent-call.sh" <<'SH'
#!/bin/bash
touch "$AGENT_MARK"
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl" "$T/fakebin/agent-call.sh"
export PATH="$T/fakebin:$PATH"
GH_REC="$T/gh.rec"; CURL_REC="$T/curl.rec"
GH_OUT="$T/gh.out"; CURL_OUT="$T/curl.out"

# ═══════════════════════════════════════════════════════════════════════════
# Section A — TICKET_META selects the body, on both lanes, in the same call
# ═══════════════════════════════════════════════════════════════════════════
cat > "$T/drive-meta.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
. "$GHLIB"
. "$BCLIB"
. "$METAFN"
TICKET_META
DRIVE
meta_run() { # meta_run -> stdout of TICKET_META
  : > "$GH_REC"; : > "$CURL_REC"
  # HENV: bin/lib/env-path.sh (BH-451/BH-455, landed on main before this ticket
  # forked but after the fork point of this rebase) resolves it once at
  # run-build.sh's top and TICKET_META reads $HENV, not $HARNESS/env directly.
  # harness_env_dir's first branch is "$root/env" when it exists as a real
  # dir, which $H/env already is, so this is the same value the full pipeline
  # would compute.
  HARNESS="$H" HENV="$H/env" PROJECT=proj KEY=AB-7 TICKET=7 METAFN="$METAFN" \
    GHLIB="$DIR/bin/lib/gh-rest.sh" BCLIB="$DIR/bin/lib/board-creds.sh" GH_ETAG=0 TMPDIR="$T" \
    GH_REC="$GH_REC" GH_OUT="$GH_OUT" CURL_REC="$CURL_REC" CURL_OUT="$CURL_OUT" \
    bash "$T/drive-meta.sh" 2>/dev/null
}

# A1 — the issues lane
printf -- '-\n' > "$H/fc-prod"; printf -- '-\n' > "$H/fc-prefix"
printf '{"title":"T","labels":[],"body":"B"}\n' > "$GH_OUT"
OUT=$(meta_run)
[ "$(jq -r '.body // "MISSING"' <<<"$OUT" 2>/dev/null)" = B ] && ok \
  || bad "A1: the issues lane must select the body, got '$OUT'"
[ "$(jq -r '.title // ""' <<<"$OUT" 2>/dev/null)" = T ] && ok \
  || bad "A1: the issues lane must still select the title, got '$OUT'"
[ "$(grep -c . "$GH_REC")" = 1 ] && ok \
  || bad "A1: the body must ride the call TICKET_META already made, got $(grep -c . "$GH_REC") gh calls"
# BH-1649: the one call is the REST issue read; its jq projection is what keeps
# the answer to title, labels and body (pinned by run-build-issue-rest.bh-1641-test.sh).
[ "$(cat "$GH_REC")" = "api -i -X GET repos/o/r/issues/7" ] && ok \
  || bad "A1: the one call must be the REST issue read, got '$(cat "$GH_REC")'"

# A2 — the board lane: the description is the body
printf 'https://x.test\n' > "$H/fc-prod"; printf '/api/board\n' > "$H/fc-prefix"
printf 'X_INTERNAL_API_TOKEN=t\n' > "$H/env/proj.env"
printf '{"ticket":{"title":"T","description":"<h2>Rollout</h2>"}}\n' > "$CURL_OUT"
OUT=$(meta_run)
[ "$(jq -r '.body // "MISSING"' <<<"$OUT" 2>/dev/null)" = '<h2>Rollout</h2>' ] && ok \
  || bad "A2: the board lane must select .description as the body, got '$OUT'"
[ "$(jq -r '.title // ""' <<<"$OUT" 2>/dev/null)" = T ] && ok \
  || bad "A2: the board lane must still select the title, got '$OUT'"
[ "$(grep -c . "$GH_REC")" = 0 ] && ok || bad "A2: the board lane must not call gh"
[ "$(grep -c . "$CURL_REC")" = 1 ] && ok \
  || bad "A2: the board lane must make exactly one call, got $(grep -c . "$CURL_REC")"
# A3 — a board that spells it `body`, and one that carries neither
printf '{"ticket":{"title":"T","body":"plain"}}\n' > "$CURL_OUT"
[ "$(jq -r '.body // "MISSING"' <<<"$(meta_run)" 2>/dev/null)" = plain ] && ok \
  || bad "A3: the board lane must fall back to .body when there is no description"
printf '{"ticket":{"title":"T"}}\n' > "$CURL_OUT"
[ "$(jq -r '.body // "MISSING"' <<<"$(meta_run)" 2>/dev/null)" = "" ] && ok \
  || bad "A3: a ticket with no body at all must select an empty string, never null"

# ═══════════════════════════════════════════════════════════════════════════
# Sections B/C — the hook itself
# ═══════════════════════════════════════════════════════════════════════════
REAL_FC="$DIR/bin/lib/file-children.sh"
[ -r "$REAL_FC" ] && ok || bad "extract: bin/lib/file-children.sh (the real detector) is missing"

# The lane script, stubbed — except for `--is-rollout`, which runs the REAL
# fc_has_rollout. The detector under test is therefore the shipped one, not a
# paraphrase of it, and the negatives below are real answers.
RR="$H/bin/run-rollout.sh"
cat > "$RR" <<'SH'
#!/bin/bash
if [ "${1:-}" = --is-rollout ]; then
  [ "${ISROLL_RC:-0}" != 0 ] && exit "$ISROLL_RC"
  # shellcheck source=/dev/null
  . "$REAL_FC"
  fc_has_rollout < "$2"
  exit $?
fi
printf '%s\n' "$*" >> "$STUB_REC"
[ -n "${STUB_RUNTXT:-}" ] && printf '%s\n' "$STUB_RUNTXT" > "${4:-.}/rollout-run.txt"
[ -n "${STUB_OUT:-}" ] && printf '%s\n' "$STUB_OUT"
exit "${STUB_RC:-0}"
SH
chmod +x "$RR"

# Everything after the block is the ordinary plan path. The sentinel is what
# proves a fall-through really fell through rather than the hook eating the run.
cat > "$T/drive-hook.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
STAMP() { echo "2026-09-19 00:00:00Z"; }
# shellcheck source=/dev/null
. "$RESULTFN"
# shellcheck source=/dev/null
. "$HOOK"
touch "$BUILD/size-gate.txt"
agent-call.sh plan >/dev/null 2>&1
printf 'sentinel\n' > "$BUILD/sentinel"
DRIVE

B="$T/build"
run_hook() { # run_hook <meta-mode: full|nobody|none> <title> <body>
  scratch_rm "$B"; mkdir -p "$B"
  : > "$T/stub.rec"; : > "$GH_REC"; : > "$CURL_REC"
  rm -f "$T/agent-called"
  case "$1" in
    none)   : ;;
    nobody) jq -nc --arg t "$2" '{title:$t,labels:[]}' > "$B/ticket-meta.json" ;;
    *)      jq -nc --arg t "$2" --arg b "$3" '{title:$t,labels:[],body:$b}' > "$B/ticket-meta.json" ;;
  esac
  HARNESS="$H" BUILD="$B" PROJECT=proj KEY=AB-7 TICKET=7 \
    HOOK="$HOOK" RESULTFN="$RESULTFN" REAL_FC="$REAL_FC" \
    STUB_REC="$T/stub.rec" STUB_OUT="${STUB_OUT:-}" STUB_RC="${STUB_RC:-0}" \
    STUB_RUNTXT="${STUB_RUNTXT:-}" ISROLL_RC="${ISROLL_RC:-0}" \
    AGENT_MARK="$T/agent-called" GH_REC="$GH_REC" GH_OUT="$GH_OUT" \
    CURL_REC="$CURL_REC" CURL_OUT="$CURL_OUT" \
    bash "$T/drive-hook.sh" > "$T/hook.out" 2>&1
  HOOK_RC=$?
}
dispatched() { [ -s "$T/stub.rec" ]; }
planned()    { [ -f "$B/sentinel" ] && [ -f "$T/agent-called" ] && [ -f "$B/size-gate.txt" ]; }
result_of()  { cat "$B/RESULT" 2>/dev/null; }

POSBODY=$'Intro\n\n## Rollout\n### Wave: schema\n### Wave: routes\nafter: schema\n'

# ── B — the dispatch ────────────────────────────────────────────────────────
STUB_OUT='RESULT "ROLLOUT_FILED 2"'; STUB_RC=0; STUB_RUNTXT=""; ISROLL_RC=0
run_hook full 'AB-7: project-4 mcp rollout' "$POSBODY"
dispatched && ok || bad "B1: a rollout body on a top-level ticket must dispatch the lane: $(cat "$T/hook.out")"
[ "$(cat "$T/stub.rec")" = "proj 7 AB-7 $B" ] && ok \
  || bad "B1: the lane must be run with <project> <ticket> <KEY> <build-dir>, got '$(cat "$T/stub.rec")'"
[ "$HOOK_RC" = 0 ] && ok || bad "B1: a dispatched build must exit 0, got rc=$HOOK_RC"
[ "$(result_of)" = "ROLLOUT_FILED 2" ] && ok \
  || bad "B1: the RESULT must be the lane's own line, got '$(result_of)'"
[ -f "$T/agent-called" ] && bad "B2: the PLAN stage must never run for a rollout master" || ok
[ -f "$B/size-gate.txt" ] && bad "B2: the size gate must never see a rollout master" || ok
[ -f "$B/sentinel" ] && bad "B2: the hook must exit, not fall through, after filing" || ok
grep -q 'ROLLOUT:' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "B3: the dispatch must be logged: $(cat "$B/pipeline.log" 2>/dev/null)"
[ "$(grep -c . "$GH_REC")" = 0 ] && [ "$(grep -c . "$CURL_REC")" = 0 ] && ok \
  || bad "B3: the hook must buy no API call of its own (gh: $(cat "$GH_REC"), curl: $(cat "$CURL_REC"))"

# ── C — the negatives. Each one must leave the ordinary plan path running ────
neg() { # neg <label> <meta-mode> <title> <body>
  run_hook "$2" "$3" "${4:-}"
  dispatched && bad "C: must NOT dispatch: $1"        || ok
  planned    || bad "C: the plan path must run: $1 (sentinel=$([ -f "$B/sentinel" ] && echo y || echo n) agent=$([ -f "$T/agent-called" ] && echo y || echo n))"
  planned    && ok
  [ -f "$B/RESULT" ] && bad "C: a fall-through must write no RESULT: $1" || ok
}
STUB_OUT='RESULT "ROLLOUT_FILED 2"'; STUB_RC=0; STUB_RUNTXT=""; ISROLL_RC=0
neg "a split child's title (AB-7.2)"        full 'AB-7.2: x' "$POSBODY"
neg "a child title with leading space"      full ' AB-7.2: x' "$POSBODY"
neg "the heading is inside a \`\`\` fence"  full 'AB-7: x' $'Intro\n\n```\n## Rollout\n### Wave: a\n```\n'
neg "the heading is inside a ~~~ fence"     full 'AB-7: x' $'Intro\n\n~~~\n## Rollout\n### Wave: a\n~~~\n'
neg "the heading is inside <pre><code>"     full 'AB-7: x' $'<pre><code>## Rollout\n### Wave: a</code></pre>\n'
neg "the heading is blockquoted"            full 'AB-7: x' $'> ## Rollout\n> ### Wave: a\n'
neg "the heading is '## Rollout risk'"      full 'AB-7: x' $'## Rollout risk\nnot a rollout\n'
neg "no ticket-meta.json at all"            none 'AB-7: x' ""
neg "ticket meta with no body key"          nobody 'AB-7: x' ""
neg "an empty body"                         full 'AB-7: x' ""

# issue #816's own body: it documents the convention inside a fence, and it is
# the real-world input a reader-through-fences files issues on.
cat > "$T/816-body.md" <<'BH816_BODY_EOF'
Today the only way multi-wave work reaches the harness unattended is by accident: a plan sizes itself XL and `bin/run-decompose.sh` splits it. There is no way to hand the harness a deliberate sequence ("these five waves, in this order") and walk away. On 2026-09-17 the project-4 MCP server needed exactly that and a Mac session had to file W0, park W1–W4 as HTML files in the repo, and leave a human to file each one as the previous merged. the operator's decision ("go", 2026-09-17): add a **Rollout** ticket kind. A ticket whose body carries a `## Rollout` section with one block per wave is not planned or built as one thing; the harness files one child per wave, sequences them, parks the master, and the ordinary pipeline does the rest. Both lanes: GitHub-Issues projects day one, in-app boards once #815 and the board-side dependency tickets land. No model call anywhere in this stage; the author already wrote the waves, and the existing PLAN stage fleshes each child out as it does for any ticket body.

## Scope

### The body convention (documented in `skills/harness/SKILL.md` and `prompts/plan-contract.md`)

```
## Rollout
### Wave: <title>
after: <title of an earlier wave>[, <title>]     (optional; omit for none)
<body: the wave's own Scope / Acceptance tests / QA screens / Out of scope>
### Wave: <title>
...
```

Rules: 2–12 waves; titles unique; `after:` names resolve only to EARLIER waves (a forward or unknown name is a refusal); a wave's `after` is a hard code dependency by definition (a rollout author sequences because the code builds on the previous wave), so the GitHub lane writes `Blocked-by: #<n> (hard)`; a `## Rollout` section inside a wave body is a refusal (no nested rollouts); text above the `## Rollout` heading is the master's own description and is kept on the master. Case-insensitive on `## Rollout` and `### Wave:`; tolerate HTML bodies from in-app boards by stripping tags before parsing (the project-4 board stores `<h2>`/`<h3>`; parse `<h2>Rollout</h2>` and `<h3>Wave: …</h3>` too, and file the child bodies as HTML on that lane, markdown on the issues lane).

### `bin/lib/file-children.sh` — one filer for both decompose and rollout

Extract the filing half of `bin/run-decompose.sh` (`:266-361` issues lane, `:424-448` board lane) into a sourced library with one entry point: `file_children <project> <parent-ticket> <KEY> <build-dir> <children.json> [--kind decompose|rollout]`. Same `children.json` shape the decomposer already produces (`title`, `after` as 1-based positions, `body`, optional `contract`), so `run-decompose.sh` calls the library and its behavior and byte-exact bodies do not change (the existing `tests/run-decompose-issues-test.sh` and `tests/decompose-contract-first-test.sh` are the regression guard). Differences by kind:

- `decompose` (unchanged): contract child required, `.0: contract —` title, `CONTRACT:`/`DEPENDS:` lines, chain cap 2.
- `rollout`: no contract child; titles `<KEY>.<n>: <wave title>`; footer lines `Part of #<parent>`, `Order: <n> of <N>`, `Blocked-by: #<n> (hard)` per `after` (one line, all blockers), `Rollout wave <n> of <N>: planned by its author; the PLAN stage fleshes it out. Never split into a rollout again.`; no size budget line (a wave may still size XL and be decomposed normally by the size gate, which is allowed: depth guard applies to `.n.m` titles only).
- Board lane, both kinds: read the base path from fleet.conf column 4 instead of the hardcoded `/api/board` (`run-decompose.sh:442-444`, the bug named in `docs/BOARD-API-CONTRACT.md:31-39`); create each child with `POST {BASE}{BP}/boards/{boardId}/tickets` carrying `title`, `description`, `priority` and, when `GET /boards` advertises `capabilities` containing `dependencies`, also `parentId: <parent>` and `dependsOn: [<child ids of its after list>]`. When the board lacks the capability, `rollout` REFUSES (`ROLLOUT_FAILED board lacks dependencies`) rather than filing unsequenced children; `decompose` keeps filing as today (its children are meant to be parallel). Children are created in order so an `after` id always exists. `Idempotency-Key: rollout-<KEY>-<n>` on each create so a retried run cannot double-file (the boards honor the header on comments and moves today; ask for it on create in the same board tickets, and until then rely on the `children.txt` re-entrancy guard the decomposer already has, `:129-135`).
- Parent parking: issues lane removes `ai-build`; board lane moves the master to `in_progress` (as today), and additionally the master's comment lists each child with its key and link.
- `DECOMPOSE_DRY_RUN=1` / a new alias `FILE_CHILDREN_DRY_RUN=1` prints every `gh` or `curl` command and writes the exact bodies to `$BUILD/child-<n>.md` without network.

### `bin/run-rollout.sh <project> <ticket-id> <KEY> <build-dir>`

Deterministic: fetch the ticket body (issues lane: `gh issue view --json body`; board lane: `GET /tickets/{id}` with the envelope tolerance the contract documents), parse per the convention into `children.json`, validate, call `file_children --kind rollout`, write `$BUILD/rollout-run.txt`, and end with `RESULT "ROLLOUT_FILED <children>"` or `RESULT "ROLLOUT_FAILED <reason>"`. Write the master comment (`$BUILD/rollout-comment.md`): the wave list with links and the sentence that each wave builds when the one before it has merged. Board voice per `rules/CLAUDE.md`.

### Hook in `bin/run-build.sh`

Before the PLAN stage buys a model call: if the ticket body contains a `## Rollout` heading (or the HTML equivalent) and the ticket title does not match a child pattern `^[A-Za-z]+-[0-9]+\.[0-9]+`, dispatch `run-rollout.sh` and `exit 0`, mapping `ROLLOUT_FILED*` to job status `done` beside `DECOMPOSED*` at `:494`. The size gate never sees a rollout master.

### Sweeps and prompts

`ROLLOUT_FILED <children>` / `ROLLOUT_FAILED <reason>` get the same result-sweep rule `DECOMPOSED` / `DECOMPOSE_FAILED` have in `prompts/TEMPLATE-GH.md:42`, `prompts/cromford.md`, and the in-app prompts plus the template they render from: children are ordinary new tickets, the master stays open and unlabelled (issues) or `in_progress` (board), never re-labelled, never closed by hand; `ROLLOUT_FAILED` is one ALERTS.log line naming `<dir>/rollout-run.txt`. `bin/orphan-reconcile.sh`: a rollout master (unlabelled, children naming it in `Part of`) already reads as class (c) OWNED on the issues lane; add a fixture proving it. `bin/decompose-parent-close.sh` already closes issues-lane masters whose children all closed; confirm a rollout master closes the same way (its children carry `Part of` and `Order:`), and the in-app lane comes from #815.

### Docs

`skills/harness/SKILL.md`: a "Rollout" section under plan + handoff (when to use it instead of N hand-filed issues, the body convention, the refusals, how to hold or cancel a wave: comment `HOLD` on that child). `docs/BUILD-CONCURRENCY.md`: one paragraph on rollout children (they are chains on purpose; the two-level cap does not apply to them). `docs/BOARD-API-CONTRACT.md`: `parentId`/`dependsOn` on create.

Files to touch: `bin/lib/file-children.sh` (new), `bin/run-rollout.sh` (new), `bin/run-decompose.sh` (call the lib; no behavior change), `bin/run-build.sh` (hook + result mapping), `prompts/TEMPLATE-GH.md`, `prompts/cromford.md`, the in-app prompt template and its four rendered prompts, `skills/harness/SKILL.md`, `docs/BUILD-CONCURRENCY.md`, `docs/BOARD-API-CONTRACT.md`. Do not touch `bin/triage-gate.sh`, `bin/run-triage.sh`, `bin/decompose-parent-close.sh` (#815 owns them).

## Acceptance tests

All under `tests/`, `set -uo pipefail`, source `tests/lib/scratch.sh` first, no network, no model, `jq` guard, `gh` shim on `PATH` answering from fixtures as in `tests/run-decompose-issues-test.sh:12-52`, `curl` stub per `tests/sweep-stale-builds-test.sh:37` for the board lane. fleet.conf in `$T` has one `-` row and one in-app row. Red first.

- `tests/run-rollout-issues-test.sh`
  - A master body with 3 waves, wave 3 `after: <wave 1>, <wave 2>`, dry run: exactly 3 `gh issue create` commands; titles `AB-7.1: …`, `AB-7.2: …`, `AB-7.3: …`; child 1 and 2 bodies have no `Blocked-by`; child 3 body has one line `Blocked-by: #<n1> (hard), #<n2> (hard)`; every child has `Part of #7` and `Order: k of 3`; no child has `CONTRACT:` or a size-budget line; the master gets `--remove-label ai-build`; `children.txt` lists `AB-<n>` for each; RESULT line starts `ROLLOUT_FILED`.
  - Feed child 3's body to the REAL `bin/unblocked-children.sh` with a diff that closes #n1 only → not released; with both closed → `UNBLOCKED` (the same proof `decompose-contract-first-test.sh` does).
  - Refusals, each `ROLLOUT_FAILED` with the reason and zero `gh issue create`: one wave; 13 waves; duplicate titles; `after:` naming a later wave; `after:` naming an unknown wave; a wave body containing `## Rollout`.
  - A body with no `## Rollout` heading → the script exits without filing and without a RESULT line (run-build's hook is what decides; the script must be safe to call).
  - Second dry run with `children.txt` present → files nothing (re-entrancy).
- `tests/run-rollout-board-test.sh`
  - Board advertising `capabilities: ["dependencies"]`: 3 waves → 3 `POST …/boards/<id>/tickets` in order, child 3's JSON carries `parentId` = master id and `dependsOn` = the two ids the stub returned for children 1 and 2, all with `Idempotency-Key: rollout-TK-9-<n>`; then one comment POST on the master and one move to `in_progress`; the base path comes from the in-app fleet.conf row, not `/api/board` (fixture row uses `/api/accounting/requests-board` and the test asserts that path in the curl log).
  - HTML master body (`<h2>Rollout</h2><h3>Wave: …</h3>`) parses to the same `children.json` as the markdown one (byte compare).
  - Board without the capability → `ROLLOUT_FAILED board lacks dependencies`, zero POSTs.
- `tests/file-children-lib-test.sh`: `run-decompose.sh` through the library produces byte-identical child bodies to the checked-in expected files the existing decompose tests use (copy their fixtures; this is the no-behavior-change proof), on both lanes; the board lane now reads the fleet.conf base path.
- `tests/run-build-rollout-hook-test.sh`: with a stubbed `run-rollout.sh` on PATH, a ticket-meta body containing `## Rollout` makes `run-build.sh` call it and exit 0 with `ROLLOUT_FILED` mapped to `done`, and the PLAN stage's `agent-call.sh` stub is never invoked; a child-pattern title (`AB-7.2: …`) with a `## Rollout` body does NOT dispatch (goes to the normal plan).
- `tests/orphan-reconcile-test.sh` (extend): an unlabelled rollout master whose children name it in `Part of` reads OWNED, not ORPHAN.
- Existing suites must stay green unchanged: `tests/run-decompose-issues-test.sh`, `tests/decompose-contract-first-test.sh`, `tests/run-decompose-fresh-token-test.sh`, `tests/unblocked-children-test.sh`, `tests/reverse-dep-wake-test.sh`, `tests/size-gate-test.sh`.

## Verification contract

`bash` each new test and each existing suite above, plus the `checks/` gates in `CONTRIBUTING.md` "Before you push" (including `checks/tests-scratch-only`). The PR body lists each with its exit code. Exercised proof after merge: file one real rollout on `example-org/cromford` itself (two small doc waves, wave 2 after wave 1) and show the two children, the parked master, and wave 2 releasing when wave 1 merges. That is the first real rollout, and it is on our own repo, not a client's.

## QA screens

None.

## Out of scope

- The read side on in-app boards (gate, fingerprint, in-app parent close): #815.
- Any model call in this stage. A thin wave body is the PLAN stage's job to flesh out, as with every ticket.
- Nested rollouts, cross-project rollouts, editing a filed rollout in place (revise by commenting on the children, as with any issue; thread recency is law).

After: #815 for end-to-end value on in-app boards. Not a code dependency (this issue writes fields the board serves; #815 reads them), so no `Blocked-by`. On GitHub-Issues projects this issue is complete on its own.

BH816_BODY_EOF
grep -qx '## Rollout' "$T/816-body.md" && ok \
  || bad "C: the #816 fixture lost its fenced '## Rollout' line — the negative is vacuous"
neg "issue #816's own body (fenced convention)" full 'BH-816: Rollout ticket kind' "$(cat "$T/816-body.md")"

# absence of the lane itself
chmod -x "$RR"
neg "bin/run-rollout.sh is not executable (half-synced box)" full 'AB-7: x' "$POSBODY"
chmod +x "$RR"
mv "$RR" "$T/run-rollout.parked"
neg "bin/run-rollout.sh is not on this box yet (#984)" full 'AB-7: x' "$POSBODY"
mv "$T/run-rollout.parked" "$RR"
ISROLL_RC=2
neg "the detector itself crashed (rc 2)" full 'AB-7: x' "$POSBODY"
ISROLL_RC=0

# ── C' — the failure shapes. A filing that did not happen is never done ──────
STUB_OUT='RESULT "ROLLOUT_FAILED one wave"'; STUB_RC=0
run_hook full 'AB-7: x' "$POSBODY"
[ "$(result_of)" = "ROLLOUT_FAILED one wave" ] && ok \
  || bad "C'1: a refusal from the lane must be recorded verbatim, got '$(result_of)'"
[ "$HOOK_RC" = 0 ] && ok || bad "C'1: a refused rollout still exits 0, got rc=$HOOK_RC"
[ -f "$B/sentinel" ] && bad "C'1: a refused rollout must not then run the plan path" || ok

STUB_OUT=""; STUB_RC=0
run_hook full 'AB-7: x' "$POSBODY"
case "$(result_of)" in
  "ROLLOUT_FAILED bin/run-rollout.sh ended rc=0 without a result line"*) ok ;;
  *) bad "C'2: a silent lane run is FAILED, not done, got '$(result_of)'" ;;
esac

STUB_OUT='RESULT "ROLLOUT_FILED 2"'; STUB_RC=1
run_hook full 'AB-7: x' "$POSBODY"
case "$(result_of)" in
  ROLLOUT_FAILED*rc=1*) ok ;;
  *) bad "C'3: a FILED line from a run that exited non-zero must be demoted to FAILED, got '$(result_of)'" ;;
esac
grep -q 'ROLLOUT_FILED 2' <<<"$(result_of)" && ok \
  || bad "C'3: the demoted line must still quote what the lane claimed, got '$(result_of)'"

STUB_OUT=""; STUB_RC=0; STUB_RUNTXT='RESULT "ROLLOUT_FILED 3"'
run_hook full 'AB-7: x' "$POSBODY"
[ "$(result_of)" = "ROLLOUT_FILED 3" ] && ok \
  || bad "C'4: a result line written only to rollout-run.txt must be read, got '$(result_of)'"
STUB_RUNTXT=""

# C'5 — the reason itself carries a double quote. bin/run-rollout.sh writes free
# text into `RESULT "ROLLOUT_FAILED <reason>"`, and a reason that names a wave
# quotes it. A parser that stops at the first inner `"` matches nothing at all,
# and the lane's own word is replaced by the generic no-result-line fallback —
# so the reason is lost from $BUILD/RESULT, the job row and the sweep's ALERTS
# line, on exactly the failures somebody has to read.
STUB_OUT='RESULT "ROLLOUT_FAILED after: names unknown wave "foo""'; STUB_RC=0
run_hook full 'AB-7: x' "$POSBODY"
[ "$(result_of)" = 'ROLLOUT_FAILED after: names unknown wave "foo"' ] && ok \
  || bad "C'5: a reason carrying a double quote must be recorded verbatim, got '$(result_of)'"
case "$(result_of)" in
  *"without a result line"*) bad "C'5: the lane wrote a result line — the generic fallback must not fire, got '$(result_of)'" ;;
  *) ok ;;
esac
[ "$HOOK_RC" = 0 ] && ok || bad "C'5: a refused rollout still exits 0, got rc=$HOOK_RC"
[ -f "$B/sentinel" ] && bad "C'5: a refused rollout must not then run the plan path" || ok

# ═══════════════════════════════════════════════════════════════════════════
# Section D — where the block sits, and what it does not re-implement
# ═══════════════════════════════════════════════════════════════════════════
lineno() { grep -Fn "$1" "$RB" | head -1 | cut -d: -f1; }
L_HOOK=$(lineno '# >>> rollout hook')
L_META=$(lineno '# <<< ticket meta')
[ -n "$L_HOOK" ] && [ -n "$L_META" ] && [ "$L_HOOK" -gt "$L_META" ] && ok \
  || bad "D1: the hook must sit after the ticket-meta block (hook=$L_HOOK meta=$L_META)"
for M in '# >>> preplan adopt' '# >>> plan launch' '# >>> kind flow' '# >>> size gate'; do
  LN=$(lineno "$M")
  [ -n "$LN" ] && [ "$L_HOOK" -lt "$LN" ] && ok \
    || bad "D1: the hook must sit before '$M' (hook=$L_HOOK, that=$LN)"
done
# The depth guard is the size gate's own regex. Two spellings of "is this a
# split child" is how a child gets dispatched as a master one day.
re_of() { sed -nE "s/.*grep -qE '([^']*)'.*/\1/p" "$1" | head -1; }
HOOK_RE=$(re_of "$HOOK")
SG_RE=$(grep -F 'SG_CHILD=1' "$RB" | sed -nE "s/.*grep -qE '([^']*)'.*/\1/p" | head -1)
[ -n "$HOOK_RE" ] && [ -n "$SG_RE" ] && ok || bad "D2: could not read both child regexes (hook='$HOOK_RE' size gate='$SG_RE')"
[ "$HOOK_RE" = "$SG_RE" ] && ok \
  || bad "D2: the hook's child regex must be the size gate's, byte for byte (hook='$HOOK_RE' size gate='$SG_RE')"
# Detection is delegated. A second copy of the fence state machine here is the
# bug bin/lib/file-children.sh exists to prevent.
[ "$(grep -c 'fc_strip_fences\|fc_has_rollout' "$HOOK")" = 0 ] && ok \
  || bad "D3: the hook must not re-implement the detector"
grep -q -- '--is-rollout' "$HOOK" && ok \
  || bad "D3: detection must go through bin/run-rollout.sh --is-rollout"

# ═══════════════════════════════════════════════════════════════════════════
# Section E — the job row (_job_finish)
# ═══════════════════════════════════════════════════════════════════════════
cat > "$T/drive-jobfin.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
job_beat_stop() { :; }
job_update()      { printf 'job_update %s\n' "$*" >> "$REC"; }
job_event()       { printf 'job_event %s\n' "$*" >> "$REC"; }
job_phase_close_open() { printf 'phase_close %s\n' "$*" >> "$REC"; echo ""; }
# shellcheck source=/dev/null
. "$JOBFIN"
_job_finish
DRIVE
jobfin() { # jobfin <result line> -> everything the job seams were told
  JREC="$T/jobfin.rec"; : > "$JREC"
  JB="$T/jobfin-build"; scratch_rm "$JB"; mkdir -p "$JB"; printf '%s\n' "$1" > "$JB/RESULT"
  JOB_ID=7 JOB_BEAT="" BUILD="$JB" PROJECT=proj KEY=AB-7 \
    REC="$JREC" JOBFIN="$JOBFIN" bash "$T/drive-jobfin.sh" >/dev/null 2>&1
  cat "$JREC"
}
OUT=$(jobfin "ROLLOUT_FILED 3")
grep -q 'job_update .*status=done' <<<"$OUT" && ok \
  || bad "E1: a filed rollout must close the job row done, got: $OUT"
OUT=$(jobfin "ROLLOUT_FILED")
grep -q 'job_update .*status=done' <<<"$OUT" && ok \
  || bad "E2: ROLLOUT_FILED with no trailing count must still close done, got: $OUT"
OUT=$(jobfin "ROLLOUT_FAILED one wave")
grep -q 'job_update .*status=failed' <<<"$OUT" && ok \
  || bad "E3: a failed rollout must close the job row failed, got: $OUT"
grep -q 'job_update .*status=done' <<<"$OUT" \
  && bad "E3: a failed rollout must NEVER close the job row done, got: $OUT" || ok
# The word is asked for by name, and `*)` already answers failed, so the
# behaviour assertions cannot tell the two apart: pinned both ways, so a file
# that lost the arm fails instead of passing on a missing symbol.
grep -qE '^[[:space:]]*.*ROLLOUT_FILED\*\)[[:space:]]*st="?done' "$JOBFIN" && ok \
  || bad "E4: _job_finish must name ROLLOUT_FILED* in the done arm"
grep -qE '^[[:space:]]*[^#]*ROLLOUT_FAILED\*?\)' "$JOBFIN" \
  && bad "E4: ROLLOUT_FAILED must not be a case arm in the status map — it belongs to the catch-all" || ok

# ═══════════════════════════════════════════════════════════════════════════
# Section F — the result-sweep rule in the seven prompts
# ═══════════════════════════════════════════════════════════════════════════
# These files ARE the artifact: a watcher session reads them as its instructions,
# so a text pin is the honest test here and the absent-line case is a FAIL.
line_with() { # line_with <file> <substring...> -> line number of the first line carrying all
  local f="$1"; shift
  local out p
  out=$(grep -n . "$DIR/$f" 2>/dev/null)
  for p in "$@"; do out=$(grep -F -- "$p" <<<"$out"); done
  head -1 <<<"$out" | cut -d: -f1
}
for F in prompts/TEMPLATE-GH.md prompts/cromford.md; do
  LR=$(line_with "$F" ROLLOUT_FILED ROLLOUT_FAILED rollout-run.txt re-label COMMENTED)
  LD=$(line_with "$F" DECOMPOSE_FAILED)
  [ -n "$LR" ] && ok \
    || bad "F: $F must carry the rollout sweep rule (FILED, FAILED, rollout-run.txt, re-label, COMMENTED on one line)"
  [ -n "$LR" ] && [ -n "$LD" ] && [ "$LR" -gt "$LD" ] && ok \
    || bad "F: $F must place the rollout rule after the DECOMPOSE_FAILED bullet (rollout=$LR decompose=$LD)"
done
for F in prompts/TEMPLATE.md prompts/project-4.md prompts/project-1.md prompts/project-3.md prompts/project-2.md; do
  LR=$(line_with "$F" ROLLOUT_FILED ROLLOUT_FAILED rollout-run.txt in_progress)
  [ -n "$LR" ] && ok \
    || bad "F: $F must carry the rollout sweep rule with in_progress (the in-app master is not unlabelled)"
  if [ -n "$LR" ]; then
    grep -qF 're-label' <<<"$(sed -n "${LR}p" "$DIR/$F")" \
      && bad "F: $F is an in-app board — its rollout rule must not talk about labels" || ok
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
# Section G — the sentences the ticket routed to the PR BODY actually render
# ═══════════════════════════════════════════════════════════════════════════
# The ticket says twice "state in the PR body": the read-only confirmation about
# `bin/decompose-parent-close.sh`, and the post-merge exercised proof named as
# owed and never claimed. A commit message does not do that — `PR_BODY_FOR()`
# renders `git log --format='- %s'` (subjects only) and never reads %B. The ONE
# verbatim channel from the plan into the body is `# >>> assumptions section`,
# and it lifts `head -c 1500`, so ORDER decides what a reviewer sees.
# So this section runs the PRODUCTION block against the spec this PR ships and
# asserts the rendered bytes carry all four routed items. Writing them anywhere
# else in the plan, or pushing them past the 1500-byte cut, goes red here.
# SHARE MIRROR: .harness/ (build records) is not published, so the plan
# this section renders is absent here.
if [ ! -f "$DIR/.harness/specs/BH-985/plan.md" ]; then
  echo "SKIP G: no .harness/specs/BH-985/plan.md in this copy"
  echo "run-build-rollout-hook.bh-985: $PASS passed, $FAIL failed"
  [ "$FAIL" = 0 ]; exit
fi
SPEC="$DIR/.harness/specs/BH-985/plan.md"
[ -s "$SPEC" ] && ok || bad "G: the executed plan must ship at .harness/specs/BH-985/plan.md"
ASSUMB="$T/assumptions.sh"
marked '# >>> assumptions section' '# <<< assumptions section' "$RB" > "$ASSUMB"
[ -s "$ASSUMB" ] && ok \
  || bad "G: could not lift the assumptions-section block from the flattened pipeline"
cat > "$T/drive-assum.sh" <<'DRIVE'
set -uo pipefail
# shellcheck source=/dev/null
. "$ASSUMB"
printf '%s' "$ASSUMPTIONS_SECTION"
DRIVE
AB="$T/assum-build"; scratch_rm "$AB"; mkdir -p "$AB"; cp "$SPEC" "$AB/plan.md"
RENDERED=$(BUILD="$AB" ASSUMB="$ASSUMB" bash "$T/drive-assum.sh" 2>/dev/null)
[ -n "$RENDERED" ] && ok || bad "G: the assumptions block rendered nothing for this plan"
# One assertion per routed item, so a partial revert names which sentence was lost.
g_body() { # g_body <label> <substring...>
  local label="$1"; shift
  local p
  for p in "$@"; do
    grep -qF -- "$p" <<<"$RENDERED" && ok \
      || bad "G: the rendered PR body must carry $label — missing: $p"
  done
}
g_body "the decompose-parent-close confirmation (T11)" \
  'decompose-parent-close.sh' 'part_re' 'order_re'
g_body "the owed post-merge proof, named and not claimed" \
  'OWED after merge, NOT claimed'
g_body "shellcheck recorded NOT RUN, owed from CI" \
  'shellcheck -S error bin/run-build.sh` is NOT RUN'
g_body "the A11 note: narrowing dropped at rebase, main's #1260 form" \
  'dropped at rebase' '#1260'
# The body must not CLAIM the proof was run. Rung discipline: it is owed, and the
# words that would round it up are exactly the ones to keep out of the body.
grep -qiE 'rollout (was )?(exercised|proven|verified) (end to end|on this repo)' <<<"$RENDERED" \
  && bad "G: the body must not claim the post-merge proof was already run" || ok

echo "run-build-rollout-hook.bh-985: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
