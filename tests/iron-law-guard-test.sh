#!/bin/bash
# tests/iron-law-guard-test.sh — the act-time iron-law guard, driven for real.
#
# WHY THIS SHAPE. A guard whose only proof is a grep is the shape of guard this
# repo keeps finding inert (see the note in agent-call.sh's own header). So both
# halves are DRIVEN: the hook script is fed real PreToolUse payloads on stdin and
# its exit code, its stderr reason and the line it appends to findings.log are
# read back off disk; and bin/agent-call.sh is run against a temp HARNESS with a
# fake claude on PATH, so what actually reaches the CLI's argv and environment is
# read out of the file that fake wrote — not asserted from the source.
#
# The four things that must stay true:
#   1. the five irreversible families are DENIED (rc 2) with a reason the model sees
#   2. ordinary build commands are untouched, including ones that merely MENTION
#      a blocked verb inside an argument
#   3. a session that is not a harness build/triage lane is not guarded at all
#   4. a broken guard is never SILENT. A guard that diagnoses its own degrade
#      (no jq, unreadable payload) denies nothing and says so in ALERTS; a guard
#      that CRASHED before reaching a verdict denies everything and says so
#      (#409 — a killed hook used to exit 143, which the CLI runs anyway)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/bin" "$T/fakebin" "$T/repo"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

GUARD="$DIR/bin/iron-law-guard.sh"
# SLOWPATH: a PATH whose jq sleeps WALLCLOCK_STUB_SLEEP_S before running the real
# one — the slowed run tests/gates-to-reports.bh-5292-test.sh R6 drives against
# the two "bounded" cases below. Unset, it is the plain PATH.
mkdir -p "$T/slowbin"
# Capped at 4s: the guard bounds every child at 5s (`timeout 5 jq`), so a longer
# sleep would test that bound instead of slowing the guard down.
printf '#!/bin/bash\nw=${WALLCLOCK_STUB_SLEEP_S:-0}; [ "$w" -gt 4 ] 2>/dev/null && w=4\nsleep "$w"\nexec %q "$@"\n' "$(command -v jq)" > "$T/slowbin/jq"
chmod +x "$T/slowbin/jq"
SLOWPATH="$PATH"; [ -n "${WALLCLOCK_STUB_SLEEP_S:-}" ] && SLOWPATH="$T/slowbin:$PATH"

# One PreToolUse payload, the shape Claude Code sends.
payload() { # payload <command> [cwd]
  jq -nc --arg c "$1" --arg d "${2:-$T}" \
    '{session_id:"s1",hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}'
}
# Run the guard as a guarded execute lane. Prints the rc; stderr lands in $T/err.
guard() { # guard <command> [cwd]
  # timeout: a guard that stops reaching a verdict must FAIL this suite, not
  # hang it — the CI step has no bound of its own.
  payload "$1" "${2:-$T}" | timeout 30 env PATH="${GUARD_PATH:-$PATH}" HARNESS="$T" HARNESS_LANE=execute \
    HARNESS_LANE_PROJECT=testproj HARNESS_TICKET=TK-7 \
    bash "$GUARD" >/dev/null 2>"$T/err"
  echo $?
}

# --- 1. the five families are denied ----------------------------------------
# Each case is a shape that has actually been reachable from a build session:
# the plain verb, the verb behind `cd &&`, behind the fleet's rtk rewrite,
# behind `bash -c`, and behind the harness's own merge script.
while IFS='|' read -r RULE CMD; do
  [ -n "$CMD" ] || continue
  RC=$(guard "$CMD")
  if [ "$RC" != 2 ]; then bad "NOT DENIED (rc=$RC): $CMD"; continue; fi
  ok
  grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" \
    || bad "denied but gave the model no reason: $CMD"
  grep -q "family=actguard-$RULE" "$T/logs/findings.log" 2>/dev/null \
    || bad "denied but filed no $RULE finding: $CMD"
