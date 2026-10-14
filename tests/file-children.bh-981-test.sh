#!/bin/bash
# tests/file-children.bh-981-test.sh — bin/lib/file-children.sh, the shared
# child-filer contract (BH-981, child .0 of #816).
#
# WHAT IS UNDER TEST, and why the exact bytes matter. This library is the seam
# the rollout lane and the decompose lane will both file children through, and
# the decompose lane's child bodies must not move by one byte while that
# happens: bin/unblocked-children.sh launches a child off `Blocked-by: #<n>`,
# bin/lib/dep-verify-lib.sh reads the `(hard)` suffix, bin/decompose-parent-close.sh
# counts `Part of #N` / `Order: n of N`, and bin/size-gate.sh reads the size
# budget line. So the footer assertions here do not compare against a string
# somebody typed in this file — they drive the REAL bin/run-decompose.sh under
# DECOMPOSE_DRY_RUN=1 and diff its produced child bodies against the library's
# output. A one-byte drift is a red.
#
# The second load-bearing half is fc_has_rollout. Downstream it decides whether
# a ticket is filed as N issues on somebody's repo without a plan stage, so a
# false positive is issues nobody asked for under our App identity. Every
# negative in the corpus below is its own assertion, and issue #816's own body
# (which documents the `## Rollout` convention INSIDE a fence) is committed
# verbatim as the real-world negative.
#
# No network, no model call, no gh, no secrets, nothing written outside $T.
# Run from anywhere:
#   tests/file-children.bh-981-test.sh      (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/file-children.sh"
if [ ! -r "$LIB" ]; then
  echo "FAIL: bin/lib/file-children.sh is missing"
  echo "file-children.bh-981: 0 pass, 1 fail"
  exit 1
fi

# ===========================================================================
# A1 — it is a LIBRARY: syntactic, inert when sourced, and it never exits
# ===========================================================================
bash -n "$LIB" 2>/dev/null && ok || bad "bash -n on the library: $(bash -n "$LIB" 2>&1)"
if command -v shellcheck >/dev/null 2>&1; then
  SC=$(shellcheck -S error "$LIB" 2>&1) && ok || bad "shellcheck -S error: $SC"
else
  echo "note: shellcheck absent — the A1 lint assertion did not run"
fi
# Sourcing is silent, writes nothing, and leaves rc 0 under `set -u`.
mkdir -p "$T/probe"
BEFORE=$(ls -A "$T/probe")
SRC_OUT=$(cd "$T/probe" && bash -c 'set -u; . "$1"; echo SOURCED-OK' _ "$LIB" 2>&1); SRC_RC=$?
{ [ "$SRC_RC" -eq 0 ] && [ "$SRC_OUT" = SOURCED-OK ]; } \
  && ok || bad "sourcing under set -u must print nothing and return 0 (rc=$SRC_RC, out='$SRC_OUT')"
AFTER=$(ls -A "$T/probe")
[ "$BEFORE" = "$AFTER" ] \
  && ok || bad "sourcing must write no file at source time (before='$BEFORE' after='$AFTER')"
# A sourced `exit` kills the LANE that sourced it, and `set -e` changes that
# lane's error handling from underneath it. Structural, not a behaviour claim.
CODE=$(grep -vE '^[[:space:]]*#' "$LIB")
grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*e' <<<"$CODE" \
  && bad "a sourced library must not set -e" || ok
grep -qE '(^|[;&|[:space:]])exit([[:space:]]|$)' <<<"$CODE" \
  && bad "a sourced library must never exit — it would kill its caller" || ok

# shellcheck source=bin/lib/file-children.sh
. "$LIB" || { echo "FAIL: the library would not source"; exit 1; }

# ===========================================================================
# A2 — fc_dry: both env names, either one alone, case-insensitive
# ===========================================================================
dry_rc() { # dry_rc [VAR=val ...] -> the rc fc_dry answers with
  env -u FILE_CHILDREN_DRY_RUN -u DECOMPOSE_DRY_RUN "$@" \
      bash -c 'set -u; . "$1"; fc_dry' _ "$LIB"
  printf '%s' "$?"
}
for V in 1 true yes on TRUE On YES; do
  [ "$(dry_rc "FILE_CHILDREN_DRY_RUN=$V")" = 0 ] \
    && ok || bad "fc_dry must be true for FILE_CHILDREN_DRY_RUN=$V"
  [ "$(dry_rc "DECOMPOSE_DRY_RUN=$V")" = 0 ] \
    && ok || bad "fc_dry must be true for DECOMPOSE_DRY_RUN=$V (the old name still works)"
done
for V in 0 no off "" nonsense; do
  [ "$(dry_rc "FILE_CHILDREN_DRY_RUN=$V")" = 1 ] \
    && ok || bad "fc_dry must be false for FILE_CHILDREN_DRY_RUN='$V'"
  [ "$(dry_rc "DECOMPOSE_DRY_RUN=$V")" = 1 ] \
    && ok || bad "fc_dry must be false for DECOMPOSE_DRY_RUN='$V'"
done
[ "$(dry_rc)" = 1 ] && ok || bad "fc_dry must be false when neither name is set"
# ALIAS, NOT REPLACEMENT: either one alone arms it.
[ "$(dry_rc FILE_CHILDREN_DRY_RUN=0 DECOMPOSE_DRY_RUN=1)" = 0 ] \
  && ok || bad "the old name alone must still arm the dry run"
[ "$(dry_rc FILE_CHILDREN_DRY_RUN=1 DECOMPOSE_DRY_RUN=0)" = 0 ] \
  && ok || bad "the new name alone must arm the dry run"

