#!/bin/bash
# tests/hotfix-migrate-needs-operator.bh-9817-test.sh — BH-9817: a before-merge
# migration file the project's workflow can never apply is `needs-operator`,
# the conductor parks it, and a long hold raises one alert a day.
#
# Code under test: bin/lib/hotfix-migrate-operator.sh (hm_op_refuses,
# hm_op_step, hm_op_stop), the advisory gate branch of bin/hotfix-migrate.sh,
# the two rows of bin/lib/hotfix-migrate-knobs.sh (operator_step,
# workflow_refuses), mc_hotfix_proof in bin/lib/mc/classify.sh, the hold arm of
# bin/merge-conductor.d/bh-9403-before-merge-proof.sh and the fragment
# bin/merge-conductor.d/bh-9817-held-operator-alert.sh, and the seed fragment
# worker/jobs/schema.d/202611181628-bh-9817-hotfix-migrate-operator-seed.sql.
#
# The real stage runs end to end against a scratch $HARNESS with a fake `gh`
# (argv log, per-case fixture dir). The gate reports fed to hm_op_refuses come
# from the real bin/check-migration-appliable.sh. The conductor cases run the
# real mc_mig_hold -> mc_bm_proof -> mc_bm_held_alert path, on the comment the
# stage posted in N1. 0 network calls.
#
# Cases: N1 a GRANT file; N2 the refuse-list table (N2b strict, N2c the row);
# N3 a re-run; M1 the conductor parks; H1-H5 the held alert; S1 the seed rows.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hotfix-migrate-needs-operator.bh-9817-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: hotfix-migrate-needs-operator: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }

OPLIB="$REPO/bin/lib/hotfix-migrate-operator.sh"
KLIB="$REPO/bin/lib/hotfix-migrate-knobs.sh"
SEEDF="$REPO/worker/jobs/schema.d/202611181628-bh-9817-hotfix-migrate-operator-seed.sql"
FRAG="$REPO/bin/merge-conductor.d/bh-9817-held-operator-alert.sh"
for f in "$OPLIB" "$SEEDF" "$FRAG"; do [ -r "$f" ] && ok || bad "missing $f"; done
# A value may be literals joined with || (the refuse list splits DROP so the
# schema tests' no-DROP check passes); the pieces are joined back here.
seedval() { grep -oE "'$1',('[^']*'( *\|\| *'[^']*')*)" "$SEEDF" 2>/dev/null | sed -E "s/^'[^']*',//; s/' *\|\| *'//g; s/^'//; s/'$//"; }

# ---- the scratch harness ----------------------------------------------------
HH="$T/h"
mkdir -p "$HH/logs" "$HH/state" "$HH/locks" "$HH/env" "$HH/builds" "$T/fakebin" "$T/set"
scratch_install_closure bin/hotfix-migrate.sh "$HH" >/dev/null || bad "closure install of hotfix-migrate.sh"
scratch_install_closure bin/check-migration-appliable.sh "$HH" >/dev/null || bad "closure install of check-migration-appliable.sh"
[ -r "$HH/bin/lib/hotfix-migrate-operator.sh" ] && ok || bad "the stage's closure must carry bin/lib/hotfix-migrate-operator.sh"
printf '#!/bin/bash\nexit 0\n' > "$HH/bin/beat.sh"; chmod +x "$HH/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$HH/bin/gh-token.sh"; chmod +x "$HH/bin/gh-token.sh"
: > "$HH/env/global.env"
cat > "$HH/bin/jobs-client.sh" <<EOF
setting_get() { [ -f "$T/set/\$1" ] || return 2; cat "$T/set/\$1"; }
EOF
cat > "$HH/bin/alert-line.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.log"
exit 0
EOF
chmod +x "$HH/bin/alert-line.sh"
row() { printf '%s' "$2" > "$T/set/$1"; }
MKROW='{"before_merge":1,"workflow":"migrate-branch.yml","files_input":"file","max_files":1,"per_file":1,"dispatch_ref":"main","branch_input":"ref","file_form":"basename","glob":"prisma/sql/*.sql","approve_head":1,"needs_quiet":"off","local_gate":"advisory","gate_workflows":"migration-ledger.yml","require_word":1}'
rows_mk() { # the project-6 rows, the operator step and the refuse list from the SEED fragment
  rm -f "$T/set/"*
  row hotfix_migrate.conf.mk-os "${1:-$MKROW}"; row mc.migration_gate_checks.mk-os gate
  row hotfix_migrate.operator_step.mk-os "$(seedval hotfix_migrate.operator_step.project-6-os)"
  row hotfix_migrate.workflow_refuses.mk-os "$(seedval hotfix_migrate.workflow_refuses.project-6-os)"
}

