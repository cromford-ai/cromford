#!/bin/bash
# tests/hotfix-migrate-before-merge.bh-9403-test.sh — BH-9403: add-only
# migration files apply before the merge, for NORMAL PRs of the projects whose
# settings row hotfix_migrate.conf.<project> has "before_merge":1.
#
# Code under test: bin/lib/hotfix-migrate-knobs.sh (the row), bin/hotfix-migrate.sh
# and bin/lib/hotfix-migrate-workflow.sh (dispatch shape, approval, per-file loop,
# outcome words, the checks wait that ignores the migration gate), the
# `# >>> hotfix migrate stage` block of bin/lib/rb/result.sh (the trigger), and
# the conductor side: mc_hotfix_proof's MC_HFP_ANY_LABEL, the fragment
# bin/merge-conductor.d/bh-9403-before-merge-proof.sh and its call in mc_mig_hold.
#
# The real bin/hotfix-migrate.sh runs end to end against a scratch $HARNESS. A
# fake `gh` on PATH logs every argv line and answers from per-case fixture dirs
# ($FX); a verb it does not know is logged to unknown.log and exits 99. A fake
# bin/jobs-client.sh serves settings rows from files, and a fake
# bin/alert-line.sh counts alerts. 0 network calls. Each case has its own build
# dir, fixture dir and PR number, so no case depends on another's state.
#
# Cases: K1-K4 the row; D1 the dispatch argv; A1-A5 the approval; L1-L4 the
# per-file loop; B1-B5 binding the run to our dispatch; O1 the outcome table; R1 a refusal; I1 inert; C1-C4 the checks
# wait; G1-G2 the local gate; X1 no workflow; E1 project-6 end to end; T1 the
# run-build trigger (project-5); M1-M5 the conductor; S1 the seed rows.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hotfix-migrate-before-merge.bh-9403-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: hotfix-migrate-before-merge: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }

KLIB="$REPO/bin/lib/hotfix-migrate-knobs.sh"
WLIB="$REPO/bin/lib/hotfix-migrate-workflow.sh"
for f in "$KLIB" "$REPO/bin/merge-conductor.d/bh-9403-before-merge-proof.sh"; do
  [ -r "$f" ] && ok || bad "missing $f"
done

# ---- the scratch harness ----------------------------------------------------
HH="$T/h"
mkdir -p "$HH/logs" "$HH/state" "$HH/locks" "$HH/env" "$HH/builds" "$T/fakebin" "$T/set"
scratch_install_closure bin/hotfix-migrate.sh "$HH" >/dev/null || { bad "closure install of hotfix-migrate.sh"; }
scratch_install_closure bin/check-migration-appliable.sh "$HH" >/dev/null || { bad "closure install of check-migration-appliable.sh"; }
printf '#!/bin/bash\nexit 0\n' > "$HH/bin/beat.sh"; chmod +x "$HH/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$HH/bin/gh-token.sh"; chmod +x "$HH/bin/gh-token.sh"
: > "$HH/env/global.env"
# settings rows: one file per key under $T/set; $T/set/.down = the worker is down
cat > "$HH/bin/jobs-client.sh" <<EOF
setting_get() { [ -e "$T/set/.down" ] && return 1; [ -f "$T/set/\$1" ] || return 2; cat "$T/set/\$1"; }
EOF
# alerts: one line per --id, as the real alert-line.sh keeps one alert row per
# akey alert:<id>; every call also lands in alerts.calls
cat > "$HH/bin/alert-line.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.calls"
id=""; [ "\$1" = --id ] && id="\$2"
[ -n "\$id" ] && grep -qF -- "--id \$id " "$T/alerts.log" 2>/dev/null && exit 0
printf '%s\n' "\$*" >> "$T/alerts.log"
exit 0
EOF
chmod +x "$HH/bin/alert-line.sh"
row() { printf '%s' "$2" > "$T/set/$1"; }
rows_reset() { rm -f "$T/set/"* "$T/set/.down"; }
MKROW='{"before_merge":1,"workflow":"migrate-branch.yml","files_input":"file","max_files":1,"per_file":1,"dispatch_ref":"main","branch_input":"ref","file_form":"basename","glob":"prisma/sql/*.sql","approve_head":1,"needs_quiet":"off","local_gate":"advisory","gate_workflows":"migration-ledger.yml","require_word":1}'

# ---- the fake gh ------------------------------------------------------------
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
FX="${FX:?FX unset}"
printf '%s\n' "$*" >> "$FX/gh.log"
q=""; prev=""
for a in "$@"; do [ "$prev" = "-q" ] && q="$a"; prev="$a"; done
key() { printf '%s' "$1" | tr '/' '_'; }
case "$*" in
  "auth "*) exit 0 ;;
  "api -X POST repos/"*"/pulls/"*"/reviews"*)
    printf '%s\n' "$*" >> "$FX/approve.log"
    n=$(grep -c . "$FX/approve.log")
    if [ -f "$FX/approve.own" ] && [ "$n" = 1 ]; then
      echo 'gh: Unprocessable Entity (HTTP 422): Can not approve your own pull request' >&2; exit 1; fi
    [ -f "$FX/approve.fail" ] && { echo 'gh: HTTP 500' >&2; exit 1; }
    echo '{}'; exit 0 ;;
  "api --paginate repos/"*"/reviews"*)
    jq -r "$q" "$FX/reviews.json" 2>/dev/null; exit 0 ;;
  "api repos/"*"/issues/"*"/comments"*)
    for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$FX/comment.md"; cat "${a#body=@}" >> "$FX/comments.all" ;; esac; done
    echo 4242; exit 0 ;;
  "api repos/"*"/actions/runs"*) echo '{"workflow_runs":[]}'; exit 0 ;;
  "api repos/"*"/pulls/"[0-9]*)
    [ -f "$FX/head.fail" ] && exit 1
    hn=$(( $(cat "$FX/head.reads" 2>/dev/null || echo 0) + 1 )); echo "$hn" > "$FX/head.reads"
    if [ -f "$FX/head.moveafter" ] && [ "$hn" -gt "$(cat "$FX/head.moveafter")" ]; then cat "$FX/head.moved"; exit 0; fi
    cat "$FX/head.sha"; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
  "pr checks"*)
    cat "$FX/checks.out" 2>/dev/null
    exit "$(cat "$FX/checks.rc" 2>/dev/null || echo 0)" ;;
  "pr list"*) echo "https://github.com/o/p/pull/1"; exit 0 ;;
  "workflow run"*)
    printf '%s\n' "$*" >> "$FX/dispatch.log"
    tok=""; for a in "$@"; do case "$a" in file=*) tok="${a#file=}" ;; esac; done
    [ -f "$FX/dispatch-fail-$(key "$tok")" ] && { echo "gh: HTTP 422" >&2; exit 1; }
    # run ids are unique per fixture dir, as on GitHub: a counter the case never truncates
    n=$(( $(cat "$FX/run.seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/run.seq"; id=$((700 + n))
    printf '%s' "$tok" > "$FX/run-$id.tok"
    printf '{"databaseId":%s,"createdAt":"2099-01-01T00:00:%02dZ","status":"queued","event":"workflow_dispatch"}\n' "$id" "$n" >> "$FX/runs.jsonl"
    # $FX/foreign: another PR's dispatch on the same ref lands right after ours (newer)
    if [ -f "$FX/foreign" ]; then
      printf 'other_pr.sql' > "$FX/run-999.tok"
      printf '{"databaseId":999,"createdAt":"2099-01-01T00:00:59Z","status":"queued","event":"workflow_dispatch"}\n' >> "$FX/runs.jsonl"
    fi
    exit 0 ;;
  "run list"*) if [ -s "$FX/runs.jsonl" ]; then jq -s . "$FX/runs.jsonl"; else echo '[]'; fi; exit 0 ;;
  "run watch "*)
    tok=$(cat "$FX/run-$3.tok" 2>/dev/null)
    [ -f "$FX/hang-$(key "$tok")" ] && exec sleep 30  # determinism: ok a hung fake run; the stage under test kills it with its own timeout
    exit "$(cat "$FX/wrc-$(key "$tok")" 2>/dev/null || echo 0)" ;;
  "run view "*"--log"*)
    tok=$(cat "$FX/run-$3.tok" 2>/dev/null)
    cat "$FX/log-$(key "$tok")" 2>/dev/null; exit 0 ;;
  "run view "*)
    [ -n "$q" ] || q=.
    echo '{"status":"completed","conclusion":"success"}' | jq -r "$q"; exit 0 ;;
