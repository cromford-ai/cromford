# shellcheck shell=bash
# bin/lib/mc-ci-advisory.sh — BH-9210: a failed workflow run that holds no
# failed REQUIRED check is advisory, not red. Sourced, never run.
#
# Incident (2026-11-07): every project-6 PR sat RED_TWICE. The report-only
# workflows `unit-clock` and `unit-shuffle` failed on every head, and
# mc_ci_state answered `red` for any failed latest workflow run. Mergify
# required only `ci` and `e2e-ratchet`, and both were green. The BH-8012 net
# (bin/lib/mc-required-ci.sh) reads one check-runs page of 100, and a project-6
# head holds more check runs than that, so it did not fire.
#
# THE RULE. On a Mergify repo (not project-4) whose .mergify.yml queue_rules name
# at least one `check-success` name, a failed latest run is advisory when its
# jobs (a job IS the check run of its run) were read in full and every job whose
# name exactly equals a required name concluded `success`. A run with no
# required job is advisory too. Any other conclusion of a required job
# (failure, cancelled, skipped, timed_out, none) keeps the run red. A read that
# fails, does not parse, or does not hold every job keeps the run red: an
# unread run is never advisory. Each advisory head writes one ledger line and
# one `advisory-red: <workflow>` log line per advisory workflow, once.
#
# NO READABLE REQUIRED SET (BH-9368). When .mergify.yml cannot be read
# (required-unread) or names no check-success (required-none), a failed run is
# advisory only when its jobs were read in full and EVERY job that did not end
# success, skipped or neutral has a name that ends in MC_CI_REPORT_ONLY_SUFFIX
# (` (report only)`). One other failed job, or a jobs read that fails or is
# cut, keeps the run red. MC_CI_REQ_APPLIED stays 0: no required set was read.
# A `continue-on-error: true` job is not visible in the jobs API; it does not
# fail its workflow run, so mc_ci_state already reads that run as green.
#
# Knobs (one file each in catalog/lanes.d/merge-conductor.knobs.d/):
#   MC_CI_ADVISORY_RED     1 = the rule is on; 0 = every failed run is red.
#   MC_CI_REPORT_ONLY_SUFFIX  the job-name suffix of a report-only check; default
#                          ` (report only)`, empty = off (BH-9368).
#   MC_CI_JOBS_PAGES_MAX   jobs pages (100 each) read per failed run; default 3.
#   MC_CI_ADVISORY_KEEP_D  days a ledger line is kept; default 7.
#
# The ledger: $MC_STATE_DIR/ci-advisory-red.tsv, `<epoch>\t<slug>\t<sha>\t<workflows>`.
# Writer: mca_note. Readers: mca_note (dedup), mca_count_24h
# (bin/fleet-status-push.sh field `ci_advisory_red`).
[ -n "${MC_CI_ADVISORY_LIB:-}" ] && return 0
MC_CI_ADVISORY_LIB=1

# mca_enabled — rc 0 unless MC_CI_ADVISORY_RED is 0.
#   Knob: catalog/lanes.d/merge-conductor.knobs.d/MC_CI_ADVISORY_RED.json (fallback 1).
mca_enabled() { [ "${MC_CI_ADVISORY_RED:-1}" != 0 ]; }

# _mca_int <value> <fallback> — a whole number >= 1, else the fallback.
_mca_int() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) [ "$((10#$1))" -ge 1 ] && printf '%s' "$((10#$1))" || printf '%s' "$2" ;; esac; }

_mca_now() { if command -v mc_now >/dev/null 2>&1; then mc_now; else date -u +%s; fi; }

