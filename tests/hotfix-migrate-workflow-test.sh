#!/bin/bash
# tests/hotfix-migrate-workflow-test.sh — the hotfix go-live stage, WORKFLOW
# shape (BH-370.3): bin/lib/hotfix-migrate-workflow.sh.
#
# WHY THIS TEST EXISTS. The endpoint shape asks an app to apply its own SQL. The
# workflow shape does something heavier: it DISPATCHES a GitHub Actions workflow
# that holds the database credential, so a dispatch this stage sends is a
# production write we cannot take back. Everything interesting here is therefore
# a refusal: a needs-quiet answer nobody could read, a quiet probe that never
# reached zero, a probe that is not configured at all, a red check, a run that
# was already dispatched for this fingerprint. The proof in every one of those
# cases is $T/dispatch.log — the literal list of `gh workflow run` argv lines
# that left the box. An empty dispatch.log IS the assertion.
#
# The second half of the file is about honesty after the dispatch: a nonzero
# `gh run watch` keeps its real status word, our own timeout is recorded as a
# re-attachable in-flight run (never as applied), and a proof that failed to
# post leaves posted_comment_id null with rc 3.
#
# Everything runs against a scratch $HARNESS with stub `gh`, `node` and `probe`
# binaries on PATH; the real bin/hotfix-migrate.sh drives the real lib end to
# end, so deleting the `case "$MODE" in workflow)` call site fails this suite.
#
# Run from anywhere (as root, next to a live harness, prefix the run with
# HARNESS_TEST_SANDBOX=1 — scratch.sh's guard):
#   HARNESS_TEST_SANDBOX=1 bash tests/hotfix-migrate-workflow-test.sh
# exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/hotfix-migrate-workflow.sh"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/env" "$T/h/builds" "$T/fakebin"
cp "$DIR/bin/hotfix-migrate.sh" "$DIR/bin/check-migration-appliable.sh" "$T/h/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-ci-read.sh" "$DIR/bin/lib/gh-app-auth.sh" \
   "$T/h/bin/lib/"
[ -f "$LIB" ] && cp "$LIB" "$T/h/bin/lib/"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/gh-token.sh"; chmod +x "$T/h/bin/gh-token.sh"
: > "$T/h/env/global.env"
: > "$T/h/env/x-os.env"

# ---------------------------------------------------------------------------
# stubs. gh records EVERY argv line; `workflow run` additionally lands in its own
# dispatch.log, which is the file every "nothing was dispatched" case reads.
# `run view --json ... -q <expr>` applies the PRODUCTION jq expression with real
# jq to the fixture, so what is under test is the expression the lib ships.
# ---------------------------------------------------------------------------
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
printf '%s\t%s\n' "\${GH_TOKEN:-unset}" "\$*" >> "$T/gh-tok.log"
case "\$*" in
  "api repos/"*"/issues/"*"/comments"*)
    for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$T/comment.md" ;; esac; done
    if [ -f "$T/comment.fail" ]; then echo "gh: could not post" >&2; exit 1; fi
    echo 4242; exit 0 ;;
  "api repos/"*"/actions/runs"*) echo '{"workflow_runs":[]}'; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
  "pr checks"*)
    cat "$T/checks.out" 2>/dev/null
    exit "\$(cat "$T/checks.rc" 2>/dev/null || echo 1)" ;;
  "pr list"*) echo "https://github.com/o/p/pull/9"; exit 0 ;;
  "workflow run"*)
    printf '%s\n' "\$*" >> "$T/dispatch.log"
    exit "\$(cat "$T/dispatch.rc" 2>/dev/null || echo 0)" ;;
  "run list"*)
    # A dispatched run exists only AFTER its dispatch, as on GitHub: before the
    # first \`workflow run\` of the case the list holds only the runs that
    # predate it (the 2000-01-01 neighbours). The lib reads this list once
    # before its dispatch (BH-9403: a run listed then is never ours).
    if [ -s "$T/dispatch.log" ]; then cat "$T/runs.json" 2>/dev/null || echo '[]'
    else jq -c '[.[] | select(.createdAt < "2099")]' "$T/runs.json" 2>/dev/null || echo '[]'; fi
    exit 0 ;;
  "run watch"*)
    # a run that never settles, so the lib's own \`timeout\` (rc 124) is real
    [ -f "$T/watch.hang" ] && exec sleep infinity
    exit "\$(cat "$T/watch.rc" 2>/dev/null || echo 0)" ;;
  *"--log"*)
    if [ -f "$T/log.huge" ]; then
      pad=\$(printf '%400s' '' | tr ' ' x)
      i=1; while [ "\$i" -le 80 ]; do echo "line \$i \$pad"; i=\$((i+1)); done
    else
      i=1; while [ "\$i" -le 80 ]; do echo "line \$i"; i=\$((i+1)); done
    fi
    [ -f "$T/log.fail" ] && exit 1
    exit 0 ;;
  "run view"*)
    q=""; prev=""
    for a in "\$@"; do [ "\$prev" = "-q" ] && q="\$a"; prev="\$a"; done
    [ -n "\$q" ] || q=.
    jq -r "\$q" "$T/view.json" 2>/dev/null
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# HOTFIX_NEEDS_QUIET_CMD's default is `node scripts/migration-sql.mjs
# --needs-quiet <file>`, so the needs-quiet answer is a node stub: per file from
# $T/nq-<basename>, default `no`, rc from $T/nq.rc.
cat > "$T/fakebin/node" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/nq.calls"
f=\$(basename "\${!#}")
cat "$T/nq-\$f" 2>/dev/null || echo no
exit "\$(cat "$T/nq.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/fakebin/node"

