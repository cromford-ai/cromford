#!/bin/bash
# tests/compact-recheck.bh-9049-test.sh — the iron-law re-check after context
# compaction (BH-9049): a SessionStart hook (matcher "compact") on the build
# stages plan, execute and fix. No model call.
#
# WHAT IS PROVEN HERE
#   P1-P3  mc_iron_law_lines (bin/lib/mc/classify.sh): the merge-sweep literal
#          scan with new-file line numbers; same skip set; parity with
#          mc_iron_law_names, whose output is pinned unchanged.
#   R1-R8  cr_rls_hits (bin/lib/compact-recheck.sh): CREATE TABLE with no
#          ENABLE ROW LEVEL SECURITY in the same diff.
#   K1-K6  compact_recheck_settings: the install decision (stage x knob x the
#          COMPACT_RECHECK_ENABLED override) and the hook settings file it writes.
#   A1-A4  the real bin/agent-call.sh with a fake claude: what --settings holds.
#   H1-H12 the real hook bin/compact-recheck.sh on scratch git repos.
#   S1     the seed rows in the composed worker/jobs/schema.sql.
# WHAT IS NOT PROVEN HERE: that the real claude CLI fires SessionStart with
# source "compact". That is the CLI's documented contract on 2.x.
# Each case builds its own scratch tree under $T/<case>; no case reads another's.
# Run from anywhere: tests/compact-recheck.bh-9049-test.sh (exit 0 = all pass)
# The checks read output from a here-string (grep -q X <<<"$(ctx ...)"), never
# a pipe: a grep -q that exits at its first match can SIGPIPE the writer.
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TAB=$(printf '\t')
unset COMPACT_RECHECK_ENABLED # the cases set it themselves (K6); an ambient value must not leak in

HOOK_SRC="$DIR/bin/compact-recheck.sh"
LIB_SRC="$DIR/bin/lib/compact-recheck.sh"
CLASSIFY_SRC="$DIR/bin/lib/mc/classify.sh"

# mkh <dir> — a scratch HARNESS: the hook and its source closure (its lib and
# the scanner, bin/lib/mc/classify.sh), checks-run, checks/ and the two rules
# topics, copied from this checkout.
mkh() {
  local h="$1"
  mkdir -p "$h/bin/lib/mc" "$h/rules/topics" "$h/logs" "$h/state"
  scratch_install_closure bin/compact-recheck.sh "$h" >/dev/null || bad "mkh: closure of bin/compact-recheck.sh not installed in $h"
  cp "$DIR/bin/checks-run.sh" "$h/bin/checks-run.sh"
  cp -R "$DIR/checks" "$h/checks"
  cp "$DIR/rules/topics/01-iron-guardrails.md" "$DIR/rules/topics/04-building-software.md" "$h/rules/topics/"
  chmod +x "$h/bin/"*.sh 2>/dev/null
}

# mkrepo <dir> — a git repo with one commit on main and a branch "feat".
mkrepo() {
  local r="$1"
  mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@example.test; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false
  printf 'readme\n' > "$r/README"
  git -C "$r" add README; git -C "$r" commit -q -m init
  git -C "$r" checkout -q -b feat
}

# run_hook <case-dir> <cwd> <session> [source] -- env...
#   stdout -> <case>/out.json, rc -> <case>/rc
run_hook() {
  local c="$1" cwd="$2" sid="$3" src="${4:-compact}"; shift 4 2>/dev/null || shift $#
  mkdir -p "$c/home"
  printf '{"session_id":"%s","source":"%s","cwd":"%s","hook_event_name":"SessionStart"}' "$sid" "$src" "$cwd" \
    | ( cd "$cwd" 2>/dev/null || cd "$c" || exit 1
        env HARNESS="$c/h" HOME="$c/home" COMPACT_RECHECK_JOB=job-1 COMPACT_RECHECK_PHASE=execute \
            COMPACT_RECHECK_PROJECT=cromford COMPACT_RECHECK_TIMEOUT_S=20 COMPACT_RECHECK_MAX_HITS=50 "$@" \
            bash "$c/h/bin/compact-recheck.sh" ) > "$c/out.json" 2> "$c/err.txt"
  echo $? > "$c/rc"
}
ctx()  { jq -r '.hookSpecificOutput.additionalContext // empty' "$1/out.json" 2>/dev/null; }
logl() { cat "$1/h/logs/compact-recheck.log" 2>/dev/null; }