done <<'CASES'
pr-merge|gh pr merge 123 --squash
pr-merge|cd /root/repos/x && gh pr merge 12
pr-merge|rtk gh pr merge 12
pr-merge|bash -c 'gh pr merge 9'
pr-merge|bash /root/harness/bin/merge-sweep.sh
pr-merge|/root/harness/bin/merge-queue.sh project-2
push-main|git push origin main
push-main|git push --force origin main
push-main|git push --force-with-lease origin HEAD:main
push-main|git push -f origin +master
push-main|git push --all origin
push-main|git -C /root/repos/x push origin main
agent-push|git push -u origin act-time-hooks
agent-push|git push --force origin feature/rebased
prisma-live-db|npx prisma db push
prisma-live-db|pnpm exec prisma migrate deploy
prisma-live-db|npx prisma migrate dev --name x
prisma-live-db|npx prisma migrate reset
prod-db-write|psql "$DATABASE_URL" -c "UPDATE users SET tier='pro'"
prod-db-write|psql postgres://u:p@db.abcd.supabase.co:5432/postgres -f fix.sql
prod-db-write|psql "$DATABASE_URL"
prod-db-write|mysql -h prod.rds.amazonaws.com -e "DELETE FROM t"
vercel-deploy|vercel --prod
vercel-deploy|npx vercel deploy
vercel-deploy|vercel promote dpl_x --scope project-12
vercel-deploy|vercel
CASES

# The reason has to name the lane and forbid the workaround, or the model reads
# it as "try a different spelling".
RC=$(guard "gh pr merge 5")
[ "$RC" = 2 ] && grep -q "execute" "$T/err" && grep -qi "Do not work around this" "$T/err" \
  && ok || bad "the deny reason does not name the lane and rule out a workaround"

# --- 2. ordinary build commands are untouched -------------------------------
: > "$T/logs/findings.log"
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  RC=$(guard "$CMD")
  [ "$RC" = 0 ] && ok || bad "OVER-BLOCKED (rc=$RC): $CMD :: $(head -1 "$T/err")"
done <<'ALLOWED'
gh pr create --title "act-time hooks" --body-file /tmp/b
gh pr view 12 --json state
git commit -m "docs: note that gh pr merge is forbidden here"
git log --grep push -5
npx prisma generate
npx prisma migrate diff --from-empty --to-schema-datamodel prisma/schema.prisma
DATABASE_URL=postgres://u@localhost:5432/db npx prisma migrate dev
psql "$DATABASE_URL" -c "SELECT count(*) FROM users"
psql -h localhost -c "UPDATE t SET a=1"
vercel env pull .env.local --scope project-12
vercel logs os.project-2.example
npm run build && npm test
echo "vercel deploy and gh pr merge are not ours to run"
ALLOWED
[ -s "$T/logs/findings.log" ] \
  && bad "an allowed command filed a finding: $(head -1 "$T/logs/findings.log")" || ok

# A bare `git push` is judged by the branch the session is standing on: the
# refspec is implicit, so the command text alone cannot answer it.
git -C "$T/repo" init -q -b main && git -C "$T/repo" commit -q --allow-empty -m x
[ "$(guard "git push" "$T/repo")" = 2 ] \
  && ok || bad "a bare git push while on main was allowed"
grep -q 'family=actguard-push-main' "$T/logs/findings.log" \
  && ok || bad "a bare git push on main must stay rule push-main"
# BH-2741: a feature branch is no longer the agent's to push either. The
# harness pushes it after the session, through bin/lib/hold-push.sh.
git -C "$T/repo" checkout -q -b feat
: > "$T/logs/findings.log"
[ "$(guard "git push" "$T/repo")" = 2 ] \
  && ok || bad "a bare git push on a feature branch was allowed (BH-2741: the harness pushes it)"
grep -q 'family=actguard-agent-push .*:: hold=' "$T/logs/findings.log" \
  && ok || bad "a bare feature-branch push must file ONE agent-push finding naming the hold: $(cat "$T/logs/findings.log")"