esac
printf '%s\n' "$*" >> "$FX/unknown.log"
exit 99
EOF
chmod +x "$T/fakebin/gh"
# the default needs-quiet command is `node scripts/migration-sql.mjs`: answer no
printf '#!/bin/bash\necho no\n' > "$T/fakebin/node"; chmod +x "$T/fakebin/node"

# ---- worktrees --------------------------------------------------------------
mkwt() { # mkwt <dir> <path>=<sql>...   (branch ticket/x, origin o/p)
  local d="$1" kv; shift
  git init -q -b main "$d" 2>/dev/null
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo readme > "$d/README.md"; git -C "$d" add -A >/dev/null; git -C "$d" commit -qm init
  git -C "$d" remote add origin https://github.com/o/p.git
  git -C "$d" checkout -q -b ticket/x
  for kv in "$@"; do mkdir -p "$d/$(dirname "${kv%%=*}")"; printf '%s\n' "${kv#*=}" > "$d/${kv%%=*}"; done
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm sql
}
ADD='CREATE TABLE "Alpha" ("id" TEXT NOT NULL); ALTER TABLE "Alpha" ENABLE ROW LEVEL SECURITY;'
X1F=prisma/sql/20261110000000_x.sql
WT1="$T/wt1"; mkwt "$WT1" "$X1F=$ADD"
WT2="$T/wt2"; mkwt "$WT2" "prisma/sql/20261110000002_b.sql=$ADD" "prisma/sql/20261110000001_a.sql=$ADD"
# two dirs: a path sort puts manual/..._z first, the file-name sort puts _a first
WTO="$T/wto"; mkwt "$WTO" "prisma/migrations/manual/20261110000009_z.sql=$ADD" "prisma/sql/20261110000001_a.sql=$ADD"
WTU="$T/wtu"; mkwt "$WTU" "prisma/sql/20261110000003_u.sql=UPDATE t SET x=2 WHERE id=7;"
TSF=prisma/migrations/manual/2026-11-10-t.sql
WTT="$T/wtt"; mkwt "$WTT" "$TSF=$ADD"
HEAD1=$(git -C "$WT1" rev-parse HEAD)
OTHER=$(printf 'e%.0s' $(seq 40))

# ---- one case = one fixture dir, one build dir, one PR number ---------------
CN=0
newcase() { # newcase -> sets FX, BD, PRN; default fixtures: green checks, head = HEAD1
  CN=$((CN+1)); PRN=$((100 + CN))
  FX="$T/fx$CN"; BD="$HH/builds/mk-os-BH-$PRN-202611130000"
  mkdir -p "$FX" "$BD"
  printf 'build\tpass\t1s\n' > "$FX/checks.out"; echo 0 > "$FX/checks.rc"
  printf '%s\n' "$HEAD1" > "$FX/head.sha"; echo '[]' > "$FX/reviews.json"
  : > "$FX/gh.log"
}
run_hm() { # run_hm <project> <worktree> [VAR=VAL...] -> prints rc
  local p="$1" w="$2"; shift 2
  ( cd "$T" && PATH="$T/fakebin:$PATH" env FX="$FX" HARNESS="$HH" WT="$w" BASE=main SLUG=o/p \
      BRANCH=ticket/x PR_URL="https://github.com/o/p/pull/$PRN" HOTFIX_CI_WAIT=2 \
      HOTFIX_RUN_WAIT=5 HOTFIX_RUN_LOCATE_WAIT=0 HOTFIX_QUIET_POLL=0 HOTFIX_QUIET_MAX_WAIT=0 \
      HM_BEFORE_MERGE=1 HM_VERDICT=APPROVE HM_REVIEWED_SHA="$HEAD1" HM_TODAY=2026-11-13 \
      "$@" bash "$HH/bin/hotfix-migrate.sh" "$p" "$BD" > "$FX/hm.out" 2> "$FX/hm.err" )
  echo $?
}
cnt() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }
nalerts() { cnt "$T/alerts.log"; }
mkrow() { rows_reset; row hotfix_migrate.conf.mk-os "${1:-$MKROW}"; row mc.migration_gate_checks.mk-os gate; }
logok() { printf '2026-11-13T00:00:01.0Z applied: %s (3 statements)\n' "$1"; }

# ============================================================================
# K. the settings row (hmk_conf)
# ============================================================================
kconf() { # kconf <shell snippet run after hmk_conf>
  ( export HARNESS="$HH"; setting_get() { [ -e "$T/set/.down" ] && return 1; [ -f "$T/set/$1" ] || return 2; cat "$T/set/$1"; }
    export HOTFIX_MIGRATE_WORKFLOW=env.yml HOTFIX_WORKFLOW_FILES_INPUT=envin
    . "$KLIB" || exit 9
    hmk_conf mk-os 2>"$T/k.err"; eval "$1" )
}
mkrow
[ "$(kconf 'echo "$HOTFIX_MIGRATE_WORKFLOW $HOTFIX_WORKFLOW_FILES_INPUT $HOTFIX_WORKFLOW_MAX_FILES $HMK_DISPATCH_REF $HMK_BRANCH_INPUT $HMK_FILE_FORM $HMK_GLOB $HMK_PER_FILE $HMK_APPROVE_HEAD $HMK_BEFORE_MERGE $HMK_NEEDS_QUIET $HMK_LOCAL_GATE $HMK_GATE_WORKFLOWS $HMK_GATE_CHECKS"')" \
  = "migrate-branch.yml file 1 main ref basename prisma/sql/*.sql 1 1 1 off advisory migration-ledger.yml gate" ] && ok \
  || bad "K1 the seed row exports every key (got '$(kconf 'echo "$HOTFIX_MIGRATE_WORKFLOW $HMK_DISPATCH_REF $HMK_GLOB $HMK_GATE_CHECKS"')')"
