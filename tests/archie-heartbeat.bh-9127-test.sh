#!/bin/bash
# tests/archie-heartbeat.bh-9127-test.sh — BH-9127: Archie posts a heartbeat
# (POST /api/staff/ticks, agent archie) for every orchestrate turn, every
# archie.sh tick that got its lock and every archie-research.sh run that got
# its lock, plus one activity row (POST /api/staff/turns) per turn and per
# tick that acted. bin/lib/archie-hb.sh is the one writer. It fails
# open: rc 0 always, nothing on stdout, one log line on a failed post.
#
# WHAT IS STUBBED. `_jobs_req_file` (the jobs transport) records each post to
# $T/posts.jsonl and answers from $T/req.rc / $T/req.http. A PATH `curl` shim
# counts calls: H9 requires 0 (BH-7563 item 6). archie.sh and
# archie-research.sh run from scratch trees built by scratch_install_closure,
# under their sandbox fixture seams. The clock is pinned (ARCHIE_HB_NOW,
# ARCHIE_NOW); nothing here reads the wall clock.
#
# H3 lifts the real `# >>> archie heartbeat` block and the real
# `# >>> turn exit` block from bin/orchestrate.sh. H5 lifts the real sidecar
# block and the `# >>> archie turn key` block.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-heartbeat.bh-9127-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-heartbeat: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

LIB="$DIR/bin/lib/archie-hb.sh"
SRC="$DIR/bin/orchestrate.sh"
[ -f "$LIB" ] && ok || bad "missing bin/lib/archie-hb.sh"
[ -f "$DIR/bin/archie.sh" ] && [ -f "$DIR/bin/archie-research.sh" ] && ok || bad "missing bin/archie.sh or bin/archie-research.sh"

# Fixed instants: no wall-clock read.
NOW=1793926805                       # 2026-11-06T01:00:05Z
T0=2026-11-06T01:00:00Z
T0E=1793926800
NOWISO=2026-11-06T01:00:05Z
TOKEN=ghp_fixtureFIXTUREfixture0123456789abcdef

mkdir -p "$T/fakebin" "$T/tmp"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$FXT/curl.calls"
exit 7
SH
chmod +x "$T/fakebin/curl"

# The jobs transport stub: one JSON line per post, rc and http from files.
cat > "$T/stub.sh" <<'SH'
_jobs_req_file() {
  local m="$1" p="$2" f="$3"
  jq -c --arg m "$m" --arg p "$p" '{m: $m, p: $p, b: .}' "$f" >> "$FXT/posts.jsonl"
  printf 'post %s\n' "$p" >> "$FXT/order"
  printf '%s\n' "${JOBS_ALERT:-1}" >> "$FXT/alert.flag"
  JOBS_HTTP=$(cat "$FXT/req.http" 2>/dev/null || echo 201)
  return "$(cat "$FXT/req.rc" 2>/dev/null || echo 0)"
}
# The settings read: $FXT/setting.<key> is the row; no file is no row (rc 2).
setting_get() {
  [ -f "$FXT/setting.$1" ] || return 2
  cat "$FXT/setting.$1"
}
SH

H="$T/h"
mkdir -p "$H"
scratch_install_closure bin/lib/archie-hb.sh "$H" >/dev/null || bad "scratch_install_closure bin/lib/archie-hb.sh"

reset() {
  local p
  for p in posts.jsonl order req.rc req.http hb.log stdout stderr rc reply.txt reqlog alert.flag setting.staff.turns.summary_in_max; do scratch_rm "$T/$p" || exit 1; done
}
# hb <script>: a fresh shell with the lib and the stub; stdout to $T/stdout.
hb() {
  env -u JOBS_URL -u HARNESS_SECRET PATH="$T/fakebin:$PATH" HARNESS="$H" FXT="$T" HARNESS_TEST_SANDBOX=1 \
    ARCHIE_HB_NOW="$NOW" ARCHIE_HB_LOG="$T/hb.log" TMPDIR="$T/tmp" \
    bash -c 'set -uo pipefail; . "$HARNESS/bin/lib/archie-hb.sh" || exit 90; . "$FXT/stub.sh"; '"$1" \
    > "$T/stdout" 2>"$T/stderr"
  echo $? > "$T/rc"
}
posts() { local n=0; [ -f "$T/posts.jsonl" ] && n=$(jq -s --arg p "$1" '[.[] | select(.p == $p)] | length' "$T/posts.jsonl"); echo "${n:-0}"; }
body()  { jq -c --arg p "$1" 'select(.p == $p) | .b' "$T/posts.jsonl" 2>/dev/null | head -n1; }
lines() { local n=0; [ -f "$1" ] && n=$(grep -c . "$1"); echo "${n:-0}"; }
COUNTS='["collected","new_items","deferred","model_calls","digested","filed","refused","unsupported","failed","held"]'