# ===========================================================================
# A3 — fc_sq is SQ(), and fc_log is LOG()
# ===========================================================================
# Not "a regex I wrote next to the regex I wrote": the real SQ() definition is
# lifted out of bin/run-decompose.sh and both are run on the same inputs.
SQ_DEF=$(grep -m1 '^SQ() {' "$DIR/bin/run-decompose.sh")
[ -n "$SQ_DEF" ] && ok || bad "could not find SQ() in bin/run-decompose.sh to compare against"
while IFS= read -r S; do
  WANT=$(bash -c 'eval "$1"; SQ "$2"' _ "$SQ_DEF" "$S" 2>&1)
  GOT=$(fc_sq "$S")
  [ "$GOT" = "$WANT" ] \
    && ok || bad "fc_sq must be byte-identical to SQ() for [$S]: got [$GOT] want [$WANT]"
done <<'SQCASES'
plain title
it's a "quoted" one
a'b'c
$(rm -rf /) `id` \ backslash
SQCASES

mkdir -p "$T/lg"
( FC_PROJECT=p; FC_KEY=K; fc_log "$T/lg" "hello world" ) && ok || bad "fc_log must return 0"
[ "$(wc -l < "$T/lg/pipeline.log")" -eq 1 ] \
  && ok || bad "fc_log writes exactly one line: $(cat "$T/lg/pipeline.log")"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z \[p/K\] hello world$' "$T/lg/pipeline.log" \
  && ok || bad "fc_log must use LOG()'s format: $(cat "$T/lg/pipeline.log")"
( FC_PROJECT=p; FC_KEY=K; fc_log "$T/lg" "second" ) >/dev/null 2>&1
[ "$(wc -l < "$T/lg/pipeline.log")" -eq 2 ] \
  && ok || bad "fc_log appends, one line per call: $(cat "$T/lg/pipeline.log")"
# A logging failure must never take down the lane that logged.
( fc_log /nonexistent/dir/xyz "msg" ) && ok || bad "fc_log must be a silent no-op on an absent build dir"
[ -e /nonexistent/dir ] && bad "fc_log must not create a build dir" || ok
LOGOUT=$( ( fc_log /nonexistent/dir/xyz "msg" ) 2>&1 )
[ -z "$LOGOUT" ] && ok || bad "a failed fc_log must say nothing to the caller's streams: '$LOGOUT'"

# ===========================================================================
# A4 — fc_child_footer (LOAD-BEARING): byte-identical to what the REAL
#      bin/run-decompose.sh writes into a child body today
# ===========================================================================
DEC="$DIR/bin/run-decompose.sh"
[ -x "$DEC" ] && ok || bad "bin/run-decompose.sh is missing or not executable"
mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/logs"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish      example-org/scoutish   https://scoutish.example  -                              9 box-1 10.0.0.9
ledger-os     example-org/ledger-os  https://ar.example        /api/accounting/requests-board 3 box-1 10.0.0.3
CONF
export FLEET_CONF="$T/h/fleet.conf"
cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENT CALL: $*" >> "${AGENT_LOG:-/dev/null}"
exit 0
SH
chmod +x "$T/h/bin/agent-call.sh"

