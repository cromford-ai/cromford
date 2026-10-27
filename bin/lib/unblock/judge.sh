#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/judge.sh — the PR unblock agent's judge (UNB-2): ONE bounded
# model question with a closed answer set. Sourced, never run; nothing runs on
# source.
#
#   unblock_judge <question> <input-file> <key>
#     question  test-weakening (LEGIT | WEAKENED | UNSURE)
#               cap-only       (CAP_ONLY | UNSURE)
#     key       the decision key (repo#pr@head:rule); it is part of the fp.
#     stdout    one JSON object {question, answer, outcome, model_calls, cost_usd, fp}
#     rc 0      answered (UNSURE included); rc 1 bad args or no root.
#
#   ubt_stage_judge <decision-json> <model>   the UNB-0 tick seam (see below)
#
#   unblock_judge_spec <question>
#     stdout    {input, proceed_on, block_on, block_cites} for the question:
#               test-weakening  .diff, LEGIT proceeds, WEAKENED blocks (G16)
#               cap-only        .cap_line, CAP_ONLY proceeds
#               another word    {} (rc 1)
#     The rule schema (UNB-0/UNB-8 _schema.json) gives .judge only prompt,
#     question and when, so the routing lives here, next to the answer sets.
#     A .judge that sets one of these keys overrides the table (direct callers).
#
#   unblock_judge_route <rule-file> <answer>
#     proceed   the answer is in proceed_on (the question's table, then judge.proceed_on)
#     block     the answer is in block_on; line 2 is block_cites, space separated
#     escalate  anything else, UNSURE included
#
# DEDUP BEFORE SPEND, in this order:
#   1. the input is refused over its cap (test-weakening UNBLOCK_JUDGE_DIFF_MAX_LINES,
#      default 400; cap-only UNBLOCK_JUDGE_CAP_MAX_LINES, default 60):
#      outcome over-cap, no call. An unreadable SOP file: outcome no-prompt, no call.
#   2. model = model route role unblock.judge (lane_role_model). No route:
#      outcome no-route, no call. No model literal lives here.
#   3. fp = sha256(question, model, key, sha256(input)). The ledger
#      state/unblock-judge/<fp>.json {outcome, attempts, answer, cost_usd, ts}
#      is read under flock -n on locks/unblock-judge-<fp12>.lock (held: outcome
#      busy, no call). `ok` and `empty` are terminal: outcome cached, no call.
#      `failed` at UNBLOCK_JUDGE_MAX_ATTEMPTS (default 2): outcome failed, no call.
#   4. the attempt is written (failed, attempts+1) BEFORE the call; a failed
#      write is no call.
#   5. ONE agent-call (timeout UNBLOCK_JUDGE_TIMEOUT_S, default 120), no tools,
#      stage unblock-judge, lane unblock, capped by
#      AGENT_CALL_BUDGET_USD_UNBLOCK_JUDGE=UNBLOCK_LLM_MAX_USD (default 0.6).
#      rc 74-79 billed nothing: the attempt is handed back (outcome refused).
#      Another rc stays counted (outcome failed). A blank reply is `empty`
#      (billed, terminal). Otherwise the first line, trimmed of blanks, must be
#      exactly one word of the question's set, in upper case; anything else is
#      stored as `ok` with the answer UNSURE (billed, terminal, never asked again).
#
# RETENTION: each call deletes ledger files older than UNBLOCK_JUDGE_LEDGER_DAYS
# (default 30) and logs the count; UNBLOCK_JUDGE_PRUNE_DRY=1 only logs it. The
# ledger only answers "did we already pay for this question"; the decision
# record is UNB-0's table and the cost is in cost_rows.
#
# Test seam: with HARNESS_TEST_SANDBOX=1, UNBLOCK_FIXTURE names a file that is
# sourced before the route is read (a suite defines lane_role_model there).
#
# NO ROOT DEFAULT (D43): the root is $HARNESS, then $H; with neither it is rc 1.

_UJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_uj_log() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s judge: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$h/logs/unblock.log" 2>/dev/null || true
}

