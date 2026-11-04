#!/bin/bash
# tests/archie-cards.bh-8817-test.sh — BH-8817 (C0): a Tackler card goes to
# Archie first; the operator is paged only on Archie's "needs-operator" answer or when a
# card is still open past the settings row unblock.archie_answer_max_min.
#
#   R1-R4  bin/lib/unblock/card.sh unblock_card_route / unblock_card_send /
#          ubt_stage_card: route archie = ROUTED_ARCHIE, 0 alerts, outcome
#          escalated, card .route and .class; route operator and every unreadable
#          or unknown row = today's SENT_CARD; shadow = WOULD_SEND_CARD; R4 is
#          the plan's REPRO command, verbatim.
#   P1-P8  the SHIPPED bin/unblock.sh tick: the timeout sweep, the page-once
#          state, legacy rows, a BH-8766 wait record, a failed page, paging
#          past 100 rows, UNBLOCK_ACT=0 and shadow, the Archie claim lease.
#   P9     the record POST fails after ROUTED_ARCHIE: the operator is paged direct,
#          once, with the card's alert id (the card is in no ledger row).
#   P10    /route answers 404 (a worker with no route yet): the sweep pages.
#   A1-A8  the SHIPPED bin/archie-cards.sh tick: claim before spend, the
#          prompt fence, the three answers, the refusals, the off switches, the
#          per-tick cap, 0 vendor calls.
#   L1-L8  Archie's levers in the SHIPPED bin/archie-cards.sh: the ub_act
#          record is built from the ledger row for each lever, done = an
#          `acted` answer with the lever, a lever that does not fit or that
#          the writer refuses = needs-operator and one page, ARCHIE_CARDS_ACT,
#          the REAL writer's never-auto gate, invalid lever answers.
#   L9     lever rebuild runs main's REAL rebuild arm (BH-8736): the phase to
#          planned, then launch_fastpath; a refused phase = needs-operator;
#          re_offer launches with no phase write.
#   L10    the ticket key from both subject formats (ticket:<p>:<KEY> and
#          the lifecycle collector's <p>:<KEY>), only when it is a ticket key.
#   P3b    a card from main's ask arm (no .route) is never swept or claimed.
#   U1-U6  the SHIPPED bin/unblock-reply.sh archie verb (and intercept
#          unchanged); U6 the acted answer and its lever.
#   M1-M2  the SHIPPED bin/unblock-metrics.sh daily: the cards line.
#   M3     the digest line prints the worker's T11 counts as sent (W10's
#          answer: direct cards counted as operator 3; acted 0 is still printed).
#   G1-G2  the rule miner's read: bin/lib/unblock/archie-repeats.sh uar_list,
#          and the SHIPPED bin/rule-miner.sh (dry run) bundles one incident
#          per repeated Archie answer.
#
# STUBS. The jobs API is a curl stub on PATH: it answers $JURL from a file row
# store ($FXT/rows.json) with the worker's status codes for the routes these
# scripts call (worker/jobs/test/unblock-cards.bh-8817.test.js pins the real
# worker). Every request is one `JOBS <method> <path> <body>` line in
# $FXT/seq.log. A curl to any other URL, and every gh call, is one line in
# $T/net.log and exit 7. bin/lane-alert.sh and bin/agent-call.sh are logging
# stubs in the scratch harness. bin/unblock.sh reads settings rows through its
# UNBLOCK_FIXTURE (setting_get over $FXT/settings/<key>); bin/archie-cards.sh
# reads the model route through its ARCHIE_CARDS_FIXTURE. With $FXT/ubact.stub
# present, that fixture also replaces ub_act with a logging stub (one `UBACT
# <record> UNBLOCK_ACT=<v>` line, the outcome and detail from the file), so the
# lever cases pin the record the lane builds; L6 runs the REAL writer.
#
# MUTATIONS (D1), each tried once by hand: send every act card to lane-alert
# (drop the route branch) -> R1, R4 red; read the route row as archie when it
# is unreadable -> R2 red; drop the age check in the sweep -> P1 red; drop the
# paged_at check -> P2 red; ignore the claim lease -> P8 red; call agent-call
# before the archie-claim -> A1, A4 red; accept `Hold` -> A5 red; drop the
# per-tick cap -> A7 red; drop the card.route check in the reply verb -> U2 red;
# drop the direct page after a failed record -> P9 red; drop the PR-subject
# check of the PR levers -> L3 red; answer acted on a refused lever -> L4 red;
# rebuild as launch_fastpath -> L2, L9 red; the infra subject regex only ->
# L10 red; no UB_TICKET_RE check on the key -> L10 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-cards.bh-8817-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { grep -qF -- "$3" "$2" 2>/dev/null && ok || bad "$1: [$3] not in $2: $(head -c 800 "$2" 2>/dev/null)"; }
hasnt() { if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1: [$3] in $2"; else ok; fi; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

for SRC in "$REPO/bin/archie-cards.sh" "$REPO/bin/lib/unblock/card.sh" "$REPO/bin/unblock.sh" \
           "$REPO/bin/unblock-reply.sh" "$REPO/bin/unblock-metrics.sh" "$REPO/catalog/prompts/archie-card.md" \
           "$REPO/catalog/lanes.d/archie-cards.json" "$REPO/cron/lanes/778-archie-cards.cron" \
           "$REPO/catalog/llm-sites.d/8817-archie-card.json" "$REPO/catalog/context-budgets.d/8817-archie-card.json" \
           "$REPO/catalog/lanes.d/unblock.knobs.d/UNBLOCK_CARD_SWEEP_PAGES.json" \
           "$REPO/worker/jobs/src/routes/unblock-cards.js" "$REPO/worker/jobs/src/lib/core.d/bh-8817-unblock-cards.js" \
           "$REPO/worker/jobs/schema.d/202611032326-bh-8817-archie-cards.sql"; do
  [ -e "$SRC" ] || bad "missing ${SRC#"$REPO"/}"
done

# ═════ R4: the plan's REPRO, verbatim (run from the repo root) ═══════════════
( cd "$REPO" && bash -c 'T=$(mktemp -d); mkdir -p $T/bin; printf "#!/bin/sh\necho \"\$@\" >> $T/alerts\n" > $T/bin/lane-alert.sh; chmod +x $T/bin/lane-alert.sh; echo "{\"id\":\"u-abcdef\",\"key\":\"abcdef0123456789\",\"options\":[\"hold\",\"x\"],\"recommendation\":2,\"text\":\"TACKLER CARD u-abcdef x\"}" > $T/card.json; setting_get(){ echo archie; }; . bin/lib/unblock/card.sh; out=$(HARNESS=$T UNBLOCK_ACT=1 unblock_card_send $T/card.json act); echo "$out"; [ "${out%% *}" = ROUTED_ARCHIE ] && test ! -s $T/alerts' ) > "$T/repro.out" 2>&1
eq "R4 the REPRO command exits 0 ($(head -c 300 "$T/repro.out"))" "$?" 0

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"; FB="$T/fakebin"; COL="$T/collectors"
mkdir -p "$H/bin" "$H/env" "$H/catalog/prompts" "$H/catalog/unblock-rules.d" "$FB" || exit 1
: > "$H/env/global.env"
printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$H/fleet.conf"
for S in bin/unblock.sh bin/archie-cards.sh bin/unblock-reply.sh bin/unblock-metrics.sh bin/fleet-conf.sh \
         bin/jobs-client.sh bin/lib/unblock/rules.sh bin/lib/unblock/card.sh; do
  [ -e "$REPO/$S" ] || continue
  ( cd "$REPO" && scratch_install_closure "$S" "$H" ) >/dev/null || { echo "setup: closure $S"; exit 1; }
done
cp "$REPO"/catalog/unblock-rules.d/*.json "$H/catalog/unblock-rules.d/"
cp "$REPO/catalog/prompts/unblock-decide.md" "$H/catalog/prompts/"
[ -r "$REPO/catalog/prompts/archie-card.md" ] && cp "$REPO/catalog/prompts/archie-card.md" "$H/catalog/prompts/"
rm -f "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh"
# lane-alert: logs, answers $FXT/alert.rc (default 0).
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf 'ALERT %s\n' "$(printf '%s' "$*" | tr '\n' '|')" >> "$FXT/seq.log"
exit "$(cat "$FXT/alert.rc" 2>/dev/null || echo 0)"
SH
# agent-call: logs the stage and the env, keeps the prompt, answers
# $FXT/answer.<stage> (none = empty) and $FXT/agent.rc (default 0).
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
n=$(( $(cat "$FXT/ac.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/ac.n"
printf 'AGENTCALL %s %s %s %s tools=%s lane=%s fp=%s\n' "$1" "$2" "$3" "$4" "${AGENT_CALL_NO_TOOLS:-}" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_FP:-}" >> "$FXT/seq.log"
cp "${6#@}" "$FXT/prompt.$1.$n" 2>/dev/null
rc=$(cat "$FXT/agent.rc" 2>/dev/null || echo 0)
if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then exit "$rc"; fi
if [ -f "$FXT/answer.$1" ]; then cat "$FXT/answer.$1" > "$5"; else : > "$5"; fi
exit "$rc"
SH
# launch-fastpath: logs, answers $FXT/fp.rc (default 0). act.sh runs it by path.
cat > "$H/bin/launch-fastpath.sh" <<'SH'
#!/bin/bash
printf 'FASTPATH %s\n' "$*" >> "$FXT/seq.log"
exit "$(cat "$FXT/fp.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh" "$H/bin/launch-fastpath.sh"
for b in gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$FB/$b"
  chmod +x "$FB/$b"
done

JURL="http://jobs.fixture.test"
cat > "$FB/curl" <<'SH'
#!/bin/bash
m=GET url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m=$2; shift 2 ;;
    --data-binary|-d) data=$2; shift 2 ;;
    -m|--connect-timeout|-w|-H|-o) shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$url" in "$JURL"/*) ;; *) echo "curl $url" >> "$NETLOG"; exit 7 ;; esac
case "$data" in @*) data=$(cat "${data#@}") ;; esac
printf 'JOBS %s %s %s\n' "$m" "${url#"$JURL"}" "$data" >> "$FXT/seq.log"
# shellcheck disable=SC1091
. "$ROUTER"
route "$m" "${url#"$JURL"}" "$data"
SH
chmod +x "$FB/curl"
# The fake worker over $FXT/rows.json. Status codes as the routes answer them.
cat > "$T/router.sh" <<'SH'
ans() { printf '%s\n%s' "$2" "$1"; exit 0; }
qp() { local v; v=$(sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p" <<<"$2"); printf '%b' "${v//%/\\x}"; }
nowiso() { date -u -d "@$(cat "$FXT/now")" +%Y-%m-%dT%H:%M:%SZ; }
rows() { cat "$FXT/rows.json"; }
put() { jq -c "$@" "$FXT/rows.json" > "$FXT/rows.tmp" && mv "$FXT/rows.tmp" "$FXT/rows.json"; }
row() { jq -c --argjson i "$1" '[.[] | select(.id == $i)] | first // empty' "$FXT/rows.json"; }
route() {
  local m=$1 p=$2 d=$3 id r verb k
  if [[ ${p%%\?*} =~ ^/api/unblock/decisions/([0-9]+)/(answer|archie-claim|route|paged)$ ]]; then
    id=${BASH_REMATCH[1]}; verb=${BASH_REMATCH[2]}
    [ -f "$FXT/$verb.code" ] && ans "$(cat "$FXT/$verb.code")" '{"error":"forced"}'
    r=$(row "$id"); [ -n "$r" ] || ans 404 '{"error":"decision not found"}'
    case "$verb" in
      answer)
        k=$(jq -r '.command_id // ""' <<<"$d")
        [ -n "$k" ] && [ "$(jq -r '.answer_command_id // ""' <<<"$r")" = "$k" ] && ans 409 '{"duplicate":true}'
        [ "$(jq -r .outcome <<<"$r")" = escalated ] || ans 422 '{"error":"not_escalated"}'
        if [ "$(jq -r .answered_by <<<"$d")" = archie ]; then
          [ "$(jq -r '.source // ""' <<<"$d")" = archie ] || ans 403 '{"error":"agent_answerer"}'
          [ "$(jq -r '.routed_to // ""' <<<"$r")" = "" ] || ans 422 '{"error":"not_escalated","outcome":"routed"}'
        fi
        put --argjson i "$id" --argjson b "$d" --arg t "$(nowiso)" 'map(if .id == $i then . + {outcome: "answered",
          answer: $b.answer, answered_by: $b.answered_by, answer_source: ($b.source // null), answer_command_id: $b.command_id,
          answered_at: $t, outcome_detail: ($b.note // .outcome_detail)} else . end)'
        ans 200 '{"ok":true}' ;;
      archie-claim)
        [ "$(jq -r .outcome <<<"$r")" = escalated ] || ans 422 '{"error":"not_escalated"}'
        jq -e '.archie_claimed_at == null and .routed_to == null' >/dev/null <<<"$r" || ans 409 '{"error":"claimed"}'
        put --argjson i "$id" --arg t "$(nowiso)" 'map(if .id == $i then .archie_claimed_at = $t else . end)'
        ans 200 '{"ok":true}' ;;
      route)
        [ "$(jq -r .outcome <<<"$r")" = escalated ] || ans 422 '{"error":"not_escalated"}'
        jq -e --argjson b "$d" '.routed_to == null and ($b.claimed_before == null or .archie_claimed_at == null
          or .archie_claimed_at < $b.claimed_before)' >/dev/null <<<"$r" || ans 409 '{"error":"routed"}'
        put --argjson i "$id" --argjson b "$d" --arg t "$(nowiso)" 'map(if .id == $i then . + {routed_to: "operator",
          routed_at: $t, route_reason: "\($b.by): \($b.reason)"} else . end)'
        ans 200 '{"ok":true}' ;;
      paged)
        jq -e '.routed_to == "operator" and .paged_at == null' >/dev/null <<<"$r" || ans 409 '{"error":"paged"}'
        put --argjson i "$id" --arg t "$(nowiso)" 'map(if .id == $i then .paged_at = $t else . end)'
        ans 200 '{"ok":true}' ;;
    esac
  fi
  case "$m ${p%%\?*}" in
    "GET /api/unblock/decisions")
      [ -f "$FXT/list.code" ] && ans "$(cat "$FXT/list.code")" '{"error":"forced"}'
      ans 200 "$(jq -c --arg o "$(qp outcome "$p")" --arg pr "$(qp project "$p")" --arg c "$(qp card "$p")" \
        --arg b "$(qp before_id "$p")" --arg l "$(qp limit "$p")" '
        ($l | if . == "" then 50 else tonumber end) as $lim
        | [.[] | select(($c == "" or .card.id == $c) and (($o == "" and $c == "") or .outcome == ($o | if . == "" then "escalated" else . end))
            and ($pr == "" or .project == $pr) and ($b == "" or .id < ($b | tonumber)))]
        | sort_by(-.id) | .[0:$lim] as $d
        | {limit: $lim, decisions: $d, next_before_id: (if ($d | length) == $lim then $d[-1].id else null end)}' "$FXT/rows.json")" ;;
    "POST /api/unblock/decisions/claim")
      k=$(jq -r .decision_key <<<"$d")
      r=$(jq -c --arg k "$k" '[.[] | select(.decision_key == $k)] | first // empty' "$FXT/rows.json")
      [ -n "$r" ] && ans 409 "$(jq -c '{claimed: false, id, outcome, decision}' <<<"$r")"
      id=$(( $(jq '[.[].id] | max // 0' "$FXT/rows.json") + 1 ))
      put --argjson i "$id" --argjson b "$d" --arg t "$(nowiso)" '. + [$b + {id: $i, outcome: "claimed", created_at: $t,
        card: null, routed_to: null, routed_at: null, route_reason: null, paged_at: null, archie_claimed_at: null, answer_source: null}]'
      ans 200 "{\"claimed\":true,\"id\":$id}" ;;
    "POST /api/unblock/decisions/record")
      [ -f "$FXT/record.code" ] && ans "$(cat "$FXT/record.code")" '{"error":"forced"}'
      k=$(jq -r .decision_key <<<"$d")
      put --arg k "$k" --argjson b "$d" 'map(if .decision_key == $k and .outcome == "claimed" then . + {outcome: $b.outcome,
        outcome_detail: $b.outcome_detail, card: ($b.card // .card)} else . end)'
      ans 200 '{"ok":true}' ;;
    "GET /api/unblock/cards/daily")
      [ -f "$FXT/daily.code" ] && ans "$(cat "$FXT/daily.code")" '{"error":"forced"}'
      ans 200 "$(jq -c --arg p "$(qp project "$p")" --arg d "$(qp day "$p")" '{project: $p, day: $d} + .' "$FXT/daily.json")" ;;
    "GET /api/unblock/metrics") ans 200 "$(cat "$FXT/metrics.json")" ;;
    "GET /api/unblock/cards/repeats")
      [ -f "$FXT/repeats.code" ] && ans "$(cat "$FXT/repeats.code")" '{"error":"forced"}'
      ans 200 "$(jq -c --arg s "$(qp since "$p")" --arg m "$(qp min "$p")" '{since: $s, min: ($m | tonumber), repeats: .}' "$FXT/repeats.json")" ;;
    "GET /api/settings") ans 200 "$(cat "$FXT/settings.json")" ;;
    # one row by key (jobs-client.sh setting-get, act.sh's mode read): only
    # the rows a case writes to $FXT/wsettings/<key>, else no row (404).
    "GET /api/settings/"*) k=${p#/api/settings/}
      [ -f "$FXT/wsettings/$k" ] && ans 200 "$(jq -nc --arg k "$k" --arg v "$(cat "$FXT/wsettings/$k")" '{setting: {key: $k, value: $v}}')" ;;
  esac
  ans 404 '{"error":"no route"}'
}
SH
# The unblock.sh and archie-cards.sh fixtures (sandbox seams).
cat > "$T/fx.sh" <<'SH'
setting_get() {
  [ -f "$FXT/settings/$1.fail" ] && return 1
  [ -f "$FXT/settings/$1" ] || return 2
  cat "$FXT/settings/$1"
}
lane_gate_or_exit() { printf 'GATE %s\n' "$*" >> "$FXT/seq.log"; [ -f "$FXT/lane-off" ] && exit 0; return 0; }
lane_env_apply() { return 0; }
lane_role_model() { printf 'ROUTE %s\n' "$*" >> "$FXT/seq.log"; [ -f "$FXT/route.none" ] && return 1; printf 'model-fixture\n'; }
# lifecycle_transition (bin/lib/jobs/lifecycle.sh, #8731): with $FXT/lt.rc a
# logging stub, so L9 runs main's REAL rebuild arm (BH-8736) with no worker.
if [ -f "$FXT/lt.rc" ]; then
  lifecycle_transition() { printf 'LT %s\n' "$*" >> "$FXT/seq.log"; return "$(cat "$FXT/lt.rc")"; }
fi
if [ -f "$FXT/ubact.stub" ]; then
  ub_act() {
    printf 'UBACT %s UNBLOCK_ACT=%s\n' "$1" "${UNBLOCK_ACT:-}" >> "$FXT/seq.log"
    IFS=$'\t' read -r UB_ACT_OUTCOME UB_ACT_DETAIL < "$FXT/ubact.stub"
    [ "$UB_ACT_OUTCOME" = rc1 ] && { UB_ACT_OUTCOME="" UB_ACT_DETAIL=""; return 1; }
    printf '%s\t%s\n' "$UB_ACT_OUTCOME" "$UB_ACT_DETAIL"; return 0
  }
fi
SH

export HARNESS_SECRET=fixture-harness-secret JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 JOBS_SETTINGS_CACHE_S=0 GH_ETAG=0
NOW=1790000000                                   # 2026-09-21T13:46:40Z
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ago() { iso $((NOW - $1 * 60)); }                # ago <minutes>
modes() { # modes <mode> — the settings cache bin/lib/unblock/scope.sh reads
  mkdir -p "$H/state"
  jq -nc --argjson fa "$NOW" --arg m "$1" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": $m}, seeded: {}}' \
    > "$H/state/settings-cache.json"
}
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/flags" "$H/locks" "$FXT" "$COL"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT/settings" "$H/flags" "$COL"
  : > "$FXT/seq.log"; echo '[]' > "$FXT/rows.json"; echo "$NOW" > "$FXT/now"
  echo 1 > "$FXT/settings/unblock.enabled"
  echo archie > "$FXT/settings/unblock.route_to"
  modes act
}
# card <key> [route|-] [recommend-wait] — a card from the REAL composer
# (unblock_card_compose over the deterministic fallback), plus .route.
card() {
  ( . "$REPO/bin/lib/unblock/card.sh"
    jq -nc --arg k "$1" '{kind: "box-hung", subject: ("box:orgo-" + $k[0:4]), project: "cromford", decision_key: $k,
      ssh_unreachable_min: 40}' > "$T/stall.json"
    if [ "${3:-}" = wait ]; then
      echo '{"what":"w","options":["wait for the next probe","hold: keep it parked"],"recommendation":1,"reason":"r"}' > "$T/dec.json"
    else
      unblock_card_fallback "$T/stall.json" > "$T/dec.json"
    fi
    unblock_card_compose "$T/stall.json" "$T/dec.json" "$1" "$NOW" ) | jq -c --arg r "${2:--}" 'if $r == "-" then . else . + {route: $r, class: "infra-restart"} end'
}
# seed <id> <key> <route|-> <age-min> [jq filter] — one escalated ledger row.
seed() {
  local c; c=$(card "$2" "$3" "${6:-}")
  jq -c --argjson i "$1" --arg k "$2" --argjson c "$c" --arg t "$(ago "$4")" --arg f "${5:-.}" '. + [({id: $i, decision_key: $k,
    project: "cromford", repo: "example-org/cromford", subject_kind: "box", subject: $c.subject, decision: "escalate",
    stall_class: "box-hung", evidence: {ssh_unreachable_min: 40, envbundle_fail_1h: 5}, outcome: "escalated", card: $c,
    created_at: $t, routed_to: null, routed_at: null, route_reason: null, paged_at: null, archie_claimed_at: null,
    answer: null, answered_by: null, answer_source: null, answer_command_id: null})]' "$FXT/rows.json" > "$FXT/rows.tmp" \
    && mv "$FXT/rows.tmp" "$FXT/rows.json"
  [ "${5:-.}" = . ] || { jq -c --argjson i "$1" "map(if .id == \$i then ($5) else . end)" "$FXT/rows.json" > "$FXT/rows.tmp" && mv "$FXT/rows.tmp" "$FXT/rows.json"; }
}
k12() { ( . "$REPO/bin/lib/unblock/card.sh"; _unblock_card_hex "$1" | cut -c1-12 ); }   # the alert id key
fld() { jq -r --argjson i "$1" ".[] | select(.id == \$i) | $2" "$FXT/rows.json"; }
RUNENV=(HARNESS="$H" FXT="$FXT" ROUTER="$T/router.sh" NETLOG="$T/net.log" JURL="$JURL" JOBS_URL="$JURL" HARNESS_TEST_SANDBOX=1
  LANE_GATE_DISABLE=1 LANE_GATE_NOW=$NOW LANE_GATE_CACHE_S=60 FLEET_CONF="$H/fleet.conf" PATH="$FB:$PATH" TMPDIR="$T")
tick() { # the shipped Tackler tick
  env "${RUNENV[@]}" UNBLOCK_FIXTURE="$T/fx.sh" UNBLOCK_COLLECTORS_DIR="$COL" UNBLOCK_TIMED=1 UNBLOCK_NOW=$NOW UB_NOW=$NOW "$@" \
    bash "$H/bin/unblock.sh" tick --project cromford > "$T/tick.out" 2>&1
}
atick() { # the shipped Archie card lane
  env "${RUNENV[@]}" ARCHIE_CARDS_FIXTURE="$T/fx.sh" ARCHIE_CARDS_TIMED=1 ARCHIE_CARDS_NOW=$NOW "$@" \
    bash "$H/bin/archie-cards.sh" tick > "$T/atick.out" 2>&1
}
reply() { env "${RUNENV[@]}" bash "$H/bin/unblock-reply.sh" "$@" 2>"$T/reply.err"; }
alerts() { cnt '^ALERT ' "$FXT/seq.log"; }
posts() { cnt "^JOBS POST /api/unblock/decisions/[0-9]*/$1 " "$FXT/seq.log"; }
calls() { cnt '^AGENTCALL archie-card ' "$FXT/seq.log"; }
ULOG="$H/logs/unblock.log"; ALOG="$H/logs/archie-cards.log"

# ═════ R1-R3: the route (card.sh, sourced) ═══════════════════════════════════
# rsend <setting_get body|undef> <mode> [card-route] — prints the send line and
# the alert count.
rsend() {
  ( mkdir -p "$T/r/bin"; : > "$T/r/alerts"
    printf '#!/bin/sh\necho "$@" >> %s/r/alerts\n' "$T" > "$T/r/bin/lane-alert.sh"; chmod +x "$T/r/bin/lane-alert.sh"
    [ "$1" = undef ] || eval "setting_get() { $1; }"
    . "$REPO/bin/lib/unblock/card.sh"
    jq -nc --arg r "${3:-}" '{id: "u-abc123", key: "abc1230000000000", options: ["hold", "x"], recommendation: 2,
      text: "TACKLER CARD u-abc123 x"} + (if $r == "" then {} else {route: $r} end)' > "$T/r/card.json"
    out=$(HARNESS="$T/r" UNBLOCK_ACT=1 unblock_card_send "$T/r/card.json" "$2"); echo "$out $(grep -c . "$T/r/alerts")"
    echo "route=$(unblock_card_route)" )
}
out=$(rsend 'printf archie' act)
eq "R1 act + route archie: ROUTED_ARCHIE, 0 alerts" "$(head -1 <<<"$out")" "ROUTED_ARCHIE u-abc123 0"
eq "R2 route operator: SENT_CARD + 1 alert" "$(head -1 <<<"$(rsend 'printf operator' act)")" "SENT_CARD u-abc123 1"
for C in 'return 2' 'return 1' undef 'printf Archie' 'printf ""' 'printf archie,operator' 'printf archie; return 1'; do
  eq "R2 [$C] resolves to operator" "$(tail -1 <<<"$(rsend "$C" act)")" "route=operator"