# --- 3. the lane fence ------------------------------------------------------
# The orchestrator conversation, box-chat and the merge lanes must be untouched.
# `env -u` is load-bearing, not decoration: this suite is itself run BY a harness
# build lane, which exports HARNESS_LANE into everything it launches. Without the
# scrub the "no lane" case inherits HARNESS_LANE=execute and this assertion tests
# a guarded session against the unguarded expectation — it fails on a box and
# passes on a laptop, which is the worst of both.
unguarded() { payload "$1" | env -u HARNESS_LANE -u HARNESS_LANE_PROJECT -u HARNESS_LANE_WT \
  HARNESS="$T" ${2:+HARNESS_LANE=$2} bash "$GUARD" >/dev/null 2>&1; echo $?; }
[ "$(unguarded "gh pr merge 1")" = 0 ] \
  && ok || bad "a session with no HARNESS_LANE (the orchestrator) was guarded"
[ "$(unguarded "gh pr merge 1" chat)" = 0 ] \
  && ok || bad "the chat lane was guarded"
[ "$(unguarded "gh pr merge 1" execute)" = 2 ] \
  && ok || bad "the execute lane was NOT guarded"
printf '{"tool_name":"Edit","tool_input":{"file_path":"/x"}}' \
  | env HARNESS="$T" HARNESS_LANE=execute bash "$GUARD" >/dev/null 2>&1
[ $? = 0 ] && ok || bad "a non-Bash tool call was judged by a Bash guard"

# --- 4. the finding is readable by the thing that consumes it ---------------
# rule-miner.sh source (e) walks fields until `::`, keys on family=, and reads
# the first [bracketed] token as the project. A line it cannot key is mined as
# nothing, silently — so parse it here exactly the way that awk does.
: > "$T/logs/findings.log"; guard "gh pr merge 42 # ship it" >/dev/null
read -r FAM PROJ < <(awk '{fam="";proj="";
    for(i=1;i<=NF;i++){ if($i=="::") break;
      else if(substr($i,1,7)=="family=") fam=substr($i,8);
      else if(proj=="" && substr($i,1,1)=="["){proj=$i; gsub(/[][]/,"",proj)} }
    print fam, proj}' "$T/logs/findings.log")
[ -n "$FAM" ] && [ "$FAM" != "-" ] \
  && ok || bad "rule-miner's own field walk cannot key this finding (family='$FAM')"
[ "$PROJ" = testproj ] && ok || bad "the finding does not carry the project (got '$PROJ')"
grep -q "ticket=TK-7" "$T/logs/findings.log" \
  && ok || bad "the finding does not carry the ticket"
[ "$(wc -l < "$T/logs/findings.log")" = 1 ] \
  && ok || bad "one blocked command filed $(wc -l < "$T/logs/findings.log") findings"

# --- 5. a broken guard denies nothing, loudly -------------------------------
: > "$T/logs/ALERTS.log"
RC=$(payload "gh pr merge 1" | env -i PATH=/nonexistent HARNESS="$T" HARNESS_LANE=execute \
       HARNESS_LANE_PROJECT=testproj /bin/bash "$GUARD" >/dev/null 2>&1; echo $?)
[ "$RC" = 0 ] && ok || bad "a guard that cannot run its own dependencies bricked the command (rc=$RC)"
grep -q "iron-law guard INERT" "$T/logs/ALERTS.log" \
  && ok || bad "a degraded guard failed open SILENTLY — the one failure mode this must not have"
: > "$T/logs/ALERTS.log"
RC=$(printf 'not json' | env HARNESS="$T" HARNESS_LANE=execute bash "$GUARD" >/dev/null 2>&1; echo $?)
[ "$RC" = 0 ] && grep -q "INERT" "$T/logs/ALERTS.log" \
  && ok || bad "an unparseable payload did not degrade loudly (rc=$RC)"