# _uj_out <question> <answer> <outcome> <model_calls> <cost_usd|null> <fp>
_uj_out() {
  jq -nc --arg q "$1" --arg a "$2" --arg o "$3" --argjson n "$4" --argjson c "$5" --arg fp "$6" \
    '{question: $q, answer: $a, outcome: $o, model_calls: $n, cost_usd: $c, fp: $fp}'
}

# _uj_knob <env> <fallback> <min> <max>: the env value when it is an integer in
# [min, max], else the fallback (and one warn line when it was set). The rows
# are catalog/lanes.d/unblock.knobs.d/<env>.json; lane_env_apply unblock fills them.
_uj_knob() {
  local v="${!1:-}"
  if [ -z "$v" ]; then echo "$2"; return 0; fi
  if [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; then echo "$v"; return 0; fi
  _uj_log "warn: $1='$v' is not an integer in [$3, $4], using $2"
  echo "$2"
}

_uj_prune() {
  local dir="$1" days="${UNBLOCK_JUDGE_LEDGER_DAYS:-30}" n
  [[ $days =~ ^[1-9][0-9]*$ ]] || days=30
  [ -d "$dir" ] || return 0
  n=$(find "$dir" -maxdepth 1 -type f -name '*.json' -mtime +"$days" 2>/dev/null | grep -c .)
  if [ "${UNBLOCK_JUDGE_PRUNE_DRY:-0}" = 1 ]; then
    _uj_log "prune: dry run, $n ledger file(s) older than $days days"
  else
    find "$dir" -maxdepth 1 -type f -name '*.json' -mtime +"$days" -delete 2>/dev/null
    _uj_log "prune: deleted $n ledger file(s) older than $days days"
  fi
}

unblock_judge() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || { echo "unblock_judge: no root (\$HARNESS or \$H)" >&2; return 1; }
  [ "$#" -eq 3 ] || { echo "usage: unblock_judge <question> <input-file> <key>" >&2; return 1; }
  local q="$1" in="$2" key="$3" set cap model isha fp dir led lockf
  case "$q" in
    test-weakening) set="LEGIT WEAKENED UNSURE"; cap=$(_uj_knob UNBLOCK_JUDGE_DIFF_MAX_LINES 400 1 5000) ;;
    cap-only) set="CAP_ONLY UNSURE"; cap=$(_uj_knob UNBLOCK_JUDGE_CAP_MAX_LINES 60 1 2000) ;;
    *) echo "unblock_judge: unknown question '$q'" >&2; return 1 ;;
  esac
  [ -r "$in" ] || { echo "unblock_judge: input $in unreadable" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "unblock_judge: jq is required" >&2; return 1; }

  if [ "$(wc -l < "$in")" -gt "$cap" ]; then
    _uj_log "$q $key: input over the $cap-line cap, no call"
    _uj_out "$q" UNSURE over-cap 0 0 ""; return 0
  fi

  declare -F lane_role_model >/dev/null || . "$_UJ_DIR/../lane-model.sh" 2>/dev/null
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${UNBLOCK_FIXTURE:-}" ]; then
    # shellcheck disable=SC1090
    . "$UNBLOCK_FIXTURE"
  fi
  # The tick (ubt_stage_judge) already read the route with the project scope
  # and hands its model in _UJ_MODEL; a direct caller reads the route here.
  model="${_UJ_MODEL:-}"
  if [ -z "$model" ] && { ! declare -F lane_role_model >/dev/null || ! model=$(lane_role_model unblock.judge) || [ -z "$model" ]; }; then
    _uj_log "$q $key: no model route for unblock.judge, no call"
    _uj_out "$q" UNSURE no-route 0 0 ""; return 0
  fi

  if [ ! -r "$h/catalog/prompts/unblock-judge.md" ]; then
    _uj_log "$q $key: prompt catalog/prompts/unblock-judge.md unreadable, no call"
    _uj_out "$q" UNSURE no-prompt 0 0 ""; return 0
  fi

  isha=$(sha256sum < "$in" | cut -c1-64)
  fp=$(printf '%s\n%s\n%s\n%s\n' "$q" "$model" "$key" "$isha" | sha256sum | cut -c1-64)
  dir="$h/state/unblock-judge"; led="$dir/$fp.json"; lockf="$h/locks/unblock-judge-${fp:0:12}.lock"
  mkdir -p "$dir" "$h/locks" 2>/dev/null || { _uj_out "$q" UNSURE failed 0 0 "$fp"; return 0; }
  _uj_prune "$dir"

  (
    exec 9>"$lockf" || { _uj_out "$q" UNSURE busy 0 0 "$fp"; exit 0; }
    flock -n 9 || { _uj_log "$q $key: fp ${fp:0:12} is being asked by another run, no call"; _uj_out "$q" UNSURE busy 0 0 "$fp"; exit 0; }
    local outcome="" att=0 ans maxa usd raw pf rc text cost tmo
    tmo=$(_uj_knob UNBLOCK_JUDGE_TIMEOUT_S 120 10 900)
    maxa="${UNBLOCK_JUDGE_MAX_ATTEMPTS:-2}"; [[ $maxa =~ ^[1-9][0-9]*$ ]] || maxa=2
    usd="${UNBLOCK_LLM_MAX_USD:-0.6}"; [[ $usd =~ ^[0-9]+(\.[0-9]+)?$ ]] || usd=0.6
    if [ -f "$led" ]; then
      outcome=$(jq -r '.outcome // ""' "$led" 2>/dev/null)
      att=$(jq -r '.attempts // 0' "$led" 2>/dev/null); [[ $att =~ ^[0-9]+$ ]] || att=0
      case "$outcome" in
        ok)    ans=$(jq -r '.answer // "UNSURE"' "$led"); _uj_out "$q" "$ans" cached 0 0 "$fp"; exit 0 ;;
        empty) _uj_out "$q" UNSURE cached 0 0 "$fp"; exit 0 ;;
        failed) if [ "$att" -ge "$maxa" ]; then
                  _uj_log "$q $key: fp ${fp:0:12} failed $att times, no call"; _uj_out "$q" UNSURE failed 0 0 "$fp"; exit 0
                fi ;;
      esac
    fi
    # write_led <outcome> <attempts> [answer] [cost]: temp + mv.
    write_led() {
      jq -n --arg o "$1" --argjson a "$2" --arg r "${3:-}" --argjson c "${4:-null}" --arg t "$(date -u +%FT%TZ)" \
        '{outcome: $o, attempts: $a, answer: (if $r == "" then null else $r end), cost_usd: $c, ts: $t}' > "$led.tmp" 2>/dev/null \
        && mv -f "$led.tmp" "$led"
    }
    att=$((att + 1))
    write_led failed "$att" || { _uj_log "$q $key: the attempt could not be recorded, no call"; _uj_out "$q" UNSURE failed 0 0 "$fp"; exit 0; }
    raw=$(mktemp "${TMPDIR:-/tmp}/unblock-judge.XXXXXX") && pf=$(mktemp "${TMPDIR:-/tmp}/unblock-judge-p.XXXXXX") \
      || { write_led failed "$((att - 1))"; _uj_out "$q" UNSURE failed 0 0 "$fp"; exit 0; }
    { cat "$h/catalog/prompts/unblock-judge.md"
      printf '\n## Question\n%s\n\nAnswer with exactly one word from: %s\n\n' "$q" "$set"
      printf '=== UNTRUSTED INPUT unblock-judge ===\n'
      cat "$in"
      printf '\n=== END UNTRUSTED INPUT unblock-judge ===\n'
    } > "$pf"
    env -u AGENT_CALL_TICKET -u AGENT_CALL_PR -u AGENT_CALL_GUARD_FORCE \
      AGENT_CALL_NO_TOOLS=1 AGENT_CALL_LANE=unblock AGENT_CALL_FP="unblock-judge:$fp" AGENT_CALL_GUARD_STAGE=unblock-judge \
      AGENT_CALL_BUDGET_USD_UNBLOCK_JUDGE="$usd" "$h/bin/agent-call.sh" unblock-judge fleet "$model" "$tmo" "$raw" "@$pf" >/dev/null 2>&1
    rc=$?
    text=$(cat "$raw" 2>/dev/null)
    cost=$(jq -c '.total_cost_usd // null | if type == "number" then . else null end' "$raw.json" 2>/dev/null); [ -n "$cost" ] || cost=null
    rm -f "$raw" "$raw.json" "$raw.err" "$pf"
    if [ "$rc" != 0 ]; then
      if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then
        write_led failed "$((att - 1))" || true
        _uj_log "$q $key: agent-call refused (rc=$rc, nothing billed), fp ${fp:0:12}"
        _uj_out "$q" UNSURE refused 0 0 "$fp"; exit 0
      fi
      _uj_log "$q $key: agent-call failed (rc=$rc), fp ${fp:0:12}, attempt $att of $maxa"
      _uj_out "$q" UNSURE failed 1 "$cost" "$fp"; exit 0
    fi
    if [ -z "${text//[[:space:]]/}" ]; then
      write_led empty "$att" "" "$cost" || _uj_log "warn: the empty answer for fp ${fp:0:12} was paid for and not recorded"
      _uj_log "$q $key: empty answer (billed, terminal), fp ${fp:0:12}"
      _uj_out "$q" UNSURE empty 1 "$cost" "$fp"; exit 0
    fi
    ans=$(head -1 <<<"$text" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [[ $ans =~ ^[A-Z_]+$ ]] && [[ " $set " == *" $ans "* ]] || ans=UNSURE
    write_led ok "$att" "$ans" "$cost" || _uj_log "warn: the answer for fp ${fp:0:12} was paid for and not recorded"
    _uj_log "$q $key: answered $ans, fp ${fp:0:12}, cost ${cost}"
    _uj_out "$q" "$ans" ok 1 "$cost" "$fp"; exit 0
  )
  return 0
}