done
eq "R2 [' archie\\n'] (trimmed) resolves to archie" "$(tail -1 <<<"$(rsend 'printf " archie\n"' act)")" "route=archie"
eq "R2 a card .route operator wins over the row archie" "$(head -1 <<<"$(rsend 'printf archie' act operator)")" "SENT_CARD u-abc123 1"
eq "R2 a card .route archie wins over the row operator" "$(head -1 <<<"$(rsend 'printf operator' act archie)")" "ROUTED_ARCHIE u-abc123 0"
eq "R3 shadow + archie: WOULD_SEND_CARD, 0 alerts" "$(head -1 <<<"$(rsend 'printf archie' shadow)")" "WOULD_SEND_CARD u-abc123 0"

# R1 ubt_stage_card: outcome escalated, card .route and .class
out=$( mkdir -p "$T/r1/bin" "$T/r1/catalog/prompts"; : > "$T/r1/alerts"
  printf '#!/bin/sh\necho "$@" >> %s/r1/alerts\n' "$T" > "$T/r1/bin/lane-alert.sh"
  printf '#!/bin/sh\n: > "$5"\n' > "$T/r1/bin/agent-call.sh"; chmod +x "$T/r1/bin/"*.sh
  cp "$REPO/catalog/prompts/unblock-decide.md" "$T/r1/catalog/prompts/"
  setting_get() { printf archie; }
  . "$REPO/bin/lib/unblock/card.sh"
  D=$(jq -nc '{decision_key: "r1key00000000", project: "cromford", subject: "box:orgo-7", class: "infra-restart",
    decision: "escalate", evidence: {ssh_unreachable_min: 40}}')
  HARNESS="$T/r1" UNBLOCK_ACT=1 UBT_CLAIMED_KEY=r1key00000000 UB_NOW=$NOW ubt_stage_card "$D" m-fixture act; echo "alerts=$(grep -c . "$T/r1/alerts")" )
