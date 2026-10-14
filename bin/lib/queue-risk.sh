#!/bin/bash
# gh-identity: raw-by-design — its two label writes run INSIDE mc_enqueue_mergify, on the identity the conductor already armed for this repo, the same identity that writes the merge-queue label right after them; a second mint here would override that choice.
# bin/lib/queue-risk.sh — THE BREAK-RISK SCORE IN THE MERGE QUEUE (BH-5430).
# Sourced, never executed.
#
#   qr_rules_load                       the weights, globs, size limits and
#                                       threshold from settings rows
#   qr_mode                             queue_risk.mode: off|shadow|enforce
#   qr_score <files> <lines> <nfiles> <slug> <num>
#                                       `<score>\t<threshold>\t<solo|batch>\t<reasons>`
#   qr_enqueue_step <slug> <num> <head> mc_enqueue_mergify's block; rc 0 always
#
# WHY. Mergify batches PRs in arrival order (batch_size 8) and stacks each batch
# on the ones ahead of it, so one risky PR fails its own batch and every stacked
# batch behind it, and Mergify then bisects for ~20 minutes a round. On
# 2026-10-08 that held every merge for more than 1.5 hours. A PR that is likely
# to break goes into the `solo` queue (batch_size 1, config/mergify/template.yml)
# instead: it costs its own CI run and takes nobody down with it.
#
# THE SCORE is a sum of cheap signals, each counted ONCE per PR (not per file),
# each with a weight row. The path signals read a glob row; the others read
# the PR object (lines, files), main's tree (new tests) and the conductor's
# attempt ledger (prior culprit verdicts, prior pre-queue reds):
#   shared_lib ci_config registry generated share_mirror schema  a path matches
#   new_tests        a test-shaped path that main ($HARNESS) does not have yet
#   size             lines >= size_lines; >= size_lines_big counts it twice
#   size_files       changed files >= size_files
#   ejected_before   per `bejculprit <slug>#<n>` ledger line, capped at 2x
#   prequeue_red     any `pqred <slug>#<n>` ledger line (BH-4545's park mark)
# score >= threshold is solo. Every row is a settings row (queue_risk.*); the
# QR_*_DEFAULT constants below are only the fallbacks, used on rc 2 (no row).
# An unreadable row (rc 1, or a non-integer weight) also uses the fallback and
# puts `rows-unreadable` in the reasons: the rows tune routing, they are not a
# safety gate, so an outage still routes.
#
# UNKNOWN RISK IS TODAY'S ROUTING, NEVER SOLO. A PR whose file list cannot be
# read is `batch` with the reason files-unavailable. That is the opposite of
# qp_impact's serial-on-unknown on purpose: a GitHub blip must not put every PR
# in a size-1 lane and cut merge throughput 8x, and `batch` is exactly what the
# queue did for every PR before this lib.
#
# The root is ${HARNESS:-${H:-}} and nothing else (D43): empty is a silent rc 0.
# Bash 4, jq; no awk.
[ -n "${_QR_LOADED:-}" ] && return 0
_QR_LOADED=1

QR_SIGNALS='shared_lib ci_config registry generated share_mirror schema new_tests size size_files ejected_before prequeue_red'
QR_PATH_SIGNALS='shared_lib ci_config registry generated share_mirror schema'
QR_W_DEFAULT_shared_lib=30
QR_W_DEFAULT_ci_config=40
QR_W_DEFAULT_registry=25
QR_W_DEFAULT_generated=20
QR_W_DEFAULT_share_mirror=30
QR_W_DEFAULT_schema=40
QR_W_DEFAULT_new_tests=10
QR_W_DEFAULT_size=15
QR_W_DEFAULT_size_files=10
QR_W_DEFAULT_ejected_before=25
QR_W_DEFAULT_prequeue_red=20
QR_GLOBS_DEFAULT_shared_lib='bin/lib/*'
QR_GLOBS_DEFAULT_ci_config='.github/* .mergify.yml config/mergify/* bin/test-impact* bin/ci-plan.sh'
QR_GLOBS_DEFAULT_registry='catalog/* cron/* worker/jobs/src/index.js'
# The committed members of the `## Generated files` table
# (docs/verification-map/index/tail.md). catalog/lanes.json and cron/*.cron are
# generated and git-ignored, so they never appear in a PR diff.
QR_GLOBS_DEFAULT_generated='rules/CLAUDE.md env-templates/*'
QR_GLOBS_DEFAULT_share_mirror='bin/share/*'
QR_GLOBS_DEFAULT_schema='worker/jobs/schema.sql worker/*/schema.d/* *migrations/* worker/jobs/src/lib/core.js'
QR_THRESHOLD_DEFAULT=50
QR_SIZE_LINES_DEFAULT=400
QR_SIZE_LINES_BIG_DEFAULT=1000
QR_SIZE_FILES_DEFAULT=15
# Not rows: the shape of a test file, and the culprit-verdict cap.
QR_NEW_TEST_GLOBS='tests/*-test.sh tests/mc/*-test.sh worker/jobs/test/*.test.js console-ui/tests/*.test.js'
QR_EJECT_CAP=2

