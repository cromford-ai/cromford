#!/bin/bash
# tests/staff-archivist-lever.bh-10125-test.sh — BH-10125 (C4 of #9423): the
# archivist staff agent reads Archie's hand-fix log (archie_actions, through
# the BH-4587 reader and fingerprint), samples its metric
# causes_fixed_by_hand_twice, and at level file files ONE ai-build issue per
# repeated cause after an issue dedupe. Driven through the SHIPPED
# bin/staff/archivist-lever.sh.
#
# THE WORLD. A scratch $HARNESS with the lane's closure (scratch_install_closure)
# and the harness repo acme/fixt-harness. Every archie_actions row is written by
# the REAL writer, wave 2's afq_claim/afq_close, against the model below, with
# the dedupe keys and evidence shapes the watch lane writes (the BH-4587 suite's
# world, D63).
#
# WHAT IS STUBBED, and only this. ARCHIVIST_FIXTURE=$T/fx.sh (sandbox-only):
#   _jobs_req       a jq model of /api/settings/<key>, /api/archie/actions
#                   (day, playbook, limit, truncated via $T/trunc.<day>),
#                   /api/staff/agent.
#   _jobs_req_file  a model of POST /api/staff/levers/metric and
#                   /api/staff/levers/actions (natural key idempotence:
#                   existing:true on the same payload, 409 on another).
#   flag_active     a file under $H/flags.
#   gh_rest         a stateful model of the issue lists and POST issues
#                   (--input payload); every call is logged.
# PATH stubs git, gh and curl log to $T/forbidden.log and fail.
#
# Cases: C0 U1 D1 D2 D3 M1 M2 L1 L2 F1 F2 F3 F4 F5 F6 F7 E1 E2 E3 E4 E5 E6 R1 N1.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-archivist-lever.bh-10125-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-archivist-lever: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "staff-archivist-lever: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "${ARCHIVIST_TEST_VERBOSE:-}" = 1 ] && [ -n "${1:-}" ] && echo "ok: $1"; return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

LEVER_REL=bin/staff/archivist-lever.sh

# ═════ C0: the sources this ticket ships ══════════════════════════════════════
for f in "$SRC/$LEVER_REL" "$SRC/catalog/lanes.d/staff-archivist-lever.json" "$SRC/cron/lanes/787-staff-archivist-lever.cron" \
         "$SRC/docs/notes/2026-11-25-BH-10125-archivist.md" "$SRC/docs/verification-map/entries/BH-10125.md"; do
  if [ -s "$f" ]; then ok "C0 ships ${f#"$SRC"/}"; else bad "C0 missing ${f#"$SRC"/}"; fi