eq "R1 ubt_stage_card outcome escalated" "$(head -1 <<<"$out" | jq -r .outcome)" escalated
eq "R1 ubt_stage_card card .route/.class" "$(head -1 <<<"$out" | jq -r '"\(.card.route) \(.card.class)"')" "archie infra-restart"
eq "R1 ubt_stage_card 0 alerts" "$(tail -1 <<<"$out")" "alerts=0"

# ═════ P1: the timeout sweep inside the shipped Tackler tick ═════════════════
reset; seed 7 p1key0000001 archie 61
tick UNBLOCK_ACT=1
eq "P1 61 min, knob absent (60): route, alert, paged in that order" \
  "$(grep -oE '^(JOBS POST /api/unblock/decisions/7/(route|paged)|ALERT)' "$FXT/seq.log" | tr '\n' ';')" \
  "JOBS POST /api/unblock/decisions/7/route;ALERT;JOBS POST /api/unblock/decisions/7/paged;"
eq "P1 the route body: to operator, by timeout" "$(grep '^JOBS POST /api/unblock/decisions/7/route ' "$FXT/seq.log" | sed 's/^[^{]*//' | jq -r '"\(.to) \(.by)"')" "operator timeout"
has "P1 the alert id is unblock-<key12>, critical" "$FXT/seq.log" "ALERT --critical --id unblock-$(k12 p1key0000001) --severity critical"
has "P1 the alert says NEEDS OPERATOR" "$FXT/seq.log" "NEEDS OPERATOR:"
eq "P1 row routed and paged" "$(fld 7 '"\(.routed_to) \(.paged_at != null)"')" "operator true"
case "$(grep ' tick cromford mode=act' "$ULOG" | tail -1)" in *" sweep_paged=1") ok ;; *) bad "P1 tick line has sweep_paged=1: $(tail -3 "$ULOG")" ;; esac
reset; seed 7 p1key0000002 archie 59; tick UNBLOCK_ACT=1
eq "P1 59 min: 0 route POSTs, 0 alerts" "$(posts route) $(alerts)" "0 0"
case "$(grep ' tick cromford mode=act' "$ULOG" | tail -1)" in *sweep_paged*) bad "P1 59 min: no sweep_paged field" ;; *) ok ;; esac
reset; seed 7 p1key0000003 archie 31; echo 30 > "$FXT/settings/unblock.archie_answer_max_min"; tick UNBLOCK_ACT=1
eq "P1 knob 30 + 31 min: 1 route, 1 alert" "$(posts route) $(alerts)" "1 1"
for K in abc 0 4 1441; do
  reset; seed 7 p1key0000004 archie 31; echo "$K" > "$FXT/settings/unblock.archie_answer_max_min"; tick UNBLOCK_ACT=1
  eq "P1 knob [$K] -> 60 used: 31 min does not page" "$(posts route) $(alerts)" "0 0"
  has "P1 knob [$K] one log line" "$ULOG" "unblock.archie_answer_max_min"