_qr_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_qr_log() { command -v mc_log >/dev/null 2>&1 && mc_log "$*"; return 0; }

# _qr_match <path> <glob> — `**` reads as `*`, and a bash `*` crosses `/`
# (risk-tier.sh's _rt_match).
_qr_match() {
  local p="$1" g="${2//\*\*/*}"
  # shellcheck disable=SC2053
  [[ $p == $g ]]
}

# _qr_first <files-file> <globs> — the first path matching any glob.
_qr_first() {
  local p g gs=()
  # read -a, never an unquoted expansion: `docs/*` would glob against the cwd.
  read -r -a gs <<<"$(printf '%s' "$2" | tr '\n\t' '  ')"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for g in "${gs[@]}"; do _qr_match "$p" "$g" && { printf '%s' "$p"; return 0; }; done
  done < "$1"
  return 1
}

# _qr_setting <key> <fallback> <int|globs> — prints the row, or the fallback on
# rc 2. rc 1 or a non-integer int prints the fallback and sets
# QR_RULES_UNREADABLE=1. Run in THIS shell (output to a file), never in $( ).
_qr_setting() {
  local v rc=0
  if ! command -v setting_get >/dev/null 2>&1; then printf '%s' "$2"; return 0; fi
  v=$(setting_get "$1" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    2) printf '%s' "$2"; return 0 ;;
    *) QR_RULES_UNREADABLE=1; printf '%s' "$2"; return 0 ;;
  esac
  v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ "$3" = int ]; then
    case "$v" in ''|*[!0-9]*) QR_RULES_UNREADABLE=1; printf '%s' "$2"; return 0 ;; esac
    v=$((10#$v))
  fi
  printf '%s' "$v"
}

# THE ROWS ARE READ ONCE PER CONDUCTOR TICK (lead review of a74f4446). 21 rows
# and the mode are 22 serial worker GETs, each up to JOBS_TIMEOUT on a hung
# worker, so reading them per enqueue cost minutes. With MC_TICK_ID set, the
# first load of a tick writes the values to <MC_TICK_DIR>/<tick>.queue-risk
# (tmp + mv) and every later load in that tick, in any process of it (qr_score
# runs inside $( )), sources the file. A new tick reads the rows again, so a row
# edit routes on the next tick. Without MC_TICK_ID every call reads the rows.
_qr_tick_file() {
  [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ] || return 1
  printf '%s/%s.%s' "$MC_TICK_DIR" "$(printf '%s' "$MC_TICK_ID" | tr -c 'A-Za-z0-9._-' '_')" "$1"
}

qr_rules_load() {
  local f s d cache v
  if cache=$(_qr_tick_file queue-risk-rules) && [ -r "$cache" ] && . "$cache" 2>/dev/null; then return 0; fi
  QR_RULES_UNREADABLE=""
  f=$(mktemp "${TMPDIR:-/tmp}/queue-risk.XXXXXX") || { QR_RULES_UNREADABLE=1; f=""; }
  # _rd <var> <key> <fallback> <kind>
  _rd() {
    if [ -n "$f" ]; then _qr_setting "$2" "$3" "$4" > "$f"; printf -v "$1" '%s' "$(cat "$f")"
    else printf -v "$1" '%s' "$3"; fi
  }
  for s in $QR_SIGNALS; do
    d="QR_W_DEFAULT_$s"; _rd "QR_W_$s" "queue_risk.weight.$s" "${!d}" int
  done
  for s in $QR_PATH_SIGNALS; do
    d="QR_GLOBS_DEFAULT_$s"; _rd "QR_GLOBS_$s" "queue_risk.globs.$s" "${!d}" globs
  done
  _rd QR_THRESHOLD queue_risk.threshold "$QR_THRESHOLD_DEFAULT" int
  _rd QR_SIZE_LINES queue_risk.size_lines "$QR_SIZE_LINES_DEFAULT" int
  _rd QR_SIZE_LINES_BIG queue_risk.size_lines_big "$QR_SIZE_LINES_BIG_DEFAULT" int
  _rd QR_SIZE_FILES queue_risk.size_files "$QR_SIZE_FILES_DEFAULT" int
  unset -f _rd
  [ -n "$f" ] && rm -f "$f"
  if [ -n "$cache" ] && mkdir -p "${cache%/*}" 2>/dev/null; then
    { for v in QR_RULES_UNREADABLE QR_THRESHOLD QR_SIZE_LINES QR_SIZE_LINES_BIG QR_SIZE_FILES; do
        printf '%s=%q\n' "$v" "${!v}"
      done
      for s in $QR_SIGNALS; do v="QR_W_$s"; printf '%s=%q\n' "$v" "${!v}"; done
      for s in $QR_PATH_SIGNALS; do v="QR_GLOBS_$s"; printf '%s=%q\n' "$v" "${!v}"; done
    } > "$cache.tmp.$$" 2>/dev/null && mv -f "$cache.tmp.$$" "$cache" 2>/dev/null || rm -f "$cache.tmp.$$" 2>/dev/null
  fi
  return 0
}

# qr_mode — queue_risk.mode. No settings reader, no row or an outage is shadow
# (log and record, write no label); an unknown value is off, with one log line.
# Read once per tick too (the tick file is <tick>.queue-risk-mode).
qr_mode() {
  local v rc=0 cache m
  if cache=$(_qr_tick_file queue-risk-mode) && [ -r "$cache" ]; then
    m=$(cat "$cache" 2>/dev/null)
    case "$m" in off|shadow|enforce) printf '%s' "$m"; return 0 ;; esac
  fi
  command -v setting_get >/dev/null 2>&1 || { printf shadow; return 0; }
  v=$(setting_get queue_risk.mode 2>/dev/null) || rc=$?
  if [ "$rc" = 0 ]; then
    v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$v" in
      off|shadow|enforce) m="$v" ;;
      *) _qr_log "queue_risk.mode '$(printf '%s' "$v" | tr -d '\n' | head -c 40)' is not off|shadow|enforce — risk routing is off"; m=off ;;
    esac
  else
    m=shadow
  fi
  if [ -n "$cache" ] && mkdir -p "${cache%/*}" 2>/dev/null; then
    printf '%s\n' "$m" > "$cache.tmp.$$" 2>/dev/null && mv -f "$cache.tmp.$$" "$cache" 2>/dev/null || rm -f "$cache.tmp.$$" 2>/dev/null
  fi
  printf '%s' "$m"
}

