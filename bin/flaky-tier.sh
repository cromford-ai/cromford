#!/bin/bash
# bin/flaky-tier.sh [project|owner/repo] [--dry-run] — daily auto-quarantine of
# this repo's own flaky suites (BH-3686, slice BH-3701).
#
# Reads the flake ledger bin/flaky-detect.sh writes. A suite that flaked on
# FLAKY_TIER_MIN distinct heads in FLAKY_TIER_WINDOW_DAYS gets exactly one
# `ai-build` fix ticket FIRST, then an active quarantine row. The active rows
# are then projected into the repo Actions variable CI_QUARANTINE, which CI
# reads. One tick:
#   1 rows      metric_flake_quarantine_rows. Unreadable = one warn alert and
#               STOP: nothing is quarantined, released or projected.
#   2 evidence  metric_flakes_list 2000 over the window: kind=flake rows for
#               tests/*.sh suites that still exist, distinct heads per suite.
#               A suite with an INACTIVE row only counts heads from the day
#               after that row's updated_at (a release or a /ci toggle starts
#               the count over). Unreadable = skip 3-4 only.
#   3 guards    more than FLAKY_TIER_MAX_NEW candidates = none quarantined and
#               one critical flaky-tier-mass:<slug> page. A protected candidate
#               (bin/lib/test-protected.sh) = a critical flaky-protected:<suite>
#               page and nothing else; it resolves when the count drops below N.
#   4 quarantine  the open ticket carrying the suite's marker, or a new one,
#               THEN the row. No quarantine without its ticket. An issue search
#               that is not a clean read (rc 44/75, or the 1000-row cap) skips.
#   4b suite quarantine (BH-9697, bin/lib/suite-quarantine-hub.sh): the active
#               suite_quarantine rows bin/selection-gate.sh wrote (a suite red
#               on a PR merged with main AND on main). ONE `ai-build` repair
#               ticket per row with none (an open issue with the row's marker
#               is reused), at most SUITE_QUARANTINE_MAX_NEW new per tick, then
#               the row link. Unreadable rows: no ticket, no release, and step 6
#               projects the flaky rows only.
#   5 release   ft_release (bin/lib/flaky-tier-release.sh) decides.
#   5b          a suite_quarantine row whose suite passed in the newest cached
#               nightly run newer than the row, on another sha than the red
#               main sha, is released. SUITE_QUARANTINE_ACT=0 skips 4b and 5b.
#   6 projection  active rows, minus missing and protected suites, plus the
#               active suite_quarantine rows (same filters), sorted and
#               space-joined (`-` when empty) into CI_QUARANTINE, with the admin
#               token on those calls only. 404 = POST, differs = PATCH.
#   7 one tick line in logs/flaky-tier.log.
#
#   bin/flaky-tier.sh cromford --dry-run    # every decision, no writes
#
# --dry-run or FLAKY_TIER_ACT=0: prints `would: …` and writes nothing (no
# ticket, row, variable, alert or state file). Knobs: catalog/lanes.d/flaky-tier.json.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

case "${1:-}" in -h|--help) sed -n '2,44p' "$0"; exit 0 ;; esac
# >>> lane gate (BH-1165): flags/lane-off-flaky-tier or all-off exits 0; the
# settings rows land in the env the knob reads below use. Both fail OPEN.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit flaky-tier
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    flaky-tier
export HARNESS="$H"
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# Again below the env load: global.env re-assigns the names it carries (BH-1165).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    flaky-tier
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
# The four below are REQUIRED: without tp_protected every suite would read as
# unprotected, and without gh_ci_api ft_release releases nothing on every tick
# (BH-4321), so a missing one stops the lane rather than degrading it.
for _l in gh-rest-list.sh test-protected.sh gh-ci-read.sh flaky-tier-release.sh; do
  # shellcheck source=/dev/null
  . "$H/bin/lib/$_l" || { echo "flaky-tier: cannot load bin/lib/$_l" >&2; exit 1; }
done
# BH-9697: optional. Without it the suite quarantine is skipped with one line
# and CI_QUARANTINE carries the flaky rows only (more suites run, never fewer).
# shellcheck source=bin/lib/suite-quarantine-hub.sh
. "$H/bin/lib/suite-quarantine-hub.sh" 2>/dev/null || true
command -v tp_protected >/dev/null 2>&1 && command -v gh_rest_var >/dev/null 2>&1 && command -v gh_ci_api >/dev/null 2>&1 \
  || { echo "flaky-tier: tp_protected, gh_rest_var or gh_ci_api missing" >&2; exit 1; }

