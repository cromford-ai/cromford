#!/bin/bash
# tests/plan-collisions.bh-5791-test.sh — the design-collision check at PLAN
# (BH-5791): a plan names the symbols it changes, and the build checks main
# since the plan's base and every open PR for changes to the same symbols.
#
# HOW IT DRIVES. A scratch git repo with a local bare origin. Main branches and
# refs/pull/<n>/head refs are pushed into the origin, and a stub `gh` answers
# the REST open-PR list. The C cases run the real "$DIR/bin/plan-collisions.sh"
# and the real "$DIR/bin/lib/plan-collisions.sh" from a scratch_install_closure
# tree. The G cases lift the `design collisions (BH-5791)` block VERBATIM out of
# the flattened pipeline (tests/lib/rb-all.sh) and run it with a CC stub that
# records each repair prompt. C10 lifts both `changed symbols note` blocks, from
# the pipeline and from "$DIR/bin/run-preplan.sh".
#
#   C1-C10  the lib, the CLI and the planner note
#   G1-G7   the gate block in the plan stage
# Run: HARNESS_TEST_SANDBOX=1 bash tests/plan-collisions.bh-5791-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "could not flatten the pipeline"; exit 1; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$T/fakebin" "$T/calls" "$T/build"
scratch_install_closure bin/plan-collisions.sh "$H" >/dev/null || bad "C0: closure install failed for bin/plan-collisions.sh"
scratch_install_closure bin/plan-gate.sh "$H" >/dev/null || bad "C0: closure install failed for bin/plan-gate.sh"
scratch_install_closure bin/planned-files.sh "$H" >/dev/null || bad "C0: closure install failed for bin/planned-files.sh"

# The stub gh: one line per call, and the REST envelope gh_rest reads. In
# GH_MODE=down it prints nothing, which gh_rest answers as rc 75.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$CALLS/gh"
[ "${GH_MODE:-ok}" = down ] && exit 1
printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n'
cat "$PULLS"
SH
chmod +x "$T/fakebin/gh"
export CALLS="$T/calls" PULLS="$T/pulls.json" GH_ETAG=0 HARNESS="$H"
cnt() { if [ -f "$CALLS/$1" ]; then wc -l < "$CALLS/$1" | tr -d ' '; else echo 0; fi; }