# qr_score <files-file> <lines> <nfiles> <slug> <num> — always rc 0. Reads the
# rows itself (qr_rules_load). <lines>/<nfiles> that are not integers count 0.
qr_score() {
  local files="${1:-}" lines="${2:-}" nf="${3:-}" slug="${4:-}" num="${5:-}"
  local score=0 reasons="" s w g hit root route n cap
  qr_rules_load
  if [ -z "$files" ] || [ ! -r "$files" ] || ! grep -q . "$files" 2>/dev/null; then
    printf -- '-\t%s\tbatch\tfiles-unavailable\n' "$QR_THRESHOLD"; return 0
  fi
  case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
  case "$nf" in ''|*[!0-9]*) nf=0 ;; esac
  _add() { score=$((score + $2)); reasons="${reasons:+$reasons,}$1:+$2($3)"; }
  for s in $QR_PATH_SIGNALS; do
    w="QR_W_$s"; g="QR_GLOBS_$s"
    [ "${!w}" -gt 0 ] || continue
    hit=$(_qr_first "$files" "${!g}") && _add "$s" "${!w}" "$hit"
  done
  root=$(_qr_root)
  if [ "$QR_W_new_tests" -gt 0 ] && [ -n "$root" ]; then
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      _qr_first <(printf '%s\n' "$s") "$QR_NEW_TEST_GLOBS" >/dev/null || continue
      [ -e "$root/$s" ] && continue
      _add new_tests "$QR_W_new_tests" "$s"; break
    done < "$files"
  fi
  if [ "$QR_W_size" -gt 0 ] && [ "$lines" -ge "$QR_SIZE_LINES" ]; then
    w=$QR_W_size; [ "$lines" -ge "$QR_SIZE_LINES_BIG" ] && w=$((w * 2))
    _add size "$w" "$lines lines"
  fi
  [ "$QR_W_size_files" -gt 0 ] && [ "$nf" -ge "$QR_SIZE_FILES" ] && _add size_files "$QR_W_size_files" "$nf files"
  # The conductor's attempt ledger (bin/lib/mc/locks.sh), keyed `<slug>#<n>`.
  if command -v mc_attempt_count >/dev/null 2>&1 && [ -n "$slug" ] && [ -n "$num" ]; then
    n=$(mc_attempt_count bejculprit "$slug#$num" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    cap=$n; [ "$cap" -gt "$QR_EJECT_CAP" ] && cap=$QR_EJECT_CAP
    [ "$cap" -gt 0 ] && [ "$QR_W_ejected_before" -gt 0 ] \
      && _add ejected_before "$((QR_W_ejected_before * cap))" "$n culprit verdict$([ "$n" = 1 ] || echo s)"
    n=$(mc_attempt_count pqred "$slug#$num" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -gt 0 ] && [ "$QR_W_prequeue_red" -gt 0 ] && _add prequeue_red "$QR_W_prequeue_red" "parked prequeue-red before"
  else
    reasons="${reasons:+$reasons,}history-unread"
  fi
  unset -f _add
  [ -n "$QR_RULES_UNREADABLE" ] && reasons="${reasons:+$reasons,}rows-unreadable"
  route=batch; [ "$score" -ge "$QR_THRESHOLD" ] && route=solo
  printf '%s\t%s\t%s\t%s\n' "$score" "$QR_THRESHOLD" "$route" "$reasons"
}

