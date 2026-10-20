#!/bin/bash
# tests/migration-index-lint.bh-7667-test.sh — BH-7667: the deterministic
# migration index lint (bin/lib/migration-index-lint.sh) in the lead review
# (bin/lead-review.sh) and the box review (bin/review-prs.sh).
#
#   U1  the decision table: P1-P8 flag at the CREATE line, N1-N9 do not (every
#       diff is written by real git, the same writer both lanes read)
#   U2  replay: the 0338 (#2016) and 0322 (#1920) fixtures as new files give
#       exactly 2 findings, :61 and :54 (the fixtures are reconstructions, see
#       tests/fixtures/bh-7667/README.md)
#   U3  mil_tables: the env knob, no setting_get, a settings row; the seed
#       fragment and the composed schema carry review.large_tables.project-6-os
#   U4  the catalog: rl_line_blocks keeps the lint line and the untagged LLM
#       line, not a CONCURRENTLY line; rl_cap keeps the lint line standing
#   LR1-LR5 the real bin/lead-review.sh block as the body of review(): red is a
#       BLOCK report with no agent call; clean and no-row reach the agent (no
#       row reads no diff); a failed git diff is left running; it sits after
#       the console qa gate and before the patch-same replay
#   RP1-RP4 the real bin/review-prs.sh blocks: a red lint turns an APPROVE into
#       REQUEST_CHANGES that verdict_parse reads; no lint and no verdict change
#       nothing; the diff block fills RP_MIL from a real diff; the reuse
#       condition names RP_MIL
#   M1-M4 mutants: no CONCURRENTLY test fails N1; no comment strip fails N4b
#       and P1;
#       the lead red arm cut fails LR1; the box block cut fails RP1
# Run: HARNESS_TEST_SANDBOX=1 bash tests/migration-index-lint.bh-7667-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/migration-index-lint.sh"
LR="$DIR/bin/lead-review.sh"
RP="$DIR/bin/review-prs.sh"
FIX="$DIR/tests/fixtures/bh-7667"
export HARNESS="$DIR" VERDICT_WINDOW_LINES=3
export GIT_AUTHOR_DATE="2026-10-20T07:00:00Z" GIT_COMMITTER_DATE="2026-10-20T07:00:00Z"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset REVIEW_LEVEL_LARGE_TABLES REVIEW_LEVEL_MODE
unset -f setting_get 2>/dev/null
[ -r "$LIB" ] || { echo "FAIL: no bin/lib/migration-index-lint.sh"; exit 1; }
. "$DIR/bin/lib/review-level.sh" || { echo "FAIL: cannot source bin/lib/review-level.sh"; exit 1; }
. "$DIR/bin/lib/verdict-parse.sh" || { echo "FAIL: cannot source bin/lib/verdict-parse.sh"; exit 1; }
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

# gdiff <case> <path> <base-text|-> <head-text> — a scratch repo with <path>
# at <base-text> (- = absent) on tag scratch-base and <head-text> on HEAD; prints
# the diff file path. The diff is real git output.
gdiff() {
  local c="$1" p="$2" b="$3" h="$4" g="$T/g/$1"
  mkdir -p "$g"; git -C "$g" init -q -b main >/dev/null 2>&1
  mkdir -p "$g/$(dirname "$p")"
  if [ "$b" != - ]; then printf '%s\n' "$b" > "$g/$p"; git -C "$g" add -A; fi
  git -C "$g" commit -q --allow-empty -m base
  git -C "$g" tag scratch-base
  printf '%s\n' "$h" > "$g/$p"; git -C "$g" add -A; git -C "$g" commit -q -m head
  git -C "$g" -c diff.noprefix=false diff --no-color scratch-base...HEAD > "$T/g/$c.diff"
  printf '%s' "$T/g/$c.diff"
}
# u1 <lib> <case> <expect-line|none> <path> <base> <head> [tables]
u1() {
  local lib="$1" c="$2" want="$3" p="$4" b="$5" h="$6" tb="${7-event}" d out rc
  d=$(gdiff "$c" "$p" "$b" "$h")
  out=$(bash -c '. "$1" || exit 9; mil_scan "$2" "$3" mk' _ "$lib" "$d" "$tb"); rc=$?
  if [ "$want" = none ]; then
    [ "$rc" = 0 ] && [ -z "$out" ] && return 0
    echo "$c: want no finding, got rc $rc [$out]"; return 1
  fi
  [ "$rc" = 1 ] && [ "$(grep -c . <<<"$out")" = 1 ] \
    && grep -qF -- "- [BLOCK destructive-migration] $p:$want: CREATE INDEX on large table event without CONCURRENTLY" <<<"$out" && return 0
  echo "$c: want one finding at $p:$want, got rc $rc [$out]"; return 1
}