# ═════ H1: a tick post ═══════════════════════════════════════════════════════
reset
hb "archie_hb_tick turn $T0 done 0 1 0; echo rc=\$? >&2; archie_hb_key turn $T0 > \"\$FXT/key\""
eq H1_rc "$(cat "$T/rc")" 0
eq H1_fn_rc "$(cat "$T/stderr")" "rc=0"
eq H1_one_post "$(posts /api/staff/ticks)" 1
B=$(body /api/staff/ticks)
eq H1_method "$(jq -r 'select(.p == "/api/staff/ticks") | .m' "$T/posts.jsonl" 2>/dev/null)" POST
eq H1_agent "$(jq -r .agent <<<"$B")" archie
grep -Eq '^archie-turn-[0-9]+-[0-9]+$' <<<"$(jq -r .tick_key <<<"$B")" && ok || bad "H1 tick_key shape: $(jq -r .tick_key <<<"$B")"
eq H1_key_is_turn_key "$(jq -r .tick_key <<<"$B")" "$(cat "$T/key" 2>/dev/null)"
grep -Eq "^archie-turn-$T0E-[0-9]+\$" <<<"$(cat "$T/key" 2>/dev/null)" && ok || bad "H1 archie_hb_key turn <started_at> uses that instant: $(cat "$T/key" 2>/dev/null)"
eq H1_started "$(jq -r .started_at <<<"$B")" "$T0"
eq H1_ended "$(jq -r .ended_at <<<"$B")" "$NOWISO"
eq H1_phase "$(jq -r .phase <<<"$B")" done
eq H1_counts_int "$(jq -c --argjson c "$COUNTS" '[$c[] as $f | .[$f] | (type == "number" and . == floor)] | all' <<<"$B")" true
eq H1_model_calls "$(jq -r .model_calls <<<"$B")" 1
eq H1_nulls "$(jq -c '[.collector_rc, .collector_s, .model_rc, .cost_run_id]' <<<"$B")" "[null,null,null,null]"
eq H1_stdout_empty "$(cat "$T/stdout")" ""
eq H1_no_log_on_success "$(lines "$T/hb.log")" 0

# ═════ H2: a failed post is rc 0, silent, one log line ═══════════════════════
reset; echo 1 > "$T/req.rc"; echo 503 > "$T/req.http"
hb "archie_hb_tick sweep $T0 done 2 0 1; echo rc=\$? >&2"
eq H2_rc "$(cat "$T/stderr")" "rc=0"
eq H2_stdout_empty "$(cat "$T/stdout")" ""
eq H2_one_line "$(lines "$T/hb.log")" 1
# The post opts out of the transport's daily ALERTS line (JOBS_ALERT=0,
# bin/lib/jobs/req.sh _jobs_log): a heartbeat is optional, its failure is the
# heartbeat log line only.
eq H2_no_alert_line "$(sort -u "$T/alert.flag" 2>/dev/null | tr '\n' ' ')" "0 "
grep -Eq "^$NOWISO archie-heartbeat: tick archie-sweep-$T0E-[0-9]+ post failed rc=1 http=503\$" "$T/hb.log" \
  && ok || bad "H2 log line: $(cat "$T/hb.log" 2>/dev/null)"
# A 409 (rc 9) is not a 2xx either.
reset; echo 9 > "$T/req.rc"; echo 409 > "$T/req.http"; printf 'done\n' > "$T/reply.txt"
hb "archie_hb_turn archie-turn-$T0E-7 $T0 beat answered \"\$FXT/reply.txt\"; echo rc=\$? >&2"
eq H2_turn_rc "$(cat "$T/stderr")" "rc=0"
grep -Eq "archie-heartbeat: turn archie-turn-$T0E-7 post failed rc=9 http=409\$" "$T/hb.log" \
  && ok || bad "H2 turn log line: $(cat "$T/hb.log" 2>/dev/null)"