done

# ═════ P2: routed to the operator by Archie; page once; BH-8766 severity ═════════════
reset; seed 8 p2key0000001 archie 10 '.routed_to = "operator" | .route_reason = "archie: money"'
tick UNBLOCK_ACT=1
eq "P2 routed_to operator, paged_at null: 1 alert, 1 paged POST" "$(alerts) $(posts paged)" "1 1"
has "P2 the page carries Archie's reason" "$FXT/seq.log" "NEEDS OPERATOR: archie: money"
: > "$FXT/seq.log"; tick UNBLOCK_ACT=1
eq "P2 second tick: paged_at set, 0 alerts" "$(alerts) $(posts paged)" "0 0"
reset; seed 8 p2key0000002 archie 10 '.routed_to = "operator" | .route_reason = "archie: x"' wait
tick UNBLOCK_ACT=1
has "P2 a wait-recommended card pages as warn" "$FXT/seq.log" "ALERT --id unblock-$(k12 p2key0000002) --severity warn"
hasnt "P2 a wait-recommended card has no --critical" "$FXT/seq.log" "--critical"

# ═════ P3: a legacy row (no card.route) ══════════════════════════════════════
reset; seed 9 p3key0000001 - 300; tick UNBLOCK_ACT=1
eq "P3 legacy row 5 h old: 0 alerts, 0 POSTs" "$(alerts) $(cnt '^JOBS POST' "$FXT/seq.log")" "0 0"
# P3b: an escalated row from main's ask arm (BH-8736): .lifecycle, no .route.
reset; seed 9 p3bkey000001 - 300 '.subject_kind = "build" | .subject = "cromford:BH-8817" | .stall_class = "ticket-plan-blocked"
  | .card.lifecycle = {project: "cromford", ticket_key: "BH-8817"}'
eq "P3b the ask row has no route" "$(fld 9 '.card.route // "none"')" none
tick UNBLOCK_ACT=1
eq "P3b ask row 5 h old: 0 sweep pages, 0 route POSTs" "$(alerts) $(posts route)" "0 0"
echo '{"pick":"hold","reason":"x"}' > "$FXT/answer.archie-card"; atick
eq "P3b ask row: 0 Archie claims, 0 calls" "$(posts archie-claim) $(calls)" "0 0"

# ═════ P4: a BH-8766 wait record: no escalate, no route, no page ═════════════
reset
jq -nc '{kind: "pr-verdict-old-head", family: "queue", project: "cromford", repo: "example-org/cromford",
  subject: "example-org/cromford#8663", pr: 8663, head: "1f3578d000000000000000000000000000000000", old_verdict: "MERGE",
  lead_request_open: false, idle_min: 5, restamp_idle_min: 20, request_id: "none", priority: 5}' > "$FXT/lines.jsonl"
printf 'ub_collect_fixture() { cat "$FXT/lines.jsonl"; }\n' > "$COL/fixture.sh"
tick UNBLOCK_ACT=1
eq "P4 a wait record: 0 claims, 0 route POSTs, 0 alerts" \
  "$(cnt '^JOBS POST /api/unblock/decisions/claim' "$FXT/seq.log") $(posts route) $(alerts)" "0 0 0"
has "P4 the tick waited" "$ULOG" "waited=1"

# ═════ P5: a failed page is not stamped and is sent again with the same id ═══
reset; seed 10 p5key0000001 archie 10 '.routed_to = "operator" | .route_reason = "archie: x"'; echo 1 > "$FXT/alert.rc"
tick UNBLOCK_ACT=1
eq "P5 lane-alert rc 1: 1 alert, 0 paged POSTs" "$(alerts) $(posts paged)" "1 0"
rm -f "$FXT/alert.rc"; : > "$FXT/seq.log"; tick UNBLOCK_ACT=1
eq "P5 next tick: sent again, then paged" "$(alerts) $(posts paged)" "1 1"
has "P5 the same alert id" "$FXT/seq.log" "--id unblock-$(k12 p5key0000001)"

# ═════ P6: the archie row on page 2 ══════════════════════════════════════════
reset
jq -c --arg t "$(ago 5)" --argjson c "$(card legacy000000 -)" '. + [range(2; 102) as $i | {id: $i, decision_key: "legacy\($i)",
  project: "cromford", outcome: "escalated", card: $c, created_at: $t, routed_to: null, paged_at: null, archie_claimed_at: null}]' \
  "$FXT/rows.json" > "$FXT/rows.tmp" && mv "$FXT/rows.tmp" "$FXT/rows.json"
seed 1 p6key0000001 archie 61
tick UNBLOCK_ACT=1
eq "P6 the 101st escalated row is read on page 2 and paged" "$(cnt 'before_id=2' "$FXT/seq.log") $(alerts)" "1 1"
reset
jq -c --arg t "$(ago 5)" --argjson c "$(card legacy000000 -)" '. + [range(2; 102) as $i | {id: $i, decision_key: "legacy\($i)",
  project: "cromford", outcome: "escalated", card: $c, created_at: $t, routed_to: null, paged_at: null, archie_claimed_at: null}]' \
  "$FXT/rows.json" > "$FXT/rows.tmp" && mv "$FXT/rows.tmp" "$FXT/rows.json"
seed 1 p6key0000002 archie 61
tick UNBLOCK_ACT=1 UNBLOCK_CARD_SWEEP_PAGES=1
eq "P6 UNBLOCK_CARD_SWEEP_PAGES=1: page 2 not read, 0 alerts" "$(cnt 'before_id=' "$FXT/seq.log") $(alerts)" "0 0"
has "P6 sweep truncated logged" "$ULOG" "sweep truncated"

# ═════ P7: UNBLOCK_ACT=0 still pages; shadow never sweeps ════════════════════
reset; seed 7 p7key0000001 archie 61; tick UNBLOCK_ACT=0
eq "P7 UNBLOCK_ACT=0, mode act: the sweep still pages" "$(alerts)" 1
reset; modes shadow; seed 7 p7key0000002 archie 61; tick UNBLOCK_ACT=1
eq "P7 mode shadow: 0 list reads, 0 alerts" "$(cnt '^JOBS GET /api/unblock/decisions' "$FXT/seq.log") $(alerts)" "0 0"

# ═════ P8: the Archie claim lease ════════════════════════════════════════════
reset; seed 7 p8key0000001 archie 70 ".archie_claimed_at = \"$(ago 5)\""; tick UNBLOCK_ACT=1
eq "P8 claimed 5 min ago (lease 15): 0 route POSTs, 0 alerts" "$(posts route) $(alerts)" "0 0"
reset; seed 7 p8key0000002 archie 70 ".archie_claimed_at = \"$(ago 20)\""; tick UNBLOCK_ACT=1
eq "P8 claimed 20 min ago: routed and paged" "$(posts route) $(alerts)" "1 1"
eq "P8 the route POST carries claimed_before = now - 15 min" \
  "$(grep '^JOBS POST /api/unblock/decisions/7/route ' "$FXT/seq.log" | sed 's/^[^{]*//' | jq -r .claimed_before)" "$(ago 15)"
reset; seed 7 p8key0000003 archie 70; echo 409 > "$FXT/route.code"; tick UNBLOCK_ACT=1
eq "P8 /route 409 (Archie won): 0 alerts" "$(posts route) $(alerts)" "1 0"

# ═════ A1: Archie works a card the SHIPPED Tackler tick escalated ════════════
reset
jq -nc '{kind: "box-hung", family: "infra", project: "cromford", subject: "box:orgo-7", stall_at_hour: "2026-10-30T11",
  orgo_hosted: true, orgo_state: "running", ssh_unreachable_min: 40, hung_min_threshold: 30, envbundle_fail_1h: 5,
  last_restart_min_ago: 10, build_claim_10m: false}' > "$FXT/lines.jsonl"
printf 'ub_collect_fixture() { cat "$FXT/lines.jsonl"; }\n' > "$COL/fixture.sh"
tick UNBLOCK_ACT=1
eq "A1 setup: the tick escalated one card routed to archie, 0 alerts" \
  "$(jq -r '[.[] | select(.outcome == "escalated" and .card.route == "archie")] | length' "$FXT/rows.json") $(alerts)" "1 0"
