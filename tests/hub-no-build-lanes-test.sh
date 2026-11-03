#!/bin/bash
# tests/hub-no-build-lanes-test.sh — THE HUB RUNS NO AGENT BUILD WORK (BH-393).
#
# WHY DRIVEN AND NOT GREPPED. The policy has existed since 2026-08-24
# (docs/HUB-THINNING-PLAN.md) and on 2026-09-15 ten `up10` self-improvement
# lanes were executing inside /root/harness/tmp/wt-up10-* on the hub when it was
# wiped. A policy whose only enforcement is a paragraph is the shape of guard
# this repo keeps discovering was inert all along. So:
#   - bin/agent-call.sh is RUN, against a scratch $HARNESS with a fake `claude`
#     on PATH, and what it did (or did not) invoke is read back off disk.
#   - the run-build.sh and run-preplan.sh guards are extracted VERBATIM by their
#     `# >>> hub-no-build` / `# <<< hub-no-build` markers and executed. The
#     extraction asserts the block is non-empty, so a missing marker fails here
#     instead of quietly testing nothing.
#   - bin/up10-lane.sh is RUN, with ssh, gh, box-for.sh, fleet-conf.sh and
#     run-build.sh all stubbed. Nothing here touches a real box, a real ledger
#     or a real GitHub issue.
#
# The negatives carry the weight: the lanes that must KEEP working on the hub
# (triage, chat, review-by-default), the boxes that are not the hub, the box
# named box-hub0 that must not prefix-match box-hub, and a
# half-synced box with no lib beside the script — which must fail OPEN to
# today's behaviour rather than take the fleet's build lanes down with it.
#
# Run from anywhere: tests/hub-no-build-lanes-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/fakebin" "$T/state" "$T/bin/lib" "$T/env" \
         "$T/plans" "$T/builds/rb" "$T/tmp"
: > "$T/env/global.env"
# This suite runs inside the harness, which exports its own HARNESS_TICKET and
# may carry an operator's knobs. Every one of them is an input to the thing
# under test, so none of them may leak in from the caller.
unset HARNESS_TICKET HUB_BUILD_OK HUB_NO_BUILD_LANES HUB_BOX_NAME BOX_NAME
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── the artefacts under test have to exist at all ────────────────────────────
LIB="$DIR/bin/lib/hub-box.sh"
UP10="$DIR/bin/up10-lane.sh"
[ -r "$LIB" ]  && ok || bad "bin/lib/hub-box.sh is missing — the shared hub guard does not exist"
[ -r "$UP10" ] && ok || bad "bin/up10-lane.sh is missing — the up10 chain has nothing to re-home onto"
cp "$LIB" "$T/bin/lib/hub-box.sh" 2>/dev/null
cp "$DIR/bin/box-name.sh" "$T/bin/box-name.sh" && chmod +x "$T/bin/box-name.sh"

box() { printf '%s\n' "$1" > "$T/state/box-name"; }

# ── stubs ────────────────────────────────────────────────────────────────────
# Fake claude: leaves a sentinel, then answers like the real CLI's json envelope.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_SINK"
touch "$T_SENTINEL_DIR/claude-was-called"
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
chmod +x "$T/fakebin/claude"
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"
chmod +x "$T/fakebin/billing-mode.sh"
# GNU `timeout` shim (same reason as tests/agent-call-notools-test.sh).
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"

# box-for.sh / fleet-conf.sh: the fleet registry, answered from files the test
# rewrites, so "column 6 is empty" and "no tailnet address" are real cases.
printf 'box-small\n' > "$T/stub-box-for"
printf '10.0.0.13\n'          > "$T/stub-tailnet-ip"
cat > "$T/bin/box-for.sh" <<EOF
#!/bin/bash
cat "$T/stub-box-for"
EOF
cat > "$T/bin/fleet-conf.sh" <<EOF
#!/bin/bash
case "\${1:-}" in
  --tailnet-ip-of-box) cat "$T/stub-tailnet-ip" ;;
  *) case "\${2:-}" in repo) echo example-org/cromford ;; esac ;;