# ---------------------------------------------------------------- P1-P3 -----
P="$T/p"; mkdir -p "$P"
cat > "$P/d.diff" <<'EOF'
diff --git a/src/agent.ts b/src/agent.ts
--- a/src/agent.ts
+++ b/src/agent.ts
@@ -1,5 +1,4 @@
 line1
-removed claude-opus-4
--- an old sql comment
 line3
+// never claude-opus in a comment
 line4
@@ -10,3 +9,4 @@
 a
 b
+const m = "claude-sonnet-4-5";
 c
diff --git a/app/page.tsx b/app/page.tsx
new file mode 100644
--- /dev/null
+++ b/app/page.tsx
@@ -0,0 +1,3 @@
+export default function P() {
+  if (window.confirm("x")) return null;
+  const n = "claude-instant-1";
diff --git a/lib/url.ts b/lib/url.ts
--- a/lib/url.ts
+++ b/lib/url.ts
@@ -3,0 +4,1 @@
+const u = process.env.VERCEL_URL;
diff --git a/tests/x.test.ts b/tests/x.test.ts
--- a/tests/x.test.ts
+++ b/tests/x.test.ts
@@ -1,0 +1,1 @@
+const m = "claude-sonnet-4-5";
diff --git a/docs/a.md b/docs/a.md
--- a/docs/a.md
+++ b/docs/a.md
@@ -1,0 +1,1 @@
+use claude-opus-4
diff --git a/scripts/migrations/seed.sql b/scripts/migrations/seed.sql
--- a/scripts/migrations/seed.sql
+++ b/scripts/migrations/seed.sql
@@ -1,0 +1,1 @@
+INSERT INTO m VALUES ('claude-haiku-4');
EOF
P_LINES=$( ( . "$CLASSIFY_SRC" 2>/dev/null; command -v mc_iron_law_lines >/dev/null 2>&1 && mc_iron_law_lines "$P/d.diff" ) )
P_EXPECT="src/agent.ts:11${TAB}claude-sonnet-4-5
app/page.tsx:2${TAB}window.confirm(
lib/url.ts:4${TAB}VERCEL_URL"
[ "$P_LINES" = "$P_EXPECT" ] && ok || bad "P1/P2 mc_iron_law_lines printed [$P_LINES], want [$P_EXPECT]"
P_NAMES=$( ( . "$CLASSIFY_SRC" 2>/dev/null; mc_iron_law_names "$P/d.diff" ) )
[ "$P_NAMES" = "src/agent.ts (claude-sonnet-4-5)
app/page.tsx (window.confirm()
lib/url.ts (VERCEL_URL)" ] && ok || bad "P3 mc_iron_law_names output changed: [$P_NAMES]"
[ "$(printf '%s\n' "$P_LINES" | grep -c .)" = "$(printf '%s\n' "$P_NAMES" | grep -c .)" ] && ok \
  || bad "P3 parity: lines vs names count differ"

# ---------------------------------------------------------------- R1-R8 -----
R="$T/r"; mkdir -p "$R"
rls() { ( . "$LIB_SRC" 2>/dev/null; command -v cr_rls_hits >/dev/null 2>&1 || { echo NO-FUNCTION; exit 0; }; cr_rls_hits "$1" ) ; }
sqlfile() { # sqlfile <path> <line>... -> a new-file diff block
  local p="$1"; shift
  printf 'diff --git a/%s b/%s\nnew file mode 100644\n--- /dev/null\n+++ b/%s\n@@ -0,0 +1,%s @@\n' "$p" "$p" "$p" "$#"
  printf '+%s\n' "$@"
}
sqlfile supabase/migrations/1_x.sql "-- a table" "CREATE TABLE foo (id int);" > "$R/r1.diff"
[ "$(rls "$R/r1.diff")" = "supabase/migrations/1_x.sql:2${TAB}rls-missing" ] && ok || bad "R1 no ALTER: got [$(rls "$R/r1.diff")]"
sqlfile supabase/migrations/2_x.sql "CREATE TABLE IF NOT EXISTS public.bar (id int);" "ALTER TABLE baz ENABLE ROW LEVEL SECURITY;" > "$R/r2.diff"
[ "$(rls "$R/r2.diff")" = "supabase/migrations/2_x.sql:1${TAB}rls-missing" ] && ok || bad "R2 other table's ALTER: got [$(rls "$R/r2.diff")]"
sqlfile m/3.sql "CREATE TABLE app.foo (id int);" "ALTER TABLE public.foo ENABLE ROW LEVEL SECURITY;" > "$R/r3.diff"
[ "$(rls "$R/r3.diff")" = "m/3.sql:1${TAB}rls-missing" ] && ok || bad "R3 other schema: got [$(rls "$R/r3.diff")]"
sqlfile m/4.sql "CREATE TABLE foo (id int);" "ALTER TABLE foo ENABLE ROW LEVEL SECURITY;" > "$R/r4.diff"
[ -z "$(rls "$R/r4.diff")" ] && ok || bad "R4 same-file ALTER: got [$(rls "$R/r4.diff")]"
{ sqlfile m/5a.sql 'create table "Foo" (id int);'; sqlfile m/5b.sql 'alter table public."foo" enable row level security;'; } > "$R/r5.diff"
[ -z "$(rls "$R/r5.diff")" ] && ok || bad "R5 case/quotes/schema across files: got [$(rls "$R/r5.diff")]"
{ sqlfile worker/jobs/schema.d/2026_x.sql "CREATE TABLE t1 (id int);"; sqlfile tests/fixtures/a.sql "CREATE TABLE t2 (id int);"; } > "$R/r6.diff"
[ -z "$(rls "$R/r6.diff")" ] && ok || bad "R6 worker/ and tests/: got [$(rls "$R/r6.diff")]"
{ sqlfile m/7.sql "-- CREATE TABLE foo (id int);" "CREATE TEMP TABLE t (id int);"
  printf 'diff --git a/m/7b.sql b/m/7b.sql\n--- a/m/7b.sql\n+++ b/m/7b.sql\n@@ -1,1 +0,0 @@\n-CREATE TABLE z (id int);\n'; } > "$R/r7.diff"
[ -z "$(rls "$R/r7.diff")" ] && ok || bad "R7 comment/temp/removed: got [$(rls "$R/r7.diff")]"
sqlfile src/db.ts 'await sql`CREATE TABLE foo (id int)`;' > "$R/r8.diff"
[ -z "$(rls "$R/r8.diff")" ] && ok || bad "R8 .ts file: got [$(rls "$R/r8.diff")]"

# ---------------------------------------------------------------- K1-K6 -----
K="$T/k"; mkh "$K/h"
# kcall <settings-rows> <stage> <project> <out> [miss-rc] -> prints "CR=<path>|JOB=..|BD=..|PH=..|TO=..|MH=..", keys to $K/keys
kcall() {
  printf '%s' "$1" > "$K/rows.tsv"; : > "$K/keys"
  ( export HARNESS="$K/h"
    unset COMPACT_RECHECK_JOB COMPACT_RECHECK_PHASE COMPACT_RECHECK_PROJECT COMPACT_RECHECK_BUILD_DIR COMPACT_RECHECK_TIMEOUT_S COMPACT_RECHECK_MAX_HITS
    setting_get() { echo "$1" >> "$K/keys"; local l; l=$(grep -m1 "^$1${TAB}" "$K/rows.tsv") || return "${MISS_RC:-2}"; printf '%s' "${l#*"$TAB"}"; }
    MISS_RC="${5:-2}"
    . "$LIB_SRC" 2>/dev/null || { echo "NO-LIB"; exit 0; }
    compact_recheck_settings "$2" "$3" "$4"
    printf 'CR=%s|JOB=%s|BD=%s|PH=%s|TO=%s|MH=%s\n' "${CR_SETTINGS:-}" "${COMPACT_RECHECK_JOB:-}" "${COMPACT_RECHECK_BUILD_DIR:-}" \
      "$(env | sed -n 's/^COMPACT_RECHECK_PHASE=//p')" "${COMPACT_RECHECK_TIMEOUT_S:-}" "${COMPACT_RECHECK_MAX_HITS:-}" )
}
ON="build.compact_recheck.cromford.enabled${TAB}1"
SF="$K/h/state/compact-recheck-settings.json"
got=$(kcall "$ON" execute cromford "$K/builds/cromford-X-1/execute-run.txt")
[ "$got" = "CR=$SF|JOB=cromford-X-1|BD=$K/builds/cromford-X-1|PH=execute|TO=30|MH=50" ] && ok || bad "K1 execute+on: $got"
[ "$(jq -r '.hooks.SessionStart[0].matcher' "$SF" 2>/dev/null)" = compact ] && ok || bad "K1 matcher not compact: $(cat "$SF" 2>/dev/null)"
[ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$SF" 2>/dev/null)" = "$K/h/bin/compact-recheck.sh" ] && ok || bad "K1 command wrong"
[ "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$SF" 2>/dev/null)" = 30 ] && ok || bad "K1 timeout not 30"
for st in plan fix; do
  got=$(kcall "$ON" "$st" cromford "$K/state/rounds/ck7.fix-run.txt")
  [ "$got" = "CR=$SF|JOB=ck7|BD=|PH=$st|TO=30|MH=50" ] && ok || bad "K1 $st+on: $got"
done
got=$(kcall "$ON
build.compact_recheck.timeout_s${TAB}12
build.compact_recheck.max_hits${TAB}7" execute cromford "$K/o.txt")
[ "$got" = "CR=$SF|JOB=o|BD=|PH=execute|TO=12|MH=7" ] && ok || bad "K1 knob values: $got"
[ "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$SF" 2>/dev/null)" = 12 ] && ok || bad "K1 timeout knob not in file"
for rows in "build.compact_recheck.cromford.enabled${TAB}0" "" "build.compact_recheck.cromford.enabled${TAB}true"; do
  got=$(kcall "$rows" execute cromford "$K/o.txt")
  [ "$got" = "CR=|JOB=|BD=|PH=|TO=|MH=" ] && ok || bad "K2 off for rows [$rows]: $got"
done
got=$(kcall "" execute cromford "$K/o.txt" 1)
[ "$got" = "CR=|JOB=|BD=|PH=|TO=|MH=" ] && ok || bad "K2 outage: $got"
for st in review triage execute-advisor; do
  got=$(kcall "$ON" "$st" cromford "$K/o.txt")
  [ "$got" = "CR=|JOB=|BD=|PH=|TO=|MH=" ] && ok || bad "K3 $st: $got"
done
got=$(kcall "build.compact_recheck.otherproj.enabled${TAB}1" execute cromford "$K/o.txt")
[ "$got" = "CR=|JOB=|BD=|PH=|TO=|MH=" ] && ok || bad "K4 other project's row turned it on: $got"
grep -qx 'build.compact_recheck.cromford.enabled' "$K/keys" && ok || bad "K4 key read: $(cat "$K/keys")"
# K6 the env override COMPACT_RECHECK_ENABLED is read before the row: 1 with
# no row turns it on, 0 over a row of 1 turns it off, and it never opens a
# stage outside plan/execute/fix.
got=$(COMPACT_RECHECK_ENABLED=1 kcall "" execute cromford "$K/o.txt")
[ "$got" = "CR=$SF|JOB=o|BD=|PH=execute|TO=30|MH=50" ] && ok || bad "K6 env 1, no row: $got"
got=$(COMPACT_RECHECK_ENABLED=0 kcall "$ON" execute cromford "$K/o.txt")
[ "$got" = "CR=|JOB=|BD=|PH=|TO=|MH=" ] && ok || bad "K6 env 0 over row 1: $got"
got=$(COMPACT_RECHECK_ENABLED=1 kcall "" review cromford "$K/o.txt")
[ "$got" = "CR=|JOB=|BD=|PH=|TO=|MH=" ] && ok || bad "K6 env 1 on review: $got"
for v in abc 0; do
  got=$(kcall "$ON
build.compact_recheck.timeout_s${TAB}$v
build.compact_recheck.max_hits${TAB}$v" execute cromford "$K/o.txt")
  [ "$got" = "CR=$SF|JOB=o|BD=|PH=execute|TO=30|MH=50" ] && ok || bad "K5 bad value $v: $got"
done

# ---------------------------------------------------------------- A1-A4 -----
A="$T/a"; mkh "$A"; mkdir -p "$A/fakebin" "$A/.claude" "$A/wt" "$A/flags" "$A/locks" "$A/builds/bh-1"
cat > "$A/fakebin/claude" <<'EOF'
#!/bin/bash
prev=""
for a in "$@"; do [ "$prev" = --settings ] && cp "$a" "$SETTINGS_SINK"; prev="$a"; done
printf '{"result":"ok","usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0.01}\n'
EOF
printf '#!/bin/bash\necho subscription\n' > "$A/fakebin/billing-mode.sh"
cat > "$A/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\nexit 0\n' > "$A/bin/iron-law-guard.sh"
chmod +x "$A/fakebin/"* "$A/bin/iron-law-guard.sh"
# The jobs client, stubbed: setting_get answers from $A/rows.tsv, rc 2 = no row.
cat > "$A/bin/jobs-client.sh" <<EOF
setting_get() { local l; l=\$(grep -m1 "^\$1${TAB}" "$A/rows.tsv") || return 2; printf '%s' "\${l#*${TAB}}"; }
EOF
printf '{"enabledPlugins":{"vercel@claude-plugins-official":true}}\n' > "$A/.claude/settings.json"
acall() { # acall <rows> <stage> [env...]
  printf '%s' "$1" > "$A/rows.tsv"; local st="$2"; shift 2
  rm -f "$A/settings.out"
  ( cd "$A/wt" || exit 1
    export SETTINGS_SINK="$A/settings.out" PATH="$A/fakebin:$PATH" HARNESS="$A" HOME="$A" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" LANE_GATE_DISABLE=1
    unset CLAUDE_CONFIG_DIR SESSION_PROFILE_STAGES EDIT_FEEDBACK AGENT_SETTINGS
    env "$@" bash "$DIR/bin/agent-call.sh" "$st" cromford claude-opus-5-5 60 "$A/builds/bh-1/$st-run.txt" "hello" >/dev/null 2>&1 )
}
acall "$ON" execute
[ "$(jq -r '.hooks.SessionStart[0].matcher' "$A/settings.out" 2>/dev/null)" = compact ] && ok \
  || bad "A1 --settings has no SessionStart compact hook: $(cat "$A/settings.out" 2>/dev/null)"
[ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$A/settings.out" 2>/dev/null)" = "$A/bin/compact-recheck.sh" ] && ok || bad "A1 hook command wrong"
[ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$A/settings.out" 2>/dev/null)" = "$A/bin/iron-law-guard.sh" ] && ok \
  || bad "A2 the iron-law guard is gone from the merged settings"
acall "$ON" execute SESSION_PROFILE_STAGES=execute
[ "$(jq -r '.enabledPlugins["vercel@claude-plugins-official"]' "$A/settings.out" 2>/dev/null)" = false ] && ok \
  || bad "A3 session profile plugin override lost: $(cat "$A/settings.out" 2>/dev/null)"
jq -e '.hooks.SessionStart and .hooks.PreToolUse' "$A/settings.out" >/dev/null 2>&1 && ok || bad "A3 hooks lost with the profile on"
acall "build.compact_recheck.cromford.enabled${TAB}0" execute
[ -s "$A/settings.out" ] && ok || bad "A4 no --settings at all (the guard must still be there)"
jq -e '.hooks | has("SessionStart") | not' "$A/settings.out" >/dev/null 2>&1 && ok || bad "A4 knob off still installed the hook"
acall "$ON" review
jq -e '.hooks | has("SessionStart") | not' "$A/settings.out" >/dev/null 2>&1 && ok || bad "A4 review stage got the hook"

# ---------------------------------------------------------------- H1-H12 ----
# H1: a committed claude- string and an uncommitted CREATE TABLE with no RLS.
C="$T/h1"; mkh "$C/h"; mkrepo "$C/r"
mkdir -p "$C/r/src" "$C/r/supabase/migrations"
printf 'export const a = 1;\nexport const m = "claude-sonnet-4-5";\n' > "$C/r/src/agent.ts"
git -C "$C/r" add src; git -C "$C/r" commit -q -m agent
printf 'CREATE TABLE foo (id int);\n' > "$C/r/supabase/migrations/1_a.sql"
run_hook "$C" "$C/r" s-h1
[ "$(cat "$C/rc")" = 0 ] && ok || bad "H1 rc $(cat "$C/rc")"
grep -qx 'iron-law scan after compaction: src/agent.ts:2 model-id' <<<"$(ctx "$C")" && ok || bad "H1 model-id hit not printed: $(ctx "$C" | grep 'iron-law scan' ; cat "$C/err.txt")"
grep -qx 'iron-law scan after compaction: supabase/migrations/1_a.sql:1 rls-missing' <<<"$(ctx "$C")" && ok || bad "H1 rls-missing hit not printed"
grep -qx 'Fix each hit now, before you continue.' <<<"$(ctx "$C")" && ok || bad "H1 no fix line"
[ "$(jq -r '.hookSpecificOutput.hookEventName' "$C/out.json" 2>/dev/null)" = SessionStart ] && ok || bad "H1 hookEventName"
grep -q ' compact-recheck job=job-1 phase=execute project=cromford session=s-h1 compaction=1 hits=2 rules=ok scan=ok' <<<"$(logl "$C")" && ok \
  || bad "H1 log line: $(logl "$C")"

# H2: clean diff.
C="$T/h2"; mkh "$C/h"; mkrepo "$C/r"
printf 'fine\n' > "$C/r/ok.txt"; git -C "$C/r" add ok.txt; git -C "$C/r" commit -q -m ok
run_hook "$C" "$C/r" s-h2
[ "$(logl "$C" | wc -l | tr -d ' ')" = 1 ] && ok || bad "H2 not exactly one log line: $(logl "$C")"
grep -q ' hits=0 rules=ok scan=ok' <<<"$(logl "$C")" && ok || bad "H2 log: $(logl "$C")"
grep -qE '^iron-law scan after compaction: 0 hits against [0-9a-f]{8}\.$' <<<"$(ctx "$C")" && ok || bad "H2 no 0-hits line: $(ctx "$C" | tail -3)"
grep -q 'Fix each hit' <<<"$(ctx "$C")" && bad "H2 fix line on a clean diff" || ok
grep -q '^IRON LAWS, re-read after context compaction' <<<"$(ctx "$C")" && ok || bad "H2 no rules header"

# H3: the scanner is missing.
C="$T/h3"; mkh "$C/h"; mkrepo "$C/r"; rm -f "$C/h/bin/lib/mc/classify.sh"
printf 'const m = "claude-opus-4";\n' > "$C/r/x.ts"
run_hook "$C" "$C/r" s-h3
[ "$(cat "$C/rc")" = 0 ] && ok || bad "H3 rc $(cat "$C/rc")"
grep -q '^## Iron guardrails' <<<"$(ctx "$C")" && ok || bad "H3 rules block missing"
grep -q '^iron-law scan after compaction: not run (scanner missing' <<<"$(ctx "$C")" && ok || bad "H3 context: $(ctx "$C" | tail -2)"
grep -qE ' scan=missing:[a-z]' <<<"$(logl "$C")" && ok || bad "H3 log: $(logl "$C")"

# H4: the rules block is read from rules/topics at hook time.
C="$T/h4"; mkh "$C/h"; mkrepo "$C/r"
run_hook "$C" "$C/r" s-h4
grep -q '^## Iron guardrails' <<<"$(ctx "$C")" && ok || bad "H4 no guardrails heading"
grep -q '^### Data & config iron laws' <<<"$(ctx "$C")" && ok || bad "H4 no data & config heading"
grep -q 'Additive-only schema changes' <<<"$(ctx "$C")" && ok || bad "H4 data & config body missing"
grep -q '^### UI/UX standards' <<<"$(ctx "$C")" && bad "H4 UI/UX section leaked in" || ok
printf '\n- PROBE-LINE-H4 a new iron law.\n' >> "$C/h/rules/topics/01-iron-guardrails.md"
run_hook "$C" "$C/r" s-h4b
grep -q 'PROBE-LINE-H4' <<<"$(ctx "$C")" && ok || bad "H4 a topic edit did not change the output"
rm -f "$C/h/rules/topics/"*.md; mkdir -p "$C/home/.claude"
cp "$DIR/rules/CLAUDE.md" "$C/home/.claude/CLAUDE.md"
run_hook "$C" "$C/r" s-h4c
grep -q '^## Iron guardrails' <<<"$(ctx "$C")" && grep -q '^### Data & config iron laws' <<<"$(ctx "$C")" && ok || bad "H4 CLAUDE.md fallback"
grep -q '^### UI/UX standards' <<<"$(ctx "$C")" && bad "H4 fallback: UI/UX leaked" || ok
grep -q '^## Product Board Triage' <<<"$(ctx "$C")" && bad "H4 fallback: triage section leaked" || ok
rm -f "$C/home/.claude/CLAUDE.md"
run_hook "$C" "$C/r" s-h4d
[ "$(cat "$C/rc")" = 0 ] && ok || bad "H4 no rules: rc $(cat "$C/rc")"
grep -q ' rules=missing ' <<<"$(logl "$C" | tail -1)" && ok || bad "H4 no rules: log $(logl "$C" | tail -1)"

# H5: cwd is not a git tree.
C="$T/h5"; mkh "$C/h"; mkdir -p "$C/plain"
run_hook "$C" "$C/plain" s-h5
[ "$(cat "$C/rc")" = 0 ] && ok || bad "H5 rc"
grep -q ' scan=skipped:not-a-git-tree' <<<"$(logl "$C")" && ok || bad "H5 log: $(logl "$C")"
grep -q '^iron-law scan after compaction: not run (not-a-git-tree)\.$' <<<"$(ctx "$C")" && ok || bad "H5 context"

# H6: no base ref (the only branch is not main, no origin).
C="$T/h6"; mkh "$C/h"; mkdir -p "$C/r"; git -C "$C/r" init -q -b solo
git -C "$C/r" -c user.email=t@e -c user.name=t commit -q --allow-empty -m x
run_hook "$C" "$C/r" s-h6
[ "$(cat "$C/rc")" = 0 ] && ok || bad "H6 rc"
grep -q ' scan=skipped:no-base' <<<"$(logl "$C")" && ok || bad "H6 log: $(logl "$C")"

# H7: an untracked new file is scanned.
C="$T/h7"; mkh "$C/h"; mkrepo "$C/r"; mkdir -p "$C/r/app"
printf 'export function f() {\n  return window.confirm("sure?");\n}\n' > "$C/r/app/page.tsx"
run_hook "$C" "$C/r" s-h7
grep -qx 'iron-law scan after compaction: app/page.tsx:2 native-dialog' <<<"$(ctx "$C")" && ok || bad "H7 untracked hit: $(ctx "$C" | grep 'iron-law scan')"

# H8: a git that hangs past the step timeout, and a box with no jq.
C="$T/h8"; mkh "$C/h"; mkrepo "$C/r"; mkdir -p "$C/slowbin"
printf '#!/bin/bash\nsleep 30\n' > "$C/slowbin/git"; chmod +x "$C/slowbin/git"
start=$(date +%s)
run_hook "$C" "$C/r" s-h8 compact PATH="$C/slowbin:$PATH" COMPACT_RECHECK_TIMEOUT_S=4
el=$(( $(date +%s) - start ))
[ "$(cat "$C/rc")" = 0 ] && ok || bad "H8 hang: rc $(cat "$C/rc")"
[ "$el" -lt 15 ] && ok || bad "H8 hang: the hook took ${el}s"
grep -q ' scan=failed:timeout' <<<"$(logl "$C")" && ok || bad "H8 hang log: $(logl "$C")"
# NOJQ: every tool on PATH except jq, claude and curl.
NJ="$T/nojq"; mkdir -p "$NJ"
IFS=: read -r -a _pd <<<"$PATH"
for d in "${_pd[@]}"; do
  [ -d "$d" ] || continue
  for b in "$d"/*; do
    n="${b##*/}"; case "$n" in jq|claude|curl|wget) continue ;; esac
    [ -e "$NJ/$n" ] || ln -s "$b" "$NJ/$n" 2>/dev/null
  done
done
C="$T/h8b"; mkh "$C/h"; mkrepo "$C/r"; printf 'const m = "claude-haiku-4";\n' > "$C/r/x.ts"
run_hook "$C" "$C/r" s-h8b compact PATH="$NJ"
[ "$(cat "$C/rc")" = 0 ] && ok || bad "H8 no jq: rc $(cat "$C/rc")"
grep -q '^IRON LAWS, re-read after context compaction' "$C/out.json" && ok || bad "H8 no jq: no plain context: $(head -3 "$C/out.json")"
grep -qx 'iron-law scan after compaction: x.ts:1 model-id' "$C/out.json" && ok || bad "H8 no jq: hit not printed"
grep -q ' session=s-h8b .* hits=1 .*scan=ok.* out=plain' <<<"$(logl "$C")" && ok || bad "H8 no jq: log $(logl "$C")"

# H9: the compaction count, the build-dir log and the note's awk.
C="$T/h9"; mkh "$C/h"; mkrepo "$C/r"; mkdir -p "$C/build"
printf 'const m = "claude-opus-4";\n' > "$C/r/y.ts"
run_hook "$C" "$C/r" s-h9 compact COMPACT_RECHECK_BUILD_DIR="$C/build"
run_hook "$C" "$C/r" s-h9 compact COMPACT_RECHECK_BUILD_DIR="$C/build"
run_hook "$C" "$C/r" other compact
grep -q ' session=s-h9 compaction=1 hits=1 ' <<<"$(logl "$C" | sed -n 1p)" && ok || bad "H9 first: $(logl "$C" | sed -n 1p)"
grep -q ' session=s-h9 compaction=2 hits=1 ' <<<"$(logl "$C" | sed -n 2p)" && ok || bad "H9 second: $(logl "$C" | sed -n 2p)"
grep -q ' session=other compaction=1 ' <<<"$(logl "$C" | sed -n 3p)" && ok || bad "H9 other session: $(logl "$C" | sed -n 3p)"
[ "$(grep -c ' session=s-h9 ' "$C/build/compact-recheck.log" 2>/dev/null)" = 2 ] && ok || bad "H9 build-dir log"
NOTE="$DIR/docs/notes/2026-11-04-BH-9049-compact-recheck.md"
AWK_LINE=$(grep -m1 "^awk '" "$NOTE" 2>/dev/null)
if [ -n "$AWK_LINE" ]; then
  LOG="$C/h/logs/compact-recheck.log"
  got=$(eval "$AWK_LINE" | sort)
  [ "$got" = "job-1 3 2 3" ] && ok || bad "H9 the note's awk read [$got], want [job-1 3 2 3]"
else bad "H9 no awk line in $NOTE"; fi

# H10: a non-compact source does nothing; no model or network tool on PATH.
C="$T/h10"; mkh "$C/h"; mkrepo "$C/r"
run_hook "$C" "$C/r" s-h10 startup PATH="$NJ"
[ "$(cat "$C/rc")" = 0 ] && ok || bad "H10 rc"
[ -s "$C/out.json" ] && bad "H10 startup printed: $(cat "$C/out.json")" || ok
[ -s "$C/h/logs/compact-recheck.log" ] && bad "H10 startup logged" || ok
run_hook "$C" "$C/r" s-h10 compact PATH="$NJ"
grep -q 'IRON LAWS' "$C/out.json" && ok || bad "H10 compact with no claude/curl on PATH printed nothing"

# H11: the hit cap.
C="$T/h11"; mkh "$C/h"; mkrepo "$C/r"
printf 'a = "claude-opus-4";\nb = "claude-opus-4";\nc = "claude-opus-4";\nd = "claude-opus-4";\n' > "$C/r/z.ts"
run_hook "$C" "$C/r" s-h11 compact COMPACT_RECHECK_MAX_HITS=2
[ "$(ctx "$C" | grep -c '^iron-law scan after compaction: z.ts:[0-9]* model-id$')" = 2 ] && ok || bad "H11 not 2 hit lines: $(ctx "$C" | grep 'iron-law scan')"
grep -qx 'iron-law scan after compaction: 2 more hit(s) not shown' <<<"$(ctx "$C")" && ok || bad "H11 no overflow line"
grep -q ' hits=4 ' <<<"$(logl "$C")" && ok || bad "H11 log: $(logl "$C")"

# H12: an untracked file named like a git option is a path, not an option. Without
# the "--" before the paths, git diff --no-index read "--output=README" as its
# --output option and truncated the tracked README.
C="$T/h12"; mkh "$C/h"; mkrepo "$C/r"
touch -- "$C/r/--output=README"
printf 'a = "claude-opus-4";\n' > "$C/r/y.ts"
run_hook "$C" "$C/r" s-h12
[ "$(cat "$C/r/README")" = readme ] && ok || bad "H12 tracked README changed: '$(cat "$C/r/README")'"
[ -z "$(git -C "$C/r" status --porcelain --untracked-files=no)" ] && ok || bad "H12 tracked tree dirty: $(git -C "$C/r" status --porcelain --untracked-files=no)"
grep -qx 'iron-law scan after compaction: y.ts:1 model-id' <<<"$(ctx "$C")" && ok || bad "H12 scan did not run: $(logl "$C")"

# ---------------------------------------------------------------- S1 --------
S="$T/s"; mkdir -p "$S"
bash "$DIR/bin/schema-build.sh" --root "$DIR" --to "$S/schema.sql" >/dev/null 2>&1
seed() { grep -oE "\('$1','[^']*'" "$S/schema.sql" | head -1 | sed -E "s/^\('[^']*','//; s/'\$//"; }
[ "$(seed 'build\.compact_recheck\.cromford\.enabled')" = 1 ] && ok || bad "S1 enabled seed"
[ "$(seed 'build\.compact_recheck\.timeout_s')" = 30 ] && ok || bad "S1 timeout_s seed"
[ "$(seed 'build\.compact_recheck\.max_hits')" = 50 ] && ok || bad "S1 max_hits seed"
grep -qE "^CR_TIMEOUT_FALLBACK=30 " "$LIB_SRC" && grep -qE "^CR_MAX_HITS_FALLBACK=50 " "$LIB_SRC" && ok || bad "S1 code fallbacks differ from the seeds"
grep -q . <<<"$(grep -E "'build\.compact_recheck\.[a-z_-]+\.enabled'" "$S/schema.sql" | grep -v cromford)" \
  && bad "S1 a non-cromford enabled row is seeded" || ok

echo "compact-recheck.bh-9049: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