# _qr_record <slug> <num> <head> <score> <threshold> <route> <mode> <reasons>
# — POST /api/queue-risk (an upsert per repo+pr+head). A failure is one log line.
_qr_record() {
  local body sc="$4"
  command -v _jobs_req >/dev/null 2>&1 || { _qr_log "QRISK $1#$2: no jobs client, score not recorded"; return 0; }
  case "$sc" in ''|*[!0-9]*) sc=null ;; esac
  body=$(jq -nc --arg r "$1" --argjson p "$2" --arg h "$3" --arg pj "${1#*/}" --argjson s "$sc" \
    --argjson t "$5" --arg ro "$6" --arg m "$7" --arg why "${8:0:1000}" \
    '{repo:$r, pr:$p, head_sha:$h, project:$pj, score:$s, threshold:$t, route:$ro, mode:$m, reasons:$why}' 2>/dev/null) \
    || { _qr_log "QRISK $1#$2: record body could not be built"; return 0; }
  _jobs_req POST /api/queue-risk "$body" >/dev/null 2>&1 \
    || _qr_log "QRISK $1#$2@${3:0:12}: the score could not be recorded (POST /api/queue-risk failed${JOBS_HTTP:+, HTTP $JOBS_HTTP})"
  return 0
}

# qr_enqueue_step <slug> <num> <head> — mc_enqueue_mergify's block, BEFORE the
# merge-queue label. rc 0 always: it never holds a PR. Runs only for a repo
# whose config/mergify/repos/<repo>.conf names this slug AND carries a
# solo_label= line (the label the rendered solo queue keys on), so an
# opted-out repo costs no read at all.
#   enforce + solo   POST the solo label (before merge-queue, so the PR is
#                    never briefly in default without it)
#   batch, not off   DELETE a solo label the PR still carries from an older
#                    head (enforce only: shadow writes no label at all)
#   shadow           log + record, with `would route <r>`
qr_enqueue_step() {
  local slug="$1" num="$2" head="$3" root conf label mode pj="" files lines nf labels title ref out
  local score thr route reasons note="" enc err
  root=$(_qr_root); [ -n "$root" ] || return 0
  conf="$root/config/mergify/repos/${slug#*/}.conf"
  [ -r "$conf" ] && grep -qx "slug=$slug" "$conf" 2>/dev/null || return 0
  label=$(sed -n 's/^solo_label=\([a-z0-9][a-z0-9-]*\)[[:space:]]*$/\1/p' "$conf" | tail -1)
  [ -n "$label" ] || return 0
  QR_SOLO_LABEL="$label"
  mode=$(qr_mode)
  [ "$mode" = off ] && return 0
  files=$(mktemp "${TMPDIR:-/tmp}/qr-files.XXXXXX") || files=""
  lines=""; nf=""; labels=""; title=""; ref=""
  if command -v gh_rest_var >/dev/null 2>&1 && gh_rest_var pj GET "repos/$slug/pulls/$num" 2>/dev/null && [ -n "$pj" ] \
     && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$pj"; then
    lines=$(jq -r '((.additions // 0) + (.deletions // 0))' <<<"$pj" 2>/dev/null)
    nf=$(jq -r '.changed_files // 0' <<<"$pj" 2>/dev/null)
    labels=$(jq -r '[.labels[]?.name] | join(",")' <<<"$pj" 2>/dev/null)
    title=$(jq -r '.title // ""' <<<"$pj" 2>/dev/null)
    ref=$(jq -r '.head.ref // ""' <<<"$pj" 2>/dev/null)
    [ -n "$files" ] && command -v mc_pr_files >/dev/null 2>&1 && mc_pr_files "$slug" "$num" "" "$head" > "$files" 2>/dev/null
  else
    pj=""
  fi
  command -v train_is_train >/dev/null 2>&1 \
    || { [ -r "${BASH_SOURCE[0]%/*}/train-shape.sh" ] && . "${BASH_SOURCE[0]%/*}/train-shape.sh"; }
  if [ -n "$pj" ] && [[ ",$labels," == *,fix-main-red,* ]]; then
    qr_rules_load; out=$(printf -- '-\t%s\tbatch\tfix-main-red' "$QR_THRESHOLD")
  elif [ -n "$pj" ] && command -v train_is_train >/dev/null 2>&1 && train_is_train "$title" "$ref"; then
    qr_rules_load; out=$(printf -- '-\t%s\tbatch\ttrain' "$QR_THRESHOLD")
  elif [ -n "$pj" ]; then
    out=$(qr_score "$files" "$lines" "$nf" "$slug" "$num")
  else
    out=$(qr_score "" 0 0 "$slug" "$num")
  fi
  [ -n "$files" ] && rm -f "$files"
  IFS=$'\t' read -r score thr route reasons <<<"$out"
  [ "$mode" = shadow ] && note=" (would route $route)"
  _qr_log "QRISK $slug#$num@${head:0:12} score=$score threshold=$thr route=$route mode=$mode$note reasons=${reasons:--}"
  _qr_record "$slug" "$num" "$head" "$score" "$thr" "$route" "$mode" "$reasons"
  [ "$mode" = enforce ] || return 0
  # A skipped PR (fix-main-red, train) gets no label write. A PR whose object
  # read but whose file list did not routes batch, and a queue-solo it still
  # carries from an older head is removed (lead review of a74f4446): unknown
  # risk is today's routing, never solo. An unreadable PR ($pj empty) has no
  # label list to act on.
  case "$reasons" in fix-main-red|train) return 0 ;; esac
  case "$reasons" in files-unavailable) [ -n "$pj" ] || return 0 ;; esac
  if [ "$route" = solo ]; then
    [[ ",$labels," == *",$label,"* ]] && return 0
    err=$(gh api -X POST "repos/$slug/issues/$num/labels" -f "labels[]=$label" 2>&1 >/dev/null) \
      || _qr_log "QRISK $slug#$num: label $label could not be added ($(head -1 <<<"$err")) — it queues in default"
  elif [[ ",$labels," == *",$label,"* ]]; then
    enc=$(jq -rn --arg l "$label" '$l | @uri')
    err=$(gh api -X DELETE "repos/$slug/issues/$num/labels/$enc" 2>&1 >/dev/null) \
      || _qr_log "QRISK $slug#$num: stale label $label could not be removed ($(head -1 <<<"$err"))"
  fi
  return 0
}