# The payload arrives on a pipe the hook cannot reopen — the first live run of
# this guard read it as `< /dev/stdin`, which the CLI's hook environment answers
# with "No such device or address", and the script then died on the unbound
# variable BEFORE it could say so. It looked exactly like a working guard.
# Closed stdin reproduces that class: unreadable payload -> loud, never silent.
: > "$T/logs/ALERTS.log"
env HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj bash "$GUARD" 0<&- >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && grep -q "INERT" "$T/logs/ALERTS.log" \
  && ok || bad "an unreadable payload did not degrade loudly (rc=$RC, alerts=$(cat "$T/logs/ALERTS.log"))"

# ... and any OTHER way of failing before a verdict — a set -u abort, a bad edit
# to this file — REFUSES, and announces itself. A self-diagnosed degrade (above)
# denies nothing, because the guard knows what is wrong with it and can step
# aside; a guard killed mid-thought knows nothing about the command it was
# judging, so it fails closed (#409). Either way it is never quietly broken.
: > "$T/logs/ALERTS.log"
sed 's|^trap .*EXIT$|&\nBROKEN_ON_PURPOSE="$THIS_VARIABLE_DOES_NOT_EXIST"|' "$GUARD" > "$T/broken-guard.sh"
RC=$(payload "gh pr merge 1" | env HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj \
       bash "$T/broken-guard.sh" >/dev/null 2>&1; echo $?)
[ "$RC" = 2 ] && grep -q "\[iron-law\] guard crashed" "$T/logs/ALERTS.log" \
  && ok || bad "a guard that died before deciding did not refuse and announce it (rc=$RC, want 2, alerts=$(cat "$T/logs/ALERTS.log"))"

# ...and that line has to carry the REAL exit status. `local rc=$?` inside the
# handler reads the status of the trap's own first command, not the status the
# script died with, so every crash was filed as rc=0 — an audit line that says
# the guard exited cleanly is worth exactly as much as no audit line.
grep -qE '\[iron-law\] guard crashed: exited rc=[1-9][0-9]* before a verdict' "$T/logs/ALERTS.log" \
  && ok || bad "the crash line filed rc=0 for a crash: $(grep 'guard crashed' "$T/logs/ALERTS.log" | head -1)"

# The payload read is BOUNDED. The CLI hands the hook a pipe it does not always
# close, and `read -r -d ""` on a payload with no NUL terminator blocks until the
# PreToolUse budget ABANDONS the hook — the one case no exit code can answer,
# because the CLI ignores whatever an abandoned hook prints, so the command runs
# unguarded no matter how the guard exits. Held-open stdin reproduces that
# exactly: the guard has to reach a verdict on its own clock, not the caller's.
: > "$T/logs/ALERTS.log"
# The fifo is opened READ-WRITE by this shell, so nothing here can block on
# open() and no second process holds the pipe: the payload is written, the guard
# inherits the read end, and because this shell keeps the write end open the
# guard never sees EOF — which is the condition being tested.
mkfifo "$T/hold.fifo"
exec 8<>"$T/hold.fifo"
payload "gh pr merge 1" >&8
# TEST-CHANGE BH-5292: was `ELAPSED -le 5` under `timeout 15`. the operator changed the
# rule (2026-10-07): no wall-clock asserts. What it guarded — the guard ends the
# read ITSELF instead of blocking until something outside kills it — is proved
# by the exit: under a 60s hang guard, rc 124 means the read never returned and
# the timeout decided. A mutation that drops the bounded read (TMOUT) hangs here
# and fails on 124; a slowed run (sleep in jq) still passes.
timeout 60 env PATH="$SLOWPATH" HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj \
  bash "$GUARD" <&8 >/dev/null 2>&1
RC=$?
exec 8>&-
[ "$RC" != 124 ] \
  && ok || bad "the guard never returned on a payload with no terminator — the hang guard, not the guard, decided (rc 124)"
{ [ "$RC" = 2 ] || { [ "$RC" = 0 ] && grep -q "INERT" "$T/logs/ALERTS.log"; }; } \
  && ok || bad "a payload the guard could not finish reading neither judged nor degraded loudly (rc=$RC)"