# K1 round trip with the SEED fragment's own JSON
SEEDF="$REPO/worker/jobs/schema.d/202611131603-bh-9403-hotfix-migrate-conf-seed.sql"
SEEDMK=$(grep -o "'hotfix_migrate.conf.project-6-os','[^']*'" "$SEEDF" | sed -E "s/^'[^']*','//; s/'$//")
rows_reset; row hotfix_migrate.conf.mk-os "$SEEDMK"
[ "$(kconf 'echo "$HOTFIX_MIGRATE_WORKFLOW $HMK_DISPATCH_REF $HMK_BRANCH_INPUT $HMK_FILE_FORM $HMK_APPROVE_HEAD $HMK_PER_FILE $HMK_LOG_CAP_KB"')" \
  = "migrate-branch.yml main ref basename 1 1 2048" ] && ok || bad "K1 the seed fragment's JSON round-trips through hmk_conf"
[ "$(kconf 'echo "$HMK_REQUIRE_WORD"')" = 1 ] && ok || bad "K1 the project-6 seed row sets require_word 1"
SEEDTS=$(grep -o "'hotfix_migrate.conf.project-5','[^']*'" "$SEEDF" | sed -E "s/^'[^']*','//; s/'$//")
rows_reset; row hotfix_migrate.conf.mk-os "$SEEDTS"
[ "$(kconf 'echo "${HMK_REQUIRE_WORD:-0}"')" = 0 ] && ok || bad "K1 the project-5 seed row keeps require_word off (today's meaning)"
# K1b dispatch_lock_s and require_word: valid values export, invalid ones are ignored
rows_reset; row hotfix_migrate.conf.mk-os '{"dispatch_lock_s":30,"require_word":1}'
[ "$(kconf 'echo "$HOTFIX_DISPATCH_LOCK_WAIT $HMK_REQUIRE_WORD"')" = "30 1" ] && ok || bad "K1b dispatch_lock_s 30, require_word 1 (got '$(kconf 'echo "$HOTFIX_DISPATCH_LOCK_WAIT $HMK_REQUIRE_WORD"')')"
rows_reset; row hotfix_migrate.conf.mk-os '{"dispatch_lock_s":0,"require_word":2}'
[ "$(kconf 'echo "${HOTFIX_DISPATCH_LOCK_WAIT:-unset}|$HMK_REQUIRE_WORD"')" = "unset|" ] && ok || bad "K1b dispatch_lock_s 0 and require_word 2 are ignored"
# K2 an invalid workflow is ignored (env value stays), with one stderr line
rows_reset; row hotfix_migrate.conf.mk-os '{"workflow":"x.yml; rm -rf /","dispatch_ref":"../x","max_files":99,"file_form":"evil","before_merge":1}'
[ "$(kconf 'echo "$HOTFIX_MIGRATE_WORKFLOW|$HMK_DISPATCH_REF|${HOTFIX_WORKFLOW_MAX_FILES:-}|$HMK_FILE_FORM|$HMK_BEFORE_MERGE"')" = "env.yml||||1" ] && ok \
  || bad "K2 invalid keys must be ignored (got '$(kconf 'echo "$HOTFIX_MIGRATE_WORKFLOW|$HMK_DISPATCH_REF|${HOTFIX_WORKFLOW_MAX_FILES:-}|$HMK_FILE_FORM"')')"
kconf : ; [ "$(grep -c 'not valid; ignored' "$T/k.err")" = 4 ] && ok || bad "K2 one stderr line per invalid key ($(cat "$T/k.err"))"
# K3 an unreadable row: env values and defaults, HMK_SRC=unreadable
mkrow; : > "$T/set/.down"
[ "$(kconf 'echo "$HOTFIX_MIGRATE_WORKFLOW $HMK_SRC ${HMK_PER_FILE:-0} ${HMK_BEFORE_MERGE:-0}"')" = "env.yml unreadable 0 0" ] && ok \
  || bad "K3 unreadable row must keep the env values (got '$(kconf 'echo "$HOTFIX_MIGRATE_WORKFLOW $HMK_SRC"')')"
rows_reset
[ "$(kconf 'echo "$HOTFIX_MIGRATE_WORKFLOW $HMK_SRC"')" = "env.yml none" ] && ok || bad "K3 no row: env values, HMK_SRC=none"
# K4 the row beats the env file
mkrow
[ "$(kconf 'echo "$HOTFIX_MIGRATE_WORKFLOW $HOTFIX_WORKFLOW_FILES_INPUT"')" = "migrate-branch.yml file" ] && ok || bad "K4 the row must beat the env knobs"
( export HARNESS="$HH"; setting_get() { [ -f "$T/set/$1" ] || return 2; cat "$T/set/$1"; }; . "$KLIB"; hmk_before_merge mk-os ) && ok || bad "K4 hmk_before_merge must be rc 0 for before_merge 1"
( export HARNESS="$HH"; setting_get() { [ -f "$T/set/$1" ] || return 2; cat "$T/set/$1"; }; . "$KLIB"; hmk_before_merge other-os ) && bad "K4 no row must not be before-merge" || ok

# ============================================================================
# E1 + D1. project-6 end to end: approval, dispatch from main, applied, proof
# ============================================================================
mkrow; newcase; logok 20261110000000_x.sql > "$FX/log-20261110000000_x.sql"
RC=$(run_hm mk-os "$WT1"); E1FX="$FX"; E1BD="$BD"
[ "$RC" = 0 ] && ok || bad "E1 rc must be 0 (got $RC: $(tail -3 "$FX/hm.err"))"
[ "$(cnt "$FX/approve.log")" = 1 ] && grep -q "commit_id=$HEAD1" "$FX/approve.log" && grep -q 'event=APPROVE' "$FX/approve.log" && ok \
  || bad "E1 one APPROVED review pinned to the sha (got: $(cat "$FX/approve.log" 2>/dev/null))"
[ "$(cat "$FX/dispatch.log" 2>/dev/null)" = "workflow run migrate-branch.yml -R o/p --ref main -f file=20261110000000_x.sql -f ref=ticket/x" ] && ok \
  || bad "D1 the dispatch argv (got: $(cat "$FX/dispatch.log" 2>/dev/null))"
AL=$(grep -n 'reviews' "$FX/gh.log" | grep -- '-X POST' | head -1 | cut -d: -f1); DL=$(grep -n '^workflow run' "$FX/gh.log" | head -1 | cut -d: -f1)
[ -n "$AL" ] && [ -n "$DL" ] && [ "$AL" -lt "$DL" ] && ok || bad "E1 the approval must come before the dispatch (approve line $AL, dispatch line $DL)"
grep -q '^run list .*--branch main' "$FX/gh.log" && ok || bad "E1 the run lookup must list under the dispatch ref main"
head -n1 "$FX/comment.md" | grep -qE '^<!-- hotfix-migrate-proof fp=[0-9a-f]{64} decision=applied -->$' && ok \
  || bad "E1 the proof marker must say applied (got: $(head -n1 "$FX/comment.md" 2>/dev/null))"
[ "$(jq -r '.decision + " " + (.files[0].status) + " " + (.files[0].run_id|tostring)' "$BD/hotfix-migrate.json")" = "applied applied 701" ] && ok \
  || bad "E1 ledger: applied, file applied, run 701 (got $(cat "$BD/hotfix-migrate.json"))"