eq H2_turn_one_line "$(lines "$T/hb.log")" 1
# No transport at all (no _jobs_req_file, no jobs-client under the root): rc 0, logged.
reset
env -u JOBS_URL -u HARNESS_SECRET PATH="$T/fakebin:$PATH" HARNESS="$T/noroot" FXT="$T" HARNESS_TEST_SANDBOX=1 \
  ARCHIE_HB_NOW="$NOW" ARCHIE_HB_LOG="$T/hb.log" TMPDIR="$T/tmp" \
  bash -c '. "'"$H"'/bin/lib/archie-hb.sh"; archie_hb_tick turn '"$T0"' done 0 1 0; echo rc=$?' > "$T/stdout" 2>/dev/null
eq H2_no_transport_rc "$(cat "$T/stdout")" "rc=0"
grep -q 'post failed' "$T/hb.log" && ok || bad "H2 no transport is one log line: $(cat "$T/hb.log" 2>/dev/null)"

# ═════ H3: the orchestrate block runs after the reply and fails open ═════════
eq H3_block_once "$(grep -c '^# >>> archie heartbeat' "$SRC")" 1
eq H3_block_end "$(grep -c '^# <<< archie heartbeat' "$SRC")" 1
TAIL=$(sed -n '/^deliver_reply "\$OUT" "\$REPLY_ERR"$/,/^# <<< archie heartbeat/p' "$SRC")
grep -q 'archie_hb_turn' <<<"$TAIL" && ok || bad "H3 the lift from deliver_reply to '# <<< archie heartbeat' holds no archie_hb_turn: the block is missing or before the reply"
grep -q '^# >>> reply status' <<<"$TAIL" && ok || bad "H3 the heartbeat block must come after the reply-status block"
orc_tail() { # orc_tail <reply-err>
  hb "deliver_reply() { printf 'reply %s\n' \"\$1\" >> \"\$FXT/order\"; }
      cmd_status() { printf 'status %s\n' \"\$1\" >> \"\$FXT/order\"; }
      ORCT_KEY=''; ORCT_HB=''; OUT='Filed BH-1'; REPLY_ERR='$1'; ORC_REPF=\"\$FXT/reply.txt\"
      ARCHIE_TURN_KEY=archie-turn-$T0E-42; ARCHIE_TURN_T0=$T0; ARCHIE_TURN_TRIGGER=telegram
      $TAIL
      echo after >> \"\$FXT/order\""
}
reset; echo 1 > "$T/req.rc"; echo 0 > "$T/req.http"; printf 'Filed BH-1\n' > "$T/reply.txt"
orc_tail ""
eq H3_rc "$(cat "$T/rc")" 0
eq H3_first_is_reply "$(head -n1 "$T/order" 2>/dev/null)" "reply Filed BH-1"
eq H3_order "$(grep -v '^status ' "$T/order" 2>/dev/null | tr '\n' '|')" "reply Filed BH-1|post /api/staff/ticks|post /api/staff/turns|after|"
eq H3_two_log_lines "$(lines "$T/hb.log")" 2
grep -q "turn archie-turn-$T0E-42 post failed rc=1" "$T/hb.log" && ok || bad "H3 the turn failure is logged: $(cat "$T/hb.log" 2>/dev/null)"
eq H3_stdout_empty "$(cat "$T/stdout")" ""
reset; printf 'Filed BH-1\n' > "$T/reply.txt"
orc_tail ""
B=$(body /api/staff/turns)
eq H3_answered "$(jq -r .outcome <<<"$B")" answered
eq H3_turn_key "$(jq -r .turn_key <<<"$B")" "archie-turn-$T0E-42"
eq H3_trigger "$(jq -r .trigger <<<"$B")" telegram
eq H3_cost_run "$(jq -r .cost_run_id <<<"$B")" "staff-turn:archie-turn-$T0E-42"
eq H3_tick_done "$(jq -r .phase <<<"$(body /api/staff/ticks)")" done
reset; printf '(finished with no reply) boom\n' > "$T/reply.txt"
orc_tail no_reply
eq H3_no_reply "$(jq -r .outcome <<<"$(body /api/staff/turns)")" no_reply

# orc_on_exit: a turn that stopped after its claim posts tick (act) + turn (stopped).
EXIT_BLOCK=$(sed -n '/^# >>> turn exit/,/^# <<< turn exit/p' "$SRC")
grep -q 'trap orc_on_exit EXIT' <<<"$EXIT_BLOCK" && ok || bad "H3 the turn-exit block lift is empty"
stop_turn() { # stop_turn <ORCT_KEY> <ORCT_SKIP_NOREPLY> <_LEDGER_DONE> <CMD_ID>
  hb "ORC=\"\$FXT/orc\"; CMD_ID='$4'
      ledger_reply() { printf 'ledger %s\n' \"\$2\" >> \"\$FXT/order\"; _LEDGER_DONE=1; }
      cmd_status() { :; }
      $EXIT_BLOCK
      ORCT_KEY='$1'; ORCT_SKIP_NOREPLY=$2; _LEDGER_DONE=$3
      ARCHIE_TURN_KEY=archie-turn-$T0E-43; ARCHIE_TURN_T0=$T0; ARCHIE_TURN_TRIGGER=slack
      exit 3"
}
reset; stop_turn k1 0 0 ""
eq H3_stop_rc_kept "$(cat "$T/rc")" 3
eq H3_stop_tick "$(posts /api/staff/ticks)" 1
eq H3_stop_turn "$(posts /api/staff/turns)" 1
eq H3_stop_phase "$(jq -r .phase <<<"$(body /api/staff/ticks)")" act
B=$(body /api/staff/turns)
eq H3_stop_outcome "$(jq -r .outcome <<<"$B")" stopped
eq H3_stop_summary "$(jq -r .summary <<<"$B")" "(the turn stopped before answering)"
eq H3_stop_trigger "$(jq -r .trigger <<<"$B")" slack
eq H3_stop_cost "$(jq -r .cost_run_id <<<"$B")" "staff-turn:archie-turn-$T0E-43"
reset; stop_turn k1 0 0 c-fixture-1
eq H3_stop_with_cmd_turn "$(posts /api/staff/turns)" 1
grep -q '^ledger no_reply' "$T/order" && ok || bad "H3 the stopped turn still posts its no_reply ledger row"
reset; stop_turn "" 0 0 ""
eq H3_preclaim_nothing "$(posts /api/staff/ticks)/$(posts /api/staff/turns)" "0/0"
reset; stop_turn k1 1 0 ""
eq H3_copy_turn_nothing "$(posts /api/staff/ticks)/$(posts /api/staff/turns)" "0/0"
reset; stop_turn k1 0 1 ""
eq H3_replied_nothing "$(posts /api/staff/turns)" 0

# Every orc-monitor model call of a turn carries its cost run id.
NL=$(grep -c 'AGENT_CALL_LANE=orc-monitor' "$SRC")
NC=$(grep 'AGENT_CALL_LANE=orc-monitor' "$SRC" | grep -c 'COST_RUN_ID=staff-turn:\$ARCHIE_TURN_KEY')
[ "${NL:-0}" -ge 4 ] && [ "$NL" = "$NC" ] && ok || bad "H3 every AGENT_CALL_LANE=orc-monitor line sets COST_RUN_ID=staff-turn:\$ARCHIE_TURN_KEY ($NC of $NL)"

# ═════ H4: the turn body ═════════════════════════════════════════════════════
reset
printf '\n  \nFiled BH-1 and BH-2\nPR https://github.com/example-org/cromford/pull/12?x=1 then https://github.com/example-org/cromford/issues/99\n' > "$T/reply.txt"
hb "archie_hb_turn archie-turn-$T0E-44 $T0 telegram answered \"\$FXT/reply.txt\" staff-turn:archie-turn-$T0E-44"
B=$(body /api/staff/turns)
eq H4_rc "$(cat "$T/rc")" 0
eq H4_agent "$(jq -r .agent <<<"$B")" archie
eq H4_summary "$(jq -r .summary <<<"$B")" "Filed BH-1 and BH-2"
eq H4_link "$(jq -r .link_url <<<"$B")" "https://github.com/example-org/cromford/pull/12"
eq H4_cost "$(jq -r .cost_run_id <<<"$B")" "staff-turn:archie-turn-$T0E-44"
eq H4_times "$(jq -r '[.started_at, .ended_at] | join(" ")' <<<"$B")" "$T0 $NOWISO"
eq H4_trigger_outcome "$(jq -r '[.trigger, .outcome] | join(" ")' <<<"$B")" "telegram answered"
eq H4_stdout_empty "$(cat "$T/stdout")" ""
reset; printf 'the token %s leaked\nno link here\n' "$TOKEN" > "$T/reply.txt"
hb "archie_hb_turn archie-turn-$T0E-45 $T0 beat answered \"\$FXT/reply.txt\""
B=$(body /api/staff/turns)
eq H4_redacted "$(jq -r .summary <<<"$B")" "the token <redacted:github-token> leaked"
grep -qF "$TOKEN" "$T/posts.jsonl" && bad "H4 the fixture token reached the post" || ok
eq H4_no_link "$(jq -r '.link_url | tostring' <<<"$B")" null
eq H4_no_cost "$(jq -r '.cost_run_id | tostring' <<<"$B")" null
# A link the route refuses (LINK_RE: no _ in an owner, no leading 0) is skipped
# for the next one, so the post never turns into a 400 that loses the row.
reset; printf 'Done\nsee https://github.com/bad_owner/r/pull/1 and https://github.com/o/r/pull/012 then https://github.com/example-org/cromford/issues/7\n' > "$T/reply.txt"
hb "archie_hb_turn archie-turn-$T0E-49 $T0 beat answered \"\$FXT/reply.txt\""
eq H4_link_route_shape "$(jq -r .link_url <<<"$(body /api/staff/turns)")" "https://github.com/example-org/cromford/issues/7"
reset; head -c 2500 /dev/zero | tr '\0' 'a' > "$T/reply.txt"; printf '\n' >> "$T/reply.txt"
hb "archie_hb_turn archie-turn-$T0E-46 $T0 beat answered \"\$FXT/reply.txt\""
eq H4_cut_2000 "$(jq -r '.summary | length' <<<"$(body /api/staff/turns)")" 2000
# The cut is the route's own bound, the settings row staff.turns.summary_in_max.
reset; head -c 2500 /dev/zero | tr '\0' 'a' > "$T/reply.txt"; printf '\n' >> "$T/reply.txt"; echo 120 > "$T/setting.staff.turns.summary_in_max"
hb "archie_hb_turn archie-turn-$T0E-50 $T0 beat answered \"\$FXT/reply.txt\""
eq H4_cut_knob "$(jq -r '.summary | length' <<<"$(body /api/staff/turns)")" 120
# A bad row value is the fallback 2000, never a 0-length cut.
reset; head -c 2500 /dev/zero | tr '\0' 'a' > "$T/reply.txt"; printf '\n' >> "$T/reply.txt"; echo 0 > "$T/setting.staff.turns.summary_in_max"
hb "archie_hb_turn archie-turn-$T0E-51 $T0 beat answered \"\$FXT/reply.txt\""
eq H4_cut_bad_knob "$(jq -r '.summary | length' <<<"$(body /api/staff/turns)")" 2000
# The scrub cannot run: the summary is withheld, never sent raw.
reset; printf 'the token %s leaked\n' "$TOKEN" > "$T/reply.txt"
hb "token_redact() { return 1; }; archie_hb_turn archie-turn-$T0E-47 $T0 beat answered \"\$FXT/reply.txt\""
eq H4_scrub_failed "$(jq -r .summary <<<"$(body /api/staff/turns)")" "(summary withheld: scrub failed)"
H2D="$T/h-noscrub"; mkdir -p "$H2D"
scratch_install_closure bin/lib/archie-hb.sh "$H2D" >/dev/null && scratch_rm "$H2D/bin/lib/token-redact.sh"
reset; printf 'the token %s leaked\n' "$TOKEN" > "$T/reply.txt"
env PATH="$T/fakebin:$PATH" HARNESS="$H2D" FXT="$T" HARNESS_TEST_SANDBOX=1 ARCHIE_HB_NOW="$NOW" ARCHIE_HB_LOG="$T/hb.log" TMPDIR="$T/tmp" \
  bash -c '. "$HARNESS/bin/lib/archie-hb.sh"; . "$FXT/stub.sh"; archie_hb_turn archie-turn-'"$T0E"'-48 '"$T0"' beat answered "$FXT/reply.txt"' >/dev/null 2>&1
eq H4_no_scrub_lib "$(jq -r .summary <<<"$(body /api/staff/turns)")" "(summary withheld: scrub failed)"
grep -qF "$TOKEN" "$T/posts.jsonl" && bad "H4 the token was sent with no scrub" || ok

# ═════ H5: the trigger table, through the real sidecar + turn key blocks ═════
META_BLOCK=$(sed -n '/^ORIGIN=""; CMD_ID=""/,/^\[ "\$TG_OK" = 1 \]/p' "$SRC")
KEY_BLOCK=$(sed -n '/^# >>> archie turn key/,/^# <<< archie turn key/p' "$SRC")
grep -q 'ARCHIE_TURN_TRIGGER' <<<"$KEY_BLOCK" && ok || bad "H5 the '# >>> archie turn key' block is missing"
OH="$T/orch"; mkdir -p "$OH/env"
scratch_install_closure bin/lib/orc-reply-ledger.sh "$OH" >/dev/null || bad "H5 install orc-reply-ledger.sh"
scratch_install_closure bin/lib/archie-hb.sh "$OH" >/dev/null || bad "H5 install archie-hb.sh"
printf 'TELEGRAM_BOT_TOKEN=tok-fixture-1\nTELEGRAM_CHAT_ID=-1000000000000\n' > "$OH/env/global.env"
trig() { # trig <meta-json|->
  scratch_rm "$OH/msg.meta"; printf 'hello' > "$OH/msg"
  [ "$1" = - ] || printf '%s\n' "$1" > "$OH/msg.meta"
  env -u HARNESS_ENV_DIR -u CMD_ID PATH="$T/fakebin:$PATH" HARNESS="$OH" MSGF="$OH/msg" HARNESS_TEST_SANDBOX=1 ARCHIE_HB_NOW="$NOW" \
    bash -c "set -uo pipefail
      HARNESS=\"\$HARNESS\"; MSGF=\"\$MSGF\"
      . \"$DIR/bin/lib/env-path.sh\"; HENV=\$(harness_env_dir \"\$HARNESS\")
      $META_BLOCK
      $KEY_BLOCK
      printf '%s %s %s' \"\$ARCHIE_TURN_TRIGGER\" \"\$ARCHIE_TURN_T0\" \"\$ARCHIE_TURN_KEY\"" 2>/dev/null
}
R=$(trig '{"origin":"dash","command_id":"1","from_name":"the operator"}')
eq H5_dash "${R%% *}" dash
eq H5_t0 "$(cut -d' ' -f2 <<<"$R")" "$NOWISO"
grep -Eq "^archie-turn-$NOW-[0-9]+\$" <<<"$(cut -d' ' -f3 <<<"$R")" && ok || bad "H5 turn key: $R"
R=$(trig '{"transport":"slack","command_id":"2","from_name":"the operator"}');    eq H5_slack "${R%% *}" slack
R=$(trig '{"transport":"telegram","command_id":"3","from_name":"the operator"}'); eq H5_telegram "${R%% *}" telegram
R=$(trig '{"command_id":"4","from_name":"the operator"}');                        eq H5_absent_transport "${R%% *}" telegram
R=$(trig -);                                                              eq H5_no_meta "${R%% *}" beat
R=$(trig '{"transport":"telegram","command_id":"5","from_name":""}');     eq H5_empty_from "${R%% *}" beat
R=$(trig '{"transport":"slack","command_id":"6"}');                       eq H5_slack_no_from "${R%% *}" beat

# ═════ H6: once per process ═════════════════════════════════════════════════
reset; printf 'x\n' > "$T/reply.txt"
hb "archie_hb_tick turn $T0 done 0 1 0; archie_hb_tick turn $T0 done 0 1 0
    archie_hb_turn archie-turn-$T0E-49 $T0 beat answered \"\$FXT/reply.txt\"; archie_hb_turn archie-turn-$T0E-49 $T0 beat answered \"\$FXT/reply.txt\""
eq H6_one_tick "$(posts /api/staff/ticks)" 1
eq H6_one_turn "$(posts /api/staff/turns)" 1

# ═════ H7: bin/archie.sh tick ═══════════════════════════════════════════════
AH="$T/ah"; mkdir -p "$AH/bin" "$AH/env" "$AH/logs"
: > "$AH/env/global.env"
for s in archie-tg-send.sh alert-line.sh lane-alert.sh; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/sends.log"\nexit 0\n' > "$AH/bin/$s"; chmod +x "$AH/bin/$s"
done
printf '#!/bin/bash\nprintf "call\\n" >> "$FXT/agentcalls"\n: > "$5"\nexit 0\n' > "$AH/bin/agent-call.sh"; chmod +x "$AH/bin/agent-call.sh"
scratch_install_closure bin/archie.sh "$AH" >/dev/null && scratch_install_closure bin/jobs-client.sh "$AH" >/dev/null || bad "H7 install the bin/archie.sh and bin/jobs-client.sh closures"
{ cat "$T/stub.sh"; cat <<'SH'
_jobs_req() {
  local m="$1" p="$2"
  printf '%s %s\n' "$m" "$p" >> "$FXT/reqlog"
  JOBS_HTTP=200
  case "$m ${p%%\?*}" in
    "GET /api/settings") printf '{"settings":[]}'; return 0 ;;
    "GET /api/initiatives")
      case "$p" in *'?id='*) printf '{"initiative":{"id":1,"status":"active"}}'; return 0 ;; esac
      cat "$FXT/initiatives.json"; return 0 ;;
    "GET /api/initiatives/events")
      [ -f "$FXT/event.none" ] && { JOBS_HTTP=404; return 2; }
      printf '{"event":{"status":"composed","body":"I1 moved: fixture beat body","value":"","attempts":1}}'; return 0 ;;
    "POST /api/initiatives/check"|"PUT /api/ledger") printf '{"ok":true}'; return 0 ;;
    "GET /api/ledger")
      case "$p" in *'key='*) JOBS_HTTP=404; return 2 ;; esac
      case "$p" in *'kind=archie_followup'*) [ -f "$FXT/followups.json" ] && { cat "$FXT/followups.json"; return 0; } ;; esac
      printf '{"ledgers":[]}'; return 0 ;;
  esac
  JOBS_HTTP=404; return 2
}
lane_role_model() { echo test-model; }
archie_repo_activity_block() { return 1; }
SH
} > "$T/afx.sh"
init_row() { # init_row <next_check_at>
  jq -nc --arg n "$1" '{initiatives: [{id: 1, slug: "init-1", goal: "Fixture goal", metric_query: "none", cadence_hours: 168,
    escalation_rule: "always", status: "active", next_check_at: $n, links: [], last_value: null}], truncated: false}' > "$T/initiatives.json"
}
areset() {
  reset
  local p; for p in initiatives.json event.none followups.json sends.log agentcalls; do scratch_rm "$T/$p" || exit 1; done
  scratch_rm "$AH/state" || exit 1; scratch_rm "$AH/locks" || exit 1; scratch_rm "$AH/logs/archie.log" || exit 1
  printf '{"initiatives":[],"truncated":false}' > "$T/initiatives.json"
}
atick() {
  env JOBS_URL=https://jobs.invalid HARNESS_SECRET=fixture-secret PATH="$T/fakebin:$PATH" HARNESS="$AH" FXT="$T" HARNESS_TEST_SANDBOX=1 \
    ARCHIE_NOW="$NOW" ARCHIE_HB_NOW="$NOW" ARCHIE_HB_LOG="$T/hb.log" ARCHIE_FIXTURE="$T/afx.sh" ARCHIE_TIMED=1 \
    LANE_GATE_DISABLE=1 TMPDIR="$T/tmp" "$@" bash "$AH/bin/archie.sh" tick > "$T/stdout" 2>"$T/stderr"
  echo $? > "$T/rc"
}
# 0 due: one tick, no turn.
areset; atick
eq H7_due0_rc "$(cat "$T/rc")" 0
eq H7_due0_tick "$(posts /api/staff/ticks)" 1
eq H7_due0_turn "$(posts /api/staff/turns)" 0
B=$(body /api/staff/ticks)
grep -Eq "^archie-sweep-$NOW-[0-9]+\$" <<<"$(jq -r .tick_key <<<"$B")" && ok || bad "H7 sweep tick key: $(jq -r .tick_key <<<"$B")"
eq H7_due0_fields "$(jq -r '[.agent, .phase, .started_at] | join(" ")' <<<"$B")" "archie done $NOWISO"
# 1 beat: one tick, one turn (trigger sweep, outcome acted, the tick's own line).
areset; init_row 2026-11-06T00:45:00Z; atick
eq H7_beat_rc "$(cat "$T/rc")" 0
eq H7_beat_sent "$(lines "$T/sends.log")" 1
eq H7_beat_tick "$(posts /api/staff/ticks)" 1
eq H7_beat_turn "$(posts /api/staff/turns)" 1
B=$(body /api/staff/ticks)
eq H7_beat_counts "$(jq -c '[.collected, .model_calls, .digested]' <<<"$B")" "[1,0,1]"
B=$(body /api/staff/turns)
eq H7_beat_trigger "$(jq -r '[.trigger, .outcome] | join(" ")' <<<"$B")" "sweep acted"
eq H7_beat_summary "$(jq -r .summary <<<"$B")" "due=1 checked=1 beats=1 model_calls=0 skipped=0"
grep -qF "$(jq -r .summary <<<"$B")" "$AH/logs/archie.log" && ok || bad "H7 the turn summary is the tick's own log line"
eq H7_beat_cost_null "$(jq -r '.cost_run_id | tostring' <<<"$B")" null
# 1 model call and no beat: still a turn.
areset; init_row 2026-11-06T00:45:00Z; : > "$T/event.none"; atick
eq H7_call_made "$(lines "$T/agentcalls")" 1
eq H7_call_turn "$(posts /api/staff/turns)" 1
eq H7_call_summary "$(jq -r .summary <<<"$(body /api/staff/turns)")" "due=1 checked=1 beats=0 model_calls=1 skipped=0"
# Every initiative skipped (not due on this side): a tick, no turn.
areset; init_row 2026-11-06T02:00:00Z; atick
grep -q 'skipped=1' "$AH/logs/archie.log" && ok || bad "H7 the skipped-only tick logs skipped=1: $(cat "$AH/logs/archie.log" 2>/dev/null)"
eq H7_skipped_tick "$(posts /api/staff/ticks)" 1
eq H7_skipped_turn "$(posts /api/staff/turns)" 0
# A follow-up woke the initiative: trigger follow-up.
areset; init_row 2026-11-06T00:45:00Z
jq -nc '{ledgers: [{kind: "archie_followup", key: "fu-fixture-1", status: "pending", updated_at: "2026-11-05T00:00:00Z",
  detail: ({due_at: "2026-11-06T00:30:00Z", initiative_id: 1, note: "check the fixture"} | tojson)}]}' > "$T/followups.json"