RID=$(jq -r '.[0].id' "$FXT/rows.json"); CID=$(jq -r '.[0].card.id' "$FXT/rows.json")
: > "$FXT/seq.log"
echo '{"pick":"none","reason":"PR already merged"}' > "$FXT/answer.archie-card"
atick
eq "A1 claim before agent-call" "$(grep -oE "^(JOBS POST /api/unblock/decisions/$RID/archie-claim|AGENTCALL archie-card)" "$FXT/seq.log" | tr '\n' ';')" \
  "JOBS POST /api/unblock/decisions/$RID/archie-claim;AGENTCALL archie-card;"
has "A1 one bounded, tool-less call on stage archie-card" "$FXT/seq.log" "AGENTCALL archie-card cromford model-fixture 120 tools=1 lane=archie-cards fp=archie-card:"
has "A1 the route role is stage.archie" "$FXT/seq.log" "ROUTE stage.archie cromford"
P=$(ls "$FXT"/prompt.archie-card.* 2>/dev/null | head -1)
[ -n "$P" ] && awk '/^<<<UNTRUSTED$/{f=1;next} /^UNTRUSTED>>>$/{f=0} f' "$P" > "$T/fence.txt"
has "A1 the fence holds the card id" "$T/fence.txt" "$CID"
has "A1 the fence holds an evidence field" "$T/fence.txt" "ssh_unreachable_min"
eq "A1 the answer POST" "$(grep "^JOBS POST /api/unblock/decisions/$RID/answer " "$FXT/seq.log" | sed 's/^[^{]*//' | jq -c '{answer, answered_by, source, command_id}')" \
  "{\"answer\":\"none\",\"answered_by\":\"archie\",\"source\":\"archie\",\"command_id\":\"archie-$CID\"}"
eq "A1 the row is answered, source archie" "$(fld "$RID" '"\(.outcome) \(.answer_source)"')" "answered archie"
eq "A1 0 alerts" "$(alerts)" 0
has "A1 the lane log line" "$ALOG" "archie-cards cromford seen=1 claimed=1 calls=1 answered=1 routed=0 deferred=0"
: > "$FXT/seq.log"; tick UNBLOCK_ACT=1
eq "A1 the next Tackler tick: 0 alerts" "$(alerts)" 0

# ═════ A2: hold, and JSON inside prose ═══════════════════════════════════════
reset; seed 7 a2key0000001 archie 5
printf 'Here is my answer.\n{"pick":"hold","reason":"the box restarts at 12:00"}\nDone.\n' > "$FXT/answer.archie-card"
atick
eq "A2 prose around the JSON: answer hold" "$(fld 7 '"\(.outcome) \(.answer)"')" "answered hold"
eq "A2 0 alerts" "$(alerts)" 0

# ═════ A3: needs-operator routes, and the next Tackler tick pages once ═══════════
reset; seed 7 a3key0000001 archie 5
echo '{"pick":"needs-operator","reason":"money: a spend cap change"}' > "$FXT/answer.archie-card"
atick
eq "A3 needs-operator: 1 route POST by archie, 0 answer POSTs" \
  "$(posts route) $(posts answer) $(grep '/7/route ' "$FXT/seq.log" | sed 's/^[^{]*//' | jq -r .by)" "1 0 archie"
eq "A3 0 alerts from the lane" "$(alerts)" 0
tick UNBLOCK_ACT=1; tick UNBLOCK_ACT=1
eq "A3 two Tackler ticks: one page" "$(alerts)" 1
has "A3 the page carries Archie's reason" "$FXT/seq.log" "NEEDS OPERATOR: archie: money: a spend cap change"

# ═════ A4: claim 409, no route, agent-call refused, empty answer ═════════════
reset; seed 7 a4key0000001 archie 5; echo 409 > "$FXT/archie-claim.code"; echo '{"pick":"hold","reason":"x"}' > "$FXT/answer.archie-card"
atick; eq "A4 claim 409: 0 agent-calls, 0 answers" "$(calls) $(posts answer)" "0 0"
reset; seed 7 a4key0000002 archie 5; touch "$FXT/route.none"; echo '{"pick":"hold","reason":"x"}' > "$FXT/answer.archie-card"
atick; eq "A4 no model route: claimed, 0 agent-calls" "$(posts archie-claim) $(calls)" "1 0"
reset; seed 7 a4key0000003 archie 5; echo 75 > "$FXT/agent.rc"; echo '{"pick":"hold","reason":"x"}' > "$FXT/answer.archie-card"
atick; eq "A4 agent-call rc 75: 1 attempt, 0 answers" "$(cnt '^AGENTCALL' "$FXT/seq.log") $(posts answer)" "1 0"
atick; eq "A4 rc 75: the claim holds, no second call" "$(cnt '^AGENTCALL' "$FXT/seq.log")" 1
reset; seed 7 a4key0000004 archie 5; : > "$FXT/answer.archie-card"
atick; eq "A4 empty answer: 1 call, 0 answers, 0 routes" "$(calls) $(posts answer) $(posts route)" "1 0 0"

# ═════ A5: invalid picks ═════════════════════════════════════════════════════
for J in '{"pick":"Hold","reason":"x"}' '{"pick":"act","reason":"x"}' '{"pick":"2","reason":"x"}' \
         '{"pick":"none","reason":""}' '{"pick":"none"}' '{"pick":"needs operator","reason":"x"}' \
         '{"pick":"hold","reason":"a"} broken {"pick":"none","reason":"b"}'; do
  reset; seed 7 a5key0000001 archie 5; printf '%s\n' "$J" > "$FXT/answer.archie-card"
  atick; eq "A5 [$J]: 1 call, 0 answers, 0 routes" "$(calls) $(posts answer) $(posts route)" "1 0 0"
  # The lane itself refuses the answer (not only the reply verb behind it).
  has "A5 [$J]: the lane logs it invalid" "$ALOG" "invalid answer (billed, terminal)"
done

# ═════ A6: the off switches ══════════════════════════════════════════════════
for SW in enabled kill lane lock; do
  reset; seed 7 a6key0000001 archie 5; echo '{"pick":"hold","reason":"x"}' > "$FXT/answer.archie-card"
  case "$SW" in
    enabled) atick ARCHIE_CARDS_ENABLED=0; arc=$? ;;
    kill) touch "$H/flags/staff-kill-all"; atick; arc=$? ;;
    lane) touch "$FXT/lane-off"; atick; arc=$? ;;
    lock) mkdir -p "$H/locks"; exec 8>"$H/locks/archie-cards.lock"; flock -n 8; atick; arc=$?; exec 8>&- ;;
  esac
  eq "A6 $SW: rc 0" "$arc" 0
  eq "A6 $SW: 0 ledger requests, 0 calls" "$(cnt '^JOBS [A-Z]* /api/unblock' "$FXT/seq.log") $(cnt '^AGENTCALL' "$FXT/seq.log")" "0 0"
  [ "$SW" = enabled ] && eq "A6 enabled=0: 0 requests of any kind" "$(cnt '^JOBS ' "$FXT/seq.log")" 0
done

# ═════ A7: the per-tick cap; operator-routed and legacy rows are never claimed ══
reset; seed 7 a7key0000001 archie 5; seed 8 a7key0000002 archie 4; seed 9 a7key0000003 archie 3
echo '{"pick":"hold","reason":"x"}' > "$FXT/answer.archie-card"
atick ARCHIE_CARDS_MAX_PER_TICK=1
eq "A7 cap 1 with 3 rows: 1 claim, the oldest" "$(posts archie-claim) $(cnt '/7/archie-claim' "$FXT/seq.log")" "1 1"
has "A7 deferred=2" "$ALOG" "deferred=2"
reset; seed 7 a7key0000004 archie 5 '.routed_to = "operator"'; seed 8 a7key0000005 - 5
atick
eq "A7 operator-routed and legacy rows: 0 claims" "$(posts archie-claim) $(calls)" "0 0"

# ═════ U1-U5: bin/unblock-reply.sh archie ════════════════════════════════════
reset; seed 7 u1key0000001 archie 5; UC=$(fld 7 .card.id)
out=$(reply archie "$UC" hold "reason x"); rc=$?
eq "U1 hold: ARCHIE_ANSWERED, rc 0" "$out $rc" "ARCHIE_ANSWERED $UC hold 0"
eq "U1 GET then answer POST" "$(grep -oE '^JOBS (GET /api/unblock/decisions\?|POST /api/unblock/decisions/7/answer)' "$FXT/seq.log" | tr '\n' ';')" \
  "JOBS GET /api/unblock/decisions?;JOBS POST /api/unblock/decisions/7/answer;"
eq "U1 the body" "$(grep '/7/answer ' "$FXT/seq.log" | sed 's/^[^{]*//' | jq -c '{answer, answered_by, source, note}')" \
  '{"answer":"hold","answered_by":"archie","source":"archie","note":"reason x"}'
eq "U1 the row outcome answered" "$(fld 7 .outcome)" answered
reset; seed 7 u2key0000001 operator 5; UC=$(fld 7 .card.id)
out=$(reply archie "$UC" hold x); rc=$?
eq "U2 card route operator: refused rc 1, 0 POSTs" "${out%% *} $rc $(cnt '^JOBS POST' "$FXT/seq.log")" "ARCHIE_REFUSED 1 0"
reset; seed 7 u2key0000002 archie 5 '.routed_to = "operator"'; UC=$(fld 7 .card.id)
out=$(reply archie "$UC" hold x); eq "U2 routed_to set: refused, 0 POSTs" "${out%% *} $(cnt '^JOBS POST' "$FXT/seq.log")" "ARCHIE_REFUSED 0"
reset; seed 7 u2key0000003 archie 5; UC=$(fld 7 .card.id)
out=$(reply archie "$UC" 2 x); rc=$?
eq "U2 answer 2: refused, 0 requests" "${out%% *} $(cnt '^JOBS ' "$FXT/seq.log")" "ARCHIE_REFUSED 0"
[ "$rc" != 0 ] && ok || bad "U2 answer 2: rc != 0"
reset; seed 7 u3key0000001 archie 5; UC=$(fld 7 .card.id)
out=$(reply archie "$UC" needs-operator "client decision"); rc=$?
eq "U3 needs-operator: ARCHIE_ROUTED, rc 0" "$out $rc" "ARCHIE_ROUTED $UC 0"
eq "U3 the route body" "$(grep '/7/route ' "$FXT/seq.log" | sed 's/^[^{]*//' | jq -c '{to, by, reason}')" \
  '{"to":"operator","by":"archie","reason":"client decision"}'