# A HEREDOC BODY IS DATA. `cat > file <<'EOF' ... EOF` writes a file; a 40KB one
# that merely CONTAINS a guarded verb used to miss the fast path and spend ~10s
# in the classifier, which is long enough for the hook timeout to fire — and a
# killed hook runs the command unguarded. The body is stripped; the launcher in
# front of it and anything after the closing delimiter are still judged.
# 40KB of ordinary SQL — many short words, which is what the classifier is slow
# on (one giant unbroken token is cheap and proves nothing).
BODY=$(awk 'BEGIN{for(i=0;i<520;i++) printf "INSERT INTO widgets (id, name, tier) VALUES (%d, %cwidget-name-here%c, %cpro%c);\n", i, 39, 39, 39, 39}')
: > "$T/logs/findings.log"
HD=$(printf 'cat > /tmp/mig.sql <<%s\n%s\nnpx prisma db push\nEOF\necho wrote it\n' "'EOF'" "$BODY")
: > "$T/logs/ALERTS.log"
RC=$(GUARD_PATH="$SLOWPATH" guard "$HD")
[ "$RC" = 0 ] \
  && ok || bad "a guarded verb inside a heredoc BODY was blocked (rc=$RC) — the body is a file being written, not a command"
# TEST-CHANGE BH-5292: was `ELAPSED -le 3`. the operator changed the rule (2026-10-07):
# no wall-clock asserts. The slow path it guarded is the 40KB body reaching the
# classifier; that is now proved by WORK, not seconds: the guard reached a real
# verdict (no INERT degrade, no hang-guard 124), and the strip the guard runs
# hands the classifier the launcher and the tail only — none of the 520 body
# lines. A mutation that skips the strip is blocked above (the body holds
# `npx prisma db push`); one that breaks the strip fails the count below.
grep -q INERT "$T/logs/ALERTS.log" \
  && bad "the 40KB heredoc degraded instead of judging: $(head -1 "$T/logs/ALERTS.log")" || ok
awk '/^_strip_quoted_heredocs\(\) \{/,/^\}/' "$GUARD" > "$T/strip.sh"
# Flattened the way the guard hands it over (jq turns \n\r\t into spaces).
STRIPPED=$(bash -c '. "$1"; _strip_quoted_heredocs "$2"' _ "$T/strip.sh" "$(printf '%s' "$HD" | tr '\n\r\t' '   ')" 2>/dev/null)
[ -s "$T/strip.sh" ] && [ -n "$STRIPPED" ] && [ "$(grep -c 'INSERT INTO' <<<"$STRIPPED")" = 0 ] \
  && grep -q 'echo wrote it' <<<"$STRIPPED" && grep -q 'cat > /tmp/mig.sql' <<<"$STRIPPED" \
  && ok || bad "the heredoc strip did not reduce the 40KB body to launcher + tail: $(head -c 300 <<<"$STRIPPED")"
[ -s "$T/logs/findings.log" ] \
  && bad "a heredoc body filed a finding: $(head -1 "$T/logs/findings.log")" || ok
# The body of a runbook or a migration is full of shell separators, so without
# the strip its lines are read as segments and classified as real commands.
[ "$(guard "$(printf 'cat > /tmp/runbook.md <<%s\nnpx prisma db push;\ngh pr merge 12;\nEOF\necho wrote it\n' "'EOF'")")" = 0 ] \
  && ok || bad "writing a runbook that QUOTES the forbidden commands was blocked as if it ran them"
HD2=$(printf 'cat > /tmp/mig.sql <<%s\n%s\nEOF\nnpx prisma db push\n' "'EOF'" "$BODY")
[ "$(guard "$HD2")" = 2 ] \
  && ok || bad "a real prisma db push AFTER the closing delimiter was allowed — the strip ate a live command"
[ "$(guard "$(printf 'psql postgres://u:p@db.abcd.supabase.co/postgres <<%s\nUPDATE t SET a=1;\nSQL\n' "'SQL'")")" = 2 ] \
  && ok || bad "the command in FRONT of a heredoc stopped being classified"

