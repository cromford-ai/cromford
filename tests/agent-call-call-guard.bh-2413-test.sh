#!/bin/bash
# tests/agent-call-call-guard.bh-2413-test.sh — BH-2413: the build's plan,
# execute and fix calls carry a STABLE AGENT_CALL_FP, so re-buying an identical
# plan across builds counts against the K3 cap.
#
#   A. bin/lib/call-guard.sh call_guard_build_fp, sourced (the pure builder)
#   B. bin/lib/rb/plan.sh's `build call fp` / `call fp reuse` / `call fp write`
#      blocks, extracted from the flattened pipeline and driven on fixtures
#   C. the production entry: the REAL extracted CC() -> the REAL
#      bin/agent-call.sh -> a fake worker `curl` (bh-2305's shape)
#   D. the fix fingerprint: round name and tree ride on it
#
# Run from anywhere: tests/agent-call-call-guard.bh-2413-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

SHA1=4a46293e1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f
SHA2=1797a7f9aa2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f
META='{"title":"K3 call guard","body":"make the fp stable"}'
THREAD1='[[9001,"2026-09-25T18:00:00Z"]]'
THREAD2='[[9001,"2026-09-25T18:00:00Z"],[9002,"2026-09-25T18:30:00Z"]]'
THREAD1E='[[9001,"2026-09-25T18:05:00Z"]]'

# --- A. the pure builder -----------------------------------------------------
bfp() { # bfp <key> <sha> <material> -> stdout, and call_guard_build_fp's rc
  ( . "$DIR/bin/lib/call-guard.sh" || exit 9; printf '%s' "$3" | call_guard_build_fp "$1" "$2" )
}
a1=$(bfp BH-1 "$SHA1" "$META$THREAD1"); a1b=$(bfp BH-1 "$SHA1" "$META$THREAD1")
[ -n "$a1" ] && [ "$a1" = "$a1b" ] && ok || bad "A1 same material+sha gave '$a1' vs '$a1b'"
[[ "$a1" =~ ^BH-1:th[0-9a-f]{16}:m[0-9a-f]{12}$ ]] && ok || bad "A1 shape '$a1'"
[ "${a1##*:m}" = "${SHA1:0:12}" ] && ok || bad "A1 the m part is not the sha prefix: '$a1'"
a2=$(bfp BH-1 "$SHA1" "$META$THREAD2")
[ -n "$a2" ] && [ "$a2" != "$a1" ] && ok || bad "A2 an extra comment kept the fp '$a2'"
a3=$(bfp BH-1 "$SHA2" "$META$THREAD1")
[ -n "$a3" ] && [ "$a3" != "$a1" ] && ok || bad "A3 a moved sha kept the fp '$a3'"
for c in "empty-material||$SHA1" "blank-material|   |$SHA1" "empty-sha|$META|" "zzz-sha|$META|zzz" "short-sha|$META|4a46" "empty-key|$META|$SHA1"; do
  name=${c%%|*}; rest=${c#*|}; m=${rest%|*}; s=${rest##*|}; k=BH-1
  [ "$name" = empty-key ] && k=""
  o=$(bfp "$k" "$s" "$m"); BFP_RC=$?
  [ "$BFP_RC" = 1 ] && [ -z "$o" ] && ok || bad "A4 $name: rc $BFP_RC out '$o', want rc 1 and nothing"
done
a5=$(bfp BH-1 "$SHA1" "$META$THREAD1E")
[ -n "$a5" ] && [ "$a5" != "$a1" ] && ok || bad "A5 a comment edit kept the fp"
a6=$(bfp BH-2 "$SHA1" "$META$THREAD1")
[ -n "$a6" ] && [ "$a6" != "$a1" ] && ok || bad "A6 two keys with one material share '$a6'"

# --- B. the plan-stage blocks ------------------------------------------------
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
cut_block() { awk -v n="$1" '$0=="# >>> " n{f=1;next} $0=="# <<< " n{exit} f' "$RB_ALL" > "$2"; }
cut_block "build call fp" "$T/b-fns.sh"
cut_block "call fp reuse" "$T/b-reuse.sh"
cut_block "call fp write" "$T/b-write.sh"
[ -s "$T/b-fns.sh" ] && [ -s "$T/b-reuse.sh" ] && [ -s "$T/b-write.sh" ] && ok \
  || bad "B0 could not extract the build call fp blocks from the pipeline"
# ordering: the reuse read sits before the checkpoint if, the write in the fresh-plan branch
ln_of() { grep -n -m1 -F -x "$1" "$RB_ALL" | cut -d: -f1; }
l_reuse=$(ln_of "# >>> call fp reuse"); l_ckpt=$(grep -n -m1 '^if \[ -s "\$BUILD/plan.md" \] && ! PLAN_IS_BLOCKED' "$RB_ALL" | cut -d: -f1)
l_write=$(ln_of "# >>> call fp write"); l_tfw=$(ln_of "# >>> ticket fingerprint write"); l_plan=$(ln_of "# >>> plan prompt (tests/run-build-test-home.bh-580-test.sh drives this block)")
[ -n "$l_reuse" ] && [ -n "$l_ckpt" ] && [ "$l_reuse" -lt "$l_ckpt" ] && ok || bad "B0 reuse ($l_reuse) is not before the checkpoint if ($l_ckpt)"
[ -n "$l_write" ] && [ -n "$l_tfw" ] && [ -n "$l_plan" ] && [ "$l_write" -gt "$l_ckpt" ] && [ "$l_write" -lt "$l_plan" ] && ok \
  || bad "B0 write ($l_write) is not in the fresh-plan branch before the plan prompt ($l_plan)"

HB="$T/hb"; mkdir -p "$HB/bin/lib"
cp "$DIR/bin/lib/call-guard.sh" "$HB/bin/lib/call-guard.sh"
cat > "$HB/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in
  board_prefix) printf '%s\n' "${FAKE_PREFIX:--}" ;;
  repo) printf '%s\n' "example-org/cromford" ;;
  prod) printf '%s\n' "-" ;;
