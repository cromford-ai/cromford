#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie.sh — BH-4062 (BH-3966.1): the pure helpers behind Archie's
# initiative tracer. Sourced by bin/archie.sh (the tick lane and the Telegram
# intercept), by bin/orchestrate.sh and bin/daily-digest.sh (archie_sign),
# never run.
#
#   archie_parse_cmd <text>      -> rc 0 and one TAB line when <text> is an
#                                   Archie command, rc 1 when it is not:
#                                     track<TAB><rest>
#                                     reply<TAB><decision><TAB><id><TAB><note>
#                                     ask<TAB><question to send back>
#                                     delegate<TAB><class>   (BH-4067)
#                                     askfirst<TAB><class>   (BH-4067)
#   archie_parse_track <rest>    -> rc 0 and a JSON object {goal, metric_query,
#                                   cadence_hours, escalation_rule, links} when
#                                   every field is valid; rc 1 and the NAME of
#                                   the first bad field on stdout otherwise.
#                                   Defaults: metric none, every
#                                   ARCHIE_DEFAULT_CADENCE_H hours (24), escalate
#                                   always. Junk is refused, never clamped (D11).
#   archie_metric_csv <spec>     -> the number, rc 0; rc 1 = unreadable (absent
#                                   is not zero: a missing file, column or row,
#                                   a `-` or a blank cell all answer rc 1).
#   archie_escalates <rule> <value> <last_value> -> rc 0 escalate, 1 stay silent.
#   archie_compose <rec> <goal> <value> <rule> <links-json> <id> <max-chars>
#                                -> the beat body: the recommendation first,
#                                   then goal, metric, links, how to reply, and
#                                   the signature, never longer than
#                                   ARCHIE_BODY_MAX (links past it are counted).
#                                   An 8th arg auto:<class> makes it the
#                                   after-report of a delegated call (BH-4067):
#                                   `Handled under your standing OK for <class>: `
#                                   first, and an overrule line instead of the
#                                   approve line. Without it the body is unchanged.
#   archie_sign <text>           -> <text> with a final `Archie` line, once.
#   archie_fail_class <body>     -> BH-4609: the class of a model_failed slot from
#                                   its event body: `budget_stop<TAB><retry_after>`
#                                   for `budget_stop <ISO-Z> ...`, else `attempt`
#                                   (absent or junk is the smaller cap).
#   archie_budget_stop <envelope> -> BH-4609: rc 0 and the envelope's
#                                   total_cost_usd (or `?`) when agent-call's
#                                   $OUT.json says the call stopped on its dollar
#                                   cap (the test bin/agent-call.sh uses:
#                                   .terminal_reason // .subtype // .stop_reason
#                                   matches budget); rc 1 otherwise, a missing or
#                                   non-JSON file included.
#   archie_split_class <answer>  -> two parts, `<class>\n<rest>`: the slug of a
#                                   well-formed first line `CLASS: <slug>`
#                                   (lowercased) and the text after it; any
#                                   other answer is `unclassified` and the
#                                   whole answer (BH-4067).
#   archie_sensitive <class> <goal> <rec> -> rc 0 when any of the three touches
#                                   clients, money, production, merges or
#                                   deploys (ARCHIE_SENSITIVE_RE). Such an
#                                   escalation is never auto-handled and never
#                                   counts toward a streak (BH-4067).
#   archie_no_action <sentence>  -> rc 0 when the sentence only says nothing is
#                                   needed from the operator: it matches
#                                   ARCHIE_NO_ACTION_RE, NOT ARCHIE_ASK_RE and
#                                   NOT ARCHIE_NEWS_RE (news: something went red,
#                                   tripped, was paused, reverted or blocked; a
#                                   sentence carrying news is sent even when it
#                                   ends "nothing for you to do"). All three are
#                                   case-insensitive EREs, settable knobs on the
#                                   archie lane. A blank sentence is rc 1 (the
#                                   caller's own blank check owns it), and so is
#                                   a malformed ARCHIE_ASK_RE or ARCHIE_NEWS_RE:
#                                   the message is sent, never silenced.
#                                   BH-4779: such an answer sends nothing.
#
# Root: ${HARNESS:-${H:-}} only (D43). An empty root makes archie_metric_csv
# answer unreadable; it never builds a path from nothing.