# ── the git fixture ──────────────────────────────────────────────────────────
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false "$@"; }
O="$T/origin.git"; R="$T/repo"
git init -q --bare -b main "$O"
git init -q -b main "$R"
cd "$R" || exit 1
git remote add origin "$O"
mkdir -p lib
cat > lib/flags.sh <<'SH'
#!/bin/bash
flag_active() { # flag_active <name>
  [ -e "$FLAGS/$1" ]
}
flag_set() { # flag_set <name>
  touch "$FLAGS/$1"
}
SH
cat > lib/api.js <<'JS'
export function handle(req) {
  if (req.route === 'GET /api/flags') return 1;
  return 0;
}
JS
G add -A && G commit -qm "base" && G push -q origin main 2>/dev/null
BASE_SHA=$(git rev-parse HEAD)
# branch <name> <sed-expr> <file> : a commit on top of the base, pushed as <name>
branch() {
  G checkout -q -B "$1" "$BASE_SHA"
  sed -i "$2" "$3"
  G commit -qam "$1 change"
  G push -q -f origin "$1" 2>/dev/null
}
branch m-body  's/\[ -e "\$FLAGS\/\$1" \]/[ -f "$FLAGS\/$1" ]/' lib/flags.sh
MBODY_SHA=$(git rev-parse --short=12 HEAD)
branch m-other 's/touch "\$FLAGS/: > "$FLAGS/' lib/flags.sh
G checkout -q -B m-gone "$BASE_SHA"
printf '#!/bin/bash\nflag_set() { # flag_set <name>\n  touch "$FLAGS/$1"\n}\n' > lib/flags.sh
G commit -qam "m-gone change" && G push -q -f origin m-gone 2>/dev/null
MGONE_SHA=$(git rev-parse --short=12 HEAD)
# pr <n> <sed-expr> <file> : refs/pull/<n>/head in the origin
pr() {
  G checkout -q -B "pr$1" "$BASE_SHA"
  sed -i "$2" "$3"
  G commit -qam "pr $1 change"
  G push -q -f origin "pr$1:refs/pull/$1/head" 2>/dev/null
  git rev-parse --short=12 HEAD > "$T/pr$1.sha"
}
pr 7  's/\[ -e /[ -L /' lib/flags.sh
pr 8  "s/'GET \/api\/flags') return 1/'GET \/api\/flags') return 2/" lib/api.js
pr 9  's/\[ -e /[ -s /' lib/flags.sh
pr 10 's/\[ -e /[ -r /' lib/flags.sh
pr 11 's/\[ -e /[ -w /' lib/flags.sh
pr 12 's/\[ -e /[ -x /' lib/flags.sh
pr 13 's/\[ -e /[ -O /' lib/flags.sh
# m-plans / m-code (review of 5af55a47): another ticket's plan.md and a docs
# note that only MENTION a verb; a code file that uses it (and a format name
# with an unbalanced "(").
G checkout -q -B m-plans "$BASE_SHA"
mkdir -p .harness/specs/BH-9 docs/notes
printf 'verb `flags-cli.sh`: a new verb.\n' > .harness/specs/BH-9/plan.md
printf 'See flags-cli.sh.\n' > docs/notes/2026-10-12-x.md
G add -A && G commit -qm "m-plans change" && G push -q -f origin m-plans 2>/dev/null
G checkout -q -B m-code "$BASE_SHA"
printf '#!/bin/bash\n# calls flags-cli.sh\n## Foo (BH-1\n' > lib/cli.sh
G add -A && G commit -qm "m-code change" && G push -q -f origin m-code 2>/dev/null
MCODE_SHA=$(git rev-parse --short=12 HEAD)
G checkout -q -B ticket/bh-5791 "$BASE_SHA"
G fetch -q origin 2>/dev/null
cat > "$PULLS" <<'JSON'
[{"number":7,"title":"BH-1: flags","head":{"ref":"feature-x"}},
 {"number":8,"title":"BH-2: api","head":{"ref":"feature-y"}},
 {"number":9,"title":"self branch","head":{"ref":"custom-self"}},
 {"number":10,"title":"BH-5791: an earlier attempt","head":{"ref":"other-ref"}},
 {"number":11,"title":"the stack parent","head":{"ref":"stack-parent"}},
 {"number":12,"title":"a retry","head":{"ref":"ticket/bh-5791-r2"}},
 {"number":13,"title":"the first attempt","head":{"ref":"ticket/bh-5791"}}]
JSON

# plan_with <file> <changed-symbols body or -> [design-collisions body]
plan_with() {
  {
    printf '# BH-5791 fixture plan\n\n## Scope\n\nChange the flag check. Edit `lib/flags.sh`.\n\n'
    printf '### Task 1: change the flag check\n- VALIDATE: `bash tests/flags-test.sh` passes.\n- SATISFIES: "the flag check is strict"\n\n'
    [ "$2" = - ] || printf '## Changed symbols\n\n%s\n\n' "$2"
    [ -z "${3:-}" ] || printf '## Design collisions\n\n%s\n\n' "$3"
    printf '## Acceptance tests\n\n- `tests/flags-test.sh` asserts the strict check.\n\n## QA screens\n\nNone.\n\n## Size\n\nFILES: 1\nLINES: 5\n\nKIND: infra\nSIZE: S\n'
  } > "$1"
}
LISTED='- function `flag_active`: the check becomes strict.'

# pc <plan> <main-ref> : run the CLI; OUT, RC, $T/col.txt
pc() {
  local p="$1" m="$2"
  OUT=$(cd "$R" && PATH="$T/fakebin:$PATH" "$H/bin/plan-collisions.sh" --plan "$p" --repo "$R" \
        --base "$BASE_SHA" --main "$m" --slug o/r --self-branch custom-self --self-key BH-5791 \
        --stack-base stack-parent --out "$T/col.txt" 2>"$T/pc.err"); RC=$?
}
TAB=$'\t'
row() { grep -qF "$1" "$T/col.txt" 2>/dev/null; }