esac
EOF
chmod +x "$HB/bin/fleet-conf.sh"
# BH-7919: TICKET_THREAD_SIG now asks bin/lib/tracker.sh trk_gh_issue_number.
scratch_install_closure bin/lib/tracker.sh "$HB" >/dev/null || exit 1
W="$T/wt"; mkdir -p "$W"
( cd "$W" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base \
  && git update-ref refs/remotes/origin/main HEAD ) || bad "B0 scratch repo"
W_SHA=$(git -C "$W" rev-parse HEAD)

# drive_b <build-dir> <mode> ; env: FP_BEFORE, FAKE_PREFIX, GH_RC, GH_BODY, B_BASE
# mode: fresh (reuse + write) | resume (reuse only). Prints BUILD_CALL_FP.
drive_b() {
  local B="$1" mode="$2"
  ( HARNESS="$HB"; PROJECT=cromford; KEY=BH-2413; BUILD="$B"; WT="$W"; BASE="${B_BASE:-main}"
    FP_BEFORE="${FP_BEFORE:-}"
    STAMP() { echo now; }
    # prints the body EVEN on a failing rc, so only the rc check can refuse it
    gh_rest() { echo "$*" >> "$T/gh.calls"; printf '%s\n' "$GH_BODY"; return "${GH_RC:-0}"; }
    export FAKE_PREFIX
    . "$T/b-fns.sh"
    . "$T/b-reuse.sh"
    [ "$mode" = fresh ] && . "$T/b-write.sh"
    printf '%s' "${BUILD_CALL_FP:-}" )
}
GH_JSON='[{"id":9001,"updated_at":"2026-09-25T18:00:00Z","body":"hi"}]'
newb() { local b="$T/b/$1"; scratch_rm "$b"; mkdir -p "$b"; printf '%s\n' "$META" > "$b/ticket-meta.json"; printf '%s' "$b"; }