CONTRACT_TEXT='src/db/metrics.ts: MetricRow; src/api/metrics.ts: GET /api/metrics'
SPEC='[
 {"title":"metrics table + read API","contract":"'"$CONTRACT_TEXT"'","after":[],"body":"Create the table and the read endpoint.\n\nFiles: src/db/metrics.ts, src/api/metrics.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"dashboard tile","after":[1],"body":"Render the tile against the read API.\n\nFiles: src/app/dashboard/MetricTile.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"weekly digest email","after":[],"body":"Send the digest.\n\nFiles: src/jobs/digest.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'

drive_decompose() { # drive_decompose <maxl> <maxf> [ENV=val ...]
  local ml="$1" mf="$2"; shift 2
  rm -rf "$T/b"; mkdir -p "$T/b"
  printf '%s\n' "$SPEC" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300\n' > "$T/b/size-gate.txt"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" \
        DECOMPOSE_DRY_RUN=1 "$@" "$DEC" scoutish 552 TK-552 "$T/b" "$ml" "$mf" >/dev/null 2>&1 )
}
footer_of() { awk 'f || /^---$/ { f=1; print }' "$1"; }

# --- the defaults (300 / 12 / 60), contract child and both siblings ---------
drive_decompose 300 12 && ok || bad "the dry-run drive of bin/run-decompose.sh must succeed"
for N in 1 2 3; do
  [ -s "$T/b/children/child-$N.md" ] || bad "no child-$N.md came out of the drive"
done
footer_of "$T/b/children/child-1.md" > "$T/real-1.txt"
footer_of "$T/b/children/child-2.md" > "$T/real-2.txt"
footer_of "$T/b/children/child-3.md" > "$T/real-3.txt"
# The contract child is n=1 and carries the CONTRACT lines; a sibling carries
# the blocker the filer composed for it. Those strings are the CALLER's job, so
# they are handed in here exactly as bin/run-decompose.sh composes them.
DEP2="DEPENDS: #553 hard — this slice imports the contract ($CONTRACT_TEXT)"
DEP3="$DEP2
DEPENDS: #554 soft — a separate slice of the same parent, no shared code"
fc_child_footer decompose 552 1 3 "" "" "$CONTRACT_TEXT" > "$T/lib-1.txt"
fc_child_footer decompose 552 2 3 "#553 (hard)" "$DEP2" "$CONTRACT_TEXT" > "$T/lib-2.txt"
fc_child_footer decompose 552 3 3 "#553 (hard)" "$DEP3" "$CONTRACT_TEXT" > "$T/lib-3.txt"
for N in 1 2 3; do
  if diff -u "$T/real-$N.txt" "$T/lib-$N.txt" > "$T/diff-$N.txt" 2>&1; then ok
  else bad "fc_child_footer decompose drifted from the real decomposer on child $N:
$(cat "$T/diff-$N.txt")"; fi
done

# --- the three knobs are READ, not baked -----------------------------------
# CONTRACT_MAX_LINES is the env name bin/run-decompose.sh resolves CONTRACT_MAXL
# from; MAXL/MAXF are its 5th and 6th arguments.
drive_decompose 500 20 CONTRACT_MAX_LINES=40 && ok || bad "the override drive must succeed"
footer_of "$T/b/children/child-1.md" > "$T/real-k1.txt"
footer_of "$T/b/children/child-2.md" > "$T/real-k2.txt"
( MAXL=500 MAXF=20 CONTRACT_MAX_LINES=40
  fc_child_footer decompose 552 1 3 "" "" "$CONTRACT_TEXT" ) > "$T/lib-k1.txt"
( MAXL=500 MAXF=20 CONTRACT_MAX_LINES=40
  fc_child_footer decompose 552 2 3 "#553 (hard)" "$DEP2" "$CONTRACT_TEXT" ) > "$T/lib-k2.txt"
for N in k1 k2; do
  if diff -u "$T/real-$N.txt" "$T/lib-$N.txt" > "$T/diff-$N.txt" 2>&1; then ok
  else bad "the footer must read MAXL/MAXF/CONTRACT_MAXL from the shell ($N):
$(cat "$T/diff-$N.txt")"; fi
done
grep -q 'aim for 40 lines' "$T/lib-k1.txt" \
  && ok || bad "CONTRACT_MAXL must reach the contract sentence: $(cat "$T/lib-k1.txt")"
grep -q 'at most 500 lines of product code across 20 files' "$T/lib-k2.txt" \
  && ok || bad "MAXL/MAXF must reach the size budget line: $(cat "$T/lib-k2.txt")"

# --- the ROLLOUT footer: four lines, and NONE of the decompose extras -------
fc_child_footer rollout 900 2 4 "#901 (hard), #902 (hard)" "$DEP2" "$CONTRACT_TEXT" > "$T/roll-2.txt"
fc_child_footer rollout 900 1 4 "" "$DEP2" "$CONTRACT_TEXT" > "$T/roll-1.txt"
[ "$(wc -l < "$T/roll-2.txt")" -eq 5 ] \
  && ok || bad "a blocked rollout wave is exactly 5 lines: $(cat "$T/roll-2.txt")"
[ "$(wc -l < "$T/roll-1.txt")" -eq 4 ] \
  && ok || bad "an unblocked rollout wave is exactly 4 lines: $(cat "$T/roll-1.txt")"
[ "$(head -1 "$T/roll-2.txt")" = '---' ] \
  && ok || bad "the footer opens with the --- rule: $(cat "$T/roll-2.txt")"
grep -qx 'Part of #900' "$T/roll-2.txt" && ok || bad "rollout: Part of line: $(cat "$T/roll-2.txt")"
grep -qx 'Order: 2 of 4' "$T/roll-2.txt" && ok || bad "rollout: Order line: $(cat "$T/roll-2.txt")"
grep -qx 'Blocked-by: #901 (hard), #902 (hard)' "$T/roll-2.txt" \
  && ok || bad "rollout: the blocker string is passed in composed, verbatim: $(cat "$T/roll-2.txt")"
grep -qx 'Rollout wave 2 of 4: planned by its author; the PLAN stage fleshes it out. Never split into a rollout again.' "$T/roll-2.txt" \
  && ok || bad "rollout: the wave sentence: $(cat "$T/roll-2.txt")"
grep -qi 'blocked-by' "$T/roll-1.txt" \
  && bad "a wave with no after list carries no Blocked-by line: $(cat "$T/roll-1.txt")" || ok
# The depends and contract arguments were non-empty above ON PURPOSE: a rollout
# wave must ignore them, not render them.
for ABSENT in 'CONTRACT:' 'DEPENDS:' 'Size budget:' 'Split child (depth 1)' 'You do not wait'; do
  grep -qF "$ABSENT" "$T/roll-2.txt" \
    && bad "a rollout wave must not carry '$ABSENT': $(cat "$T/roll-2.txt")" || ok
done

# --- the Blocked-by line this footer writes is one the REAL launcher reads ---
# An assertion about a regex next to the regex proves nothing:
# bin/unblocked-children.sh is what actually launches a child.
mkdir -p "$T/gh"
cat > "$T/gh/gh" <<'SH'
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" post "$@" && exit 0
#!/bin/bash
cat "$ISSUES_JSON"
SH
chmod +x "$T/gh/gh"
RB=$(jq -Rs . < "$T/roll-2.txt")
unblocked_with() { # unblocked_with <state-of-902>
  jq -nc --argjson b "$RB" --arg s "$1" '[
    {"number":901,"state":"CLOSED","title":"AB-9.1: wave one","body":"Part of #900"},
    {"number":902,"state":$s,"title":"AB-9.2: wave two","body":"Part of #900"},
    {"number":999,"state":"OPEN","title":"AB-9.3: wave three","body":$b}
  ]' > "$T/issues.json"
mkdir -p "$T/h/bin/lib"; cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"
  PATH="$T/gh:$PATH" ISSUES_JSON="$T/issues.json" HARNESS="$T/h" GH_ISSUES_REPO="example-org/scoutish" \
    "$DIR/bin/unblocked-children.sh" scoutish \
    <<<'board issues: CHANGED 901 "AB-9.1" (state: OPEN -> CLOSED)' 2>/dev/null
}
UNB=$(unblocked_with CLOSED)
grep -q 'UNBLOCKED 999 ' <<<"$UNB" \
  && ok || bad "with both blockers closed the real launcher must release the wave (got: '$UNB')"