done
SEED=$(ls "$SRC"/worker/jobs/schema.d/*-bh-10125-archivist-lever.sql 2>/dev/null | head -1)
if [ -n "$SEED" ]; then
  eq "C0 the seed holds both rows" "$(grep -c "'staff.archivist.recur_n','2'\|'staff.archivist.window_days','7'" "$SEED")" 2
else
  bad "C0 no worker/jobs/schema.d/*-bh-10125-archivist-lever.sql"
fi
check "C0 cron: hourly :57 behind the hub lease" \
  "grep -q '^57 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/staff/archivist-lever.sh ' '$SRC/cron/lanes/787-staff-archivist-lever.cron' 2>/dev/null"
eq "C0 lane row" "$(jq -r '.script + " " + .switch.name + " " + .scope + " " + .cadence' "$SRC/catalog/lanes.d/staff-archivist-lever.json" 2>/dev/null)" \
  "bin/staff/archivist-lever.sh lane-off-staff-archivist-lever hub 57 * * * *"
if [ ! -f "$SRC/$LEVER_REL" ]; then
  echo "staff-archivist-lever: $PASS passed, $FAIL failed"; exit 1
fi

# ═════ U1: the action answer (ARCHIVIST_LIB_ONLY=1) ═══════════════════════════
(
  ARCHIVIST_LIB_ONLY=1 . "$SRC/$LEVER_REL" || { echo "FAIL: U1 source"; exit 1; }
  f=0
  chk() { local b="$T/u1.json" got; printf '%s' "$2" > "$b"
          got=$(arch_action_verdict "$1" "$b" "$3")
          [ "$got" = "$4" ] || { echo "FAIL: U1 $5: want [$4] got [$got]"; f=1; }; }
  chk 200 '{"ok":true,"action":{"action_key":"ab"}}' 0 run "a new row is run"
  chk 201 '{"ok":true,"action":{"action_key":"ab"}}' 0 run "a 201 new row is run"
  chk 200 '{"ok":true,"existing":true,"action":{"action_key":"ab"}}' 0 taken "existing is taken"
  chk 409 '{"error":"key_mismatch","action":{}}' 9 taken "409 is taken"
  chk 500 '{"error":"x"}' 1 failed "500 is failed"
  chk "" '' 1 failed "rc 1, empty body is failed"
  chk 200 '{"ok":false}' 0 failed "ok:false is failed"
  chk 200 'not json' 0 failed "a non-JSON 200 is failed"
  chk 404 '' 2 failed "404 is failed"
  exit "$f"
) && ok "U1 action verdicts" || bad "U1 action verdicts"

D=86400
NOW0=1791720000                      # Sun 2026-10-11T12:00:00Z
DAY0=2026-10-11
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
fp() { printf '%s' "$1" | sha1sum | cut -c1-12; }
cdisk() { printf 'watch|disk|%s|run_cleanup' "$1"; }    # the cause of a watch-disk row on project $1

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/env" "$H/flags" "$T/fakebin" "$T/tmp" "$T/home"
scratch_install_closure "$LEVER_REL" "$H" >/dev/null || exit 1
scratch_install_closure bin/archie-fm-improve.sh "$H" >/dev/null || exit 1
# The closure scan does not follow `. "$SELF/jobs-client.sh"`; the client goes in by its own closure.
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/tracker/github-issues.sh "$H" >/dev/null || exit 1
: > "$H/env/global.env"
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
SH
chmod +x "$H/bin/alert-line.sh"
for s in git gh curl; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "$FXT/forbidden.log"\nexit 1\n' "$s" > "$T/fakebin/$s"
done
chmod +x "$T/fakebin/"*
: > "$T/forbidden.log"

cat > "$T/fx.sh" <<'SH'
fx_now() { printf '%s' "${FXNOW:-${ARCHIVIST_NOW:-${ARCHIE_FMI_NOW:-0}}}"; }
fx_clock() { date -u -d "@$(fx_now)" +%Y-%m-%dT%H:%M:%SZ; }
flag_active() { printf 'FLAG %s\n' "$1" >> "$FXT/flaglog"; [ -e "$HARNESS/flags/$1" ]; }
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 db="$FXT/db.json" key t
  JOBS_HTTP=""; JOBS_BODY=""
  [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
  printf '%s %s\n' "$m" "$p" >> "$FXT/reqlog"
  t=$(fx_clock)
  qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
  case "$m ${p%%\?*}" in
    GET\ /api/settings/*)
      key=${p#/api/settings/}
      out=$(jq -c --arg k "$key" 'select(.settings | has($k)) | {setting: {key: $k, value: .settings[$k]}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; printf '{"error":"no such setting"}'; return 2; } ;;
    "GET /api/staff/agent")
      out=$(jq -c --arg n "$(qp name)" '{agent: {name: $n, status: .agent_status}}' "$db") ;;
    "POST /api/archie/actions")
      key=$(jq -r .dedupe_key <<<"$b")
      out=$(jq -c --arg k "$key" '.actions[] | select(.dedupe_key == $k)' "$db")
      if [ -z "$out" ]; then
        jq --argjson b "$b" --arg t "$t" '.actions += [$b + {id: ((.actions | length) + 1), day: $t[0:10], attempts: 1,
            evidence: ($b.evidence // {}), created_at: $t, updated_at: $t}]' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        out=$(jq -c --arg k "$key" '{ok: true, created: true, action: (.actions[] | select(.dedupe_key == $k))}' "$db"); code=201
      else
        out=$(jq -c '{ok: true, existing: true, action: .}' <<<"$out")
      fi ;;
    "POST /api/archie/actions/outcome")
      out=$(jq -c --argjson b "$b" '.actions[] | select(.id == $b.id and .dedupe_key == $b.dedupe_key)' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; printf '{"error":"archie action not found"}'; return 2; }
      jq --argjson b "$b" --arg t "$t" '.actions |= map(if .id == $b.id then
          .outcome = $b.outcome | .action = ($b.action // .action) | .why = ($b.why // .why)
          | .evidence = ($b.evidence // .evidence) | .updated_at = $t else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --argjson b "$b" '{ok: true, action: (.actions[] | select(.id == $b.id))}' "$db") ;;
    "GET /api/archie/actions")
      [ -f "$FXT/archie.absent" ] && { JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2; }
      local d pb lim; d=$(qp day); pb=$(qp playbook); lim=$(qp limit)
      [ -f "$FXT/down.$d" ] && { JOBS_HTTP=503; return 1; }
      out=$(jq -c --arg d "$d" --arg pb "$pb" --argjson l "${lim:-100}" --argjson tr "$([ -f "$FXT/trunc.$d" ] && echo true || echo false)" \
        '[.actions[] | select(.day == $d and ($pb == "" or .playbook == $pb))] | sort_by(.created_at, .id) | reverse as $r
        | {ok: true, day: $d, actions: $r[0:$l], truncated: ($tr or ($r | length) > $l)}' "$db") ;;
    *) JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
_jobs_req_file() {
  local m="$1" p="$2" f="$3" b out k ak st
  JOBS_HTTP=""; JOBS_BODY=""
  b=$(cat "$f")
  printf '%s %s\n' "$m" "$p" >> "$FXT/reqlog"
  case "$m $p" in
    "POST /api/staff/levers/metric")
      printf '%s\n' "$(jq -c . <<<"$b")" >> "$FXT/samples.jsonl"
      if [ -f "$FXT/metric.down" ]; then JOBS_HTTP=500; return 1; fi
      JOBS_HTTP=200; out='{"ok":true,"settled":0}' ;;
    "POST /api/staff/levers/actions")
      printf 'ACTION %s\n' "$(jq -r .key <<<"$b")" >> "$FXT/calls.log"
      printf '%s\n' "$(jq -c . <<<"$b")" >> "$FXT/action-posts.jsonl"
      st=$(cat "$FXT/action.status" 2>/dev/null || echo ok)
      case "$st" in
        500) JOBS_HTTP=500; return 1 ;;
        409) JOBS_HTTP=409; out='{"error":"key_mismatch","action":{}}'; printf '%s' "$out"; return 9 ;;
      esac
      k=$(jq -r '"\(.agent)|\(.lever)|\(.key)"' <<<"$b")
      ak=$(printf '%s' "$k" | sha256sum | cut -c1-64)
      if [ "$st" = existing ] || grep -q "^$ak " "$FXT/staff-actions.txt" 2>/dev/null; then
        out=$(jq -nc --arg a "$ak" '{ok: true, existing: true, action: {action_key: $a}}')
      else
        printf '%s %s\n' "$ak" "$(jq -c . <<<"$b")" >> "$FXT/staff-actions.txt"
        out=$(jq -nc --arg a "$ak" '{ok: true, action: {action_key: $a}}')
      fi
      JOBS_HTTP=200 ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
gh_rest() {
  local m="$1" p="$2" a input="" st n gh="$FXT/gh.json"
  shift 2
  printf '%s %s %s\n' "$m" "$p" "$*" >> "$FXT/ghrest.log"
  while [ $# -gt 0 ]; do
    case "$1" in --input) input="$2"; shift ;; esac
    shift
  done
  case "$m $p" in
    GET\ repos/acme/fixt-harness/issues\?*)
      [ -f "$FXT/issues.down" ] && { GH_REST_STATUS=500; return 75; }
      n=$(printf '%s' "$p" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p')
      GH_REST_STATUS=200
      [ "$n" = 1 ] || { echo '[]'; return 0; }
      case "$p" in
        *labels=archie-fm-improve*state=all*) jq -c '[.issues[] | select(any(.labels[]; .name == "archie-fm-improve"))]' "$gh" ;;
        *state=open*) jq -c '[.issues[] | select(.state == "open")]' "$gh" ;;
        *) echo '[]' ;;
      esac
      return 0 ;;
    "POST repos/acme/fixt-harness/issues")
      printf 'ISSUE %s\n' "$(jq -r .title "$input")" >> "$FXT/calls.log"
      st=$(cat "$FXT/issue.status" 2>/dev/null || echo 201)
      if [ "$st" = rc1 ]; then GH_REST_STATUS=000; return 1; fi
      GH_REST_STATUS=$st
      case "$st" in 2*) ;; *) echo '{"message":"Validation Failed"}'; return 75 ;; esac
      n=$(jq '[.issues[].number] | (max // 9000) + 1' "$gh")
      [ "$n" -gt 9000 ] || n=9001
      jq --argjson n "$n" --slurpfile in "$input" --arg c "$(fx_clock)" \
        '.issues += [{number: $n, title: $in[0].title, body: $in[0].body, state: "open", state_reason: null, created_at: $c, closed_at: null,
          html_url: ("https://github.com/acme/fixt-harness/issues/" + ($n | tostring)), labels: ($in[0].labels | map({name: .}))}]' "$gh" > "$gh.tmp" && mv "$gh.tmp" "$gh"
      cp "$input" "$FXT/issue-payload.$n"
      jq -c --argjson n "$n" '.issues[] | select(.number == $n) | {number, html_url}' "$gh"; return 0 ;;
  esac
  GH_REST_STATUS=404; return 44
}
:
SH

# The REAL writer: wave 2's afq_claim (and afq_close), one process per batch.
# A line: epoch \t playbook \t key \t project \t repo \t pr \t mode \t action \t why \t evidence \t final-outcome|-
cat > "$T/writer.sh" <<'SH'
#!/bin/bash
. "$HARNESS/bin/jobs-client.sh" 2>/dev/null
. "$HARNESS/bin/lib/archie-fm.sh" || exit 1
. "$HARNESS/bin/lib/archie-fm-queue/common.sh" || exit 1
. "$FXT/fx.sh"
AFQ_RETRY_S=1800; AFM_LOG=""
while IFS=$'\t' read -r e pb key p repo n mode act why ev fin; do
  FXNOW=$e; NOW=$e
  case "$pb" in watch-*) AFQ_ACTOR=archie-fm-watch ;; queue-*) AFQ_ACTOR=archie-fm-queue ;; improve) AFQ_ACTOR=archie-fm-improve ;; *) AFQ_ACTOR=archie-fm ;; esac
  afq_claim "$pb" "$key" "$p" "$repo" "$n" "$mode" "$act" "$why" "$ev" || { echo "writer: claim of $key failed" >&2; exit 1; }
  if [ "$mode" = on ] && [ "$fin" != - ]; then afq_close "$pb" "$fin" "" "" "" || { echo "writer: close of $key failed" >&2; exit 1; }; fi
done
SH
chmod +x "$T/writer.sh"

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=fixture-secret \
       TMPDIR="$T/tmp" HOME="$T/home" HARNESS_REPO=acme/fixt-harness JOBS_SETTINGS_CACHE_S=0 LANE_GATE_DISABLE=1
unset HARNESS_ENV_DIR STAFF_ENABLED ARCHIVIST_NOW ARCHIVIST_FIXTURE ARCHIVIST_LIB_ONLY \
      ARCHIE_FMI_ENABLED ARCHIE_FMI_NOW ARCHIE_FMI_FIXTURE ARCHIE_FMI_TIMED 2>/dev/null || true

WQ=""
wq() { local IFS=$'\t'; WQ+="$*"$'\n'; }
wflush() { [ -n "$WQ" ] || return 0; printf '%s' "$WQ" | bash "$T/writer.sh" || bad "the writer failed"; WQ=""; }
# inc <epoch> <project> <incident> [mode] — a watch-disk row exactly as
#   afw_handle writes it: key watch:disk:<incident>:run_cleanup:<mode>.
inc() {
  local e="$1" p="$2" i="$3" mode="${4:-on}" act=run_cleanup out=done
  [ "$mode" = on ] || { act=would_run_cleanup; out=-; }
  wq "$e" watch-disk "watch:disk:$i:run_cleanup:$mode" "$p" acme/fixt-harness 0 "$mode" "$act" "disk over threshold on $p" \
     "$(jq -nc --arg i "$i" '{source: "alert", alert_id: $i, class: "disk", incident: $i, subject: $i}')" "$out"
}
# rep <project> <n> [first-epoch] — n distinct incidents of one cause, an hour apart.
rep() {
  local p="$1" n="$2" e="${3:-$((NOW0 - 2 * D))}" k
  for ((k = 0; k < n; k++)); do inc $((e + k * 3600)) "$p" "disk-$p@$k"; done
}
world() {
  local p
  WQ=""
  for p in db.json gh.json reqlog ghrest.log alerts.log out samples.jsonl action-posts.jsonl staff-actions.txt calls.log \
           flaglog issue.status action.status metric.down issues.down archie.absent; do
    scratch_rm "$T/$p" || exit 1
  done
  rm -f "$T"/issue-payload.* "$T"/trunc.* "$T"/down.* "$H"/flags/*
  scratch_rm "$H/logs/staff-archivist-lever.log" || exit 1
  jq -n '{settings: {"archie.manage": "on", "staff.archivist.level": "file"}, agent_status: "active", actions: []}' > "$T/db.json"
  jq -n '{issues: []}' > "$T/gh.json"
  : > "$T/reqlog"; : > "$T/ghrest.log"; : > "$T/calls.log"; : > "$T/samples.jsonl"; : > "$T/action-posts.jsonl"
}
setting() { jq --arg k "$1" --arg v "$2" '.settings[$k] = $v' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
unsetting() { jq --arg k "$1" 'del(.settings[$k])' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
run() { # run <now> [VAR=value ...] — one run of the shipped lane
  local now="$1"; shift
  wflush; : > "$T/reqlog"      # reqlog holds this run's requests only (the writer's are not the lane's)
  env HARNESS_TEST_SANDBOX=1 ARCHIVIST_NOW="$now" ARCHIVIST_FIXTURE="$T/fx.sh" "$@" \
    bash "$H/bin/staff/archivist-lever.sh" > "$T/out" 2>&1
  RC=$?
}
gh_issue() { # gh_issue <n> <state> <reason|null> <body> <labels-json> [created-epoch] [pr]
  jq --argjson n "$1" --arg s "$2" --arg r "$3" --arg b "$4" --argjson l "$5" --arg c "$(iso "${6:-$((NOW0 - 3 * D))}")" --arg pr "${7:-}" \
    '.issues += [{number: $n, title: "x", body: $b, state: $s, state_reason: (if $r == "null" then null else $r end),
      created_at: $c, closed_at: null, html_url: ("https://github.com/acme/fixt-harness/issues/" + ($n | tostring)),
      labels: ($l | map({name: .}))} + (if $pr == "" then {} else {pull_request: {url: "x"}} end)]' \
    "$T/gh.json" > "$T/gh.tmp" && mv "$T/gh.tmp" "$T/gh.json"
}
marker() { printf '<!-- archie-fm-improve:fp=%s -->' "$1"; }
lastlog() { tail -1 "$H/logs/staff-archivist-lever.log" 2>/dev/null | cut -d' ' -f2-; }
fld() { lastlog | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
nsamples() { grep -c . "$T/samples.jsonl" 2>/dev/null; }
sample() { tail -1 "$T/samples.jsonl" | jq -r "$1"; }
nactions() { grep -c . "$T/action-posts.jsonl" 2>/dev/null; }
nissues() { grep -c '^POST repos/acme/fixt-harness/issues ' "$T/ghrest.log" 2>/dev/null; }
ngh() { grep -c . "$T/ghrest.log" 2>/dev/null; }
lastpayload() { ls "$T"/issue-payload.* 2>/dev/null | sort -t. -k2 -n | tail -1; }
repeated() { # repeated <since> <recur_n> — arch_repeated over the occurrences of the rows now in the db (wflush first)
  bash -c '
    H="$1"; . "$H/bin/lib/archie-fm.sh"; . "$H/bin/lib/archie-fm-improve/common.sh"
    ARCHIVIST_LIB_ONLY=1 . "$H/bin/staff/archivist-lever.sh"
    W="$FXT/rep.$2.$3"; mkdir -p "$W"; AFI_ROWS="$W/rows"; AFI_OCC="$W/occ"   # under $T: the scratch exit trap removes it
    jq -c ".actions[]" "$FXT/db.json" > "$AFI_ROWS"
    afi_occurrences; arch_repeated "$AFI_OCC" "$2" "$3"' _ "$H" "$1" "$2"
}

# ═════ D1: the repeat rule ════════════════════════════════════════════════════
world
SINCE=$((NOW0 - 7 * D))
rep d1-two 2                                                        # yes: exactly recur_n
rep d1-three 3                                                      # yes
inc $((NOW0 - D)) d1-mixed d1m-A; inc $((NOW0 - D + 60)) d1-mixed d1m-A observe; inc $((NOW0 - D + 120)) d1-mixed d1m-B  # yes
rep d1-one 1                                                        # no
inc $((NOW0 - D)) d1-dual d1d-A; inc $((NOW0 - D + 60)) d1-dual d1d-A observe   # no: one incident in two modes
inc $((NOW0 - 8 * D)) d1-old d1o-A; inc $((NOW0 - D)) d1-old d1o-B  # no: one is 8 days old
for k in 1 2; do
  wq $((NOW0 - k * 3600)) improve "improve:ticket:d1imp$k:$DAY0:on" hub acme/fixt-harness 0 on file_ticket "x" '{"fp":"d1imp"}' done
  wq $((NOW0 - k * 3600)) watch-ticket "watch:ticket:disk:d1wt$k:on" hub acme/fixt-harness 0 on file_ticket "still open" '{"class":"disk"}' done
  wq $((NOW0 - k * 3600)) queue-enqueue "queue-enqueue:acme/d1skip#7:h$k:on" fixt acme/d1skip 7 on enqueue "not ready" '{}' skipped
  wq $((NOW0 - k * 3600)) data-lane "data-lane:acme/d1dl#6:h$k:on" fixt acme/d1dl 6 on apply "apply" '{}' done
done
wq $((NOW0 - 3600)) queue-culprit "queue-culprit:acme/d1q#51:block:c1:900:on" other acme/d1q 51 on block_verdict "x" '{"suites":["tests/a-test.sh"]}' done
wq $((NOW0 - 7200)) queue-culprit "queue-culprit:acme/d1q#52:block:c2:901:on" other acme/d1q 52 on block_verdict "x" '{"suites":["tests/b-test.sh"]}' done
wflush; OUT=$(repeated "$SINCE" 2)
eq "D1 the repeated causes, count desc then fp" "$(cut -f1,2 <<<"$OUT" | tr '\t\n' ': ')" \
  "$(fp "$(cdisk d1-three)"):3 $( { printf '%s:2\n' "$(fp "$(cdisk d1-two)")" "$(fp "$(cdisk d1-mixed)")"; } | LC_ALL=C sort | tr '\n' ' ')"
eq "D1 the cause column" "$(awk -F'\t' 'NR==1{print $3}' <<<"$OUT")" "$(cdisk d1-three)"
for p in d1-one d1-dual d1-old; do
  check "D1 [$p] is not repeated" "! grep -q '$(fp "$(cdisk "$p")")' <<<\"\$OUT\""
done
eq "D1 no other cause is repeated (improve, watch-ticket, skipped, data-lane done, two queue-culprit suites)" "$(grep -c . <<<"$OUT")" 3
eq "D1 recur_n 3: only the 3-occurrence cause" "$(repeated "$SINCE" 3 | cut -f1)" "$(fp "$(cdisk d1-three)")"

# ═════ D2/D3: the recur_n and window_days rows, through the lane ═════════════
world; setting staff.archivist.level observe
rep d2-two 2
setting staff.archivist.recur_n 3
run "$NOW0"
eq "D2 recur_n row 3: a 2-occurrence cause is not repeated" "$(fld causes_fixed_by_hand_twice)" 0
for v in abc 0; do
  setting staff.archivist.recur_n "$v"; run "$NOW0"
  eq "D2 recur_n row '$v' = fallback 2" "$(fld causes_fixed_by_hand_twice)" 1
done
unsetting staff.archivist.recur_n
world; setting staff.archivist.level observe
inc $((NOW0 - 3 * D)) d3-old d3-A; inc $((NOW0 - 3600)) d3-old d3-B
run "$NOW0"
eq "D3 window 7 (no row): an occurrence 3 days old counts" "$(fld causes_fixed_by_hand_twice)" 1
setting staff.archivist.window_days 2; run "$NOW0"
eq "D3 window_days row 2: the occurrence 3 days old drops out" "$(fld causes_fixed_by_hand_twice)" 0
setting staff.archivist.window_days 31; : > "$T/reqlog"; run "$NOW0"
eq "D3 window_days row 31 = 7" "$(fld causes_fixed_by_hand_twice)" 1
check "D3 window_days row 31 writes one warn line" "grep -q 'warn: staff.archivist.window_days=31' '$H/logs/staff-archivist-lever.log'"
eq "D3 window 7 reads 7 days of rows" "$(grep -c 'GET /api/archie/actions?day=.*&limit=500$' "$T/reqlog")" 7

# ═════ M1/M2: the metric sample at observe ═══════════════════════════════════
world; setting staff.archivist.level observe
rep m1-a 2; rep m1-b 3; rep m1-c 1
run "$NOW0"
eq "M1 rc" "$RC" 0
eq "M1 one sample" "$(nsamples)" 1
eq "M1 sample agent/metric/value" "$(sample '"\(.agent) \(.metric) \(.value)"')" "archivist causes_fixed_by_hand_twice 2"
check "M1 sample detail" "sample .detail | grep -q '^repeated=2 occurrences=6 window_days=7 recur_n=2$'"
eq "M1 0 action posts" "$(nactions)" 0
eq "M1 0 GitHub calls" "$(ngh)" 0
eq "M1 summary would=2" "$(fld would)" 2
eq "M1 summary level=observe sample=ok" "$(fld level) $(fld sample)" "observe ok"
world
run "$NOW0"
eq "M2 0 occurrences: one sample" "$(nsamples)" 1
eq "M2 the value is 0" "$(sample .value)" 0
eq "M2 0 GitHub calls" "$(ngh)" 0

# ═════ L1/L2: the level gate ═════════════════════════════════════════════════
for lv in observe none 'act;rm' OBSERVE; do
  world; rep l1 2
  if [ "$lv" = none ]; then unsetting staff.archivist.level; else setting staff.archivist.level "$lv"; fi
  run "$NOW0"
  eq "L1 [$lv] 0 action posts" "$(nactions)" 0
  eq "L1 [$lv] 0 issue POSTs" "$(nissues)" 0
  eq "L1 [$lv] 0 GitHub calls" "$(ngh)" 0
  eq "L1 [$lv] level=observe would=1" "$(fld level) $(fld would)" "observe 1"
done
for lv in file act ' FILE '; do
  world; rep l2 2; setting staff.archivist.level "$lv"
  run "$NOW0"
  eq "L2 [$lv] files one issue" "$(nissues) $(fld filed)" "1 1"
done

# ═════ F1: level file, one repeated cause, no issue ═══════════════════════════
world
C_F1=$(cdisk f1-hub); FP_F1=$(fp "$C_F1")
rep f1-hub 2
run "$NOW0"
eq "F1 rc" "$RC" 0
eq "F1 one action post" "$(nactions)" 1
A=$(tail -1 "$T/action-posts.jsonl")
eq "F1 action fields" "$(jq -r '"\(.agent) \(.lever) \(.target) \(.dryRun) \(.metric) \(.metricBefore) \(.key)"' <<<"$A")" \
  "archivist file-ticket $FP_F1 false causes_fixed_by_hand_twice 1 file:$FP_F1:$DAY0"
eq "F1 metricBefore is the sample value" "$(jq -r .metricBefore <<<"$A")" "$(sample .value)"
check "F1 action detail is the cause" "jq -e --arg c '$C_F1' '.detail == \$c' <<<'$A' >/dev/null"
eq "F1 one issue POST" "$(nissues)" 1
P=$(lastpayload)
eq "F1 labels" "$(jq -c .labels "$P")" '["ai-build","archie-fm-improve","staff:archivist"]'
check "F1 body: Cause line" "jq -r .body '$P' | grep -qxF 'Cause: \`$C_F1\`'"
check "F1 body: the marker for that fp" "jq -r .body '$P' | grep -qF '$(marker "$FP_F1")'"
check "F1 body: the occurrences" "[ \"\$(jq -r .body '$P' | grep -c 'The fix Archie applied by hand: run_cleanup -> done')\" = 2 ]"
check "F1 body: acceptance tests" "jq -r .body '$P' | grep -q '^## Acceptance tests'"
check "F1 body and title: no em dash" "! jq -r '.title, .body' '$P' | grep -q '—'"
eq "F1 title" "$(jq -r .title "$P")" "Archivist: $C_F1 fixed by hand 2 times in 7 days"
eq "F1 summary filed=1" "$(fld filed) $(fld failed) $(fld repeated)" "1 0 1"
check "F1 log line names the url" "grep -q '$FP_F1: filed https://github.com/acme/fixt-harness/issues/9001' '$H/logs/staff-archivist-lever.log'"

# ═════ F4: a second run after F1 ═════════════════════════════════════════════
run $((NOW0 + 3600))
eq "F4 second run: already=1" "$(fld already)" 1
eq "F4 second run: 0 new POSTs" "$(nissues)" 1
eq "F4 second run: 0 new action posts" "$(nactions)" 1

# ═════ R1: archie-fm-improve sees the archivist issue as its own ═════════════
OUT=$(env HARNESS_TEST_SANDBOX=1 ARCHIE_FMI_NOW=$((NOW0 + 3600)) ARCHIE_FMI_FIXTURE="$T/fx.sh" bash "$H/bin/archie-fm-improve.sh" --dry-list 2>&1)
eq "R1 --dry-list: the fp is #9001 open" "$(awk -F'\t' -v f="$FP_F1" '$1 == f {print $3}' <<<"$OUT")" "#9001 open"

# ═════ F2: three repeated causes, cap 3 ═══════════════════════════════════════
world
rep f2-a 2; rep f2-b 4; rep f2-c 3
run "$NOW0"
eq "F2 three issues" "$(nissues) $(fld filed)" "3 3"
eq "F2 highest count first" "$(grep '^ISSUE' "$T/calls.log" | sed 's/.*fixed by hand \([0-9]*\) times.*/\1/' | tr '\n' ' ')" "4 3 2 "
eq "F2 one fp per issue" "$(for f in "$T"/issue-payload.*; do jq -r .body "$f" | grep -o 'fp=[0-9a-f]*'; done | sort -u | grep -c .)" 3

# ═════ F3: the dedupe ════════════════════════════════════════════════════════
f3() { # f3 <tag> <state> <reason> <labels> <body-fp|other> [pr] -> want POSTs
  world; local c fp b
  c=$(cdisk "f3-$1"); fp=$(fp "$c"); rep "f3-$1" 2
  case "$5" in self) b="Cause: \`$c\`"$'\n'"$(marker "$fp")" ;; *) b="$(marker 0123456789ab)" ;; esac
  gh_issue 700 "$2" "$3" "$b" "$4" "" "${6:-}"
  run "$NOW0"
}
f3 open open null '["ai-build","archie-fm-improve"]' self
eq "F3 label-list open issue with the marker: 0 POSTs, already=1" "$(nissues) $(fld already)" "0 1"
eq "F3 ... and no action post" "$(nactions)" 0
f3 done closed completed '["archie-fm-improve"]' self
eq "F3 label-list closed completed: 0 POSTs, already=1" "$(nissues) $(fld already)" "0 1"
f3 np closed not_planned '["archie-fm-improve"]' self
eq "F3 label-list closed not_planned: 0 POSTs, already=1" "$(nissues) $(fld already)" "0 1"
f3 nolabel open null '["bug"]' self
eq "F3 open issue with the marker, no label: 0 POSTs, already=1" "$(nissues) $(fld already)" "0 1"
f3 other open null '["archie-fm-improve"]' other
eq "F3 a marker with another fp: 1 POST" "$(nissues) $(fld already)" "1 0"
f3 pr open null '["archie-fm-improve"]' self pr
eq "F3 a pull request with the marker: 1 POST" "$(nissues) $(fld already)" "1 0"
f3 closedbug closed completed '["bug"]' self
eq "F3 a closed issue outside the label list: 1 POST" "$(nissues) $(fld already)" "1 0"