# ============================================================================
# C. the lib and the CLI
# ============================================================================
lib() { bash -c '. "$HARNESS/bin/lib/plan-collisions.sh" || exit 9; "$@"' _ "$@"; }

# C1 pc_symbols
plan_with "$T/c1.md" '- function `flag_active`: stricter. callers: left alone: the arg is optional
- verb `flags-cli.sh`: a new verb.
- route `GET /api/flags`: answers 2.
- format `## Flag list`: a new section.
- not-a-kind `ignored`: dropped.'
S=$(lib pc_symbols "$T/c1.md" "$R" HEAD 2>/dev/null)
[ "$(printf '%s\n' "$S" | grep -c '^listed')" = 4 ] && ok || bad "C1: want 4 listed rows, got: $S"
grep -qxF "listed${TAB}function${TAB}flag_active${TAB}the arg is optional" <<<"$S" && ok || bad "C1: function row or its reason is wrong: $S"
grep -qxF "listed${TAB}verb${TAB}flags-cli.sh${TAB}" <<<"$S" && ok || bad "C1: verb row missing: $S"
grep -qxF "listed${TAB}route${TAB}GET /api/flags${TAB}" <<<"$S" && ok || bad "C1: route row missing: $S"
grep -qxF "listed${TAB}format${TAB}## Flag list${TAB}" <<<"$S" && ok || bad "C1: format row missing: $S"
plan_with "$T/c1n.md" 'None.'
S=$(lib pc_symbols "$T/c1n.md" "$R" HEAD 2>/dev/null)
[ -z "$S" ] && ok || bad "C1: a None section must give 0 rows, got: $S"
plan_with "$T/c1d.md" -
printf 'The plan touches `flag_set` and `no_such_function_here` and `ab`.\n' >> "$T/c1d.md"
S=$(lib pc_symbols "$T/c1d.md" "$R" HEAD 2>/dev/null)
[ "$S" = "derived${TAB}function${TAB}flag_set${TAB}" ] && ok || bad "C1: no section must derive exactly flag_set, got: $S"

# C2 (ACCEPTANCE 1): a merged change to the same function after the base
plan_with "$T/c2.md" "$LISTED"
PLAN_COLLISION_MAX_PRS=0 pc "$T/c2.md" origin/m-body
[ "$RC" = 1 ] && ok || bad "C2: the CLI must answer rc 1 on a collision (rc=$RC, $(cat "$T/pc.err"))"
row "COLLISION${TAB}listed${TAB}flag_active${TAB}main${TAB}${MBODY_SHA}" && ok || bad "C2: no main collision row for flag_active @$MBODY_SHA: $(cat "$T/col.txt" 2>/dev/null)"
case "$OUT" in COLLISIONS:*hits=1*) ok ;; *) bad "C2: summary line wrong: $OUT" ;; esac
lib pc_note "$T/c2.md" "$T/col.txt" 2>/dev/null
grep -q '^## Design collision check (BH-5791)$' "$T/c2.md" && ok || bad "C2: pc_note wrote no note"
grep -F '`flag_active`' "$T/c2.md" | grep -qF "main $MBODY_SHA" && ok || bad "C2: the note bullet must name flag_active and main $MBODY_SHA: $(sed -n '/Design collision check/,$p' "$T/c2.md")"
[ "$(tail -1 "$T/c2.md")" = "SIZE: S" ] && ok || bad "C2: the note must not move the SIZE line off the last line"

# C3: a main change to a DIFFERENT function in the same file
plan_with "$T/c3.md" "$LISTED"
PLAN_COLLISION_MAX_PRS=0 pc "$T/c3.md" origin/m-other
[ "$RC" = 0 ] && ! row "${TAB}flag_active${TAB}main${TAB}" && ok || bad "C3: a change to flag_set must not collide with flag_active (rc=$RC): $(cat "$T/col.txt")"

