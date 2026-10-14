#!/bin/bash
# tests/spec-repos.bh-6576-test.sh — BH-6576: a ticket body line
# `Spec-repo: <owner>/<repo>` names a repo the pool build may READ.
#
# bin/lib/spec-repos.sh reads the line (spec_repos_parse), loads it for one
# GitHub-Issues ticket through gh_rest with a per-tick cache (spec_repos_load),
# and answers "does this pool machine carry a token for spec repos"
# (spec_repos_machine_has).
#
# PINNED (the real lib sourced, gh_rest stubbed):
#   P1-P7 the parser: the line shapes that count, the ones that do not (the
#         key mid-sentence, a fence, a bad slug, shell text), dedupe, the cap.
#   L1-L5 the loader: the issue read, the cache (no subshell), a cuid id, an
#         unreadable read (rc 2, said once, cached), a body with no line.
#   U1-U3 the union helper: knob repos, the project slug and duplicates out.
#   M1-M4 the machine check on the json spawn_one writes.
# Run from anywhere: bash tests/spec-repos.bh-6576-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/spec-repos.sh"
[ -r "$LIB" ] && ok || { bad "bin/lib/spec-repos.sh is missing"; echo "spec-repos (BH-6576): $PASS passed, $FAIL failed"; exit 1; }
# shellcheck source=bin/lib/spec-repos.sh
. "$LIB" || { bad "sourcing bin/lib/spec-repos.sh failed"; exit 1; }

# parse <body> -> the parsed slugs on one line, space-joined
parse() { printf '%s' "$1" | spec_repos_parse | paste -sd' ' -; }
eq() { [ "$2" = "$3" ] && ok || bad "$1: expected '$3', got '$2'"; }

# ── P1-P7: the parser ───────────────────────────────────────────────────────
eq P1 "$(parse 'Spec-repo: example-org/project-6')" "example-org/project-6"
eq P2 "$(parse $'Intro\n- Spec-repos: a/b, c/d\n* Spec-repo: `e/f` g/h\n')" "a/b c/d e/f g/h"
eq P2b "$(parse '`Spec-repo: example-org/project-6`')" "example-org/project-6"
OUT=$(parse $'SPEC-REPO: x/y\r\nspec-repos: z/w\r\n')
eq P3 "$OUT" "x/y z/w"
case "$OUT" in *$'\r'*) bad "P3: a CR survived the parse" ;; *) ok ;; esac
# This ticket's own body names the key inside a sentence.
P4BODY='project-5 tickets cite a spec file in example-org/project-6. Option 1: a ticket body line (`Spec-repo: example-org/project-6`) widens the token.
The key Spec-repo: a/b mid-line does not count either.'
eq P4 "$(parse "$P4BODY")" ""
eq P5a "$(parse $'```\nSpec-repo: a/b\n```\n')" ""
eq P5b "$(parse $'~~~md\nSpec-repo: a/b\n~~~\nSpec-repo: c/d\n')" "c/d"
eq P5c "$(parse $'```\n~~~\nSpec-repo: a/b\n```\n')" ""
eq P6 "$(parse 'Spec-repo: not a slug, $(id)/x, a/b;rm, ok/one, `ok/two`')" "ok/one ok/two"
eq P6b "$(parse $'Spec-repo:\nSpecrepo: a/b\nSpec repo: c/d\n')" ""
eq P7a "$(parse $'Spec-repo: a/b\nSpec-repo: A/B, c/d')" "a/b c/d"
TWELVE=$(printf 'o/r%s ' 01 02 03 04 05 06 07 08 09 10 11 12)
OUT=$(parse "Spec-repo: $TWELVE")
eq P7b "$(wc -w <<<"$OUT" | tr -d ' ')" 10
eq P7c "${OUT##* }" "o/r10"