# ── U1 the decision table ─────────────────────────────────────────────────────
P1='-- MK: connector index
-- second line
CREATE INDEX IF NOT EXISTS i ON event ("orgId");'
U1_CASES=(
  "P1|3|prisma/sql/0001_a.sql|-|$P1"
  "P2|1|db/m/0002.SQL|-|create unique index i on public.event(a);"
  "P3|2|m/0003.sql|-|SELECT 1;
CREATE INDEX i
  ON \"event\" (a);"
  "P4|1|m/0004.sql|-|CREATE INDEX i ON ONLY event (a);"
  "P5|1|m/0005.sql|-|CREATE INDEX event_concurrently_idx ON event (a);"
  "P6|1|m/0006.sql|-|CREATE INDEX i ON EVENT (a); -- use CONCURRENTLY later"
  "P7|1|m/0007.sql|CREATE INDEX i
  ON event_old (a);|CREATE INDEX i
  ON event (a);"
  "P8|1|m/0008.sql|-- old comment
SELECT 1;|CREATE INDEX i ON event (a);
SELECT 1;"
  "N1|none|m/n1.sql|-|CREATE INDEX CONCURRENTLY IF NOT EXISTS i ON event (a);"
  "N2|none|m/n2.sql|-|CREATE UNIQUE INDEX CONCURRENTLY i ON event (a);"
  "N3|none|m/n3.sql|-|CREATE INDEX i ON event_log (a);
CREATE INDEX j ON events (a);
CREATE INDEX k ON \"eventType\" (a);"
  "N4|none|m/n4.sql|-|--   1. CREATE INDEX IF NOT EXISTS i ON event (a);"
  "N4b|none|m/n4b.sql|-|-- run this first; CREATE INDEX i ON event (a);
SELECT 1;"
  "N5|none|m/n5.sql|-|/* CREATE INDEX i
   ON event (a); */
SELECT 1;"
  "N6|none|src/db.ts|-|CREATE INDEX IF NOT EXISTS i ON event (\"orgId\");"
  "N7|none|m/n7.sql|CREATE INDEX IF NOT EXISTS i ON event (\"orgId\");
SELECT 1;|SELECT 1;"
  "N8|none|m/n8.sql|CREATE INDEX IF NOT EXISTS i ON event (\"orgId\");
SELECT 1;|CREATE INDEX IF NOT EXISTS i ON event (\"orgId\");
SELECT 1;
CREATE INDEX j ON small_t (a);"
)
for row in "${U1_CASES[@]}"; do
  IFS='|' read -r c want p b h <<<"$row"
  # The texts hold newlines: read the fields again from the whole row.
  b=$(printf '%s' "$row" | awk -F'|' '{print $4}' RS='\x01'); h=$(printf '%s' "$row" | awk -F'|' '{print $5}' RS='\x01')
  msg=$(u1 "$LIB" "$c" "$want" "$p" "$b" "$h") && ok || bad "U1 $msg"
done
msg=$(u1 "$LIB" N9 none m/n9.sql - "$P1" "") && ok || bad "U1 $msg"
# rc 2: an unreadable file with a list; rc 0 and no read with no list.
mil_scan "$T/nope.diff" event >/dev/null 2>&1; [ $? = 2 ] && ok || bad "U1 an unreadable diff is not rc 2"
mil_scan "$T/nope.diff" "" >/dev/null 2>&1; [ $? = 0 ] && ok || bad "U1 an empty list read the file"

# ── U2 replay ─────────────────────────────────────────────────────────────────
g="$T/replay"; mkdir -p "$g/prisma/sql"; git -C "$g" init -q -b main
git -C "$g" commit -q --allow-empty -m base; git -C "$g" tag scratch-base
cp "$FIX/0338_salesforce_connector.sql.txt" "$g/prisma/sql/0338_salesforce_connector.sql"
cp "$FIX/0322_otter_connector.sql.txt" "$g/prisma/sql/0322_otter_connector.sql"
git -C "$g" add -A; git -C "$g" commit -q -m "connectors"
git -C "$g" -c diff.noprefix=false diff --no-color scratch-base...HEAD > "$T/replay.diff"
out=$(mil_scan "$T/replay.diff" event project-6-os); rc=$?
[ "$rc" = 1 ] && [ "$(grep -c . <<<"$out")" = 2 ] \
  && grep -qF -- '- [BLOCK destructive-migration] prisma/sql/0338_salesforce_connector.sql:61: CREATE INDEX on large table event' <<<"$out" \
  && grep -qF -- '- [BLOCK destructive-migration] prisma/sql/0322_otter_connector.sql:54: CREATE INDEX on large table event' <<<"$out" \
  && ok || bad "U2 replay: rc $rc [$out]"
grep -qF 'large tables of project-6-os: event' <<<"$out" && ok || bad "U2 the finding does not name the project list: [$out]"

# ── U3 the list ───────────────────────────────────────────────────────────────
[ "$(REVIEW_LEVEL_LARGE_TABLES='Event, audit_log' bash -c '. "$1"; . "$2"; mil_tables x' _ "$DIR/bin/lib/review-level.sh" "$LIB")" = "event audit_log" ] \
  && ok || bad "U3 env knob: [$(REVIEW_LEVEL_LARGE_TABLES='Event, audit_log' bash -c '. "$1"; . "$2"; mil_tables x' _ "$DIR/bin/lib/review-level.sh" "$LIB")]"
[ -z "$(bash -c '. "$1"; . "$2"; mil_tables project-6-os' _ "$DIR/bin/lib/review-level.sh" "$LIB")" ] && ok || bad "U3 no setting_get is not an empty list"
[ -z "$(bash -c '. "$1"; mil_tables project-6-os' _ "$LIB")" ] && ok || bad "U3 no rl_knob is not an empty list"
got=$(bash -c '. "$1"; . "$2"
  setting_get() { case "$1" in review.large_tables.project-6-os) printf " event "; return 0 ;; *) return 2 ;; esac; }
  printf "%s|" "$(mil_tables project-6-os)" "$(mil_tables project-5)"' _ "$DIR/bin/lib/review-level.sh" "$LIB")
