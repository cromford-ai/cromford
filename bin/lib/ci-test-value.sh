#!/bin/bash
# gh-identity: raw-by-design — its one raw gh call is `gh api --help`, a local flag probe that sends no request; every GitHub read goes through gh_rest, on whatever identity the caller armed.
# bin/lib/ci-test-value.sh — the collector half of the CI test value report
# (BH-6618). Sourced by bin/ci-test-value-report.sh, never executed, and
# nothing runs on source except the two seam files below.
#
# It has no harness root of its own: every path it writes is under $CTV_OUT,
# and a function that needs CTV_OUT refuses (rc 75) when it is empty.
#
#   ctv_gh_get <api-path> <cache-key|->   one GitHub REST GET, body on stdout.
#       rc 0 read (or cache hit), 44 absent, 75 unread. Run it as a plain
#       command with `> file`, never inside `$( )`: CTV_GH_READS, CTV_STOP and
#       GH_REST_STATUS must stay in the caller's shell.
#   ctv_parse_job_log                     a job log on stdin ->
#       `unit\trc\tsecs\tline_no`, one line per unit the log names.
#   ctv_excerpt <log> <line_no> <harness|test|job>   the failure text of a unit.
#   ctv_rules_load / ctv_classify_row     the rule registry (rules.d/).
#   ctv_row_put                           the CTV_* row vars as one row line.
#   ctv_classify_all <rows>               rows -> $CTV_OUT/occurrences.tsv.
#
# THE RULE REGISTRY. bin/lib/ci-test-value/rules.d/NN-<slug>.sh, one file per
# rule group, sourced once in LC_ALL=C order. Each defines ctv_rule_<slug>
# (dashes become underscores). A rule reads the CTV_* row vars; to decide the
# row it prints `class\trule\twhy` and returns 0. The first rc 0 wins.
_CTV_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/lib/ci-test-value/model.sh
. "$_CTV_LIB_DIR/ci-test-value/model.sh"
# shellcheck source=bin/lib/ci-test-value/sources.sh
. "$_CTV_LIB_DIR/ci-test-value/sources.sh"

# The row file's columns, in order. ctv_row_put writes them, ctv_classify_all
# reads them back. The separator is \x1f, not a tab: `read` collapses runs of
# a whitespace IFS, so an empty field between two tabs would shift the rest.
_CTV_ROW_VARS=(CTV_DAY CTV_RUN_ID CTV_ATTEMPT CTV_JOB_ID CTV_WORKFLOW_ID CTV_EVENT
  CTV_HEAD_BRANCH CTV_HEAD_SHA CTV_BASE_SHA CTV_PR_NUMBERS CTV_IS_BATCH
  CTV_DISPLAY_TITLE CTV_JOB_NAME CTV_JOB_CONCLUSION CTV_STEP CTV_UNIT CTV_RC
  CTV_SECS CTV_EXCERPT_FILE CTV_RUN_URL CTV_JOB_URL)

# _ctv_gh_esc_probe — sets _CTV_GH_ESC to --allow-escape-sequences when the
#   installed gh lists it in `gh api --help`, else to empty. Once per process.
#   The help goes into a variable first: `gh … | grep -q` is a SIGPIPE race.
_ctv_gh_esc_probe() {
  local h
  [ -n "${_CTV_GH_ESC_PROBED:-}" ] && return 0
  _CTV_GH_ESC_PROBED=1; _CTV_GH_ESC=
  h=$(gh api --help 2>/dev/null) || h=
  [[ "$h" == *--allow-escape-sequences* ]] && _CTV_GH_ESC=--allow-escape-sequences
  return 0
}