# _mca_jobs <slug> <run-id> <outvar> — every latest-attempt job of the run as
#   `<conclusion>\t<name>` lines into <outvar> (`-` for no conclusion: an
#   empty first field would vanish under a tab IFS). rc 0 when the pages held
#   total_count jobs; rc 1 otherwise, with MCA_WHY naming why.
_mca_jobs() {
  local slug="$1" id="$2" _out="$3" max p=1 body tot got=0 page all="" rc n
  # Knob: catalog/lanes.d/merge-conductor.knobs.d/MC_CI_JOBS_PAGES_MAX.json (fallback 3).
  max=$(_mca_int "${MC_CI_JOBS_PAGES_MAX:-}" 3)
  printf -v "$_out" '%s' ""
  while [ "$p" -le "$max" ]; do
    rc=0; mc_rest_var body gh_rest GET "repos/$slug/actions/runs/$id/jobs?filter=latest&per_page=100&page=$p" || rc=$?
    [ "$rc" = 0 ] || { MCA_WHY="run $id jobs read failed (HTTP ${GH_REST_STATUS:-000})"; return 1; }
    tot=$(jq -er '.total_count | numbers' <<<"$body" 2>/dev/null) \
      && page=$(jq -er '[.jobs[] | "\((.conclusion // "") | if . == "" then "-" else . end)\t\(.name // "" | gsub("[\t\n]"; " "))"] | join("\n")' <<<"$body" 2>/dev/null) \
      || { MCA_WHY="run $id jobs page $p does not parse"; return 1; }
    # A failed run with no job at all (a broken workflow file) names nothing
    # either way: it stays red.
    [ "$tot" -gt 0 ] || { MCA_WHY="run $id lists no job"; return 1; }
    n=$(jq -r '.jobs | length' <<<"$body" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    got=$(( got + n ))
    [ -n "$page" ] && all="${all:+$all$'\n'}$page"
    [ "$got" -ge "$tot" ] && { printf -v "$_out" '%s' "$all"; return 0; }
    [ "$n" = 0 ] && break
    p=$((p + 1))
  done
  MCA_WHY="run $id holds $tot jobs, read $got in $max page(s)"
  return 1
}

# _mca_report_only <slug> <lines> — BH-9368, mca_split's rule when no required
#   set can be read. Sets MCA_KEEP, MC_CI_ADVISORY and MC_CI_RED_RUN_IDS in the
#   caller's shell. Knob: MC_CI_REPORT_ONLY_SUFFIX (fallback ` (report only)`,
#   catalog/lanes.d/merge-conductor.knobs.d/MC_CI_REPORT_ONLY_SUFFIX.json).
_mca_report_only() {
  local slug="$1" lines="$2" suf line s c id name jl jc jn red keep="" n
  suf="${MC_CI_REPORT_ONLY_SUFFIX- (report only)}"
  [ -n "$suf" ] || return 0
  MC_CI_RED_RUN_IDS=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS='|' read -r s c id name <<<"$line"
    red=""; n=0
    if ! _mca_jobs "$slug" "$id" jl; then
      red=unread
    else
      while IFS=$'\t' read -r jc jn; do
        [ -n "$jn" ] || continue
        case "$jc" in success|skipped|neutral) continue ;; esac
        n=$((n + 1))
        # An exact suffix: ` (report only)` at the end, with its leading space.
        case "$jn" in *"$suf") [ "${#jn}" -gt "${#suf}" ] && continue ;; esac
        red=1
      done <<<"$jl"
      [ "$n" -gt 0 ] || red=1
    fi
    if [ -n "$red" ]; then
      keep="${keep:+$keep$'\n'}$line"
      MC_CI_RED_RUN_IDS="${MC_CI_RED_RUN_IDS:+$MC_CI_RED_RUN_IDS }$id"
    else
      MC_CI_ADVISORY="${MC_CI_ADVISORY:+$MC_CI_ADVISORY,}$name"
    fi
  done <<<"$lines"
  MCA_KEEP="$keep"
  return 0
}