reset; seed 7 u4key0000001 archie 5; UC=$(fld 7 .card.id); echo 422 > "$FXT/answer.code"
out=$(reply archie "$UC" hold x); rc=$?
eq "U4 answer 422: ARCHIE_REFUSED, rc 1" "${out%% *} $rc" "ARCHIE_REFUSED 1"
echo 409 > "$FXT/answer.code"
out=$(reply archie "$UC" hold x); rc=$?
eq "U4 answer 409 duplicate: ARCHIE_ANSWERED, rc 0" "${out%% *} $rc" "ARCHIE_ANSWERED 0"
reset
UNBLOCK_TRANSPORT=telegram UNBLOCK_FROM_USER=owner_a BOX_CHAT_OWNERS=telegram:owner_a=owner@example.com reply intercept "Tackler u-abcdef none" >/dev/null
eq "U5 intercept 'Tackler u-abcdef none': rc 1" "$?" 1

# ═════ M1: the daily cards line ══════════════════════════════════════════════
reset
jq -nc '{settings: [{key: "unblock.project.cromford.mode", value: "act"}]}' > "$FXT/settings.json"
cp "$REPO/tests/fixtures/unblock/bh-7728/metrics-week.json" "$FXT/metrics.json"
echo '{"received":4,"archie":2,"operator":1,"false":1}' > "$FXT/daily.json"
TUE=$(date -u -d 2026-10-20T00:17:00Z +%s)
env "${RUNENV[@]}" UNBLOCK_NOW=$TUE bash "$H/bin/unblock-metrics.sh" daily > "$T/m.out" 2>&1
has "M1 the cards line" "$H/logs/unblock-metrics.log" "tackler cromford 2026-10-19 cards: received 4, archie 2, operator 1, false 1"
has "M1 printed" "$T/m.out" "cards: received 4, archie 2, operator 1, false 1"
has "M1 the day of the metrics line" "$FXT/seq.log" "/api/unblock/cards/daily?project=cromford&day=2026-10-19"
reset
jq -nc '{settings: [{key: "unblock.project.cromford.mode", value: "act"}]}' > "$FXT/settings.json"
cp "$REPO/tests/fixtures/unblock/bh-7728/metrics-week.json" "$FXT/metrics.json"; echo 503 > "$FXT/daily.code"
env "${RUNENV[@]}" UNBLOCK_NOW=$TUE bash "$H/bin/unblock-metrics.sh" daily > "$T/m.out" 2>&1
has "M1 unreadable" "$H/logs/unblock-metrics.log" "tackler cromford: cards unreadable (http 503)"
has "M1 the metrics line is still written" "$H/logs/unblock-metrics.log" "tackler cromford 2026-10-19: decisions"

# ═════ P9: the record POST fails after ROUTED_ARCHIE: page the operator direct ══════
p9() { # the A1 box-hung stall, escalated by the shipped tick
  jq -nc '{kind: "box-hung", family: "infra", project: "cromford", subject: "box:orgo-9", stall_at_hour: "2026-10-30T11",
    orgo_hosted: true, orgo_state: "running", ssh_unreachable_min: 40, hung_min_threshold: 30, envbundle_fail_1h: 5,
    last_restart_min_ago: 10, build_claim_10m: false}' > "$FXT/lines.jsonl"
  printf 'ub_collect_fixture() { cat "$FXT/lines.jsonl"; }\n' > "$COL/fixture.sh"
}
reset; p9; echo 503 > "$FXT/record.code"; tick UNBLOCK_ACT=1
eq "P9 record 503: the row stays claimed with no card" "$(jq -r '.[0] | "\(.outcome) \(.card)"' "$FXT/rows.json")" "claimed null"
eq "P9 record 503: 1 page, critical, the card's alert id" "$(alerts) $(cnt "^ALERT --critical --id unblock-$(jq -r '.[0].decision_key' "$FXT/rows.json" | cut -c1-12 | xargs -I{} bash -c '. '"$REPO"'/bin/lib/unblock/card.sh; _unblock_card_hex {} | cut -c1-12') " "$FXT/seq.log")" "1 1"
has "P9 the page says why" "$FXT/seq.log" "NEEDS OPERATOR: the ledger record failed, so Archie cannot see this card"
has "P9 the tick log line" "$ULOG" "failed after ROUTED_ARCHIE; paged the operator direct"
case "$(grep ' tick cromford mode=act' "$ULOG" | tail -1)" in *" paged_direct=1"*) ok ;; *) bad "P9 tick line has paged_direct=1: $(tail -3 "$ULOG")" ;; esac
reset; p9; tick UNBLOCK_ACT=1
eq "P9 record 200: ROUTED_ARCHIE, 0 pages" "$(alerts) $(jq -r '.[0].outcome' "$FXT/rows.json")" "0 escalated"
reset; p9; echo 503 > "$FXT/record.code"; echo operator > "$FXT/settings/unblock.route_to"; tick UNBLOCK_ACT=1
eq "P9 route operator + record 503: the one direct DM of today, no second page" "$(alerts)" 1
hasnt "P9 route operator: no direct-page line" "$ULOG" "paged the operator direct"

# ═════ P10: /route 404 (the worker has no route yet): the sweep pages ════════
reset; seed 7 p10key000001 archie 61; echo 404 > "$FXT/route.code"; tick UNBLOCK_ACT=1
eq "P10 route 404: 1 route POST, 1 alert" "$(posts route) $(alerts)" "1 1"
has "P10 the log line" "$ULOG" "route 404 (the worker has no /route yet); paged with no route"
: > "$FXT/seq.log"; tick UNBLOCK_ACT=1
has "P10 the next sweep sends again with the same id" "$FXT/seq.log" "--id unblock-$(k12 p10key000001)"

# ═════ L1-L8: Archie's levers ════════════════════════════════════════════════
PRHEAD=4242f1c74242f1c74242f1c74242f1c74242f1c7
PRROW='.subject_kind = "pr" | .subject = "example-org/cromford#42" | .head = "'$PRHEAD'" | .stall_class = "pr-ejected" | .card.class = "queue-requeue"'
TKROW='.subject_kind = "build" | .subject = "ticket:cromford:BH-8798" | .head = null | .stall_class = "ticket-starved" | .card.class = "build-relaunch"'
ubrec() { grep '^UBACT ' "$FXT/seq.log" | tail -1 | sed -e 's/^UBACT //' -e 's/ UNBLOCK_ACT=.*$//'; }
lever() { # lever <id-key> <row filter> <answer json> [stub line] — one archie tick
  reset; seed 7 "$1" archie 5 "$2"; printf '%s\n' "$3" > "$FXT/answer.archie-card"
  printf '%s\n' "${4:-$(printf 'done\trequeued')}" > "$FXT/ubact.stub"
  atick "${@:5}"
}
lever l1key0000001 "$PRROW" '{"pick":"act","lever":"requeue","reason":"the batch failed on a flaky runner"}'
LC=$(fld 7 .card.id)
eq "L1 requeue: the record the writer gets" "$(ubrec | jq -c '{decision_key, project, repo, subject, pr, head, rule_id, class, action}')" \
  "{\"decision_key\":\"archie:$LC\",\"project\":\"cromford\",\"repo\":\"example-org/cromford\",\"subject\":\"example-org/cromford#42\",\"pr\":42,\"head\":\"$PRHEAD\",\"rule_id\":\"archie-card\",\"class\":\"queue-requeue\",\"action\":{\"name\":\"requeue\",\"args\":{}}}"
has "L1 UNBLOCK_ACT=1 (ARCHIE_CARDS_ACT default)" "$FXT/seq.log" " UNBLOCK_ACT=1"
eq "L1 the answer POST: acted, the lever, the writer's answer in the note" \
  "$(grep '/7/answer ' "$FXT/seq.log" | sed 's/^[^{]*//' | jq -c '{answer, lever, source, note}')" \
  '{"answer":"acted","lever":"requeue","source":"archie","note":"lever requeue done: requeued. the batch failed on a flaky runner"}'
eq "L1 the row: answered acted, 0 alerts, 0 routes" "$(fld 7 '"\(.outcome) \(.answer)"') $(alerts) $(posts route)" "answered acted 0 0"
has "L1 the lane log line" "$ALOG" "seen=1 claimed=1 calls=1 answered=0 routed=0 deferred=0 acted=1"
has "L1 the lever log line" "$ALOG" "$LC: lever requeue done requeued (ub_act rc 0)"
: > "$FXT/seq.log"; rm -f "$FXT/ubact.stub"; tick UNBLOCK_ACT=1
eq "L1 the next Tackler tick: 0 alerts" "$(alerts)" 0