ctv_gh_get() { # ctv_gh_get <api-path> <cache-key|->
  local p="${1:-}" key="${2:-}" c="" tmp rc=0
  [ -n "$p" ] && [ -n "$key" ] && [ -n "${CTV_OUT:-}" ] || return 75
  if [ "$key" != - ]; then
    [[ "$key" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$key" != *..* ]] || return 75
    c="$CTV_OUT/cache/$key"
    if [ -s "$c" ]; then cat "$c"; return 0; fi
  fi
  if [ "${CTV_GH_READS:-0}" -ge "${CTV_GH_MAX_READS:-3000}" ]; then CTV_STOP=max-reads; return 75; fi
  # rc 0 is low. rc 2 (unknown) proceeds, as the gh-budget contract says.
  if [ "${CTV_BUDGET_CHECK:-0}" = 1 ] && gh_budget_low ci-test-value; then CTV_STOP=budget-low; return 75; fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/ctv-get.XXXXXX") || return 75
  CTV_GH_READS=$(( ${CTV_GH_READS:-0} + 1 ))
  # A job log holds ANSI colour codes. A gh that has --allow-escape-sequences
  # prints only the headers for such a body unless the flag is passed, and
  # gh_rest answers 75 on the empty 200 (BH-6636 probe). A gh without the flag
  # (the hub's gh 2.45) rejects it as an unknown flag, so it rides only on a
  # log read and only when `gh api --help` lists it. A JSON body has no raw
  # ESC byte. Either way the log is stored with its escape sequences removed.
  if [[ "$p" == */logs ]]; then
    _ctv_gh_esc_probe
    GH_ETAG=0 gh_rest GET "$p" ${_CTV_GH_ESC:+"$_CTV_GH_ESC"} > "$tmp" || rc=$?
    if [ "$rc" = 0 ]; then
      LC_ALL=C sed $'s/\x1b\\[[0-9;?]*[A-Za-z]//g; s/\x1b//g' "$tmp" > "$tmp.s" && mv -f "$tmp.s" "$tmp" || rc=75
    fi
  else
    GH_ETAG=0 gh_rest GET "$p" > "$tmp" || rc=$?
  fi
  case "$rc" in
    0) ;;
    44) rm -f "$tmp"; return 44 ;;
    *) rm -f "$tmp" "$tmp.s"; return 75 ;;
  esac
  if [ -n "$c" ]; then
    mkdir -p "${c%/*}" && cp "$tmp" "$c.tmp.$$" && mv -f "$c.tmp.$$" "$c" || rm -f "$c.tmp.$$"
  fi
  cat "$tmp"
  rm -f "$tmp"
  return 0
}

# One GitHub timestamp prefix, a BOM and a trailing \r are stripped first. A
# harness suite line is anchored at column 0, so a test that echoes one
# indented is not a unit. A `FAIL <token>` line (vitest/jest) and a node
# --test `location:` line count only for a test-file token, once per file. A
# node unit's line_no is the `not ok` line that opens its block (the test name).
ctv_parse_job_log() {
  LC_ALL=C awk -v q="'" '
    { sub(/\r$/, "") }
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z /, "") }
    function testfile(t) { return t ~ /\.test\./ || t ~ /\.spec\./ || t ~ /__tests__\// }
    function once(u) { if (u in seen) return 0; seen[u] = 1; return 1 }
    /^[ \t]*not ok [0-9]+ - / { nok = NR }
    /^--- tests\/(mc\/)?[A-Za-z0-9._\/-]+\.sh rc=[0-9]+ [0-9]+s$/ {
      rc = $3; sub(/^rc=/, "", rc); s = $4; sub(/s$/, "", s)
      printf "%s\t%s\t%s\t%d\n", $2, rc, s, NR; next
    }
    /^ ?FAIL[ \t]+[^ \t]/ {
      if ($1 == "FAIL" && testfile($2) && once($2)) printf "%s\t1\t-\t%d\n", $2, NR
      next
    }
    /^[ \t]+location: / {
      u = $0; sub(/^[ \t]+location: /, "", u)
      if (length(u) < 3 || substr(u, 1, 1) != q || substr(u, length(u), 1) != q) next
      u = substr(u, 2, length(u) - 2)
      if (u !~ /:[0-9]+:[0-9]+$/) next
      sub(/:[0-9]+:[0-9]+$/, "", u)
      sub(/^\/home\/runner\/work\/[^\/]+\/[^\/]+\//, "", u)
      if (testfile(u) && once(u)) printf "%s\t1\t-\t%d\n", u, (nok ? nok : NR)
    }'
}

ctv_excerpt() { # ctv_excerpt <log> <line_no> <harness|test|job>
  local n="${CTV_EXCERPT_LINES:-60}"
  LC_ALL=C awk -v from="${2:-0}" -v kind="${3:-job}" -v n="$n" '
    { sub(/\r$/, ""); sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z /, "") }
    kind == "job" { buf[NR % n] = $0; next }
    kind == "harness" && NR > from {
      if ($0 ~ /^--- tests\/(mc\/)?[A-Za-z0-9._\/-]+\.sh rc=[0-9]+ [0-9]+s$/ || NR > from + n) exit
      print; next
    }
    kind == "test" && NR >= from { if (NR >= from + n) exit; print }
    END { if (kind == "job") for (i = NR - n + 1; i <= NR; i++) if (i > 0) print buf[i % n] }
  ' "$1"
}