ARCHIE_METRIC_RE='^csv:logs/[A-Za-z0-9._/-]+\.csv#[A-Za-z0-9_]+(@[A-Za-z0-9_]+=[A-Za-z0-9._-]+)?$'
ARCHIE_RULE_RE='^(always|change|(>=|<=|>|<) -?[0-9]+(\.[0-9]+)?)$'
# The worker's cap on a check event's body (initiatives.js: optText(b.body, 4000)).
ARCHIE_BODY_MAX=4000
# BH-4067: the protected-topic floor. A code constant on purpose, never a
# settings row: the ticket makes these classes never delegable, and a row would
# let a settings write widen Archie's authority without the operator.
ARCHIE_SENSITIVE_RE='client|customer|money|spend|cost|budget|billing|invoice|pric|\$[0-9]|usd|prod\b|production|merge|land(ing)? (the )?(train|#|pr)|deploy|release|ship(ping)? (it|to)|roll ?back|migration|secret|key rotation|rotate .*key|vercel|wrangler'
# BH-4588: the hard limits, the only scan a lever-* class gets. A code
# constant for the same reason as ARCHIE_SENSITIVE_RE: a settings write must
# not widen Archie's authority. A direct merge (a squash or land into main
# too), a push to main (a `HEAD:main` refspec too), a production DB write, a
# deploy (outside the deploy lanes Archie does not run one), a release or a
# rollback, money, cost or a spend-cap raise (`usd` with no word boundary, so
# `..._max_usd` is caught), a client-visible write, and the topics the full
# scan protects that no lever needs: secrets, key rotation and migrations.
# "merge queue", "push with lease", "rebase onto main" and "merge-conductor"
# are not hard limits; a lever names them. A write to a board other than the
# harness board is checked in archie_sensitive (archie_client_board).
ARCHIE_HARD_LIMIT_RE='gh (pr )?merge|pulls/[0-9]+/merge|\<merge[[:space:]]+(#?[0-9]+|pr|it|this|that|them|now|the (pr|branch|change))\>|\<(squash|direct(ly)?|admin)[- ]merge|merge[[:space:]]+(--admin|directly)|push(es|ed|ing)?[^.]{0,40}\<(to|onto|into) (origin/)?(main|master)\>|force[- ]?push(es|ed|ing)? (origin/)?(main|master)\>|\<push(es|ed|ing)? (origin )?(main|master)\>|prod(uction)?[- ]?(db|database|d1|postgres|sql)\>|(db|database) (in|on) prod|prisma db push|:(refs/heads/)?(main|master)\>|\<(squash|merge|land|cherry-?pick)(s|es|ed|ing)?\>[^.]{0,40}\<(to|onto|into) (origin/)?(main|master)\>|\<land(s|ed|ing)? (the )?(train|#|pr)|\<deploy(s|ed|ing|ment)?\>|wrangler|vercel|flyctl|\<releas(e|es|ed|ing)\>|roll(s|ed|ing)? ?back|spend|budget|cost|dollar|\$[0-9]|usd|money|billing|invoice|\<pric(e|es|ing)\>|secret|credential|key rotation|rotat(e|es|ed|ing)[^.]{0,40}\<(key|token|password)s?\>|migration|client[- ]?(board|ticket|comment|facing|visible|email|message|channel)|customer|(post|comment|reply|write|message|email|tell)[^.]{0,40}\<clients?\>'
ARCHIE_CLASS_RE='^[a-z][a-z0-9-]{1,40}$'
# BH-4779: "nothing for you to do" is not a message. Defaults equal the registry
# defaults in catalog/lanes.d/archie.json (lane_env_apply archie exports a row).
ARCHIE_NO_ACTION_RE_DEFAULT='nothing (here )?for you|nothing (you need |that needs you )?to (do|decide|approve|act on)|nothing (is )?(needed|required) (from|of) you|no action (is )?(needed|required)|(don.{0,3}t|do not) need to do anything|no need for you to'
ARCHIE_ASK_RE_DEFAULT='\?|\b(can|could|would|will) you\b|\bplease\b|\bshould (i|we)\b|\bwant me to\b|\byour call\b|\bup to you\b|\blet me know\b|\b(approve|drop|change) i[0-9]+|\bneeds? your (ok|okay|approval|decision|call|input|eyes)\b|\bdecide (whether|if|which|between|on)\b'
ARCHIE_NEWS_RE_DEFAULT='\b(red|fail(s|ed|ing|ure|ures)?|broke|broken|down|outage|tripped|paused|stopped|halted|reverted|rolled back|re-?queued|block(s|ed|ing)?|stuck|overdue|over (budget|the cap)|lost|errors?|regress(ed|ion)?)\b'
ARCHIE_NO_ACTION_RE="${ARCHIE_NO_ACTION_RE:-$ARCHIE_NO_ACTION_RE_DEFAULT}"
ARCHIE_ASK_RE="${ARCHIE_ASK_RE:-$ARCHIE_ASK_RE_DEFAULT}"
ARCHIE_NEWS_RE="${ARCHIE_NEWS_RE:-$ARCHIE_NEWS_RE_DEFAULT}"