# L2: every lever maps to its writer action, from the row.
lever l2key0000001 "$PRROW" '{"pick":"act","lever":"fix_round","reason":"r","brief":"fix the flaky wait in tests/x.sh"}'
eq "L2 fix_round" "$(ubrec | jq -c .action)" '{"name":"fix_round","args":{"brief":"fix the flaky wait in tests/x.sh"}}'
lever l2key0000002 "$PRROW" '{"pick":"act","lever":"fix_round","reason":"the reason is the brief"}'
eq "L2 fix_round with no brief takes the reason" "$(ubrec | jq -c .action.args)" '{"brief":"the reason is the brief"}'
lever l2key0000003 "$PRROW" '{"pick":"act","lever":"re_review","reason":"r","brief":"the old verdict was on an older head"}'
eq "L2 re_review" "$(ubrec | jq -c .action)" '{"name":"lead_rerequest","args":{"request_id":"none","priority":5,"notes":"the old verdict was on an older head"}}'
lever l2key0000004 "$PRROW" '{"pick":"act","lever":"re_review","reason":"r","brief":"'"$(printf 'n%.0s' $(seq 1 400))"'"}' "" ARCHIE_CARDS_REREVIEW_PRIORITY=3
eq "L2 re_review: the knob priority, notes cut to 300" "$(ubrec | jq -c '[.action.args.priority, (.action.args.notes | length)]')" '[3,300]'
lever l2key0000005 "$PRROW" '{"pick":"act","lever":"rebase","reason":"behind main"}'
eq "L2 rebase" "$(ubrec | jq -c .action)" '{"name":"update_branch","args":{}}'
lever l2key0000006 "$TKROW" '{"pick":"act","lever":"rebuild","reason":"the last build died on the pool"}'
eq "L2 rebuild: main's rebuild arm, the key from the subject" "$(ubrec | jq -c '[.action, .pr]')" '[{"name":"rebuild","args":{"key":"BH-8798"}},null]'
lever l2key0000007 "$TKROW" '{"pick":"act","lever":"re_offer","reason":"r"}'
eq "L2 re_offer" "$(ubrec | jq -c .action)" '{"name":"launch_fastpath","args":{"key":"BH-8798"}}'
lever l2key0000008 "$PRROW" '{"pick":"act","lever":"ticket_comment","reason":"the gate is red on main","brief":"see run 123"}'
eq "L2 ticket_comment on a PR: the PR thread" "$(ubrec | jq -c '[.action.name, .action.args.issue, .action.args.lines[0:2]]')" '["ticket_comment",42,["the gate is red on main","see run 123"]]'
lever l2key0000009 "$TKROW | .repo = \"example-org/cromford\"" '{"pick":"act","lever":"ticket_comment","reason":"r"}'
eq "L2 ticket_comment on a harness ticket: issue 8798" "$(ubrec | jq -c '[.action.args.issue, .repo]')" '[8798,"example-org/cromford"]'
lever l2key0000010 '.' '{"pick":"act","lever":"file_ticket","reason":"orgo-box hangs every hour","brief":"envbundle fails 5 times an hour"}'
eq "L2 file_ticket: the harness repo, the title from the row" "$(ubrec | jq -c '[.repo, .action.name, .action.args.title]')" \
  "[\"example-org/cromford\",\"file_ticket\",\"Archie: box-hung on $(fld 7 .subject)\"]"
has "L2 file_ticket: the lines carry the card id" "$FXT/seq.log" "Archie answered Tackler card $(fld 7 .card.id)"
lever l2key0000011 "$PRROW" '{"pick":"act","lever":"requeue","reason":"r","pr":99,"head":"ffffffffffffffffffffffffffffffffffffffff","repo":"evil/repo"}'
eq "L2 the model cannot name the PR, head or repo" "$(ubrec | jq -c '[.pr, .head, .repo]')" "[42,\"$PRHEAD\",\"example-org/cromford\"]"

# L3: a lever that does not fit the subject: no writer call, needs-operator, one page.
lever l3key0000001 '.' '{"pick":"act","lever":"requeue","reason":"x"}'
eq "L3 requeue on a box: 0 writer calls, 1 route by archie" "$(cnt '^UBACT' "$FXT/seq.log") $(posts route) $(posts answer)" "0 1 0"
has "L3 the route reason names the lever" "$FXT/seq.log" "Archie picked lever requeue, not pulled: lever requeue needs a PR subject. x"
tick UNBLOCK_ACT=1; eq "L3 the next Tackler tick pages once" "$(alerts)" 1
lever l3key0000002 '.subject = "ticket:cromford:BH-1" | .repo = "example-org/project-3"' '{"pick":"act","lever":"ticket_comment","reason":"x"}'
eq "L3 ticket_comment on another repo's ticket: not pulled" "$(cnt '^UBACT' "$FXT/seq.log") $(posts route)" "0 1"

# L4: the writer refuses, fails or answers rc 1: needs-operator with what Archie tried.
for S in "$(printf 'refused\tno-opt-in')" "$(printf 'failed\tfix-round-enqueue-failed')" "$(printf 'would\tWOULD_REQUEUE')" rc1; do
  lever l4key0000001 "$PRROW" '{"pick":"act","lever":"requeue","reason":"x"}' "$S"
  eq "L4 [$S]: 1 writer call, 0 answers, 1 route" "$(cnt '^UBACT' "$FXT/seq.log") $(posts answer) $(posts route)" "1 0 1"
  has "L4 [$S]: the reason carries the outcome" "$FXT/seq.log" "Archie pulled lever requeue: $( [ "$S" = rc1 ] && echo bad-input || printf '%s' "${S%%$'\t'*}")"
done

# L5: ARCHIE_CARDS_ACT=0 gives the writer UNBLOCK_ACT=0.
lever l5key0000001 "$PRROW" '{"pick":"act","lever":"requeue","reason":"x"}' "$(printf 'would\tWOULD_REQUEUE')" ARCHIE_CARDS_ACT=0
has "L5 ARCHIE_CARDS_ACT=0: UNBLOCK_ACT=0" "$FXT/seq.log" " UNBLOCK_ACT=0"

# L6: the REAL writer (no stub): a never-auto class is refused before any read.
reset; seed 7 l6key0000001 archie 5 "$PRROW | .card.class = \"merge\""
echo '{"pick":"act","lever":"requeue","reason":"x"}' > "$FXT/answer.archie-card"
atick
eq "L6 the real ub_act: never-auto merge, 1 warn alert, 1 route, 0 answers" \
  "$(cnt '^ALERT --severity warn --id unblock-never-' "$FXT/seq.log") $(posts route) $(posts answer)" "1 1 0"
has "L6 the route reason" "$FXT/seq.log" "Archie pulled lever requeue: refused never-auto:merge"

# L7: invalid lever answers are refused by the lane (billed, terminal).
for J in '{"pick":"act","lever":"merge","reason":"x"}' '{"pick":"act","lever":"requeue"}' '{"pick":"act","lever":"Requeue","reason":"x"}' \
         '{"pick":"hold","lever":"requeue","reason":"x"}' '{"pick":"none","lever":"requeue","reason":"x"}' '{"pick":"act","lever":["requeue"],"reason":"x"}'; do
  lever l7key0000001 "$PRROW" "$J"
  eq "L7 [$J]: 0 writer calls, 0 answers, 0 routes" "$(cnt '^UBACT' "$FXT/seq.log") $(posts answer) $(posts route)" "0 0 0"
  has "L7 [$J]: logged invalid" "$ALOG" "invalid answer (billed, terminal)"
done

# L8: the claim is still before the spend, and the lever after the call.
lever l8key0000001 "$PRROW" '{"pick":"act","lever":"requeue","reason":"x"}'
eq "L8 claim, call, writer, answer in that order" \
  "$(grep -oE '^(JOBS POST /api/unblock/decisions/7/(archie-claim|answer)|AGENTCALL archie-card|UBACT)' "$FXT/seq.log" | tr '\n' ';')" \
  "JOBS POST /api/unblock/decisions/7/archie-claim;AGENTCALL archie-card;UBACT;JOBS POST /api/unblock/decisions/7/answer;"

# ═════ L9: lever rebuild through main's REAL rebuild arm (BH-8736) ══════════
LCROW='.subject_kind = "build" | .subject = "cromford:BH-8817" | .head = null | .stall_class = "ticket-abandoned" | .card.class = "build-relaunch"'
l9() { # l9 <key> <lever> <lifecycle_transition rc> — the REAL ub_act, stubbed libs
  reset; seed 7 "$1" archie 5 "$LCROW"; echo "$3" > "$FXT/lt.rc"
  mkdir -p "$FXT/wsettings"; echo act > "$FXT/wsettings/unblock.project.cromford.mode"   # the writer's mode row
  printf '{"pick":"act","lever":"%s","reason":"the build died on the pool"}\n' "$2" > "$FXT/answer.archie-card"
  atick
}
l9 l9key0000001 rebuild 0
eq "L9 rebuild: the phase first, then the launch, in that order" \
  "$(grep -oE '^(LT [^ ]+ [^ ]+ [^ ]+ [^ ]+|FASTPATH .*$)' "$FXT/seq.log" | tr '\n' ';')" \
  "LT cromford BH-8817 planned lifecycle;FASTPATH cromford BH-8817;"
eq "L9 rebuild done: answered acted, lever rebuild, 0 routes" \
  "$(grep '/7/answer ' "$FXT/seq.log" | sed 's/^[^{]*//' | jq -c '[.answer, .lever]') $(posts route)" '["acted","rebuild"] 0'
l9 l9key0000002 rebuild 2
eq "L9 lifecycle rc 2: 0 launches, 0 answers, 1 route" "$(cnt '^FASTPATH' "$FXT/seq.log") $(posts answer) $(posts route)" "0 0 1"
has "L9 lifecycle rc 2: needs-operator names no-row" "$FXT/seq.log" "Archie pulled lever rebuild: refused no-row"
l9 l9key0000003 re_offer 0
eq "L9 re_offer: 0 transitions, 1 launch, acted" \
  "$(cnt '^LT ' "$FXT/seq.log") $(cnt '^FASTPATH cromford BH-8817$' "$FXT/seq.log") $(grep '/7/answer ' "$FXT/seq.log" | sed 's/^[^{]*//' | jq -r .lever)" "0 1 re_offer"