esac
EOF
chmod +x "$T/bin/box-for.sh" "$T/bin/fleet-conf.sh"

# run-build.sh: records its argv, then unblocks the reader on the fifo so the
# test never has to guess how long a detached launch takes.
mkfifo "$T/rb.fifo"
cat > "$T/bin/run-build.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/rb-argv.txt"
echo launched > "$T/rb.fifo"
EOF
chmod +x "$T/bin/run-build.sh"

# gh: every invocation recorded; the issue list answers from a file the test
# rewrites. BH-1651: up10-lane reads the list over REST (gh_rest_issue_list ->
# `gh api -i`), so the stub answers in the REST wire shape; a nonzero
# stub-gh-list-rc is a read that did not answer (HTTP 403).
printf '[]\n' > "$T/stub-gh-issue-list"
printf '0\n'  > "$T/stub-gh-list-rc"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-argv.txt"
. "$DIR/tests/lib/gh-cli-rest-adapter.sh" || exit 1  # BH-8962: the REST create, from the issue create arm
gh_cli_rest_create "\$0" "\$@" && exit 0
case "\$*" in
  "api -i -X GET repos/"*"/issues "*)
    if [ "\$(cat "$T/stub-gh-list-rc")" = 0 ]; then
      printf 'HTTP/2 200\r\n\r\n'; cat "$T/stub-gh-issue-list"
    else
      printf 'HTTP/2 403\r\n\r\n{"message":"Forbidden"}\n'
    fi
    exit 0 ;;
esac
case "\${1:-} \${2:-}" in
  "issue list")   cat "$T/stub-gh-issue-list"; exit "\$(cat "$T/stub-gh-list-rc")" ;;
  "issue create") echo "https://github.com/example-org/cromford/issues/42" ;;
esac
EOF
chmod +x "$T/fakebin/gh"

# ssh: records argv and stdin, never opens a socket.
cat > "$T/fakebin/fakessh" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$T/ssh-argv.txt"
cat > "$T/ssh-stdin.txt"
EOF
chmod +x "$T/fakebin/fakessh"

printf 'do the thing\n' > "$T/brief.txt"
: > "$T/empty-brief.txt"

alerts() { grep -c '\[hub-no-build\]' "$T/logs/ALERTS.log" 2>/dev/null || true; }
reset_alerts() { : > "$T/logs/ALERTS.log"; rm -f "$T"/flags/alerted-hub-no-build-*; }

# ═══ 1. the lib itself ═══════════════════════════════════════════════════════
libq() { # libq <shell snippet> [env assignments...] — run it with the lib sourced
  local snip="$1"; shift
  ( export HARNESS="$T"
    # shellcheck source=/dev/null
    env "$@" bash -uc '. "$1"; shift; eval "$@"' _ "$T/bin/lib/hub-box.sh" "$snip" 2>&1 )
}
lib_rc() { local snip="$1"; shift; libq "$snip" "$@" >/dev/null 2>&1; echo $?; }

box box-hub
[ "$(libq 'hub_box_name')" = box-hub ] \
  && ok || bad "hub_box_name is not box-hub: $(libq 'hub_box_name')"
[ "$(libq 'hub_box_name' HUB_BOX_NAME=box-zz)" = box-zz ] \
  && ok || bad "HUB_BOX_NAME does not rename the hub — a renamed hub would stop being the hub"
[ "$(lib_rc 'is_hub_box box-hub')" = 0 ] && ok || bad "is_hub_box box-hub said no"
[ "$(lib_rc 'is_hub_box local')" = 0 ]           && ok || bad "is_hub_box local said no"
[ "$(lib_rc 'is_hub_box box-hub0')" = 0 ] \
  && bad "box-hub0 prefix-matched the hub — every lane on that box would refuse" || ok
[ "$(lib_rc 'is_hub_box box-small')" = 0 ] \
  && bad "box-small was read as the hub" || ok