# mca_split <slug> <sha> <failed-lines> — plain command, never in $( ).
#   Input: one `completed|failure|<run-id>|<workflow name>` line per latest
#   failed run (mc_ci_state's reduction shape). Sets, in the caller's shell:
#     MCA_KEEP            the input lines that stay red
#     MC_CI_ADVISORY      advisory workflow names, comma list
#     MC_CI_RED_CHECKS    required job names not `success` in a kept run, comma list
#     MC_CI_RED_RUN_IDS   the run ids of the kept lines, space list
#     MC_CI_REQ_APPLIED   1 when the rule ran, 0 when the old rule stands
#     MC_CI_REQ_SHA       <sha>
#     MCA_WHY             one line
mca_split() {
  local slug="$1" sha="$2" lines="$3" req prov line s c id name jl jc jn red adv keep="" GH_REST_TIMEOUT_S
  MCA_KEEP="$lines"; MC_CI_ADVISORY=""; MC_CI_RED_CHECKS=""; MC_CI_RED_RUN_IDS=""
  MC_CI_REQ_APPLIED=0; MC_CI_REQ_SHA="$sha"; MCA_WHY=""
  while IFS='|' read -r s c id name; do [ -n "$id" ] && MC_CI_RED_RUN_IDS="${MC_CI_RED_RUN_IDS:+$MC_CI_RED_RUN_IDS }$id"; done <<<"$lines"
  mca_enabled || { MCA_WHY=off; return 0; }
  case "$slug" in */project-4) MCA_WHY=project-4; return 0 ;; esac
  command -v mc_queue_provider >/dev/null 2>&1 && command -v mc_mergify_required_checks >/dev/null 2>&1 \
    && command -v gh_rest >/dev/null 2>&1 && command -v mc_rest_var >/dev/null 2>&1 || { MCA_WHY=no-reader; return 0; }
  prov=$(mc_queue_provider "$slug" 2>/dev/null)
  [ "$prov" = mergify ] || { MCA_WHY="provider ${prov:-none}"; return 0; }
  req=$(mc_mergify_required_checks "$slug" 2>/dev/null) || MCA_WHY=required-unread
  if [ -z "$MCA_WHY" ]; then
    req=$(grep -v '^[[:space:]]*$' <<<"$req")
    [ -n "$req" ] || MCA_WHY=required-none
  fi
  GH_REST_TIMEOUT_S=30
  command -v mc_ci_read_timeout_s >/dev/null 2>&1 && GH_REST_TIMEOUT_S=$(mc_ci_read_timeout_s)
  [ "${GH_REST_TIMEOUT_S:-0}" -gt 0 ] 2>/dev/null || GH_REST_TIMEOUT_S=
  if [ -n "$MCA_WHY" ]; then
    # BH-9368: no readable required set. Only a report-only failure is advisory.
    _mca_report_only "$slug" "$lines"
    if [ -n "$MC_CI_ADVISORY" ]; then
      MCA_WHY="$MCA_WHY; report-only advisory $MC_CI_ADVISORY"
      mca_note "$slug" "$sha" "$MC_CI_ADVISORY" "no readable required set; every failed job is a report-only check"
    fi
    return 0
  fi
  MC_CI_REQ_APPLIED=1; MC_CI_RED_RUN_IDS=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS='|' read -r s c id name <<<"$line"
    red=""
    if ! _mca_jobs "$slug" "$id" jl; then
      red=unread
    else
      while IFS=$'\t' read -r jc jn; do
        [ -n "$jn" ] || continue
        grep -qxF -- "$jn" <<<"$req" || continue
        [ "$jc" = success ] && continue
        red=1
        case ",$MC_CI_RED_CHECKS," in *",$jn,"*) ;; *) MC_CI_RED_CHECKS="${MC_CI_RED_CHECKS:+$MC_CI_RED_CHECKS,}$jn" ;; esac
      done <<<"$jl"
    fi
    if [ -n "$red" ]; then
      keep="${keep:+$keep$'\n'}$line"
      MC_CI_RED_RUN_IDS="${MC_CI_RED_RUN_IDS:+$MC_CI_RED_RUN_IDS }$id"
    else
      MC_CI_ADVISORY="${MC_CI_ADVISORY:+$MC_CI_ADVISORY,}$name"
    fi
  done <<<"$lines"
  MCA_KEEP="$keep"
  adv="$MC_CI_ADVISORY"
  [ -n "$MCA_WHY" ] || MCA_WHY="required $(paste -sd, <<<"$req"); advisory ${adv:-none}; red ${MC_CI_RED_CHECKS:-none}"
  [ -n "$adv" ] && mca_note "$slug" "$sha" "$adv" "$(paste -sd, <<<"$req" | sed 's/,/, /g')"
  return 0
}