ctv_rules_load() {
  local dir f base slug fn
  [ "${_CTV_RULES_LOADED:-}" = 1 ] && return 0
  dir="$_CTV_LIB_DIR/ci-test-value/rules.d"
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${CTV_RULES_DIR:-}" ]; then dir="$CTV_RULES_DIR"; fi
  _CTV_RULES=()
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    base=${f##*/}; slug=${base#[0-9][0-9]-}; slug=${slug%.sh}; fn="ctv_rule_${slug//-/_}"
    # shellcheck disable=SC1090 # the registry is a directory of files
    if ! . "$f"; then echo "ctv: rule file $f failed to source" >&2; return 1; fi
    if ! declare -F "$fn" >/dev/null; then echo "ctv: rule file $f does not define $fn" >&2; return 1; fi
    _CTV_RULES+=("$fn")
  done < <(printf '%s\n' "$dir"/[0-9][0-9]-*.sh | LC_ALL=C sort)
  _CTV_RULES_LOADED=1
}

ctv_classify_row() { # the CTV_* row vars -> `class\trule\twhy`
  local fn out rc line cls rule
  ctv_rules_load || return 1
  for fn in ${_CTV_RULES[@]+"${_CTV_RULES[@]}"}; do
    rc=0; out=$("$fn") || rc=$?
    [ "$rc" = 0 ] || continue
    line=${out%%$'\n'*}
    cls=${line%%$'\t'*}; rule=${line#*$'\t'}; rule=${rule%%$'\t'*}
    if [[ "$line" == *$'\t'*$'\t'* ]] && [[ "$cls" =~ ^[a-z][a-z0-9_-]*$ ]] && [ -n "$rule" ]; then
      printf '%s\n' "$line"
    else
      printf 'unknown\tU2.rule-error\t%s\n' "${fn#ctv_rule_}" | tr _ -
    fi
    return 0
  done
  printf 'unknown\tU1.undecided\t\n'
}

_ctv_clean() { local v="${1:-}"; v=${v//[$'\t\n\r\x1f']/ }; printf '%s' "$v"; }

ctv_row_put() { # the CTV_* row vars -> one \x1f-separated line on stdout
  local v out="" sep=""
  for v in "${_CTV_ROW_VARS[@]}"; do out+="$sep$(_ctv_clean "${!v:-}")"; sep=$'\x1f'; done
  printf '%s\n' "$out"
}

ctv_classify_all() { # ctv_classify_all <rows> -> $CTV_OUT/occurrences.tsv
  local rows="${1:-}" occ tmp line cls rule why i
  local -a vals
  [ -n "${CTV_OUT:-}" ] && [ -r "$rows" ] || return 1
  ctv_rules_load || return 1
  occ="$CTV_OUT/occurrences.tsv"; tmp="$occ.tmp.$$"
  {
    printf '#run_id\tattempt\tjob_id\tday\tevent\tis_batch\thead_sha\tunit\trc\tsecs\tclass\trule\trun_url\tjob_url\twhy\n'
    while IFS= read -r line; do
      IFS=$'\x1f' read -r -a vals <<<"$line"
      for i in "${!_CTV_ROW_VARS[@]}"; do printf -v "${_CTV_ROW_VARS[$i]}" '%s' "${vals[$i]:-}"; done
      IFS=$'\t' read -r cls rule why < <(ctv_classify_row)
      printf '%s\t' "$CTV_RUN_ID" "$CTV_ATTEMPT" "$CTV_JOB_ID" "$CTV_DAY" "$CTV_EVENT" "$CTV_IS_BATCH" \
        "$CTV_HEAD_SHA" "$CTV_UNIT" "$CTV_RC" "$CTV_SECS" "$cls" "$rule" "$CTV_RUN_URL" "$CTV_JOB_URL"
      _ctv_clean "$why"; printf '\n'
    done < "$rows" | LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3n -k8,8
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$occ" || return 1
  [ "${CTV_NO_MODEL:-0}" = 1 ] && return 0
  ctv_model_pass "$occ"
}
