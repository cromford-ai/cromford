#!/bin/bash
# tests/archie-fm-tracer.bh-4583-test.sh — BH-4583 (BH-4574.1): Archie's
# factory-manager tracer, driven through the SHIPPED bin/archie-fm.sh (the
# ticket's tests/archie-fm-tracer-test.sh, keyed to the ticket per house rule).
#
# THE WORLD IS A REAL GIT REPO. $T/origin.git is a bare remote with `main`, a
# parent branch ticket/bh-9001 (two commits, "parent 1" and "parent 2") and a
# child ticket/bh-9002 cut from the parent's tip with ONE commit of its own
# ("child own"). The parent is then SQUASH-merged into main, so the child still
# carries the two pre-squash commits: the exact state the playbook exists for.
# $T/repos/fixt is the hub clone (MC_REPOS). The repo carries a tiny
# bin/test-impact-gate.sh that logs to $T/suites.log and exits $T/suite.rc, so
# the lane's suite step runs a real script in the replayed tree. The lane runs
# it in a snapshot under env -i (afm_isolated), so the script carries $T as a
# literal and records its env and cwd in $T/suite.env / $T/suite.pwd. tick()
# passes ARCHIE_FM_SUITE_AS=self (the uid switch needs root + setpriv); AT8
# drives the nobody path against a setpriv that refuses.
#
# WHAT IS STUBBED, and only this. ARCHIE_FM_FIXTURE=$T/fx.sh (sandbox-only)
# replaces:
#   _jobs_req             a jq model of /api/settings/<key> and the three
#                         /api/archie/actions routes over $T/db.json, with the
#                         worker's status codes and _jobs_req's rc contract
#                         (0 2xx, 9 409, 2 404, 1 other); every request lands
#                         in $T/reqlog. The worker side of the same contract
#                         runs for real in worker/jobs/test/archie-actions.bh-4583.test.js;
#   gh_rest_pr_list_var   answers from $T/prs.json (logged to $T/ghrest.log);
#   mc_git_auth           MC_REMOTE=file://$T/origin.git, no token;
#   mc_hold_keeps_pr      held when $T/held exists;
#   hold_push_verdict     clear (the hold read is bin/lib/hold.sh's, not ours).
# bin/fleet-conf.sh is one project `fixt` -> acme/fixt, bin/alert-line.sh
# appends to $T/alerts.log. PATH carries a `gh` that logs to $T/gh.log: the
# REST retarget (`api -X PATCH repos/acme/fixt/pulls/2 -f base=main`) flips the
# base in $T/prs.json and writes `patch` to $T/order.log; anything else fails.
# A post-receive hook in origin.git writes `push` there, so the order of the
# two is read from one file. A `curl` that logs to $T/net.log and fails keeps
# everything offline.
#
# Cases: AT1 clean restack (+ the digest line), AT2 conflict, AT2b red suites,
# AT3 observe (+ per-project rows, off, junk), AT4 idempotent, AT5 guards,
# AT6 deferred / reclaim / failed (+ the base put back, and stranded), AT7
# no fork point (failed + one alert, BH-4784), AT8 suite isolation, AT9 the tick's deadline and its backstop, X
# mutations.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-tracer.bh-4583-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-fm-tracer: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-fm-tracer: flock is required"; exit 1; }

PASS=0; FAIL=0
# ARCHIE_FM_TEST_VERBOSE=1 prints one `ok: <case>` line per pass (the evidence
# a reviewer reads); without it only failures print.
ok()  { PASS=$((PASS+1)); [ "${ARCHIE_FM_TEST_VERBOSE:-}" = 1 ] && [ -n "${1:-}" ] && echo "ok: $1"; return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/archie-fm.sh" "$DIR/bin/lib/archie-fm.sh" "$DIR/worker/jobs/src/routes/archie-actions.js" \
         "$DIR/catalog/lanes.d/archie-fm.json" "$DIR/cron/lanes/725-archie-fm.cron"; do
  if [ -f "$f" ]; then ok "ships ${f#"$DIR"/}"; else bad "missing $f"; fi
done
if [ ! -f "$DIR/bin/archie-fm.sh" ] || [ ! -f "$DIR/bin/lib/archie-fm.sh" ]; then
  echo "archie-fm-tracer: $PASS passed, $FAIL failed"; exit 1
fi

NOW=1791184500                       # 2026-10-05T07:15:00Z, read once
DAY=2026-10-05
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
       GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
mkdir -p "$T/home" "$T/tmp"

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
: > "$H/env/global.env"
rm -f "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --projects) cat "$FXT/projects" 2>/dev/null || echo fixt ;;
  --*) ;;
  *) [ "${2:-}" = repo ] && echo "acme/$1" ;;
