#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/override.sh — BH-7728 (UNB-6): find a person's reversal of a
# Tackler act inside the override window, demote the rule's staff class to
# ask_first, then stamp override_* on the ledger row. Sourced by
# bin/unblock-metrics.sh (`overrides`) and, for uo_class_of only, by
# bin/staff/tackler-report.sh. Never run.
#
# WHY. The spec's Ledger rule "Override": one reversal by a person demotes the
# class (agent-core). Without it a wrong class keeps its delegation, and the
# weekly precision has no numerator.
#
# WHAT uo_scan does, once per call:
#   1. GET /api/unblock/overrides/candidates?since=<now - 2 x window>: the done
#      acts with no override (an act is created before it is acted; the window
#      runs from acted_at). A 503 "unblock_decisions schema not applied" is one
#      `ledger not live` line; any other failure is one `candidates
#      unreadable` line. Both stamp nothing and return 0.
#   2. Per row (at most UNBLOCK_OVERRIDE_MAX_ROWS, until UO_DEADLINE), by the
#      row's action, one signal. A signal answers rc 0 override (UO_WHO,
#      UO_AT, UO_EVID set), rc 1 none, rc 2 unknown (unreadable or a cut page:
#      never an override, counted `unknown`, retried next run):
#        post_block, post_verdict  a source=human verdict row, reviewer not
#                     tackler:*, on the row's head, of the opposite class
#                     (BLOCK vs MERGE|MERGE-WITH-NOTES) to action_args.verdict
#                     (post_block with none: BLOCK)
#        requeue, queue  an issue event `unlabeled $MC_MERGIFY_LABEL` or a
#                     `@mergifyio dequeue` comment by an actor of type User
#                     whose login does not end in [bot]. A full page of 100
#                     with no match is unknown.
#        setting_set  a config_changes row (kind setting, name action_args.key)
#                     by an actor that is not tackler*, registry-seed, seed or
#                     *[bot], whose value differs from action_args.value
#      Every signal counts only inside (acted_at, acted_at + window]. Another
#      action has no signal: skipped, one log line per action name per run.
#   3. On an override: the class is `.class` of the rule file in
#      catalog/unblock-rules.d whose `.id` is the row's rule_id. A class: POST
#      /api/staff/classes/delegation ask_first (actor unblock-override). 200
#      changed/existing, 404 not-found and 409 never-delegable go on to the
#      stamp; a transport failure or any other answer stops this row with no
#      stamp (the next run retries; the demote is idempotent). No class (no
#      file, no field): no demote, `no-class` in the detail.
#   4. POST /api/unblock/overrides {id, override_by, override_at,
#      override_detail "<signal>: <evidence>; demote: <word>"}.
#   5. One line: `overrides: candidates=N checked=N overrides=N demoted=N
#      unknown=N`. demoted counts only a 200 that carried a change_id.
#
# FAILURE. Nothing here exits. An unset root, a missing _jobs_req or a missing
# gh_rest is rc 1 from uo_scan with one line on stderr. The caller sets UO_NOW
# (epoch seconds); unset is the clock.
#
# Knobs (catalog/lanes.d/unblock-metrics.json): UNBLOCK_OVERRIDE_WINDOW_H
# (24), UNBLOCK_OVERRIDE_MAX_ROWS (200). Out of range is one warn line and the
# default, never a clamp.
# gh-rest: no-graphql

_uo_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_uo_now() { if [[ ${UO_NOW:-} =~ ^[0-9]+$ ]]; then printf '%s' "$UO_NOW"; else date -u +%s; fi; }
_uo_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
_uo_log() {
  local root; root=$(_uo_root); [ -n "$root" ] || return 0
  mkdir -p "$root/logs" 2>/dev/null
  printf '%s %s\n' "$(_uo_iso "$(_uo_now)")" "$*" >> "$root/logs/unblock-metrics.log" 2>/dev/null
}
_uo_int() { # _uo_int <name> <value> <default> <min> <max>
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    _uo_log "warn: $1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}
# _uo_plus <iso> <seconds>: the ISO time that many seconds later.
_uo_plus() { local e; [ -n "${1:-}" ] || return 1; e=$(date -u -d "$1" +%s 2>/dev/null) || return 1; _uo_iso "$((e + $2))"; }

# uo_class_of <rule_id>: prints the class of the ONE rule file whose .id is
# <rule_id>; rc 1 when no file or more than one file carries it (fail closed).
# By id, not by file stem (BH-8418): U8-box-restart.json carries id U8. Each
# file is read on its own, so a file that is not JSON hides no other rule.
uo_class_of() {
  local id="${1:-}" root f c
  root=$(_uo_root); [ -n "$root" ] || return 1
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || return 1
  c=$(for f in "$root"/catalog/unblock-rules.d/[!_]*.json; do jq -c . "$f" 2>/dev/null || true; done \
    | jq -rs --arg id "$id" '[.[] | select(type == "object" and .id == $id)]
        | if length == 1 then .[0].class // empty | strings else empty end' 2>/dev/null) || return 1
  [[ $c =~ ^[a-z][a-z0-9-]{1,40}$ ]] || return 1
  printf '%s' "$c"
}

# The verdict's class: block, merge, or empty.
_uo_vclass() { case "$1" in BLOCK) echo block ;; MERGE|MERGE-WITH-NOTES) echo merge ;; *) echo "" ;; esac; }