# B1 in-app board: FP_BEFORE is the thread signal
B=$(newb b1); FPB='2026-09-25T18:00:00Z|2026-09-25T18:00:00Z|2026-09-25T17:00:00Z|3'
got=$(FP_BEFORE="$FPB" FAKE_PREFIX=/api drive_b "$B" fresh)
want=$(bfp BH-2413 "$W_SHA" "$(jq -c '{title,body}' "$B/ticket-meta.json")"$'\n'"$FPB")
[ -n "$want" ] && [ "$got" = "$want" ] && [ "$(cat "$B/call-fp" 2>/dev/null)" = "$want" ] && ok \
  || bad "B1 in-app: BUILD_CALL_FP '$got' file '$(cat "$B/call-fp" 2>/dev/null)' want '$want'"
# B2 GitHub project: FP_BEFORE empty, the comments projection is the signal
: > "$T/gh.calls"
B=$(newb b2)
got=$(FP_BEFORE="" FAKE_PREFIX=- GH_BODY="$GH_JSON" drive_b "$B" fresh)
want=$(bfp BH-2413 "$W_SHA" "$(jq -c '{title,body}' "$B/ticket-meta.json")"$'\n'"$(jq -c '[.[] | [.id, .updated_at]]' <<<"$GH_JSON")")
[ -n "$want" ] && [ "$got" = "$want" ] && [ "$(cat "$B/call-fp" 2>/dev/null)" = "$want" ] && ok \
  || bad "B2 github: BUILD_CALL_FP '$got' want '$want'"
grep -q 'GET repos/example-org/cromford/issues/2413/comments' "$T/gh.calls" && ok || bad "B2 gh_rest call: $(cat "$T/gh.calls")"
# B2b a changed GitHub thread gives a different fp through the block
B=$(newb b2b)
got2=$(FP_BEFORE="" FAKE_PREFIX=- GH_BODY='[{"id":9001,"updated_at":"2026-09-25T18:00:00Z"},{"id":9002,"updated_at":"2026-09-25T19:00:00Z"}]' drive_b "$B" fresh)
[ -n "$got2" ] && [ "$got2" != "$got" ] && ok || bad "B2b a new comment kept the fp '$got2'"
# B3 no ticket-meta.json -> no file, one log line
B=$(newb b3); rm -f "$B/ticket-meta.json"; printf 'stale\n' > "$B/call-fp"
got=$(FP_BEFORE="$FPB" FAKE_PREFIX=/api drive_b "$B" fresh)
[ -z "$got" ] && [ ! -e "$B/call-fp" ] && ok || bad "B3 no meta: fp '$got', file present=$([ -e "$B/call-fp" ] && echo y || echo n)"
[ "$(grep -c 'no stable call fp' "$B/pipeline.log" 2>/dev/null)" = 1 ] && grep -q 'no ticket-meta' "$B/pipeline.log" && ok \
  || bad "B3 log: $(cat "$B/pipeline.log" 2>/dev/null)"
# B4 gh_rest rate limited (75) -> no signal, no file
B=$(newb b4)
got=$(FP_BEFORE="" FAKE_PREFIX=- GH_RC=75 GH_BODY="$GH_JSON" drive_b "$B" fresh)
[ -z "$got" ] && [ ! -e "$B/call-fp" ] && grep -q 'no stable call fp (no thread signal)' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "B4 rate limited: fp '$got' log '$(cat "$B/pipeline.log" 2>/dev/null)'"
# B4b gh_rest rc 0 but an unparseable body -> no signal
B=$(newb b4b)
got=$(FP_BEFORE="" FAKE_PREFIX=- GH_BODY="not json" drive_b "$B" fresh)
[ -z "$got" ] && [ ! -e "$B/call-fp" ] && ok || bad "B4b unparseable comments gave fp '$got'"
# B5 origin/$BASE unresolvable -> no file
B=$(newb b5)
got=$(FP_BEFORE="$FPB" FAKE_PREFIX=/api B_BASE=no-such-branch drive_b "$B" fresh)
[ -z "$got" ] && [ ! -e "$B/call-fp" ] && grep -q 'no stable call fp (origin/no-such-branch' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "B5 no base: fp '$got' log '$(cat "$B/pipeline.log" 2>/dev/null)'"
# B6 resume: an existing call-fp is read back unchanged, nothing recomputed
B=$(newb b6); printf 'BH-2413:th0123456789abcdef:m0123456789ab\n' > "$B/call-fp"
got=$(FP_BEFORE="$FPB" FAKE_PREFIX=/api drive_b "$B" resume)
[ "$got" = "BH-2413:th0123456789abcdef:m0123456789ab" ] && ok || bad "B6 resume read '$got'"