esac
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
SH
cp "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/gh.log"
if [ "${1:-} ${2:-} ${3:-}" = "api -X PATCH" ] && [ "${5:-}" = -f ]; then
  [ -f "$FXT/patch.refuse" ] && exit 1
  [ -f "$FXT/patch.refuse.second" ] && grep -q patch "$FXT/order.log" && exit 1
  n=${4##*/}; b=${6#base=}
  jq --argjson n "$n" --arg b "$b" 'map(if .number == $n then .base.ref = $b else . end)' "$FXT/prs.json" > "$FXT/prs.tmp" \
    && mv "$FXT/prs.tmp" "$FXT/prs.json"
  echo patch >> "$FXT/order.log"
  exit 0
fi
exit 1
SH
printf '#!/bin/bash\nprintf "curl %%s\\n" "$*" >> "$FXT/net.log"\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

# The worker, modelled in jq over $T/db.json: the same answers as
# worker/jobs/src/routes/archie-actions.js and the settings route.
cat > "$T/fx.sh" <<'SH'
fx_clock() { date -u -d "@$ARCHIE_FM_NOW" +%Y-%m-%dT%H:%M:%SZ; }
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 db="$FXT/db.json" key t
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/flags*|/api/lanes*) JOBS_HTTP=404; return 2 ;; esac
  [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/reqlog"
  t=$(fx_clock)
  qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
  case "$m ${p%%\?*}" in
    GET\ /api/settings/*)
      [ -f "$FXT/settings.down" ] && { JOBS_HTTP=503; return 1; }
      key=${p#/api/settings/}
      out=$(jq -c --arg k "$key" 'select(.settings | has($k)) | {setting: {key: $k, value: .settings[$k]}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; } ;;
    "POST /api/archie/actions")
      [ -f "$FXT/route.absent" ] && { JOBS_HTTP=404; return 2; }
      key=$(jq -r .dedupe_key <<<"$b")
      out=$(jq -c --arg k "$key" '.actions[] | select(.dedupe_key == $k)' "$db")
      if [ -z "$out" ]; then
        jq --argjson b "$b" --arg t "$t" '.actions += [$b + {id: ((.actions | length) + 1), day: $t[0:10], attempts: 1,
            evidence: ($b.evidence // {}), created_at: $t, updated_at: $t}]' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        out=$(jq -c --arg k "$key" '{ok: true, created: true, action: (.actions[] | select(.dedupe_key == $k))}' "$db"); code=201
      elif jq -e --argjson b "$b" '.project == $b.project and .repo == $b.repo and .pr == $b.pr and .playbook == $b.playbook and .mode == $b.mode' <<<"$out" >/dev/null; then
        out=$(jq -c '{ok: true, existing: true, action: .}' <<<"$out")
      else
        out=$(jq -c '{error: "different payload", action: .}' <<<"$out"); JOBS_HTTP=409; JOBS_BODY=$out; printf '%s' "$out"; return 9
      fi ;;
    "POST /api/archie/actions/outcome")
      out=$(jq -c --argjson b "$b" '.actions[] | select(.id == $b.id and .dedupe_key == $b.dedupe_key)' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; }
      if ! jq -e --argjson b "$b" '(.outcome + ">" + $b.outcome) as $tr
           | ["started>done","started>requested","started>would","started>deferred","started>failed","deferred>started","deferred>failed"]
           | index($tr) != null' <<<"$out" >/dev/null || ! jq -e --argjson b "$b" '.updated_at == $b.expect_updated_at' <<<"$out" >/dev/null; then
        out=$(jq -c '{error: "stale or illegal", action: .}' <<<"$out"); JOBS_HTTP=409; JOBS_BODY=$out; printf '%s' "$out"; return 9
      fi
      jq --argjson b "$b" --arg t "$t" '.actions |= map(if .id == $b.id then
          (if .outcome == "deferred" and $b.outcome == "started" then .attempts += 1 else . end)
          | .outcome = $b.outcome | .action = ($b.action // .action) | .why = ($b.why // .why)
          | .evidence = ($b.evidence // .evidence) | .updated_at = $t else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --argjson b "$b" '{ok: true, action: (.actions[] | select(.id == $b.id))}' "$db") ;;
    "GET /api/archie/actions")
      [ -f "$FXT/route.absent" ] && { JOBS_HTTP=404; return 2; }
      local d pb s cb; d=$(qp day); pb=$(qp playbook); s=$(qp summary); cb=$(qp count_by)
      out=$(jq -c --arg d "$d" --arg pb "$pb" --arg s "$s" --arg cb "$cb" '[.actions[] | select(.day == $d and ($pb == "" or .playbook == $pb))] as $r
        | if $s == "1" then {ok: true, day: $d, total: ($r | length),
             restacked: ([$r[] | select(.mode == "on" and .action == "restack" and .outcome == "done")] | length),
             fix_rounds: ([$r[] | select(.outcome == "requested")] | length),
             would: ([$r[] | select(.outcome == "would")] | length),
             deferred: ([$r[] | select(.outcome == "deferred")] | length),
             failed: ([$r[] | select(.outcome == "failed")] | length)}
          else {ok: true, day: $d, actions: $r,
             counts: (reduce $r[] as $x ({}; .[$x.playbook][$x.mode][if $cb == "action" then $x.action else $x.outcome end] += 1)),
             truncated: false} + (if $cb == "action" then {count_by: "action"} else {} end) end' "$db") ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
gh_rest_pr_list_var() {
  local v="$1" slug="$2" state="$3" head="${4:-}" out
  printf 'list %s %s %s\n' "$slug" "$state" "$head" >> "$FXT/ghrest.log"
  if [ -n "$head" ]; then
    [ -f "$FXT/parent.down" ] && { printf -v "$v" '%s' ''; GH_REST_STATUS=502; return 75; }
    out=$(jq -c --arg h "${head#*:}" --arg st "$state" '[.[] | select(.head.ref == $h and ($st == "all" or .state == $st))]' "$FXT/prs.json")
  elif [ "$slug" = acme/fixt ]; then
    out=$(jq -c --arg st "$state" '[.[] | select(.state == $st)]' "$FXT/prs.json")
  else
    out='[]'
  fi
  printf -v "$v" '%s' "$out"; GH_REST_STATUS=200; return 0
}
mc_git_auth() { MC_REMOTE="file://$FXT/origin.git"; export MC_GIT_TOKEN=fixture-token GIT_ASKPASS=/nonexistent/askpass; return 0; }
mc_hold_keeps_pr() { [ -f "$FXT/held" ]; }
. "$HARNESS/bin/lib/hold-push.sh"
hold_push_verdict() { [ -f "$FXT/hold.unreadable" ] && { printf 'unreadable\tfixture\n'; return 2; }; printf 'clear\tfixture\n'; return 0; }
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test \
       MC_REPOS="$T/repos" MC_REHYDRATE=0 TMPDIR="$T/tmp"
unset ARCHIE_FM_ENABLED ARCHIE_FM_RETRY_S ARCHIE_FM_MAX_ATTEMPTS ARCHIE_FM_SUITE_TIMEOUT_S ARCHIE_FM_PROJECTS_PER_TICK \
  ARCHIE_FM_NOW ARCHIE_FM_FIXTURE ARCHIE_FM_TIMED ARCHIE_FM_DEADLINE ARCHIE_FM_TICK_CEILING_S ARCHIE_FM_SUITE_AS 2>/dev/null || true

G() { git -C "$T/work" "$@" >/dev/null 2>&1; }
# world [clean|conflict|byhand] — a fresh repo, db, PR list and harness state.
world() {
  local v="${1:-clean}" p
  for p in origin.git repos work db.json reqlog gh.log ghrest.log order.log suites.log suite.rc alerts.log net.log projects \
           held hold.unreadable settings.down route.absent parent.down move.child patch.refuse patch.refuse.second suite.sleep suite.env suite.pwd \
           fakebin2 out rc; do
    scratch_rm "$T/$p" || exit 1
  done
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1
  scratch_rm "$H/logs/archie-fm.log" || exit 1; scratch_rm "$H/logs/merge-conductor.log" || exit 1
  mkdir -p "$T/work/src" "$T/work/bin" "$T/repos"
  git init -q -b main "$T/work"
  printf 'line one\nline two\n' > "$T/work/src/a.txt"
  { printf '#!/bin/bash\nFXT=%q\n' "$T"; cat <<'SH'; } > "$T/work/bin/test-impact-gate.sh"
echo "run $*" >> "$FXT/suites.log"
env > "$FXT/suite.env"; pwd > "$FXT/suite.pwd"
# a hung suite: it holds until the case removes suite.sleep, at most 30 s
if [ -f "$FXT/suite.sleep" ]; then
  for _ in $(seq 300); do [ -f "$FXT/suite.sleep" ] || break; sleep 0.1; done
  exit 1
fi
if [ -f "$FXT/move.child" ]; then
  d=$(mktemp -d)
  git clone -q "$FXT/origin.git" "$d" && git -C "$d" checkout -q ticket/bh-9002 \
    && echo moved > "$d/src/x.txt" && git -C "$d" add -A \
    && git -C "$d" -c user.name=someone -c user.email=someone@example.invalid commit -qm "someone else" \
    && git -C "$d" push -q origin ticket/bh-9002
  rm -rf "$d"
fi
exit "$(cat "$FXT/suite.rc" 2>/dev/null || echo 0)"
SH
  chmod +x "$T/work/bin/test-impact-gate.sh"
  G add -A; G commit -qm "base"
  G checkout -q -b ticket/bh-9001
  echo 1 > "$T/work/src/p.txt"; G add -A; G commit -qm "parent 1"
  echo 2 > "$T/work/src/p.txt"; G add -A; G commit -qm "parent 2"
  PHEAD=$(git -C "$T/work" rev-parse HEAD)
  G checkout -q -b ticket/bh-9002
  if [ "$v" = conflict ]; then
    printf 'line ONE from the child\nline two\n' > "$T/work/src/a.txt"
  else
    echo child > "$T/work/src/c.txt"
  fi
  G add -A; G commit -qm "child own"
  OWN=$(git -C "$T/work" rev-parse HEAD)
  G checkout -q main
  G merge --squash ticket/bh-9001; G commit -qm "BH-9001 squash"
  if [ "$v" = conflict ]; then
    printf 'line one, as main has it now\nline two\n' > "$T/work/src/a.txt"; G add -A; G commit -qm "main moves on"
  fi
  if [ "$v" = byhand ]; then
    G checkout -q -B ticket/bh-9002 main
    echo child > "$T/work/src/c.txt"; G add -A; G commit -qm "child own"
    G checkout -q main
  fi
  CHILD=$(git -C "$T/work" rev-parse ticket/bh-9002)
  git init -q --bare -b main "$T/origin.git"
  G push -q "$T/origin.git" main ticket/bh-9001 ticket/bh-9002
  printf '#!/bin/sh\necho push >> "%s/order.log"\n' "$T" > "$T/origin.git/hooks/post-receive"
  chmod +x "$T/origin.git/hooks/post-receive"
  git clone -q "$T/origin.git" "$T/repos/fixt"
  jq -n --arg c "$CHILD" --arg p "$PHEAD" '[
    {number: 2, state: "open", html_url: "https://github.com/acme/fixt/pull/2", merged_at: null,
     head: {ref: "ticket/bh-9002", sha: $c, repo: {full_name: "acme/fixt"}}, base: {ref: "ticket/bh-9001"}},
    {number: 1, state: "closed", html_url: "https://github.com/acme/fixt/pull/1", merged_at: "2026-10-05T06:00:00Z",
     head: {ref: "ticket/bh-9001", sha: $p, repo: {full_name: "acme/fixt"}}, base: {ref: "main"}},
    {number: 3, state: "open", html_url: "https://github.com/acme/fixt/pull/3", merged_at: null,
     head: {ref: "ticket/bh-9003", sha: "3333333333333333333333333333333333333333", repo: {full_name: "acme/fixt"}}, base: {ref: "main"}}]' > "$T/prs.json"
  jq -n '{settings: {"archie.manage": "on", "archie.cap.stacked-parent-merged": "20"}, actions: []}' > "$T/db.json"
  : > "$T/reqlog"; : > "$T/gh.log"; : > "$T/order.log"; : > "$T/suites.log"
}
setting() { jq --arg k "$1" --arg v "$2" '.settings[$k] = $v' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
tick() { # tick [VAR=value ...]  — one tick of the shipped lane at NOW
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FM_NOW="$NOW" ARCHIE_FM_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 ARCHIE_FM_SUITE_AS=self "$@" \
    bash "$H/bin/archie-fm.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
rows()   { jq '.actions | length' "$T/db.json"; }
row()    { jq -r --arg f "$1" '.actions[0] | getpath($f | split(".")) // "null" | tostring' "$T/db.json"; }
oref()   { git -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
refs()   { git -C "$T/origin.git" for-each-ref; git -C "$T/repos/fixt" for-each-ref; git -C "$T/repos/fixt" worktree list --porcelain; }
patches(){ grep -c '^api -X PATCH repos/acme/fixt/pulls/2 -f base=main$' "$T/gh.log"; }
posts()  { grep -c '^POST /api/archie/actions ' "$T/reqlog"; }
closes() { grep -c '^POST /api/archie/actions/outcome ' "$T/reqlog"; }
prstate(){ awk -F'\t' '$1 == "acme/fixt#2"' "$H/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
pid_of() { git -C "$T/origin.git" show "$1" 2>/dev/null | git patch-id --stable | cut -d' ' -f1; }
lastlog(){ tail -1 "$H/logs/archie-fm.log" 2>/dev/null; }

# ── assertion bundles, reused by the X mutations ────────────────────────────
# at1_world_ticked: a clean world, one tick in `on` mode. at1_own_only: the
# child on origin is main + exactly its own commit.
at1_world_ticked() { world clean; tick; }
at1_own_only() {
  [ "$(git -C "$T/origin.git" rev-list --count main..ticket/bh-9002)" = 1 ] \
    && [ "$(git -C "$T/origin.git" log -1 --format=%s ticket/bh-9002)" = "child own" ] \
    && [ "$(pid_of ticket/bh-9002)" = "$(pid_of "$OWN")" ]
}
# at3_observe_clean: one observe tick wrote ONE would row and nothing else.
at3_observe_clean() {
  local before ps
  world clean; setting archie.manage observe
  before=$(refs); ps=$(prstate)
  tick
  [ "$(refs)" = "$before" ] && [ "$(patches)" = 0 ] && [ ! -s "$T/suites.log" ] && [ "$(prstate)" = "$ps" ] \
    && [ "$(rows)" = 1 ] && [ "$(row mode)/$(row action)/$(row outcome)" = observe/would_restack/would ]
}
# at4_observe_second: a second observe tick on the same state closes nothing.
at4_observe_second() {
  local before
  at3_observe_clean || return 1
  before=$(refs); : > "$T/reqlog"
  tick
  [ "$(refs)" = "$before" ] && [ "$(rows)" = 1 ] && [ "$(posts)" = 1 ] && [ "$(closes)" = 0 ] \
    && [ "$(row outcome)" = would ]
}

# ── AT1: clean restack ───────────────────────────────────────────────────────
at1_world_ticked
check "AT1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "AT1 the child on origin is main + ONLY its own commit, patch-id identical ($(git -C "$T/origin.git" log --format=%s main..ticket/bh-9002 | tr '\n' '|'))" 'at1_own_only'
check "AT1 neither pre-squash parent commit rides along" \
  '! grep -q "^parent " <<<"$(git -C "$T/origin.git" log --format=%s main..ticket/bh-9002)"'
check "AT1 the new head sits on main" '[ "$(git -C "$T/origin.git" rev-parse ticket/bh-9002^)" = "$(oref main)" ]'
eq "AT1 exactly one retarget PATCH of pulls/2 to main" "$(patches)" 1
eq "AT1 the retarget precedes the push" "$(tr '\n' ' ' < "$T/order.log")" "patch push "
eq "AT1 the PR's base is now main" "$(jq -r '.[] | select(.number == 2) | .base.ref' "$T/prs.json")" main
eq "AT1 the suites ran once, against the target" "$(cat "$T/suites.log")" "run --base origin/main --head HEAD"
eq "AT1 exactly one archie_actions row" "$(rows)" 1
eq "AT1 the row" "$(row playbook) $(row mode) $(row action) $(row outcome)" "stacked-parent-merged on restack done"
eq "AT1 evidence old_head" "$(row evidence.old_head)" "$CHILD"
eq "AT1 evidence new_head = the origin tip" "$(row evidence.new_head)" "$(oref ticket/bh-9002)"
eq "AT1 evidence parent_pr" "$(row evidence.parent_pr)" 1
eq "AT1 evidence own_commits" "$(row evidence.own_commits)" 1
eq "AT1 the dedupe key" "$(row dedupe_key)" "stacked-parent-merged:acme/fixt#2:$CHILD:$PHEAD:on"
eq "AT1 the parent branch is untouched" "$(oref ticket/bh-9001)" "$PHEAD"
eq "AT1 main is untouched" "$(git -C "$T/origin.git" log -1 --format=%s main)" "BH-9001 squash"
eq "AT1 no worktree left on the hub clone" "$(git -C "$T/repos/fixt" worktree list | wc -l | tr -d ' ')" 1
check "AT1 the claim is the first write: POST create before outcome ($(cut -d' ' -f1,2 "$T/reqlog" | tr '\n' '|'))" \
  '[ "$(grep -n "^POST /api/archie/actions " "$T/reqlog" | head -1 | cut -d: -f1)" -lt "$(grep -n "^POST /api/archie/actions/outcome " "$T/reqlog" | head -1 | cut -d: -f1)" ]'
check "AT1 summary line: $(lastlog)" \
  'lastlog | grep -qE "^[^ ]+ projects=1 prs=2 stuck=1 unclassified=1 restacked=1 fix_rounds=0 would=0 deferred=0 skipped=0 failed=0 repaired=0$"'
# The only curl a tick makes is bin/lib/merge-conductor-lib.sh's own
# source-time GET /api/settings (the conductor lib's knob read, the resolver
# pays it too); nothing to GitHub and nothing to /api/archie leaves the stubs.
check "AT1 no GitHub or archie_actions traffic outside the stubs ($(grep -c . "$T/net.log" 2>/dev/null))" \
  '! grep -qE "github|/api/archie" "$T/net.log" 2>/dev/null'
# The digest line, from the fixture's own summary answer for the day.
SUMJ=$(ARCHIE_FM_NOW=$NOW bash -c ". '$T/fx.sh'; _jobs_req GET '/api/archie/actions?day=$DAY&summary=1'")
jq -n --arg d "$DAY" --argjson f "$SUMJ" '{day: $d, factory_manager: $f}' > "$T/digest.json"
DD=$(bash -c ". '$DIR/bin/lib/daily-digest-render.sh'; dd_render '$T/digest.json' https://console.test - 0 5 -")
eq "AT1 dd_render prints exactly ONE Factory manager line" "$(grep -c '^Factory manager: ' <<<"$DD")" 1
check "AT1 the digest line: $(grep '^Factory manager' <<<"$DD")" \
  'grep -qxF "Factory manager: 1 actions (1 restacked, 0 repaired, 0 fix rounds asked, 0 would-do in observe, 0 deferred, 0 failed) https://console.test/" <<<"$DD"'
jq -n --arg d "$DAY" '{day: $d, factory_manager: {ok: true, day: $d, total: 0, restacked: 0, fix_rounds: 0, would: 0, deferred: 0, failed: 0}}' > "$T/digest0.json"
check "AT1 a quiet day says no actions, never blank" \
  '[ "$(bash -c ". \"$DIR/bin/lib/daily-digest-render.sh\"; dd_render \"$T/digest0.json\" https://console.test - 0 5 -" | grep "^Factory manager")" = "Factory manager: no actions https://console.test/" ]'
jq -n --arg d "$DAY" '{day: $d}' > "$T/digestnone.json"
check "AT1 no .factory_manager key: no line at all" \
  '! bash -c ". \"$DIR/bin/lib/daily-digest-render.sh\"; dd_render \"$T/digestnone.json\" https://console.test - 0 5 -" | grep -q "^Factory manager"'

# ── AT4 (on): a second tick on the same state does nothing ──────────────────
BEFORE=$(refs); GHB=$(cat "$T/gh.log"); DBB=$(cat "$T/db.json"); : > "$T/reqlog"
tick
eq "AT4 refs unchanged" "$(refs)" "$BEFORE"
eq "AT4 gh.log unchanged" "$(cat "$T/gh.log")" "$GHB"
eq "AT4 db unchanged" "$(cat "$T/db.json")" "$DBB"
eq "AT4 no archie_actions POST in the second tick" "$(grep -c '^POST /api/archie/actions' "$T/reqlog")" 0

# ── AT2: the child's own commit conflicts ────────────────────────────────────
world conflict
tick
eq "AT2 the child on origin is byte-identical (no push)" "$(oref ticket/bh-9002)" "$CHILD"
check "AT2 nothing was pushed ($(cat "$T/order.log" | tr '\n' ' '))" '! grep -q push "$T/order.log"'
R=$(prstate)
eq "AT2 the conductor row is BLOCKED_HUMAN" "$(cut -f2 <<<"$R")" BLOCKED_HUMAN
REASON=$(cut -f7 <<<"$R")
check "AT2 the park reason ($REASON)" '[[ $REASON == "conflict-unresolvable: stacked child of parent=#1 (https://github.com/acme/fixt/pull/1)"* ]] && [[ $REASON == *src/a.txt*"(archie-fm)" ]]'
check "AT2 the reason is a resolver hand-off (mc_handoff_owns)" \
  'bash -c ". \"$DIR/bin/lib/merge-conductor-lib.sh\" >/dev/null 2>&1; mc_handoff_owns \"\$1\"" _ "$REASON"'
eq "AT2 exactly one row" "$(rows)" 1
eq "AT2 the row" "$(row action) $(row outcome)" "fix_round requested"
check "AT2 the conflict path is in evidence" 'jq -e ".actions[0].evidence.conflicts | index(\"src/a.txt\")" "$T/db.json" >/dev/null'
eq "AT2 the suites never ran on a conflict" "$(wc -l < "$T/suites.log" | tr -d ' ')" 0
eq "AT2 no worktree left under the hub clone" "$(git -C "$T/repos/fixt" worktree list | wc -l | tr -d ' ')" 1
check "AT2 summary counts the fix round: $(lastlog)" 'lastlog | grep -q " restacked=0 fix_rounds=1 "'
PSB=$(cat "$H/state/merge-conductor/pr-state.tsv"); : > "$T/reqlog"
tick
eq "AT4 (conflict) the second tick writes no second park" "$(cat "$H/state/merge-conductor/pr-state.tsv")" "$PSB"
eq "AT4 (conflict) row count still 1" "$(rows)" 1
eq "AT4 (conflict) no archie_actions POST" "$(grep -c '^POST /api/archie/actions' "$T/reqlog")" 0

# ── AT2b: red suites ─────────────────────────────────────────────────────────
world clean; echo 1 > "$T/suite.rc"
tick
eq "AT2b no push" "$(oref ticket/bh-9002)" "$CHILD"
REASON=$(cut -f7 <<<"$(prstate)")
check "AT2b park reason starts rebase-gate-red: ($REASON)" '[[ $REASON == "rebase-gate-red: stacked child of parent=#1 replayed onto main, suites red: "*"(archie-fm)" ]]'
eq "AT2b one row, requested" "$(rows) $(row action) $(row outcome)" "1 fix_round requested"

# ── AT3: observe ─────────────────────────────────────────────────────────────
check "AT3 observe: no git write, no PATCH, no suites, no park, ONE would row" 'at3_observe_clean'
check "AT3 the would row's evidence names onto + upstream" \
  '[ "$(row evidence.onto) $(row evidence.parent_head)" = "main $PHEAD" ]'
check "AT3 the observe key carries the mode" '[ "$(row dedupe_key)" = "stacked-parent-merged:acme/fixt#2:$CHILD:$PHEAD:observe" ]'
check "AT3 summary: $(lastlog)" 'lastlog | grep -q " restacked=0 fix_rounds=0 would=1 "'
check "AT4 (observe) a second tick: POST 200 existing, row count 1, no close, no git write" 'at4_observe_second'
# archie.manage=on + archie.manage.fixt=observe -> the same as observe.
world clean; setting archie.manage.fixt observe; BEFORE=$(refs)
tick
check "AT3 the per-project row wins: observe" '[ "$(refs)" = "$BEFORE" ] && [ "$(patches)" = 0 ] && [ "$(row mode)/$(row outcome)" = observe/would ]'
# archie.manage.fixt=off -> nothing read past the settings row, no row.
world clean; setting archie.manage.fixt off; BEFORE=$(refs)
tick
check "AT3 off: no row, no PATCH, no PR read" '[ "$(rows)" = 0 ] && [ "$(patches)" = 0 ] && [ ! -s "$T/ghrest.log" ] && [ "$(refs)" = "$BEFORE" ]'
# archie.manage=bogus -> observe + one warn line.
world clean; setting archie.manage bogus; BEFORE=$(refs)
tick
check "AT3 a junk mode is observe" '[ "$(refs)" = "$BEFORE" ] && [ "$(row mode)/$(row outcome)" = observe/would ]'
eq "AT3 a junk mode is ONE warn line" "$(grep -c "warn: archie.manage='bogus' is not on, observe or off" "$H/logs/archie-fm.log")" 1
# The settings value is trimmed before it is compared.
world clean; setting archie.manage $'observe \n'
tick
check "AT3 trailing whitespace is trimmed (observe, no warn)" '[ "$(row mode)" = observe ] && ! grep -q warn "$H/logs/archie-fm.log"'
# No archie.manage row at all -> the documented fallback, on.
world clean; jq 'del(.settings["archie.manage"])' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
check "AT3 no row at all: the fallback is on (restacked)" 'at1_own_only && [ "$(row mode)/$(row outcome)" = on/done ]'

# ── AT5: guards ──────────────────────────────────────────────────────────────
nothing_written() { [ "$(rows)" = 0 ] && [ "$(patches)" = 0 ] && [ "$(oref ticket/bh-9002)" = "$CHILD" ] && [ ! -s "$T/order.log" ]; }
world clean
jq 'map(if .number == 2 then .head.repo.full_name = "someone/fixt" else . end)' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
tick
check "AT5 fork head: no row, no write" 'nothing_written && grep -q "head lives in someone/fixt" "$H/logs/archie-fm.log"'
# Review B1/I1 (2026-10-06): only harness-built PRs. A person's branch on the
# child, or a long-lived base as the "parent", is never Archie's to restack.
world clean
jq 'map(if .number == 2 then .head.ref = "agent/TK-9002" else . end)' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
tick
check "AT5 a person's child branch (agent/TK-9002): no row, no write" 'nothing_written && grep -q "agent/TK-9002 on ticket/bh-9001 is not a harness build branch pair" "$H/logs/archie-fm.log"'
world clean
jq 'map(if .number == 2 then .base.ref = "develop" elif .number == 1 then .head.ref = "develop" else . end)' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
tick
check "AT5 a long-lived parent branch (develop): no row, no write" 'nothing_written && grep -q "ticket/bh-9002 on develop is not a harness build branch pair" "$H/logs/archie-fm.log"'
# Review I4: a PR the blocked-resolver owns (a sticky hand-off reason) is left to it.
world clean; mkdir -p "$H/state/merge-conductor"
printf 'acme/fixt#2\tBLOCKED_HUMAN\t%s\t%s\t%s\t0\tconflict-unresolvable: x\thttps://github.com/acme/fixt/pull/2\n' "$NOW" "$CHILD" "$CHILD" >> "$H/state/merge-conductor/pr-state.tsv"
tick
check "AT5 a resolver hand-off (conflict-unresolvable): no row, no write" 'nothing_written && grep -q "blocked-resolver.sh owns this PR (conflict-unresolvable" "$H/logs/archie-fm.log"'
world clean; : > "$T/held"
tick
check "AT5 HOLD: no row, no write" 'nothing_written && grep -q "on HOLD" "$H/logs/archie-fm.log"'
# Review I3: the push guard's hold read is unreadable -> fail closed, no write.
world clean; : > "$T/hold.unreadable"
tick
check "AT5 an unreadable hold read: no row, no write" 'nothing_written && grep -q "the hold read says unreadable (rc=2)" "$H/logs/archie-fm.log"'
world clean; mkdir -p "$H/state/stack-follow"
printf '1\thttps://github.com/acme/fixt/pull/1\tticket/bh-9001\t%s\tmain\t0\t%s\n' "$PHEAD" "$NOW" > "$H/state/stack-follow/acme_fixt#2"
tick
check "AT5 a conductor stack-follow record: no row" 'nothing_written && grep -q "owes this child a stack-follow" "$H/logs/archie-fm.log"'
world clean; mkdir -p "$H/locks"
flock "$H/locks/merge-conductor-fixt-2.lock" sleep 30 >/dev/null 2>&1 & LKP=$!
for _ in $(seq 1 50); do flock -n "$H/locks/merge-conductor-fixt-2.lock" true || break; sleep 0.1; done
T0=$SECONDS
tick
TOOK=$((SECONDS - T0))
kill $(pgrep -P "$LKP" 2>/dev/null) "$LKP" 2>/dev/null; wait "$LKP" 2>/dev/null
check "AT5 the conductor's PR lock held: no row, no write ($(rows) $(patches) $(tail -2 "$H/logs/archie-fm.log" 2>/dev/null))" 'nothing_written && grep -q "holds its PR lock" "$H/logs/archie-fm.log"'
check "AT5 ...and the tick does not wait (${TOOK}s)" '[ "$TOOK" -lt 20 ]'
world clean; setting archie.cap.stacked-parent-merged 1
jq --arg d "$DAY" '.actions += [{id: 1, dedupe_key: "stacked-parent-merged:acme/other#7:a:b:on", day: $d, project: "fixt", repo: "acme/other",
   pr: 7, playbook: "stacked-parent-merged", mode: "on", action: "restack", outcome: "done", why: "x", evidence: {}, attempts: 1,
   actor: "archie-fm", created_at: "2026-10-05T01:00:00Z", updated_at: "2026-10-05T01:00:00Z"}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
check "AT5 day cap reached: no claim, no write" '[ "$(rows)" = 1 ] && [ "$(posts)" = 0 ] && [ "$(patches)" = 0 ] && [ "$(oref ticket/bh-9002)" = "$CHILD" ]'
check "AT5 ...logged cap reached" 'grep -q "cap reached (1 of 1" "$H/logs/archie-fm.log"'
world clean; setting archie.cap.stacked-parent-merged 0
tick
check "AT5 cap 0: the playbook is off" 'nothing_written && grep -q "the playbook is off" "$H/logs/archie-fm.log"'
world clean; : > "$T/settings.down"
tick
check "AT5 settings outage: no row, no write, no PR read" 'nothing_written && [ ! -s "$T/ghrest.log" ] && grep -q "settings could not be read" "$H/logs/archie-fm.log"'
world clean; : > "$T/route.absent"
tick
check "AT5 route 404: no write" 'nothing_written'
eq "AT5 route 404: one log line" "$(grep -c "archie_actions route absent" "$H/logs/archie-fm.log")" 1
world clean; : > "$T/parent.down"
tick
check "AT5 parent unreadable: skipped, not 'not merged', no row" 'nothing_written && grep -q "parent PR could not be read (HTTP 502)" "$H/logs/archie-fm.log"'
world clean; tick ARCHIE_FM_ENABLED=0
check "AT5 ARCHIE_FM_ENABLED=0: no request at all" '[ ! -s "$T/reqlog" ] && [ ! -s "$T/ghrest.log" ]'
world clean
jq 'map(if .number == 2 then .base.ref = "main" else . end)' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
tick
check "AT5 no stuck PR: no row, no summary line" 'nothing_written && [ ! -s "$H/logs/archie-fm.log" ]'
world clean
jq 'map(if .number == 1 then .merged_at = null else . end)' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
tick
check "AT5 parent closed unmerged: unclassified, no row" 'nothing_written'

# ARCHIE_FM_PROJECTS_PER_TICK=1 over two projects: each tick reads one, and
# two ticks ten minutes apart read both (the start rotates; nothing starves).
world clean; printf 'fixt\nzeta\n' > "$T/projects"
tick ARCHIE_FM_PROJECTS_PER_TICK=1
A=$(grep -c '^list acme/[a-z]* open $' "$T/ghrest.log")
tick ARCHIE_FM_NOW=$((NOW + 600)) ARCHIE_FM_PROJECTS_PER_TICK=1
check "AT5 a per-tick project cap reads one project a tick ($A then $(grep -c '^list acme/[a-z]* open $' "$T/ghrest.log"))" \
  '[ "$A" = 1 ] && [ "$(grep -c "^list acme/[a-z]* open $" "$T/ghrest.log")" = 2 ]'
check "AT5 ...and two ticks reach both projects ($(grep "open $" "$T/ghrest.log" | tr '\n' '|'))" \
  'grep -q "^list acme/fixt open $" "$T/ghrest.log" && grep -q "^list acme/zeta open $" "$T/ghrest.log"'

# ── AT6: deferred, reclaimed, failed ─────────────────────────────────────────
world clean; : > "$T/move.child"
tick
eq "AT6 lease refused: the row is deferred" "$(row outcome)" deferred
check "AT6 ...the other writer's commit stands" '[ "$(git -C "$T/origin.git" log -1 --format=%s ticket/bh-9002)" = "someone else" ]'
check "AT6 ...the reason is the push ($(row why))" '[[ "$(row why)" == "the push was refused"* ]]'
eq "AT6 ...the base is put back on the parent branch, so a later tick sees it" \
  "$(jq -r '.[] | select(.number == 2) | .base.ref' "$T/prs.json")" ticket/bh-9001
eq "AT6 ...two PATCHes: to main, then back" "$(grep -c '^api -X PATCH repos/acme/fixt/pulls/2 ' "$T/gh.log")" 2
eq "AT6 ...no alert" "$(cat "$T/alerts.log" 2>/dev/null)" ""
NEWHEAD=$(oref ticket/bh-9002); rm -f "$T/move.child"
jq --arg h "$NEWHEAD" 'map(if .number == 2 then .head.sha = $h else . end)' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
tick ARCHIE_FM_NOW=$((NOW + 600))
check "AT6 ...the next tick classifies it again and restacks the new head ($(lastlog))" \
  '[ "$(rows)" = 2 ] && [ "$(jq -r ".actions[1].outcome" "$T/db.json")" = done ] && [ "$(jq -r ".[] | select(.number == 2) | .base.ref" "$T/prs.json")" = main ] && [ "$(git -C "$T/origin.git" rev-list --count main..ticket/bh-9002)" = 2 ]'

# A refused push whose base cannot be put back is the one state no later tick
# can see: failed at once, with ONE alert.
world clean; : > "$T/move.child"; : > "$T/patch.refuse.second"
tick
eq "AT6 stranded: the row closes failed at once" "$(row outcome)" failed
check "AT6 stranded: the why says the base could not be put back ($(row why))" '[[ "$(row why)" == *"could not be put back on ticket/bh-9001"* ]]'
eq "AT6 stranded: ONE alert" "$(wc -l < "$T/alerts.log" | tr -d ' ')" 1
check "AT6 stranded: the alert names the PR and the rebase ($(cat "$T/alerts.log"))" \
  'grep -qF "git rebase --onto origin/main $PHEAD" "$T/alerts.log" && grep -qF "https://github.com/acme/fixt/pull/2" "$T/alerts.log"'
check "AT6 stranded: the summary counts it ($(lastlog))" 'lastlog | grep -q " deferred=0 skipped=0 failed=1 repaired=0$"'
world clean; echo 125 > "$T/suite.rc"
tick
check "AT6 suites could not run: deferred, attempts 1, no PATCH, no push" \
  '[ "$(row outcome)/$(row attempts)" = deferred/1 ] && [ "$(patches)" = 0 ] && [ "$(oref ticket/bh-9002)" = "$CHILD" ]'
tick ARCHIE_FM_NOW=$((NOW + 60)) ARCHIE_FM_MAX_ATTEMPTS=2
check "AT6 too fresh to reclaim: still attempts 1" '[ "$(row outcome)/$(row attempts)" = deferred/1 ] && [ "$(wc -l < "$T/suites.log" | tr -d " ")" = 1 ]'
tick ARCHIE_FM_NOW=$((NOW + 1800)) ARCHIE_FM_MAX_ATTEMPTS=2
check "AT6 at NOW+ARCHIE_FM_RETRY_S it is reclaimed: attempts 2" '[ "$(row outcome)/$(row attempts)" = deferred/2 ] && [ "$(wc -l < "$T/suites.log" | tr -d " ")" = 2 ]'
eq "AT6 still one row" "$(rows)" 1
tick ARCHIE_FM_NOW=$((NOW + 3600)) ARCHIE_FM_MAX_ATTEMPTS=2
eq "AT6 at ARCHIE_FM_MAX_ATTEMPTS the row closes failed" "$(row outcome)" failed
eq "AT6 ...with ONE alert line" "$(wc -l < "$T/alerts.log" | tr -d ' ')" 1
check "AT6 the alert names the PR and the rebase to run ($(cat "$T/alerts.log"))" \
  'grep -qF "git rebase --onto origin/main $PHEAD" "$T/alerts.log" && grep -qF "https://github.com/acme/fixt/pull/2" "$T/alerts.log"'
tick ARCHIE_FM_NOW=$((NOW + 5400)) ARCHIE_FM_MAX_ATTEMPTS=2
check "AT6 a failed row is final: no second alert, no suites" '[ "$(wc -l < "$T/alerts.log" | tr -d " ")" = 1 ] && [ "$(wc -l < "$T/suites.log" | tr -d " ")" = 2 ]'

# ── AT7: the child was restacked by hand, base still the parent branch ──────
# BH-4784: no Archie restack of the parent recorded a fork point, so it is
# failed with ONE alert, never a silent noop.
world byhand
tick
eq "AT7 row restack / failed" "$(row action) $(row outcome)" "restack failed"
check "AT7 ...why starts 'parent head not in child history' ($(row why))" '[[ "$(row why)" == "parent head not in child history"* ]]'
eq "AT7 ...ONE alert" "$(wc -l < "$T/alerts.log" | tr -d ' ')" 1
check "AT7 no push, no PATCH" '[ "$(oref ticket/bh-9002)" = "$CHILD" ] && [ "$(patches)" = 0 ] && [ ! -s "$T/order.log" ]'
: > "$T/reqlog"
tick
check "AT4 (failed) a second tick on the same state closes nothing" '[ "$(rows)" = 1 ] && [ "$(closes)" = 0 ] && [ "$(posts)" = 1 ] && [ "$(wc -l < "$T/alerts.log" | tr -d " ")" = 1 ]'

# ── AT8: PR code never sees the lane's token or env ─────────────────────────
world clean
tick
check "AT8 the restack still lands (the token is re-armed for the push)" 'at1_own_only && [ "$(row outcome)" = done ]'
check "AT8 the suite's env carries no secret: no HARNESS_SECRET, MC_GIT_TOKEN, GIT_ASKPASS, GH_TOKEN, JOBS_URL" \
  '[ -s "$T/suite.env" ] && ! grep -qE "^(HARNESS_SECRET|MC_GIT_TOKEN|GIT_ASKPASS|GH_TOKEN|JOBS_URL|HARNESS)=" "$T/suite.env"'
check "AT8 the suite ran in a snapshot, not the hub clone's worktree ($(cat "$T/suite.pwd"))" \
  '[[ "$(cat "$T/suite.pwd")" == "$T/tmp/afm-suite-"*/repo ]]'