# ── L1-L5: the loader, through a gh_rest stub ───────────────────────────────
# GH_STUB_RC / GH_STUB_STATUS / GH_STUB_BODY drive it; every call is logged.
gh_rest() {
  printf '%s %s token=%s\n' "$1" "$2" "${GH_TOKEN:-}" >> "$T/gh.calls"
  GH_REST_STATUS="${GH_STUB_STATUS:-200}"
  [ "${GH_STUB_RC:-0}" = 0 ] || return "$GH_STUB_RC"
  printf '%s\n' "$GH_STUB_BODY"
}
: > "$T/gh.calls"
GH_STUB_BODY='{"number":3487,"body":"Build the report.\r\nSpec-repo: example-org/project-6\r\n"}'
SPEC_REPOS=stale; LRC=0
SPEC_REPOS_GH_TOKEN=tok-fixture-slug spec_repos_load example-org/project-5 3487 2>"$T/l.err" || LRC=$?
eq L1-rc "$LRC" 0
eq L1-value "$SPEC_REPOS" "example-org/project-6"
eq L1-call "$(cat "$T/gh.calls")" "GET repos/example-org/project-5/issues/3487 token=tok-fixture-slug"
GH_STUB_BODY='{"body":"Spec-repo: example-org/changed"}'
SPEC_REPOS=""; spec_repos_load example-org/project-5 3487 || bad "L2: a cache hit must answer rc 0"
eq L2-calls "$(wc -l < "$T/gh.calls" | tr -d ' ')" 1
eq L2-value "$SPEC_REPOS" "example-org/project-6"
SPEC_REPOS=stale; LRC=0; spec_repos_load example-org/project-5 cmabc123xyz || LRC=$?
eq L3-rc "$LRC" 0
eq L3-value "$SPEC_REPOS" ""
eq L3-calls "$(wc -l < "$T/gh.calls" | tr -d ' ')" 1
for case in "75 403" "44 404"; do
  read -r GH_STUB_RC GH_STUB_STATUS <<<"$case"
  N="9$GH_STUB_RC"
  SPEC_REPOS=stale; LRC=0
  spec_repos_load example-org/project-5 "$N" 2>"$T/l.err" || LRC=$?
  eq "L4-rc-$GH_STUB_RC" "$LRC" 2
  eq "L4-value-$GH_STUB_RC" "$SPEC_REPOS" ""
  eq "L4-err-$GH_STUB_RC" "$(cat "$T/l.err")" "spec-repos: example-org/project-5#$N unreadable (http $GH_STUB_STATUS) — no spec repos this spawn"
  BEFORE=$(wc -l < "$T/gh.calls")
  LRC=0; spec_repos_load example-org/project-5 "$N" 2>"$T/l.err" || LRC=$?
  eq "L4-cached-rc-$GH_STUB_RC" "$LRC" 2
  eq "L4-cached-calls-$GH_STUB_RC" "$(wc -l < "$T/gh.calls")" "$BEFORE"
  [ -s "$T/l.err" ] && bad "L4: a cached miss must not be said again" || ok
done
GH_STUB_RC=0; GH_STUB_STATUS=200
GH_STUB_BODY='{"body":"The report must match the prototype."}'
SPEC_REPOS=stale; LRC=0; spec_repos_load example-org/project-5 3500 || LRC=$?
eq L5-rc "$LRC" 0
eq L5-value "$SPEC_REPOS" ""
GH_STUB_BODY='{"body":null}'
SPEC_REPOS=stale; spec_repos_load example-org/project-5 3501; eq L5-null "$SPEC_REPOS" ""
GH_STUB_BODY='not json'
SPEC_REPOS=stale; LRC=0; spec_repos_load example-org/project-5 3502 2>/dev/null || LRC=$?
eq L5-badjson "$LRC/$SPEC_REPOS" "2/"
SPEC_REPOS=stale; LRC=0; spec_repos_load "" 3503 2>/dev/null || LRC=$?
eq L5-noslug "$LRC/$SPEC_REPOS" "2/"
GH_STUB_BODY='{"body":"- Spec-repos: example-org/a, `example-org/b`"}'
spec_repos_load example-org/project-5 3504; eq L5-two "$SPEC_REPOS" "example-org/a,example-org/b"
LRC=0; ( unset -f gh_rest; spec_repos_load example-org/project-5 3505 ) || LRC=$?
eq L5-nogh "$LRC" 2

# ── U1-U3: spec_repos_extra (the swap block's union) ────────────────────────
eq U1 "$(spec_repos_extra "" "example-org/project-6" example-org/project-5)" "example-org/project-6"
eq U2 "$(spec_repos_extra "example-org/A ThirdRepo/x" "example-org/a,example-org/project-6,example-org/project-6,example-org/project-5" example-org/project-5)" "example-org/project-6"
eq U3 "$(spec_repos_extra $'example-org/a,\texample-org/b' "example-org/b,example-org/c" example-org/project-5)" "example-org/c"
eq U3b "$(spec_repos_extra "" "" example-org/project-5)" ""

# ── M1-M4: the machine check ────────────────────────────────────────────────
printf '{"machine":"m1","key":"TK-1"}\n' > "$T/m1.json"
printf '{"machine":"m2","key":"TK-2","spec_repos":""}\n' > "$T/m2.json"
printf '{"machine":"m3","key":"TK-3","spec_repos":"example-org/project-6"}\n' > "$T/m3.json"
printf '{"machine":"m4","key":"TK-4","spec_repos":"example-org/a,example-org/b"}\n' > "$T/m4.json"
spec_repos_machine_has "$T/m1.json" && bad "M1: no spec_repos key must answer rc 1" || ok
spec_repos_machine_has "$T/m2.json" && bad "M1: an empty spec_repos must answer rc 1" || ok
spec_repos_machine_has "$T/m3.json" && ok || bad "M2: one spec repo must answer rc 0"
spec_repos_machine_has "$T/m4.json" && ok || bad "M3: two spec repos must answer rc 0"
spec_repos_machine_has "$T/absent.json" && bad "M4: an unreadable file must answer rc 1" || ok

echo "spec-repos (BH-6576): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