# C4: open PRs; our own PRs and the stack parent are skipped
plan_with "$T/c4.md" "$LISTED"
: > "$CALLS/gh"
pc "$T/c4.md" origin/main
row "COLLISION${TAB}listed${TAB}flag_active${TAB}#7${TAB}$(cat "$T/pr7.sha")" && ok || bad "C4: no #7 row: $(cat "$T/col.txt")"
for n in 9 10 11 12 13; do
  row "${TAB}#$n${TAB}" && bad "C4: PR #$n must be skipped (self or stack parent): $(cat "$T/col.txt")" || ok
done
grep -q '^OPEN_PRS: checked ' "$T/col.txt" && ok || bad "C4: OPEN_PRS state missing: $(cat "$T/col.txt")"
[ -z "$(git -C "$R" for-each-ref refs/collision-check/)" ] && ok || bad "C4: the fetched PR refs must be deleted"

# C5: a route changed in a PR is a text match
plan_with "$T/c5.md" '- route `GET /api/flags`: answers 2.'
pc "$T/c5.md" origin/main
grep -F "COLLISION${TAB}listed${TAB}GET /api/flags${TAB}#8${TAB}" "$T/col.txt" | grep -qF '(text match)' && ok || bad "C5: the route must hit #8 as a text match: $(cat "$T/col.txt")"

# C5b (review of 5af55a47): another ticket's plan.md and a docs note that only
# mention a verb are no collision; a code file that uses it is one.
H5=$(lib pc_hit "$R" "$BASE_SHA" origin/m-plans verb flags-cli.sh "on main")
[ -z "$H5" ] && ok || bad "C5b: a mention in .harness/specs/ or docs/ must not collide: '$H5'"
H5=$(lib pc_hit "$R" "$BASE_SHA" origin/m-code verb flags-cli.sh "on main")
[ "${H5%%"$TAB"*}" = "$MCODE_SHA" ] && ok || bad "C5b: a code change naming the verb must still collide @$MCODE_SHA: '$H5'"
# C5c: a name with an unbalanced "(" is escaped, not a git error read as no hit.
H5=$(lib pc_hit "$R" "$BASE_SHA" origin/m-code format '## Foo (BH-1' "on main")
[ "${H5%%"$TAB"*}" = "$MCODE_SHA" ] && ok || bad "C5c: format '## Foo (BH-1' must hit @$MCODE_SHA: '$H5'"

# C6: the definition was removed on main
plan_with "$T/c6.md" "$LISTED"
PLAN_COLLISION_MAX_PRS=0 pc "$T/c6.md" origin/m-gone
grep -F "COLLISION${TAB}listed${TAB}flag_active${TAB}main${TAB}${MGONE_SHA}" "$T/col.txt" | grep -qF 'removed or renamed on main' && ok || bad "C6: removed def must say so: $(cat "$T/col.txt")"

# C7: an unread PR list is never "no PRs"; MAX_PRS=0 is off with no gh call
plan_with "$T/c7.md" "$LISTED"
: > "$CALLS/gh"
GH_MODE=down pc "$T/c7.md" origin/m-body
grep -q '^OPEN_PRS: unread' "$T/col.txt" && ok || bad "C7: a down gh must read OPEN_PRS: unread: $(cat "$T/col.txt")"
row "COLLISION${TAB}listed${TAB}flag_active${TAB}main${TAB}" && ok || bad "C7: main hits must still be reported when PRs are unread"
case "$OUT" in *prs=unread*) ok ;; *) bad "C7: summary must say prs=unread: $OUT" ;; esac
lib pc_note "$T/c7.md" "$T/col.txt" 2>/dev/null
grep -q 'open PRs could not be read' "$T/c7.md" && ok || bad "C7: the note must say the open PRs could not be read"
: > "$CALLS/gh"
PLAN_COLLISION_MAX_PRS=0 pc "$T/c7.md" origin/m-body
grep -q '^OPEN_PRS: off$' "$T/col.txt" && [ "$(cnt gh)" = 0 ] && ok || bad "C7: MAX_PRS=0 must be off with no gh call (gh=$(cnt gh)): $(cat "$T/col.txt")"
# an unresolvable base is unread, never none
OUT=$(cd "$R" && PLAN_COLLISION_MAX_PRS=0 "$H/bin/plan-collisions.sh" --plan "$T/c7.md" --repo "$R" --base 0123456789abcdef0123456789abcdef01234567 \
      --main origin/m-body --slug o/r --self-branch b --self-key BH-5791 --out "$T/col.txt" 2>/dev/null); RC=$?