UNB=$(unblocked_with OPEN)
grep -q 'UNBLOCKED 999 ' <<<"$UNB" \
  && bad "the SECOND #n on the line must be read too — 902 is open (got: '$UNB')" || ok

# ===========================================================================
# A5 — fc_child_title
# ===========================================================================
# `\([^ ]*\)`, not `\(.\)`: the dash is a 3-byte em dash and a single-char `.`
# cannot match it byte-wise, so a `.` here makes this suite locale-dependent —
# green under a UTF-8 locale and red under the C locale that
# bin/run-tests-in-docker.sh runs with. A gate that only fails on the machine
# people run it on teaches them to stop reading the failing list.
# The dash is read out of the file that WRITES the title. Until BH-982 that was
# the inline `CT="$KEY.0: contract — $TITLE"` in bin/run-decompose.sh; that line
# has moved behind fc_child_title, so this reads the printf below it.
EMDASH=$(sed -n "s/.*printf '%s\.0: contract \([^ ]*\) %s\\\\n'.*/\1/p" "$LIB" | head -1)
[ -n "$EMDASH" ] && ok || bad "could not read the contract-title dash out of bin/lib/file-children.sh"
[ "$(fc_child_title decompose TK-552 0 'metrics table')" = "TK-552.0: contract $EMDASH metrics table" ] \
  && ok || bad "decompose i=0 is the contract title with the real em dash: $(fc_child_title decompose TK-552 0 'metrics table')"
[ "$(fc_child_title decompose TK-552 2 'dashboard tile')" = 'TK-552.2: dashboard tile' ] \
  && ok || bad "decompose i>0: $(fc_child_title decompose TK-552 2 'dashboard tile')"
[ "$(fc_child_title rollout AB-7 0 'schema')" = 'AB-7.1: schema' ] \
  && ok || bad "rollout waves start at .1: $(fc_child_title rollout AB-7 0 'schema')"
# The same title the REAL decomposer prints for the same child.
grep -qF "$(fc_child_title decompose TK-552 0 'metrics table + read API')" "$T/b/decompose-gh.log" \
  && ok || bad "the contract title must match what bin/run-decompose.sh files: $(grep -m1 'issue create' "$T/b/decompose-gh.log")"
grep -qF "$(fc_child_title decompose TK-552 2 'weekly digest email')" "$T/b/decompose-gh.log" \
  && ok || bad "the sibling title must match what bin/run-decompose.sh files"
I=0; ZERO=0
while [ "$I" -le 11 ]; do
  case "$(fc_child_title rollout AB-7 "$I" x)" in *.0:*) ZERO=1 ;; esac
  I=$((I + 1))
done
[ "$ZERO" = 0 ] && ok || bad "a rollout wave must never be reachable as .0"

# ===========================================================================
# A6 — fc_strip_fences / fc_has_rollout, the classifier that arms a filing run
# ===========================================================================
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

rollout_rc() { printf '%s\n' "$1" | fc_has_rollout; printf '%s' "$?"; }
neg() { [ "$(rollout_rc "$1")" != 0 ] && ok || bad "must NOT arm the rollout lane: $2"; }
pos() { [ "$(rollout_rc "$1")" = 0 ]  && ok || bad "must arm the rollout lane: $2"; }

# 1. the real-world case: issue #816's own body documents the convention inside
#    a ``` fence. A detector that reads through the fence files issues nobody
#    asked for, on somebody else's repo, under our App identity.
if fc_has_rollout < "$T/816-body.md"; then
  bad "issue #816's own body is FENCED — it must not arm the lane"
else ok; fi
grep -qx '## Rollout' "$T/816-body.md" \
  && ok || bad "the #816 fixture lost its fenced '## Rollout' line — the negative is vacuous"

neg '```
## Rollout
```' 'a ``` fence'
neg '~~~
## Rollout
~~~' 'a ~~~ fence'
neg '<pre><code>
## Rollout
</code></pre>' '<pre><code> span'
neg '> ## Rollout' 'a blockquoted heading is a quoted spec, not a declaration'
neg '## Rollout risk' 'a heading with a suffix'
neg '## Rollout plan' 'a heading with a suffix'
neg 'We should do a rollout in waves.' 'the bare word in prose'
neg '### Rollout' 'h3 is the wave level, not the section level'
neg '##Rollout' 'no space after the hashes is not the heading'
neg '```
## Rollout' 'an unterminated fence swallows to EOF: a body we cannot parse must not arm an irreversible lane'
neg '' 'an empty body'
neg '
	' 'a whitespace-only body'
neg '```
~~~
## Rollout
~~~
```' 'a ~~~ inside a ``` fence does not close it'
# 11. the markdown code form that has no marker for fc_strip_fences to track:
#     an INDENTED code block. A body that documents the convention this way —
#     four spaces, no fence — is the same false positive the corpus exists to
#     prevent, and the detector must fail closed on it too.
neg '    ## Rollout
    ### Wave: one' 'a 4-space indented code block is code, not a heading'
neg 'intro

        ## Rollout' 'a deeper indented code block (8 spaces)'
neg '	## Rollout' 'a tab-indented code block'
neg '  	## Rollout' 'spaces then a tab in the leading run is still an indent'
# …and the three spaces markdown does allow on a real heading still arm it.
pos '   ## Rollout' 'three leading spaces is a legal markdown heading indent'

