#!/bin/bash
# tests/execute-resume.bh-9123-test.sh — BH-9123 (slice C1 of BH-9064), the
# execute checkpoint, resume and park.
#
# An execute session that ends rc 124 (timeout), rc 143 (kill) or with a
# context kill ($OUT.ctxkill) is relaunched from a brief of its pushed work
# (bin/lib/execute-checkpoint-brief.sh, prompts/stages/execute-resume.md),
# with --resume <sid> when the session file is on this box. At the attempt cap,
# or when the ledger refuses the call as terminal, the build parks:
# RESULT "EXECUTE_EMPTY parked: ...", exit 3.
#
# This suite DRIVES the real code: the `lane checkpoints` block (CC, CKPT_*),
# the `execute prompt` block and the `execute result` block, cut from the
# flattened pipeline (tests/lib/rb-all.sh) by their markers. CC runs the REAL
# bin/agent-call.sh against a fake claude on PATH and the REAL jobs worker on a
# node:sqlite file (tests/lib/ledger-worker-fake.bh-9064.sh), with K3 (the call
# guard) on its default map (execute=3). No network, no vendor.
# Each case has its own fingerprint and its own repo, so no case depends on
# another or on order.
#
# Run from anywhere: tests/execute-resume.bh-9123-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/tests/lib/ledger-worker-fake.bh-9064.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }
node -e 'require("node:sqlite")' 2>/dev/null || { echo "node:sqlite missing — skipping"; exit 0; }

export HOME="$T/home"; mkdir -p "$HOME"
git config --global user.email harness@localhost >/dev/null 2>&1
git config --global user.name  harness           >/dev/null 2>&1
git config --global init.defaultBranch main      >/dev/null 2>&1