# the quiet probe: pops one line off $T/probe.seq per call. No seq file at all is
# the "nobody could read it" shape: rc 1, no output.
cat > "$T/fakebin/probe" <<EOF
#!/bin/bash
printf 'probe\n' >> "$T/probe.calls"
[ -s "$T/probe.seq" ] || exit 1
line=\$(head -n1 "$T/probe.seq")
tail -n +2 "$T/probe.seq" > "$T/probe.next"; mv "$T/probe.next" "$T/probe.seq"
printf '%s\n' "\$line"
exit "\$(cat "$T/probe.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/fakebin/probe"

# ---------------------------------------------------------------------------
# a scratch repo that looks like a workflow project's worktree
# ---------------------------------------------------------------------------
mkwt() { # mkwt <dir> <branch>   (leaves the branch checked out, origin = o/p)
  local d="$1" b="$2"
  git init -q -b main "$d" 2>/dev/null
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo readme > "$d/README.md"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm init
  git -C "$d" remote add origin https://github.com/o/p.git
  git -C "$d" checkout -q -b "$b"
  mkdir -p "$d/prisma/migrations/manual"
}
commit_wt() { git -C "$1" add -A >/dev/null; git -C "$1" commit -qm sql; }

WT="$T/wt"; mkwt "$WT" ticket/x
cat > "$WT/prisma/migrations/manual/2026-09-15-a.sql" <<'SQL'
CREATE TABLE "Alpha" ("id" TEXT NOT NULL);
ALTER TABLE "Alpha" ENABLE ROW LEVEL SECURITY;
SQL
cat > "$WT/prisma/migrations/manual/2026-09-15-b.sql" <<'SQL'
CREATE TABLE "Beta" ("id" TEXT NOT NULL);
ALTER TABLE "Beta" ENABLE ROW LEVEL SECURITY;
SQL
commit_wt "$WT"
A=prisma/migrations/manual/2026-09-15-a.sql
B=prisma/migrations/manual/2026-09-15-b.sql

# the data-edit worktree: a 0-row guarded UPDATE with its own revert line. The
# appliability gate flags it BEFORE the mode dispatch, which is the point — a
# data edit never reaches a dispatch, and the revert line still rides in the proof.
WTR="$T/wt-revert"; mkwt "$WTR" ticket/x
cat > "$WTR/prisma/migrations/manual/2026-09-15-a.sql" <<'SQL'
-- revert: UPDATE t SET x=1 WHERE id=7;
UPDATE t SET x=2 WHERE id=7;
SQL
commit_wt "$WTR"

# the awkward-name worktree: one migration whose FILENAME is a command
# substitution. git keeps the name, `git diff --name-only` hands it over intact,
# and nothing downstream may ever let a shell look at it.
WTE="$T/wt-evil"; mkwt "$WTE" ticket/x
EVIL='prisma/migrations/manual/2026-09-15-c$(touch pwned).sql'
{ echo 'CREATE TABLE "Gamma" ("id" TEXT NOT NULL);'
  echo 'ALTER TABLE "Gamma" ENABLE ROW LEVEL SECURITY;'; } > "$WTE/$EVIL"
commit_wt "$WTE"

BX="$T/h/builds/x-os-BH-9-202609150001"; mkdir -p "$BX"

reset() {
  : > "$T/gh.log"; : > "$T/dispatch.log"; : > "$T/gh-tok.log"
  rm -f "$T/comment.md" "$T/comment.fail" "$T/nq.calls" "$T/probe.calls" \
        "$T/probe.seq" "$T/probe.rc" "$T/nq.rc" "$T/watch.hang" "$T/watch.rc" \
        "$T/dispatch.rc" "$T/log.fail" "$T/log.huge" \
        "$T/nq-2026-09-15-a.sql" "$T/nq-2026-09-15-b.sql"
  rm -f "$BX/hotfix-migrate.json" "$BX/hotfix-dispatch.txt" "$BX/hotfix-run-watch.txt" \
        "$BX/hotfix-run-log.txt" "$BX/hotfix-quiet.err" "$BX/hotfix-checks.txt"
  rm -rf "$T/h/locks"; mkdir -p "$T/h/locks"
  echo 0 > "$T/checks.rc"; printf 'build\tpass\t1s\n' > "$T/checks.out"
  # the freshly dispatched run is 777; 111 is the stale neighbour that must never
  # be mistaken for ours. Fixed timestamps: this suite never reads the clock.
  printf '%s\n' '[{"databaseId":777,"createdAt":"2099-01-01T00:00:00Z","status":"completed"},
   {"databaseId":111,"createdAt":"2000-01-01T00:00:00Z","status":"completed"}]' > "$T/runs.json"
  printf '%s\n' '{"status":"completed","conclusion":"success"}' > "$T/view.json"
}