# 12. a fence is a MARKER AND A RUN LENGTH, not a marker. The natural way to
#     document "put your waves in a fence" is to wrap the example in a LONGER
#     fence — CommonMark closes a run only with a run of the same character at
#     least as long. Closing a 4-backtick fence on the inner 3-backtick line
#     reopens visibility inside the outer block, and the heading the author was
#     quoting arms the lane.
neg '````
text
```
## Rollout
```
````' 'a 3-backtick inner block must not close a 4-backtick outer fence'
neg '~~~~
```
## Rollout
```
~~~~' 'a ``` line must not close a ~~~~ fence'
pos '```
fenced
```
## Rollout' 'a same-length close still ends the fence, so the heading after it counts'
pos '`````
fenced
`````
## Rollout' 'a longer close ends the run it opened'

# 13. the HTML twin of the blockquote negative above. An in-app board stores
#     the quoted convention as <blockquote><h2>…</h2></blockquote>, and the
#     markdown '> <h2>Rollout</h2>' reaches the tag pass with its '>' intact.
#     '> ## Rollout' is already a committed negative; the same sentence written
#     for a board that stores HTML must answer the same way.
neg '<blockquote><h2>Rollout</h2></blockquote>' 'a blockquoted HTML heading is a quoted spec, not a declaration'
neg '<blockquote>
<h2>Rollout</h2>
</blockquote>' 'a multi-line <blockquote> span is dropped whole'
neg '> <h2>Rollout</h2>' 'a markdown blockquote carrying an HTML heading'
pos 'text
<blockquote><h2>Rollout</h2></blockquote>
<h2>Rollout</h2>' 'the blockquote closes: a real HTML heading after it still arms'

# 14. CRLF. Cheap insurance, not a shape seen in the wild (429 real bodies
#     across the fleet's repos carry zero \r) — but a web editor that ever
#     writes one must not silently turn a real rollout master into an ordinary
#     ticket, and \r must not sneak past the fence and indent guards either.
pos "$(printf '## Rollout\r')" 'a CRLF heading line still arms the lane'
CRLF_FENCE=$(printf '```\r\n## Rollout\r\n```\r')
neg "$CRLF_FENCE" 'a CRLF fence still hides the heading inside it'
neg "$(printf '    ## Rollout\r')" 'a CRLF indented code block is still code'

# 15. CommonMark's closing sequence. '## Rollout ##' renders as the heading
#     "Rollout", so this is a DELIBERATE false negative, pinned here so the
#     decision is a committed one rather than an accident of the regex: the
#     detector's contract is that every uncertain shape answers no, and a
#     missed rollout master is recoverable (it is planned as an ordinary
#     ticket, which is today's behaviour) where a false positive files N
#     issues on a client repo with no plan stage.
neg '## Rollout ##' 'a CommonMark closing sequence is deliberately not the heading we arm on'

pos '## Rollout' 'the bare heading'
pos '## rollout' 'case-insensitive (lower)'
pos '## ROLLOUT' 'case-insensitive (upper)'
pos '##  Rollout  ' 'trimmed'
pos '<h2>Rollout</h2>' 'the HTML heading an in-app board stores'
pos 'intro
```
## Rollout
```
## Rollout
### Wave: one' 'a CLOSED fence does not hide the real heading that follows it'
pos 'Some text

## Rollout

### Wave: one
after: none' 'the shape a rollout master really has'

# fc_strip_fences, all four stages, in order, byte-compared.
printf '%s\n' 'intro' '```text' '## Rollout' '```' '<pre>## Rollout</pre>' \
  '<h2>Heading two</h2>' '<h3>Heading three</h3>' '<p>tail <b>text</b></p>' 'done' > "$T/mixed.md"
printf '%s\n' 'intro' '' '## Heading two' '' '### Heading three' '' 'tail text' 'done' > "$T/mixed-want.txt"
fc_strip_fences < "$T/mixed.md" > "$T/mixed-got.txt"
if diff -u "$T/mixed-want.txt" "$T/mixed-got.txt" > "$T/mixed-diff.txt" 2>&1; then ok
else bad "fc_strip_fences output drifted:
$(cat "$T/mixed-diff.txt")"; fi

# ===========================================================================
# A7 — fc_board_base: the registry's column 4, never a hardcoded /api/board
# ===========================================================================
TOKEN='sk-fixture-3f9c2b-do-not-log'
cat > "$T/h/env/ledger-os.env" <<ENVF
LEDGER_INTERNAL_API_TOKEN=$TOKEN
LEDGER_API_BASE=https://ar.example
ENVF
cat > "$T/h/env/scoutish.env" <<'ENVF'
SCOUTISH_API_BASE=https://scoutish.example
ENVF
base_of() { # base_of <project> [VAR=val ...]
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" "${@:2}" \
      bash -c 'set -u; . "$1"; fc_board_base "$2"' _ "$LIB" "$1"
}
GOT=$(base_of ledger-os 2>"$T/base.err"); RC=$?
{ [ "$RC" -eq 0 ] && [ "$GOT" = 'https://ar.example/api/accounting/requests-board' ]; } \
  && ok || bad "the base must come from the env file + fleet.conf column 4 (rc=$RC, got '$GOT')"