grep -q '^MAIN: unread' "$T/col.txt" && [ "$RC" = 0 ] && ok || bad "C7: a missing base object must be MAIN: unread (rc=$RC): $(cat "$T/col.txt")"

# C8: the note claims no file and adds no untraced task
plan_with "$T/build/plan.md" "$LISTED"
PLAN_COLLISION_MAX_PRS=0 pc "$T/build/plan.md" origin/m-body
"$H/bin/planned-files.sh" "$T/build"; cp "$T/build/planned-files.txt" "$T/pf.before"
"$H/bin/plan-gate.sh" "$T/build/plan.md" > "$T/pg.before" 2>&1
lib pc_note "$T/build/plan.md" "$T/col.txt" 2>/dev/null
grep -q '^## Design collision check' "$T/build/plan.md" && ok || bad "C8: no note to test"
"$H/bin/planned-files.sh" "$T/build"
cmp -s "$T/pf.before" "$T/build/planned-files.txt" && ok || bad "C8: the note changed the file claim: $(diff "$T/pf.before" "$T/build/planned-files.txt")"
"$H/bin/plan-gate.sh" "$T/build/plan.md" > "$T/pg.after" 2>&1
[ "$(grep -E '^PLAN_(TASKS|UNTRACED):' "$T/pg.before")" = "$(grep -E '^PLAN_(TASKS|UNTRACED):' "$T/pg.after")" ] \
  && grep -q '^PLAN_TASKS:' "$T/pg.after" && ok || bad "C8: the note changed the plan gate: $(diff "$T/pg.before" "$T/pg.after")"
grep -qE '(VALIDATE|SATISFIES):' <<<"$(sed -n '/^## Design collision check/,/^## Size/p' "$T/build/plan.md")" && bad "C8: the note must not carry VALIDATE/SATISFIES" || ok

# C9: the note step is idempotent
lib pc_note "$T/build/plan.md" "$T/col.txt" 2>/dev/null
[ "$(grep -c '^## Design collision check (BH-5791)$' "$T/build/plan.md")" = 1 ] && ok || bad "C9: two note runs must leave one heading"

# C10: the planner note blocks
awk 'index($0,"# >>> changed symbols note (BH-5791)")==1{f=1} f{print} index($0,"# <<< changed symbols note (BH-5791)")==1{exit}' "$RB" > "$T/note-rb.sh"
awk 'index($0,"# >>> changed symbols note (BH-5791)")==1{f=1} f{print} index($0,"# <<< changed symbols note (BH-5791)")==1{exit}' "$DIR/bin/run-preplan.sh" > "$T/note-pp.sh"
[ -s "$T/note-rb.sh" ] && [ -s "$T/note-pp.sh" ] && ok || bad "C10: could not lift both changed symbols note blocks"
V=$(HARNESS="$H" bash -c 'UI_PLAN_NOTE=""; . "$0"; printf "%s" "$UI_PLAN_NOTE"' "$T/note-rb.sh" 2>/dev/null)
case "$V" in *'## Changed symbols'*'## Design collisions'*) ok ;; *) bad "C10: the plan-stage note is missing its sections: $V" ;; esac
V=$(HARNESS="$H" bash -c 'PP_PREAMBLE=""; . "$0"; printf "%s" "$PP_PREAMBLE"' "$T/note-pp.sh" 2>/dev/null)
case "$V" in *'## Changed symbols'*'## Design collisions'*) ok ;; *) bad "C10: the pre-plan note is missing its sections: $V" ;; esac
mkdir -p "$T/nolib/bin/lib"
V=$(HARNESS="$T/nolib" bash -c 'UI_PLAN_NOTE="keep"; . "$0"; printf "%s" "$UI_PLAN_NOTE"' "$T/note-rb.sh" 2>/dev/null)
[ "$V" = keep ] && ok || bad "C10: no lib must leave UI_PLAN_NOTE unchanged, got: $V"
V=$(HARNESS="$T/nolib" bash -c 'PP_PREAMBLE="keep"; . "$0"; printf "%s" "$PP_PREAMBLE"' "$T/note-pp.sh" 2>/dev/null)
[ "$V" = keep ] && ok || bad "C10: no lib must leave PP_PREAMBLE unchanged, got: $V"
L_UI=$(grep -n '^# <<< untrusted input gate' "$RB" | head -1 | cut -d: -f1)
L_N=$(grep -n '^# >>> changed symbols note (BH-5791)' "$RB" | head -1 | cut -d: -f1)
L_CC=$(grep -n '^CC plan ' "$RB" | head -1 | cut -d: -f1)
[ -n "$L_N" ] && [ -n "$L_UI" ] && [ -n "$L_CC" ] && [ "$L_UI" -lt "$L_N" ] && [ "$L_N" -lt "$L_CC" ] && ok \
  || bad "C10: the plan-stage note must sit after the untrusted input gate and before the plan call (${L_UI:-?} < ${L_N:-?} < ${L_CC:-?})"