run_hm() { # run_hm <worktree> [VAR=VAL ...] -> prints rc
  local w="$1"; shift
  ( cd "$T" && PATH="$T/fakebin:$PATH" env HARNESS="$T/h" WT="$w" BASE=main SLUG=o/p \
      BRANCH=ticket/x PR_URL=https://github.com/o/p/pull/9 HOTFIX_CI_WAIT=2 \
      HOTFIX_MIGRATE_MODE=workflow HOTFIX_QUIET_PROBE_CMD=probe \
      HOTFIX_QUIET_MAX_WAIT=0 HOTFIX_QUIET_POLL=0 HOTFIX_RUN_WAIT=5 \
      HOTFIX_RUN_LOCATE_WAIT=0 \
      "$@" bash "$T/h/bin/hotfix-migrate.sh" x-os "$BX" > "$T/hm.out" 2> "$T/hm.err" )
  echo $?
}
marker()    { head -n1 "$T/comment.md" 2>/dev/null; }
ndispatch() { local n; n=$(grep -c . "$T/dispatch.log" 2>/dev/null); echo "${n:-0}"; }
led()       { jq -r "$1" "$BX/hotfix-migrate.json" 2>/dev/null; }

# ===========================================================================
# 0. the file under test
# ===========================================================================
[ -f "$LIB" ] && ok || bad "0: bin/lib/hotfix-migrate-workflow.sh must exist"

# ===========================================================================
# 1. the happy path: checks green, no file needs a quiet window, one dispatch,
#    the run located and watched green, one proof, one ledger
# ===========================================================================
reset
RC=$(run_hm "$WT")
[ "$RC" = 0 ] || bad "1: a green run must exit 0 (got $RC; $(head -c 300 "$T/hm.err"))"
[ "$RC" = 0 ] && ok
printf 'workflow run migrate-manual.yml -R o/p --ref ticket/x -f files=%s,%s\n' "$A" "$B" > "$T/want-dispatch"
diff -q "$T/want-dispatch" "$T/dispatch.log" >/dev/null 2>&1 && ok \
  || bad "1: the dispatch argv must be exactly the contract's (got: $(tr '\n' ' ' < "$T/dispatch.log"))"
FP=$(led .fp)
[ -n "$FP" ] && [ "$FP" != null ] && ok || bad "1: the ledger must carry a fingerprint"
[ "$(marker)" = "<!-- hotfix-migrate-proof fp=$FP decision=applied -->" ] && ok \
  || bad "1: comment line 1 must be the proof marker with decision=applied (got '$(marker)')"
grep -q 'https://github.com/o/p/actions/runs/777' "$T/comment.md" && ok \
  || bad "1: the proof must carry the run URL built from the id gh returned"
grep -q '(last 60 lines)' "$T/comment.md" && ok || bad "1: the proof must say the log is the last 60 lines"
grep -q '^line 21$' "$T/comment.md" && ok || bad "1: the proof must carry the tail of the run log"
grep -q '^line 20$' "$T/comment.md" && bad "1: the log tail is 60 lines, so line 20 must not be in it" || ok
[ "$(grep -c ': quiet window: not needed' "$T/comment.md")" = 2 ] && ok \
  || bad "1: one quiet-window line per file (got $(grep -c 'quiet window' "$T/comment.md"))"
grep -q "$A: applied (run 777)" "$T/comment.md" && ok || bad "1: the proof must name each file's result and run"
[ "$(led .mode)" = workflow ] && ok || bad "1: ledger mode must be workflow (got '$(led .mode)')"
[ "$(led .decision)" = applied ] && ok || bad "1: ledger decision must be applied (got '$(led .decision)')"
[ "$(led '[.files[].run_id]|unique|join(",")')" = 777 ] && ok \
  || bad "1: every ledger file must carry the run id (got '$(led '[.files[].run_id]|join(",")')')"
[ "$(led '[.files[].status]|unique|join(",")')" = applied ] && ok || bad "1: both files must be recorded applied"
[ "$(led .posted_comment_id)" = 4242 ] && ok || bad "1: the ledger must be rewritten with the posted comment id"
[ "$(led .after_deploy)" = null ] && ok || bad "1: after_deploy belongs to BH-370.4 — null here"
grep -q 'run watch 777' "$T/gh.log" && ok || bad "1: the located run must be watched"
grep -q 'pr merge\|pr close\|pr edit' "$T/gh.log" && bad "1: this stage must never act on the PR" || ok

# ===========================================================================
# 2. a quiet window that never became readable: no dispatch
# ===========================================================================
reset
echo yes > "$T/nq-2026-09-15-a.sql"
RC=$(run_hm "$WT")                    # no probe.seq: the probe exits 1, says nothing
[ "$RC" = 3 ] && ok || bad "2: an unreadable probe must hold, exit 3 (got $RC)"
[ "$(ndispatch)" = 0 ] && ok || bad "2: an unreadable probe must dispatch nothing (got $(ndispatch))"
grep -q 'decision=hold' <<<"$(marker)" && ok || bad "2: marker must say decision=hold (got '$(marker)')"
grep -q 'read error' "$T/comment.md" && ok || bad "2: the proof must say the probe could not be read"
[ "$(led '[.files[]|select(has("run_id"))]|length')" = 0 ] && ok || bad "2: a run that never happened has no run_id"
[ -s "$BX/hotfix-quiet.err" ] && ok || bad "2: the probe's own stderr must land in \$BUILD/hotfix-quiet.err"