# uo_signal_verdict <row-json> <window-s>
uo_signal_verdict() {
  local row=$1 win=$2 repo pr head acted end mine want resp hit
  repo=$(jq -r '.repo // ""' <<<"$row"); head=$(jq -r '.head // ""' <<<"$row")
  pr=$(jq -r '.subject // "" | capture("#(?<n>[0-9]+)$").n // ""' <<<"$row" 2>/dev/null)
  acted=$(jq -r '.acted_at // ""' <<<"$row")
  mine=$(jq -r '(.action_args // "{}" | try fromjson catch {}) .verdict // (if .action == "post_block" then "BLOCK" else "" end)' <<<"$row" 2>/dev/null)
  mine=$(_uo_vclass "$mine")
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ $pr =~ ^[0-9]+$ ]] && [[ $head =~ ^[0-9a-f]{40}$ ]] \
    && [ -n "$acted" ] && [ -n "$mine" ] || return 2
  [ "$mine" = block ] && want=merge || want=block
  end=$(_uo_plus "$acted" "$win") || return 2
  resp=$(_jobs_req GET "/api/verdicts?repo=$repo&pr=$pr") || return 2
  hit=$(jq -c --arg h "$head" --arg a "$acted" --arg e "$end" --arg w "$want" '
    [(.rows // [])[] | select(.source == "human" and ((.reviewer // "") | test("^tackler:") | not)
      and .head_sha == $h and (.created_at // "") > $a and (.created_at // "") <= $e
      and ((.verdict == "BLOCK" and $w == "block") or ((.verdict == "MERGE" or .verdict == "MERGE-WITH-NOTES") and $w == "merge")))]
    | sort_by(.created_at) | first // empty' <<<"$resp" 2>/dev/null) || return 2
  if [ -z "$hit" ]; then
    jq -e '.truncated == true' <<<"$resp" >/dev/null 2>&1 && return 2
    return 1
  fi
  UO_WHO=$(jq -r '.reviewer // "human"' <<<"$hit"); UO_AT=$(jq -r .created_at <<<"$hit")
  UO_EVID="verdict: #$(jq -r .id <<<"$hit") $(jq -r .verdict <<<"$hit") by $UO_WHO on ${head:0:12}"
  return 0
}

# uo_signal_dequeue <row-json> <window-s>
uo_signal_dequeue() {
  local row=$1 win=$2 repo pr acted end lbl tmp hit n
  repo=$(jq -r '.repo // ""' <<<"$row"); acted=$(jq -r '.acted_at // ""' <<<"$row")
  pr=$(jq -r '.subject // "" | capture("#(?<n>[0-9]+)$").n // ""' <<<"$row" 2>/dev/null)
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ $pr =~ ^[0-9]+$ ]] && [ -n "$acted" ] || return 2
  end=$(_uo_plus "$acted" "$win") || return 2
  lbl="${MC_MERGIFY_LABEL:-merge-queue}"
  tmp=$(mktemp "${TMPDIR:-/tmp}/uo-gh.XXXXXX") || return 2
  gh_rest GET "repos/$repo/issues/$pr/events?per_page=100" > "$tmp" || { rm -f "$tmp"; return 2; }
  hit=$(jq -c --arg l "$lbl" --arg a "$acted" --arg e "$end" '
    [.[]? | select(.event == "unlabeled" and (.label.name // "") == $l and (.actor.type // "") == "User"
      and ((.actor.login // "") | endswith("[bot]") | not) and (.created_at // "") > $a and (.created_at // "") <= $e)]
    | first // empty | {who: .actor.login, at: .created_at, what: ("unlabeled " + $l + " by " + .actor.login)}' "$tmp" 2>/dev/null) \
    || { rm -f "$tmp"; return 2; }
  if [ -z "$hit" ]; then
    n=$(jq 'length' "$tmp" 2>/dev/null || echo 100)
    [ "$n" -ge 100 ] && { rm -f "$tmp"; return 2; }
    gh_rest GET "repos/$repo/issues/$pr/comments?since=$acted&per_page=100" > "$tmp" || { rm -f "$tmp"; return 2; }
    hit=$(jq -c --arg a "$acted" --arg e "$end" '
      [.[]? | select(((.body // "") | test("@mergifyio\\s+dequeue"; "i")) and (.user.type // "") == "User"
        and ((.user.login // "") | endswith("[bot]") | not) and (.created_at // "") > $a and (.created_at // "") <= $e)]
      | first // empty | {who: .user.login, at: .created_at, what: ("@mergifyio dequeue by " + .user.login)}' "$tmp" 2>/dev/null) \
      || { rm -f "$tmp"; return 2; }
    if [ -z "$hit" ]; then
      n=$(jq 'length' "$tmp" 2>/dev/null || echo 100); rm -f "$tmp"
      [ "$n" -ge 100 ] && return 2
      return 1
    fi
  fi
  rm -f "$tmp"
  UO_WHO=$(jq -r .who <<<"$hit"); UO_AT=$(jq -r .at <<<"$hit")
  UO_EVID="dequeue: $(jq -r .what <<<"$hit") on $repo#$pr"
  return 0
}

# uo_signal_setting <row-json> <window-s>
uo_signal_setting() {
  local row=$1 win=$2 key val acted end resp hit q
  acted=$(jq -r '.acted_at // ""' <<<"$row")
  key=$(jq -r '.action_args // "{}" | try fromjson catch {} | .key // "" | strings' <<<"$row" 2>/dev/null)
  val=$(jq -r '.action_args // "{}" | try fromjson catch {} | .value // "" | tostring' <<<"$row" 2>/dev/null)
  [[ $key =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$ ]] && [ -n "$acted" ] || return 2
  end=$(_uo_plus "$acted" "$win") || return 2
  q=$(jq -nr --arg k "$key" '$k | @uri')
  resp=$(_jobs_req GET "/api/config-changes?kind=setting&name=$q&limit=20") || return 2
  hit=$(jq -c --arg k "$key" --arg v "$val" --arg a "$acted" --arg e "$end" '
    [(.changes // [])[] | select(.kind == "setting" and .name == $k and (.at // "") > $a and (.at // "") <= $e)
      | (.actor // "") as $who
      | select(($who | test("^tackler") | not) and $who != "registry-seed" and $who != "seed" and ($who | endswith("[bot]") | not))
      | . + {v: ((.after_json // "{}") | try fromjson catch {} | .value // null | tostring)}
      | select(.v != $v)]
    | sort_by(.at) | first // empty' <<<"$resp" 2>/dev/null) || return 2
  if [ -z "$hit" ]; then
    jq -e '.truncated == true' <<<"$resp" >/dev/null 2>&1 && return 2
    return 1
  fi
  UO_WHO=$(jq -r .actor <<<"$hit"); UO_AT=$(jq -r .at <<<"$hit")
  UO_EVID="setting: config_changes #$(jq -r .id <<<"$hit") $key=$(jq -r .v <<<"$hit") by $UO_WHO"
  return 0
}

# uo_demote <class> <decision-id> <who>: prints the demote word; rc 1 = stop
# this row (no stamp). `changed` only for a 200 that carried a change_id.
uo_demote() {
  local cls=$1 id=$2 who=$3 body resp rc
  body=$(jq -nc --arg c "$cls" --arg r "override of decision #$id by $who" \
    '{agent: "tackler", class: $c, decision: "ask_first", actor: "unblock-override", reason: $r[0:500]}') || return 1
  resp=$(_jobs_req POST /api/staff/classes/delegation "$body"); rc=$?
  case "$rc" in
    0) if jq -e '.change_id | numbers' <<<"$resp" >/dev/null 2>&1; then echo changed; else echo existing; fi; return 0 ;;
    2) echo not-found; return 0 ;;
    9) if jq -e '.error == "never_delegable"' <<<"$resp" >/dev/null 2>&1; then echo never-delegable; return 0; fi
       _uo_log "overrides: decision #$id demote of $cls refused: $(head -c 120 <<<"$resp"); not stamped"; return 1 ;;
  esac
  _uo_log "overrides: decision #$id demote of $cls failed (http ${JOBS_HTTP:-none}); not stamped, the next run retries"
  return 1
}

uo_scan() {
  local root win max now since resp rc tmp row id action sig cls word detail body n=0 checked=0 ovr=0 dem=0 unk=0 skipped=" "
  root=$(_uo_root)
  [ -n "$root" ] && command -v _jobs_req >/dev/null 2>&1 && command -v gh_rest >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
    || { echo "override.sh: no root, _jobs_req, gh_rest or jq" >&2; return 1; }
  win=$(( $(_uo_int UNBLOCK_OVERRIDE_WINDOW_H "${UNBLOCK_OVERRIDE_WINDOW_H:-24}" 24 1 168) * 3600 ))
  max=$(_uo_int UNBLOCK_OVERRIDE_MAX_ROWS "${UNBLOCK_OVERRIDE_MAX_ROWS:-200}" 200 10 1000)
  now=$(_uo_now); since=$(_uo_iso "$((now - 2 * win))")
  tmp=$(mktemp "${TMPDIR:-/tmp}/uo-cand.XXXXXX") || return 0
  _jobs_req GET "/api/unblock/overrides/candidates?since=$since" > "$tmp"; rc=$?
  if [ "$rc" != 0 ]; then
    if [ "${JOBS_HTTP:-}" = 503 ] && grep -q 'unblock_decisions schema not applied' <<<"${JOBS_BODY:-}"; then
      _uo_log "overrides: ledger not live (unblock_decisions schema not applied); nothing checked"
    else
      _uo_log "overrides: candidates unreadable (rc $rc, http ${JOBS_HTTP:-none}); nothing checked"
    fi
    rm -f "$tmp"; return 0
  fi
  jq -c '.candidates[]?' "$tmp" > "$tmp.rows" 2>/dev/null || { _uo_log "overrides: candidates unparsable; nothing checked"; rm -f "$tmp" "$tmp.rows"; return 0; }
  jq -e '.truncated == true' "$tmp" >/dev/null 2>&1 && _uo_log "overrides: candidates truncated at the route cap; the rest next run"
  while IFS= read -r row; do
    n=$((n + 1))
    [ "$checked" -ge "$max" ] && continue
    if [[ ${UO_DEADLINE:-} =~ ^[0-9]+$ ]] && [ "$(date -u +%s)" -ge "$UO_DEADLINE" ]; then
      _uo_log "overrides: deadline reached after $checked row(s); the rest next run"; break
    fi
    id=$(jq -r '.id // ""' <<<"$row"); action=$(jq -r '.action // ""' <<<"$row")
    [[ $id =~ ^[0-9]+$ ]] || continue
    UO_WHO=""; UO_AT=""; UO_EVID=""
    case "$action" in
      post_block|post_verdict) checked=$((checked + 1)); uo_signal_verdict "$row" "$win"; sig=$? ;;
      requeue|queue) checked=$((checked + 1)); uo_signal_dequeue "$row" "$win"; sig=$? ;;
      setting_set) checked=$((checked + 1)); uo_signal_setting "$row" "$win"; sig=$? ;;
      *) case "$skipped" in *" $action "*) ;; *) skipped="$skipped$action "; _uo_log "overrides: action '${action:-none}' has no override signal; skipped" ;; esac
         continue ;;
    esac
    case "$sig" in
      0) ;;
      1) continue ;;
      *) unk=$((unk + 1)); continue ;;
    esac
    ovr=$((ovr + 1))
    if cls=$(uo_class_of "$(jq -r '.rule_id // ""' <<<"$row")"); then
      word=$(uo_demote "$cls" "$id" "$UO_WHO") || continue
      [ "$word" = changed ] && dem=$((dem + 1))
    else
      word=no-class
    fi
    detail="$UO_EVID; demote: $word"
    body=$(jq -nc --argjson id "$id" --arg b "$UO_WHO" --arg a "$UO_AT" --arg d "$detail" \
      '{id: $id, override_by: $b[0:80], override_at: $a, override_detail: $d[0:500]}') || continue
    _jobs_req POST /api/unblock/overrides "$body" >/dev/null \
      || _uo_log "overrides: decision #$id stamp failed (http ${JOBS_HTTP:-none}); the next run re-detects it"
  done < "$tmp.rows"
  rm -f "$tmp" "$tmp.rows"
  _uo_log "overrides: candidates=$n checked=$checked overrides=$ovr demoted=$dem unknown=$unk"
  return 0
}

# uo_active_projects: the projects whose settings row unblock.project.<p>.mode
# is shadow or act (a missing row is off, spec "Mode per project"), one per
# line, sorted. rc 1 when the settings cannot be read.
uo_active_projects() {
  local resp
  resp=$(_jobs_req GET /api/settings) || return 1
  jq -r '[(.settings // [])[] | select((.key // "") | test("^unblock\\.project\\.[a-z0-9][a-z0-9._-]{0,63}\\.mode$"))
    | select(.value == "shadow" or .value == "act") | .key | sub("^unblock\\.project\\."; "") | sub("\\.mode$"; "")]
    | unique[]' <<<"$resp" 2>/dev/null
}