# --- C. production entry: CC() -> bin/agent-call.sh -> fake worker ------------
python3 - "$RB_ALL" "$T/cc.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("CC() { # CC <stage>")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write(src[start:end])
PY
[ -s "$T/cc.sh" ] && ok || bad "C0 could not extract CC()"

mkdir -p "$T/bin/lib/jobs" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
mrs_fixture "$T" testproj
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/jobs/"*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/env-path.sh"
cp "$DIR/bin/billing-mode.sh" "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexec bash "%s/bin/agent-call.sh" "$@"\n' "$DIR" > "$T/bin/agent-call.sh"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
echo '{"result":"the answer","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# THE FAKE WORKER (bh-2305's shape). Rows: call_id<TAB>project<TAB>stage<TAB>fp<TAB>status.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) data="$2"; shift 2 ;;
    -X|-m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
case "$url" in */api/call-guard/*) ;; *) exit 7 ;; esac
touch "$CG_ROWS"
case "$url" in
  */claim)
    id=$(jq -r .call_id <<<"$data"); p=$(jq -r .project <<<"$data"); s=$(jq -r .stage <<<"$data")
    f=$(jq -r .fp <<<"$data"); m=$(jq -r .max <<<"$data")
    n=$(awk -F'\t' -v p="$p" -v s="$s" -v f="$f" '$2==p && $3==s && $4==f && ($5=="claimed"||$5=="ok"||$5=="empty"||$5=="failed"){c++} END{print c+0}' "$CG_ROWS")
    if [ "$n" -lt "$m" ]; then
      printf '%s\t%s\t%s\t%s\tclaimed\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      printf '{"allowed":true,"count":%s,"max":%s,"call_id":"%s"}\n200' "$((n+1))" "$m" "$id"
    else
      printf '%s\t%s\t%s\t%s\trefused\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      printf '{"allowed":false,"count":%s,"max":%s,"call_id":"%s","top":[{"fp":"%s","paid":%s,"refused":1}]}\n200' "$n" "$m" "$id" "$f" "$n"
    fi ;;
  */settle)
    id=$(jq -r .call_id <<<"$data"); o=$(jq -r .outcome <<<"$data")
    awk -F'\t' -v OFS='\t' -v id="$id" -v o="$o" '$1==id && $5=="claimed"{$5=o} {print}' "$CG_ROWS" > "$CG_ROWS.tmp" && mv "$CG_ROWS.tmp" "$CG_ROWS"
    printf '{"settled":true}\n200' ;;
  *) printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404' ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

ROWS="$T/cg.rows"
reset() { : > "$T/order"; : > "$ROWS"; rm -f "$T/logs/"* "$T"/flags/alerted-* 2>/dev/null; }
# cc <build-dir> <stage> <outfile-basename> <build-call-fp> [VAR=VAL ...] -> prints the rc.
# The prompt embeds the build dir, exactly as every real plan/execute prompt does.
# Runs from the scratch repo $CCWD (the tree the fix fp reads).
CCWD="$W"
cc() {
  local b="$1" stage="$2" out="$3" bfp="$4" su; shift 4
  mkdir -p "$b"
  su=$(printf '%s' "$stage" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]_' '_')
  ( unset AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET AGENT_CALL_GUARD_FORCE HARNESS_TICKET AGENT_CALL_FP \
          CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP CALL_GUARD_FAIL_CLOSED_METERED
    export ORDER_SINK="$T/order" CG_ROWS="$ROWS" \
           PATH="$T/fakebin:$PATH" HOME="$T" \
           JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox \
           CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 "RUNNER_$su=claude" "RUNNER_${su}_FALLBACK=" \
           LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    export HARNESS="$T"
    cd "$CCWD" || exit 9
    set -u
    HARNESS="$T"; PROJECT=testproj; CG_ORIENT="CODEGRAPH NOT AVAILABLE"; VMAP_ORIENT="VMAP"
    BUILD_CALL_FP="$bfp"
    . "$T/cc.sh"
    CC "$stage" claude-fable-5-1 60 "$b/$out" "$stage for BH-2413 ($out). Write to $b/plan.md." >/dev/null 2>&1 )
  echo $?
}
vendor_calls() { grep -c . "$T/order" 2>/dev/null || true; }
fps_of() { awk -F'\t' -v s="$1" '$3==s{print $4}' "$ROWS"; }

