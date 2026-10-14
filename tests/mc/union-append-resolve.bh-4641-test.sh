#!/bin/bash
# tests/mc/union-append-resolve.bh-4641-test.sh — the merge-conductor's rebase
# lane resolves an APPEND-ONLY conflict on an allowlisted file (schema.sql,
# index.js, the JSON registries, route-table.d fragments) by keeping both
# blocks, main's first, instead of parking the PR conflict-unresolvable.
#
# WHAT THIS PINS (BH-4641). On 2026-10-05 about eight PRs were parked
# `conflict-unresolvable: worker/jobs/schema.sql` (and llm-sites.json,
# context-budgets.json, index.js) where both sides had only appended a block at
# the same place. Each sat 1-3h until a session did the union by hand.
#
# THE RULE UNDER TEST. Resolve only when every hunk is pure insertion on both
# sides (no base line removed or changed anywhere in the file), compose main's
# block then the branch's, validate the result (python sqlite3 for .sql, jq plus
# a duplicate-key parse for .json, node --check for .js), and otherwise leave
# the file a REAL conflict. A union-resolved merge is not a clean main merge,
# so mc_rebase pushes it but does NOT rebind the approval (rc 5).
#
# WHY REAL GIT. The whole question is what git's index and diff3 hunks hold for
# these shapes, so every case builds a real repo, merges main INTO the ticket
# branch with HEAD on the branch (stage 2 = branch, stage 3 = main), exactly as
# mc_rebase does, and asserts on the real bytes.
# Run from anywhere: tests/mc/union-append-resolve.bh-4641-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ONE clock read; every fixture commit is stamped from it.
NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"

# The library runs against a SCRATCH harness, never /root/harness.
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/locks" "$T/h/flags" "$T/h/builds" "$T/h/config"
unset MC_UNION_FILES
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init
: > "$MC_LOG"

BR=ticket/bh-9001
SCHEMA=worker/jobs/schema.sql
INDEX=worker/jobs/src/index.js
SITES=catalog/llm-sites.json
BUDGETS=catalog/context-budgets.json
FRAGS=worker/jobs/test/route-table.d