[ ! -s "$FX/unknown.log" ] && ok || bad "E1 the fake gh saw a verb it does not know: $(cat "$FX/unknown.log")"
# a re-run of the stage is idempotent: no second approval, no second dispatch
newcase; FX="$E1FX"; BD="$E1BD"; RC=$(run_hm mk-os "$WT1")
[ "$RC" = 0 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && [ "$(cnt "$FX/approve.log")" = 1 ] && ok \
  || bad "E1 a re-run must dispatch nothing new (rc $RC, dispatches $(cnt "$FX/dispatch.log"))"

# ============================================================================
# A. the approval gate
# ============================================================================
# A2 head moved after the review
mkrow; newcase; echo "$OTHER" > "$FX/head.sha"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 3 ] && [ "$(cnt "$FX/approve.log")" = 0 ] && [ "$(cnt "$FX/dispatch.log")" = 0 ] && ok \
  || bad "A2 head moved: rc 3, 0 POST, 0 dispatch (rc $RC, posts $(cnt "$FX/approve.log"), dispatches $(cnt "$FX/dispatch.log"))"
grep -q 'head moved after the review' "$FX/comment.md" && ok || bad "A2 the proof must say the head moved"
head -n1 "$FX/comment.md" | grep -q 'decision=retry' && ok || bad "A2 a stop before any dispatch is decision retry, not hold (got $(head -n1 "$FX/comment.md"))"
# A2b the head moves between file 1 and file 2 (per-file): file 2 is not
# dispatched. Reads: 1 approval, 2 file 1's pre-dispatch check, 3 file 2's.
mkrow; newcase; logok 20261110000001_a.sql > "$FX/log-20261110000001_a.sql"; logok 20261110000002_b.sql > "$FX/log-20261110000002_b.sql"
echo 2 > "$FX/head.moveafter"; echo "$OTHER" > "$FX/head.moved"
RC=$(run_hm mk-os "$WT2")
[ "$RC" = 3 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && grep -q 'file=20261110000001_a.sql' "$FX/dispatch.log" && ok \
  || bad "A2b a head that moves after file 1: rc 3, file 2 not dispatched (rc $RC, dispatches $(cnt "$FX/dispatch.log"))"
[ "$(jq -r '[.files[].status] | join(" ")' "$BD/hotfix-migrate.json")" = "applied hold" ] && grep -q 'head moved after the review' "$FX/comment.md" && ok \
  || bad "A2b ledger applied/hold and the proof names the moved head (got $(jq -c '[.files[].status]' "$BD/hotfix-migrate.json"))"
# A3 verdict BLOCK; and an empty reviewed sha; and a head nobody could read
for v in "HM_VERDICT=BLOCK" "HM_REVIEWED_SHA=" "HEADFAIL"; do
  mkrow; newcase
  if [ "$v" = HEADFAIL ]; then : > "$FX/head.fail"; RC=$(run_hm mk-os "$WT1"); else RC=$(run_hm mk-os "$WT1" "$v"); fi
  [ "$RC" = 3 ] && [ "$(cnt "$FX/approve.log")" = 0 ] && [ "$(cnt "$FX/dispatch.log")" = 0 ] && ok \
    || bad "A3 $v: rc 3, 0 POST, 0 dispatch (rc $RC, posts $(cnt "$FX/approve.log"), dispatches $(cnt "$FX/dispatch.log"))"
done
# A4 already approved at the head: no POST, one dispatch
mkrow; newcase; logok 20261110000000_x.sql > "$FX/log-20261110000000_x.sql"
jq -n --arg h "$HEAD1" '[{id:1,state:"APPROVED",commit_id:"0000"},{id:2,state:"APPROVED",commit_id:$h}]' > "$FX/reviews.json"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 0 ] && [ "$(cnt "$FX/approve.log")" = 0 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && ok \
  || bad "A4 already approved: 0 POST, 1 dispatch (rc $RC, posts $(cnt "$FX/approve.log"))"
# an APPROVED review on an OLD commit does not count
mkrow; newcase; logok 20261110000000_x.sql > "$FX/log-20261110000000_x.sql"
jq -n '[{id:1,state:"APPROVED",commit_id:"0000"},{id:2,state:"COMMENTED"}]' > "$FX/reviews.json"
RC=$(run_hm mk-os "$WT1")
[ "$(cnt "$FX/approve.log")" = 1 ] && ok || bad "A4 an approval on another commit must not count"
# A5 422 own pull request: a second POST on the default credential, then dispatch
mkrow; newcase; logok 20261110000000_x.sql > "$FX/log-20261110000000_x.sql"; : > "$FX/approve.own"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 0 ] && [ "$(cnt "$FX/approve.log")" = 2 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && ok \
  || bad "A5 self-approve 422: 2 POSTs then 1 dispatch (rc $RC, posts $(cnt "$FX/approve.log"), dispatches $(cnt "$FX/dispatch.log"))"
# any other POST failure: hold, nothing dispatched
mkrow; newcase; : > "$FX/approve.fail"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 3 ] && [ "$(cnt "$FX/dispatch.log")" = 0 ] && ok || bad "A5 a failed POST must hold with 0 dispatch (rc $RC)"

# ============================================================================
# L. the per-file loop
# ============================================================================
mkrow; newcase
logok 20261110000001_a.sql > "$FX/log-20261110000001_a.sql"; logok 20261110000002_b.sql > "$FX/log-20261110000002_b.sql"
RC=$(run_hm mk-os "$WT2")
[ "$RC" = 0 ] && [ "$(cnt "$FX/dispatch.log")" = 2 ] && ok || bad "L1 two files: two dispatches (rc $RC, $(cnt "$FX/dispatch.log"))"
[ "$(sed -nE 's/.* -f file=([^ ]+) .*/\1/p' "$FX/dispatch.log" | tr '\n' ' ')" = "20261110000001_a.sql 20261110000002_b.sql " ] && ok \
  || bad "L1 the lower name first (got $(sed -nE 's/.* -f file=([^ ]+) .*/\1/p' "$FX/dispatch.log" | tr '\n' ' '))"
[ "$(cnt "$FX/approve.log")" = 1 ] && ok || bad "L1 one approval for the PR, not one per file"
# L1b file-name order across two directories, not path order
mkrow; newcase
logok 20261110000001_a.sql > "$FX/log-20261110000001_a.sql"; logok 20261110000009_z.sql > "$FX/log-20261110000009_z.sql"
RC=$(run_hm mk-os "$WTO")
[ "$RC" = 0 ] && [ "$(sed -nE 's/.* -f file=([^ ]+) .*/\1/p' "$FX/dispatch.log" | tr '\n' ' ')" = "20261110000001_a.sql 20261110000009_z.sql " ] && ok \
  || bad "L1b file-name order across dirs (rc $RC, got $(sed -nE 's/.* -f file=([^ ]+) .*/\1/p' "$FX/dispatch.log" | tr '\n' ' '))"