# ═════ F5: the day cap ═══════════════════════════════════════════════════════
world; rep f5-hub 2
for n in 801 802 803; do gh_issue "$n" open null "x$n" '["archie-fm-improve"]' $((NOW0 - 3600)); done
run "$NOW0"
eq "F5 3 created today, cap 3: capped=1" "$(fld capped) $(nissues)" "1 0"
eq "F5 ... 0 action posts" "$(nactions)" 0
world; rep f5-hub 2
for n in 801 802 803; do gh_issue "$n" open null "x$n" '["archie-fm-improve"]' $((NOW0 - D)); done
run "$NOW0"
eq "F5 3 created yesterday: files" "$(fld filed) $(fld capped)" "1 0"
world; rep f5-hub 2; setting staff.archivist.file_max_day 4
for n in 801 802 803; do gh_issue "$n" open null "x$n" '["archie-fm-improve"]' $((NOW0 - 3600)); done
run "$NOW0"
eq "F5 file_max_day row 4: files" "$(fld filed) $(fld capped)" "1 0"

# ═════ F6: record before act ═════════════════════════════════════════════════
world; rep f6-hub 2
run "$NOW0"
eq "F6 the action post comes before the issue POST" "$(cut -d' ' -f1 "$T/calls.log" | tr '\n' ' ')" "ACTION ISSUE "
for st in existing 409 500; do
  world; rep "f6-$st" 2; echo "$st" > "$T/action.status"
  run "$NOW0"
  case "$st" in
    500) eq "F6 action 500: failed=1, 0 issue POSTs" "$(fld failed) $(nissues)" "1 0" ;;
    *)   eq "F6 action $st: taken=1, 0 issue POSTs" "$(fld taken) $(nissues)" "1 0" ;;
  esac