# --- fixture helpers ----------------------------------------------------------
# mkrepo <tag>: a repo at $T/<tag> with main checked out. W is the worktree.
mkrepo() {
  W="$T/$1"
  git init -q -b main "$W"
  git -C "$W" config user.email t@t
  git -C "$W" config user.name t
  git -C "$W" config commit.gpgsign false
  mkdir -p "$W/worker/jobs/src" "$W/catalog" "$W/bin" "$W/$FRAGS"
  printf '{ "name": "jobs", "private": true, "type": "module" }\n' > "$W/worker/jobs/package.json"
}
put()    { mkdir -p "$(dirname "$W/$1")"; printf '%s' "$2" > "$W/$1"; }
commit() { git -C "$W" add -A; git -C "$W" commit -qm "$1"; }
# base -> fork the branch -> main's edits -> the branch's edits -> merge main
# into the branch. The two edit steps are the caller's: between `on_main` and
# `on_branch`, and after `on_branch` before `merge_main`.
fork()      { git -C "$W" branch -q "$BR"; }
on_branch() { git -C "$W" checkout -q "$BR"; }
merge_main() { git -C "$W" merge -q --no-edit main >/dev/null 2>&1; }
unmerged()  { [ -n "$(git -C "$W" ls-files -u -- "$1")" ]; }
msgfile()   { local p; p=$(git -C "$W" rev-parse --git-path MERGE_MSG); case "$p" in /*) printf '%s' "$p" ;; *) printf '%s/%s' "$W" "$p" ;; esac; }
lineof()    { grep -n -- "$2" "$W/$1" | head -1 | cut -d: -f1; }
resolve()   { OUT=$(mc_resolve_conflicts "$W" "$BR"); RC=$?; }

SQL_BASE='CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE b (id INTEGER PRIMARY KEY);
'
SQL_MAIN="${SQL_BASE}-- main's table
CREATE TABLE m (id INTEGER PRIMARY KEY, v TEXT);
"
SQL_TICK="${SQL_BASE}-- the branch's table
CREATE TABLE t (id INTEGER PRIMARY KEY, w TEXT);
"
# schema_case <tag> <main text> <branch text>: a schema.sql conflict, merged.
schema_case() {
  mkrepo "$1"; put "$SCHEMA" "$SQL_BASE"; commit base; fork
  put "$SCHEMA" "$2"; commit main-side
  on_branch; put "$SCHEMA" "$3"; commit branch-side
  merge_main
}

JS_BASE="import { routes as a } from './a.js';
import { routes as b } from './b.js';

export const ROUTES = [
  ...a,
  ...b,
];
"
JS_MAIN="import { routes as a } from './a.js';
import { routes as b } from './b.js';
import { routes as m } from './main-fam.js';

export const ROUTES = [
  ...a,
  ...b,
  ...m,
];
"
JS_TICK="import { routes as a } from './a.js';
import { routes as b } from './b.js';
import { routes as t } from './tick-fam.js';

export const ROUTES = [
  ...a,
  ...b,
  ...t,
];
"

pysql() { python3 -c 'import sqlite3,sys; sqlite3.connect(":memory:").executescript(open(sys.argv[1]).read())' "$1"; }

# =============================================================================
# U1 schema.sql: both sides append a table -> resolved, main's first, parses.
# =============================================================================
schema_case u1 "$SQL_MAIN" "$SQL_TICK"
unmerged "$SCHEMA" && ok || bad "U1 fixture: schema.sql should conflict after the merge"
resolve
[ "$RC" = 0 ] && ok || bad "U1 rc should be 0, got $RC (stdout: $OUT; log: $(tail -2 "$MC_LOG"))"
[ -z "$OUT" ] && ok || bad "U1 stdout must be empty on success, got: $OUT"
[ -z "$(git -C "$W" diff --name-only --diff-filter=U)" ] && ok || bad "U1 no path may stay unmerged"
grep -q 'CREATE TABLE m ' "$W/$SCHEMA" && grep -q 'CREATE TABLE t ' "$W/$SCHEMA" && ok || bad "U1 both tables must be present: $(cat "$W/$SCHEMA")"
M=$(lineof "$SCHEMA" 'CREATE TABLE m '); TT=$(lineof "$SCHEMA" 'CREATE TABLE t ')
[ -n "$M" ] && [ -n "$TT" ] && [ "$M" -lt "$TT" ] && ok || bad "U1 main's table must come first (m at ${M:-?}, t at ${TT:-?})"
grep -q '^<<<<<<<\|^=======$\|^>>>>>>>' "$W/$SCHEMA" && bad "U1 no conflict marker may remain" || ok
pysql "$W/$SCHEMA" && ok || bad "U1 the merged schema must parse in sqlite3"
grep -q "^Union-resolved: $SCHEMA (BH-4641)$" "$(msgfile)" && ok || bad "U1 MERGE_MSG must carry the trailer: $(cat "$(msgfile)")"
grep -q "$SCHEMA union-resolved by the append-union step: 1 hunk(s), main's block first (BH-4641)" "$MC_LOG" \
  && ok || bad "U1 the resolution must be logged: $(tail -2 "$MC_LOG")"

# =============================================================================
# U5 the trailer survives `git commit --no-edit` (what mc_rebase runs).
# =============================================================================
git -C "$W" commit -q --no-edit >/dev/null 2>&1 && ok || bad "U5 the resolved merge must commit"
grep -q "^Union-resolved: $SCHEMA (BH-4641)$" <<<"$(git -C "$W" log -1 --format=%B HEAD)" \
  && ok || bad "U5 the merge commit message must carry the trailer: $(git -C "$W" log -1 --format=%B HEAD)"
[ "$(git -C "$W" rev-list --parents -1 HEAD | wc -w)" = 3 ] && ok || bad "U5 the commit must be a two-parent merge"

# =============================================================================
# U2 index.js: both add an import and a spread -> resolved, node --check ok.
# =============================================================================
mkrepo u2; put "$INDEX" "$JS_BASE"; commit base; fork
put "$INDEX" "$JS_MAIN"; commit main-side
on_branch; put "$INDEX" "$JS_TICK"; commit branch-side
merge_main
resolve
[ "$RC" = 0 ] && ok || bad "U2 rc should be 0, got $RC ($OUT; $(tail -2 "$MC_LOG"))"
IM=$(lineof "$INDEX" "main-fam.js"); IT=$(lineof "$INDEX" "tick-fam.js")
SM=$(lineof "$INDEX" '\.\.\.m,'); ST=$(lineof "$INDEX" '\.\.\.t,')
[ -n "$IM" ] && [ -n "$IT" ] && [ "$IM" -lt "$IT" ] && ok || bad "U2 main's import must precede the branch's ($IM vs $IT)"
[ -n "$SM" ] && [ -n "$ST" ] && [ "$SM" -lt "$ST" ] && ok || bad "U2 main's spread must precede the branch's ($SM vs $ST)"
node --check "$W/$INDEX" && ok || bad "U2 node --check must pass on the merged index.js"
grep -q "2 hunk(s)" "$MC_LOG" && ok || bad "U2 both hunks must be counted in the log line"

# =============================================================================
# U3 JSON array append (llm-sites.json shape) -> valid JSON with both, in order.
# =============================================================================
SITES_BASE='{
  "version": 1,
  "sites": [
    {"id": "a"},
    {"id": "b"}
  ]
}
'
mkrepo u3; put "$SITES" "$SITES_BASE"; commit base; fork
put "$SITES" '{
  "version": 1,
  "sites": [
    {"id": "a"},
    {"id": "b"},
    {"id": "main"}
  ]
}
'; commit main-side
on_branch; put "$SITES" '{
  "version": 1,
  "sites": [
    {"id": "a"},
    {"id": "b"},
    {"id": "tick"}
  ]
}
'; commit branch-side
merge_main
unmerged "$SITES" && ok || bad "U3 fixture: llm-sites.json should conflict"
resolve
[ "$RC" = 0 ] && ok || bad "U3 rc should be 0, got $RC ($OUT; $(tail -2 "$MC_LOG"))"
jq -e . "$W/$SITES" >/dev/null 2>&1 && ok || bad "U3 the merged file must be valid JSON: $(cat "$W/$SITES")"
[ "$(jq -c '.sites|map(.id)' "$W/$SITES" 2>/dev/null)" = '["a","b","main","tick"]' ] \
  && ok || bad "U3 ids must be a,b,main,tick: $(jq -c '.sites|map(.id)' "$W/$SITES" 2>&1)"

# =============================================================================
# U3b JSON object key append (context-budgets.json shape).
# =============================================================================
BUD_BASE='{
  "a": 1,
  "b": 2
}
'
budget_case() { # <tag> <main key line> <branch key line>
  mkrepo "$1"; put "$BUDGETS" "$BUD_BASE"; commit base; fork
  put "$BUDGETS" "{
  \"a\": 1,
  \"b\": 2,
  $2
}
"; commit main-side
  on_branch; put "$BUDGETS" "{
  \"a\": 1,
  \"b\": 2,
  $3
}
"; commit branch-side
  merge_main
}
budget_case u3b '"m": 3' '"t": 4'
resolve
[ "$RC" = 0 ] && ok || bad "U3b distinct keys: rc should be 0, got $RC ($(tail -2 "$MC_LOG"))"
[ "$(jq -c 'keys' "$W/$BUDGETS" 2>/dev/null)" = '["a","b","m","t"]' ] && ok || bad "U3b both keys must be present: $(cat "$W/$BUDGETS")"
budget_case u3c '"x": 3' '"x": 4'
resolve
[ "$RC" = 1 ] && ok || bad "U3b same key: rc should be 1 (a duplicate key is a semantic conflict), got $RC"
grep -qx "$BUDGETS" <<<"$OUT" && ok || bad "U3b same key: stdout must list the file, got: $OUT"
unmerged "$BUDGETS" && ok || bad "U3b same key: the file must still be unmerged"
grep -q "$BUDGETS left as a REAL conflict by the append-union step: validator failed.*duplicate key" "$MC_LOG" \
  && ok || bad "U3b same key: the decline must name the duplicate key: $(tail -2 "$MC_LOG")"

# =============================================================================
# U4 multi-line objects: both sides add the same `},` / `{` lines, git's diff3
# treats them as common, and its conflict hunk is only `"id": "main"` against
# `"id": "tick"`. Unioning that hunk would put both ids in ONE object, so the
# whole objects must be kept intact, main's first.
# =============================================================================
mkrepo u4; put "$SITES" '{
  "sites": [
    {
      "id": "a"
    },
    {
      "id": "b"
    }
  ]
}
'; commit base; fork
put "$SITES" '{
  "sites": [
    {
      "id": "a"
    },
    {
      "id": "b"
    },
    {
      "id": "main"
    }
  ]
}
'; commit main-side
on_branch; put "$SITES" '{
  "sites": [
    {
      "id": "a"
    },
    {
      "id": "b"
    },
    {
      "id": "tick"
    }
  ]
}
'; commit branch-side
merge_main
resolve
[ "$RC" = 0 ] && ok || bad "U4 rc should be 0, got $RC ($(tail -2 "$MC_LOG"))"
[ "$(jq -c '.sites|map(.id)' "$W/$SITES" 2>/dev/null)" = '["a","b","main","tick"]' ] \
  && ok || bad "U4 ids must be a,b,main,tick: $(cat "$W/$SITES")"

# =============================================================================
# U6 one side edits an existing line -> parked.
# =============================================================================
# (a) the branch changes a column in base's FIRST table (outside the hunk, so
#     git merges that line cleanly) and also appends a table.
schema_case u6a "$SQL_MAIN" "CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE b (id INTEGER PRIMARY KEY);
-- the branch's table
CREATE TABLE t (id INTEGER PRIMARY KEY, w TEXT);
"
resolve
[ "$RC" = 1 ] && ok || bad "U6a a branch that edits a base line must park, got rc $RC"
grep -qx "$SCHEMA" <<<"$OUT" && ok || bad "U6a stdout must be the conflict list, got: $OUT"
unmerged "$SCHEMA" && ok || bad "U6a the file must still be unmerged"
grep -q '^<<<<<<<' "$W/$SCHEMA" && ok || bad "U6a the worktree must still carry the markers"
grep -q "left as a REAL conflict by the append-union step: not pure insertion: the branch changed or removed a base line" "$MC_LOG" \
  && ok || bad "U6a the decline reason must be logged: $(tail -2 "$MC_LOG")"
# (b) inside the hunk, MAIN edits the last base line while the branch appends.
schema_case u6b "CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE b (id INTEGER PRIMARY KEY, z TEXT);
-- main's table
CREATE TABLE m (id INTEGER PRIMARY KEY, v TEXT);
" "$SQL_TICK"
resolve
[ "$RC" = 1 ] && ok || bad "U6b main editing a base line inside the hunk must park, got rc $RC"
unmerged "$SCHEMA" && ok || bad "U6b the file must still be unmerged"

# =============================================================================
# U7 route-table.d number collision -> the branch's fragment is renumbered.
# =============================================================================
frag_case() { # <tag> <main frag> <branch frag>
  mkrepo "$1"
  put "$FRAGS/660-x.txt" "x
"; put "$FRAGS/670-y.txt" "y
"; put "$INDEX" "$JS_BASE"; commit base; fork
  put "$FRAGS/$2" "main
"; put "$INDEX" "$JS_MAIN"; commit main-side
  on_branch; put "$FRAGS/$3" "tick
"; put "$INDEX" "$JS_TICK"; commit branch-side
  merge_main
}
frag_case u7 680-main-fam.txt 680-tick-fam.txt
resolve
[ "$RC" = 0 ] && ok || bad "U7 rc should be 0, got $RC ($OUT; $(tail -3 "$MC_LOG"))"
LS=$(git -C "$W" ls-files -- "$FRAGS" | sed 's#.*/##' | tr '\n' ' ')
[ "$LS" = "660-x.txt 670-y.txt 680-main-fam.txt 681-tick-fam.txt " ] && ok || bad "U7 the staged fragments must be 660/670/680-main/681-tick, got: $LS"
[ -f "$W/$FRAGS/681-tick-fam.txt" ] && [ ! -e "$W/$FRAGS/680-tick-fam.txt" ] && ok || bad "U7 the worktree must carry the renamed file only"
[ "$(git -C "$W" ls-files -- "$FRAGS" | sed 's#.*/##' | cut -c1-3 | sort | uniq -d)" = "" ] && ok || bad "U7 fragment numbers must be unique"
grep -q "^Union-resolved: $FRAGS/680-tick-fam.txt -> $FRAGS/681-tick-fam.txt (BH-4641, renumbered)$" "$(msgfile)" \
  && ok || bad "U7 MERGE_MSG must name the rename: $(cat "$(msgfile)")"
git -C "$W" commit -q --no-edit >/dev/null 2>&1 && ok || bad "U7 the merge must commit"
grep -qx "$FRAGS/681-tick-fam.txt" <<<"$(git -C "$W" ls-tree -r --name-only HEAD -- "$FRAGS")" && ok || bad "U7 the rename must land in the merge commit"

# =============================================================================
# U8 a NON-tail collision (below base's last number) -> parked, nothing renamed.
# =============================================================================
frag_case u8 665-w.txt 665-z.txt
resolve
[ "$RC" = 1 ] && ok || bad "U8 a mid-table collision must park, got rc $RC"
grep -qx "$INDEX" <<<"$OUT" && ok || bad "U8 stdout must be the conflict list, got: $OUT"
LS=$(git -C "$W" ls-files -- "$FRAGS" | sed 's#.*/##' | tr '\n' ' ')
[ "$LS" = "660-x.txt 665-w.txt 665-z.txt 670-y.txt " ] && ok || bad "U8 nothing may be renamed, got: $LS"

# =============================================================================
# U9 a file NOT on the allowlist -> parked.
# =============================================================================
mkrepo u9; put bin/other.sh 'a
b
'; commit base; fork
put bin/other.sh 'a
b
main
'; commit main-side
on_branch; put bin/other.sh 'a
b
tick
'; commit branch-side
merge_main
resolve
[ "$RC" = 1 ] && ok || bad "U9 an off-list file must park, got rc $RC"
unmerged bin/other.sh && ok || bad "U9 the file must still be unmerged"

# =============================================================================
# U10 a failed validation -> parked, file restored, one log line.
# =============================================================================
schema_case u10 "$SQL_MAIN" "${SQL_BASE}CREATE TABLE t (x TEXT
"
N0=$(grep -c 'left as a REAL conflict by the append-union step: validator' "$MC_LOG" || true)
resolve
[ "$RC" = 1 ] && ok || bad "U10 a schema that does not parse must park, got rc $RC"
unmerged "$SCHEMA" && ok || bad "U10 the file must still be unmerged"
grep -q '^<<<<<<<' "$W/$SCHEMA" && ok || bad "U10 the file must be restored to its conflicted state: $(cat "$W/$SCHEMA")"
N1=$(grep -c 'left as a REAL conflict by the append-union step: validator' "$MC_LOG" || true)
[ "$((N1 - N0))" = 1 ] && ok || bad "U10 exactly one validator decline line, got $((N1 - N0))"
grep -q "Union-resolved" "$(msgfile)" && bad "U10 a declined file must not leave a trailer" || ok

# =============================================================================
# U11 the knob.
# =============================================================================
schema_case u11a "$SQL_MAIN" "$SQL_TICK"
OUT=$(MC_UNION_FILES=off mc_resolve_conflicts "$W" "$BR"); RC=$?
[ "$RC" = 1 ] && ok || bad "U11 MC_UNION_FILES=off must restore today's park, got rc $RC"
schema_case u11b "$SQL_MAIN" "$SQL_TICK"
OUT=$(MC_UNION_FILES='bin/other.sh' mc_resolve_conflicts "$W" "$BR"); RC=$?
[ "$RC" = 1 ] && ok || bad "U11 schema.sql off the operator's list must park, got rc $RC"
[ "$(MC_UNION_FILES='a.sql, b.json  c/*' mc_union_globs | tr '\n' ' ')" = "a.sql b.json c/* " ] \
  && ok || bad "U11 commas and spaces both separate entries: $(MC_UNION_FILES='a.sql, b.json  c/*' mc_union_globs | tr '\n' ' ')"
[ "$(mc_union_globs | tr '\n' ' ')" = "worker/jobs/schema.sql worker/jobs/src/index.js catalog/llm-sites.json catalog/context-budgets.json worker/jobs/test/route-table.d/* " ] \
  && ok || bad "U11 unset, the compiled default applies: $(mc_union_globs | tr '\n' ' ')"
mc_path_is_union "$FRAGS/700-new.txt" && ok || bad "U11 a route-table.d fragment is on the default list"
mc_path_is_union bin/other.sh && bad "U11 bin/other.sh is not on the default list" || ok
schema_case u11c "$SQL_MAIN" "$SQL_TICK"
OUT=$( lane_knob() { [ "$1 $2" = "merge-conductor MC_UNION_FILES" ] && printf '%s' "worker/jobs/schema.sql"; }
       MC_UNION_FILES=off mc_resolve_conflicts "$W" "$BR" ); RC=$?
[ "$RC" = 0 ] && ok || bad "U11 the settings row (lane_knob) is honoured over the env, got rc $RC"

# =============================================================================
# U12/U13 through mc_rebase itself, against a local bare origin.
# =============================================================================
REMOTE=""
mc_git_auth()       { MC_REMOTE="$REMOTE"; return 0; }
mc_git_auth_clear() { :; }
job_verdict_rebind() { echo "$*" >> "$T/rebind.calls"; return 0; }

# mk_origin <tag> <main schema> <branch schema>: a bare origin from a repo
# shaped like schema_case, with main checked out. Sets REMOTE ORIGIN BR_HEAD.
mk_origin() {
  mkrepo "$1/work"; put "$SCHEMA" "$SQL_BASE"; commit base; fork
  put "$SCHEMA" "$2"; commit main-side
  on_branch; put "$SCHEMA" "$3"; commit branch-side
  BR_HEAD=$(git -C "$W" rev-parse HEAD)
  git -C "$W" checkout -q main
  ORIGIN="$T/$1/origin.git"
  git clone -q --bare "$W" "$ORIGIN"
  REMOTE="file://$ORIGIN"
  mkdir -p "$T/$1/repos"
  git clone -q "file://$ORIGIN" "$T/$1/repos/demo-os"
  git -C "$T/$1/repos/demo-os" config user.email t@t
  git -C "$T/$1/repos/demo-os" config user.name t
  git -C "$T/$1/repos/demo-os" config commit.gpgsign false
  export MC_REPOS="$T/$1/repos"
}
# A build record that names the PR, with its reviewed-sha at the old head.
mk_record() { # <url> <reviewed>
  mkdir -p "$T/h/builds/demo-os-BH-9001-1"
  printf 'PR_CREATED %s\n' "$1" > "$T/h/builds/demo-os-BH-9001-1/RESULT"
  printf '%s\n' "$2" > "$T/h/builds/demo-os-BH-9001-1/reviewed-sha"
}

URL=https://github.com/o/r/pull/12
mk_origin u12 "$SQL_MAIN" "$SQL_TICK"
mk_record "$URL" "$BR_HEAD"
rm -f "$T/rebind.calls"
OUT=$(mc_rebase o/r demo-os "$BR" "$BR_HEAD" "$URL"); RC=$?
[ "$RC" = 5 ] && ok || bad "U12 a union-resolved rebase must return rc 5 (pushed, approval not rebound), got $RC ($(tail -3 "$MC_LOG"))"
[ -n "$OUT" ] && [ "$OUT" = "$(git -C "$ORIGIN" rev-parse "$BR")" ] && ok || bad "U12 stdout must be the pushed sha: '$OUT'"
[ "$OUT" != "$BR_HEAD" ] && ok || bad "U12 the branch must have moved"
[ ! -e "$T/rebind.calls" ] && ok || bad "U12 job_verdict_rebind must NOT be called: $(cat "$T/rebind.calls" 2>/dev/null)"
[ "$(cat "$T/h/builds/demo-os-BH-9001-1/reviewed-sha")" = "$BR_HEAD" ] && ok || bad "U12 reviewed-sha must stay on the old head"
grep -q "$URL pushed ${OUT:0:8} — union-resolved ($SCHEMA (BH-4641)): approval deliberately NOT rebound" "$MC_LOG" \
  && ok || bad "U12 the log must say the rebind was withheld: $(tail -3 "$MC_LOG")"
grep -q "^Union-resolved: $SCHEMA (BH-4641)$" <<<"$(git -C "$ORIGIN" log -1 --format=%B "$BR")" && ok || bad "U12 the pushed merge commit must carry the trailer"
grep -q 'CREATE TABLE t ' <<<"$(git -C "$ORIGIN" show "$BR:$SCHEMA")" && ok || bad "U12 the pushed tree must hold the branch's table"

# Control: a clean merge through the same path is rc 0 and rebinds once.
# Main moves on a file the branch never touches, so the merge is clean.
URL2=https://github.com/o/r/pull/13
mkrepo u12d/work; put "$SCHEMA" "$SQL_BASE"; commit base; fork
put README "main
"; commit main-side
on_branch; put "$SCHEMA" "$SQL_TICK"; commit branch-side
BR_HEAD=$(git -C "$W" rev-parse HEAD); git -C "$W" checkout -q main
ORIGIN="$T/u12d/origin.git"; git clone -q --bare "$W" "$ORIGIN"; REMOTE="file://$ORIGIN"
mkdir -p "$T/u12d/repos"; git clone -q "file://$ORIGIN" "$T/u12d/repos/demo-os"
git -C "$T/u12d/repos/demo-os" config user.email t@t; git -C "$T/u12d/repos/demo-os" config user.name t
git -C "$T/u12d/repos/demo-os" config commit.gpgsign false
export MC_REPOS="$T/u12d/repos"
rm -f "$T/rebind.calls"
OUT=$(mc_rebase o/r demo-os "$BR" "$BR_HEAD" "$URL2"); RC=$?
[ "$RC" = 0 ] && ok || bad "U12 control: a clean merge must be rc 0, got $RC ($(tail -3 "$MC_LOG"))"
[ "$(wc -l < "$T/rebind.calls" 2>/dev/null)" = 1 ] && ok || bad "U12 control: the rebind must be called exactly once"

# U12b a union merge with a REGENERATE commit on top. The repo declares a
# committed generated file that the merged tree makes stale, so
# mc_regen_generated commits `regenerate ...` over the union merge and HEAD no
# longer carries the trailer. The rebind must still be withheld.
URL4=https://github.com/o/r/pull/15
mkrepo u12b/work
put docs/verification-map/index/tail.md '## Generated files

| Path | Regenerate |
|---|---|
| `gen.txt` | `wc -l < worker/jobs/schema.sql > gen.txt` |
'
put gen.txt "stale
"
put "$SCHEMA" "$SQL_BASE"; commit base; fork
put "$SCHEMA" "$SQL_MAIN"; commit main-side
on_branch; put "$SCHEMA" "$SQL_TICK"; commit branch-side
BR_HEAD=$(git -C "$W" rev-parse HEAD); git -C "$W" checkout -q main
ORIGIN="$T/u12b/origin.git"; git clone -q --bare "$W" "$ORIGIN"; REMOTE="file://$ORIGIN"
mkdir -p "$T/u12b/repos"; git clone -q "file://$ORIGIN" "$T/u12b/repos/demo-os"
git -C "$T/u12b/repos/demo-os" config user.email t@t; git -C "$T/u12b/repos/demo-os" config user.name t
git -C "$T/u12b/repos/demo-os" config commit.gpgsign false
export MC_REPOS="$T/u12b/repos"
mk_record "$URL4" "$BR_HEAD"
rm -f "$T/rebind.calls"
OUT=$(MC_GIT_NAME=t MC_GIT_EMAIL=t@t mc_rebase o/r demo-os "$BR" "$BR_HEAD" "$URL4"); RC=$?
grep -q '^regenerate gen.txt after rebase onto origin/main$' <<<"$(git -C "$ORIGIN" log -1 --format=%s "$BR")" \
  && ok || bad "U12b fixture: the pushed head must be the regenerate commit, got: $(git -C "$ORIGIN" log -2 --format=%s "$BR" | tr '\n' '|')"
grep -q "^Union-resolved: $SCHEMA (BH-4641)$" <<<"$(git -C "$ORIGIN" log -1 --format=%B "$BR^")" \
  && ok || bad "U12b fixture: the union merge must sit under the regenerate commit"
[ "$RC" = 5 ] && ok || bad "U12b a union merge under a regenerate commit must return rc 5, got $RC ($(tail -3 "$MC_LOG"))"
[ ! -e "$T/rebind.calls" ] && ok || bad "U12b job_verdict_rebind must NOT be called: $(cat "$T/rebind.calls" 2>/dev/null)"
[ "$(cat "$T/h/builds/demo-os-BH-9001-1/reviewed-sha")" = "$BR_HEAD" ] && ok || bad "U12b reviewed-sha must stay on the old head"
grep -q "$URL4 pushed ${OUT:0:8} — union-resolved ($SCHEMA (BH-4641)): approval deliberately NOT rebound" "$MC_LOG" \
  && ok || bad "U12b the log must say the rebind was withheld: $(tail -3 "$MC_LOG")"

# U13 the same recipe on a U6 shape: parked, the remote untouched.
URL3=https://github.com/o/r/pull/14
mk_origin u13 "$SQL_MAIN" "CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE b (id INTEGER PRIMARY KEY);
CREATE TABLE t (id INTEGER PRIMARY KEY, w TEXT);
"
OUT=$(mc_rebase o/r demo-os "$BR" "$BR_HEAD" "$URL3"); RC=$?
[ "$RC" = 1 ] && ok || bad "U13 a non-append conflict through mc_rebase must be rc 1, got $RC"
grep -qx "$SCHEMA" <<<"$OUT" && ok || bad "U13 stdout must list the file, got: $OUT"
[ "$(git -C "$ORIGIN" rev-parse "$BR")" = "$BR_HEAD" ] && ok || bad "U13 the remote branch must be unchanged"

# =============================================================================
# U14 the pool twin: a RESULT with a UNION: line is rc 5 and never rebinds.
# =============================================================================
H40=1111111111111111111111111111111111111111
N40=2222222222222222222222222222222222222222
pool_case() { # <with-union 0|1>
  local rf="$T/pool-result.$1" key="RB-7-${H40:0:8}"
  { printf 'REBASED %s\nPR: https://github.com/o/r/pull/7\nHEAD: %s\nBRANCH: %s\nBASE: main\nGATE: typecheck=skipped unit=skipped\n' "$N40" "$H40" "$BR"
    [ "$1" = 1 ] && printf 'UNION: %s (BH-4641)\n' "$SCHEMA"
  } > "$rf"
  rm -f "$T/rebind.calls" "$(mc_rb_file o/r 7 "$H40")"
  mc_pool_rebase_apply demo-os "$key" "$rf"
}
pool_case 1; PRC=$?
[ "$PRC" = 0 ] && ok || bad "U14 the apply itself must succeed, got $PRC"
[ "$(jq -r .rc "$(mc_rb_file o/r 7 "$H40")" 2>/dev/null)" = 5 ] && ok || bad "U14 a UNION: RESULT must record rc 5, got $(cat "$(mc_rb_file o/r 7 "$H40")" 2>/dev/null)"
[ ! -e "$T/rebind.calls" ] && ok || bad "U14 a UNION: RESULT must not rebind"
grep -q "deliberately NOT rebound" "$MC_LOG" && ok || bad "U14 the pool apply must log the withheld rebind"
pool_case 0
[ "$(jq -r .rc "$(mc_rb_file o/r 7 "$H40")" 2>/dev/null)" = 0 ] && ok || bad "U14 control: no UNION: line is rc 0"
[ "$(wc -l < "$T/rebind.calls" 2>/dev/null)" = 1 ] && ok || bad "U14 control: exactly one rebind"

# =============================================================================
# U15 end to end on the pool path: the machine's rebase_job_run union-resolves,
# writes the UNION: line, and the hub's apply of that very RESULT withholds the
# rebind.
# =============================================================================
mk_origin u15 "$SQL_MAIN" "$SQL_TICK"
RF="$T/u15/RESULT"
( export REBASE_JOB_URL=https://github.com/o/r/pull/7 REBASE_WT_DIR="$T/u15/wt" PROJECT=demo-os
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/rebase-job.sh"
  rebase_job_run "$T/u15/repos/demo-os" o/r "$BR" "$BR_HEAD" main "$RF" "$DIR" ); JRC=$?
[ "$JRC" = 0 ] && ok || bad "U15 rebase_job_run must rebase, got rc $JRC: $(head -1 "$RF" 2>/dev/null)"
NEWH=$(git -C "$ORIGIN" rev-parse "$BR")
[ "$(head -1 "$RF")" = "REBASED $NEWH" ] && ok || bad "U15 line 1 must be REBASED <pushed sha>: $(head -1 "$RF")"
[ "$(sed -n 7p "$RF")" = "UNION: $SCHEMA (BH-4641)" ] && ok || bad "U15 line 7 must be the UNION: line: $(cat "$RF")"
"$DIR/bin/result-prefix-ok.sh" "$(head -1 "$RF")" && ok || bad "U15 the reap gate must still read line 1 as a RESULT"
rm -f "$T/rebind.calls" "$(mc_rb_file o/r 7 "$BR_HEAD")"
mc_pool_rebase_apply demo-os "RB-7-${BR_HEAD:0:8}" "$RF" && ok || bad "U15 the apply must succeed"
[ "$(jq -r .rc "$(mc_rb_file o/r 7 "$BR_HEAD")" 2>/dev/null)" = 5 ] && ok || bad "U15 the machine's union RESULT must apply as rc 5"
[ ! -e "$T/rebind.calls" ] && ok || bad "U15 no rebind on the machine's union RESULT"

echo "union-append-resolve.bh-4641: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
