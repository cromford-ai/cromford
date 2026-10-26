#!/bin/bash
# tests/prompt-render.bh-7971-test.sh — BH-7971 (BH-7940.3): the hub renders the
# resolved prompts into state/prompts/, fleet-propagate pushes them to the
# boxes, and a fleet `rules` head becomes the box ~/.claude/CLAUDE.md.
#
# bin/prompt-render.sh runs over real curl against the REAL jobs worker on
# 127.0.0.1 (tests/lib/prompts-worker.bh-7969.mjs, node:sqlite). Each case
# starts its own worker (the worker exits on its own after 120 s) and its own
# scratch HARNESS, so no case reads another's data. No call leaves the box.
#
# Cases: resolve-_fleet render-writes-seven unchanged-no-rewrite
# worker-down-keeps-old fleet-rules-to-_fleet project-rules-file
# head-dropped-removes rc4-skipped no-jobs-url-noop canon-table
# update-runners-prefers-fleet-rules sync-apply-prefers-fleet-rules
# drift-probe-follows-fleet-rules propagate-pushes-on-change
# propagate-retries-failed-box propagate-no-prompts-dir bad-knob-falls-back
# round-trip
# Run from anywhere: tests/prompt-render.bh-7971-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "prompt-render.bh-7971: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

RENDER="$DIR/bin/prompt-render.sh"
RESOLVE="$DIR/bin/prompt-resolve.sh"
SRV="$DIR/tests/lib/prompts-worker.bh-7969.mjs"
SECRET=sec-fixture-7971
KINDS="rules watcher plan execute review fix-round qa"

PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# start <name> — start a worker; sets URL_<name>.
start() {
  local name=$1
  rm -f "$T/$name.port"; : > "$T/$name.count"
  node "$SRV" "$SECRET" "$T/$name.port" "$T/$name.count" 2>"$T/$name.err" &
  PIDS+=($!)
  local i
  for i in $(seq 1 100); do
    [ -s "$T/$name.port" ] && break
    kill -0 "${PIDS[-1]}" 2>/dev/null || break
    sleep 0.1
  done
  if [ ! -s "$T/$name.port" ]; then
    wait "${PIDS[-1]}"; local rc=$?
    if [ "$rc" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
    bad "worker $name did not start (rc $rc): $(head -3 "$T/$name.err")"; done_
  fi
  printf -v "URL_$name" 'http://127.0.0.1:%s' "$(cat "$T/$name.port")"
}

# post <url> <scope> <kind> <project|-> <body file> — save a version; prints its id.
post() {
  local q=""; [ "$4" = - ] || q="?project=$4"
  jq -n --rawfile b "$5" '{body:$b, author:"fixture-author"}' > "$T/post.json"
  curl -sS -H "authorization: Bearer $SECRET" -H 'content-type: application/json' \
    --data-binary @"$T/post.json" "$1/api/prompts/$2/$3$q" | jq -r '.id'
}

# The scratch checkout: the repo rules, every stage template and two watcher
# prompts. demo-z has no prompts/demo-z.md, so its watcher resolves to rc 4.
CK="$T/checkout"
mkdir -p "$CK/rules" "$CK/prompts/stages"
printf 'repo rules\nline two\n' > "$CK/rules/CLAUDE.md"
printf 'repo rtk\n' > "$CK/rules/RTK.md"
printf '{"repo":true}\n' > "$CK/rules/settings.json"
for k in plan execute review fix-round qa; do printf 'repo stage %s ${KEY}\n' "$k" > "$CK/prompts/stages/$k.md"; done
printf 'repo watcher demo-x\n' > "$CK/prompts/demo-x.md"
printf 'repo watcher demo-y\n' > "$CK/prompts/demo-y.md"

# mkh <name> <project...> — a scratch HARNESS with a fleet.conf of these projects.
mkh() {
  local h="$T/$1" p; shift
  mkdir -p "$h/logs" "$h/state" "$h/bin"
  # bin/alert-line.sh, stubbed: its last step is the ALERTS.log append; the
  # beat it also sends is a jobs call this suite must not make.
  printf '#!/bin/bash\nwhile [ "${1#--}" != "$1" ]; do shift 2; done\necho "$(date -u +%%FT%%TZ) $*" >> "$HARNESS/logs/ALERTS.log"\n' > "$h/bin/alert-line.sh"
  chmod +x "$h/bin/alert-line.sh"
  : > "$h/fleet.conf"
  for p in "$@"; do printf '%s Acme/%s - - 2 local 127.0.0.1\n' "$p" "$p" >> "$h/fleet.conf"; done
  printf '%s' "$h"
}
# render <harness> <url> — one bin/prompt-render.sh run; rc to RC.
render() {
  JOBS_URL="$2" HARNESS_SECRET="$SECRET" HARNESS="$1" HARNESS_CHECKOUT="$CK" FLEET_CONF="$1/fleet.conf" \
    "$RENDER" > "$T/render.out" 2>&1
  RC=$?
}
tree_sum() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) | sha256sum; }
[ -x "$RENDER" ] || bad "bin/prompt-render.sh is missing or not executable"