# ===========================================================================
# 3. exactly `0` is zero, and nothing else is
# ===========================================================================
reset; echo yes > "$T/nq-2026-09-15-a.sql"; printf '0\n' > "$T/probe.seq"
RC=$(run_hm "$WT")
[ "$RC" = 0 ] && ok || bad "3a: a probe that printed 0 must let the dispatch happen (got $RC)"
[ "$(ndispatch)" = 1 ] && ok || bad "3a: exactly one dispatch (got $(ndispatch))"
grep -Eq "$A: quiet window: waited [0-9]+s, active=0" "$T/comment.md" && ok \
  || bad "3a: the waiting file's proof line must say how long we waited"
grep -q "$B: quiet window: not needed" "$T/comment.md" && ok \
  || bad "3b: the file that did not need a quiet window says so on its own line"

for BADZERO in 2 00 '0 scans' ' 0' -1 ''; do
  reset; echo yes > "$T/nq-2026-09-15-a.sql"; printf '%s\n' "$BADZERO" > "$T/probe.seq"
  RC=$(run_hm "$WT")
  [ "$RC" = 3 ] && ok || bad "3: probe output '$BADZERO' is not zero — must hold (got $RC)"
  [ "$(ndispatch)" = 0 ] && ok || bad "3: probe output '$BADZERO' must dispatch nothing (got $(ndispatch))"
done
reset; echo yes > "$T/nq-2026-09-15-a.sql"; printf '2\n' > "$T/probe.seq"
RC=$(run_hm "$WT")
grep -q 'quiet window not reached in 0s; last probe: active=2' "$T/comment.md" && ok \
  || bad "3: the hold must quote the last probe it read"
grep -q "$A: quiet window: HOLD:" "$T/comment.md" && ok \
  || bad "3: the waiting file's own line must say it held"
# the loop really re-probes: 2 first, then 0
reset; echo yes > "$T/nq-2026-09-15-a.sql"; printf '2\n0\n' > "$T/probe.seq"
RC=$(run_hm "$WT" HOTFIX_QUIET_MAX_WAIT=5)
[ "$RC" = 0 ] && ok || bad "3e: the probe loop must re-read until the window opens (got $RC)"
[ "$(ndispatch)" = 1 ] && ok || bad "3e: one dispatch after the window opened (got $(ndispatch))"
[ "$(grep -c . "$T/probe.calls")" = 2 ] && ok || bad "3e: the probe must have been called twice"
# rc beats stdout: a probe that printed 0 and failed is a read error
reset; echo yes > "$T/nq-2026-09-15-a.sql"; printf '0\n' > "$T/probe.seq"; echo 1 > "$T/probe.rc"
RC=$(run_hm "$WT")
[ "$RC" = 3 ] && ok || bad "3f: a nonzero probe exit is a read error even when it printed 0 (got $RC)"
[ "$(ndispatch)" = 0 ] && ok || bad "3f: a failed probe must dispatch nothing (got $(ndispatch))"

# ===========================================================================
# 4. a quiet window is needed and no probe is configured
# ===========================================================================
reset; echo yes > "$T/nq-2026-09-15-a.sql"
RC=$(run_hm "$WT" HOTFIX_QUIET_PROBE_CMD=)
[ "$RC" = 3 ] && ok || bad "4: no probe + a file that needs quiet must hold (got $RC)"
[ "$(ndispatch)" = 0 ] && ok || bad "4: an unconfigured probe must dispatch nothing (got $(ndispatch))"
grep -q 'probe not configured' "$T/comment.md" && ok || bad "4: the proof must name the missing knob"
[ -f "$T/probe.calls" ] && bad "4: nothing may call the probe when none is configured" || ok
# the negative: nobody needs a quiet window, so the missing probe is irrelevant
reset
RC=$(run_hm "$WT" HOTFIX_QUIET_PROBE_CMD=)
[ "$RC" = 0 ] && ok || bad "4: with no file needing quiet, an unset probe must not hold (got $RC)"
[ "$(ndispatch)" = 1 ] && ok || bad "4: that run must still dispatch (got $(ndispatch))"

# ===========================================================================
# 5. dedupe before spend: a run already paid for is watched, never re-dispatched
# ===========================================================================
reset
RC=$(run_hm "$WT"); FP=$(led .fp)          # a real fingerprint for this SQL
reset
jq -n --arg fp "$FP" --arg a "$A" --arg b "$B" \
  '{fp:$fp,mode:"workflow",decision:"hold",
    files:[{path:$a,status:"in_progress",run_id:"777"},{path:$b,status:"in_progress",run_id:"777"}],
    posted_comment_id:null,after_deploy:null}' > "$BX/hotfix-migrate.json"
RC=$(run_hm "$WT")
[ "$(ndispatch)" = 0 ] && ok || bad "5: an in-flight run for this fingerprint must not be dispatched again (got $(ndispatch))"
grep -q 'run watch 777' "$T/gh.log" && ok || bad "5: the in-flight run must be re-attached and watched"
[ "$RC" = 0 ] && ok || bad "5: a re-attached run that finished green exits 0 (got $RC)"
[ "$(led .decision)" = applied ] && ok || bad "5: the re-attached green run is applied (got '$(led .decision)')"
# A ledger word that is NOT a terminal failure still names a run we already paid
# for. Step 7 writes such words whenever the watch itself misfired: a transient
# `gh run watch` error after the run went green records the view's own word
# (`success`, `completed`), and a watch AND a view that both failed record
# `exit <rc>`. Falling through any of those dispatches the same migration twice.
led_run() { # led_run <status word> — a ledger for THIS fp carrying run 777
  jq -n --arg fp "$FP" --arg a "$A" --arg b "$B" --arg s "$1" \
    '{fp:$fp,mode:"workflow",decision:"hold",
      files:[{path:$a,status:$s,run_id:"777"},{path:$b,status:$s,run_id:"777"}],
      posted_comment_id:null,after_deploy:null}' > "$BX/hotfix-migrate.json"
}
for LST in success completed 'exit 1' 'exit 124'; do
  reset; led_run "$LST"
  RC=$(run_hm "$WT")
  [ "$(ndispatch)" = 0 ] && ok \
    || bad "5: ledger status '$LST' carries run 777 — a second dispatch is a second apply (got $(ndispatch))"
  grep -q 'run watch 777' "$T/gh.log" && ok || bad "5: ledger status '$LST' must re-attach to run 777"