done

# ═════ F7: the filing fails ══════════════════════════════════════════════════
for st in 422 rc1; do
  world; rep "f7-$st" 2; echo "$st" > "$T/issue.status"
  run "$NOW0"
  eq "F7 [$st] failed=1 filed=0" "$(fld failed) $(fld filed)" "1 0"
  want=422; [ "$st" = rc1 ] && want=000
  check "F7 [$st] the log names HTTP $want" "grep -q 'filing answered HTTP $want' '$H/logs/staff-archivist-lever.log'"
  eq "F7 [$st] the action row stays" "$(grep -c . "$T/staff-actions.txt")" 1
  rm -f "$T/issue.status"
  run $((NOW0 + D))
  eq "F7 [$st] the next UTC day: a new key and a filing" "$(fld filed) $(nactions)" "1 2"
  check "F7 [$st] the new key is the next day" "tail -1 '$T/action-posts.jsonl' | jq -e '.key | endswith(\":2026-10-12\")' >/dev/null"
done

# ═════ E1: the kill switches ═════════════════════════════════════════════════
for k in flag:staff-off-all flag:staff-kill-all flag:staff-off-archivist flag:staff-kill-archivist env:STAFF_ENABLED=0; do
  world; rep e1 2
  case "$k" in
    flag:*) : > "$H/flags/${k#flag:}"; run "$NOW0" ;;
    env:*) run "$NOW0" STAFF_ENABLED=0 ;;
  esac
  eq "E1 [$k] rc" "$RC" 0
  eq "E1 [$k] 0 requests, 0 GitHub calls" "$(grep -c . "$T/reqlog") $(ngh)" "0 0"
  check "E1 [$k] logs killed by" "grep -q 'killed by' '$H/logs/staff-archivist-lever.log'"