[ "$(lib_rc 'is_hub_box ""')" = 0 ] \
  && bad "an EMPTY box name was read as the hub — an unnameable box would refuse every lane" || ok
[ "$(libq 'local_box_name')" = box-hub ] \
  && ok || bad "local_box_name did not read state/box-name: $(libq 'local_box_name')"

reset_alerts
[ "$(lib_rc 'hub_no_build_refuse execute BH-1')" = 0 ] \
  && ok || bad "hub_no_build_refuse did not refuse execute on the hub"
[ "$(lib_rc 'hub_no_build_refuse execute BH-1')" = 0 ] && ok || bad "the second refusal did not refuse"
[ "$(alerts)" = 1 ] \
  && ok || bad "two refusals of the same (lane,ticket) wrote $(alerts) ALERTS lines, not one — preplan-tick fires every 2 minutes"
grep -q '\[hub-no-build\] refused execute BH-1' "$T/logs/ALERTS.log" \
  && ok || bad "the ALERTS line is not in the ticket's shape: $(cat "$T/logs/ALERTS.log")"
reset_alerts
[ "$(lib_rc 'hub_no_build_refuse execute BH-1' HUB_BUILD_OK=1)" = 0 ] \
  && bad "HUB_BUILD_OK=1 did not override the refusal" || ok
[ "$(alerts)" = 0 ] && ok || bad "an overridden call still wrote an ALERTS line"
[ "$(lib_rc 'hub_no_build_refuse triage BH-1')" = 0 ] \
  && bad "the triage lane was refused — fleet-scoped lanes must be unaffected" || ok
box box-small
[ "$(lib_rc 'hub_no_build_refuse execute BH-1')" = 0 ] \
  && bad "execute was refused on box-small — the guard is not box-scoped" || ok

