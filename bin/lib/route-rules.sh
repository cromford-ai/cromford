#!/bin/bash
# bin/lib/route-rules.sh — P4: plan-driven model routing, SHADOW MODE.
#
# WHAT IT ANSWERS. Given a build dir whose PLAN stage has finished, which
# execute model, review tier and test scope WOULD this build get if the plan's
# own structure picked them? Today every stage runs on the build.* model_routes
# rows (Opus 5.5) whatever the plan says the work is; P4 measures what a
# plan-driven router would do, so the decision to turn one on is made on
# evidence rather than a pricing page (docs/ROUTE-RULES.md).
#
# LOG ONLY. The answer is written to $BUILD/route-shadow.json, one
# `ROUTE_SHADOW (log only)` line in $BUILD/pipeline.log, and one
# POST /api/route-shadow row. Nothing in bin/run-build.sh reads any of them.
# The hook there runs this file as its OWN process, with argv only, output
# discarded, every inherited fd above 2 closed and a 30 s ceiling, so it cannot
# change a variable, hold a build lock or change an exit code of the build
# (tests/route-rules.p4-test.sh section D proves the runner argv
# byte-identical with and without it). It does ADD wall time: up to 30 s.
#
# DETERMINISTIC. The features come from artifacts the pipeline already wrote:
#   plan.md            the Acceptance tests / System invariants sections, a
#                      colon-anchored CONTRACT: line, the KIND line (fallback)
#   kind.txt           KIND / KIND_REPRO          (bin/kind-gate.sh)
#   size-gate.txt      SIZE_DECLARED lines=/files= (bin/size-gate.sh)
#   plan-gate.txt      PLAN_TRACE                 (bin/plan-gate.sh)
#   planned-files.txt  -> bin/lib/review-tier.sh review_tier_files, the SAME
#                      classifier the review stage runs on the real diff
#   ticket-meta.json   the title (a split's unit 0 is `<KEY>.0: ...`)
# and the rules are route_rules rows (GET /api/route-rules, cached on this box
# for an outage). Same artifacts + same rules = byte-identical answer; no model
# call, no clock in the decision.
#
# NO MODEL ID LIVES HERE. A rule names a model_routes ROLE; the would-be model
# is that role's rung 0 through bin/lib/model-route.sh, like every live lane.
# The review model is always build.review's: no rule can move the reviewer to
# a cheaper model, and a rule can only RAISE the review tier above what the
# classifier gives the planned files.
#
# FAILS TOWARD THE FRONTIER. A missing plan, an empty planned-files list or an
# unreadable artifact is not "small and safe": the classifier answers T2 for an
# empty list, T2 is risk surface, and risk surface is the live execute role.
#
#   . bin/lib/route-rules.sh
#     route_features <build>                  -> the features, one JSON object
#     route_rules_decide <features> <rules>   -> the decision, one JSON object
#                                                (both args JSON text; pure)
#   bin/lib/route-rules.sh resolve <build> [project]      decision as k=v lines
#   bin/lib/route-rules.sh shadow <project> <key> <build> <actual-exec-model>
#                                 <actual-review-model> [job-id]
#                                              record it (always rc 0)
#
# Knobs (catalog/lanes.d/_lib.route-rules.json; settings rows via lib_env_apply):
#   ROUTE_SHADOW            1 = record (default); 0 = do nothing at all.
#                           The route-shadow-off switch (a switch.route-shadow-off
#                           settings row, else flags/route-shadow-off) is the same.
#   ROUTE_RULES_TIMEOUT_S   per-request worker timeout (default 4)
set -uo pipefail

RR_HARNESS="${HARNESS:-/root/harness}"
_RR_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