GOT=$(base_of ledger-os LEDGER_API_BASE=https://exported.example)
[ "$GOT" = 'https://exported.example/api/accounting/requests-board' ] \
  && ok || bad "an exported *_API_BASE wins over the file literal (got '$GOT')"
GOT=$(base_of ledger-os LEDGER_API_BASE=https://exported.example/)
[ "$GOT" = 'https://exported.example/api/accounting/requests-board' ] \
  && ok || bad "a trailing slash must not double in the join (got '$GOT')"
printf 'LEDGER_API_BASE="https://quoted.example/"\n' > "$T/h/env/ledger-os.env"
GOT=$(base_of ledger-os)
[ "$GOT" = 'https://quoted.example/api/accounting/requests-board' ] \
  && ok || bad "a quoted value in the env file is unquoted before the join (got '$GOT')"
# BH-1955: the base variable is bin/lib/internal-token.sh's answer — a digit
# prefix and *_APP_BASE resolve, `export` is stripped, two bases refuse.
printf 'project-32_APP_BASE=https://o2.example\n' > "$T/h/env/ledger-os.env"
GOT=$(base_of ledger-os)
[ "$GOT" = 'https://o2.example/api/accounting/requests-board' ] \
  && ok || bad "a digit-prefixed *_APP_BASE must resolve (got '$GOT')"
printf 'export LEDGER_APP_BASE=https://ex.example\n' > "$T/h/env/ledger-os.env"
GOT=$(base_of ledger-os)
[ "$GOT" = 'https://ex.example/api/accounting/requests-board' ] \
  && ok || bad "an exported *_APP_BASE line must resolve (got '$GOT')"
printf 'VENDOR_API_BASE=https://vendor.example\nLEDGER_APP_BASE=https://ar.example\n' > "$T/h/env/ledger-os.env"
GOT=$(base_of ledger-os); RC=$?
{ [ "$RC" -ne 0 ] && [ -z "$GOT" ]; } \
  && ok || bad "two base variables must print nothing and fail, never pick the first (rc=$RC, got '$GOT')"
# Fails CLOSED: an empty base concatenated into a URL is a request to the wrong
# host, not an error anyone sees.
GOT=$(base_of scoutish); RC=$?
{ [ "$RC" -ne 0 ] && [ -z "$GOT" ]; } \
  && ok || bad "a '-' prefix (the GitHub-Issues lane) must print nothing and fail (rc=$RC, got '$GOT')"
GOT=$(base_of no-such-project); RC=$?
{ [ "$RC" -ne 0 ] && [ -z "$GOT" ]; } \
  && ok || bad "an unknown project must print nothing and fail (rc=$RC, got '$GOT')"
# NO SECRET, ANYWHERE. The env file holds tokens; this function touches one
# variable, prints one URL, and logs nothing.
cat > "$T/h/env/ledger-os.env" <<ENVF
LEDGER_INTERNAL_API_TOKEN=$TOKEN
LEDGER_API_BASE=https://ar.example
ENVF
mkdir -p "$T/bb"; printf 'pre-existing\n' > "$T/bb/pipeline.log"
BEFORE_LOG=$(cat "$T/bb/pipeline.log")
STREAMS=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" FC_BUILD="$T/bb" \
           bash -c 'set -u; . "$1"; fc_board_base ledger-os' _ "$LIB" 2>&1 )
grep -qF "$TOKEN" <<<"$STREAMS" \
  && bad "fc_board_base leaked a token into its own streams" || ok
grep -qF "$TOKEN" "$T/bb/pipeline.log" \
  && bad "fc_board_base leaked a token into the pipeline log" || ok
[ "$(cat "$T/bb/pipeline.log")" = "$BEFORE_LOG" ] \
  && ok || bad "fc_board_base must log nothing at all: $(cat "$T/bb/pipeline.log")"

# ===========================================================================
# A8 — file_children: lane resolution, module sourcing, dispatch, rc 2 and rc 3
# ===========================================================================
mkdir -p "$T/fcb"
: > "$T/fcb/pipeline.log"
printf '[]\n' > "$T/fcb/children.json"
# A COPY OF THE LIBRARY WITH NO LANE MODULE BESIDE IT. bin/lib/fc-issues.sh
# ships next to the real one since BH-982, and file_children sources whatever
# module sits beside the file it was sourced from, so the drives below — the
# rc 3 fall-through and the caller-defined stub — need a directory that has the
# contract and nothing else in it. What they assert is unchanged.
# It keeps the bin/lib shape, because file_children resolves fleet-conf.sh at
# `<its own dir>/../fleet-conf.sh` before it falls back to $HARNESS.
mkdir -p "$T/bare/bin/lib"; cp "$LIB" "$T/bare/bin/lib/file-children.sh"
cp "$DIR/bin/fleet-conf.sh" "$T/bare/bin/"
BARE="$T/bare/bin/lib/file-children.sh"
# No lane module anywhere: the rc that makes every sibling filing slice
# shippable on its own, and it is never silent.
RC=0
( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" \
      bash -c 'set -u; . "$1"; file_children scoutish 552 TK-552 "$2" "$2/children.json"' \
      _ "$BARE" "$T/fcb" ) || RC=$?
[ "$RC" -eq 3 ] && ok || bad "no lane module must answer 3, not silence (rc=$RC)"
[ "$(grep -c 'FILE_CHILDREN_UNIMPLEMENTED issues' "$T/fcb/pipeline.log")" -eq 1 ] \
  && ok || bad "rc 3 is paired with exactly one log line: $(cat "$T/fcb/pipeline.log")"
# The in-app row resolves to the board lane.
: > "$T/fcb/pipeline.log"
RC=0
( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" \
      bash -c 'set -u; . "$1"; file_children ledger-os tkt-1 LG-9 "$2" "$2/children.json"' \
      _ "$BARE" "$T/fcb" ) || RC=$?
{ [ "$RC" -eq 3 ] && grep -q 'FILE_CHILDREN_UNIMPLEMENTED board' "$T/fcb/pipeline.log"; } \
  && ok || bad "a real board prefix is the board lane (rc=$RC): $(cat "$T/fcb/pipeline.log")"

# The module beside the library wins; the $HARNESS/bin/lib copy is the fallback.
mkdir -p "$T/own" "$T/plain" "$T/h/bin/lib"
cp "$LIB" "$T/own/file-children.sh"; cp "$LIB" "$T/plain/file-children.sh"
cat > "$T/own/fc-issues.sh" <<'SH'
fc_file_issues() { printf 'beside-the-lib %s %s\n' "$FC_LANE" "$FC_KIND" > "$FC_BUILD/who.txt"; return 0; }
SH
cat > "$T/h/bin/lib/fc-issues.sh" <<'SH'
fc_file_issues() { printf 'harness-fallback %s %s\n' "$FC_LANE" "$FC_KIND" > "$FC_BUILD/who.txt"; return 0; }
SH
rm -f "$T/fcb/who.txt"
( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" \
      bash -c 'set -u; . "$1"; file_children scoutish 552 TK-552 "$2" "$2/children.json"' \
      _ "$T/own/file-children.sh" "$T/fcb" ) && ok || bad "a lane module beside the library must dispatch"
[ "$(cat "$T/fcb/who.txt" 2>/dev/null)" = 'beside-the-lib issues decompose' ] \
  && ok || bad "the module beside the library wins: $(cat "$T/fcb/who.txt" 2>/dev/null)"
rm -f "$T/fcb/who.txt"
( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" \
      bash -c 'set -u; . "$1"; file_children scoutish 552 TK-552 "$2" "$2/children.json" --kind rollout' \
      _ "$T/plain/file-children.sh" "$T/fcb" ) && ok || bad "the \$HARNESS/bin/lib fallback must dispatch"
[ "$(cat "$T/fcb/who.txt" 2>/dev/null)" = 'harness-fallback issues rollout' ] \
  && ok || bad "the fallback module ran and --kind rollout reached it: $(cat "$T/fcb/who.txt" 2>/dev/null)"

# A stub defined by the CALLER is dispatched to, exactly once, with all seven
# FC_* readable inside it. $T/h2 is a harness with no lane module in it and
# $BARE has none beside it, so the only definition in play is the caller's.
mkdir -p "$T/h2"
cat > "$T/fcb/stub-drive.sh" <<'SH'
set -u
. "$1"
fc_file_issues() {
  printf '%s\n' "$FC_PROJECT" "$FC_PARENT" "$FC_KEY" "$FC_BUILD" "$FC_SPEC" "$FC_KIND" "$FC_LANE" >> "$FC_BUILD/seen.txt"
  printf 'called\n' >> "$FC_BUILD/calls.txt"
  return 0
}
file_children scoutish 552 TK-552 "$2" "$2/children.json"
rc=$?
env | grep -c '^FC_' > "$2/exported.txt"
exit $rc
SH
rm -f "$T/fcb/seen.txt" "$T/fcb/calls.txt"
( env HARNESS="$T/h2" FLEET_CONF="$T/h/fleet.conf" \
      bash "$T/fcb/stub-drive.sh" "$BARE" "$T/fcb" ) && ok || bad "a caller-defined stub must be dispatched to"
[ "$(wc -l < "$T/fcb/calls.txt" 2>/dev/null)" = 1 ] \
  && ok || bad "the lane function is called exactly once (got $(cat "$T/fcb/calls.txt" 2>/dev/null))"
WANT_FC=$(printf '%s\n' scoutish 552 TK-552 "$T/fcb" "$T/fcb/children.json" decompose issues)
[ "$(cat "$T/fcb/seen.txt" 2>/dev/null)" = "$WANT_FC" ] \
  && ok || bad "all seven FC_* must be set for the lane module: $(cat "$T/fcb/seen.txt" 2>/dev/null)"
[ "$(cat "$T/fcb/exported.txt" 2>/dev/null)" = 0 ] \
  && ok || bad "nothing is exported: a child process sees $(cat "$T/fcb/exported.txt" 2>/dev/null) FC_ variables"

# A bad --kind is a usage error, and it dispatches NOTHING.
rm -f "$T/fcb/calls.txt"
: > "$T/fcb/pipeline.log"
cat > "$T/fcb/bad-kind.sh" <<'SH'
set -u
. "$1"
fc_file_issues() { printf 'called\n' >> "$FC_BUILD/calls.txt"; return 0; }
file_children scoutish 552 TK-552 "$2" "$2/children.json" --kind nonsense
SH
RC=0
( env HARNESS="$T/h2" FLEET_CONF="$T/h/fleet.conf" bash "$T/fcb/bad-kind.sh" "$LIB" "$T/fcb" ) || RC=$?
[ "$RC" -eq 2 ] && ok || bad "a bad --kind is a usage error, rc 2 (got $RC)"
[ -e "$T/fcb/calls.txt" ] && bad "a bad --kind must dispatch nothing" || ok
[ "$(wc -l < "$T/fcb/pipeline.log")" -eq 1 ] \
  && ok || bad "a refused --kind says so, once: $(cat "$T/fcb/pipeline.log")"
# Too few positionals is the same usage error.
RC=0
( env HARNESS="$T/h2" FLEET_CONF="$T/h/fleet.conf" \
      bash -c 'set -u; . "$1"; file_children scoutish 552' _ "$LIB" ) || RC=$?
[ "$RC" -eq 2 ] && ok || bad "a short call is a usage error, rc 2 (got $RC)"

# ===========================================================================
# A9/A10/A11 — the lints, the no-caller claim, and the untouched files
# ===========================================================================
if [ -x "$DIR/bin/test-determinism-lint.sh" ]; then
  DL=$("$DIR/bin/test-determinism-lint.sh" "$DIR/tests/file-children.bh-981-test.sh" 2>&1) \
    && ok || bad "this suite must pass the determinism lint: $DL"
else
  echo "note: bin/test-determinism-lint.sh absent — the A9 assertion did not run"
fi
# This suite is this TICKET's own file, per the repo's test-home rule — nothing
# was appended to tests/run-decompose-issues-test.sh, which a sibling slice will
# be editing at the same hour.
# shellcheck source=bin/lib/test-home-lib.sh
. "$DIR/bin/lib/test-home-lib.sh" 2>/dev/null
if command -v th_is_own >/dev/null 2>&1; then
  th_is_own tests/file-children.bh-981-test.sh BH-981 \
    && ok || bad "this suite must be recognised as BH-981's own test file"
  [ "$(th_per_ticket_path tests/file-children-test.sh BH-981)" = 'tests/file-children.bh-981-test.sh' ] \
    && ok || bad "the file name must be the one th_per_ticket_path produces"
else
  echo "note: bin/lib/test-home-lib.sh absent — the test-home assertions did not run"
fi
# WHO IS ALLOWED TO REACH THE CONTRACT. BH-981 shipped it with no caller at
# all. BH-982 wires the issues lane: bin/lib/fc-issues.sh (the lane module)
# and bin/run-decompose.sh (the one caller) are expected. BH-984 wires the
# rollout lane the same way, with bin/run-rollout.sh as its own caller and no
# lane-module indirection. Nothing ELSE may have grown a call: run-build.sh,
# the board module and the cron/fly entry points are still separate slices,
# and a call from one of them arriving early is what this assertion is for.
# A COMMENT IS NOT A CALLER (BH-985): a sibling slice that names this file in
# a code comment — "detection is delegated to bin/lib/file-children.sh" — was
# reported here as a caller, which is the matcher being wrong about what it
# claims to measure (bin/run-build.sh:1840 does exactly this on its own).
# BH-983 ships the board lane module, bin/lib/fc-board.sh, the one file_children dispatches to.
# BH-1955 sources the file from bin/file-health-ticket.sh for fc_board_base
# ONLY (the board URL resolver the ticket names), never the filer; the second
# grep below pins that it calls nothing else from here.
# BH-5961 adds bin/lib/slice-remainder.sh: it files the remaining slices of a
# merged SLICE plan through fc_file_issues (kind slice), never file_children,
# so the board lane cannot receive that kind.
# BH-6308 adds bin/lib/slice-closeout.sh for the same reason: it files ONE
# "rest of" child through fc_file_issues (kind slice), never file_children.
CALLERS=$(cd "$DIR" && grep -rn 'file-children\.sh\|file_children\|fc_[a-z_]*(' bin/ fly/ cron/ --include='*.sh' 2>/dev/null \
          | grep -vE '^bin/lib/file-children\.sh:|^bin/lib/fc-issues\.sh:|^bin/lib/fc-board\.sh:|^bin/run-decompose\.sh:|^bin/run-rollout\.sh:|^bin/file-health-ticket\.sh:|^bin/lib/slice-remainder\.sh:|^bin/lib/slice-closeout\.sh:' \
          | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
[ -z "$CALLERS" ] && ok || bad "only bin/run-decompose.sh (+ its lane module) and bin/run-rollout.sh may call the filer (found):
$CALLERS"
FHT=$(cd "$DIR" && grep -nE 'file_children|fc_[a-z_]+' bin/file-health-ticket.sh 2>/dev/null \
      | grep -vE '^[0-9]+:[[:space:]]*#' | grep -oE 'file_children|fc_[a-z_]+' | grep -vx 'fc_board_base')
[ -z "$FHT" ] && ok || bad "bin/file-health-ticket.sh may use fc_board_base from this file and nothing else (found): $FHT"
# ...and THIS SLICE opens none of the five files the ticket names.
BASE=$(cd "$DIR" && git merge-base origin/main HEAD 2>/dev/null || git merge-base main HEAD 2>/dev/null)
# This arm judges BH-981's OWN slice; on any other branch (one that edits
# bin/run-build.sh for its own ticket) it must stay inert, so it bites only when
# the diff touches the ticket's spec. (2026-09-21: #727 went red here for
# touching bin/triage-gate.sh on BH-590. 2026-09-24: BH-1955 touched the lib for
# fc_board_base AND triage-gate/run-build for its own items; the lib is shared
# now, so touching it no longer says "this is BH-981's slice".)
if [ -n "$BASE" ]; then
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-981's own slice
  TOUCHED=$(cd "$DIR" && git diff --name-only "$BASE"...HEAD 2>/dev/null; cd "$DIR" && git diff --name-only 2>/dev/null)
  if ! grep -qE '^\.harness/specs/BH-981/' <<<"$(printf '%s\n' "$TOUCHED")"; then
    echo "note: this branch is not BH-981's slice — the A11 untouched-files arm judges only the ticket's own branch"
  else
  # run-decompose.sh came off this list with BH-982, whose whole job is to move
  # the filing loop out of it. The other four still belong to sibling slices.
  FORBIDDEN=$(printf '%s\n' "$TOUCHED" | grep -xE 'bin/(run-build|triage-gate|run-triage|decompose-parent-close)\.sh')
  [ -z "$FORBIDDEN" ] && ok || bad "the ticket forbids touching these, and this branch does:
$FORBIDDEN"
  fi
else
  echo "note: no merge base against main — the A11 untouched-files assertion did not run"
fi

echo "file-children.bh-981: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