[ "$got" = "event||" ] && ok || bad "U3 settings row per project: [$got]"
FRAG="$DIR/worker/jobs/schema.d/202610200712-bh-7667-review-large-tables.sql"
grep -qF "('review.large_tables.project-6-os','event'" "$FRAG" 2>/dev/null && ok || bad "U3 the seed fragment has no project-6-os row"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/schema-build.sh" --root "$DIR" --worker jobs --to "$T/schema.sql" >/dev/null 2>"$T/schema.err" \
  && grep -qF "('review.large_tables.project-6-os','event'" "$T/schema.sql" && ok || bad "U3 the composed schema lacks the seed: $(head -3 "$T/schema.err")"

# ── U4 the catalog ────────────────────────────────────────────────────────────
LINT1=$(head -n 1 <<<"$out")
rl_line_blocks "$LINT1" && ok || bad "U4 the lint line does not stand: $LINT1"
rl_line_blocks "- [BLOCK] prisma/sql/0338_salesforce_connector.sql:61: CREATE INDEX on large table event without CONCURRENTLY blocks writes" \
  && ok || bad "U4 the untagged LLM line does not stand"
rl_line_blocks "- [BLOCK] CREATE INDEX CONCURRENTLY on a small table" && bad "U4 a CONCURRENTLY line stands" || ok
printf 'Findings\n%s\n- [BLOCK] card padding is 14 px\n\nVERDICT: BLOCK\n' "$LINT1" > "$T/u4.md"
k=$(rl_cap "$T/u4.md" project-6-os --approve MERGE-WITH-NOTES --block BLOCK --lens lead 2>/dev/null)
grep -q 'standing=1' <<<"$k" && grep -q 'verdict=BLOCK\|verdict=unchanged' <<<"$k" && grep -qx 'VERDICT: BLOCK' "$T/u4.md" && grep -qxF -- "$LINT1" "$T/u4.md" \
  && ok || bad "U4 rl_cap: [$k] $(cat "$T/u4.md")"

# ── LR the real lead block ────────────────────────────────────────────────────
# lr_cut <src> <out> — the block between its markers.
lr_cut() { awk '/^  # >>> migration index lint \(BH-7667\)/{f=1} f{print} /^  # <<< migration index lint$/{exit}' "$1" > "$2"; }
lr_cut "$LR" "$T/lr-block.sh"
grep -q 'mil_scan "\$H/tmp/lead-review-\$key-\$\$.mil"' "$T/lr-block.sh" && ok || bad "LR: no migration lint block in bin/lead-review.sh"
# lrfn <block> <out> — the block as the body of review(): its return leaves it.
lrfn() {
  { printf '%s\n' 'review() {' '  local H="$C/h" REPO_DIR="$C/repo" repo=example-org/project-6 project="${LR_PROJECT-project-6-os}"'
    printf '%s\n' '  local sha="$LR_SHA" base=main key=TK-9 pr=9 id=1 job=j1 report="$C/report.md" RVLINE="" bfp=fp'
    cat "$1"
    printf '%s\n' '  echo "AGENT_REACHED"' '}'; } > "$2"
}
lrfn "$T/lr-block.sh" "$T/lr-fn.sh"
# lr <case> <head-sql> [env...] — review() over a scratch repo whose PR head adds m/x.sql.
lr() {
  local c="$1" sql="$2" fn="${LR_FN:-$T/lr-fn.sh}"; shift 2
  local C="$T/$c"; mkdir -p "$C/h/tmp" "$C/repo"
  git -C "$C/repo" init -q -b main; git -C "$C/repo" commit -q --allow-empty -m base
  git -C "$C/repo" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$C/repo/m"; printf '%s\n' "$sql" > "$C/repo/m/x.sql"; git -C "$C/repo" add -A; git -C "$C/repo" commit -q -m head
  env C="$C" LR_SHA="$(git -C "$C/repo" rev-parse HEAD)" "$@" bash -c '
    . "$0" || exit 9; . "$1" || exit 9
    log() { printf "%s\n" "$*" >> "$C/log"; }
    job_update() { printf "%s\n" "$*" >> "$C/job"; }
    finish_done() { printf "%s|" "$@" > "$C/finish"; }
    lr_left_running() { printf "%s\n" "$*" > "$C/left"; }
    . "$2" || exit 9
    review' "$DIR/bin/lib/review-level.sh" "$LIB" "$fn" > "$C/out" 2>&1
}
# lr1_ok <case> — the red arm's evidence, as LR1 reads it.
lr1_ok() {
  local C="$T/$1" sha
  sha=$(git -C "$C/repo" rev-parse HEAD)
  ! grep -q AGENT_REACHED "$C/out" \
    && grep -qx -- '- migration lint: red' "$C/report.md" 2>/dev/null && grep -qx -- '- reviewer model: migration-lint' "$C/report.md" \
    && grep -qx 'VERDICT: BLOCK' "$C/report.md" \
    && grep -qF -- '- [BLOCK destructive-migration] m/x.sql:1: CREATE INDEX on large table event without CONCURRENTLY' "$C/report.md" \
    && [ "$(cat "$C/finish" 2>/dev/null)" = "1|j1|$sha|BLOCK|$C/report.md|migration-lint|migration lint: red|TK-9|" ] \
    && [ -z "$(ls -A "$C/h/tmp")" ]
}
lr lr1 'CREATE INDEX IF NOT EXISTS i ON event ("orgId");' REVIEW_LEVEL_LARGE_TABLES=event
lr1_ok lr1 && ok || bad "LR1: report [$(cat "$T/lr1/report.md" 2>/dev/null)] finish [$(cat "$T/lr1/finish" 2>/dev/null)] out [$(cat "$T/lr1/out")] tmp [$(ls -A "$T/lr1/h/tmp")]"
grep -q '^TK-9: migration lint red (1 finding(s)); BLOCK with no agent call$' "$T/lr1/log" && ok || bad "LR1 log: $(cat "$T/lr1/log" 2>/dev/null)"
lr lr2 'CREATE INDEX CONCURRENTLY IF NOT EXISTS i ON event ("orgId");' REVIEW_LEVEL_LARGE_TABLES=event
grep -q AGENT_REACHED "$T/lr2/out" && [ ! -e "$T/lr2/finish" ] && grep -qx 'TK-9: migration lint clean' "$T/lr2/log" && ok \
  || bad "LR2: out [$(cat "$T/lr2/out")] log [$(cat "$T/lr2/log" 2>/dev/null)]"
# LR3: no row. A git stub on PATH records any call: none is made.
mkdir -p "$T/gitstub"; printf '#!/bin/sh\necho "$*" >> "%s/gitstub/calls"\nexit 1\n' "$T" > "$T/gitstub/git"; chmod +x "$T/gitstub/git"
mkdir -p "$T/lr3"; lr lr3 'CREATE INDEX i ON event (a);'
: > "$T/gitstub/calls"
env C="$T/lr3" LR_SHA=x PATH="$T/gitstub:$PATH" bash -c '. "$0"; . "$1"
  log() { printf "%s\n" "$*" >> "$C/log3"; }; job_update() { :; }; finish_done() { echo FINISH; }; lr_left_running() { echo LEFT; }
  . "$2"; review' "$DIR/bin/lib/review-level.sh" "$LIB" "$T/lr-fn.sh" > "$T/lr3/out3" 2>&1
grep -q AGENT_REACHED "$T/lr3/out3" && [ ! -s "$T/gitstub/calls" ] && grep -qx 'TK-9: migration lint off (no review.large_tables row for project-6-os)' "$T/lr3/log3" \
  && ok || bad "LR3: out [$(cat "$T/lr3/out3")] git calls [$(cat "$T/gitstub/calls")] log [$(cat "$T/lr3/log3" 2>/dev/null)]"
# LR4: git diff fails: left running, failed, no verdict, no agent.
env C="$T/lr3" LR_SHA=x PATH="$T/gitstub:$PATH" REVIEW_LEVEL_LARGE_TABLES=event bash -c '. "$0"; . "$1"
  log() { printf "%s\n" "$*" >> "$C/log4"; }; job_update() { echo "JOB $*"; }; finish_done() { echo FINISH; }; lr_left_running() { echo "LEFT $*"; }
  . "$2"; review' "$DIR/bin/lib/review-level.sh" "$LIB" "$T/lr-fn.sh" > "$T/lr3/out4" 2>&1
grep -qx 'LEFT migration lint unreadable' "$T/lr3/out4" && grep -qx 'JOB j1 status=failed' "$T/lr3/out4" \
  && ! grep -q 'AGENT_REACHED\|FINISH' "$T/lr3/out4" && [ -s "$T/gitstub/calls" ] && ok || bad "LR4: [$(cat "$T/lr3/out4")]"
# LR5: the block follows the console qa gate and precedes the replay.
L_CQ=$(grep -n '^  # <<< console qa gate$' "$LR" | cut -d: -f1)
L_MI=$(grep -n '^  # >>> migration index lint (BH-7667)' "$LR" | cut -d: -f1)
L_RE=$(grep -n 'elif lw_replay "\$repo" "\$pr" "\$sha" "\$REPO_DIR"; then' "$LR" | cut -d: -f1)
[ -n "$L_CQ" ] && [ -n "$L_MI" ] && [ -n "$L_RE" ] && [ "$L_CQ" -lt "$L_MI" ] && [ "$L_MI" -lt "$L_RE" ] && ok \
  || bad "LR5: order console qa ${L_CQ:-none} < lint ${L_MI:-none} < replay ${L_RE:-none}"
grep -q '^\. "\$H/bin/lib/migration-index-lint.sh" 2>/dev/null || log ' "$LR" && ok || bad "LR5: bin/lead-review.sh does not source the lib"

# ── RP the real box blocks ────────────────────────────────────────────────────
rp_cut() { awk '/^  # >>> review-prs migration lint \(BH-7667/{f=1} f{print} /^  # <<< review-prs migration lint$/{exit}' "$1" > "$2"; }
rp_cut "$RP" "$T/rp-block.sh"
grep -q 'mil_merge "\$OUT_FILE.mil"' "$T/rp-block.sh" && ok || bad "RP: no migration lint block in bin/review-prs.sh"
# rp <block> <case> <review-file> <verdict> <rp_mil> — run the block, keep REVIEW and VERDICT.
rp() {
  local C="$T/$2"; mkdir -p "$C"
  env C="$C" RV="$(cat "$3")" V="$4" M="$5" bash -c '. "$0"; . "$1"
    STAMP() { echo 2026-10-20T07:00:00Z; }
    REVIEW="$RV"; VERDICT="$V"; RP_MIL="$M"; OUT_FILE="$C/out"; LOG="$C/log"; PROJECT=project-6-os; NUM=9; SHA=abcdef0123
    . "$2"
    printf "%s" "$REVIEW" > "$C/review"; printf "%s" "$VERDICT" > "$C/verdict"' "$DIR/bin/lib/verdict-parse.sh" "$LIB" "$1"
}
printf 'Clean diff. One nit.\n\n- [NOTE] a sort header\n\nTIER: 2\nVERDICT: APPROVE\n' > "$T/rv-approve.md"
rp1_ok() {
  local C="$T/$1"
  [ "$(cat "$C/verdict")" = REQUEST_CHANGES ] \
    && [ "$(verdict_parse -w 'APPROVE|REQUEST_CHANGES' "$C/review" 2>/dev/null)" = REQUEST_CHANGES ] \
    && [ "$(grep -c '^Migration index lint (BH-7667)$' "$C/review")" = 1 ] && grep -qxF -- "$LINT1" "$C/review" \
    && [ "$(grep -ci '^VERDICT' "$C/review")" = 1 ] && grep -q 'migration lint: 1 finding(s) -> REQUEST_CHANGES' "$C/log"
}
rp "$T/rp-block.sh" rp1 "$T/rv-approve.md" APPROVE "$LINT1"
rp1_ok rp1 && ok || bad "RP1: verdict [$(cat "$T/rp1/verdict")] review [$(cat "$T/rp1/review")] log [$(cat "$T/rp1/log" 2>/dev/null)]"
rp "$T/rp-block.sh" rp2 "$T/rv-approve.md" APPROVE ""
cmp -s <(printf '%s' "$(cat "$T/rv-approve.md")") "$T/rp2/review" && [ "$(cat "$T/rp2/verdict")" = APPROVE ] && [ ! -e "$T/rp2/log" ] && ok \
  || bad "RP2: no lint changed the review: [$(cat "$T/rp2/review")] [$(cat "$T/rp2/verdict")]"
printf 'garbled output\n' > "$T/rv-none.md"
rp "$T/rp-block.sh" rp2b "$T/rv-none.md" "" "$LINT1"
[ "$(cat "$T/rp2b/review")" = "garbled output" ] && [ -z "$(cat "$T/rp2b/verdict")" ] && ok || bad "RP2: an empty VERDICT was changed: [$(cat "$T/rp2b/verdict")]"
# RP3: the diff block fills RP_MIL from a real diff, only with a row.
awk '/^  # >>> review-prs migration diff lint \(BH-7667\)/{f=1} f{print} /^  # <<< review-prs migration diff lint$/{exit}' "$RP" > "$T/rp-diff.sh"
rpd() { # rpd <diff> [env...] — RP_MIL after the block
  local d="$1"; shift
  env D="$d" "$@" bash -c '. "$0"; . "$1"; STAMP() { echo S; }
    DIFF_FILE="$D"; PROJECT=project-6-os; NUM=9; SHA=abcdef0123; LOG=/dev/null
    . "$2"; printf "%s" "$RP_MIL"' "$DIR/bin/lib/review-level.sh" "$LIB" "$T/rp-diff.sh"
}
got=$(rpd "$T/replay.diff" REVIEW_LEVEL_LARGE_TABLES=event)
[ "$(grep -c 'BLOCK destructive-migration' <<<"$got")" = 2 ] && ok || bad "RP3: the diff block did not lint the replay diff: [$got] $(head -c 200 "$T/rp-diff.sh")"
[ -z "$(rpd "$T/replay.diff")" ] && ok || bad "RP3: no row still linted"
# RP4: a red lint refuses the reuse, and the scan reads the gh pr diff file.
awk '/# >>> review-prs bought/{f=1} f && /review_bought "\$SLUG" "\$NUM" "\$SHA"/{print; exit} f{print}' "$RP" | grep -q '\[ -z "\${RP_MIL:-}" \]' && ok \
  || bad "RP4: the review_bought reuse condition does not name RP_MIL"
L_GH=$(grep -n 'gh pr diff "\$NUM" -R "\$SLUG" > "\$DIFF_FILE"' "$RP" | cut -d: -f1)
L_SC=$(grep -n 'mil_scan "\$DIFF_FILE"' "$RP" | cut -d: -f1)
L_RB=$(grep -n 'review_bought "\$SLUG" "\$NUM" "\$SHA" >/dev/null' "$RP" | cut -d: -f1)
[ -n "$L_GH" ] && [ -n "$L_SC" ] && [ -n "$L_RB" ] && [ "$L_GH" -lt "$L_SC" ] && [ "$L_SC" -lt "$L_RB" ] && ok \
  || bad "RP4: order gh pr diff ${L_GH:-none} < mil_scan ${L_SC:-none} < review_bought ${L_RB:-none}"

# ── M mutants ─────────────────────────────────────────────────────────────────
sed '/if (rest ~ \/\^CONCURRENTLY/d' "$LIB" > "$T/m1.sh"
cmp -s "$LIB" "$T/m1.sh" && bad "M1 setup: the CONCURRENTLY test is not in the lib" || ok
u1 "$T/m1.sh" m1 none m/n1.sql - "CREATE INDEX CONCURRENTLY IF NOT EXISTS i ON event (a);" >/dev/null && bad "M1: N1 passes with no CONCURRENTLY test" || ok
sed 's/i = index(text, "--"); j = index(text, "\/\*")/i = 0; j = 0/' "$LIB" > "$T/m2.sh"
cmp -s "$LIB" "$T/m2.sh" && bad "M2 setup: the comment strip is not in the lib" || ok
u1 "$T/m2.sh" m2 none m/n4b.sql - "-- run this first; CREATE INDEX i ON event (a);" >/dev/null && bad "M2: N4b passes with no comment strip" || ok
u1 "$T/m2.sh" m2b 3 prisma/sql/0001_a.sql - "$P1" >/dev/null && bad "M2: P1 (comments before the CREATE) passes with no comment strip" || ok
grep -v 'finish_done "\$id" "\$job" "\$sha" BLOCK "\$report" migration-lint' "$T/lr-block.sh" > "$T/m3-block.sh"
cmp -s "$T/lr-block.sh" "$T/m3-block.sh" && bad "M3 setup: no red arm finish_done in the lead block" || ok
lrfn "$T/m3-block.sh" "$T/m3-fn.sh"
LR_FN="$T/m3-fn.sh" lr m3 'CREATE INDEX IF NOT EXISTS i ON event ("orgId");' REVIEW_LEVEL_LARGE_TABLES=event
lr1_ok m3 && bad "M3: LR1 passes with the red arm's finish_done cut" || ok
printf '  # >>> review-prs migration lint (BH-7667)\n  :\n  # <<< review-prs migration lint\n' > "$T/m4-block.sh"
rp "$T/m4-block.sh" m4 "$T/rv-approve.md" APPROVE "$LINT1"
rp1_ok m4 && bad "M4: RP1 passes with the box block cut" || ok

echo "migration-index-lint: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