_rr_src() { # _rr_src <lib-name> — this checkout's copy first, then the harness's
  local f
  for f in "${_RR_SELF_DIR:+$_RR_SELF_DIR/$1}" "$RR_HARNESS/bin/lib/$1"; do
    [ -n "$f" ] && [ -r "$f" ] && { . "$f" >/dev/null 2>&1; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- features ---
# _rr_plan_scan <plan.md> -> three 0/1 words: acceptance_tests invariants contract
# Fenced blocks are skipped whole: a sample heading is not a section.
_rr_plan_scan() {
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    # The section is judged on its FIRST content line. The plan prompt
    # (bin/lib/rb/plan.sh) has a SIZE S plan write "None beyond the iron laws"
    # plus one sentence of why: a first line that STARTS with an empty-section
    # phrase (none, n/a, not applicable, no [new|additional|system] invariants,
    # nothing beyond; any case, any trailing text, bullets and bold stripped) is
    # an empty section. "Nonce" is not "none": the word must end there. After
    # such a line, a later (a)-(d) clause line is still real content.
    # Only a heading of the SAME or a HIGHER level closes the section; a deeper
    # one ("### (a) Cross-run state") is content. Review of #2288, B1 and B1prime.
    function norm(s) { s = tolower(s); gsub(/^[[:space:]*_>-]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    function empty_phrase(s) {
      return s ~ /^(none|n\/a|not applicable|no (new |additional |system )?invariants|nothing beyond)([^a-z0-9]|$)/
    }
    function clause(s) { return s ~ /^\(?[a-d]\)([[:space:]]|$)/ }
    function content(s) {
      if (s == "") return
      if (first) { first = 0; if (!empty_phrase(s)) found = 1; return }
      if (clause(s)) found = 1
    }
    /^#+[[:space:]]/ {
      t = tolower($0); match($0, /^#+/); hl = RLENGTH
      if (inv && hl > lvl) { h = $0; sub(/^#+[[:space:]]+/, "", h); content(norm(h)); next }
      inv = 0
      if (t ~ /^#+[[:space:]]+acceptance tests/) acc = 1
      if (t ~ /^#+[[:space:]]+(system[[:space:]]+)?invariants([^a-z]|$)/) { inv = 1; lvl = hl; first = 1 }
      next
    }
    inv { content(norm($0)) }
    /^[[:space:]]*([-*][[:space:]]+)?CONTRACT:/ { con = 1 }
    END { printf "%d %d %d\n", acc + 0, found + 0, con + 0 }
  ' "$1" 2>/dev/null || echo "0 0 0"
}

# _rr_plan_paths <plan.md> -> every path token the plan names, one per line.
# bin/planned-files.sh keeps only some prefixes (src/, prisma/, tests/, ...) and
# extensions, so a plan that touches worker/, bin/, supabase/migrations/,
# server/, packages/ or a .py/.go file can reach the classifier as a docs-only
# list. These tokens are the FLOOR under it (review of #2288, I1): the plan's
# tier is the max of both. A token is a word ending in a code/data/doc
# extension, or a directory path through migrations/; URLs are dropped first,
# and prose slashes ("tests/docs", "and/or") carry no extension so never count.
# Over-listing is the safe direction: it can only move a plan toward review.
_rr_plan_paths() {
  sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:])>"]*##g' "$1" 2>/dev/null | tr '`"'"'"'()[]<>,;' ' ' \
    | grep -oE '([A-Za-z0-9_@.+-]+/)*[A-Za-z0-9_@+-][A-Za-z0-9_@.+-]*\.(sql|prisma|py|go|ts|tsx|js|jsx|mjs|cjs|sh|bash|rb|rs|java|kt|php|cs|swift|yml|yaml|json|toml|md|mdx|css|scss|html|vue|svelte)|([A-Za-z0-9_@.+-]+/)*migrations?/' \
    | sed 's#^\./##' | grep -viE '^(node|next|nuxt|vue|react|express|three|d3|chart|deno|bun)\.js$' | sort -u
}

route_features() { # route_features <build> -> JSON
  local b="${1:-}" plan kind repro lines files trace pt ptr pc acc inv con title u0=0 scan
  plan="$b/plan.md"
  kind=$(sed -n 's/^KIND:[[:space:]]*//p' "$b/kind.txt" 2>/dev/null | tail -1)
  [ -n "$kind" ] || kind=$(sed -n 's/^KIND:[[:space:]]*//p' "$plan" 2>/dev/null | tail -1)
  kind=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z')
  case "$kind" in bug|feature|copy|migration|infra) ;; *) kind=unknown ;; esac
  repro=$(sed -n 's/^KIND_REPRO:[[:space:]]*//p' "$b/kind.txt" 2>/dev/null | tail -1)
  lines=$(sed -n 's/^SIZE_DECLARED:.*lines=\([0-9][0-9]*\).*/\1/p' "$b/size-gate.txt" 2>/dev/null | tail -1)
  files=$(sed -n 's/^SIZE_DECLARED:.*files=\([0-9][0-9]*\).*/\1/p' "$b/size-gate.txt" 2>/dev/null | tail -1)
  trace=$(sed -n 's/^PLAN_TRACE:[[:space:]]*//p' "$b/plan-gate.txt" 2>/dev/null | tail -1)
  if command -v review_tier_files >/dev/null 2>&1; then
    ptr=$(review_tier_files "$b/planned-files.txt")
  else
    ptr="T2 reason=review-tier.sh unavailable"
  fi
  pt="${ptr%% *}"; case "$pt" in T0|T1|T2) ;; *) pt=T2 ;; esac
  # The floor: the plan's own path tokens, through the same classifier. Only a
  # HIGHER tier moves the answer; an empty token list moves nothing (the
  # planned-files answer already carries the empty-list T2).
  if [ "$pt" != T2 ] && [ -s "$plan" ] && command -v review_tier_files >/dev/null 2>&1; then
    local toks ft
    toks=$(_rr_plan_paths "$plan")
    if [ -n "$toks" ]; then
      ft=$(printf '%s\n' "$toks" | review_tier_files); ft="${ft%% *}"
      case "$pt$ft" in
        T0T1|T0T2|T1T2) ptr="$ft reason=plan path tokens (planned-files.txt said $pt)"; pt="$ft" ;;
      esac
    fi
  fi
  pc=$(grep -c '[^[:space:]]' "$b/planned-files.txt" 2>/dev/null) || pc=0
  if [ -s "$plan" ]; then scan=$(_rr_plan_scan "$plan"); else scan="0 0 0"; fi
  read -r acc inv con <<<"$scan"
  title=$(jq -r '.title // ""' "$b/ticket-meta.json" 2>/dev/null)
  grep -Eq '^[A-Za-z][A-Za-z0-9]*-[0-9]+\.0:' <<<"$title" && u0=1
  [ "$con" = 1 ] && u0=1
  jq -nc \
    --arg plan "$([ -s "$plan" ] && echo 1 || echo 0)" --arg kind "$kind" --arg repro "${repro:-}" \
    --arg lines "${lines:-}" --arg files "${files:-}" --arg trace "${trace:-}" \
    --arg pt "$pt" --arg ptr "${ptr#* reason=}" --arg pc "$pc" --arg acc "$acc" --arg inv "$inv" --arg u0 "$u0" '
    ($lines | tonumber? // null) as $l
    | {plan_present: ($plan == "1"), kind: $kind, kind_repro: $repro,
       lines: $l, files: ($files | tonumber? // null), size_declared: ($l != null),
       plan_trace: $trace, acceptance_tests: ($acc == "1"),
       planned_count: ($pc | tonumber? // 0), planned_tier: $pt, planned_tier_reason: $ptr,
       u0: ($u0 == "1"), invariant_bearing: ($inv == "1")}
    | .risk_surface = (.planned_tier == "T2" or .kind == "migration")
    # Files only: the plan'"'"'s own KIND label never picks the lite model
    # (review of #2288, I2). A copy change in product files is judged as the
    # product change it is.
    | .docs_only = (.planned_tier == "T0")
    | .fully_specified = (.plan_present and .plan_trace == "ok" and .size_declared
                          and .acceptance_tests and (.kind != "bug" or .kind_repro == "ok"))'
}

# ---------------------------------------------------------------- decision ---
# route_rules_decide <features-json> <rules-json> -> the decision JSON.
# Only mode 'shadow' rows are evaluated (the worker refuses any other live
# value, and 'off' is off). The FIRST matching 'route' rule by (priority, name)
# picks the unit's routing; every matching 'bump' rule is then applied in the
# same order. No match = the live execute role, the classifier's tier, full.
route_rules_decide() {
  jq -nc --argjson f "$1" --argjson r "$2" '
    def tier_n: if . == "T0" then 0 elif . == "T1" then 1 else 2 end;
    def tier_s: if . <= 0 then "T0" elif . == 1 then "T1" else "T2" end;
    def on($k): ($f[$k] // false) == true;
    def hot($rate; $n; $m): $rate != null and $n != null and $n >= ($m.min_reviews // 0) and $rate > $m.bounce_rate_gt;
    def matches:
      .match as $m
      | (($m.any // null) == null or any($m.any[]; on(.)))
        and (($m.all // null) == null or all($m.all[]; on(.)))
        and (($m.none // null) == null or all($m.none[]; on(.) | not))
        and (($m.max_lines // null) == null or ($f.lines != null and $f.lines <= $m.max_lines))
        and (($m.kind // null) == null or any($m.kind[]; . == $f.kind))
        and (($m.planned_tier // null) == null or any($m.planned_tier[]; . == $f.planned_tier))
        and (($m.bounce_rate_gt // null) == null
             or hot($f.bounce_project_rate; $f.bounce_project_n; $m)
             or hot($f.bounce_class_rate; $f.bounce_class_n; $m));
    ($f.planned_tier // "T2") as $pt
    | ([($r.rules // [])[] | select(.mode == "shadow")] | sort_by(.priority, .name)) as $rs
    | ([$rs[] | select(.effect == "route") | select(matches)] | first) as $base
    | {rule: ($base.name // ""),
       execute_role: ($base.execute_role // "build.execute"),
       review_n: ([(($base.review_tier // "T0") | tier_n), ($pt | tier_n)] | max),
       test_scope: ($base.test_scope // "full"), bumped: []}
    | reduce ($rs[] | select(.effect == "bump") | select(matches)) as $b (.;
        .execute_role = ($b.execute_role // .execute_role)
        | .review_n = ([.review_n + ($b.tier_bump // 0), 2] | min)
        | .test_scope = ($b.test_scope // .test_scope)
        | .bumped += [$b.name])
    | {rule, execute_role, review_tier: (.review_n | tier_s), planned_tier: $pt,
       test_scope, bumped: (.bumped | join(","))}'
}

# ------------------------------------------------------------------ worker ---
_rr_client() { # the real jobs client (and its modules), this checkout's first
  local c
  command -v _jobs_req >/dev/null 2>&1 && return 0
  for c in "${_RR_SELF_DIR:+$_RR_SELF_DIR/../jobs-client.sh}" "$RR_HARNESS/bin/jobs-client.sh"; do
    [ -n "$c" ] && [ -r "$c" ] && [ -r "$(dirname "$c")/lib/jobs/req.sh" ] || continue
    . "$c" >/dev/null 2>&1
    command -v _jobs_req >/dev/null 2>&1 && return 0
  done
  return 1
}

# _rr_rules_load -> sets RR_RULES (the rules JSON) and RR_RULES_SOURCE
# (worker | cache | none) in THIS shell. The worker's answer is cached per box;
# the cache answers only an outage, and no rules at all is an empty set (every
# build then reads "no rule matched" — the same as the live build).
_rr_rules_load() {
  local cache="$RR_HARNESS/state/route-rules.json" resp
  RR_RULES='{"rules":[]}'; RR_RULES_SOURCE=none
  if _rr_client && [ -n "${HARNESS_SECRET:-}" ] \
     && resp=$(JOBS_ALERT=0 _jobs_req GET /api/route-rules 2>/dev/null) \
     && [ -n "$resp" ] \
     && printf '%s' "$resp" | jq -e '(.rules | type) == "array"' >/dev/null 2>&1; then
    RR_RULES="$resp"; RR_RULES_SOURCE=worker
    mkdir -p "${cache%/*}" 2>/dev/null
    printf '%s\n' "$resp" > "$cache.tmp.$$" 2>/dev/null && mv -f "$cache.tmp.$$" "$cache" 2>/dev/null
    return 0
  fi
  # [ -s ] / [ -n ] first: jq 1.6 exits 0 on `jq -e` over empty input.
  if [ -s "$cache" ] && jq -e '(.rules | type) == "array"' "$cache" >/dev/null 2>&1; then
    RR_RULES=$(cat "$cache"); RR_RULES_SOURCE=cache
  fi
  return 0
}

# _rr_bounce <project> [rule] [days] -> `rate n` (rate may be null), or nothing
_rr_bounce() {
  local resp
  [ -n "${1:-}" ] && [ -n "${HARNESS_SECRET:-}" ] && _rr_client || return 0
  command -v route_shadow_bounce >/dev/null 2>&1 || return 0
  resp=$(JOBS_ALERT=0 route_shadow_bounce "$1" "${2:-}" "${3:-30}" 2>/dev/null) || return 0
  printf '%s' "$resp" | jq -r 'select(.reviewed != null) | "\(.rate // "null") \(.reviewed)"' 2>/dev/null
}

# _rr_with_bounce <features> <project> <rule> <days> -> features + bounce_*.
_rr_with_bounce() {
  local f="$1" pr pn cr cn
  read -r pr pn <<<"$(_rr_bounce "$2" "" "$4")"
  [ -n "$3" ] && read -r cr cn <<<"$(_rr_bounce "$2" "$3" "$4")"
  jq -c --arg pr "${pr:-null}" --arg pn "${pn:-null}" --arg cr "${cr:-null}" --arg cn "${cn:-null}" '
    .bounce_project_rate = ($pr | tonumber? // null) | .bounce_project_n = ($pn | tonumber? // null)
    | .bounce_class_rate = ($cr | tonumber? // null) | .bounce_class_n = ($cn | tonumber? // null)' <<<"$f"
}

# route_rules_resolve <build> [project] -> the decision JSON, with the features
# and the rules source beside it. Two passes, because the unit-class bounce
# rate belongs to whichever rule the plan matched first.
route_rules_resolve() {
  local b="${1:-}" project="${2:-}" feats rules d rule days
  _rr_src review-tier.sh
  feats=$(route_features "$b") || return 1
  _rr_rules_load
  rules="$RR_RULES"
  days=$(jq -r '[(.rules // [])[] | select(.mode == "shadow" and .effect == "bump") | .match.days // empty] | max // 30' <<<"$rules" 2>/dev/null)
  case "$days" in ''|*[!0-9]*) days=30 ;; esac
  d=$(route_rules_decide "$feats" "$rules") || return 1
  rule=$(jq -r '.rule' <<<"$d")
  if [ -n "$project" ] && jq -e 'any((.rules // [])[]; .mode == "shadow" and .effect == "bump")' >/dev/null 2>&1 <<<"$rules"; then
    feats=$(_rr_with_bounce "$feats" "$project" "$rule" "$days")
    d=$(route_rules_decide "$feats" "$rules") || return 1
  fi
  jq -c --argjson f "$feats" --arg src "$RR_RULES_SOURCE" '. + {features: $f, rules_source: $src}' <<<"$d"
}

_rr_off() {
  [ "${ROUTE_SHADOW:-1}" = 0 ] && return 0
  # The kill switch is read through lane_switch (BH-2320): a switch.route-shadow-off
  # settings row answers first, then flags/route-shadow-off as before. With no
  # lib, the file alone decides, as it always did.
  command -v lane_switch >/dev/null 2>&1 || _rr_src lane-switch.sh || true
  if command -v lane_switch >/dev/null 2>&1; then
    lane_switch route-shadow-off file && return 0
  else
    _rr_flag_file route-shadow-off && return 0
  fi
  return 1
}
_rr_flag_file() { [ -e "$RR_HARNESS/flags/$1" ]; }

_rr_knobs() { # the lib's settings rows into the env; fail-open, like every lib
  if ! command -v lib_env_apply >/dev/null 2>&1; then _rr_src lane-gate.sh || true; fi
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply route-rules >/dev/null 2>&1
  return 0
}

# route_shadow_record <project> <key> <build> <actual-exec> <actual-review> [job-id]
route_shadow_record() {
  local project="${1:-}" key="${2:-}" b="${3:-}" actual="${4:-}" review_actual="${5:-}" job="${6:-}"
  local dec role would review_model rec line
  [ -d "$b" ] || return 0
  _rr_off && return 0
  _rr_client >/dev/null 2>&1
  local JOBS_TIMEOUT="${ROUTE_RULES_TIMEOUT_S:-4}" JOBS_RETRIES=0
  dec=$(route_rules_resolve "$b" "$project") || return 0
  role=$(jq -r '.execute_role' <<<"$dec")
  if _rr_src model-route.sh; then
    would=$(_MR_QUIET=1 model_for "$role" "$project" 2>/dev/null) || would=""
    review_model=$(_MR_QUIET=1 model_for build.review "$project" 2>/dev/null) || review_model=""
  fi
  [ -n "${review_model:-}" ] || review_model="$review_actual"
  rec=$(jq -c --arg build "$(basename "$b")" --arg job "$job" --arg p "$project" --arg k "$key" \
          --arg would "${would:-}" --arg actual "$actual" --arg rm "$review_model" --arg box "${JOBS_BOX:-$(hostname 2>/dev/null)}" '
    {build: $build, job_id: $job, project: $p, ticket_key: $k, rule, bumped,
     would_execute_role: .execute_role, would_execute_model: $would, actual_execute_model: $actual,
     would_review_tier: .review_tier, planned_review_tier: .planned_tier, review_model: $rm,
     would_test_scope: .test_scope, features, rules_source, box: $box}' <<<"$dec") || return 0
  printf '%s\n' "$rec" > "$b/route-shadow.json.tmp.$$" 2>/dev/null && mv -f "$b/route-shadow.json.tmp.$$" "$b/route-shadow.json" 2>/dev/null
  line=$(jq -r '"ROUTE_SHADOW (log only) rule=\(if .rule == "" then "-" else .rule end) would=\(.would_execute_model // "?")(\(.would_execute_role))/\(.would_review_tier)/\(.would_test_scope)\(if .bumped != "" then " bumped=" + .bumped else "" end) actual=\(.actual_execute_model) review=\(.review_model) rules=\(.rules_source)"' <<<"$rec")
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$project/$key] $line" >> "$b/pipeline.log" 2>/dev/null
  if [ -n "${HARNESS_SECRET:-}" ] && command -v route_shadow_put >/dev/null 2>&1; then
    JOBS_ALERT=0 route_shadow_put "$(jq -c 'del(.rules_source)' <<<"$rec")" >/dev/null 2>&1 || true
  fi
  return 0
}

# _rr_close_fds — drop every descriptor above 2 this process inherited. The
# build holds flock locks on fds it opened for itself (6 = the repo lock, 7 =
# the per-key dedupe, 7+S = build-slot-S for any BUILD_SLOTS): the hook closes
# 6-9 by name, and this closes whatever else a box's slot count put there, so
# the shadow never holds a build's lock for its (<= 30 s) lifetime.
_rr_close_fds() {
  local fd fds
  fds=$(ls "/proc/$$/fd" 2>/dev/null) || fds=$(seq 3 254)
  for fd in $fds; do
    case "$fd" in ''|*[!0-9]*) continue ;; esac
    # 255 is bash's own handle on this script: closing it makes bash reopen the
    # file on the lowest free fd, which can be a slot number it just freed.
    [ "$fd" -gt 2 ] && [ "$fd" -lt 255 ] && eval "exec $fd>&-" 2>/dev/null
  done
  [ -n "${ROUTE_RULES_FD_PROBE:-}" ] && ls "/proc/$$/fd" > "$ROUTE_RULES_FD_PROBE" 2>/dev/null   # test seam
  return 0
}

# ---------------------------------------------------------------------- CLI ---
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"; shift 2>/dev/null
  case "$cmd" in
    shadow)
      _rr_close_fds
      _rr_off && exit 0
      _rr_knobs
      _rr_off && exit 0
      route_shadow_record "$@"
      exit 0 ;;
    resolve)
      [ -n "${1:-}" ] || { echo "usage: route-rules.sh resolve <build> [project]" >&2; exit 2; }
      d=$(route_rules_resolve "$1" "${2:-}") || exit 1
      jq -r '"rule=\(.rule)", "execute_role=\(.execute_role)", "review_tier=\(.review_tier)",
             "planned_tier=\(.planned_tier)", "test_scope=\(.test_scope)", "bumped=\(.bumped)",
             "rules_source=\(.rules_source)"' <<<"$d"
      exit 0 ;;
    *) echo "usage: route-rules.sh {shadow <project> <key> <build> <actual-exec-model> <actual-review-model> [job-id]|resolve <build> [project]}" >&2
       exit 2 ;;
  esac
fi