check "AT8 the snapshot is gone after the run" '! ls -d "$T"/tmp/afm-suite-* >/dev/null 2>&1'
world clean
mkdir -p "$T/fakebin2"; printf '#!/bin/bash\nexit 1\n' > "$T/fakebin2/setpriv"; chmod +x "$T/fakebin2/setpriv"
tick ARCHIE_FM_SUITE_AS= PATH="$T/fakebin2:$PATH"
check "AT8 as nobody, a setpriv that cannot switch: deferred, no suite ran, no PATCH, no push ($(row why))" \
  '[ "$(row outcome)" = deferred ] && [[ "$(row why)" == "the suites could not run"* ]] && [ ! -s "$T/suites.log" ] && [ "$(patches)" = 0 ] && [ "$(oref ticket/bh-9002)" = "$CHILD" ]'

# ── AT9: the tick's deadline, and a tick that outlives its backstop ─────────
world clean
tick ARCHIE_FM_DEADLINE=$(( $(date +%s) + 100 ))
check "AT9 too little time left for a suite bound: no row, no write, logged" \
  'nothing_written && grep -q "left in this tick, under a suite bound" "$H/logs/archie-fm.log"'
world clean; : > "$T/suite.sleep"
S0=$(date +%s)
tick ARCHIE_FM_TICK_CEILING_S=3
TOOK=$(( $(date +%s) - S0 ))
check "AT9 a suite outliving the tick: the trap runs at once (${TOOK}s)" '[ "$TOOK" -lt 20 ]'
check "AT9 ...the row closes deferred, not left started ($(row outcome): $(row why))" \
  '[ "$(row outcome)" = deferred ] && [[ "$(row why)" == "the tick was stopped mid-action"* ]]'