# ---- the fake gh ------------------------------------------------------------
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
FX="${FX:?FX unset}"
printf '%s\n' "$*" >> "$FX/gh.log"
q=""; prev=""
for a in "$@"; do [ "$prev" = "-q" ] && q="$a"; prev="$a"; done
case "$*" in
  "auth "*) exit 0 ;;
  "api -X POST repos/"*"/pulls/"*"/reviews"*) printf '%s\n' "$*" >> "$FX/approve.log"; echo '{}'; exit 0 ;;
  "api --paginate repos/"*"/reviews"*) echo ''; exit 0 ;;
  "api repos/"*"/issues/"*"/comments"*)
    n=$(( $(cat "$FX/comment.seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/comment.seq"
    for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$FX/comment.md" ;; esac; done
    echo $((5240 + n)); exit 0 ;;
  "api repos/"*"/actions/variables/"*)
    printf '%s\n' "$*" >> "$FX/variables.log"
    echo '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  "api repos/"*"/pulls/"[0-9]*) jq -n --arg h "$(cat "$FX/head.sha")" '{head:{sha:$h}, user:{login:"cromford-builders[bot]"}}' | jq -r "${q:-.}"; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
  "pr checks"*) printf 'build\tpass\t1s\n'; exit 0 ;;
  "workflow run"*) printf '%s\n' "$*" >> "$FX/dispatch.log"
    tok=""; for a in "$@"; do case "$a" in file=*) tok="${a#file=}" ;; esac; done
    n=$(( $(cat "$FX/run.seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/run.seq"; id=$((700 + n))
    printf '%s' "$tok" > "$FX/run-$id.tok"
    printf '{"databaseId":%s,"createdAt":"2099-01-01T00:00:%02dZ","status":"queued","event":"workflow_dispatch"}\n' "$id" "$n" >> "$FX/runs.jsonl"
    exit 0 ;;
  "run list"*) if [ -s "$FX/runs.jsonl" ]; then jq -s . "$FX/runs.jsonl"; else echo '[]'; fi; exit 0 ;;
  "run watch "*) exit 0 ;;
  "run view "*"--log"*) tok=$(cat "$FX/run-$3.tok" 2>/dev/null); printf 'applied: %s (1 statement)\n' "$tok"; exit 0 ;;
  "run view "*) [ -n "$q" ] || q=.; echo '{"status":"completed","conclusion":"success"}' | jq -r "$q"; exit 0 ;;
esac
printf '%s\n' "$*" >> "$FX/unknown.log"
exit 99
EOF
chmod +x "$T/fakebin/gh"

# ---- worktrees --------------------------------------------------------------
mkwt() { # mkwt <dir> <path>=<sql>...
  local d="$1" kv; shift
  git init -q -b main "$d" 2>/dev/null
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo readme > "$d/README.md"; git -C "$d" add -A >/dev/null; git -C "$d" commit -qm init
  git -C "$d" remote add origin https://github.com/o/p.git
  git -C "$d" checkout -q -b ticket/x
  for kv in "$@"; do mkdir -p "$d/$(dirname "${kv%%=*}")"; printf '%s\n' "${kv#*=}" > "$d/${kv%%=*}"; done
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm sql
}
GF=prisma/sql/20261118000001_grant.sql
WTG="$T/wtg"; mkwt "$WTG" "$GF=GRANT SELECT ON t TO r;"
HEAD1=$(printf 'a%.0s' $(seq 40))