unblock_judge_spec() {
  case "${1:-}" in
    test-weakening) jq -nc '{input: ".diff", proceed_on: ["LEGIT"], block_on: ["WEAKENED"], block_cites: ["G16"]}' ;;
    cap-only) jq -nc '{input: ".cap_line", proceed_on: ["CAP_ONLY"], block_on: [], block_cites: []}' ;;
    *) echo '{}'; return 1 ;;
  esac
}

# _uj_judge_eff <judge-json>: the question's table with the .judge keys over it.
_uj_judge_eff() {
  local j="${1:-}" q spec
  q=$(jq -r '.question // ""' <<<"$j" 2>/dev/null)
  spec=$(unblock_judge_spec "$q")
  jq -c --argjson s "$spec" '$s + (if type == "object" then . else {} end)' <<<"$j" 2>/dev/null || echo "$spec"
}

unblock_judge_route() {
  local rule="${1:-}" ans="${2:-}" j
  [ -r "$rule" ] || { echo escalate; return 0; }
  j=$(_uj_judge_eff "$(jq -c '.judge // {}' "$rule" 2>/dev/null)")
  if [ -n "$ans" ] && jq -e --arg a "$ans" '(.proceed_on // []) | index($a) != null' >/dev/null 2>&1 <<<"$j"; then
    echo proceed
  elif [ -n "$ans" ] && jq -e --arg a "$ans" '(.block_on // []) | index($a) != null' >/dev/null 2>&1 <<<"$j"; then
    echo block
    jq -r '(.block_cites // []) | join(" ")' <<<"$j"
  else
    echo escalate
  fi
  return 0
}