check "AT9 ...no PATCH, no push, the base unchanged" \
  '[ "$(patches)" = 0 ] && [ "$(oref ticket/bh-9002)" = "$CHILD" ] && [ "$(jq -r ".[] | select(.number == 2) | .base.ref" "$T/prs.json")" = ticket/bh-9001 ]'
eq "AT9 ...no worktree left on the hub clone" "$(git -C "$T/repos/fixt" worktree list | wc -l | tr -d ' ')" 1
check "AT9 ...no worktree or snapshot left in TMPDIR" '! ls -d "$T"/tmp/afm-restack-* "$T"/tmp/afm-suite-* >/dev/null 2>&1'
rm -f "$T/suite.sleep"
tick ARCHIE_FM_NOW=$((NOW + 1800))
check "AT9 ...and a tick past ARCHIE_FM_RETRY_S reclaims it and restacks" '[ "$(row outcome)/$(row attempts)" = done/2 ] && at1_own_only'

# ── the cron line and the registry ───────────────────────────────────────────
# TEST-CHANGE: BH-5944 — the cron line runs `archie-fm.sh --dispatch` (one run
# per project on bin/lib/project-lanes.sh) into its own cron log. The pattern is
# grep'd directly, never through eval: a `>> /root/harness/...` in an eval'd
# string reads as a write to the real harness.
AFM_CRON_RE='^\*/10 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/archie-fm.sh --dispatch >> /root/harness/logs/archie-fm-cron.log 2>&1$'
eq "cron: one hub-lease-gated */10 line for bin/archie-fm.sh --dispatch" "$(grep -cE "$AFM_CRON_RE" "$DIR/cron/lanes/725-archie-fm.cron")" 1
check "registry: hub lane, flag switch, no cost stage" \
  'jq -e ".scope == \"hub\" and .script == \"bin/archie-fm.sh\" and .switch.name == \"lane-off-archie-fm\" and .stats.cost_stage == null" "$DIR/catalog/lanes.d/archie-fm.json" >/dev/null'