done

# ═════ E2: roster inactive ═══════════════════════════════════════════════════
world; rep e2 2
jq '.agent_status = "paused"' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
run "$NOW0"
eq "E2 roster inactive: no sample, no action" "$(nsamples) $(nactions) $(ngh)" "0 0 0"

# ═════ E3: an unreadable day ═════════════════════════════════════════════════
for how in trunc down absent; do
  world; rep "e3-$how" 2
  case "$how" in
    trunc) : > "$T/trunc.2026-10-10" ;;
    down) : > "$T/down.2026-10-08" ;;
    absent) : > "$T/archie.absent" ;;
  esac
  run "$NOW0"
  eq "E3 [$how] unreadable" "$(fld causes_fixed_by_hand_twice)" unreadable
  eq "E3 [$how] 0 samples, 0 actions, 0 GitHub calls" "$(nsamples) $(nactions) $(ngh)" "0 0 0"
done

# ═════ E4: the sample fails ══════════════════════════════════════════════════
world; rep e4 2; : > "$T/metric.down"
run "$NOW0"
eq "E4 sample=failed, the filing still runs" "$(fld sample) $(fld filed)" "failed 1"

# ═════ E5: the issue lists are unreadable ════════════════════════════════════
world; rep e5 2; : > "$T/issues.down"; : > "$T/alerts.log"
run "$NOW0"
eq "E5 0 action posts, 0 POSTs" "$(nactions) $(nissues)" "0 0"
eq "E5 no ALERTS line" "$(grep -c . "$T/alerts.log")" 0
check "E5 lists=unreadable in the log" "grep -q 'lists=unreadable' '$H/logs/staff-archivist-lever.log'"