# --- 6. the wiring: what actually reaches the claude CLI --------------------
# agent-call.sh is run for real with a fake claude that dumps its argv and the
# environment it was handed. Nothing here is asserted from reading the source.
cp "$DIR/bin/iron-law-guard.sh" "$T/bin/"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$T_SENTINEL_DIR/argv.txt"
env > "$T_SENTINEL_DIR/env.txt"
echo '{"result":"ok","usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0.01}'
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
chmod +x "$T/fakebin/"* "$T/bin/beat.sh" "$T/bin/iron-law-guard.sh"

call() { # call <stage> [env assignments...]
  local stage="$1"; shift
  rm -f "$T/argv.txt" "$T/env.txt"
  ( export T_SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env -u HARNESS_LANE -u HARNESS_LANE_PROJECT -u HARNESS_LANE_WT -u HARNESS_LANE_BUILD_DIR \
        "$@" bash "$DIR/bin/agent-call.sh" "$stage" testproj claude-opus-5 600 "$T/out.txt" "hi" >/dev/null 2>&1 )
}
settings_arg() { grep -A1 -x -- '--settings' "$T/argv.txt" 2>/dev/null | tail -1; }

call execute
S=$(settings_arg)
[ -n "$S" ] && [ -f "$S" ] \
  && ok || bad "the execute lane got no --settings file at all"
[ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S" 2>/dev/null)" = "$T/bin/iron-law-guard.sh" ] \
  && ok || bad "the settings file claude got does not wire the guard: $(cat "$S" 2>/dev/null)"
[ "$(jq -r '.hooks.PreToolUse[0].matcher' "$S" 2>/dev/null)" = "Bash" ] \
  && ok || bad "the guard hook is not matched to Bash"
grep -qx "HARNESS_LANE=execute" "$T/env.txt" \
  && ok || bad "the lane marker never reached the claude process, so the hook cannot fence on it"
grep -qx "HARNESS_LANE_PROJECT=testproj" "$T/env.txt" \
  && ok || bad "the project never reached the claude process, so findings cannot name it"

# The chat lane keeps its authority: no guard, no marker. Reads the environment
# agent-call.sh actually set, not the one this suite inherited — see call() above.
call chat
[ -z "$(settings_arg)" ] && ! grep -q "^HARNESS_LANE=" "$T/env.txt" \
  && ok || bad "the chat lane was fenced — merge-lane and chat sessions must keep their authority"

# The red-squigglies hook and the guard have to COEXIST: a second --settings
# replaces the first, so this is the regression that would silently disarm one
# of them. Exactly one --settings, carrying both hooks.
call execute EDIT_FEEDBACK=1
cp "$DIR/bin/edit-feedback-settings.json" "$T/bin/" 2>/dev/null
call execute EDIT_FEEDBACK=1
S=$(settings_arg)
[ "$(grep -c -x -- '--settings' "$T/argv.txt")" = 1 ] \
  && ok || bad "claude got $(grep -c -x -- '--settings' "$T/argv.txt") --settings flags; the later one silently wins"
[ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S" 2>/dev/null)" = "$T/bin/iron-law-guard.sh" ] \
  && [ "$(jq -r '.hooks.PostToolUse[0].hooks[0].command // empty' "$S" 2>/dev/null)" != "" ] \
  && ok || bad "the merged settings dropped one of the two hooks: $(cat "$S" 2>/dev/null)"

# A guard that is missing from the box is an ALERT, and the build still runs.
: > "$T/logs/ALERTS.log"; mv "$T/bin/iron-law-guard.sh" "$T/bin/iron-law-guard.off"
call execute
grep -q "iron-law guard MISSING" "$T/logs/ALERTS.log" \
  && ok || bad "a box with no guard script ran a build lane silently unguarded"
grep -q '^-p$' "$T/argv.txt" \
  && ok || bad "a missing guard stopped the stage from running at all — it must degrade, not brick"
mv "$T/bin/iron-law-guard.off" "$T/bin/iron-law-guard.sh"

echo "iron-law-guard: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