# ═════ X: mutations of the lib, each must turn its case red ══════════════════
LIB="$H/bin/lib/archie-fm.sh"
mutate() { # mutate <python-expr over s>
  rm -f "$LIB"
  python3 -c "import sys; s=open(sys.argv[1]).read(); $1; open(sys.argv[2],'w').write(s)" "$DIR/bin/lib/archie-fm.sh" "$LIB"
  cmp -s "$LIB" "$DIR/bin/lib/archie-fm.sh" && { echo "mutation did not change the lib"; return 1; }
  return 0
}
restore() { rm -f "$LIB"; ln -s "$DIR/bin/lib/archie-fm.sh" "$LIB"; }
if command -v python3 >/dev/null 2>&1; then
  # X1: a plain rebase onto the target, not --onto <target> <parent-head>.
  if mutate 's=s.replace("rebase --onto \"origin/$target\" \"$fork\"", "rebase \"origin/$target\"")'; then
    at1_world_ticked
    if at1_own_only; then bad "X1 a plain rebase must break AT1's own-commits-only assertion"; else ok "X1 RED: a plain rebase breaks AT1's own-commits-only assertion"; fi
  else bad "X1 mutation not applied"; fi
  restore
  # X2: the dedupe ignored (an existing row read as this tick's own).
  if mutate 's=s.replace("[ \"$(jq -r '"'"'.created == true'"'"' <<<\"$resp\")\" = true ] && return 0", "return 0")'; then
    if at4_observe_second; then bad "X2 skipping the dedupe must break AT4"; else ok "X2 RED: skipping the dedupe breaks AT4"; fi
  else bad "X2 mutation not applied"; fi
  restore
  # X3: the observe branch bypassed.
  if mutate 's=s.replace("if [ \"$mode\" != on ]; then\n    afm_close would", "if false; then\n    afm_close would")'; then
    if at3_observe_clean; then bad "X3 bypassing observe must break AT3"; else ok "X3 RED: bypassing observe breaks AT3"; fi
  else bad "X3 mutation not applied"; fi
  restore
  # X4: the suite runner keeps the lane's env (no env -i).
  if mutate 's=s.replace("env -i PATH=", "env PATH=")'; then
    world clean; tick
    if ! grep -qE "^(HARNESS_SECRET|JOBS_URL)=" "$T/suite.env"; then bad "X4 dropping env -i must leak the lane's env into the suite"; else ok "X4 RED: without env -i the suite sees the lane's env"; fi
  else bad "X4 mutation not applied"; fi
  restore
  # X5: a refused push leaves the retarget standing.
  if mutate 's=s.replace("if mc_retarget_base \"$slug\" \"$n\" \"$obase\"; then\n      AFM_RES_WHY=", "if true; then\n      AFM_RES_WHY=")'; then
    world clean; : > "$T/move.child"; tick
    if [ "$(jq -r '.[] | select(.number == 2) | .base.ref' "$T/prs.json")" = ticket/bh-9001 ]; then bad "X5 skipping the put-back must leave the base on main"; else ok "X5 RED: without the put-back the PR is left on main"; fi
  else bad "X5 mutation not applied"; fi
  restore
  check "X the restored lib is the shipped one" '[ "$(readlink "$LIB")" = "$DIR/bin/lib/archie-fm.sh" ]'
else
  bad "X python3 is required for the mutations"
fi

echo "archie-fm-tracer: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