FP1=$(bfp BH-2413 "$SHA1" "$META$THREAD1")
# C1/C2: plan=2 — builds 1 and 2 share one fp, build 3 is refused before the vendor
reset
r1=$(cc "$T/c/b1" plan plan-run.txt "$FP1" CALL_GUARD_MAX_MAP="plan=2 default=2")
r2=$(cc "$T/c/b2" plan plan-run.txt "$FP1" CALL_GUARD_MAX_MAP="plan=2 default=2")
[ "$r1" = 0 ] && [ "$r2" = 0 ] && ok || bad "C1 builds 1,2 rcs $r1 $r2"
u=$(fps_of plan | sort -u)
[ "$(fps_of plan | grep -c .)" = 2 ] && [ "$u" = "$FP1" ] && ok || bad "C1 plan rows carry fps '$(fps_of plan | tr '\n' ' ')', want both '$FP1'"
r3=$(cc "$T/c/b3" plan plan-run.txt "$FP1" CALL_GUARD_MAX_MAP="plan=2 default=2")
[ "$r3" = 74 ] && [ "$(vendor_calls)" = 2 ] && ok || bad "C2 build 3 rc $r3 vendor $(vendor_calls), want 74 and 2"
head -1 "$T/c/b3/plan-run.txt" 2>/dev/null | grep -q '^AGENT_CALL_REFUSED call-guard' && ok \
  || bad "C2 build 3 plan-run.txt line 1: '$(head -1 "$T/c/b3/plan-run.txt" 2>/dev/null)'"
# C3: the default map (plan K=3): builds 1..3 run, build 4 is refused
reset; rcs=""
for i in 1 2 3 4; do rcs="$rcs $(cc "$T/c3/b$i" plan plan-run.txt "$FP1")"; done
[ "$rcs" = " 0 0 0 74" ] && [ "$(vendor_calls)" = 3 ] && ok || bad "C3 default K: rcs '$rcs' vendor $(vendor_calls)"
# C4: execute carries the same stable fp on stage execute
reset
r=$(cc "$T/c4/b1" execute execute-run.txt "$FP1")
[ "$r" = 0 ] && [ "$(fps_of execute)" = "$FP1" ] && ok || bad "C4 execute rc $r fp '$(fps_of execute)'"
# C5: a changed thread -> a new fp -> build 5 runs even with plan=2 exhausted on FP1
reset
cc "$T/c5/b1" plan plan-run.txt "$FP1" CALL_GUARD_MAX_MAP="plan=2" >/dev/null
cc "$T/c5/b2" plan plan-run.txt "$FP1" CALL_GUARD_MAX_MAP="plan=2" >/dev/null
FP_T2=$(bfp BH-2413 "$SHA1" "$META$THREAD2")
r=$(cc "$T/c5/b5" plan plan-run.txt "$FP_T2" CALL_GUARD_MAX_MAP="plan=2")
[ "$r" = 0 ] && [ "$(fps_of plan | tail -1)" = "$FP_T2" ] && [ "$FP_T2" != "$FP1" ] && ok || bad "C5 changed thread rc $r fp '$(fps_of plan | tail -1)'"
# C6: a moved main -> a new fp -> runs
FP_M2=$(bfp BH-2413 "$SHA2" "$META$THREAD1")
r=$(cc "$T/c6/b6" plan plan-run.txt "$FP_M2" CALL_GUARD_MAX_MAP="plan=2")
[ "$r" = 0 ] && [ "$(fps_of plan | tail -1)" = "$FP_M2" ] && [ "$FP_M2" != "$FP1" ] && ok || bad "C6 moved main rc $r fp '$(fps_of plan | tail -1)'"
# C7: plan repairs, size repairs and review calls keep the per-build fallback
reset
for o in plan-repair-run.txt size-repair-run.txt; do
  cc "$T/c7/b1" plan "$o" "$FP1" >/dev/null
  cc "$T/c7/b2" plan "$o" "$FP1" >/dev/null