done
# The inverse, so the re-attach is not a blanket never-dispatch: a run GitHub
# itself finished badly is honestly dispatched again.
for LST in failure cancelled timed_out startup_failure action_required dispatch-failed; do
  reset; led_run "$LST"
  RC=$(run_hm "$WT")
  [ "$(ndispatch)" = 1 ] && ok \
    || bad "5: terminal ledger status '$LST' must be dispatched again, once (got $(ndispatch))"
done
# a ledger for DIFFERENT SQL is not our proof
reset
jq -n --arg a "$A" '{fp:"deadbeef",mode:"workflow",decision:"applied",
  files:[{path:$a,status:"applied",run_id:"777"}],posted_comment_id:1,after_deploy:null}' \
  > "$BX/hotfix-migrate.json"
RC=$(run_hm "$WT")
[ "$(ndispatch)" = 1 ] && ok || bad "5: a ledger for another fingerprint must not suppress this dispatch (got $(ndispatch))"
# and the lib's own applied-ledger short circuit, called directly (hm_main's
# idempotence block normally catches this first — the rule must hold anyway)
reset
jq -n --arg fp "$FP" --arg a "$A" '{fp:$fp,mode:"workflow",decision:"applied",
  files:[{path:$a,status:"applied",run_id:"777"}],posted_comment_id:1,after_deploy:null}' \
  > "$BX/hotfix-migrate.json"