# ── resolve-_fleet ───────────────────────────────────────────────────────────
start rf
printf 'fleet rules body\n' > "$T/fleet-rules"
printf 'demo-x project rules\n' > "$T/proj-rules"
FID=$(post "$URL_rf" fleet rules - "$T/fleet-rules")
post "$URL_rf" project rules demo-x "$T/proj-rules" >/dev/null
JOBS_URL="$URL_rf" HARNESS_SECRET="$SECRET" PROMPT_RESOLVE_ROOT="$CK" "$RESOLVE" _fleet rules > "$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && cmp -s "$T/out" "$T/fleet-rules" && ok || bad "resolve-_fleet: rc $RC '$(cat "$T/out")' ($(cat "$T/err"))"
JOBS_URL="$URL_rf" HARNESS_SECRET="$SECRET" PROMPT_RESOLVE_ROOT="$CK" "$RESOLVE" _fleet rules --source > "$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "rules fleet v1 $FID" ] && ok || bad "resolve-_fleet --source: rc $RC '$(cat "$T/out")'"
# The project head on demo-x still wins for demo-x and never for _fleet.
JOBS_URL="$URL_rf" HARNESS_SECRET="$SECRET" PROMPT_RESOLVE_ROOT="$CK" "$RESOLVE" demo-x rules > "$T/out" 2>/dev/null
cmp -s "$T/out" "$T/proj-rules" && ok || bad "resolve-_fleet: demo-x lost its project head"
JOBS_URL="$URL_rf" HARNESS_SECRET="$SECRET" PROMPT_RESOLVE_ROOT="$CK" "$RESOLVE" _fleet plan --source > "$T/out" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "plan repo v0 -" ] && ok || bad "resolve-_fleet plan: rc $RC '$(cat "$T/out")'"
# watcher has no fleet scope: usage, as tests/prompt-resolve.bh-7940-test.sh pins.
JOBS_URL="$URL_rf" HARNESS_SECRET="$SECRET" PROMPT_RESOLVE_ROOT="$CK" "$RESOLVE" _fleet watcher > "$T/out" 2>/dev/null; RC=$?
[ "$RC" = 2 ] && [ ! -s "$T/out" ] && ok || bad "resolve-_fleet watcher: rc $RC (want 2)"
[ -f "$T/rf.count" ] && [ "$(wc -l < "$T/rf.count")" -ge 1 ] && ok || bad "resolve-_fleet: the worker saw no list call"

# ── render-writes-seven ──────────────────────────────────────────────────────
start rw
printf 'review head ${KEY}\nno newline at end' > "$T/review-body"
RID=$(post "$URL_rw" project review demo-x "$T/review-body")
H1=$(mkh h1 demo-x)
render "$H1" "$URL_rw"
S1="$H1/state/prompts/demo-x"
[ "$RC" = 0 ] && ok || bad "render-writes-seven: rc $RC ($(cat "$T/render.out"))"
cmp -s "$S1/review.md" "$T/review-body" && ok || bad "render-writes-seven: review.md is not the head body"
[ "$(wc -l < "$S1/sources.tsv" 2>/dev/null)" = 7 ] && ok || bad "render-writes-seven: sources.tsv has $(wc -l < "$S1/sources.tsv" 2>/dev/null) lines (want 7)"
grep -qx "review project v1 $RID" "$S1/sources.tsv" 2>/dev/null && ok || bad "render-writes-seven: no 'review project v1 $RID' line"
grep -qx "plan repo v0 -" "$S1/sources.tsv" 2>/dev/null && ok || bad "render-writes-seven: no 'plan repo v0 -' line"
[ ! -e "$S1/plan.md" ] && [ ! -e "$S1/rules.md" ] && ok || bad "render-writes-seven: a repo-source kind file was written"
[ "$(cut -d' ' -f1 "$S1/sources.tsv" 2>/dev/null | tr '\n' ' ')" = "$KINDS " ] && ok || bad "render-writes-seven: kinds out of order: $(cut -d' ' -f1 "$S1/sources.tsv" 2>/dev/null | tr '\n' ' ')"
[ ! -e "$H1/state/prompts/_fleet/rules.md" ] && ok || bad "render-writes-seven: _fleet/rules.md written with no fleet head"
grep -q 'projects=1 written=2 removed=0 unchanged=0 down=0' "$H1/logs/prompt-render.log" 2>/dev/null && ok \
  || bad "render-writes-seven: summary line: $(tail -1 "$H1/logs/prompt-render.log" 2>/dev/null)"