# ubt_stage_judge <decision-json> <model> — the UNB-0 judge seam that
# bin/unblock.sh calls for every decision with `.judge != null`, after the
# claim and the route read (lead BLOCK #4214: no file defined it, so every
# judge decision was `deferred ... (seam not loaded)`). It is the adapter over
# unblock_judge and unblock_judge_route:
#   question  .judge.question (test-weakening | cap-only); another word is
#             outcome failed, 0 calls.
#   input     the question's input path (unblock_judge_spec; .judge.input
#             overrides), a jq path such as `.cap_line`, read over
#             .evidence (the stall record). Only a plain path is accepted
#             (`.a.b`); another expression, or an input that reads empty, is
#             outcome escalated, 0 calls (nothing to ask).
#   key       .decision_key (part of the judge fp).
#   route     unblock_judge_spec, then .judge.proceed_on / block_on / block_cites.
# stdout: one object {outcome, detail, model_calls, cost_usd, judge:{...}}:
#   judge outcome failed or busy        -> failed
#   judge outcome refused (nothing billed) -> refused
#   route proceed                       -> would (the rule's action may run;
#                                          UNB-4 acts on it, shadow records it)
#   route block                         -> refused, the detail names the cites
#   route escalate (UNSURE, over-cap, empty, no-prompt, no-route) -> escalated
# model_calls and cost_usd come from unblock_judge (cost null is 0).
ubt_stage_judge() {
  local d="${1:-}" model="${2:-}" q expr key tmp out ans jo n c rf r cites act outc detail
  _ujs_out() {
    jq -nc --arg o "$1" --arg d "$2" --arg n "$3" --arg c "$4" --argjson j "${5:-null}" \
      '{outcome: $o, detail: $d, model_calls: ($n | tonumber? // 0), cost_usd: ($c | tonumber? // 0)}
       + (if $j == null then {} else {judge: $j} end)'
  }
  jq -e 'type == "object" and (.judge | type) == "object"' >/dev/null 2>&1 <<<"$d" \
    || { _ujs_out failed "ubt_stage_judge: no judge object" 0 0; return 0; }
  q=$(jq -r '.judge.question // ""' <<<"$d")
  expr=$(jq -r '.input // ""' <<<"$(_uj_judge_eff "$(jq -c .judge <<<"$d")")")
  key=$(jq -r '.decision_key // ""' <<<"$d")
  act=$(jq -r '.action.name // "none"' <<<"$d")
  case "$q" in test-weakening|cap-only) ;; *) _ujs_out failed "judge: unknown question '$q'" 0 0; return 0 ;; esac
  [[ $expr =~ ^(\.[A-Za-z_][A-Za-z0-9_]*)+$ ]] \
    || { _ujs_out escalated "judge $q: input '$expr' is not a plain path; nothing asked" 0 0; return 0; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/unblock-judge-seam.XXXXXX") || { _ujs_out failed "judge $q: no temp dir" 0 0; return 0; }
  jq -r ".evidence | $expr // empty | if type == \"array\" then .[] | tostring elif type == \"string\" then . else tojson end" \
    <<<"$d" > "$tmp/input" 2>/dev/null || : > "$tmp/input"
  if ! grep -q '[^[:space:]]' "$tmp/input" 2>/dev/null; then
    rm -rf "$tmp"; _ujs_out escalated "judge $q: input $expr is empty; nothing asked" 0 0; return 0
  fi
  out=$(_UJ_MODEL="$model" unblock_judge "$q" "$tmp/input" "$key" 2>/dev/null)
  if ! jq -e 'type == "object" and has("outcome")' >/dev/null 2>&1 <<<"$out"; then
    rm -rf "$tmp"; _ujs_out failed "judge $q: unblock_judge answered no object" 0 0; return 0
  fi
  ans=$(jq -r '.answer // "UNSURE"' <<<"$out"); jo=$(jq -r .outcome <<<"$out")
  n=$(jq -r '.model_calls // 0' <<<"$out"); c=$(jq -r '.cost_usd // 0' <<<"$out")
  rf="$tmp/rule.json"
  jq -c '{judge: .judge}' <<<"$d" > "$rf"
  r=$(unblock_judge_route "$rf" "$ans"); rm -rf "$tmp"
  cites=$(sed -n 2p <<<"$r"); r=$(head -1 <<<"$r")
  case "$jo" in
    failed|busy) outc=failed detail="judge $q $jo (answer $ans)" ;;
    refused) outc=refused detail="judge $q refused by agent-call, nothing billed" ;;
    *) case "$r" in
         proceed) outc=would detail="judge $q=$ans ($jo): proceed $act" ;;
         block) outc=refused detail="judge $q=$ans ($jo): block${cites:+ cites $cites}" ;;
         *) outc=escalated detail="judge $q=$ans ($jo): escalate" ;;
       esac ;;
  esac
  _ujs_out "$outc" "$detail" "$n" "$c" "$(jq -c '{question, answer, outcome, fp}' <<<"$out")"
  return 0
}