done
cc "$T/c7/b1" review review-run.txt "$FP1" >/dev/null
grep -qxF "$FP1" <<<"$(fps_of plan)" && bad "C7 a repair call carried the stable fp: $(fps_of plan | tr '\n' ' ')" || ok
[ "$(fps_of plan | grep -c ':p')" = 4 ] && [ "$(fps_of plan | sort -u | grep -c .)" = 4 ] && ok \
  || bad "C7 repair fps are not 4 distinct fallbacks: $(fps_of plan | tr '\n' ' ')"
case "$(fps_of review)" in "$FP1"*|"") bad "C7 review fp '$(fps_of review)'" ;; *:p*) ok ;; *) bad "C7 review fp '$(fps_of review)'" ;; esac
# C8: an empty BUILD_CALL_FP -> the fallback shape, and two builds do not share it
reset
cc "$T/c8/b1" plan plan-run.txt "" >/dev/null
cc "$T/c8/b2" plan plan-run.txt "" >/dev/null
[ "$(fps_of plan | grep -c ':p')" = 2 ] && [ "$(fps_of plan | sort -u | grep -c .)" = 2 ] && ok \
  || bad "C8 empty BUILD_CALL_FP fps: $(fps_of plan | tr '\n' ' ')"

# --- D. the fix fingerprint --------------------------------------------------
W2="$T/wt2"; mkdir -p "$W2"
( cd "$W2" && git init -q -b main . && echo a > f && git add f && git -c user.email=t@t -c user.name=t commit -q -m a ) || bad "D0 repo2"
W3="$T/wt3"; mkdir -p "$W3"
( cd "$W3" && git init -q -b main . && echo a > f && git add f && git -c user.email=x@x -c user.name=x commit -q -m other-msg ) || bad "D0 repo3"
W4="$T/wt4"; mkdir -p "$W4"
( cd "$W4" && git init -q -b main . && echo b > f && git add f && git -c user.email=t@t -c user.name=t commit -q -m a ) || bad "D0 repo4"
reset
CCWD="$W2"; cc "$T/d/b1" fix fix-run.txt "$FP1" >/dev/null
CCWD="$W3"; cc "$T/d/b2" fix fix-run.txt "$FP1" >/dev/null
d1=$(fps_of fix | sed -n 1p); d2=$(fps_of fix | sed -n 2p)
tree=$(git -C "$W2" rev-parse --short=12 'HEAD^{tree}')
[ -n "$d1" ] && [ "$d1" = "$d2" ] && [ "$d1" = "$FP1:fix-run.txt:t$tree" ] && ok \
  || bad "D1 identical trees in two builds: '$d1' vs '$d2' (want '$FP1:fix-run.txt:t$tree')"
CCWD="$W4"; cc "$T/d/b3" fix fix-run.txt "$FP1" >/dev/null
d3=$(fps_of fix | sed -n 3p)
[ -n "$d3" ] && [ "$d3" != "$d1" ] && case "$d3" in "$FP1:fix-run.txt:t"*) true ;; *) false ;; esac && ok \
  || bad "D2 a different tree kept the fix fp '$d3'"
CCWD="$W2"; cc "$T/d/b1" fix qa-fix-run.txt "$FP1" >/dev/null
d4=$(fps_of fix | sed -n 4p)
[ "$d4" = "$FP1:qa-fix-run.txt:t$tree" ] && [ "$d4" != "$d1" ] && ok || bad "D3 qa-fix vs fix on one tree: '$d4' vs '$d1'"
CCWD="$T/c"; cc "$T/d/b4" fix fix-run.txt "$FP1" >/dev/null
d5=$(fps_of fix | sed -n 5p)
case "$d5" in "$FP1"*) bad "D4 a fix outside a git tree carried the stable fp '$d5'" ;; *:p*) ok ;; *) bad "D4 fp '$d5'" ;; esac

echo "agent-call-call-guard.bh-2413: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