L_CP=$(grep -n '^# <<< context pack delta' "$DIR/bin/run-preplan.sh" | cut -d: -f1)
L_N=$(grep -n '^# >>> changed symbols note (BH-5791)' "$DIR/bin/run-preplan.sh" | cut -d: -f1)
L_AC=$(grep -n 'bin/agent-call.sh" preplan' "$DIR/bin/run-preplan.sh" | head -1 | cut -d: -f1)
[ -n "$L_N" ] && [ -n "$L_CP" ] && [ -n "$L_AC" ] && [ "$L_CP" -lt "$L_N" ] && [ "$L_N" -lt "$L_AC" ] && ok \
  || bad "C10: the pre-plan note must sit after the context pack delta and before the pre-plan call (${L_CP:-?} < ${L_N:-?} < ${L_AC:-?})"

# C11: a PR head that cannot be fetched makes the PR list unread, never "none"
cp "$PULLS" "$T/pulls.good.json"
jq '. + [{"number":99,"title":"gone","head":{"ref":"gone-ref"}}]' "$T/pulls.good.json" > "$PULLS"
plan_with "$T/c11.md" "$LISTED"
pc "$T/c11.md" origin/main
grep -qx 'OPEN_PRS: unread (fetch failed)' "$T/col.txt" && ok || bad "C11: a failed fetch must be OPEN_PRS: unread (fetch failed): $(cat "$T/col.txt")"
[ -z "$(git -C "$R" for-each-ref refs/collision-check/)" ] && ok || bad "C11: a failed fetch must leave no refs"
cp "$T/pulls.good.json" "$PULLS"