archie_no_action() {
  local s="${1:-}"
  [ -n "${s//[[:space:]]/}" ] || return 1
  grep -Eiq -- "$ARCHIE_NO_ACTION_RE" <<<"$s" || return 1
  # Only a clean "no match" (rc 1) is no ask and no news: a malformed
  # ARCHIE_ASK_RE or ARCHIE_NEWS_RE (rc 2) fails toward sending, never silence.
  grep -Eiq -- "$ARCHIE_ASK_RE" <<<"$s"
  [ "$?" = 1 ] || return 1
  grep -Eiq -- "$ARCHIE_NEWS_RE" <<<"$s"
  [ "$?" = 1 ]
}

archie_parse_cmd() {
  local t="${1:-}" lc
  # Trim, then match case-insensitively but keep the original text for notes.
  t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
  lc=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
  local pre='^archie[,:]?[[:space:]]+'
  if [[ $lc =~ ${pre}track[[:space:]]+(.+)$ ]]; then
    # The rest, from the original text (same length prefix).
    local rest="${t:$(( ${#t} - ${#BASH_REMATCH[1]} ))}"
    printf 'track\t%s\n' "$rest"; return 0
  fi
  local dec="" id="" note=""
  if [[ $lc =~ ${pre}(approve|change|drop)[[:space:]]+#?i?([0-9]+)([[:space:]].*)?$ ]] \
    || [[ $lc =~ ^(approve|change|drop)[[:space:]]+i([0-9]+)([[:space:]].*)?$ ]]; then
    dec="${BASH_REMATCH[1]}"; id="${BASH_REMATCH[2]}"
    note="${BASH_REMATCH[3]:+${t:$(( ${#t} - ${#BASH_REMATCH[3]} ))}}"
    note="${note#"${note%%[![:space:]]*}"}"
    id=$((10#$id))
    if [ "$id" -lt 1 ]; then return 1; fi
    if [ "$dec" = change ] && [ -z "$note" ]; then
      printf 'ask\tWhat should change on I%s? Say it as: Archie change I%s <what>\n' "$id" "$id"; return 0
    fi
    printf 'reply\t%s\t%s\t%s\n' "$dec" "$id" "$(printf '%s' "$note" | tr '\t\n' '  ')"; return 0
  fi
  # A bare `Archie drop` names no initiative: ask, never guess one.
  if [[ $lc =~ ${pre}(approve|change|drop)$ ]]; then
    printf 'ask\tWhich initiative? Say it as: Archie %s I<number>\n' "${BASH_REMATCH[1]}"; return 0
  fi
  # BH-4067: the operator moves a class of call into Archie's authority, or back. The
  # class is lowercased here, once ($lc), and must be a whole slug.
  if [[ $lc =~ ${pre}(delegate|ask[[:space:]]+first)[[:space:]]+([^[:space:]]+)$ ]] \
    && [[ ${BASH_REMATCH[2]} =~ $ARCHIE_CLASS_RE ]]; then
    local cls="${BASH_REMATCH[0]}" verb=delegate
    [[ $lc =~ ${pre}delegate[[:space:]] ]] || verb=askfirst
    printf '%s\t%s\n' "$verb" "$cls"; return 0
  fi
  if [[ $lc =~ ${pre}(delegate|ask[[:space:]]+first)$ ]]; then
    printf 'ask\tWhich kind of call? Say it as: Archie delegate <class> or Archie ask first <class>, for example Archie delegate watch-cadence\n'; return 0
  fi
  return 1
}

archie_parse_track() {
  local rest="${1:-}" goal metric=none every="" rule=always links_raw="" seg key val
  local cad="${ARCHIE_DEFAULT_CADENCE_H:-24}"
  local -a segs
  IFS='|' read -r -a segs <<<"$rest"
  goal="${segs[0]:-}"
  goal="${goal#"${goal%%[![:space:]]*}"}"; goal="${goal%"${goal##*[![:space:]]}"}"
  # A goal with no letter or digit slugs to nothing on the worker.
  [[ $goal =~ [A-Za-z0-9] ]] && [ "${#goal}" -le 300 ] || { echo goal; return 1; }
  for seg in "${segs[@]:1}"; do
    [[ $seg =~ ^[[:space:]]*([A-Za-z]+)[[:space:]]*:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || { echo field; return 1; }
    key=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'); val="${BASH_REMATCH[2]}"
    case "$key" in
      metric) metric="$val" ;;
      every) every="$val" ;;
      escalate) rule="$val" ;;
      links) links_raw="$val" ;;
      *) echo "$key"; return 1 ;;
    esac
  done
  if [ -n "$every" ]; then
    [[ $every =~ ^([0-9]{1,5})[[:space:]]*([hd])$ ]] || { echo every; return 1; }
    cad=$((10#${BASH_REMATCH[1]}))
    [ "${BASH_REMATCH[2]}" = d ] && cad=$((cad * 24))
  fi
  [[ $cad =~ ^[0-9]+$ ]] && [ "$cad" -ge 1 ] && [ "$cad" -le 2160 ] || { echo every; return 1; }
  if [ "$metric" != none ]; then
    [[ $metric =~ $ARCHIE_METRIC_RE ]] && [[ $metric != *..* ]] || { echo metric; return 1; }
  fi
  [[ $rule =~ $ARCHIE_RULE_RE ]] || { echo escalate; return 1; }
  # A rule that compares a value needs a metric that produces one.
  [ "$rule" = always ] || [ "$metric" != none ] || { echo escalate; return 1; }
  local -a links=()
  if [ -n "$links_raw" ]; then
    read -r -a links <<<"$links_raw"
    [ "${#links[@]}" -le 10 ] || { echo links; return 1; }
    local l
    for l in "${links[@]}"; do
      [[ $l =~ ^https?://[^[:space:]]{1,300}$ ]] || { echo links; return 1; }
    done
  fi
  jq -nc --arg g "$goal" --arg m "$metric" --argjson c "$cad" --arg r "$rule" \
    '{goal: $g, metric_query: $m, cadence_hours: $c, escalation_rule: $r, links: $ARGS.positional}' \
    --args "${links[@]}"
}

archie_metric_csv() {
  local spec="${1:-}" root="${HARNESS:-${H:-}}" path col fcol="" fval=""
  [ -n "$root" ] || return 1
  [[ $spec =~ $ARCHIE_METRIC_RE ]] && [[ $spec != *..* ]] || return 1
  spec="${spec#csv:}"
  path="${spec%%#*}"; col="${spec#*#}"
  if [[ $col == *@* ]]; then fval="${col#*@}"; col="${col%%@*}"; fcol="${fval%%=*}"; fval="${fval#*=}"; fi
  [ -r "$root/$path" ] || return 1
  local v
  v=$(python3 - "$root/$path" "$col" "$fcol" "$fval" <<'PY' 2>/dev/null
import csv, sys
path, col, fcol, fval = sys.argv[1:5]
with open(path, newline="") as fh:
    rows = list(csv.reader(fh))
if not rows or col not in rows[0] or (fcol and fcol not in rows[0]):
    sys.exit(1)
h = rows[0]
ci = h.index(col)
fi = h.index(fcol) if fcol else None
val = None
for r in rows[1:]:
    if len(r) != len(h):
        continue
    if fi is not None and r[fi] != fval:
        continue
    val = r[ci]
if val is None:
    sys.exit(1)
print(val.strip())
PY
  ) || return 1
  v="${v%\%}"
  [[ $v =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || return 1
  printf '%s\n' "$v"
}

archie_escalates() {
  local rule="${1:-}" v="${2:-}" last="${3:-}" op n
  case "$rule" in
    always) return 0 ;;
    change)
      [ -n "$v" ] || return 1
      [ -n "$last" ] || return 0   # the first reading counts as a change
      awk -v a="$v" -v b="$last" 'BEGIN { exit !(a + 0 != b + 0) }' ;;
    *)
      [[ $rule =~ $ARCHIE_RULE_RE ]] && [ -n "$v" ] || return 1
      op="${rule%% *}"; n="${rule#* }"
      awk -v a="$v" -v op="$op" -v b="$n" 'BEGIN {
        a += 0; b += 0
        if (op == ">")  exit !(a >  b)
        if (op == ">=") exit !(a >= b)
        if (op == "<")  exit !(a <  b)
        if (op == "<=") exit !(a <= b)
        exit 1 }' ;;
  esac
}

archie_compose() {
  local rec="${1:-}" goal="${2:-}" v="${3:-}" rule="${4:-}" links="${5:-[]}" id="${6:-}" max="${7:-600}" body
  local auto="${8:-}" lead="" reply
  # One line, no em or en dashes (De-AI voice, the dd_summary fold), capped.
  rec=$(jq -Rsr --argjson m "$max" 'gsub("\\s*[—–]\\s*"; ", ") | gsub("\\s+"; " ") | sub("^[, ]+"; "") | sub("[, ]+$"; "") | .[0:$m]' <<<"$rec")
  [ -n "$rec" ] || return 1
  reply="Reply: Archie approve I$id / Archie change I$id <what> / Archie drop I$id"
  if [[ $auto == auto:* ]]; then
    # BH-4067: already acted on under a standing OK, so this reports and
    # offers the overrule; it does not ask.
    lead="Handled under your standing OK for ${auto#auto:}: "
    reply="Overrule: Archie change I$id <what> / Archie drop I$id"
  fi
  # The signed body always fits ARCHIE_BODY_MAX, measured the way the worker
  # measures it (JS length: UTF-16 units). Links that do not fit are counted
  # in one line instead; a recommendation too long even without links is cut.
  # A body the worker would refuse could never be recorded `composed`, and an
  # unrecorded answer is one the tick would pay for again.
  body=$(jq -nr --arg r "$rec" --arg g "$goal" --arg v "${v:-not measured}" --arg rule "$rule" \
    --arg L "$links" --arg id "$id" --argjson cap "$ARCHIE_BODY_MAX" --arg lead "$lead" --arg reply "$reply" '
    def u16: [explode[] | if . > 65535 then 2 else 1 end] | add // 0;
    def build($r; $ls; $more):
      $lead + $r + "\n\nGoal: " + $g + "\nMetric: " + $v + " (" + $rule + ")"
      + ($ls | map("\n" + .) | join(""))
      + (if $more > 0 then "\n\($more) more link\(if $more == 1 then "" else "s" end) on I\($id), not shown here" else "" end)
      + "\n\n" + $reply;
    ($cap - 8) as $room   # archie_sign adds "\n\nArchie"
    | ($L | try fromjson catch [] | if type == "array" then [.[] | strings] else [] end) as $all
    | ($all | length) as $n
    | (first(range($n; -1; -1) as $k | build($r; $all[0:$k]; $n - $k) | select(u16 <= $room)) // null) as $fit
    | if $fit != null then $fit
      else {r: $r} | until((build(.r; []; $n) | u16) <= $room or .r == ""; .r |= .[0:(length - 1)])
           | build(.r; []; $n) end') || return 1
  archie_sign "$body"
}

archie_sign() {
  local t="${1:-}" last
  last=$(printf '%s\n' "$t" | awk 'NF { l = $0 } END { print l }')
  last="${last#"${last%%[![:space:]]*}"}"; last="${last%"${last##*[![:space:]]}"}"
  if [ "$last" = Archie ]; then printf '%s\n' "$t"; return 0; fi
  printf '%s\n\nArchie\n' "$t"
}

archie_fail_class() {
  local b="${1:-}"
  if [[ $b =~ ^budget_stop\ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)(\ |$) ]]; then
    printf 'budget_stop\t%s\n' "${BASH_REMATCH[1]}"
  else
    printf 'attempt\n'
  fi
}

archie_budget_stop() {
  local f="${1:-}" why cost
  [ -n "$f" ] && [ -r "$f" ] || return 1
  why=$(jq -r '.terminal_reason // .subtype // .stop_reason // empty' "$f" 2>/dev/null) || return 1
  case "$why" in *[Bb][Uu][Dd][Gg][Ee][Tt]*) ;; *) return 1 ;; esac
  cost=$(jq -r '.total_cost_usd // empty' "$f" 2>/dev/null)
  [[ $cost =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] || cost='?'
  printf '%s\n' "$cost"
}

archie_split_class() {
  local t="${1:-}" first rest lc
  first="${t%%$'\n'*}"
  if [ "$first" = "$t" ]; then rest=""; else rest="${t#*$'\n'}"; fi
  lc=$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')
  if [[ $lc =~ ^[[:space:]]*class:[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]] \
    && [[ ${BASH_REMATCH[1]} =~ $ARCHIE_CLASS_RE ]]; then
    printf '%s\n%s\n' "${BASH_REMATCH[0]}" "$rest"; return 0
  fi
  printf 'unclassified\n%s\n' "$t"
}

# archie_sensitive <class> <goal> <recommendation> -> rc 0 when the decision
#   touches a protected topic. A lever-* class (BH-4588: Archie's own factory
#   levers, delegated by default) is scanned for the hard limits only; every
#   other class gets the full ARCHIE_SENSITIVE_RE scan.
archie_sensitive() {
  local re="$ARCHIE_SENSITIVE_RE"
  case "${1:-}" in lever-*) re="$ARCHIE_HARD_LIMIT_RE" ;; esac
  grep -Eiq -- "$re" < <(printf '%s\n' "${1:-}" "${2:-}" "${3:-}") && return 0
  case "${1:-}" in lever-*) archie_client_board "${2:-}" "${3:-}" ;; *) return 1 ;; esac
}

# archie_client_board <text>... -> rc 0 when a write names any board other
#   than the harness board ("the project-1 board ticket", "the board"). A client
#   board is client-visible, so a lever never writes one under its standing OK.
#   Only "harness board", "BH board", "cromford board" and "ai-build
#   board" are Archie's own; anything else fails toward asking.
archie_client_board() {
  local s w
  s=$(printf '%s\n' "$@")
  grep -Eiq -- '\<(comment|post|reply|write|tell|message|email|file|update|close|label)(s|ed|ing)?\>' <<<"$s" || return 1
  while IFS= read -r w; do
    case "$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')" in
      harness|bh|cromford|ai-build) ;;
      *) return 0 ;;
    esac
  done < <(grep -Eio -- '[a-z0-9_-]+ board\>' <<<"$s" | awk '{print $1}')
  return 1
}