CN=0
newcase() {
  CN=$((CN+1)); PRN=$((400 + CN))
  FX="$T/fx$CN"; BD="$HH/builds/mk-os-BH-$PRN-202611180000"
  mkdir -p "$FX" "$BD"; printf '%s\n' "$HEAD1" > "$FX/head.sha"; : > "$FX/gh.log"
}
run_hm() { # run_hm <worktree> [VAR=VAL...] -> prints rc
  local w="$1"; shift
  ( cd "$T" && PATH="$T/fakebin:$PATH" env FX="$FX" HARNESS="$HH" WT="$w" BASE=main SLUG=o/p \
      BRANCH=ticket/x PR_URL="https://github.com/o/p/pull/$PRN" HOTFIX_CI_WAIT=2 \
      HOTFIX_RUN_WAIT=5 HOTFIX_RUN_LOCATE_WAIT=0 HM_BEFORE_MERGE=1 HM_VERDICT=APPROVE \
      HM_REVIEWED_SHA="$HEAD1" HM_TODAY=2026-11-18 \
      "$@" bash "$HH/bin/hotfix-migrate.sh" mk-os "$BD" > "$FX/hm.out" 2> "$FX/hm.err" )
  echo $?
}
cnt() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }
marker() { head -n1 "$FX/comment.md" 2>/dev/null; }

# ============================================================================
# N1. a GRANT file, project-6 (advisory): needs-operator, nothing dispatched
# ============================================================================
rows_mk; newcase
RC=$(run_hm "$WTG"); N1FX="$FX"; N1BD="$BD"
[ "$RC" = 3 ] && ok || bad "N1 rc 3 (got $RC: $(tail -2 "$FX/hm.err"))"
marker | grep -qE '^<!-- hotfix-migrate-proof fp=[0-9a-f]{64} decision=needs-operator -->$' && ok || bad "N1 marker decision=needs-operator (got $(marker))"
[ "$(jq -r '.decision + " " + (.cause // "")' "$BD/hotfix-migrate.json" 2>/dev/null)" = "needs-operator outside-allowlist" ] && ok \
  || bad "N1 the ledger: needs-operator, cause outside-allowlist (got $(jq -c . "$BD/hotfix-migrate.json" 2>/dev/null))"
[ "$(cnt "$FX/approve.log")" = 0 ] && [ "$(cnt "$FX/dispatch.log")" = 0 ] && ok \
  || bad "N1 0 approval POST, 0 dispatch (posts $(cnt "$FX/approve.log"), dispatches $(cnt "$FX/dispatch.log"))"
grep -qF "Operator step ($GF): Read $GF and its header. Then, from a checkout of ticket/x, run DATABASE_URL=" "$FX/comment.md" 2>/dev/null && ok \
  || bad "N1 the comment names the seeded operator step with the file and branch filled in (got: $(grep 'Operator step' "$FX/comment.md" 2>/dev/null))"
grep -q 'npm run db:apply' "$FX/comment.md" 2>/dev/null && ok || bad "N1 the step names project-6's apply command"
grep -q 'FLAGGED.*GRANT SELECT ON t TO r' "$FX/comment.md" 2>/dev/null && ok || bad "N1 the comment shows the refused statement"
[ "$(grep -c '/migrate' "$FX/comment.md" 2>/dev/null)" = 0 ] && ok || bad "N1 the comment must not hold /migrate"
grep -q "the merge conductor releases the PR on its next tick, once the production migration ledger" "$FX/comment.md" 2>/dev/null \
  && ! grep -q "a re-run of the build" "$FX/comment.md" && ok || bad "N1 the comment names the real release (the production ledger), not a re-run"
[ "$(cnt "$FX/variables.log")" = 0 ] && ok || bad "N1 the stage reads no MIGRATE_COMMENT_ALLOWED variable"
LOCKS=$(find "$HH" -name 'hotfix-dispatch-*.lock' 2>/dev/null)
[ -z "$LOCKS" ] && ok || bad "N1 no dispatch lock is taken (got $LOCKS)"