# L2 the first file refused: one dispatch, rc 3, the second not-dispatched
mkrow; newcase
printf '2026-11-13T00:00:01.0Z refused: 20261110000001_a.sql: 1 statement(s) not on the additive allow-list\n' > "$FX/log-20261110000001_a.sql"
echo 1 > "$FX/wrc-20261110000001_a.sql"
RC=$(run_hm mk-os "$WT2")
[ "$RC" = 3 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && ok || bad "L2 refusal on file 1: rc 3, 1 dispatch (rc $RC, $(cnt "$FX/dispatch.log"))"
[ "$(jq -r '[.files[] | .status] | join(",")' "$BD/hotfix-migrate.json")" = "refused,not-dispatched" ] && ok \
  || bad "L2 statuses refused,not-dispatched (got $(jq -c .files "$BD/hotfix-migrate.json"))"
# L3 file 1 applied, file 2's dispatch failed -> a re-run dispatches file 2 only
mkrow; newcase
logok 20261110000001_a.sql > "$FX/log-20261110000001_a.sql"; logok 20261110000002_b.sql > "$FX/log-20261110000002_b.sql"
: > "$FX/dispatch-fail-20261110000002_b.sql"
RC=$(run_hm mk-os "$WT2")
[ "$RC" = 3 ] && [ "$(jq -r '[.files[] | .status] | join(",")' "$BD/hotfix-migrate.json")" = "applied,dispatch-failed" ] && ok \
  || bad "L3 first run: applied,dispatch-failed (rc $RC, $(jq -c .files "$BD/hotfix-migrate.json"))"
rm -f "$FX/dispatch-fail-20261110000002_b.sql"; : > "$FX/dispatch.log"
RC=$(run_hm mk-os "$WT2")
[ "$RC" = 0 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && grep -q 'file=20261110000002_b.sql' "$FX/dispatch.log" && ok \
  || bad "L3 the re-run dispatches file 2 only (rc $RC, $(cat "$FX/dispatch.log"))"
# L4 a run still going when our watch gave up: the re-run RE-ATTACHES, no dispatch
mkrow; newcase; : > "$FX/hang-20261110000000_x.sql"
RC=$(run_hm mk-os "$WT1" HOTFIX_RUN_WAIT=1)
[ "$RC" = 3 ] && [ "$(jq -r '.files[0].run_id|tostring' "$BD/hotfix-migrate.json")" = 701 ] && ok \
  || bad "L4 a watch timeout keeps the run id (rc $RC, $(jq -c .files "$BD/hotfix-migrate.json"))"
rm -f "$FX/hang-20261110000000_x.sql"; logok 20261110000000_x.sql > "$FX/log-20261110000000_x.sql"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 0 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && ok || bad "L4 the re-run re-attaches (rc $RC, dispatches $(cnt "$FX/dispatch.log"))"

# ============================================================================
# B. binding the run to OUR dispatch (BH-9403 refute review). project-6 lists
# every PR's dispatch under one ref, `main`.
# ============================================================================
# B1 the reviewer's repro: our run 701 REFUSES our file; a foreign run 999 (another
# PR's file, NEWER) lands on main right after our dispatch and applies its file.
mkrow; newcase; : > "$FX/foreign"; A0=$(nalerts)
printf 'refused: 20261110000000_x.sql: 1 statement(s) not on the additive allow-list\n' > "$FX/log-20261110000000_x.sql"
echo 1 > "$FX/wrc-20261110000000_x.sql"; logok other_pr.sql > "$FX/log-other_pr.sql"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 3 ] && ok || bad "B1 two new runs on main: rc 3 (got $RC)"
head -n1 "$FX/comment.md" | grep -q 'decision=hold' && ok || bad "B1 the proof decision must be hold (got $(head -n1 "$FX/comment.md"))"
[ "$(jq -r '.decision' "$BD/hotfix-migrate.json")" = hold ] && ! jq -e '.files[] | select(.status == "applied")' "$BD/hotfix-migrate.json" >/dev/null && ok \
  || bad "B1 the ledger records nothing applied (got $(jq -c '{decision,files}' "$BD/hotfix-migrate.json"))"
! grep -q '^run watch 999' "$FX/gh.log" && ! grep -q '^run watch' "$FX/gh.log" && ok || bad "B1 no run is watched, least of all the foreign 999 ($(grep '^run watch' "$FX/gh.log"))"
[ $(( $(nalerts) - A0 )) = 1 ] && tail -n1 "$T/alerts.log" | grep -q -- '--id hotfix-migrate-unbound-mk-os' && ok \
  || bad "B1 one alert that names the unbound dispatch (got $(( $(nalerts) - A0 )): $(tail -n1 "$T/alerts.log"))"
# B2 a run listed BEFORE our dispatch (998, a newer clock) is never ours: we bind 701
mkrow; newcase; logok 20261110000000_x.sql > "$FX/log-20261110000000_x.sql"
printf 'other_pr.sql' > "$FX/run-998.tok"; logok other_pr.sql > "$FX/log-other_pr.sql"
printf '{"databaseId":998,"createdAt":"2099-01-01T00:00:58Z","status":"in_progress","event":"workflow_dispatch"}\n' > "$FX/runs.jsonl"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 0 ] && grep -q '^run watch 701 ' "$FX/gh.log" && ! grep -q '^run watch 998' "$FX/gh.log" && ok \
  || bad "B2 the pre-dispatch run 998 is excluded, 701 is watched (rc $RC, $(grep '^run watch' "$FX/gh.log"))"
[ "$(jq -r '.files[0].run_id|tostring' "$BD/hotfix-migrate.json")" = 701 ] && ok || bad "B2 the ledger names run 701"
# B3 require_word 1: a green run that names ANOTHER file only is failed, not applied
mkrow; newcase; A0=$(nalerts); logok other_pr.sql > "$FX/log-20261110000000_x.sql"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 3 ] && [ "$(jq -r '.decision + " " + .files[0].status' "$BD/hotfix-migrate.json")" = "hold failed" ] && ok \
  || bad "B3 require_word: unworded green run is hold/failed (rc $RC, $(jq -c '{decision,files}' "$BD/hotfix-migrate.json"))"
[ $(( $(nalerts) - A0 )) = 1 ] && tail -n1 "$T/alerts.log" | grep -q -- '--id hotfix-migrate-unworded-mk-os' && ok \
  || bad "B3 one alert for the unworded run (got $(( $(nalerts) - A0 )))"
grep -q 'did not say it applied' "$FX/comment.md" && ok || bad "B3 the proof says the run did not name the file"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 3 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && [ $(( $(nalerts) - A0 )) = 1 ] && ok \
  || bad "B3 terminal: a re-run dispatches nothing and alerts nothing new (rc $RC)"
# B4 require_word 0 (project-5's meaning): the same run is applied, as before
mkrow "$(jq -c '.require_word = 0' <<<"$MKROW")"; newcase; logok other_pr.sql > "$FX/log-20261110000000_x.sql"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 0 ] && [ "$(jq -r '.files[0].status' "$BD/hotfix-migrate.json")" = applied ] && ok \
  || bad "B4 require_word 0 keeps success-unworded = applied (rc $RC)"
# B5 the dispatch lock is held by another dispatch of the same (repo, workflow, ref):
# after its wait, hold with 0 dispatches; then a free lock dispatches
mkrow; newcase; logok 20261110000000_x.sql > "$FX/log-20261110000000_x.sql"
LK="$HH/locks/hotfix-dispatch-$(printf '%s|%s|%s' o/p migrate-branch.yml main | sha1sum | cut -c1-16).lock"
mkdir -p "$HH/locks"
( flock -x 8; : > "$FX/locked"; while [ ! -e "$FX/release" ]; do sleep 0.1; done ) 8>"$LK" &  # determinism: ok the holder is released by the release file below
LP=$!
for _ in $(seq 50); do [ -e "$FX/locked" ] && break; sleep 0.1; done  # determinism: ok bounded wait for the holder to take the lock
RC=$(run_hm mk-os "$WT1" HOTFIX_DISPATCH_LOCK_WAIT=1)
[ "$RC" = 3 ] && [ "$(cnt "$FX/dispatch.log")" = 0 ] && grep -q 'held the dispatch lock' "$FX/comment.md" && ok \
  || bad "B5 a held lock: rc 3, 0 dispatches (rc $RC, dispatches $(cnt "$FX/dispatch.log"))"