atick
eq H7_followup_trigger "$(jq -r .trigger <<<"$(body /api/staff/turns)")" follow-up
# The lock is held: nothing posts.
areset; init_row 2026-11-06T00:45:00Z; mkdir -p "$AH/locks"
exec 8>"$AH/locks/archie.lock"; flock -n 8 || bad "H7 could not take the lock for the held case"
atick
exec 8>&-
eq H7_locked_rc "$(cat "$T/rc")" 0
eq H7_locked_nothing "$(posts /api/staff/ticks)/$(posts /api/staff/turns)" "0/0"
# ARCHIE_ENABLED=0: nothing posts.
areset; init_row 2026-11-06T00:45:00Z; atick ARCHIE_ENABLED=0
eq H7_disabled_nothing "$(posts /api/staff/ticks)/$(posts /api/staff/turns)" "0/0"

# ═════ H8: bin/archie-research.sh ═══════════════════════════════════════════
RH="$T/rh"; mkdir -p "$RH/bin" "$RH/env" "$T/rtmp"
: > "$RH/env/global.env"
scratch_install_closure bin/archie-research.sh "$RH" >/dev/null || bad "H8 install the bin/archie-research.sh closure"
{ cat "$T/stub.sh"; printf '%s\n' '_jobs_req() { printf "%s %s\n" "$1" "$2" >> "$FXT/reqlog"; JOBS_HTTP=503; return 1; }'; } > "$T/rfx.sh"
reset
env -u JOBS_URL -u HARNESS_SECRET PATH="$T/fakebin:$PATH" HARNESS="$RH" FXT="$T" HARNESS_TEST_SANDBOX=1 \
  ARCHIE_NOW="$NOW" ARCHIE_HB_NOW="$NOW" ARCHIE_HB_LOG="$T/hb.log" ARCHIE_RESEARCH_FIXTURE="$T/rfx.sh" ARCHIE_RESEARCH_TIMED=1 \
  LANE_GATE_DISABLE=1 TMPDIR="$T/rtmp" bash "$RH/bin/archie-research.sh" scan > "$T/stdout" 2>"$T/stderr"
eq H8_rc "$?" 0
grep -q 'spend unreadable' "$RH/logs/archie-research.log" 2>/dev/null && ok || bad "H8 the scan ran past its lock: $(cat "$RH/logs/archie-research.log" 2>/dev/null)"
eq H8_tick "$(posts /api/staff/ticks)" 1
B=$(body /api/staff/ticks)
grep -Eq "^archie-research-$NOW-[0-9]+\$" <<<"$(jq -r .tick_key <<<"$B")" && ok || bad "H8 research tick key: $(jq -r .tick_key <<<"$B")"
eq H8_turn "$(posts /api/staff/turns)" 0
eq H8_w_removed "$(find "$T/rtmp" -maxdepth 1 -name 'archie-research.*' | wc -l | tr -d ' ')" 0

# ═════ H9: no vendor and no network ═════════════════════════════════════════
eq H9_curl_calls "$(lines "$T/curl.calls")" 0

echo "archie-heartbeat: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