# ============================================================================
# N3. a second run on the same SQL: no new comment, rc 3
# ============================================================================
RC=$(run_hm "$WTG")
[ "$RC" = 3 ] && [ "$(cat "$FX/comment.seq")" = 1 ] && [ "$(cnt "$FX/dispatch.log")" = 0 ] && ok \
  || bad "N3 a re-run: rc 3, still 1 comment, 0 dispatch (rc $RC, comments $(cat "$FX/comment.seq"))"

# ============================================================================
# N2. the refuse-list table, on reports the real gate wrote
# ============================================================================
GD="$T/gate"; mkdir -p "$GD"
refuses() { # refuses <sql> [row] -> rc of hm_op_refuses on the gate's report for that statement
  printf '%s\n' "$1" > "$GD/f.sql"
  "$REPO/bin/check-migration-appliable.sh" mk-os "$GD" "$GD/f.sql" > "$GD/report.txt" 2>/dev/null
  ( HMK_WORKFLOW_REFUSES="${2-$(seedval hotfix_migrate.workflow_refuses.project-6-os)}"; . "$OPLIB" || exit 9
    hm_op_refuses "$GD/report.txt" > /dev/null )
}
n2() { # n2 <want yes|no> <sql>
  local got=no; refuses "$2" && got=yes
  [ "$got" = "$1" ] && ok || bad "N2 '$2': want match=$1, got $got"
}
n2 yes 'GRANT SELECT ("x") ON runtime_setting TO app_ro;'
n2 yes 'grant usage on schema s to r;'
n2 yes "UPDATE runtime_setting SET value='1' WHERE key='k' AND value IS NULL;"
n2 yes 'DO $$ BEGIN PERFORM 1; END $$;'
n2 yes 'DO;'
n2 yes 'CREATE OR REPLACE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;'
n2 yes 'DELETE FROM t WHERE id = 1;'
n2 yes 'CREATE POLICY p ON t USING (true);'
n2 no  'SELECT pg_advisory_xact_lock(123);'
n2 no  'INSERT INTO t (a) VALUES (1) ON CONFLICT DO NOTHING;'
n2 no  "INSERT INTO t (a) VALUES ('UPDATE');"
n2 no  'CREATE TABLE grant_log (id int);'
n2 no  'UPDATED_AT x;'
n2 no  'DOMAIN x;'
# a report with no FLAGGED line at all
: > "$GD/empty.txt"; ( HMK_WORKFLOW_REFUSES=GRANT; . "$OPLIB"; hm_op_refuses "$GD/empty.txt" >/dev/null ) && bad "N2 an empty report must not match" || ok
# N2c the row: absent or invalid -> the code fallback list; a valid row is used as it is
refuses 'GRANT SELECT ON t TO r;' '' && ok || bad "N2c an empty row: the fallback list matches GRANT"
( . "$KLIB"; _hmk_ok workflow_refuses 'GRANT;DROP' ) && bad "N2c an invalid refuse row must be refused by _hmk_ok" || ok
( . "$KLIB"; _hmk_ok workflow_refuses 'GRANT,CREATE POLICY' ) && ok || bad "N2c a valid refuse row passes _hmk_ok"
refuses 'GRANT SELECT ON t TO r;' 'UPDATE' && bad "N2c a row of UPDATE only must not match a GRANT" || ok
# the row reaches the stage: a refuse list without GRANT lets the GRANT file go on to the dispatch
rows_mk; row hotfix_migrate.workflow_refuses.mk-os 'UPDATE,DELETE'; newcase
RC=$(run_hm "$WTG")
[ "$(cnt "$FX/dispatch.log")" = 1 ] && ! grep -q needs-operator <<<"$(marker)" && ok \
  || bad "N2c a row without GRANT: the stage dispatches (rc $RC, dispatches $(cnt "$FX/dispatch.log"), $(marker))"