: > "$FX/release"; wait "$LP"
RC=$(run_hm mk-os "$WT1")
[ "$RC" = 0 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && ok || bad "B5 a free lock: the re-run dispatches once (rc $RC)"

# ============================================================================
# O1. the outcome table (hm_wf_outcome)
# ============================================================================
o1() { # o1 <log line> <watch rc> <want>
  printf '%b\n' "$1" > "$T/o1.log"
  local got; got=$( . "$WLIB"; hm_wf_outcome "$T/o1.log" "$2" 2026_x.sql prisma/sql/2026_x.sql )
  [ "$got" = "$3" ] && ok || bad "O1 log '$1' rc $2: want $3, got $got"
}
o1 'job\tstep\t2026-11-13T00:00:01Z applied: 2026_x.sql (3 statements)' 0 applied
o1 '2026-11-13T00:00:01Z already-applied: 2026_x.sql' 0 already-applied
o1 '2026-11-13T00:00:01Z applied: 2026_OTHER.sql' 0 success-unworded
o1 '2026-11-13T00:00:01Z applied: 2026_x.sql.bak' 0 success-unworded
o1 '2026-11-13T00:00:01Z refused: 2026_x.sql: 1 statement(s) not on the additive allow-list' 1 refused
o1 '2026-11-13T00:00:01Z refused: PR #12: no APPROVED review on the head' 1 refused
o1 '2026-11-13T00:00:01Z failed: 2026_x.sql: syntax error' 1 failed
o1 '2026-11-13T00:00:01Z applied: 2026_x.sql\n2026-11-13T00:00:02Z ALERT tenants: tenant-failed t1' 1 failed
o1 '::notice::migrate-branch is inert (no DATABASE_URL_APPLY_PROD)' 0 inert
o1 '# not refused: 2026_x.sql' 0 success-unworded
o1 '' 0 success-unworded
o1 '' 124 in-flight
( . "$WLIB"; printf 'x refused: a.sql: no\n' > "$T/o1.log"; hm_wf_outcome "$T/o1.log" 1 a.sql >/dev/null; [ "$HM_WF_REASON" = "refused: a.sql: no" ] ) 2>/dev/null \
  && ok || bad "O1 the refusal reason is the refused line"

# ============================================================================
# R1. an UPDATE: the workflow refuses, 0 retries, 1 alert, no label
# ============================================================================
mkrow; newcase; : > "$T/alerts.log"
printf '2026-11-13T00:00:01Z refused: 20261110000003_u.sql: 1 statement(s) not on the additive allow-list (UPDATE)\n' > "$FX/log-20261110000003_u.sql"
echo 1 > "$FX/wrc-20261110000003_u.sql"
RC=$(run_hm mk-os "$WTU")
[ "$RC" = 3 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && ok || bad "R1 rc 3 and 1 dispatch (rc $RC, $(cnt "$FX/dispatch.log"))"
[ "$(nalerts)" = 1 ] && grep -q -- "--id hotfix-migrate-refused-mk-os-$PRN-" "$T/alerts.log" && grep -q '20261110000003_u.sql' "$T/alerts.log" \
  && grep -q 'not on the additive allow-list' "$T/alerts.log" && ok || bad "R1 one alert naming the file and the reason (got: $(cat "$T/alerts.log"))"
head -n1 "$FX/comment.md" | grep -q 'decision=hold' && ok || bad "R1 the proof decision must be hold"
RC=$(run_hm mk-os "$WTU")
[ "$RC" = 3 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && [ "$(nalerts)" = 1 ] && ok \
  || bad "R1 a second stage run: no re-dispatch, no new alert (rc $RC, dispatches $(cnt "$FX/dispatch.log"), alerts $(nalerts))"
LBL=$(grep -c -- '--add-label\|labels' "$FX/gh.log"); [ "$LBL" = 0 ] && ok || bad "R1 the stage must add no label"

# ============================================================================
# I1. inert: hold, and one alert per project per UTC day
# ============================================================================
: > "$T/alerts.log"; : > "$T/alerts.calls"
for k in 1 2; do
  mkrow; newcase
  printf '::notice::migrate-branch is inert (no DATABASE_URL_APPLY_PROD)\n' > "$FX/log-20261110000000_x.sql"
  RC=$(run_hm mk-os "$WT1")
  [ "$RC" = 3 ] && [ "$(jq -r '.files[0].status' "$BD/hotfix-migrate.json")" = inert ] && ok || bad "I1 run $k: rc 3, status inert (rc $RC)"
done
[ "$(nalerts)" = 1 ] && grep -q -- '--id hotfix-migrate-inert-mk-os-2026-11-13 ' "$T/alerts.log" && ok || bad "I1 two inert runs on one day: 1 alert (got $(nalerts))"
[ ! -e "$HH/state/hotfix-migrate" ] && ok || bad "I1 the inert throttle writes no state/ file"
mkrow; newcase; printf '::notice::migrate-branch is inert\n' > "$FX/log-20261110000000_x.sql"
RC=$(run_hm mk-os "$WT1" HM_TODAY=2026-11-14)
[ "$(nalerts)" = 2 ] && ok || bad "I1 the next day alerts again (got $(nalerts))"

# ============================================================================
# C. the checks wait ignores the migration gate, by exact name
# ============================================================================
c_case() { # c_case <label> <checks rows> <want dispatches> <want rc>
  mkrow; newcase; logok 20261110000000_x.sql > "$FX/log-20261110000000_x.sql"
  printf '%b' "$2" > "$FX/checks.out"; echo 1 > "$FX/checks.rc"
  RC=$(run_hm mk-os "$WT1")
  [ "$RC" = "$4" ] && [ "$(cnt "$FX/dispatch.log")" = "$3" ] && ok || bad "$1 (rc $RC want $4, dispatches $(cnt "$FX/dispatch.log") want $3)"
}
c_case "C1 gate red, the rest green: dispatch" 'gate\tfail\t1s\nbuild\tpass\t1s\n' 1 0
c_case "C2 build red: hold, 0 dispatch" 'gate\tfail\t1s\nbuild\tfail\t1s\n' 0 3
head -n1 "$FX/comment.md" | grep -q 'decision=retry' && ok || bad "C2 red checks before the dispatch: decision retry (got $(head -n1 "$FX/comment.md"))"
c_case "C3 only gate rows: not green, hold at the deadline" 'gate\tfail\t1s\n' 0 3
c_case "C4 gate-extra red is not the gate" 'gate\tfail\t1s\ngate-extra\tfail\t1s\nbuild\tpass\t1s\n' 0 3
c_case "C4 a pending build check waits, then holds" 'gate\tfail\t1s\nbuild\tpending\t1s\n' 0 3
grep -q -- '--fail-fast' "$FX/gh.log" && bad "C the gate-aware wait must not use --fail-fast" || ok

# ============================================================================
# G. the local gate: advisory dispatches and reports, strict (default) refuses
# ============================================================================
mkrow; newcase; logok 20261110000003_u.sql > "$FX/log-20261110000003_u.sql"
RC=$(run_hm mk-os "$WTU")
[ "$RC" = 0 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && ok || bad "G1 advisory + flagged: 1 dispatch (rc $RC)"
grep -q 'FLAGGED' "$FX/comment.md" && grep -q "the workflow's allow-list decides" "$FX/comment.md" && ok \
  || bad "G1 the proof must carry the flagged lines"
mkrow "$(jq -c 'del(.local_gate)' <<<"$MKROW")"; newcase
RC=$(run_hm mk-os "$WTU")
[ "$RC" = 2 ] && [ "$(cnt "$FX/dispatch.log")" = 0 ] && [ "$(cnt "$FX/approve.log")" = 0 ] && ok \
  || bad "G2 strict (the default): rc 2, 0 dispatch, 0 approval (rc $RC)"

# ============================================================================
# X1. before-merge with no workflow: rc 4, 1 alert, no ledger, no proof
# ============================================================================
rows_reset; row hotfix_migrate.conf.nw-os '{"before_merge":1}'; newcase; : > "$T/alerts.log"
RC=$(run_hm nw-os "$WTT")
[ "$RC" = 4 ] && [ "$(nalerts)" = 1 ] && [ ! -e "$BD/hotfix-migrate.json" ] && [ ! -e "$FX/comment.md" ] && ok \
  || bad "X1 rc 4, 1 alert, no ledger, no proof (rc $RC, alerts $(nalerts))"
# the same project as a HOTFIX (HM_BEFORE_MERGE=0) keeps today's no-path proof
newcase; RC=$(run_hm nw-os "$WTT" HM_BEFORE_MERGE=0)
[ "$RC" = 5 ] && ok || bad "X1 a hotfix with no path keeps rc 5 (got $RC)"

# ============================================================================
# T1. the run-build trigger, extracted by its markers, driving the REAL stage
# ============================================================================
RB="$REPO/bin/lib/rb/result.sh"
awk '/^# >>> hotfix migrate stage/{f=1;next} /^# <<< hotfix migrate stage/{exit} f' "$RB" > "$T/hstage.sh"
[ -s "$T/hstage.sh" ] && ok || bad "T1 could not extract the stage block"
TSROW='{"before_merge":1,"workflow":"migrate-manual.yml","files_input":"file","per_file":1}'
HEADT=$(git -C "$WTT" rev-parse HEAD)
t1() { # t1 <VAR=VAL...> -> TIER/NOTE lines. The PR's live head is the project-5 head unless the case moved it.
  [ "$(cat "$FX/head.sha")" = "$HEAD1" ] && printf '%s\n' "$HEADT" > "$FX/head.sha"
  ( cd "$WTT" && PATH="$T/fakebin:$PATH" env FX="$FX" HARNESS="$HH" BUILD="$BD" PROJECT=project-5 KEY="BH-$PRN" \
      TIER=1 PR_URL="https://github.com/o/p/pull/$PRN" QA_NOTE="" WT="$WTT" BRANCH=ticket/x BASE=main SLUG=o/p \
      HOTFIX= VERDICT_WORD=APPROVE HEADBOUND_SHA="$HEADT" HOTFIX_CI_WAIT=2 HOTFIX_RUN_WAIT=5 HOTFIX_RUN_LOCATE_WAIT=0 "$@" \
      bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"; printf "TIER=%s\nNOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/hstage.sh" 2>/dev/null )
}
rows_reset; row hotfix_migrate.conf.project-5 "$TSROW"; newcase
OUT=$(t1)
[ "$(cat "$FX/dispatch.log" 2>/dev/null)" = "workflow run migrate-manual.yml -R o/p --ref ticket/x -f file=$TSF" ] && ok \
  || bad "T1 a normal project-5 PR runs Migrate Manual SQL (got: $(cat "$FX/dispatch.log" 2>/dev/null); out: $(tr '\n' ' ' <<<"$OUT"))"
grep -q 'HOTFIX-MIGRATE: applied' <<<"$OUT" && grep -q '^TIER=1$' <<<"$OUT" && ok || bad "T1 applied note, tier untouched (got $(tr '\n' ' ' <<<"$OUT"))"
[ "$(cnt "$FX/approve.log")" = 0 ] && ok || bad "T1 project-5 posts no approval"
newcase; OUT=$(t1 VERDICT_WORD=BLOCK)
[ ! -s "$FX/gh.log" ] && ok || bad "T1 verdict BLOCK: the stage must not run (gh: $(head -2 "$FX/gh.log"))"
grep -q 'BEFORE-MERGE MIGRATE: skipped' "$BD/pipeline.log" && ok || bad "T1 a skip is logged"
# T2 project-5 (no approve_head): the live head moved after the review. The
# stage reads the live head before the dispatch and dispatches nothing.
newcase; echo "$OTHER" > "$FX/head.sha"; OUT=$(t1)
[ "$(cnt "$FX/dispatch.log")" = 0 ] && grep -q "repos/o/p/pulls/$PRN" "$FX/gh.log" && ok \
  || bad "T2 project-5 moved head: 0 dispatch, live head read (dispatches $(cnt "$FX/dispatch.log"))"
head -n1 "$FX/comment.md" | grep -q 'decision=retry' && grep -q 'HOTFIX-MIGRATE: retry' <<<"$OUT" && ok \
  || bad "T2 a moved head is a retry proof (got $(head -n1 "$FX/comment.md" 2>/dev/null); $(tr '\n' ' ' <<<"$OUT"))"
newcase; OUT=$(t1 HEADBOUND_SHA="$OTHER")
[ ! -s "$FX/gh.log" ] && ok || bad "T1 a head the verdict did not judge: the stage must not run"
rows_reset; newcase; OUT=$(t1)
[ ! -s "$FX/gh.log" ] && ok || bad "T1 a project with no row: the stage must not run"
row hotfix_migrate.conf.project-5 '{"before_merge":0,"workflow":"migrate-manual.yml"}'; newcase; OUT=$(t1)
[ ! -s "$FX/gh.log" ] && ok || bad "T1 before_merge 0 is the kill switch"
row hotfix_migrate.conf.project-5 "$TSROW"; newcase
printf 'refused: x\n' > "$FX/log-$(printf '%s' "$TSF" | tr '/' '_')"; echo 1 > "$FX/wrc-$(printf '%s' "$TSF" | tr '/' '_')"
OUT=$(t1)
grep -q '^TIER=2$' <<<"$OUT" && grep -q 'HOTFIX-MIGRATE: hold' <<<"$OUT" && ok || bad "T1 a hold forces tier 2 (got $(tr '\n' ' ' <<<"$OUT"))"

# ============================================================================
# M. the conductor reads the stage's proof for a normal PR
# ============================================================================
CLASSIFY="$REPO/bin/lib/mc/classify.sh"
# The PR's files read, built from the E1 worktree with real blob shas, and the
# comments read = the proof comment E1's real stage run posted (round trip).
printf '[{"filename":"%s","status":"added","sha":"%s"},{"filename":"src/a.ts","status":"added","sha":"aa"}]' \
  "$X1F" "$(git -C "$WT1" rev-parse "HEAD:$X1F")" > "$T/pr-files.json"
mcomments() { jq -n --rawfile b "$1" '[{body:"unrelated"},{body:$b}]' > "$T/pr-comments.json"; }
mrun() { # mrun <project> [labels] -> "STATE|WHY|mmh-called|rest-reads"
  ( export HARNESS="$REPO"; H="$REPO"
    setting_get() { [ -f "$T/set/$1" ] || return 2; cat "$T/set/$1"; }
    . "$CLASSIFY" || exit 9
    mc_rest_var() { local -n _v="$1"; echo "$4" >> "$T/rest.log"; case "$4" in pulls/*) _v=$(cat "$T/pr-files.json") ;; *) _v=$(cat "$T/pr-comments.json") ;; esac; }
    mc_log() { printf '%s\n' "$*" >> "$T/mclog"; }
    . "$REPO/bin/merge-conductor.d/bh-7785-migration-hold.sh" || exit 8
    . "$REPO/bin/merge-conductor.d/bh-9403-before-merge-proof.sh" || exit 7
    mmh_decide() { echo called >> "$T/mmh.log"; MMH_VERDICT="${MMH_V:-missing}"; MMH_NAMES=20261110000000_x; MMH_DETAIL="not in the production migration ledger"; MMH_SRC=t; }
    mc_hold_comment() { :; }; mc_alert() { :; }; mc_attempt_has() { return 0; }; mc_attempt_put() { :; }
    STATE=READY; WHY=ready; P="$1"; SLUG=o/p; NUM=9; KEY="o/p#9"; HEAD="$HEAD1"; RAWLBL="${2:-ai-build}"; REC=""; ACTIONS=1; KILL=0
    mc_mig_hold
    printf '%s|%s|%s|%s\n' "$STATE" "$WHY" "$(cnt "$T/mmh.log")" "$(cnt "$T/rest.log")" )
}
mreset() { rm -f "$T/mmh.log" "$T/rest.log" "$T/mclog"; }
rows_reset; row hotfix_migrate.conf.mk-os "$MKROW"; row migrations_glob.mk-os 'prisma/sql/*.sql'
# M1 an applied proof for exactly this SQL, and production holds it: READY, no
# HELD_MIGRATION. The production ledger is still asked: the proof never stands in for it.
mreset; mcomments "$E1FX/comment.md"; R=$(MMH_V=applied mrun mk-os)
[ "${R%%|*}" = READY ] && [ "$(cut -d'|' -f3 <<<"$R")" = 1 ] && ok || bad "M1 applied proof + applied ledger: READY, mmh_decide asked once (got $R)"
grep -q 'the before-merge workflow says applied' "$T/mclog" && ! grep -q HELD_MIGRATION "$T/mclog" && ok || bad "M1 the log line ($(cat "$T/mclog" 2>/dev/null))"
# M1b an applied proof that production does NOT hold (a run bound to the wrong
# dispatch): HELD_MIGRATION, the proof does not override the ledger
mreset; mcomments "$E1FX/comment.md"; R=$(MMH_V=missing mrun mk-os)
[ "${R%%|*}" = WAIT_CI ] && grep -q 'HELD_MIGRATION' <<<"$R" && [ "$(cut -d'|' -f3 <<<"$R")" = 1 ] && ok \
  || bad "M1b an applied proof must not hide a file production lacks (got $R)"
# M2 a hold proof: BLOCKED_HUMAN, so no merge-queue label
mreset; sed '1s/decision=applied/decision=hold/' "$E1FX/comment.md" > "$T/hold.md"; mcomments "$T/hold.md"; R=$(mrun mk-os)
[ "${R%%|*}" = BLOCKED_HUMAN ] && grep -q '^BLOCKED_HUMAN|before-merge-migration-hold' <<<"$R" && [ "$(cut -d'|' -f3 <<<"$R")" = 0 ] && ok \
  || bad "M2 a hold proof parks BLOCKED_HUMAN (got $R)"
( . "$CLASSIFY"; mc_resolver_owns "before-merge-migration-hold: x" ) && bad "M2 the hold must not be resolver-owned" || ok
# M2b a retry proof (a stop before any dispatch): not parked, mmh_decide decides
mreset; sed '1s/decision=applied/decision=retry/' "$E1FX/comment.md" > "$T/retry.md"; mcomments "$T/retry.md"; R=$(mrun mk-os)
[ "${R%%|*}" != BLOCKED_HUMAN ] && [ "$(cut -d'|' -f3 <<<"$R")" = 1 ] && ok || bad "M2b a retry proof must not park BLOCKED_HUMAN (got $R)"
# M3 no marker: unchanged, mmh_decide runs (and holds HELD_MIGRATION as before)
mreset; echo '[{"body":"no marker here"}]' > "$T/pr-comments.json"; R=$(mrun mk-os)
[ "$(cut -d'|' -f3 <<<"$R")" = 1 ] && [ "${R%%|*}" = WAIT_CI ] && grep -q 'HELD_MIGRATION' <<<"$R" && ok || bad "M3 no marker: mmh_decide decides (got $R)"
# M4 a stale FP: unchanged
mreset; sed -E '1s/fp=[0-9a-f]+/fp=0000000000000000000000000000000000000000000000000000000000000000/' "$E1FX/comment.md" > "$T/stale.md"; mcomments "$T/stale.md"; R=$(mrun mk-os)
[ "$(cut -d'|' -f3 <<<"$R")" = 1 ] && [ "${R%%|*}" = WAIT_CI ] && ok || bad "M4 a stale FP changes nothing (got $R)"
# M5 a project with no row: mc_hotfix_proof is not called, 0 REST reads
mreset; mcomments "$E1FX/comment.md"; R=$(mrun other-os)
[ "$(cut -d'|' -f4 <<<"$R")" = 0 ] && [ "$(cut -d'|' -f3 <<<"$R")" = 1 ] && ok || bad "M5 no row: 0 REST reads, mmh_decide runs (got $R)"
# a hotfix PR keeps the merge-conductor.sh gate: this fragment reads nothing
mreset; R=$(mrun mk-os hotfix)
[ "$(cut -d'|' -f4 <<<"$R")" = 0 ] && ok || bad "M5 a hotfix PR is not this fragment's (got $R)"
# MC_HFP_ANY_LABEL changes nothing for a caller that does not set it
( export HARNESS="$REPO"; . "$CLASSIFY"; mc_rest_var() { echo x >> "$T/rest.log"; return 1; }
  [ "$(mc_hotfix_proof o/p 9 ai-build "" mk-os)" = n/a ] ) && ok || bad "M5 without the flag a non-hotfix PR is n/a"

# ============================================================================
# S1. the seed rows land in the composed schema
# ============================================================================
SQ="$REPO/worker/jobs/schema.sql"   # composed by jobs_schema_render above
for k in project-6-os project-5; do
  v=$(grep -o "'hotfix_migrate.conf.$k','[^']*'" "$SQ" | sed -E "s/^'[^']*','//; s/'$//")
  [ "$(jq -e .before_merge <<<"$v" 2>/dev/null)" = 1 ] && ok || bad "S1 the seed row for $k must parse with before_merge 1 (got '$v')"
done
grep -q 'migrate-manual.yml' <<<"$(grep "hotfix_migrate.conf.project-5" "$SQ")" && ok || bad "S1 project-5 stays on migrate-manual.yml"

echo "hotfix-migrate-before-merge: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