# C12: the symbol cap drops the rest and the note says so
plan_with "$T/c12.md" "$LISTED
- function \`flag_set\`: also stricter."
PLAN_COLLISION_MAX_SYMBOLS=1 PLAN_COLLISION_MAX_PRS=0 pc "$T/c12.md" origin/m-other
grep -qx 'SYMBOLS: listed=1 derived=0 dropped=1 cap=1' "$T/col.txt" && ok || bad "C12: a cap of 1 must keep 1 and drop 1: $(cat "$T/col.txt")"
! row "${TAB}flag_set${TAB}main${TAB}" && ok || bad "C12: a dropped symbol must not be checked"
lib pc_note "$T/c12.md" "$T/col.txt" 2>/dev/null
grep -q '^It dropped 1 of the symbols over the cap of 1\.$' "$T/c12.md" && ok || bad "C12: the note must say what it dropped"

# ============================================================================
# G. the gate block, lifted from the pipeline
# ============================================================================
awk 'index($0,"# >>> design collisions (BH-5791)")==1{f=1} f{print} index($0,"# <<< design collisions (BH-5791)")==1{exit}' "$RB" > "$T/gate.sh"
awk '/^PLAN_IS_BLOCKED\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$RB" > "$T/blocked-fn.sh"
[ -s "$T/gate.sh" ] && bash -n "$T/gate.sh" && ok || bad "G0: could not lift a valid design collisions block"
[ -s "$T/blocked-fn.sh" ] && ok || bad "G0: could not lift PLAN_IS_BLOCKED"
L_PG=$(grep -n '^# <<< plan gate' "$RB" | head -1 | cut -d: -f1)
L_DC=$(grep -n '^# >>> design collisions (BH-5791)' "$RB" | head -1 | cut -d: -f1)
L_KF=$(grep -n '^# >>> kind flow' "$RB" | head -1 | cut -d: -f1)
[ -n "$L_DC" ] && [ -n "$L_PG" ] && [ -n "$L_KF" ] && [ "$L_PG" -lt "$L_DC" ] && [ "$L_DC" -lt "$L_KF" ] && ok \
  || bad "G0: the block must sit after the plan gate and before the kind flow (${L_PG:-?} < ${L_DC:-?} < ${L_KF:-?})"
cat > "$T/gstubs.sh" <<'SH'
STAMP() { echo 2026-10-10T01:00:00Z; }
RESULT() { echo "$*" > "$SINK"; }
BB() { echo "$1" >> "$CALLS/bb"; }
CC() {
  echo "$1 $2 $3" >> "$CALLS/cc"; printf '%s' "$5" > "$CALLS/cc.prompt"
  if [ "${REPAIR:-none}" = add ]; then
    printf '\n## Design collisions\n\n- `flag_active`: combine — the strict check keeps the main side and adds ours.\n' >> "$BUILD/plan.md"
  fi
}
SH
. "$T/blocked-fn.sh" 2>/dev/null
# gate <base-branch> [env...] : run the block in the repo; OUT RC, $SINK
gate() {
  local b="$1"; shift
  rm -f "$CALLS/cc" "$CALLS/cc.prompt" "$CALLS/bb" "$T/result" "$T/build/pipeline.log" "$T/alerts" "$T/build/collision-base"
  OUT=$(cd "$R" && env PATH="$T/fakebin:$PATH" SINK="$T/result" BUILD="$T/build" PROJECT=tproj KEY=BH-5791 \
        BASE="$b" BRANCH=ticket/bh-5791 ALERTS="$T/alerts" PLAN_MODEL=m PP_OUTCOME= PP_DIR= GH_AUTH_SLUG=o/r \
        PLAN_COLLISION_MAX_PRS=0 "$@" \
        bash -c '. "$0"; . "$1"; . "$2"; echo CONTINUED' "$T/gstubs.sh" "$T/blocked-fn.sh" "$T/gate.sh" 2>"$T/gate.err"); RC=$?
}
continued() { case "$OUT" in *CONTINUED*) return 0 ;; *) return 1 ;; esac; }
verdict() { grep -o 'design collisions: .*' "$T/build/pipeline.log" 2>/dev/null | grep -o 'verdict=[a-z-]*' | tail -1; }

# G1: no collision
plan_with "$T/build/plan.md" "$LISTED"
gate main
continued && [ "$(cnt cc)" = 0 ] && [ ! -s "$T/result" ] && ok || bad "G1: no collision must continue with no CC call (rc=$RC, $(cat "$T/result" 2>/dev/null), $(head -3 "$T/gate.err"))"
[ "$(verdict)" = verdict=none ] && ok || bad "G1: verdict must be none: $(cat "$T/build/pipeline.log" 2>/dev/null)"
grep -q '^Checked ' "$T/build/plan.md" && ok || bad "G1: the note must say Checked"
[ "$(cat "$T/build/collision-base" 2>/dev/null)" = "$BASE_SHA" ] && ok || bad "G1: the first run must record the base it used"
[ "$(grep -c 'design collisions: ' "$T/build/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "G1: exactly one design collisions log line"

# G2: a collision the plan resolves with combine
plan_with "$T/build/plan.md" "$LISTED" '- `flag_active`: combine — main made it strict; ours keeps that and adds the name check.'
gate m-body
continued && [ "$(cnt cc)" = 0 ] && [ "$(verdict)" = verdict=resolved ] && ok || bad "G2: a combine line must resolve with no CC call ($(verdict), cc=$(cnt cc), rc=$RC)"

# G3: unresolved, one repair pass that adds the line
plan_with "$T/build/plan.md" "$LISTED"
rm -f "$T/build/collision-repair-done"
gate m-body REPAIR=add
[ "$(cnt cc)" = 1 ] && grep -q 'flag_active' "$CALLS/cc.prompt" && ok || bad "G3: exactly one repair call naming flag_active (cc=$(cnt cc))"
continued && [ "$(verdict)" = verdict=resolved ] && ok || bad "G3: the repaired plan must resolve and continue ($(verdict), rc=$RC, $(cat "$T/result" 2>/dev/null))"
[ -e "$T/build/collision-repair-done" ] && ok || bad "G3: the repair marker must be written"

# G4: unresolved, the repair writes nothing
plan_with "$T/build/plan.md" "$LISTED"
rm -f "$T/build/collision-repair-done"
gate m-body REPAIR=none
[ "$RC" = 4 ] && [ "$(cat "$T/result" 2>/dev/null)" = "PLAN_BLOCKED $T/build/plan.md" ] && ok || bad "G4: must end PLAN_BLOCKED rc 4 (rc=$RC, $(cat "$T/result" 2>/dev/null))"
PLAN_IS_BLOCKED "$T/build/plan.md" && ok || bad "G4: line 1 must read as a blocked plan: $(head -1 "$T/build/plan.md")"
[ "$(sed -n 2p "$T/build/plan.md")" = "needs-human: design collision (BH-5791)" ] && ok || bad "G4: line 2 wrong: $(sed -n 2p "$T/build/plan.md")"
grep -q '^plan_blocked$' "$CALLS/bb" 2>/dev/null && [ "$(cnt cc)" = 1 ] && [ "$(verdict)" = verdict=blocked ] && ok || bad "G4: BB plan_blocked, one CC and verdict=blocked ($(verdict), cc=$(cnt cc))"

# G5: the plan says needs-human
plan_with "$T/build/plan.md" "$LISTED" '- `flag_active`: needs-human — main and ours disagree on what a missing flag means.'
rm -f "$T/build/collision-repair-done"
gate m-body
[ "$RC" = 4 ] && [ "$(cnt cc)" = 0 ] && grep -q '^PLAN_BLOCKED ' "$T/result" 2>/dev/null && ok || bad "G5: needs-human must block with no CC (rc=$RC, cc=$(cnt cc))"

# G6: the kill switch, and an unknown value
plan_with "$T/build/plan.md" "$LISTED"
rm -f "$T/build/collision-repair-done"
gate m-body PLAN_COLLISION_ENFORCE=0
continued && [ "$(cnt cc)" = 0 ] && [ "$(verdict)" = verdict=note-only ] && grep -q '^## Design collision check' "$T/build/plan.md" && ok || bad "G6: ENFORCE=0 must note and continue ($(verdict), cc=$(cnt cc), rc=$RC)"
plan_with "$T/build/plan.md" "$LISTED"
rm -f "$T/build/collision-repair-done"
gate m-body PLAN_COLLISION_ENFORCE=maybe REPAIR=none
[ "$RC" = 4 ] && [ "$(grep -c 'PLAN_COLLISION_ENFORCE' "$T/alerts" 2>/dev/null)" = 1 ] && ok || bad "G6: an unknown value must enforce and write one ALERTS line (rc=$RC, $(cat "$T/alerts" 2>/dev/null))"

# G7: a resume does not pay twice; derived-only hits are a note
plan_with "$T/build/plan.md" "$LISTED"
touch "$T/build/collision-repair-done"
gate m-body REPAIR=add
[ "$(cnt cc)" = 0 ] && [ "$RC" = 4 ] && ok || bad "G7: a present repair marker must block without a second CC (cc=$(cnt cc), rc=$RC)"
rm -f "$T/build/collision-repair-done"
plan_with "$T/build/plan.md" -
printf 'The plan reads `flag_active` only.\n' >> "$T/build/plan.md"
gate m-body
continued && [ "$(cnt cc)" = 0 ] && [ "$(verdict)" = verdict=note-only ] && ok || bad "G7: a derived-only hit must be note-only ($(verdict), cc=$(cnt cc), rc=$RC)"

echo "plan-collisions.bh-5791-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