# an invalid row on the stage: one stderr line, the fallback list applies
rows_mk; row hotfix_migrate.workflow_refuses.mk-os 'grant;drop table x'; newcase
RC=$(run_hm "$WTG")
[ "$RC" = 3 ] && marker | grep -q 'decision=needs-operator' && grep -q 'workflow_refuses' "$FX/hm.err" && ok \
  || bad "N2c an invalid row: the fallback list, one stderr line (rc $RC, $(marker))"
# an operator_step row with /migrate in it is ignored: the generic step, still no /migrate
rows_mk; row hotfix_migrate.operator_step.mk-os 'Comment /migrate {path} on the PR.'; newcase
RC=$(run_hm "$WTG")
[ "$RC" = 3 ] && [ "$(grep -c '/migrate' "$FX/comment.md")" = 0 ] && grep -q "Operator step ($GF): Apply $GF by hand" "$FX/comment.md" && ok \
  || bad "N2c an operator_step row with /migrate: the fallback step (got $(grep 'Operator step' "$FX/comment.md"))"
# N2b strict (no local_gate): the GRANT is `flagged`, rc 2, as before
rows_mk "$(jq -c 'del(.local_gate)' <<<"$MKROW")"; newcase
RC=$(run_hm "$WTG")
[ "$RC" = 2 ] && marker | grep -q 'decision=flagged' && [ "$(cnt "$FX/dispatch.log")" = 0 ] && ok \
  || bad "N2b strict + GRANT: flagged, rc 2 (rc $RC, $(marker))"