# ═════ E6: the lock is held ══════════════════════════════════════════════════
world; rep e6 2
{ flock -n 8 && run "$NOW0"; } 8>"$H/locks/staff-archivist-lever.lock"
eq "E6 lock held: rc 0, no request" "$RC $(grep -c . "$T/reqlog") $(ngh)" "0 0 0"

# ═════ N1: no forbidden call, no state file ══════════════════════════════════
eq "N1 no gh, git or curl" "$(grep -c . "$T/forbidden.log")" 0
eq "N1 no file under state/" "$(find "$H/state" -type f 2>/dev/null | grep -c .)" 0
check "N1 no model call in the lane" "! grep -qE 'claude|anthropic|llm_call' '$SRC/$LEVER_REL'"

# ═════ E1 (lane gate): the lane-off flag stops it before any request of its own
world; rep e1-lane 2; : > "$H/flags/lane-off-staff-archivist-lever"
run "$NOW0" LANE_GATE_DISABLE=0
OWN=$(grep -E '^(GET /api/staff|GET /api/archie|GET /api/settings/staff|POST /api/staff)' "$T/reqlog")
eq "E1 [lane-off] none of the lane's own requests" "${OWN:-none} $(ngh) $(nsamples)" "none 0 0"

echo "staff-archivist-lever: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