# mca_note <slug> <sha> <workflows> [<required names>] — the head ledger.
#   Under flock: a line for (slug, sha) already there = nothing. Else one
#   ledger line, one `advisory-red:` log line per workflow, and a prune of
#   lines older than MC_CI_ADVISORY_KEEP_D days (tmp + mv). No MC_STATE_DIR:
#   nothing written. Always rc 0.
mca_note() {
  local slug="$1" sha="$2" wfs="$3" req="${4:-}" f now keep w
  [ -n "${MC_STATE_DIR:-}" ] && [ -n "$slug" ] && [ -n "$sha" ] && [ -n "$wfs" ] || return 0
  f="$MC_STATE_DIR/ci-advisory-red.tsv"
  mkdir -p "$MC_STATE_DIR" 2>/dev/null || return 0
  now=$(_mca_now)
  # Knob: catalog/lanes.d/merge-conductor.knobs.d/MC_CI_ADVISORY_KEEP_D.json (fallback 7).
  keep=$(_mca_int "${MC_CI_ADVISORY_KEEP_D:-}" 7)
  (
    flock -n 9 || exit 0
    awk -F'\t' -v s="$slug" -v h="$sha" '$2 == s && $3 == h {f = 1} END {exit !f}' "$f" 2>/dev/null && exit 0
    printf '%s\t%s\t%s\t%s\n' "$now" "$slug" "$sha" "$wfs" >> "$f" || exit 0
    if command -v mc_log >/dev/null 2>&1; then
      while IFS= read -r w; do
        [ -n "$w" ] && mc_log "advisory-red: $w on $slug ${sha:0:8}: its failed run holds no failed required check${req:+ ($req)}; not red"
      done < <(tr ',' '\n' <<<"$wfs")
    fi
    awk -F'\t' -v cut="$(( now - keep * 86400 ))" '$1 ~ /^[0-9]+$/ && $1 + 0 >= cut' "$f" > "$f.tmp.$$" 2>/dev/null \
      && mv -f "$f.tmp.$$" "$f" 2>/dev/null
    rm -f "$f.tmp.$$" 2>/dev/null
  ) 9>"$f.lock"
  return 0
}

# mca_count_24h <file> <now> — a JSON array `[{repo, heads}]`: the distinct
#   heads per repo with a ledger line in the last 24 h, most heads first. A
#   line without 4 tab fields or with a non-number epoch is dropped. A missing
#   file or a jq failure: `[]`.
mca_count_24h() {
  local f="$1" now="$2" out
  case "$now" in ''|*[!0-9]*) printf '[]'; return 0 ;; esac
  [ -r "$f" ] || { printf '[]'; return 0; }
  out=$(jq -Rsc --argjson now "$now" 'split("\n") | map(split("\t") | select(length == 4)
          | try {at: (.[0] | tonumber), repo: .[1], sha: .[2]} catch empty
          | select(.at >= $now - 86400 and .repo != "" and .sha != ""))
        | group_by(.repo) | map({repo: .[0].repo, heads: (map(.sha) | unique | length)})
        | sort_by(-.heads, .repo)' "$f" 2>/dev/null) || out='[]'
  case "$out" in '['*']') printf '%s' "$out" ;; *) printf '[]' ;; esac
}

# mca_rerun_filter <slug> <key> <head> — stdin: flaky_failed_runs lines
#   (`id|path|name|rsha`). When the required-set rule ran on <head>, it passes
#   only the runs mca_split kept red and logs one line per dropped run. Else it
#   passes every line. The globals come from this head's mc_ci_state; when they
#   are for another head (a memo hit), it calls mc_ci_state once to set them.
mca_rerun_filter() {
  local slug="$1" key="$2" head="$3" in id path name rsha
  in=$(cat)
  if [ "${MC_CI_REQ_SHA:-}" != "$head" ] && command -v mc_ci_state >/dev/null 2>&1; then
    mc_ci_state "$slug" "$head" >/dev/null 2>&1
  fi
  if [ "${MC_CI_REQ_SHA:-}" != "$head" ] || [ "${MC_CI_REQ_APPLIED:-0}" != 1 ]; then
    [ -n "$in" ] && printf '%s\n' "$in"
    return 0
  fi
  while IFS='|' read -r id path name rsha; do
    [ -n "$id" ] || continue
    case " ${MC_CI_RED_RUN_IDS:-} " in
      *" $id "*) printf '%s|%s|%s|%s\n' "$id" "$path" "$name" "$rsha" ;;
      *) command -v mc_log >/dev/null 2>&1 && mc_log "$key run $id ($name) holds no failed required check — not re-run" ;;
    esac
  done <<<"$in"
  return 0
}