# One list call per project per run (the per-run cache), plus one for _fleet.
[ "$(wc -l < "$T/rw.count")" = 2 ] && ok || bad "render-writes-seven: $(wc -l < "$T/rw.count") list calls (want 2)"

# ── unchanged-no-rewrite ─────────────────────────────────────────────────────
touch -d '2020-01-02 03:04:05' "$S1/review.md" "$S1/sources.tsv"
OLD=$(date -d '2020-01-02 03:04:05' +%s)
render "$H1" "$URL_rw"
[ "$(stat -c %Y "$S1/review.md")" = "$OLD" ] && [ "$(stat -c %Y "$S1/sources.tsv")" = "$OLD" ] && ok \
  || bad "unchanged-no-rewrite: a file was rewritten (mtime $(stat -c %Y "$S1/review.md") / $(stat -c %Y "$S1/sources.tsv"), want $OLD)"
grep -q 'written=0 removed=0 unchanged=2 down=0' "$H1/logs/prompt-render.log" && ok || bad "unchanged-no-rewrite: summary: $(tail -1 "$H1/logs/prompt-render.log")"
[ -z "$(find "$H1/state/prompts" -name '*.tmp')" ] && ok || bad "unchanged-no-rewrite: a .tmp file was left"
# A stray tmp from a killed run is removed.
: > "$S1/qa.md.tmp"; : > "$S1/sources.tsv.tmp"
render "$H1" "$URL_rw"
[ -z "$(find "$H1/state/prompts" -name '*.tmp')" ] && ok || bad "unchanged-no-rewrite: a stray .tmp survived the next run"

# ── fleet-rules-to-_fleet ────────────────────────────────────────────────────
start fr
FRID=$(post "$URL_fr" fleet rules - "$T/fleet-rules")
H2=$(mkh h2 demo-x)
render "$H2" "$URL_fr"
cmp -s "$H2/state/prompts/_fleet/rules.md" "$T/fleet-rules" && ok || bad "fleet-rules-to-_fleet: _fleet/rules.md is not the fleet body"
[ ! -e "$H2/state/prompts/demo-x/rules.md" ] && ok || bad "fleet-rules-to-_fleet: demo-x/rules.md written for a fleet head"
grep -qx "rules fleet v1 $FRID" "$H2/state/prompts/demo-x/sources.tsv" && ok || bad "fleet-rules-to-_fleet: no 'rules fleet v1 $FRID' line"
# A fleet head on a stage kind is written to the project file.
printf 'fleet plan body\n' > "$T/fleet-plan"
post "$URL_fr" fleet plan - "$T/fleet-plan" >/dev/null
render "$H2" "$URL_fr"
cmp -s "$H2/state/prompts/demo-x/plan.md" "$T/fleet-plan" && ok || bad "fleet-rules-to-_fleet: a fleet plan head was not written to demo-x/plan.md"

# ── project-rules-file ───────────────────────────────────────────────────────
post "$URL_fr" project rules demo-x "$T/proj-rules" >/dev/null
render "$H2" "$URL_fr"
cmp -s "$H2/state/prompts/demo-x/rules.md" "$T/proj-rules" && ok || bad "project-rules-file: demo-x/rules.md is not the project body"
cmp -s "$H2/state/prompts/_fleet/rules.md" "$T/fleet-rules" && ok || bad "project-rules-file: _fleet/rules.md lost the fleet head"

# ── head-dropped-removes ─────────────────────────────────────────────────────
start hd
H3=$(mkh h3 demo-x)
mkdir -p "$H3/state/prompts/demo-x" "$H3/state/prompts/_fleet" "$H3/state/prompts/gone-proj"
printf 'stale\n' > "$H3/state/prompts/demo-x/plan.md"
printf 'stale rules\n' > "$H3/state/prompts/demo-x/rules.md"
printf 'stale fleet\n' > "$H3/state/prompts/_fleet/rules.md"
printf 'stale\n' > "$H3/state/prompts/gone-proj/review.md"
render "$H3" "$URL_hd"
[ ! -e "$H3/state/prompts/demo-x/plan.md" ] && ok || bad "head-dropped-removes: demo-x/plan.md kept"
[ ! -e "$H3/state/prompts/demo-x/rules.md" ] && ok || bad "head-dropped-removes: demo-x/rules.md kept"
[ ! -e "$H3/state/prompts/_fleet/rules.md" ] && ok || bad "head-dropped-removes: _fleet/rules.md kept"
[ ! -e "$H3/state/prompts/gone-proj" ] && ok || bad "head-dropped-removes: a project dir not in fleet.conf kept"
[ -s "$H3/state/prompts/demo-x/sources.tsv" ] && ok || bad "head-dropped-removes: demo-x/sources.tsv missing"
grep -q 'removed=4' "$H3/logs/prompt-render.log" && ok || bad "head-dropped-removes: summary: $(tail -1 "$H3/logs/prompt-render.log")"
# An empty project list (unreadable registry) removes no project dir.
mkdir -p "$H3/state/prompts/gone-proj"; printf 'x\n' > "$H3/state/prompts/gone-proj/review.md"
: > "$H3/fleet.conf"
render "$H3" "$URL_hd"
[ -f "$H3/state/prompts/gone-proj/review.md" ] && ok || bad "head-dropped-removes: an empty project list removed a project dir"