# ============================================================================
# M + H. the conductor: real mc_mig_hold -> mc_bm_proof -> mc_bm_held_alert
# ============================================================================
CLASSIFY="$REPO/bin/lib/mc/classify.sh"
printf '[{"filename":"%s","status":"added","sha":"%s"}]' "$GF" "$(git -C "$WTG" rev-parse "HEAD:$GF")" > "$T/pr-files.json"
NOW=$(date -u -d '2026-11-19T12:00:00Z' +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
mcomments() { # mcomments <hours-ago> [<body-file>] -> the PR's comments: one unrelated, then the stage's proof
  jq -n --rawfile b "${2:-$N1FX/comment.md}" --arg at "$(iso $(( NOW - $1 * 3600 )))" \
    '[{body:"unrelated", created_at:"2026-11-01T00:00:00Z"},{body:$b, created_at:$at}]' > "$T/pr-comments.json"
}
mrun() { # mrun [VAR=VAL...] -> "STATE|WHY|mmh-called"; alerts land in $T/mcalerts, attempts in $T/attempts
  ( export HARNESS="$REPO"; H="$REPO"; [ $# -gt 0 ] && export "$@"
    setting_get() { [ -f "$T/set/$1" ] || return 2; cat "$T/set/$1"; }
    . "$CLASSIFY" || exit 9
    mc_rest_var() { local -n _v="$1"; case "$4" in pulls/*) _v=$(cat "$T/pr-files.json") ;; *) _v=$(cat "$T/pr-comments.json") ;; esac; }
    mc_log() { printf '%s\n' "$*" >> "$T/mclog"; }
    . "$REPO/bin/merge-conductor.d/bh-7785-migration-hold.sh" || exit 8
    . "$REPO/bin/merge-conductor.d/bh-9403-before-merge-proof.sh" || exit 7
    . "$FRAG" || exit 6
    mmh_decide() { echo called >> "$T/mmh.log"; MMH_VERDICT=$(cat "$T/mmh.verdict" 2>/dev/null || echo missing); MMH_NAMES=x; MMH_DETAIL=x; MMH_SRC=t; }
    mc_hold_comment() { :; }
    mc_alert() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T/mcalerts"; }
    mc_attempt_has() { grep -qxF "$1" "$T/attempts" 2>/dev/null; }
    mc_attempt_put() { printf '%s\n' "$1" >> "$T/attempts"; }
    STATE=READY; WHY=ready; P=mk-os; SLUG=o/p; NUM=9; KEY="o/p#9"; HEAD="$HEAD1"; RAWLBL=ai-build; REC=""
    ACTIONS="${ACTIONS:-1}"; KILL="${KILL:-0}"; MC_NOW_EPOCH="${MC_NOW_EPOCH:-$NOW}"
    mc_mig_hold
    printf '%s|%s|%s\n' "$STATE" "$WHY" "$(cnt "$T/mmh.log")" )
}
mreset() { rm -f "$T/mmh.log" "$T/mclog" "$T/mcalerts" "$T/attempts" "$T/mmh.verdict"; }
rows_mk; row migrations_glob.mk-os 'prisma/sql/*.sql'; row hotfix_migrate.held_alert_hours "$(seedval hotfix_migrate.held_alert_hours)"

# M1 a needs-operator proof for exactly this SQL, production does not hold it: hold, parked BLOCKED_HUMAN
mreset; mcomments 1
( export HARNESS="$REPO"; H="$REPO"; setting_get() { [ -f "$T/set/$1" ] || return 2; cat "$T/set/$1"; }; . "$CLASSIFY"
  mc_rest_var() { local -n _v="$1"; case "$4" in pulls/*) _v=$(cat "$T/pr-files.json") ;; *) _v=$(cat "$T/pr-comments.json") ;; esac; }
  [ "$(MC_HFP_ANY_LABEL=1 mc_hotfix_proof o/p 9 ai-build "" mk-os)" = hold ] ) && ok || bad "M1 mc_hotfix_proof reads needs-operator as hold"
R=$(mrun)
[ "${R%%|*}" = BLOCKED_HUMAN ] && [ "$(cut -d'|' -f3 <<<"$R")" = 1 ] && ok || bad "M1 a needs-operator proof parks BLOCKED_HUMAN after one production ask that says missing (got $R)"
[ ! -s "$T/mcalerts" ] && ok || bad "M1 held 1 h: no alert yet"
# M2 the operator did the step: production answers applied -> released, not parked, no held alert (refute review)
mreset; echo applied > "$T/mmh.verdict"; mcomments 30; R=$(mrun)
[ "${R%%|*}" = READY ] && ! grep -q HELD_NEEDS_OPERATOR "$T/mcalerts" 2>/dev/null && grep -q 'needs-operator, but production holds' "$T/mclog" && ok \
  || bad "M2 needs-operator + production applied: READY, no alert (got $R; $(cat "$T/mcalerts" 2>/dev/null))"
# M2b every other production answer keeps the park and the alert
for v in unreadable none off lane; do
  mreset; echo "$v" > "$T/mmh.verdict"; mcomments 7; R=$(mrun)
  [ "${R%%|*}" = BLOCKED_HUMAN ] && [ "$(cnt "$T/mcalerts")" = 1 ] && ok || bad "M2b production $v: still parked and alerted (got $R)"
done
# M2c a hold proof that is not needs-operator does not ask production for a release
mreset; echo applied > "$T/mmh.verdict"; sed '1s/decision=needs-operator/decision=hold/' "$N1FX/comment.md" > "$T/hold.md"; mcomments 1 "$T/hold.md"; R=$(mrun)
[ "${R%%|*}" = BLOCKED_HUMAN ] && [ "$(cut -d'|' -f3 <<<"$R")" = 0 ] && ok || bad "M2c a plain hold proof: parked, production not asked (got $R)"
# a retry proof still is not parked
mreset; sed '1s/decision=needs-operator/decision=retry/' "$N1FX/comment.md" > "$T/retry.md"; mcomments 30 "$T/retry.md"; R=$(mrun)
[ "${R%%|*}" != BLOCKED_HUMAN ] && ! grep -q HELD_NEEDS_OPERATOR "$T/mcalerts" 2>/dev/null && ok || bad "M1 a retry proof: not parked, no held alert (got $R)"

# H1 held 7 h, the row says 6: two ticks -> exactly 1 alert with the PR, the file and the step
mreset; mcomments 7; mrun >/dev/null; mrun >/dev/null
[ "$(cnt "$T/mcalerts")" = 1 ] && ok || bad "H1 held 7 h: 2 ticks -> 1 alert (got $(cnt "$T/mcalerts"))"
A=$(cat "$T/mcalerts" 2>/dev/null)
grep -q 'HELD_NEEDS_OPERATOR' <<<"$A" && grep -qF 'https://github.com/o/p/pull/9' <<<"$A" && grep -qF "$GF" <<<"$A" \
  && grep -q 'npm run db:apply' <<<"$A" && grep -q 'held 7h' <<<"$A" && ok || bad "H1 the alert names the PR, the held hours, the file and the step (got $A)"
[ "$(cut -f3 <<<"$A" | wc -c)" -le 501 ] && ok || bad "H1 the alert text is capped at 500 chars"
# H2 held 5 h: 0 alerts in 2 ticks
mreset; mcomments 5; mrun >/dev/null; mrun >/dev/null
[ "$(cnt "$T/mcalerts")" = 0 ] && ok || bad "H2 held 5 h: 0 alerts (got $(cnt "$T/mcalerts"))"
# H2b the row is read: 10 h -> 7 h held raises nothing
mreset; row hotfix_migrate.held_alert_hours 10; mcomments 7; mrun >/dev/null
[ "$(cnt "$T/mcalerts")" = 0 ] && ok || bad "H2b a 10 h row: 7 h held raises nothing"
# an invalid row: the code fallback (6 h)
mreset; row hotfix_migrate.held_alert_hours 'six'; mcomments 7; mrun >/dev/null
[ "$(cnt "$T/mcalerts")" = 1 ] && ok || bad "H2b an invalid row: the 6 h fallback alerts at 7 h"
row hotfix_migrate.held_alert_hours "$(seedval hotfix_migrate.held_alert_hours)"
# H3 at most once in 24 h: 7 h -> 1, 29 h -> still 1, 31 h -> 2
mreset; mcomments 7; mrun >/dev/null; mcomments 29; mrun >/dev/null
[ "$(cnt "$T/mcalerts")" = 1 ] && ok || bad "H3 7 h then 29 h: 1 alert (got $(cnt "$T/mcalerts"))"
mcomments 31; mrun >/dev/null
[ "$(cnt "$T/mcalerts")" = 2 ] && ok || bad "H3 then 31 h: a 2nd alert (got $(cnt "$T/mcalerts"))"
# H3b the repeat window is the row hotfix_migrate.held_alert_repeat_hours (lead BLOCK): 12 h -> 7 h then 20 h = 2 alerts
mreset; row hotfix_migrate.held_alert_repeat_hours 12; mcomments 7; mrun >/dev/null; mcomments 20; mrun >/dev/null
[ "$(cnt "$T/mcalerts")" = 2 ] && ok || bad "H3b a 12 h repeat row: 7 h then 20 h -> 2 alerts (got $(cnt "$T/mcalerts"))"
# an invalid repeat row: the 24 h fallback, 7 h then 20 h = 1 alert
mreset; row hotfix_migrate.held_alert_repeat_hours 'daily'; mcomments 7; mrun >/dev/null; mcomments 20; mrun >/dev/null
[ "$(cnt "$T/mcalerts")" = 1 ] && ok || bad "H3b an invalid repeat row: the 24 h fallback, 1 alert (got $(cnt "$T/mcalerts"))"
row hotfix_migrate.held_alert_repeat_hours "$(seedval hotfix_migrate.held_alert_repeat_hours)"
# H4 observe mode: 0 alerts, 1 WOULD alert log line
mreset; mcomments 7; mrun ACTIONS=0 >/dev/null
[ "$(cnt "$T/mcalerts")" = 0 ] && [ "$(grep -c 'WOULD alert HELD_NEEDS_OPERATOR' "$T/mclog")" = 1 ] && ok \
  || bad "H4 observe mode: 0 alerts, 1 WOULD line (alerts $(cnt "$T/mcalerts"), log $(grep -c WOULD "$T/mclog"))"
# H5 held since the OLDEST needs-operator marker of this fp: an older one 8 h ago, the newest 1 h ago
mreset
jq -n --rawfile b "$N1FX/comment.md" --arg a1 "$(iso $(( NOW - 8 * 3600 )))" --arg a2 "$(iso $(( NOW - 3600 )))" \
  '[{body:$b, created_at:$a1},{body:$b, created_at:$a2}]' > "$T/pr-comments.json"
mrun >/dev/null
[ "$(cnt "$T/mcalerts")" = 1 ] && grep -q 'held 8h' "$T/mcalerts" && ok || bad "H5 the held time runs from the oldest needs-operator marker (got $(cat "$T/mcalerts" 2>/dev/null))"
# a comments read that fails: no alert, no crash
mreset; mcomments 7
R=$( export HARNESS="$REPO"; H="$REPO"; . "$FRAG"; mc_rest_var() { return 1; }
     mc_alert() { echo alert >> "$T/mcalerts"; }; mc_attempt_has() { return 1; }; mc_attempt_put() { :; }; mc_log() { :; }
     SLUG=o/p; NUM=9; KEY="o/p#9"; P=mk-os; ACTIONS=1; KILL=0; MC_NOW_EPOCH=$NOW; mc_bm_held_alert; echo "rc=$?" )
[ "$R" = rc=0 ] && [ "$(cnt "$T/mcalerts")" = 0 ] && ok || bad "H a failed comments read: rc 0, no alert (got $R)"

# ============================================================================
# S1. the seed rows
# ============================================================================
[ "$(seedval hotfix_migrate.held_alert_hours)" = 6 ] && ok || bad "S1 held_alert_hours seeds 6"
[ "$(seedval hotfix_migrate.held_alert_repeat_hours)" = 24 ] && ok || bad "S1 held_alert_repeat_hours seeds 24"
SV=$(python3 -I - "$SEEDF" <<'PY'
import sqlite3, sys
db = sqlite3.connect(":memory:")
db.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT, actor TEXT, updated_at TEXT NOT NULL)")
db.executescript(open(sys.argv[1]).read())
db.executescript(open(sys.argv[1]).read())   # INSERT OR IGNORE: a re-apply is a no-op
for k, v in db.execute("SELECT key, value FROM settings ORDER BY key"):
    print(k + "\t" + v)
PY
)
[ "$(cut -f1 <<<"$SV" | tr '\n' ' ')" = "hotfix_migrate.held_alert_hours hotfix_migrate.held_alert_repeat_hours hotfix_migrate.operator_step.project-6-os hotfix_migrate.workflow_refuses.project-6-os " ] && ok \
  || bad "S1 the fragment loads the 4 rows (got $(cut -f1 <<<"$SV" | tr '\n' ' '))"
while IFS=$'\t' read -r k v; do
  grep -qxE '[a-z0-9_.-]{1,64}' <<<"$k" && ok || bad "S1 key $k fits the settings key rule"
done <<<"$SV"
( . "$KLIB"; _hmk_ok operator_step "$(seedval hotfix_migrate.operator_step.project-6-os)" ) && ok || bad "S1 the seeded project-6 step passes _hmk_ok"
( . "$KLIB"; _hmk_ok workflow_refuses "$(seedval hotfix_migrate.workflow_refuses.project-6-os)" ) && ok || bad "S1 the seeded refuse list passes _hmk_ok"
( . "$KLIB"; _hmk_ok operator_step '/migrate x' ) && bad "S1 an operator_step with /migrate must be refused" || ok
( . "$KLIB"; _hmk_ok operator_step "$(printf 'two\nlines')" ) && bad "S1 an operator_step with a newline must be refused" || ok

for f in "$T"/fx*/unknown.log; do [ -s "$f" ] && bad "the fake gh saw a verb it does not know: $(head -1 "$f")"; done

echo "hotfix-migrate-needs-operator: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