# ═══ 2. bin/agent-call.sh, driven for real ═══════════════════════════════════
run_agent() { # run_agent <stage> [env assignments...] ; echoes the rc
  local stage="$1"; shift
  rm -f "$T/claude-was-called" "$T/out.txt" "$T/argv.txt"
  ( export ARGV_SINK="$T/argv.txt" T_SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" \
           HARNESS="$T" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" HOME="$T"
    env "$@" bash "$DIR/bin/agent-call.sh" "$stage" testproj claude-fable-5 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

box box-hub
reset_alerts
RC=$(run_agent execute)
[ "$RC" = 77 ] && ok || bad "agent-call execute on the hub exited $RC, not the refusal rc 77"
[ -f "$T/claude-was-called" ] \
  && bad "the runner was invoked on the hub anyway — the refusal is decorative and the call was billed" || ok
grep -q '^AGENT_CALL_REFUSED hub-no-build' "$T/out.txt" \
  && ok || bad "\$OUT carries no refusal marker, so a caller reading it on nonzero rc reads a stale answer: $(head -1 "$T/out.txt" 2>/dev/null)"
[ -s "$T/logs/cost.csv" ] \
  && bad "a cost row was written for a call that never happened" || ok
RC=$(run_agent execute)
[ "$(alerts)" = 1 ] && ok || bad "two refused execute calls wrote $(alerts) ALERTS lines, not one"
grep -q '\[hub-no-build\] refused execute testproj' "$T/logs/ALERTS.log" \
  && ok || bad "the agent-call refusal does not name lane and ticket: $(cat "$T/logs/ALERTS.log")"

# the ticket's own scenario: HARNESS_TICKET names the ticket when there is one
reset_alerts
RC=$(run_agent execute HARNESS_TICKET=BH-393)
grep -q '\[hub-no-build\] refused execute BH-393' "$T/logs/ALERTS.log" \
  && ok || bad "HARNESS_TICKET is not used as the ticket in the refusal line: $(cat "$T/logs/ALERTS.log")"

# ...and the override
reset_alerts
RC=$(run_agent execute HUB_BUILD_OK=1)
[ "$RC" != 77 ] && ok || bad "HUB_BUILD_OK=1 still refused (rc $RC)"
[ -f "$T/claude-was-called" ] && ok || bad "HUB_BUILD_OK=1 did not reach the runner"
[ "$(alerts)" = 0 ] && ok || bad "an overridden agent-call wrote a refusal line anyway"

# the lanes the hub keeps: triage, chat — and review, which by DEFAULT still
# runs here because cron/hub.cron's review lanes have not moved (out of scope).
for S in triage chat review; do
  reset_alerts
  RC=$(run_agent "$S")
  [ "$RC" != 77 ] && ok || bad "the $S lane was refused on the hub — fleet-scoped lanes must be unaffected"
  [ -f "$T/claude-was-called" ] && ok || bad "the $S lane never reached the runner on the hub"
done
# ...and the knob is what makes review refusable the day those lanes move.
reset_alerts
RC=$(run_agent review HUB_NO_BUILD_LANES=review)
[ "$RC" = 77 ] && ok || bad "HUB_NO_BUILD_LANES=review did not make the review lane refuse (rc $RC)"
[ -f "$T/claude-was-called" ] && bad "a refused review lane still called the runner" || ok

# a box that is not the hub
for B in box-small box-hub0; do
  box "$B"
  reset_alerts
  RC=$(run_agent execute)
  [ "$RC" != 77 ] && ok || bad "execute was refused on $B (rc $RC) — only the hub refuses"
  [ -f "$T/claude-was-called" ] && ok || bad "execute never reached the runner on $B"
done

# a half-synced box: no lib beside the script and none under $HARNESS/bin.
# Fail OPEN — a missing guard must not take the fleet's build lanes down.
mkdir -p "$T/nolib/bin2" "$T/nolib/logs" "$T/nolib/state" "$T/nolib/flags"
cp "$DIR/bin/agent-call.sh" "$T/nolib/bin2/agent-call.sh"
printf 'box-hub\n' > "$T/nolib/state/box-name"
rm -f "$T/claude-was-called"
RC=$( ( export ARGV_SINK="$T/argv.txt" T_SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" \
               HARNESS="$T/nolib" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" HOME="$T"
        bash "$T/nolib/bin2/agent-call.sh" execute testproj claude-fable-5 60 "$T/nolib/out.txt" hi \
          >/dev/null 2>&1 ); echo $? )
[ "$RC" != 77 ] && ok || bad "agent-call with no hub-box lib beside it refused (rc $RC) — a mid-sync box would stop building"
[ -f "$T/claude-was-called" ] && ok || bad "the fail-open path never reached the runner"

# ═══ 3. bin/run-build.sh's guard, extracted verbatim ═════════════════════════
awk '/^# >>> hub-no-build/{f=1;next} /^# <<< hub-no-build/{exit} f' "$RB_ALL" > "$T/rb-block.sh"
grep -q 'hub_no_build_refuse' "$T/rb-block.sh" \
  && ok || bad "could not extract the hub-no-build block from bin/run-build.sh — this section would test nothing"

run_rb() { # run_rb [env assignments...] ; echoes the rc
  rm -f "$T/rb-sentinel.txt" "$T/builds/rb/RESULT"
  ( export HARNESS="$T" PATH="$T/fakebin:$PATH"
    env "$@" bash -c '
      set -uo pipefail
      PROJECT=cromford; KEY=BH-1
      BUILD="$HARNESS/builds/rb"; ALERTS="$HARNESS/logs/ALERTS.log"
      STAMP() { echo stamp; }
      RESULT() { echo "$*" > "$BUILD/RESULT"; echo "$*"; }
      . "$HARNESS/rb-block.sh"
      echo REACHED > "$HARNESS/rb-sentinel.txt"' >/dev/null 2>&1 )
  echo $?
}
box box-hub
reset_alerts
RC=$(run_rb)
[ "$RC" = 3 ] && ok || bad "a refused build exited $RC, not the pipeline's own refusal rc 3"
[ -f "$T/rb-sentinel.txt" ] && bad "a refused build ran anyway" || ok
grep -q '^BUILD_REFUSED hub-no-build' "$T/builds/rb/RESULT" 2>/dev/null \
  && ok || bad "the RESULT does not carry the refusal: $(cat "$T/builds/rb/RESULT" 2>/dev/null)"
grep -q 'box-small' "$T/builds/rb/RESULT" 2>/dev/null \
  && ok || bad "the RESULT does not name the box the ticket belongs on: $(cat "$T/builds/rb/RESULT" 2>/dev/null)"
grep -q '\[hub-no-build\] refused build BH-1' "$T/logs/ALERTS.log" \
  && ok || bad "the build refusal is silent in ALERTS.log: $(cat "$T/logs/ALERTS.log")"
RC=$(run_rb HUB_BUILD_OK=1)
[ -f "$T/rb-sentinel.txt" ] && ok || bad "HUB_BUILD_OK=1 did not let the build past the guard (rc $RC)"
box box-small
RC=$(run_rb)
[ -f "$T/rb-sentinel.txt" ] && ok || bad "a build on box-small was stopped by the hub guard (rc $RC)"

# ═══ 4. bin/run-preplan.sh's guard, extracted verbatim ══════════════════════
awk '/^# >>> hub-no-build/{f=1;next} /^# <<< hub-no-build/{exit} f' "$DIR/bin/run-preplan.sh" > "$T/rp-block.sh"
grep -q 'hub_no_build_refuse' "$T/rp-block.sh" \
  && ok || bad "could not extract the hub-no-build block from bin/run-preplan.sh — this section would test nothing"

run_rp() { # run_rp [env assignments...]
  rm -f "$T/rp-sentinel.txt"; rm -rf "$T/plans/cromford-BH-1"
  ( export HARNESS="$T" PATH="$T/fakebin:$PATH"
    env "$@" bash -c '
      set -uo pipefail
      PROJECT=cromford; KEY=BH-1
      PLANDIR="$HARNESS/plans/$PROJECT-$KEY"
      LOG="$HARNESS/logs/preplan.log"
      STAMP() { echo stamp; }
      . "$HARNESS/rp-block.sh"
      mkdir -p "$PLANDIR"
      echo REACHED > "$HARNESS/rp-sentinel.txt"' >/dev/null 2>&1 )
  echo $?
}

box box-hub
reset_alerts
: > "$T/logs/preplan.log"
RC=$(run_rp)
[ "$RC" = 3 ] && ok || bad "a refused pre-plan exited $RC, not rc 3"
[ -f "$T/rp-sentinel.txt" ] && bad "a refused pre-plan ran anyway" || ok
[ -d "$T/plans/cromford-BH-1" ] \
  && bad "a refused pre-plan left a plans/ dir behind for run-build.sh to adopt" || ok
grep -q '\[hub-no-build\] refused preplan BH-1' "$T/logs/ALERTS.log" \
  && ok || bad "the pre-plan refusal is silent in ALERTS.log: $(cat "$T/logs/ALERTS.log")"
grep -q 'pre-plan refused' "$T/logs/preplan.log" \
  && ok || bad "the refusal is not in preplan.log, where the operator looks: $(cat "$T/logs/preplan.log")"
RC=$(run_rp)
[ "$(alerts)" = 1 ] \
  && ok || bad "preplan-tick firing twice wrote $(alerts) ALERTS lines, not one"
box box-small
RC=$(run_rp)
[ -f "$T/rp-sentinel.txt" ] && ok || bad "a pre-plan on box-small was stopped by the hub guard (rc $RC)"

# ═══ 5. bin/up10-lane.sh ════════════════════════════════════════════════════
run_up10() { # run_up10 [env assignments...] -- <args...> ; echoes rc, stdout in $T/up10.out
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  rm -f "$T/ssh-argv.txt" "$T/ssh-stdin.txt" "$T/gh-argv.txt" "$T/rb-argv.txt"
  ( export HARNESS="$T" PATH="$T/fakebin:$PATH" UP10_SSH="$T/fakebin/fakessh"
    env ${envs[@]+"${envs[@]}"} bash "$UP10" "$@" > "$T/up10.out" 2>"$T/up10.err" )
  echo $?
}

# 5a. from the hub: hop to the owning box, never a local path.
box box-hub
reset_alerts
RC=$(run_up10 -- demo-slug "$T/brief.txt")
[ "$RC" = 0 ] && ok || bad "the up10 ssh hop exited $RC: $(cat "$T/up10.err")"
grep -q '^root@10.0.0.13$' "$T/ssh-argv.txt" 2>/dev/null \
  && ok || bad "up10 did not ssh to the owning box's tailnet address: $(tr '\n' ' ' < "$T/ssh-argv.txt" 2>/dev/null)"
grep -q -- '--here demo-slug' "$T/ssh-argv.txt" 2>/dev/null \
  && ok || bad "the remote command is not the --here form: $(tr '\n' ' ' < "$T/ssh-argv.txt" 2>/dev/null)"
[ "$(cat "$T/ssh-stdin.txt" 2>/dev/null)" = "$(cat "$T/brief.txt")" ] \
  && ok || bad "the brief was not piped to the remote side"
[ -s "$T/gh-argv.txt" ] && bad "up10 on the hub talked to gh locally" || ok
[ -s "$T/rb-argv.txt" ] && bad "up10 on the hub launched a local build — the exact thing BH-393 forbids" || ok

# 5b. --here on the hub: refused, and NOT overridable.
for E in HUB_BUILD_OK=0 HUB_BUILD_OK=1; do
  reset_alerts
  RC=$(run_up10 "$E" -- --here demo-slug "$T/brief.txt")
  [ "$RC" = 77 ] && ok || bad "up10 --here on the hub with $E exited $RC, not the refusal rc 77"
  grep -q '\[hub-no-build\] refused up10 demo-slug' "$T/logs/ALERTS.log" \
    && ok || bad "up10 --here on the hub with $E refused silently: $(cat "$T/logs/ALERTS.log")"
  # ...and it must not tell the operator to set a knob that will not help.
  grep -q 'HUB_BUILD_OK=1 overrides' "$T/logs/ALERTS.log" \
    && bad "the up10 refusal advertises HUB_BUILD_OK=1 as an override it does not have: $(cat "$T/logs/ALERTS.log")" || ok
  grep -q 'up10-lane.sh <slug> <brief-file>' "$T/logs/ALERTS.log" \
    && ok || bad "the up10 refusal does not say what to run instead: $(cat "$T/logs/ALERTS.log")"
  [ -s "$T/gh-argv.txt" ] && bad "a refused up10 ($E) still filed a GitHub issue" || ok
  [ -s "$T/rb-argv.txt" ] && bad "a refused up10 ($E) still launched a build on the hub" || ok
done

# 5c. --here on the owning box: file the ai-build issue, launch the ordinary pipeline.
box box-small
reset_alerts
printf '[]\n' > "$T/stub-gh-issue-list"
RC=$(run_up10 -- --here demo-slug "$T/brief.txt")
IFS= read -r -t 20 _ <> "$T/rb.fifo" \
  && ok || bad "run-build.sh was never launched on the owning box (rc $RC): $(cat "$T/up10.err")"
grep -q -- '--label ai-build' "$T/gh-argv.txt" 2>/dev/null \
  && ok || bad "the up10 issue was not filed with the ai-build label: $(cat "$T/gh-argv.txt" 2>/dev/null)"
grep -q -- '--title up10: demo-slug' "$T/gh-argv.txt" 2>/dev/null \
  && ok || bad "the up10 issue title is not 'up10: <slug>': $(cat "$T/gh-argv.txt" 2>/dev/null)"
[ "$(cat "$T/rb-argv.txt" 2>/dev/null)" = "cromford 42 BH-42" ] \
  && ok || bad "run-build.sh was launched with the wrong argv: $(cat "$T/rb-argv.txt" 2>/dev/null)"
grep -q '^LAUNCHED BH-42' "$T/up10.out" \
  && ok || bad "up10 did not report what it launched, at the rung it launched it: $(cat "$T/up10.out")"
[ "$(alerts)" = 0 ] && ok || bad "a legitimate up10 run on the owning box wrote a hub refusal"

# 5d. the issue already exists: dedupe on the title, never a second issue.
printf '[{"number":42,"title":"up10: demo-slug"}]\n' > "$T/stub-gh-issue-list"
RC=$(run_up10 -- --here demo-slug "$T/brief.txt")
IFS= read -r -t 20 _ <> "$T/rb.fifo" \
  && ok || bad "the dedupe path did not launch a build for the existing issue (rc $RC): $(cat "$T/up10.err")"
grep -q 'issue create' "$T/gh-argv.txt" 2>/dev/null \
  && bad "a second up10 run filed a duplicate issue: $(cat "$T/gh-argv.txt")" || ok
[ "$(cat "$T/rb-argv.txt" 2>/dev/null)" = "cromford 42 BH-42" ] \
  && ok || bad "the dedupe path launched the wrong ticket: $(cat "$T/rb-argv.txt" 2>/dev/null)"
printf '[]\n' > "$T/stub-gh-issue-list"

# 5d-bis. a gh read that did NOT answer is not "no issue open". Treating it as
# one files a duplicate issue on every retry.
printf '1\n' > "$T/stub-gh-list-rc"
RC=$(run_up10 -- --here demo-slug "$T/brief.txt")
[ "$RC" = 2 ] && ok || bad "a failed 'gh issue list' exited $RC, not 2 — an unanswered read must not read as 'nothing open'"
grep -q 'issue create' "$T/gh-argv.txt" 2>/dev/null \
  && bad "a failed dedupe read still filed an issue: $(cat "$T/gh-argv.txt")" || ok
[ -s "$T/rb-argv.txt" ] && bad "a failed dedupe read still launched a build" || ok
printf '0\n' > "$T/stub-gh-list-rc"

# 5d-ter. the owning box IS the hub, under a name that is not "local". Column 6
# saying box-hub (or HUB_BOX_NAME) makes LOCAL = TARGET on the hub, and
# the shortcut past the ssh hop would then run the local path there — the
# incident this file exists to stop. Refuse by identity, from any box, without
# touching gh, run-build or ssh.
for BOXNAME in box-hub box-small; do
  reset_alerts
  printf 'box-hub\n' > "$T/stub-box-for"
  box "$BOXNAME"
  RC=$(run_up10 -- demo-slug "$T/brief.txt")
  [ "$RC" = 2 ] \
    && ok || bad "box-for naming the hub (box-hub) on $BOXNAME exited $RC, not 2"
  [ -s "$T/rb-argv.txt" ] \
    && bad "up10 launched a local build when the owning box resolved to the hub — the exact thing BH-393 forbids" || ok
  [ -s "$T/gh-argv.txt" ] && bad "up10 filed a GitHub issue for a hub-owned cromford on $BOXNAME" || ok
  [ -s "$T/ssh-argv.txt" ] \
    && bad "up10 hopped to the hub instead of refusing on $BOXNAME — the refusal must not need an ssh to happen" || ok
  grep -q 'owned by the hub' "$T/logs/ALERTS.log" \
    && ok || bad "the hub-owned refusal on $BOXNAME is silent in ALERTS.log: $(cat "$T/logs/ALERTS.log")"
done
# ...and the same for an operator-renamed hub, the name only HUB_BOX_NAME knows.
reset_alerts
printf 'hub-alias\n' > "$T/stub-box-for"
box hub-alias
RC=$(run_up10 HUB_BOX_NAME=hub-alias -- demo-slug "$T/brief.txt")
[ "$RC" = 2 ] && ok || bad "box-for naming the hub as HUB_BOX_NAME=hub-alias exited $RC, not 2"
[ -s "$T/rb-argv.txt" ] && bad "a renamed hub still ran the up10 local path" || ok
[ -s "$T/ssh-argv.txt" ] && bad "a renamed hub still hopped for up10" || ok

# 5d-quater. a half-synced box, no lib beside the script and none under
# $HARNESS/bin. agent-call fails OPEN there; up10 is the deliberate exception,
# so its own fallback has to know the same three hub names the lib does.
mkdir -p "$T/nolib-up10/bin2" "$T/nolib-up10/bin" "$T/nolib-up10/logs" \
         "$T/nolib-up10/state" "$T/nolib-up10/flags" "$T/nolib-up10/tmp"
cp "$UP10" "$T/nolib-up10/bin2/up10-lane.sh"
cp "$T/bin/box-for.sh" "$T/bin/fleet-conf.sh" "$T/bin/run-build.sh" "$T/nolib-up10/bin/"
printf 'hub-alias\n' > "$T/nolib-up10/state/box-name"
rm -f "$T/ssh-argv.txt" "$T/gh-argv.txt" "$T/rb-argv.txt"
RC=$( ( export HARNESS="$T/nolib-up10" PATH="$T/fakebin:$PATH" \
               UP10_SSH="$T/fakebin/fakessh" HUB_BOX_NAME=hub-alias
        bash "$T/nolib-up10/bin2/up10-lane.sh" demo-slug "$T/brief.txt" >/dev/null 2>&1 ); echo $? )
[ "$RC" = 2 ] \
  && ok || bad "with no lib, box-for naming the hub (HUB_BOX_NAME=hub-alias) exited $RC, not 2"
[ -s "$T/rb-argv.txt" ] && bad "with no lib, up10 ran the local path on the hub" || ok
[ -s "$T/ssh-argv.txt" ] && bad "with no lib, up10 hopped instead of refusing" || ok
grep -q 'owned by the hub' "$T/nolib-up10/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the no-lib hub-owned refusal wrote no ALERTS line: $(cat "$T/nolib-up10/logs/ALERTS.log" 2>/dev/null)"
printf 'box-small\n' > "$T/stub-box-for"

# 5e. fail CLOSED: an unknown box, an unknown address, an empty brief.
box box-hub
printf '\n' > "$T/stub-tailnet-ip"
RC=$(run_up10 -- demo-slug "$T/brief.txt")
[ "$RC" = 2 ] && ok || bad "an unresolvable tailnet address exited $RC, not 2 — 'root@' is a hang, not an error"
[ -s "$T/ssh-argv.txt" ] && bad "up10 ssh'd to an empty target" || ok
printf '10.0.0.13\n' > "$T/stub-tailnet-ip"
printf '\n' > "$T/stub-box-for"
RC=$(run_up10 -- demo-slug "$T/brief.txt")
[ "$RC" = 2 ] && ok || bad "an empty box-for answer exited $RC, not 2"
[ -s "$T/ssh-argv.txt" ] && bad "up10 ssh'd with no owning box resolved" || ok
printf 'local\n' > "$T/stub-box-for"
RC=$(run_up10 -- demo-slug "$T/brief.txt")
[ "$RC" = 2 ] && ok || bad "box-for saying 'local' (the hub) exited $RC, not 2"
printf 'box-small\n' > "$T/stub-box-for"
RC=$(run_up10 -- demo-slug "$T/empty-brief.txt")
[ "$RC" = 2 ] && ok || bad "an empty brief exited $RC, not 2"
[ -s "$T/ssh-argv.txt" ] && bad "an empty brief still reached ssh" || ok

# ═══ 6. bin/orchestrate.sh's instructions name the only allowed entry ═══════
# The turn itself cannot be driven without Telegram, so this is a source pin —
# guarded so an absent symbol fails instead of passing on a count of zero.
N=$(grep -c 'up10-lane.sh' "$DIR/bin/orchestrate.sh" 2>/dev/null || true); N=${N:-0}
[ "$N" -ge 2 ] \
  && ok || bad "bin/orchestrate.sh names up10-lane.sh $N time(s); both the normal-lane prompt and SURVIVAL_BRIEF must name it"

echo "hub-no-build-lanes-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