WRC=0
# The stage seeds PROJECT/BUILD/FP/FILES/LEDGER/MODE to empty at source time, so
# this sets them the way hm_main does — after sourcing, before the call.
( cd "$T" && PATH="$T/fakebin:$PATH" HM_SOURCE_ONLY=1 HARNESS="$T/h" \
    SLUG=o/p PR_URL=https://github.com/o/p/pull/9 BRANCH=ticket/x WT="$WT" \
    HM_T_BUILD="$BX" HM_T_FP="$FP" HM_T_LEDGER="$BX/hotfix-migrate.json" \
    bash -c '. "$0"
      PROJECT=x-os; BUILD="$HM_T_BUILD"; FP="$HM_T_FP"; LEDGER="$HM_T_LEDGER"
      MODE=workflow; FILES=("$1" "$2"); hm_workflow' \
      "$T/h/bin/hotfix-migrate.sh" "$A" "$B" > "$T/direct.out" 2>&1 ) || WRC=$?
[ "$WRC" = 0 ] && ok || bad "5: hm_workflow on an applied ledger must return 0 (got $WRC; $(head -c 200 "$T/direct.out"))"
[ "$(ndispatch)" = 0 ] && ok || bad "5: hm_workflow must dispatch nothing for an applied ledger (got $(ndispatch))"
grep -q "$FP" "$T/direct.out" && ok || bad "5: hm_workflow must print the ledger it is standing on"

# ===========================================================================
# 6. the run's own answer decides — never a blanket success
# ===========================================================================
reset; echo 1 > "$T/watch.rc"
printf '%s\n' '{"status":"completed","conclusion":"failure"}' > "$T/view.json"
RC=$(run_hm "$WT")
[ "$RC" = 3 ] && ok || bad "6a: a failed run must hold, exit 3 (got $RC)"
grep -q 'decision=hold' <<<"$(marker)" && ok || bad "6a: marker must say decision=hold (got '$(marker)')"
grep -q 'failure' "$T/comment.md" && ok || bad "6a: the proof must carry the run's real conclusion"
[ "$(led '[.files[].status]|unique|join(",")')" = failure ] && ok \
  || bad "6a: the ledger must record the real word (got '$(led '[.files[].status]|join(",")')')"
[ "$(led '[.files[].run_id]|unique|join(",")')" = 777 ] && ok || bad "6a: a failed run keeps its id in the ledger"
# our own timeout: in flight, re-attachable, never applied
reset; touch "$T/watch.hang"
printf '%s\n' '{"status":"in_progress","conclusion":null}' > "$T/view.json"
RC=$(run_hm "$WT" HOTFIX_RUN_WAIT=1)
[ "$RC" = 3 ] && ok || bad "6b: a watch that hit our deadline must hold (got $RC)"
grep -q 'watch timed out after 1s' "$T/comment.md" && ok || bad "6b: the proof must say the watch timed out"
[ "$(led '[.files[].status]|unique|join(",")')" = in_progress ] && ok \
  || bad "6b: the ledger must record the run as still in flight (got '$(led '[.files[].status]|join(",")')')"
[ "$(led .decision)" = hold ] && ok || bad "6b: an unfinished run is never applied"

# ===========================================================================
# 7. the files input knob
# ===========================================================================
reset
RC=$(run_hm "$WT" HOTFIX_WORKFLOW_FILES_INPUT=)
grep -q -- '-f' "$T/dispatch.log" && bad "7: an empty files input must pass no -f (got: $(cat "$T/dispatch.log"))" || ok
[ "$RC" = 0 ] && ok || bad "7: an empty files input is not an error (got $RC)"
reset
RC=$(run_hm "$WT" HOTFIX_WORKFLOW_FILES_INPUT=paths HOTFIX_MIGRATE_WORKFLOW=manual-sql.yml)
grep -q -- "workflow run manual-sql.yml -R o/p --ref ticket/x -f paths=$A,$B" "$T/dispatch.log" && ok \
  || bad "7: both knobs must reach the argv (got: $(cat "$T/dispatch.log"))"

# ===========================================================================
# 8. a needs-quiet answer that is not yes or no is a read error, never a no
# ===========================================================================
for ANS in maybe YES ''; do
  reset; printf '%s\n' "$ANS" > "$T/nq-2026-09-15-a.sql"
  RC=$(run_hm "$WT")
  [ "$RC" = 3 ] && ok || bad "8: needs-quiet '$ANS' must hold (got $RC)"
  [ "$(ndispatch)" = 0 ] && ok || bad "8: needs-quiet '$ANS' must dispatch nothing (got $(ndispatch))"
  grep -q 'needs-quiet read error' "$T/comment.md" && ok || bad "8: the proof must name the unreadable answer"
done
reset; echo 127 > "$T/nq.rc"
RC=$(run_hm "$WT")
[ "$RC" = 3 ] && ok || bad "8: a missing needs-quiet script must hold (got $RC)"
[ "$(ndispatch)" = 0 ] && ok || bad "8: a missing needs-quiet script must dispatch nothing (got $(ndispatch))"
grep -q 'exit 127' "$T/comment.md" && ok || bad "8: the proof must carry the exit code it read"
# the negative: a script that answers `no` for every file needs no probe at all
reset; echo no > "$T/nq-2026-09-15-a.sql"; echo no > "$T/nq-2026-09-15-b.sql"
RC=$(run_hm "$WT")
[ "$RC" = 0 ] && ok || bad "8: two honest 'no' answers must proceed (got $RC)"
[ -f "$T/probe.calls" ] && bad "8: nobody needs a quiet window, so nothing may probe" || ok

# ===========================================================================
# 9. checks that are not green: stop before anything else happens
# ===========================================================================
reset; echo 1 > "$T/checks.rc"; printf 'build\tpass\t1s\nVercel\tfail\t3s\n' > "$T/checks.out"
RC=$(run_hm "$WT")
[ "$RC" = 3 ] && ok || bad "9: red checks must hold, exit 3 (got $RC)"
[ "$(ndispatch)" = 0 ] && ok || bad "9: red checks must dispatch nothing (got $(ndispatch))"
grep -q 'checks not green' "$T/comment.md" && ok || bad "9: the proof must say the checks were not green"
[ -f "$T/nq.calls" ] && bad "9: a red check must stop us before we even ask about quiet windows" || ok

# ===========================================================================
# 10. the dispatch itself failed
# ===========================================================================
reset; echo 1 > "$T/dispatch.rc"
RC=$(run_hm "$WT")
[ "$RC" = 3 ] && ok || bad "10: a failed dispatch must hold (got $RC)"
grep -q 'dispatch failed' "$T/comment.md" && ok || bad "10: the proof must say the dispatch failed"
grep -q 'run watch' "$T/gh.log" && bad "10: nothing was dispatched, so nothing may be watched" || ok
[ "$(led '[.files[].status]|unique|join(",")')" = dispatch-failed ] && ok \
  || bad "10: the ledger must record dispatch-failed (got '$(led '[.files[].status]|join(",")')')"

# ===========================================================================
# 11. dispatched, but no run we can call ours
# ===========================================================================
reset
printf '%s\n' '[{"databaseId":111,"createdAt":"2000-01-01T00:00:00Z","status":"completed"}]' > "$T/runs.json"
RC=$(run_hm "$WT")
[ "$RC" = 3 ] && ok || bad "11: a run we could not locate must hold (got $RC)"
[ "$(ndispatch)" = 1 ] && ok || bad "11: the dispatch did happen, once (got $(ndispatch))"
grep -q 'could not locate' "$T/comment.md" && ok || bad "11: the proof must say we could not find the run"
grep -q 're-run dispatches again' "$T/comment.md" && ok \
  || bad "11: the proof must warn that re-running dispatches a second time"
grep -q 'run watch' "$T/gh.log" && bad "11: an unlocated run may not be watched" || ok
[ "$(led '[.files[].status]|unique|join(",")')" = dispatched-unlocated ] && ok \
  || bad "11: the ledger must record dispatched-unlocated (got '$(led '[.files[].status]|join(",")')')"

# ===========================================================================
# 12. the run was green and the proof would not post
# ===========================================================================
reset; touch "$T/comment.fail"
RC=$(run_hm "$WT")
[ "$RC" = 3 ] && ok || bad "12: a green run whose proof never posted is a hold (got $RC)"
[ "$(led .decision)" = applied ] && ok || bad "12: the ledger still records what really happened"
[ "$(led .posted_comment_id)" = null ] && ok || bad "12: a failed post must leave posted_comment_id null"

# ===========================================================================
# 13. the seam: the stage sources the lib and dispatches to it
# ===========================================================================
( HM_SOURCE_ONLY=1 HARNESS="$T/h" bash -c '. "$0"; declare -F hm_workflow >/dev/null' \
    "$T/h/bin/hotfix-migrate.sh" ) 2>/dev/null \
  && ok || bad "13: sourcing the stage with HM_SOURCE_ONLY=1 must define hm_workflow"

# ===========================================================================
# 14. a data edit never reaches a dispatch, and its revert line still rides
# ===========================================================================
reset
RC=$(run_hm "$WTR")
[ "$RC" = 2 ] && ok || bad "14: flagged SQL must exit 2 (got $RC)"
[ "$(ndispatch)" = 0 ] && ok || bad "14: flagged SQL must never be dispatched (got $(ndispatch))"
grep -q 'revert: UPDATE t SET x=1 WHERE id=7;' "$T/comment.md" && ok \
  || bad "14: the file's own revert line must ride in the proof verbatim"

# ===========================================================================
# 15. an unreadable run log is stated, never a reason to change the decision
# ===========================================================================
reset; touch "$T/log.fail"
RC=$(run_hm "$WT")
[ "$RC" = 0 ] && ok || bad "15: a log we could not read does not change a green run (got $RC)"
[ "$(led .decision)" = applied ] && ok || bad "15: the decision comes from the run, not from its log"

# ===========================================================================
# 16. the identity the DISPATCH goes out on. One fleet PAT is one 5000/h bucket
#     for every lane and one credential whose leak is fleet-wide (#425), so a
#     lane that dispatches and watches Actions runs arms the repo-scoped App
#     token ITSELF. The stage's PAT probe (gh_repo_use_token) runs before this
#     function and may leave a token behind on some boxes, which is exactly why
#     tests/gh-app-ratchet-test.sh does not count it: so this block drives
#     hm_workflow with NO probe on the box at all and reads the token the
#     dispatch actually carried.
# ===========================================================================
AH="$T/h2"
mkdir -p "$AH/bin/lib" "$AH/logs" "$AH/env" "$AH/builds"
cp "$DIR/bin/hotfix-migrate.sh" "$DIR/bin/check-migration-appliable.sh" "$AH/bin/"
cp "$DIR/bin/lib/gh-app-auth.sh" "$AH/bin/lib/"
[ -f "$LIB" ] && cp "$LIB" "$AH/bin/lib/"
printf '#!/bin/bash\nexit 0\n' > "$AH/bin/beat.sh"; chmod +x "$AH/bin/beat.sh"
printf '#!/bin/bash\nprintf ghs_stub\n' > "$AH/bin/gh-token.sh"; chmod +x "$AH/bin/gh-token.sh"
: > "$AH/env/global.env"; : > "$AH/env/github-app.env"
BX2="$AH/builds/x-os-BH-9-202609150002"; mkdir -p "$BX2"
tok_of() { local n; n=$(grep -c "^$1	" "$T/gh-tok.log" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
arm_drive() { # arm_drive -> rc of hm_workflow, driven under $AH with GH_TOKEN=pattok
  rm -f "$BX2"/hotfix-*
  ( cd "$T" && PATH="$T/fakebin:$PATH" HM_SOURCE_ONLY=1 HARNESS="$AH" \
      GH_TOKEN=pattok SLUG=o/p PR_URL=https://github.com/o/p/pull/9 BRANCH=ticket/x \
      WT="$WT" HOTFIX_CI_WAIT=2 HOTFIX_RUN_WAIT=5 HOTFIX_RUN_LOCATE_WAIT=0 \
      HM_T_BUILD="$BX2" \
      bash -c '. "$0"
        PROJECT=x-os; BUILD="$HM_T_BUILD"; FP=abc123def456
        LEDGER="$HM_T_BUILD/hotfix-migrate.json"; MODE=workflow
        FILES=("$1" "$2"); hm_workflow' \
        "$AH/bin/hotfix-migrate.sh" "$A" "$B" > "$T/arm.out" 2>&1 )
  echo $?
}
reset
RC=$(arm_drive)
[ "$RC" = 0 ] && ok || bad "16: the armed drive must finish green (got $RC; $(head -c 300 "$T/arm.out"))"
grep -q "^ghs_stub	workflow run " "$T/gh-tok.log" && ok \
  || bad "16: the dispatch must go out on the App token this lane armed (identities seen: $(cut -f1 "$T/gh-tok.log" | sort -u | tr '\n' ' '))"
grep -q "^ghs_stub	run watch 777" "$T/gh-tok.log" && ok \
  || bad "16: the run watch must go out on the App token too"
[ "$(tok_of pattok)" = 0 ] && ok \
  || bad "16: no call may fall back to the fleet PAT on an armed box ($(tok_of pattok) did)"
grep -rqs ghs_stub "$AH/logs" "$BX2" && bad "16: a token value reached a log or the build dir" || ok
# Unarmed box: no env/github-app.env, so gh_auth_for returns 1 without forking
# and the lane runs on exactly the identity it was handed, as it did before.
mv "$AH/env/github-app.env" "$AH/env/github-app.env.off"
reset
RC=$(arm_drive)
[ "$RC" = 0 ] && ok || bad "16: an unarmed box must behave exactly as before (got $RC)"
[ "$(tok_of ghs_stub)" = 0 ] && ok || bad "16: an unarmed box must mint nothing ($(tok_of ghs_stub) calls did)"
grep -q "^pattok	workflow run " "$T/gh-tok.log" && ok \
  || bad "16: on an unarmed box the dispatch runs on the identity the lane was given"
mv "$AH/env/github-app.env.off" "$AH/env/github-app.env"
# And the helper missing entirely (a box whose harness sync has not landed it).
rm -f "$AH/bin/lib/gh-app-auth.sh"
reset
RC=$(arm_drive)
[ "$RC" = 0 ] && ok || bad "16: with no gh-app-auth.sh on the box the lane must still run (got $RC)"
grep -q "^pattok	workflow run " "$T/gh-tok.log" && ok \
  || bad "16: with no helper the dispatch still goes out, on the lane's own identity"
cp "$DIR/bin/lib/gh-app-auth.sh" "$AH/bin/lib/"

# ===========================================================================
# 17. the migration's own FILENAME never reaches a shell. A file added as
#     `…-c$(cmd).sql` survives `git diff --name-only`, and the needs-quiet knob
#     is a command plus arguments — the path is argv, never shell source.
# ===========================================================================
reset; rm -f "$T/pwned" "$WTE/pwned"
RC=$(run_hm "$WTE")
if [ -e "$T/pwned" ] || [ -e "$WTE/pwned" ]; then
  bad "17: the migration filename was evaluated as shell — \$( ) in a path ran on the box"
else
  ok
fi
[ "$RC" = 0 ] && ok || bad "17: a file with an awkward name still goes through normally (got $RC)"
[ "$(ndispatch)" = 1 ] && ok || bad "17: that file is dispatched once, by name (got $(ndispatch))"
grep -qF -- "$EVIL" "$T/dispatch.log" && ok \
  || bad "17: the dispatch must carry the path verbatim (got: $(cat "$T/dispatch.log"))"

# ===========================================================================
# 18. HOTFIX_QUIET_POLL=0 is a floor, not a hot loop: `sleep 0` would run the
#     probe — a live DB query — as fast as the box can fork, for the whole window.
# ===========================================================================
reset; echo yes > "$T/nq-2026-09-15-a.sql"; printf '2\n2\n2\n2\n2\n2\n2\n2\n' > "$T/probe.seq"
RC=$(run_hm "$WT" HOTFIX_QUIET_MAX_WAIT=2 HOTFIX_QUIET_POLL=0)
[ "$RC" = 3 ] && ok || bad "18: a window that never opened must hold (got $RC)"
NP=$(grep -c . "$T/probe.calls" 2>/dev/null) || NP=0
[ "${NP:-0}" -le 8 ] && ok \
  || bad "18: a 0 poll must floor to one second, not spin the probe ($NP probes inside a 2s window)"

# ===========================================================================
# 19. the run-log tail is capped in BYTES as well as lines. 60 long lines can
#     push the proof past GitHub's 65536-char comment limit, which would turn a
#     real apply into `applied` with no comment id.
# ===========================================================================
reset; touch "$T/log.huge"
RC=$(run_hm "$WT")
[ "$RC" = 0 ] && ok || bad "19: a huge run log must not change a green run (got $RC)"
SZ=$(wc -c < "$BX/hotfix-run-log.txt"); SZ="${SZ//[!0-9]/}"
[ "${SZ:-0}" -le 8000 ] && ok || bad "19: the run-log tail must be byte-capped (got $SZ bytes)"
[ "$(led .posted_comment_id)" = 4242 ] && ok || bad "19: the proof must still post"
[ "$(wc -c < "$T/comment.md")" -lt 65536 ] && ok || bad "19: the proof body must fit in a GitHub comment"

# ===========================================================================
# 20. the dispatch SHAPE belongs to the project's workflow, not to us.
#     project-5's migrate-manual.yml declares `file` (one path), not `files`, so
#     the input NAME, the separator and how many files may ride are all knobs —
#     and a PR carrying more files than the input holds refuses BEFORE the
#     dispatch instead of handing the run a token it cannot parse.
# ===========================================================================
reset
RC=$(run_hm "$WT" HOTFIX_WORKFLOW_FILES_INPUT=file HOTFIX_WORKFLOW_FILES_SEP=' ')
grep -qF -- "workflow run migrate-manual.yml -R o/p --ref ticket/x -f file=$A $B" "$T/dispatch.log" \
  && ok || bad "20: the separator knob must reach the argv (got: $(cat "$T/dispatch.log"))"
[ "$RC" = 0 ] && ok || bad "20: a space-joined file list is not an error (got $RC)"
reset
RC=$(run_hm "$WT" HOTFIX_WORKFLOW_FILES_INPUT=file HOTFIX_WORKFLOW_MAX_FILES=1)
[ "$RC" = 3 ] && ok || bad "20: more files than the input holds must hold (got $RC)"
[ "$(ndispatch)" = 0 ] && ok || bad "20: that hold must dispatch nothing (got $(ndispatch))"
grep -q 'more migration files' "$T/comment.md" && ok || bad "20: the proof must say why nothing was dispatched"
reset
RC=$(run_hm "$WT" HOTFIX_WORKFLOW_MAX_FILES=2)
[ "$(ndispatch)" = 1 ] && ok || bad "20: a cap this PR fits under must still dispatch (got $(ndispatch))"
[ "$RC" = 0 ] && ok || bad "20: and finish green (got $RC)"

echo "hotfix-migrate-workflow-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