# --- the scratch harness ------------------------------------------------------
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$T/fakebin" "$H/flags" "$H/locks" "$H/logs" "$H/state"
mrs_fixture "$H" fixproj
# One claude model, so a failed call is not retried on a second model inside
# agent-call: each fake-claude call below is one execute call of the build.
for R in claude.ladder claude.ladder@fixproj; do printf '0\tclaude-fable-5-1\tclaude\n' > "$H/state/model-routes/$R.tsv"; done
for S in bin/agent-call.sh bin/jobs-client.sh bin/lib/jobs/agent-call-ledger.sh \
         bin/lib/execute-checkpoint-brief.sh bin/lib/stage-prompt.sh bin/lib/execute-empty.sh; do
  ( cd "$DIR" && scratch_install_closure "$S" "$H" ) >/dev/null || { echo "FAIL: could not install the closure of $S"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$H/bin/sync-agent-rules.sh"
lwf_install "$T/fakebin" "$T/jobs.db"

# The fake vendor. It logs its argv and its prompt (stdin) per call, makes one
# commit in the worktree, then ends with the next rc of $FC_PLAN (one word per
# call). An argv it does not know is exit 99: no real vendor is ever reached.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) echo "  --resume <id>   resume a session"; exit 0 ;; esac
case " $* " in *" -p "*|*" --print "*) ;; *) echo "fake claude: unknown argv $*" >&2; exit 99 ;; esac
n=$(( $(cat "$FC_DIR/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FC_DIR/n"
printf '%s\n' "$*" > "$FC_DIR/argv.$n"
# The session file claude keeps, when the case says it is on this box.
sid=""; prev=""; for a in "$@"; do [ "$prev" = --session-id ] && sid=$a; prev=$a; done; prev=""
if [ -n "$sid" ] && [ "${FC_TRANSCRIPT:-0}" = 1 ]; then
  mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-fixture-wt"
  echo '{"type":"fixture"}' > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-fixture-wt/$sid.jsonl"
fi
cat > "$FC_DIR/prompt.$n" 2>/dev/null
for a in "$@"; do [ "${prev:-}" = -p ] && [ "$a" != -p ] && printf '%s' "$a" >> "$FC_DIR/prompt.$n"; prev=$a; done
echo "fixture step $n" > "step-$n.txt"; git add -A >/dev/null 2>&1; git commit -qm "feat: fixture step $n" >/dev/null 2>&1
rc=$(printf '%s\n' $FC_PLAN | sed -n "${n}p"); rc=${rc:-0}
[ "$rc" = 0 ] && { echo "{\"result\":\"done $n\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2},\"total_cost_usd\":0.01}"; exit 0; }
echo "fixture stop rc $rc" >&2; exit "$rc"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/"* "$H/bin/beat.sh" "$H/bin/sync-agent-rules.sh"

# --- the three blocks, cut by their markers from the flattened pipeline -------
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten bin/run-build.sh"; exit 1; }
cut_block() { awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"; }
cut_block "lane checkpoints" "$T/ckpt.sh"
cut_block "execute prompt"   "$T/prompt.sh"
cut_block "execute result"   "$T/result.sh"
# CC() itself: the function the pipeline defines, from `CC() {` to its closing `}`.
awk '/^CC\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RB_ALL" > "$T/cc.sh"
for B in ckpt cc prompt result; do
  [ -s "$T/$B.sh" ] && bash -n "$T/$B.sh" 2>/dev/null && ok || bad "could not cut a parsing '$B' block — markers missing?"
done

N=0
# fresh <fp> — a repo on ticket/fx-1 with a bare origin, a build dir with a
# plan, and an empty fake-claude log. Sets WT BUILD FC FP.
fresh() {
  N=$((N+1)); FP="$1"
  WT="$T/wt$N"; BUILD="$T/build$N"; FC="$T/fc$N"
  git init --bare -q "$T/origin$N.git"; git init -q "$WT"; mkdir -p "$BUILD" "$FC"
  ( cd "$WT" && echo base > base.txt && git add -A >/dev/null && git commit -qm base >/dev/null \
    && git remote add origin "$T/origin$N.git" && git push -q -u origin main >/dev/null 2>&1 \
    && git checkout -qb ticket/fx-1 >/dev/null 2>&1 )
  cat > "$BUILD/plan.md" <<'PLAN'
# Plan: FX-1

## Acceptance tests

- `tests/step-one.fixture-test.sh`: the first step works.
- `tests/never-written.fixture-test.sh`: the second step works.

## Size
PLAN
}
# drive [VAR=VAL ...] — run prompt + result blocks once, as rb_execute does.
# Prints "<rc> <RESULT|none>".
drive() {
  ( unset AGENT_CALL_FP AGENT_LEDGER AGENT_LEDGER_MAX_ATTEMPTS LADDER_RESUME_SID CALL_GUARD_MAX_MAP
    export PATH="$T/fakebin:$PATH" HARNESS="$H" FC_DIR="$FC" \
           JOBS_URL="https://jobs.test" HARNESS_SECRET="tok-fixture-bh9123" LWF_SECRET="tok-fixture-bh9123" \
           JOBS_RETRIES=0 JOBS_BOX=fixturebox CLAUDE_CODE_OAUTH_TOKEN=tok-fixture ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 RUNNER_EXECUTE=claude RUNNER_EXECUTE_FALLBACK= \
           LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 CHECKPOINTS=0 \
           SP_STAGES_DIR="$DIR/prompts/stages" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" FC_PLAN="${FC_PLAN:-0}" "$@"
    set -uo pipefail
    PROJECT=fixproj; KEY=FX-1; BASE=main; BRANCH=ticket/fx-1; BUILD_CALL_FP="$FP"
    EXECUTE_MODEL=claude-fable-5-1 EXECUTE_TIMEOUT_SECS=60 CG_ORIENT="" VMAP_ORIENT="map fixture"
    CKPT_RESUME_NOTE=""; KIND_EXEC_NOTE=""; REROUTE_EXEC_NOTE=""
    STAMP() { echo '2026-11-05 00:00:00Z'; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    BB() { :; }; STAGE_LANE_DEFER() { :; }
    cd "$WT" || exit 9
    . "$T/ckpt.sh"
    . "$T/cc.sh"
    CKPT_SQUASH_WIP() { :; }
    . "$H/bin/lib/stage-prompt.sh"
    . "$H/bin/lib/execute-checkpoint-brief.sh"
    . "$T/prompt.sh"
    . "$T/result.sh" ) >"$BUILD/drive.out" 2>&1
  echo "$? $(cat "$BUILD/RESULT" 2>/dev/null || echo none)"
}
calls() { cat "$FC/n" 2>/dev/null || echo 0; }
row() { lwf_sql "SELECT status, attempts, checkpoint FROM agent_call_ledger WHERE project='fixproj' AND stage='execute' AND fp=?" "$1" \
          | jq -r '"\(.status) \(.attempts) \(.checkpoint // "")"'; }
seed() { # seed <fp> <status> <attempts> <rc|null> [checkpoint]
  lwf_sql "INSERT OR REPLACE INTO agent_call_ledger (project,stage,fp,status,attempts,rc,checkpoint,first_at,last_at)
           VALUES ('fixproj','execute',?,?,?,$4,?,strftime('%Y-%m-%dT%H:%M:%SZ','now'),strftime('%Y-%m-%dT%H:%M:%SZ','now'))" \
    "$1" "$2" "$3" "${5:-}"
}
# --- 1. ecb_write: the brief names the last commit and the open items ---------
fresh "FX-1:fixture-brief"
( cd "$WT" && mkdir -p tests && echo x > tests/step-one.fixture-test.sh && git add -A >/dev/null && git commit -qm "test: step one" >/dev/null )
( cd "$WT" && HARNESS="$H" bash -c '. "$1"; ecb_write "$2" "" main' _ "$H/bin/lib/execute-checkpoint-brief.sh" "$BUILD" )
LAST=$(git -C "$WT" log -1 --format='%h %s')
grep -qxF "Last commit: $LAST" "$BUILD/checkpoint-brief.md" 2>/dev/null && ok || bad "1a the brief does not name the last commit '$LAST': $(head -c 400 "$BUILD/checkpoint-brief.md" 2>/dev/null)"
awk '/^## Acceptance items done/{f=1;next} /^## /{f=0} f' "$BUILD/checkpoint-brief.md" | grep -qF 'tests/step-one.fixture-test.sh' \
  && ok || bad "1b the item whose test file is on the branch is not listed as done"
awk '/^## Acceptance items still open/{f=1;next} /^## /{f=0} f' "$BUILD/checkpoint-brief.md" | grep -qF 'tests/never-written.fixture-test.sh' \
  && ok || bad "1c the item no commit names is not listed as open"
grep -q 'step-one.fixture-test.sh' <(sed -n '/^## Diff so far/,/^## Acceptance/p' "$BUILD/checkpoint-brief.md") && ok || bad "1d no diff stat in the brief"
# The 1-argument form (the context meter's) works with no network: JOBS_URL unset.
rm -f "$BUILD/checkpoint-brief.md"
( cd "$WT" && env -u JOBS_URL HARNESS="$H" bash -c '. "$1"; ecb_write "$2"' _ "$H/bin/lib/execute-checkpoint-brief.sh" "$BUILD" ) \
  && grep -q '^Branch: ticket/fx-1$' "$BUILD/checkpoint-brief.md" 2>/dev/null && ok || bad "1e ecb_write <build> alone did not write the brief"
# Sourcing defines functions and does nothing else.
OUT=$(cd "$T" && env -i PATH="$PATH" bash -c '. "$1"; echo sourced' _ "$DIR/bin/lib/execute-checkpoint-brief.sh" 2>&1)
[ "$OUT" = sourced ] && ok || bad "1f sourcing the lib printed or failed: $OUT"

# --- 2. rc 124 then 0, transcript on this box: --resume <sid> + the brief -----
fresh "FX-1:fixture-resume"
OUT=$(FC_PLAN="124 0" drive FC_TRANSCRIPT=1)
[ "$(calls)" = 2 ] && ok || bad "2a want 2 claude calls after rc 124 then 0, got $(calls) (out: $OUT; $(tail -5 "$BUILD/drive.out"))"
SID1=$(sed -n 's/.*--session-id \([^ ]*\).*/\1/p' "$FC/argv.1" 2>/dev/null)
[ -n "$SID1" ] && grep -q -- "--resume $SID1" "$FC/argv.2" 2>/dev/null && ok || bad "2b call 2 argv has no --resume '$SID1': $(cat "$FC/argv.2" 2>/dev/null)"
grep -q -- '--resume' "$FC/argv.1" 2>/dev/null && bad "2c call 1 must not resume" || ok
B1=$(grep '^Last commit: ' "$BUILD/checkpoint-brief.md" 2>/dev/null)
[ -n "$B1" ] && grep -qF "$B1" "$FC/prompt.2" 2>/dev/null && ok || bad "2d call 2 prompt lacks the brief line '$B1'"
grep -qF 'feat: fixture step 1' <<<"$B1" && ok || bad "2e the brief's last commit is not call 1's commit: '$B1'"
grep -qF 'DO NOT START OVER FROM THE PLAN' "$FC/prompt.2" && ok || bad "2f call 2 is not the resume prompt"
grep -qF 'Execute the plan at' "$FC/prompt.2" && bad "2g call 2 got the fresh plan prompt" || ok
[ "${OUT%% *}" = 0 ] && ok || bad "2h the resumed build should pass through (got: $OUT)"
case "$(row "$FP")" in "ok 2 ticket/fx-1@"*" session=$SID1") ok ;; *) bad "2i ledger row '$(row "$FP")', want ok 2 with checkpoint session=$SID1" ;; esac

# --- 3. no transcript on this box: no --resume, the brief is still sent -------
# agent-call retries a killed session once on the same lane (calls 1 and 2);
# its rc 143 is the build's relaunch (call 3).
fresh "FX-1:fixture-notranscript"
OUT=$(FC_PLAN="143 143 0" drive FC_TRANSCRIPT=0)
[ "$(calls)" = 3 ] && ok || bad "3a rc 143 did not relaunch once (calls $(calls); $OUT)"
grep -q -- '--session-id' "$FC/argv.2" 2>/dev/null && ok || bad "3b call 2 had no session id, so the case proves nothing: $(cat "$FC/argv.2" 2>/dev/null)"
grep -q -- '--resume' "$FC/argv.3" 2>/dev/null && bad "3c --resume with no transcript on this box: $(cat "$FC/argv.3")" || ok
B3=$(grep '^Last commit: ' "$BUILD/checkpoint-brief.md" 2>/dev/null)
[ -n "$B3" ] && grep -qF "$B3" "$FC/prompt.3" 2>/dev/null && grep -qF 'DO NOT START OVER FROM THE PLAN' "$FC/prompt.3" \
  && ok || bad "3d the brief '$B3' is not in call 3's resume prompt"

# --- 4. three timeouts: the cap parks; the next build makes 0 calls ------------
fresh "FX-1:fixture-cap"
OUT=$(FC_PLAN="124 124 124 124" drive)
[ "$(calls)" = 3 ] && ok || bad "4a want 3 calls at the cap, got $(calls)"
grep -q '^3 EXECUTE_EMPTY parked: attempts=3 fp=FX-1:fixture-cap checkpoint=ticket/fx-1@[0-9a-f]\{12\}$' <<<"$OUT" \
  && ok || bad "4b want the parked RESULT, got: $OUT"
[ "$(row "$FP" | cut -d' ' -f1-2)" = "parked 3" ] && ok || bad "4c ledger row '$(row "$FP")', want parked 3"
# The next build of the same fp: the ledger refuses, 0 claude calls, parked again.
WT_KEEP=$WT; BUILD="$T/build-next$N"; FC="$T/fc-next$N"; mkdir -p "$BUILD" "$FC"; cp "$T/build$N/plan.md" "$BUILD/"
OUT=$(FC_PLAN="0" drive)
[ "$(calls)" = 0 ] && ok || bad "4d the next build made $(calls) claude calls, want 0"
grep -q '^3 EXECUTE_EMPTY parked: attempts=3 fp=FX-1:fixture-cap ' <<<"$OUT" && ok || bad "4e the next build did not park: $OUT"

# --- 5. a failed row at the cap from earlier builds: 0 calls, parked ----------
fresh "FX-1:fixture-ledgercap"
seed "$FP" failed 3 124
OUT=$(FC_PLAN="0" drive)
[ "$(calls)" = 0 ] && ok || bad "5a a failed row at the cap made $(calls) claude calls"
grep -q '^3 EXECUTE_EMPTY parked: attempts=3 fp=FX-1:fixture-ledgercap checkpoint=ticket/fx-1@' <<<"$OUT" && ok || bad "5b want parked, got: $OUT"
[ "$(row "$FP" | cut -d' ' -f1)" = parked ] && ok || bad "5c the row was not parked: $(row "$FP")"

# --- 6. rc 1 does not relaunch -------------------------------------------------
fresh "FX-1:fixture-rc1"
OUT=$(FC_PLAN="1 0" drive)
[ "$(calls)" = 1 ] && ok || bad "6a rc 1 relaunched ($(calls) calls)"
grep -q 'parked' <<<"$OUT" && bad "6b rc 1 parked: $OUT" || ok
[ ! -f "$BUILD/checkpoint-brief.md" ] && ok || bad "6c rc 1 wrote a brief"

# --- 7. a no-progress stop does not relaunch (BH-8868 owns it) ----------------
# A claude wrapper leaves the marker agent-call's meter would leave.
fresh "FX-1:fixture-noprogress"
mkdir -p "$T/npbin"
{ echo '#!/bin/bash'
  echo "case \" \$* \" in *\" -p \"*) printf 'rule=time elapsed_s=9 total=1 ceiling=2\\n' > '$BUILD/execute-run.txt.noprogress' ;; esac"
  echo "exec '$T/fakebin/claude' \"\$@\""; } > "$T/npbin/claude"
chmod +x "$T/npbin/claude"
OUT=$(FC_PLAN="124 0" drive PATH="$T/npbin:$T/fakebin:$PATH")
[ "$(calls)" = 1 ] && ok || bad "7a a .noprogress stop relaunched ($(calls) calls; $OUT)"
[ -f "$BUILD/execute-run.txt.noprogress" ] && ok || bad "7b the wrapper left no .noprogress marker, so the case proves nothing"
[ ! -f "$BUILD/checkpoint-brief.md" ] && ok || bad "7c a .noprogress stop wrote a brief"

# --- 7d. a context kill ($OUT.ctxkill) relaunches, whatever rc it ended with --
# A claude wrapper leaves the marker agent-call's context meter leaves, on the
# first call only, and that call ends rc 2.
fresh "FX-1:fixture-ctxkill"
mkdir -p "$T/ckbin"
{ echo '#!/bin/bash'
  echo "[ -s '$FC/n' ] || case \" \$* \" in *\" -p \"*) printf 'ceiling=5 total=6 calls=1 session=x\\n' > '$BUILD/execute-run.txt.ctxkill' ;; esac"
  echo "exec '$T/fakebin/claude' \"\$@\""; } > "$T/ckbin/claude"
chmod +x "$T/ckbin/claude"
OUT=$(FC_PLAN="2 0" drive FC_TRANSCRIPT=1 PATH="$T/ckbin:$T/fakebin:$PATH")
[ "$(calls)" = 2 ] && ok || bad "7d a context kill did not relaunch once ($(calls) calls; $OUT)"
[ -f "$BUILD/execute-run.txt.ctxkill.1" ] && [ ! -f "$BUILD/execute-run.txt.ctxkill" ] && ok || bad "7e the kill marker was not set aside for the next call"
grep -qF 'DO NOT START OVER FROM THE PLAN' "$FC/prompt.2" 2>/dev/null && ok || bad "7f the relaunch after a context kill is not the resume prompt"
# The transcript is on this box (FC_TRANSCRIPT=1), and still no --resume: the
# killed session's context would be killed again at the first poll.
grep -q -- '--session-id' "$FC/argv.1" 2>/dev/null && ok || bad "7g call 1 had no session id, so 7h proves nothing: $(cat "$FC/argv.1" 2>/dev/null)"
grep -q -- '--resume' "$FC/argv.2" 2>/dev/null && bad "7h the relaunch after a context kill resumed the killed session: $(cat "$FC/argv.2")" || ok
grep -q 'continue from checkpoint .* with --resume' "$BUILD/pipeline.log" 2>/dev/null && bad "7i pipeline.log says --resume after a context kill" || ok

# --- 8a. a running row (another build holds the work): deferred, no relaunch -
fresh "FX-1:fixture-running"
seed "$FP" running 1 null
OUT=$(FC_PLAN="0" drive)
[ "$(calls)" = 0 ] && grep -q '^3 BUILD_DEFERRED execute refused by the call-guard: AGENT_CALL_REFUSED call-guard repeat ledger-running ' <<<"$OUT" \
  && [ ! -f "$BUILD/checkpoint-brief.md" ] && ok || bad "8a a running row: want 0 calls and BUILD_DEFERRED, got calls $(calls), out $OUT"

# --- 8b. no execute-resume template on the box: no relaunch, one log line ----
fresh "FX-1:fixture-notemplate"
mkdir -p "$T/stages-no-resume"; cp "$DIR/prompts/stages/"*.md "$T/stages-no-resume/"; rm -f "$T/stages-no-resume/execute-resume.md"
OUT=$(FC_PLAN="124 0" drive SP_STAGES_DIR="$T/stages-no-resume")
[ "$(calls)" = 1 ] && [ "$(grep -c 'EXECUTE resume: no execute-resume prompt' "$BUILD/pipeline.log" 2>/dev/null)" = 1 ] \
  && ok || bad "8b no template: want 1 call and 1 log line, got calls $(calls), log: $(grep 'EXECUTE' "$BUILD/pipeline.log" 2>/dev/null)"

# --- 9. K3 refuses the call (it runs before the ledger on main) ---------------
# 9a-9b: inside a checkpoint chain (a relaunch in this build) the K3 refusal
# parks. K3 execute=1 refuses the relaunch; the ledger cap stays 3.
fresh "FX-1:fixture-k3chain"
OUT=$(FC_PLAN="124 0" drive CALL_GUARD_MAX_MAP="execute=1 default=50")
[ "$(calls)" = 1 ] && ok || bad "9a want 1 vendor call (the relaunch refused by K3), got $(calls) ($OUT)"
grep -q '^3 EXECUTE_EMPTY parked: attempts=1 fp=FX-1:fixture-k3chain checkpoint=ticket/fx-1@[0-9a-f]\{12\}$' <<<"$OUT" \
  && [ "$(row "$FP" | cut -d' ' -f1)" = parked ] && ok || bad "9b a K3 refusal in a chain: want parked, got: $OUT (row $(row "$FP"))"
# 9c: outside a chain (a new build, no checkpoint on the row) it stays BH-2305's deferral.
fresh "FX-1:fixture-k3nochain"
OUT=$(FC_PLAN="0" drive CALL_GUARD_MAX_MAP="execute=1 default=50")
FC="$T/fc-k3next$N"; BUILD="$T/build-k3next$N"; mkdir -p "$FC" "$BUILD"; cp "$T/build$N/plan.md" "$BUILD/"
OUT=$(FC_PLAN="0" drive CALL_GUARD_MAX_MAP="execute=1 default=50")
[ "$(calls)" = 0 ] && grep -q '^3 BUILD_DEFERRED execute refused by the call-guard: AGENT_CALL_REFUSED call-guard repeat execute paid=1/1 ' <<<"$OUT" \
  && [ ! -f "$BUILD/checkpoint-brief.md" ] && ok || bad "9c a K3 refusal outside a chain: want BUILD_DEFERRED and no brief, got calls $(calls), out $OUT"

# --- 10. a new build whose ledger row has a checkpoint starts from the brief ---
fresh "FX-1:fixture-newbuild"
seed "$FP" failed 1 124 "ticket/fx-1@abcdef012345 session=sid-fixture-old"
OUT=$(FC_PLAN="0" drive)
[ "$(calls)" = 1 ] && ok || bad "10a want 1 call, got $(calls) ($OUT)"
grep -qF 'DO NOT START OVER FROM THE PLAN' "$FC/prompt.1" 2>/dev/null && ok || bad "10b the first call of the new build is not the resume prompt"
grep -qF 'Execute the plan at' "$FC/prompt.1" 2>/dev/null && bad "10c the new build got the fresh plan prompt" || ok
grep -q '^Last commit: ' "$FC/prompt.1" 2>/dev/null && ok || bad "10d the brief is not in the first prompt"
# Contrast: the same build shape with no checkpoint on the row gets the plan prompt.
fresh "FX-1:fixture-newbuild-none"
seed "$FP" failed 1 124
OUT=$(FC_PLAN="0" drive)
grep -qF 'Execute the plan at' "$FC/prompt.1" 2>/dev/null && ok || bad "10e a row with no checkpoint must get the plan prompt"

# --- 11. ledger off: rc 0 is byte-identical to before (no brief, no relaunch) ---
fresh "FX-1:fixture-off"
OUT=$(FC_PLAN="0" drive AGENT_LEDGER=0)
[ "$(calls)" = 1 ] && [ ! -f "$BUILD/checkpoint-brief.md" ] && [ "${OUT%% *}" = 0 ] && ok || bad "11a ledger off, rc 0: calls $(calls), out $OUT"

# --- 11b. ledger off: the build's own cap still parks after 3 calls ----------
fresh "FX-1:fixture-off-cap"
OUT=$(FC_PLAN="124 124 124 124 124" drive AGENT_LEDGER=0)
[ "$(calls)" = 3 ] && ok || bad "11b want 3 calls at the build cap with the ledger off, got $(calls)"
grep -q '^3 EXECUTE_EMPTY parked: attempts=3 fp=FX-1:fixture-off-cap checkpoint=ticket/fx-1@' <<<"$OUT" && ok || bad "11c want parked with the ledger off, got: $OUT"
[ -z "$(row "$FP")" ] && ok || bad "11d the ledger off still wrote a row: $(row "$FP")"

# --- 12. ee_stop_check routes the parked RESULT as EXECUTE_EMPTY --------------
EH="$T/eeh"; mkdir -p "$EH/builds/pool-fixproj-FX-1-a" "$EH/builds/pool-fixproj-FX-1-b" "$EH/builds/pool-fixproj-FX-2-a" "$EH/builds/pool-fixproj-FX-2-b"
for d in a b; do
  echo "EXECUTE_EMPTY parked: attempts=3 fp=FX-1:fixture-ee checkpoint=ticket/fx-1@abcdef012345" > "$EH/builds/pool-fixproj-FX-1-$d/RESULT"
  echo "BUILD_DEFERRED fixture" > "$EH/builds/pool-fixproj-FX-2-$d/RESULT"
done
EE=$(HARNESS="$EH" bash -c '. "$1"; ee_stop_check fixproj FX-1 1; echo "p=$?"; ee_stop_check fixproj FX-2 2; echo "d=$?"' _ "$DIR/bin/lib/execute-empty.sh" 2>/dev/null)
grep -q '^p=1$' <<<"$EE" && ok || bad "12a ee_stop_check did not count two parked RESULTs as EXECUTE_EMPTY ($EE)"
grep -q '^d=0$' <<<"$EE" && ok || bad "12b the contrast key was refused ($EE)"

echo "execute-resume.bh-9123: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