# ── rc4-skipped ──────────────────────────────────────────────────────────────
H4=$(mkh h4 demo-z)
render "$H4" "$URL_hd"
S4="$H4/state/prompts/demo-z/sources.tsv"
[ "$(wc -l < "$S4" 2>/dev/null)" = 6 ] && ok || bad "rc4-skipped: sources.tsv has $(wc -l < "$S4" 2>/dev/null) lines (want 6)"
! grep -q '^watcher ' "$S4" 2>/dev/null && ok || bad "rc4-skipped: a watcher line was written"
[ ! -s "$H4/logs/ALERTS.log" ] && ok || bad "rc4-skipped: an alert was written: $(cat "$H4/logs/ALERTS.log")"

# ── worker-down-keeps-old ────────────────────────────────────────────────────
PS=(); for i in $(seq -w 1 20); do PS+=("demo-p$i"); done
H5=$(mkh h5 "${PS[@]}")
for p in "${PS[@]}"; do
  mkdir -p "$H5/state/prompts/$p"
  printf 'old review %s\n' "$p" > "$H5/state/prompts/$p/review.md"
  printf 'review project v1 7\n' > "$H5/state/prompts/$p/sources.tsv"
done
mkdir -p "$H5/state/prompts/_fleet"; printf 'old fleet\n' > "$H5/state/prompts/_fleet/rules.md"
BEFORE=$(tree_sum "$H5/state/prompts")
CLOSED=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
render "$H5" "http://127.0.0.1:$CLOSED"
[ "$RC" = 0 ] && ok || bad "worker-down-keeps-old: rc $RC"
[ "$(tree_sum "$H5/state/prompts")" = "$BEFORE" ] && ok || bad "worker-down-keeps-old: a file changed"
[ "$(wc -l < "$H5/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "worker-down-keeps-old: ALERTS.log has $(wc -l < "$H5/logs/ALERTS.log" 2>/dev/null) lines (want 1)"
grep -q 'prompt-render: worker did not answer' "$H5/logs/ALERTS.log" 2>/dev/null && ok || bad "worker-down-keeps-old: alert text: $(cat "$H5/logs/ALERTS.log" 2>/dev/null)"
[ -f "$H5/state/prompt-render.down-since" ] && ok || bad "worker-down-keeps-old: no down marker"
render "$H5" "http://127.0.0.1:$CLOSED"
[ "$(wc -l < "$H5/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "worker-down-keeps-old: a second run alerted again"
[ "$(tree_sum "$H5/state/prompts")" = "$BEFORE" ] && ok || bad "worker-down-keeps-old: the second run changed a file"
grep -q 'down=1' "$H5/logs/prompt-render.log" && ok || bad "worker-down-keeps-old: no down=1 summary"
start wd
render "$H5" "$URL_wd"
[ ! -e "$H5/state/prompt-render.down-since" ] && ok || bad "worker-down-keeps-old: the marker stayed after the worker answered"
grep -q 'worker answered again' "$H5/logs/prompt-render.log" && ok || bad "worker-down-keeps-old: no 'worker answered again' line"
[ "$(wc -l < "$H5/logs/ALERTS.log")" = 2 ] && tail -1 "$H5/logs/ALERTS.log" | grep -q 'prompt-render: worker answered again' && ok \
  || bad "worker-down-keeps-old: the recovery did not resolve the alert: $(cat "$H5/logs/ALERTS.log")"

# ── no-jobs-url-noop ─────────────────────────────────────────────────────────
H6=$(mkh h6 demo-x)
mkdir -p "$H6/state/prompts/demo-x"; printf 'old\n' > "$H6/state/prompts/demo-x/review.md"
BEFORE=$(tree_sum "$H6/state")
render "$H6" ""
[ "$RC" = 0 ] && [ "$(tree_sum "$H6/state")" = "$BEFORE" ] && ok || bad "no-jobs-url-noop: rc $RC or state/ changed"
grep -q 'prompt-render: not configured' "$H6/logs/prompt-render.log" 2>/dev/null && ok || bad "no-jobs-url-noop: no 'not configured' line"
H6b=$(mkh h6b demo-x)
render "$H6b" ""
[ ! -e "$H6b/state/prompts" ] && ok || bad "no-jobs-url-noop: state/prompts/ was created"

# ── canon-table ──────────────────────────────────────────────────────────────
CANON_LIB="$DIR/bin/lib/rules-canon.sh"
if [ -r "$CANON_LIB" ] && . "$CANON_LIB"; then
  CH="$T/canon-h"
  canon_row() { # canon_row <label> <want fleet|repo> <setup...>
    local label=$1 want=$2 got gotsrc exp; shift 2
    [ -e "$CH" ] && { scratch_rm "$CH" || exit 1; }; mkdir -p "$CH/state/prompts/_fleet" "$CH/state/prompts/demo-x"
    eval "$*"
    got=$(rules_canon_path "$CH" "$CK"); gotsrc=$(rules_canon_source "$CH" "$CK")
    [ "$want" = fleet ] && exp="$CH/state/prompts/_fleet/rules.md" || exp="$CK/rules/CLAUDE.md"
    [ "$got" = "$exp" ] && [ "$gotsrc" = "$want" ] && ok || bad "canon-table $label: '$got' ($gotsrc), want $want"
  }
  canon_row non-empty fleet 'printf "x\n" > "$CH/state/prompts/_fleet/rules.md"'
  canon_row newline-only fleet 'printf "\n" > "$CH/state/prompts/_fleet/rules.md"'
  canon_row crlf fleet 'printf "a\r\nb\r\n" > "$CH/state/prompts/_fleet/rules.md"'
  canon_row no-file repo ':'
  canon_row empty-file repo ': > "$CH/state/prompts/_fleet/rules.md"'
  canon_row directory repo 'mkdir -p "$CH/state/prompts/_fleet/rules.md"; : > "$CH/state/prompts/_fleet/rules.md/x"'
  canon_row project-only repo 'printf "p\n" > "$CH/state/prompts/demo-x/rules.md"'
  canon_row tmp-only repo 'printf "t\n" > "$CH/state/prompts/_fleet/rules.md.tmp"'
else
  bad "canon-table: bin/lib/rules-canon.sh is missing or does not source"
fi

# Shared for the three canon readers below.
CH="$T/canon-live"; CD="$T/claude-dir"
mkdir -p "$CH/state/prompts/_fleet" "$CH/logs" "$CH/bin/lib" "$CD"
scratch_install_closure bin/lib/rules-canon.sh "$CH" >/dev/null || exit 1
printf 'FLEET RULES HEAD\n' > "$CH/state/prompts/_fleet/rules.md"
printf 'box local text\n' > "$CD/CLAUDE.local.md"
# expect <canon file> — the canon plus the box-local append, as every writer renders it.
expect() { cat "$1"; printf '\n\n<!-- box-specific, from %s -->\n\n' "$CD/CLAUDE.local.md"; cat "$CD/CLAUDE.local.md"; }

# ── update-runners-prefers-fleet-rules ───────────────────────────────────────
awk '/^# >>> machine rules/{f=1} f{print} /^# <<< machine rules/{exit}' "$DIR/bin/update-runners.sh" > "$T/ur-block.sh"
if grep -q 'RULES_CLAUDE_DIR' "$T/ur-block.sh" && grep -q '^# <<< machine rules' "$T/ur-block.sh"; then
  ur() { : > "$T/ur.log"; ( STAMP() { date -u +%FT%TZ; }; LOG="$T/ur.log"; HARNESS="$CH"; CHECKOUT="$CK"; RULES_CLAUDE_DIR="$CD"
         # shellcheck disable=SC1090
         . "$T/ur-block.sh" ); }
  ur
  expect "$CH/state/prompts/_fleet/rules.md" > "$T/want"
  cmp -s "$CD/CLAUDE.md" "$T/want" && ok || bad "update-runners: live is not fleet+local: $(head -2 "$CD/CLAUDE.md")"
  grep -q 'from fleet head' "$T/ur.log" && ok || bad "update-runners: log line does not name the fleet head: $(cat "$T/ur.log")"
  rm -f "$CH/state/prompts/_fleet/rules.md"; ur
  expect "$CK/rules/CLAUDE.md" > "$T/want"
  cmp -s "$CD/CLAUDE.md" "$T/want" && ok || bad "update-runners: no fleet file, live is not repo+local"
  grep -q 'from repo' "$T/ur.log" && ok || bad "update-runners: log line does not name the repo: $(cat "$T/ur.log")"
  : > "$CH/state/prompts/_fleet/rules.md"; ur
  cmp -s "$CD/CLAUDE.md" "$T/want" && ok || bad "update-runners: an empty fleet file was used"
else
  bad "update-runners: no '# >>> machine rules' block with RULES_CLAUDE_DIR in bin/update-runners.sh"
fi

# ── sync-apply-prefers-fleet-rules ───────────────────────────────────────────
rm -f "$CD/CLAUDE.md"
printf 'FLEET RULES HEAD v2\n' > "$CH/state/prompts/_fleet/rules.md"
RULES_CLAUDE_DIR="$CD" HARNESS="$CH" HARNESS_CHECKOUT="$CK" "$DIR/bin/sync-agent-rules.sh" apply > "$T/sa.out" 2>&1; RC=$?
expect "$CH/state/prompts/_fleet/rules.md" > "$T/want"
[ "$RC" = 0 ] && cmp -s "$CD/CLAUDE.md" "$T/want" && ok || bad "sync-apply: rc $RC, live is not fleet+local ($(cat "$T/sa.out"))"
rm -f "$CH/state/prompts/_fleet/rules.md"
RULES_CLAUDE_DIR="$CD" HARNESS="$CH" HARNESS_CHECKOUT="$CK" "$DIR/bin/sync-agent-rules.sh" apply > "$T/sa.out" 2>&1; RC=$?
expect "$CK/rules/CLAUDE.md" > "$T/want"
[ "$RC" = 0 ] && cmp -s "$CD/CLAUDE.md" "$T/want" && ok || bad "sync-apply: no fleet file, live is not repo+local ($(cat "$T/sa.out"))"

# ── drift-probe-follows-fleet-rules ──────────────────────────────────────────
cp "$CK/rules/RTK.md" "$CD/RTK.md"; cp "$CK/rules/settings.json" "$CD/settings.json"
printf 'FLEET RULES HEAD v3\n' > "$CH/state/prompts/_fleet/rules.md"
expect "$CH/state/prompts/_fleet/rules.md" > "$CD/CLAUDE.md"
drift() { : > "$CH/logs/ALERTS.log"; [ -e "$CH/state/rules-drift" ] && { scratch_rm "$CH/state/rules-drift" || exit 1; }
  HARNESS="$CH" HARNESS_CHECKOUT="$CK" RULES_DRIFT_BOXES=local RULES_DRIFT_CLAUDE_DIR="$CD" RULES_DRIFT_SELF_REPORT_FRESH_S=0 \
    "$DIR/bin/rules-drift-check.sh" > "$T/drift.out" 2>&1; RC=$?; }
drift
[ "$RC" = 0 ] && ! grep -q 'RULES DRIFT' "$CH/logs/ALERTS.log" && ok || bad "drift-probe: live = fleet render gave rc $RC: $(cat "$T/drift.out") $(cat "$CH/logs/ALERTS.log")"
# The repo render while a fleet head exists IS drift.
expect "$CK/rules/CLAUDE.md" > "$CD/CLAUDE.md"
drift
[ "$RC" = 1 ] && grep -q 'RULES DRIFT' "$CH/logs/ALERTS.log" && ok || bad "drift-probe: live = repo render with a fleet head gave rc $RC (want 1)"

# ── fleet-propagate fixture ──────────────────────────────────────────────────
# The shape of tests/fleet-propagate-test.sh: a scratch HARNESS with the real
# fleet-propagate.sh, fleet-conf.sh and box-for.sh, two boxes in fleet.conf,
# stubs for ssh, rsync, crontab, pgrep, harness-sync and lane-alert on
# FLEET_PROPAGATE_PATH, and a real scratch git origin + checkout. With no state
# file every tick is "up to date", so the prompts step is the only one that
# reaches a box.
PH="$T/ph"; PB="$T/pbin"
mkdir -p "$PH/bin" "$PH/logs" "$PH/state" "$PH/locks" "$PH/flags" "$PB"
cp "$DIR/bin/fleet-propagate.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$PH/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$PH" >/dev/null || exit 1
echo hub > "$PH/state/box-id"
cat > "$PH/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os - - 2 box-a 192.0.2.1
beta     Acme/beta     - - 4 box-b 192.0.2.2
EOF
cat > "$PB/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_CALLS"
echo "cafe123456789"; exit 0
EOF
cat > "$PB/rsync" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$RSYNC_CALLS"
for A in "$@"; do case "$A" in root@"${RSYNC_FAIL_IP:-none}":*) exit 1 ;; esac; done
exit 0
EOF
printf '#!/bin/bash\nexit 1\n' > "$PB/pgrep"
printf '#!/bin/bash\n[ "${1:-}" = -l ] && exit 0; exit 0\n' > "$PB/crontab"
printf '#!/bin/bash\necho synced; exit 0\n' > "$PH/bin/harness-sync.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$ALERTS"\n' > "$PH/bin/lane-alert.sh"
# The render stub: copy the test's source tree into state/prompts/ (and log it).
cat > "$PH/bin/prompt-render.sh" <<'EOF'
#!/bin/bash
echo render >> "$RENDER_CALLS"
[ -d "$PR_SRC" ] || exit 0
rm -rf "$HARNESS/state/prompts"; mkdir -p "$HARNESS/state/prompts"; cp -a "$PR_SRC/." "$HARNESS/state/prompts/"
EOF
printf '#!/bin/bash\necho "hub-apply HARNESS=$HARNESS" >> "$HUB_APPLY"\nexit 0\n' > "$PH/bin/sync-agent-rules.sh"
chmod +x "$PB"/* "$PH/bin"/*
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
echo readme > "$T/src/README.md"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/pcheckout"
PR_SRC="$T/prsrc"; mkdir -p "$PR_SRC/alpha-os"; printf 'review v1\n' > "$PR_SRC/alpha-os/review.md"
tick() { # tick [env assignments...] — one deploy-mode run
  : > "$T/rsync.calls"; : > "$T/ssh.calls"; : > "$T/hub.apply"; : > "$T/render.calls"; : > "$T/palerts"
  env "$@" HARNESS="$PH" HARNESS_CHECKOUT="$T/pcheckout" FLEET_PROPAGATE_PATH="$PB:/usr/bin:/bin:/usr/local/bin" \
    SSH_CALLS="$T/ssh.calls" RSYNC_CALLS="$T/rsync.calls" HUB_APPLY="$T/hub.apply" RENDER_CALLS="$T/render.calls" \
    ALERTS="$T/palerts" PR_SRC="$PR_SRC" "$PH/bin/fleet-propagate.sh" > "$T/tick.out" 2>&1
  TRC=$?
}
napply() { grep -c 'sync-agent-rules.sh apply' "$T/ssh.calls"; }

# ── propagate-pushes-on-change ───────────────────────────────────────────────
tick
[ "$TRC" = 0 ] && ok || bad "propagate: tick 1 rc $TRC ($(cat "$T/tick.out"))"
[ "$(wc -l < "$T/render.calls")" = 1 ] && ok || bad "propagate: tick 1 ran the render $(wc -l < "$T/render.calls") times"
[ "$(wc -l < "$T/rsync.calls")" = 2 ] && grep -q 'root@192.0.2.1:/root/harness/state/prompts/' "$T/rsync.calls" \
  && grep -q 'root@192.0.2.2:/root/harness/state/prompts/' "$T/rsync.calls" && ok || bad "propagate: tick 1 rsync calls: $(cat "$T/rsync.calls")"
grep -q -- '--delete' "$T/rsync.calls" && grep -q -- "--exclude=\*.tmp" "$T/rsync.calls" && ok || bad "propagate: rsync without --delete/--exclude=*.tmp: $(head -1 "$T/rsync.calls")"
[ "$(napply)" = 2 ] && grep -q -- '-n ' "$T/ssh.calls" && ok || bad "propagate: tick 1 box applies: $(cat "$T/ssh.calls")"
[ "$(wc -l < "$T/hub.apply")" = 1 ] && grep -q "HARNESS=$PH" "$T/hub.apply" && ok || bad "propagate: tick 1 hub applies: $(cat "$T/hub.apply")"
grep -q 'prompts: [0-9a-f]\{12\} pushed to 2/2 box(es)' "$PH/logs/fleet-propagate.log" && ok || bad "propagate: no 'pushed to 2/2' line: $(tail -3 "$PH/logs/fleet-propagate.log")"
tick
[ "$(wc -l < "$T/render.calls")" = 1 ] && ok || bad "propagate: tick 2 did not run the render"
[ ! -s "$T/rsync.calls" ] && [ "$(napply)" = 0 ] && [ ! -s "$T/hub.apply" ] && ok || bad "propagate: tick 2 with no change pushed: $(cat "$T/rsync.calls" "$T/hub.apply")"
printf 'review v2\n' > "$PR_SRC/alpha-os/review.md"
tick
[ "$(wc -l < "$T/rsync.calls")" = 2 ] && [ "$(napply)" = 2 ] && [ "$(wc -l < "$T/hub.apply")" = 1 ] && ok || bad "propagate: a changed file did not push to both boxes: $(cat "$T/rsync.calls")"
# A removed file is a change too (a head was dropped).
rm -f "$PR_SRC/alpha-os/review.md"
tick
[ "$(wc -l < "$T/rsync.calls")" = 2 ] && ok || bad "propagate: a removed file did not push"

# ── propagate-retries-failed-box ─────────────────────────────────────────────
printf 'review v3\n' > "$PR_SRC/alpha-os/review.md"
tick RSYNC_FAIL_IP=192.0.2.2
[ "$TRC" = 0 ] && ok || bad "retries: rc $TRC"
grep -q 'pushed to 1/2 box(es), failed: box-b' "$PH/logs/fleet-propagate.log" && ok || bad "retries: log: $(grep prompts: "$PH/logs/fleet-propagate.log" | tail -1)"
[ "$(napply)" = 1 ] && ok || bad "retries: a failed rsync still ran apply ($(napply) applies)"
tick
[ "$(wc -l < "$T/rsync.calls")" = 1 ] && grep -q 'root@192.0.2.2:' "$T/rsync.calls" && ok || bad "retries: the next tick did not push box b only: $(cat "$T/rsync.calls")"
[ ! -s "$T/hub.apply" ] && ok || bad "retries: the hub re-applied with no change"

# ── bad-knob-falls-back ──────────────────────────────────────────────────────
tick PROMPT_RENDER_TIMEOUT_S=abc PROMPT_PUSH_TIMEOUT_S=0
grep -q 'PROMPT_RENDER_TIMEOUT_S=abc is not a number of seconds — using 120' "$PH/logs/fleet-propagate.log" && ok || bad "bad-knob: no fallback line for PROMPT_RENDER_TIMEOUT_S"
grep -q 'PROMPT_PUSH_TIMEOUT_S=0 is not a number of seconds — using 60' "$PH/logs/fleet-propagate.log" && ok || bad "bad-knob: no fallback line for PROMPT_PUSH_TIMEOUT_S"
[ "$(wc -l < "$T/render.calls")" = 1 ] && ok || bad "bad-knob: the render did not run"

# ── propagate-no-prompts-dir ─────────────────────────────────────────────────
scratch_rm "$PR_SRC" || exit 1; scratch_rm "$PH/state/prompts" || exit 1
tick
[ "$TRC" = 0 ] && [ ! -s "$T/rsync.calls" ] && [ "$(napply)" = 0 ] && [ ! -s "$T/hub.apply" ] && ok || bad "no-prompts-dir: pushed with no state/prompts/: $(cat "$T/rsync.calls" "$T/ssh.calls")"
# No render script at all: the tick goes on as before.
rm -f "$PH/bin/prompt-render.sh"
tick
[ "$TRC" = 0 ] && [ ! -s "$T/render.calls" ] && [ ! -s "$T/rsync.calls" ] && ok || bad "no-prompts-dir: no render script, rc $TRC"
# --check writes and runs nothing of this step.
mkdir -p "$PR_SRC"; printf '#!/bin/bash\necho render >> "$RENDER_CALLS"\n' > "$PH/bin/prompt-render.sh"; chmod +x "$PH/bin/prompt-render.sh"
: > "$T/render.calls"
HARNESS="$PH" HARNESS_CHECKOUT="$T/pcheckout" FLEET_PROPAGATE_PATH="$PB:/usr/bin:/bin" RENDER_CALLS="$T/render.calls" \
  "$PH/bin/fleet-propagate.sh" --check > /dev/null 2>&1
[ ! -s "$T/render.calls" ] && ok || bad "no-prompts-dir: --check ran the render"

# ── round-trip ───────────────────────────────────────────────────────────────
start rt
printf 'RT review head for ${KEY}\n' > "$T/rt-body"
RTID=$(post "$URL_rt" project review demo-x "$T/rt-body")
H7=$(mkh h7 demo-x)
render "$H7" "$URL_rt"
if [ -r "$DIR/bin/lib/prompt-note.sh" ] && . "$DIR/bin/lib/prompt-note.sh"; then
  NOTE=$(prompt_note_lines demo-x "$H7" "$CK")
  grep -qx "PROMPT review: project v1 ($RTID)" <<<"$NOTE" && ok || bad "round-trip: the note does not name the head: $NOTE"
else
  bad "round-trip: bin/lib/prompt-note.sh is missing"
fi
# shellcheck source=bin/lib/stage-prompt.sh
. "$DIR/bin/lib/stage-prompt.sh" || exit 1
OUT=$(HARNESS="$H7" PROJECT=demo-x KEY=BH-1; sp_render review RT_OUT; printf '%s|%s' "$RT_OUT" "$SP_SOURCE_review")
[ "$OUT" = "RT review head for BH-1"$'\n'"|$H7/state/prompts/demo-x/review.md" ] && ok || bad "round-trip: sp_render gave '$OUT'"

done_