# ═════ L10: the ticket key, from both subject formats (Failure modes table) ══
l10() { # l10 <subject> <want key|-> — one re_offer lever through the stub writer
  lever "l10k$(printf '%s' "$1" | md5sum | cut -c1-8)" ".subject_kind = \"build\" | .subject = \"$1\" | .head = null" \
    '{"pick":"act","lever":"re_offer","reason":"x"}' "$(printf 'done\tlaunched')"
  if [ "$2" = - ]; then
    eq "L10 [$1]: no key, 0 writer calls, 1 route" "$(cnt '^UBACT' "$FXT/seq.log") $(posts route)" "0 1"
    has "L10 [$1]: needs a ticket subject" "$FXT/seq.log" "lever re_offer needs a ticket subject"
  else
    eq "L10 [$1]: the key" "$(ubrec | jq -c .action)" "{\"name\":\"launch_fastpath\",\"args\":{\"key\":\"$2\"}}"
  fi
}
l10 "ticket:cromford:BH-8817" BH-8817
l10 "cromford:BH-8817" BH-8817
l10 "cromford:BH-8817.2" BH-8817.2
for S in "cromford#8817" "project-1:BH-8817" "cromford:bh-8817" "ticket:cromford:" "cromford:BH-8817; rm" "lane:cromford:x"; do
  l10 "$S" -
done

# ═════ U6: the acted answer and its lever ════════════════════════════════════
reset; seed 7 u6key0000001 archie 5; UC=$(fld 7 .card.id)
out=$(reply archie "$UC" acted "lever requeue done: requeued" requeue); rc=$?
eq "U6 acted + lever: ARCHIE_ANSWERED, rc 0" "$out $rc" "ARCHIE_ANSWERED $UC acted 0"
eq "U6 the body carries the lever" "$(grep '/7/answer ' "$FXT/seq.log" | sed 's/^[^{]*//' | jq -c '{answer, lever}')" '{"answer":"acted","lever":"requeue"}'
for A in "acted x" "acted x merge" "hold x requeue" "acted '' requeue"; do
  reset; seed 7 u6key0000002 archie 5; UC=$(fld 7 .card.id)
  eval "out=\$(reply archie \"\$UC\" $A)"; rc=$?
  eq "U6 [$A]: refused rc 2, 0 requests" "${out%% *} $rc $(cnt '^JOBS ' "$FXT/seq.log")" "ARCHIE_REFUSED 2 0"
done

# ═════ M2: the cards line carries acted when the worker sends it ═════════════
reset
jq -nc '{settings: [{key: "unblock.project.cromford.mode", value: "act"}]}' > "$FXT/settings.json"
cp "$REPO/tests/fixtures/unblock/bh-7728/metrics-week.json" "$FXT/metrics.json"
echo '{"received":5,"archie":3,"operator":1,"false":1,"acted":1}' > "$FXT/daily.json"
env "${RUNENV[@]}" UNBLOCK_NOW=$TUE bash "$H/bin/unblock-metrics.sh" daily > "$T/m.out" 2>&1
has "M2 the cards line with acted" "$H/logs/unblock-metrics.log" "tackler cromford 2026-10-19 cards: received 5, archie 3, operator 1, false 1, acted 1"

# ═════ M3: the cards line carries the T11 operator count (W10's answer) ════════
reset
jq -nc '{settings: [{key: "unblock.project.cromford.mode", value: "act"}]}' > "$FXT/settings.json"
cp "$REPO/tests/fixtures/unblock/bh-7728/metrics-week.json" "$FXT/metrics.json"
echo '{"received":5,"archie":2,"operator":3,"false":1,"acted":0}' > "$FXT/daily.json"
env "${RUNENV[@]}" UNBLOCK_NOW=$TUE bash "$H/bin/unblock-metrics.sh" daily > "$T/m.out" 2>&1
has "M3 the cards line: direct cards count as operator, acted 0 printed" "$H/logs/unblock-metrics.log" "tackler cromford 2026-10-19 cards: received 5, archie 2, operator 3, false 1, acted 0"

# ═════ G1: uar_list, the miner's read of Archie's answers ════════════════════
reset
echo '[{"project":"cromford","stall_class":"pr-ejected","answer":"acted","lever":"requeue","n":4,"last_id":91},
       {"project":"cromford","stall_class":"box\thung","answer":"none","lever":"","n":3,"last_id":80}]' > "$FXT/repeats.json"
uar() { env "${RUNENV[@]}" bash -c '. "$1/bin/jobs-client.sh"; . "$2/bin/lib/unblock/archie-repeats.sh"; uar_list "$3" "$4" 50' _ "$H" "$REPO" "$@"; }
out=$(uar 2026-10-02T00:00:00Z 3); rc=$?
eq "G1 two groups, rc 0" "$rc $(grep -c . <<<"$out")" "0 2"
eq "G1 the first group" "$(head -1 <<<"$out")" "$(printf 'cromford\tpr-ejected\tacted\trequeue\t4\t91')"
eq "G1 a tab in a field is a space; no lever is -" "$(tail -1 <<<"$out")" "$(printf 'cromford\tbox hung\tnone\t-\t3\t80')"
has "G1 the request" "$FXT/seq.log" "JOBS GET /api/unblock/cards/repeats?since=2026-10-02T00:00:00Z&min=3&limit=50"
echo 503 > "$FXT/repeats.code"; uar 2026-10-02T00:00:00Z 3 >/dev/null; eq "G1 a 503 is rc 1" "$?" 1
uar 2026-10-02 3 >/dev/null; eq "G1 a bad since is rc 1" "$?" 1

# ═════ G2: the SHIPPED rule miner (dry run) bundles one incident per group ═══
RM="$T/rm"; mkdir -p "$RM/bin" "$RM/logs" "$RM/state/rule-mining" "$RM/locks" "$RM/env" "$RM/stub"
. "$REPO/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$RM" >/dev/null || exit 1
: > "$RM/fleet.conf"; : > "$RM/logs/findings.log"
# gh: the miner's sources (a)-(c) ask GitHub; this fake answers nothing and
# logs to its own file (0 network), so A8 still counts only real escapes.
printf '#!/bin/sh\nexit 0\n' > "$RM/stub/flock"; printf '#!/bin/sh\necho "gh $*" >> "%s/rm-gh.log"\nexit 1\n' "$T" > "$RM/stub/gh"; chmod +x "$RM/stub/"*
# The miner runs from the repo, so it sources the repo's archie-repeats.sh.
cat > "$RM/bin/jobs-client.sh" <<'SH'
_jobs_req() { printf 'MINER %s %s\n' "$1" "$2" >> "$FXT/seq.log"; [ "${2%%\?*}" = /api/unblock/cards/repeats ] || return 1
  jq -c '{repeats: .}' "$FXT/repeats.json"; }
SH
rm -f "$FXT/repeats.code"
echo '[{"project":"cromford","stall_class":"pr-ejected","answer":"acted","lever":"requeue","n":4,"last_id":91}]' > "$FXT/repeats.json"
miner() { env "$@" FXT="$FXT" HARNESS="$RM" HARNESS_TEST_SANDBOX=1 RULE_MINER_DRY=1 PATH="$RM/stub:$PATH" bash "$REPO/bin/rule-miner.sh" 2>/dev/null; }
out=$(miner HARNESS_SECRET=fixture); rc=$?
eq "G2 the dry run exits 0" "$rc" 0
grep -q 'archie-card:cromford:pr-ejected:acted:requeue' <<<"$out" && ok || bad "G2 the incident is in the inventory: $(head -c 600 <<<"$out")"
has "G2 the window and the threshold" "$FXT/seq.log" "MINER GET /api/unblock/cards/repeats?since="
has "G2 min=3 (RULE_MINER_ARCHIE_MIN default)" "$FXT/seq.log" "&min=3&limit=50"
# The week dir also holds digest.md, which carries the TYPE line but not the body:
# a sorted glob over the numbered bundles reads the file add_incident wrote.
B=$(grep -l 'TYPE: archie-card-repeat' "$RM"/state/rule-mining/*/[0-9][0-9]-archie-card-*.md 2>/dev/null | head -1)
[ -n "$B" ] && has "G2 the bundle names the lever and the rules dir" "$B" "catalog/unblock-rules.d" || bad "G2 no archie-card-repeat bundle"
: > "$FXT/seq.log"; out=$(miner -u HARNESS_SECRET)
eq "G2 no secret: 0 reads" "$(cnt '^MINER' "$FXT/seq.log")" 0
has "G2 no secret: the source-off log line" "$RM/logs/rule-miner.log" "source (g) off"
# G3: RULE_MINER_ARCHIE_LIMIT is the knob of the group cap (default 50, 1..200).
: > "$FXT/seq.log"; miner HARNESS_SECRET=fixture RULE_MINER_ARCHIE_LIMIT=7 >/dev/null
has "G3 the knob sets the limit" "$FXT/seq.log" "&min=3&limit=7"
: > "$FXT/seq.log"; miner HARNESS_SECRET=fixture RULE_MINER_ARCHIE_LIMIT=500 >/dev/null
has "G3 out of range is the default 50" "$FXT/seq.log" "&min=3&limit=50"
: > "$FXT/seq.log"; miner HARNESS_SECRET=fixture RULE_MINER_ARCHIE_LIMIT=0 >/dev/null
has "G3 zero is the default 50" "$FXT/seq.log" "&min=3&limit=50"
eq "G3 under the cap: no cap log line" "$(cnt 'RULE_MINER_ARCHIE_LIMIT=' "$RM/logs/rule-miner.log")" 0
miner HARNESS_SECRET=fixture RULE_MINER_ARCHIE_LIMIT=1 >/dev/null
has "G3 a run at the cap logs one line" "$RM/logs/rule-miner.log" "read the cap RULE_MINER_ARCHIE_LIMIT=1 groups"
K="$REPO/catalog/lanes.d/rule-miner.knobs.d/RULE_MINER_ARCHIE_LIMIT.json"
eq "G3 the knob file: default 50, range 1..200" "$(jq -r '"\(.default) \(.min) \(.max) \(.read_in)"' "$K" 2>/dev/null)" "50 1 200 bin/rule-miner.sh"

# ═════ A8: 0 vendor calls in the whole suite ═════════════════════════════════
eq "A8 0 curl (non-fixture) and gh calls ($(head -5 "$T/net.log" 2>/dev/null | tr '\n' '|'))" "$( [ -f "$T/net.log" ] && grep -c . "$T/net.log" || echo 0)" 0

echo "archie-cards.bh-8817: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