TARGET=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in --dry-run|-n) DRY=1 ;; *) [ -n "$TARGET" ] || TARGET="$1" ;; esac
  shift
done
# This lane serves one repo; a project name is only a label.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1  # BH-4080: HARNESS_REPO
case "$TARGET" in */*) SLUG="$TARGET" ;; *) SLUG="${FLAKY_TIER_REPO:-$HARNESS_REPO}" ;; esac

mkdir -p "$H/locks" "$H/logs" 2>/dev/null
exec 9>"$H/locks/flaky-tier.lock"
flock -n 9 || exit 0

NOW="${FLAKY_TIER_NOW:-$(date -u +%s)}"   # the ONLY clock read
LOG="$H/logs/flaky-tier.log"
exec 3>&1
say() { printf '  %s\n' "$*" >> "$LOG"; printf '  %s\n' "$*" >&3; }

# _ft_int NAME DEFAULT — a positive integer, else the default, said out loud.
_ft_int() {
  local v="${!1:-}"
  case "$v" in
    '') v="$2" ;;
    [1-9]|[1-9]*[0-9]) case "$v" in *[!0-9]*) say "$1='$v' is not a positive integer; using $2"; v="$2" ;; esac ;;
    *) say "$1='$v' is not a positive integer; using $2"; v="$2" ;;
  esac
  printf -v "$1" '%s' "$v"; export "${1?}"
}
_ft_int FLAKY_TIER_MIN 3; _ft_int FLAKY_TIER_WINDOW_DAYS 7; _ft_int FLAKY_TIER_MAX_NEW 3
_ft_int FLAKY_TIER_RELEASE_CLEAN 5; _ft_int FLAKY_TIER_NIGHTLY_RUNS 10
_ft_int SUITE_QUARANTINE_MAX_NEW 3   # catalog/lanes.d/flaky-tier.knobs.d/SUITE_QUARANTINE_MAX_NEW.json
export FLAKY_TIER_RELEASE_ACTORS="${FLAKY_TIER_RELEASE_ACTORS:-flaky-tier main-red-bisect}"   # for ft_release
MIN=$FLAKY_TIER_MIN; W=$FLAKY_TIER_WINDOW_DAYS
[ "${FLAKY_TIER_ACT:-1}" = 0 ] && DRY=1
[ "$DRY" = 1 ] && export FLAKY_TIER_DRY=1

# _ft_do <what> <cmd…> — the one gate every write goes through.
_ft_do() {
  local what="$1"; shift
  if [ "$DRY" = 1 ]; then say "would: $what"; return 0; fi
  "$@"
}
# _ft_alert <lane-alert opts…> <text>
_ft_alert() { _ft_do "alert ${*:1:$#-1}: ${!#}" "$H/bin/lane-alert.sh" "${@:1:$#-1}" flaky-tier "${!#}"; }

CAND=0; QUAR=0; PROT=0; REL=0; PROJ=skipped; TICKED=0
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/flaky-tier.XXXXXX") || exit 1
_ft_tick() {
  [ "$TICKED" = 1 ] && return; TICKED=1
  printf '%s flaky-tier %s: candidates=%s quarantined=%s protected=%s released=%s projection=%s%s\n' \
    "$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ')" "$SLUG" "$CAND" "$QUAR" "$PROT" "$REL" "$PROJ" \
    "$([ "$DRY" = 1 ] && echo ' [dry-run]')" | tee -a "$LOG"
  rm -rf "$TMPD"
}
trap _ft_tick EXIT
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true

# ── 1. rows ──────────────────────────────────────────────────────────────────
ROWS="$TMPD/rows"
if ! metric_flake_quarantine_rows "$SLUG" > "$ROWS" 2>/dev/null; then
  say "quarantine rows unreadable for $SLUG; stopping (no quarantine, release or projection)"
  _ft_alert --id flaky-tier-rows-unreadable --severity warn \
    "flaky-tier $SLUG: quarantine rows unreadable (worker down or route missing); nothing quarantined, released or projected this tick"
  exit 0
fi
_ft_alert --resolve --id flaky-tier-rows-unreadable "flaky-tier $SLUG: quarantine rows readable again"

# ── 2. evidence ──────────────────────────────────────────────────────────────
SINCE=$(date -u -d "@$((NOW - W*86400))" +%F)
EV="$TMPD/ev"; HEADS="$TMPD/heads"; COUNTS="$TMPD/counts"; EVIDENCE=ok
if metric_flakes_list 2000 "$SLUG" "$SINCE" > "$EV" 2>/dev/null; then
  [ "$(wc -l < "$EV")" -ge 2000 ] && say "evidence capped at 2000 rows; counts are a lower bound"
else
  EVIDENCE=unread; say "flake evidence unreadable; no quarantine this tick (release and projection still run)"
fi
# Distinct (suite, head) pairs that count: flake kind, a tests/*.sh name, and
# for a suite with an INACTIVE row, a day AFTER that row's day. An updated_at
# that is not a date drops that suite's evidence (errs toward not quarantining).
awk -F'\t' 'FILENAME == ARGV[1] {
    if ($2 == "0") { d = substr($4, 1, 10); cut[$1] = (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) ? d : "X" }
    next }
  $6 == "flake" && $4 ~ /^tests\/[^\/ ]+\.sh$/ {
    if ($4 in cut && (cut[$4] == "X" || !($1 > cut[$4]))) next
    if (!(($4, $5) in seen)) { seen[$4, $5] = 1; print $4 "\t" $5 "\t" $1 } }' "$ROWS" "$EV" > "$HEADS"
: > "$COUNTS"
while IFS=$'\t' read -r n s; do
  [ -f "$H/$s" ] && printf '%s\t%s\n' "$s" "$n" >> "$COUNTS"
done < <(cut -f1 "$HEADS" | LC_ALL=C sort | uniq -c | awk '{print $1 "\t" $2}')
count_of() { awk -F'\t' -v s="$1" '$1 == s { print $2; f = 1 } END { if (!f) print 0 }' "$COUNTS"; }
ACTIVE=$(awk -F'\t' '$2 == "1" { print $1 }' "$ROWS")
CANDS=()
while IFS=$'\t' read -r s n; do
  [ "$n" -ge "$MIN" ] || continue
  grep -Fqx -- "$s" <<< "$ACTIVE" && continue
  CANDS+=("$s")
done < "$COUNTS"
CAND=${#CANDS[@]}

# ── 3. mass cap, protected suites ────────────────────────────────────────────
PSTATE="$H/state/flaky-tier/protected-open.${SLUG//\//_}"
TODO=()
if [ "$EVIDENCE" = ok ]; then
  if [ "$CAND" -gt "$FLAKY_TIER_MAX_NEW" ]; then
    say "$CAND candidates > FLAKY_TIER_MAX_NEW=$FLAKY_TIER_MAX_NEW; quarantining none"
    _ft_alert --id "flaky-tier-mass:$SLUG" --severity critical \
      "flaky-tier $SLUG: $CAND suites crossed the flake threshold at once (${CANDS[*]}); that looks like a runner or infra problem, so none was quarantined"
  else
    _ft_alert --resolve --id "flaky-tier-mass:$SLUG" "flaky-tier $SLUG: candidates back under the cap"
    for s in ${CANDS[@]+"${CANDS[@]}"}; do
      if why=$(tp_protected "$s" "$H"); then
        PROT=$((PROT+1)); say "protected: $s ($why), $(count_of "$s") flaky heads; paging, not quarantining"
        _ft_alert --id "flaky-protected:$s" --severity critical \
          "flaky-tier $SLUG: protected suite $s flaked on $(count_of "$s") heads in $W days ($why). It is never auto-quarantined; fix it by hand"
        if [ "$DRY" != 1 ] && ! grep -Fqx -- "$s" "$PSTATE" 2>/dev/null; then
          mkdir -p "${PSTATE%/*}" && printf '%s\n' "$s" >> "$PSTATE"
        fi
      else
        TODO+=("$s")
      fi
    done
  fi
  if [ -s "$PSTATE" ]; then
    : > "$TMPD/keep"
    while read -r s; do
      if [ "$(count_of "$s")" -lt "$MIN" ]; then
        _ft_alert --resolve --id "flaky-protected:$s" "flaky-tier $SLUG: $s is below $MIN flaky heads again"
        [ "$DRY" = 1 ] && printf '%s\n' "$s" >> "$TMPD/keep"
      else printf '%s\n' "$s" >> "$TMPD/keep"; fi
    done < "$PSTATE"
    [ "$DRY" = 1 ] || cp "$TMPD/keep" "$PSTATE"
  fi
fi

# ── 4. the ticket first, then the row ────────────────────────────────────────
if [ "${#TODO[@]}" -gt 0 ]; then
  ISS="$TMPD/issues"; rc=0
  gh_rest_issue_list "$SLUG" open "" 1000 > "$ISS" || rc=$?
  [ "$rc" = 0 ] && [ "$(jq length "$ISS" 2>/dev/null)" = 1000 ] && { rc=75; GH_REST_STATUS="cap"; }
  for s in "${TODO[@]}"; do
    if [ "$rc" != 0 ]; then say "skip $s: issue search unknown (HTTP $GH_REST_STATUS)"; continue; fi
    n=$(count_of "$s"); mark="<!-- harness-flaky-quarantine: $s -->"
    first=$(awk -F'\t' -v s="$s" '$1 == s && (m == "" || $3 < m) { m = $3 } END { print m }' "$HEADS")
    T=$(jq -r --arg m "$mark" '[.[] | select((.body // "") | contains($m)) | .number][0] // empty' "$ISS")
    if [ -n "$T" ]; then
      say "$s: reusing open ticket #$T"
    else
      B="$TMPD/body"; OUT="$TMPD/created"
      {
        printf '%s\n\n' "$mark"
        printf 'We quarantined `%s`. It flaked on %s heads in %s days (threshold %s): same sha, red and green.\n\n' "$s" "$n" "$W" "$MIN"
        awk -F'\t' -v s="$s" '$1 == s { printf "- %s on %s\n", substr($2, 1, 12), $3 }' "$HEADS"
        printf '\nWhat that means: CI stops failing on this suite. The nightly tier still runs it, so we keep seeing how it behaves.\n\n'
        printf 'How it ends: %s clean nightly runs in a row lift it. The automatic release is still being built, so until it lands we lift it by hand once the flake is fixed.\n\n' "$FLAKY_TIER_RELEASE_CLEAN"
        printf 'To override it, use the toggle on the `/ci` screen. The rules are in `docs/FLAKY-TESTS.md`.\n'
      } > "$B"
      if [ "$DRY" = 1 ]; then say "would: issue 'Flaky suite quarantined: $s' (ai-build)"; T=new
      else
        rc2=0; gh_rest POST "repos/$SLUG/issues" -f "title=Flaky suite quarantined: $s" -F "body=@$B" -f 'labels[]=ai-build' > "$OUT" || rc2=$?
        T=$(jq -r '.number // empty' "$OUT" 2>/dev/null)
        case "$rc2:$T" in 0:[0-9]*) ;; *) say "skip $s: ticket create failed (HTTP $GH_REST_STATUS); no row without a ticket"; continue ;; esac
        if ! jq -e '[.labels[]?.name] | index("ai-build")' "$OUT" >/dev/null 2>&1; then
          gh_rest POST "repos/$SLUG/issues/$T/labels" -f 'labels[]=ai-build' > /dev/null \
            || { say "skip $s: #$T has no ai-build label (HTTP $GH_REST_STATUS); row next tick"; continue; }
        fi
        say "$s: filed #$T"
      fi
    fi
    if _ft_do "put $s active=1 (fix #$T)" metric_flake_quarantine_put "$SLUG" "$s" 1 \
         "auto (flaky-tier): $n flaky heads since $first; fix #$T" flaky-tier; then
      QUAR=$((QUAR+1)); say "quarantined $s ($n heads, fix #$T)"
    else say "row write failed for $s; #$T stays open and is reused next tick"; fi
  done
fi

# ── 4b. suite quarantine: one repair ticket per row (BH-9697) ────────────────
SQROWS="$TMPD/sq-rows"; SQREL="$TMPD/sq-released"; : > "$SQREL"; SQR=unread
SQACT=1; [ "${SUITE_QUARANTINE_ACT:-1}" = 0 ] && SQACT=0   # catalog/lanes.d/flaky-tier.knobs.d/SUITE_QUARANTINE_ACT.json
if ! command -v sqh_read >/dev/null 2>&1; then
  say "suite-quarantine: bin/lib/suite-quarantine-hub.sh missing; skipped, CI_QUARANTINE carries the flaky rows only"
elif sqh_read "$SLUG" "$SQROWS"; then
  SQR=ok
  [ "$SQACT" = 1 ] && sqh_file "$SLUG" "$SQROWS" "$SUITE_QUARANTINE_MAX_NEW"
else
  say "suite-quarantine: rows unreadable for $SLUG; no repair ticket or release this tick, and CI_QUARANTINE carries the flaky rows only"
fi

# ── 5. release (delegated) ───────────────────────────────────────────────────
# ft_release says why it released nothing on stderr only, and cron drops the
# lane's stderr, so each of its lines goes into the lane log (BH-4321).
ft_release "$SLUG" "$ROWS" > "$TMPD/released" 2> "$TMPD/release.err" || say "ft_release failed"
while IFS= read -r l; do [ -n "$l" ] && say "$l"; done < "$TMPD/release.err"
while read -r s; do [ -n "$s" ] && { REL=$((REL+1)); say "released $s"; }; done < "$TMPD/released"
# ── 5b. suite quarantine release on a green nightly (BH-9697) ────────────────
[ "$SQR" = ok ] && [ "$SQACT" = 1 ] && sqh_release "$SLUG" "$SQROWS" "$SQREL"

# ── 6. projection into CI_QUARANTINE ─────────────────────────────────────────
PROJ=failed; why=""
if ! metric_flake_quarantine_rows "$SLUG" > "$TMPD/rows2" 2>/dev/null; then why="rows re-read failed"
else
  : > "$TMPD/want"
  while IFS=$'\t' read -r s a _; do
    [ "$a" = 1 ] || continue
    [ -f "$H/$s" ] || { say "row names a missing suite: $s"; continue; }
    tp_protected "$s" "$H" >/dev/null && continue
    printf '%s\n' "$s" >> "$TMPD/want"
  done < "$TMPD/rows2"
  # BH-9697: the union with the active suite_quarantine rows, so the batch
  # (bin/ci-plan.sh --quarantine) drops them too.
  [ "$SQR" = ok ] && sqh_project "$SQROWS" "$SQREL" "$TMPD/want"
  WANT=$(LC_ALL=C sort -u "$TMPD/want" | paste -sd' ' -); [ -n "$WANT" ] || WANT=-
  ADM="${GH_ADMIN_TOKEN:-}"
  [ -n "$ADM" ] || ADM=$(sed -n 's/^\(export \)\{0,1\}GH_ADMIN_TOKEN=//p' "$HENV/github-admin.env" 2>/dev/null | tr -d "\"'" | head -n 1)
  if [ -z "$ADM" ]; then why="no admin token"
  else
    V="repos/$SLUG/actions/variables"; rc=0
    GH_ETAG=0 GH_TOKEN="$ADM" gh_rest_var CUR GET "$V/CI_QUARANTINE" || rc=$?
    if [ "$rc" = 0 ] && [ "$(printf '%s' "$CUR" | jq -r '.value // empty' 2>/dev/null)" = "$WANT" ]; then PROJ=same
    elif [ "$rc" = 0 ] || [ "$rc" = 44 ]; then
      if [ "$rc" = 44 ]; then m=POST; p="$V"; a=(-f name=CI_QUARANTINE); else m=PATCH; p="$V/CI_QUARANTINE"; a=(); fi
      if GH_ETAG=0 GH_TOKEN="$ADM" _ft_do "variable CI_QUARANTINE=$WANT ($m)" gh_rest "$m" "$p" ${a[@]+"${a[@]}"} -f "value=$WANT" > /dev/null
      then PROJ=updated; say "CI_QUARANTINE=$WANT"
      else why="variable $m HTTP $GH_REST_STATUS"; fi
    else why="variable read HTTP $GH_REST_STATUS"; fi
  fi
fi
if [ -n "$why" ]; then
  _ft_alert --id "flaky-tier-projection:$SLUG" --severity warn "flaky-tier $SLUG: CI_QUARANTINE not projected ($why); CI keeps the old value, retry next tick"
else
  _ft_alert --resolve --id "flaky-tier-projection:$SLUG" "flaky-tier $SLUG: CI_QUARANTINE projected again"
fi
exit 0
