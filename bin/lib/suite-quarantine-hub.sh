# shellcheck shell=bash
# bin/lib/suite-quarantine-hub.sh — the hub half of the suite quarantine
# (BH-9697, Part D of BH-9582). Sourced by bin/flaky-tier.sh, never run.
#
# bin/selection-gate.sh writes an active suite_quarantine row for a suite that
# is red on the PR merged with main AND red on main AND not changed by the diff.
# This lib does the rest, once a day, on the hub:
#   sqh_read <slug> <file>     the active rows, `suite TAB repair_issue|- TAB
#                              main_sha_red TAB created_at` a line
#                              (bin/jobs-client.sh suite-quarantine-list).
#                              rc 1 = unreadable: never read as "no rows".
#   sqh_file <slug> <file> <max>   ONE repair ticket per row with no
#                              repair_issue: an open issue that carries the
#                              row's marker is reused, else a new `ai-build`
#                              issue, at most <max> new per tick. The issue
#                              first, the row link second; a failed link leaves
#                              the row NULL and the next tick finds the issue by
#                              its marker (no duplicate). The create goes
#                              through tracker_create (bin/lib/tracker.sh,
#                              github-issues adapter), loaded lazily after the
#                              DRY gate (BH-9730).
#   sqh_release <slug> <file> <released-out>   a row whose suite passed in the
#                              newest cached nightly run that is newer than the
#                              row and on another sha than main_sha_red is
#                              released (bin/jobs-client.sh
#                              suite-quarantine-release). Its suite is appended
#                              to <released-out>.
#   sqh_project <file> <released-file> <want-file>   appends the suites the
#                              projection into CI_QUARANTINE must carry: active,
#                              not released this tick, present, not protected.
# Reads from bin/flaky-tier.sh: say, _ft_do, DRY, TMPD. Every write goes
# through _ft_do, so --dry-run and FLAKY_TIER_ACT=0 write nothing. The root is
# ${HARNESS:-${H:-}} only (D43).

_sqh_root() { printf '%s' "${HARNESS:-${H:-}}"; }

sqh_read() {
  local root out
  root=$(_sqh_root); [ -n "$root" ] && [ -r "$root/bin/jobs-client.sh" ] || return 1
  out=$(bash "$root/bin/jobs-client.sh" suite-quarantine-list "$1" 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk -F'\t' 'NF >= 4 && $1 ~ /^tests\/[^ ]+\.sh$/' > "$2"
}

# _sqh_link <slug> <suite> <issue> — the row's repair_issue; rc 0 only when
# the worker set it (updated 1).
_sqh_link() {
  local root body out
  root=$(_sqh_root)
  body=$(jq -cn --arg r "$1" --arg s "$2" --argjson n "$3" '{repo: $r, suite: $s, repair_issue: $n}') || return 1
  out=$(bash "$root/bin/jobs-client.sh" suite-quarantine-issue "$body" 2>/dev/null) || return 1
  [ "$(jq -r '.updated // empty' <<<"$out" 2>/dev/null)" = 1 ]
}

# _sqh_tracker — load the tracker seam for the issue create (BH-9730): source
# $root/bin/lib/tracker.sh when tracker_create is not defined, then load the
# github-issues adapter. rc 1 when either step fails.
_sqh_tracker() {
  local root
  root=$(_sqh_root)
  if ! declare -F tracker_create >/dev/null 2>&1; then
    [ -n "$root" ] && [ -r "$root/bin/lib/tracker.sh" ] || return 1
    # shellcheck source=/dev/null
    . "$root/bin/lib/tracker.sh" || return 1
    declare -F tracker_create >/dev/null 2>&1 || return 1
  fi
  tracker_load github-issues || return 1
}

sqh_file() {
  local slug="$1" rows="$2" max="$3" iss rc s n red at mark t body out new=0
  local -a over=()
  awk -F'\t' '$2 == "-" { f = 1 } END { exit !f }' "$rows" || return 0
  iss="$TMPD/sq-issues"; rc=0
  gh_rest_issue_list "$slug" open "" 1000 > "$iss" || rc=$?
  [ "$rc" = 0 ] && [ "$(jq length "$iss" 2>/dev/null)" = 1000 ] && { rc=75; GH_REST_STATUS="cap"; }
  if [ "$rc" != 0 ]; then
    say "suite-quarantine: issue search unknown (HTTP ${GH_REST_STATUS:-?}); unlinked rows stay NULL until the next tick"
    return 0
  fi
  while IFS=$'\t' read -r s n red at; do
    [ "$n" = - ] || continue
    mark="<!-- harness-suite-quarantine: $s -->"
    t=$(jq -r --arg m "$mark" '[.[] | select((.body // "") | contains($m)) | .number][0] // empty' "$iss" 2>/dev/null)
    if [ -n "$t" ]; then
      if _ft_do "link suite-quarantine $s to #$t" _sqh_link "$slug" "$s" "$t"; then say "suite-quarantine: $s reuses open ticket #$t"
      else say "suite-quarantine: link of $s to #$t failed; the row stays NULL, retried next tick"; fi
      continue
    fi
    if [ "$new" -ge "$max" ]; then over+=("$s"); continue; fi
    new=$((new + 1))
    body="$TMPD/sq-body"; out="$TMPD/sq-created"
    {
      printf '%s\n\n' "$mark"
      printf 'We quarantined `%s`. The pre-queue selection gate found it red on a PR merged with main, red on main `%s` as well, and the PR does not touch it. So main itself breaks it, not the PR.\n\n' "$s" "${red:0:12}"
      printf 'What that means: the merge batch stops running it (CI_QUARANTINE), so it no longer blocks unrelated PRs. The nightly tier still runs it.\n\n'
      printf 'How it ends: fix the suite on main. The first scheduled nightly run on a newer main sha in which it passes lifts the quarantine by itself.\n\n'
      printf 'Quarantined at %s. The rules are in `docs/gates/prequeue-fresh-main.md`.\n' "$at"
    } > "$body"
    if [ "${DRY:-0}" = 1 ]; then say "would: suite-quarantine issue '[suite-quarantine] $s' (ai-build), then link the row"; continue; fi
    _sqh_tracker || { say "suite-quarantine: ticket create for $s failed (tracker seam bin/lib/tracker.sh not loadable); the row stays NULL, retried next tick"; continue; }
    jq -n --arg t "[suite-quarantine] $s" --rawfile b "$body" '{title: $t, body: $b, labels: ["ai-build"]}' > "$TMPD/sq-payload.json" 2>/dev/null \
      || { say "suite-quarantine: ticket create for $s failed (payload not written); the row stays NULL, retried next tick"; continue; }
    rm -f "$out"
    rc=0; TRK_SLUG="$slug" tracker_create "$TMPD/sq-payload.json" "$out" || rc=$?
    t=$(jq -r '.number // empty' "$out" 2>/dev/null)
    case "$rc:$t" in 0:[0-9]*) ;; *)
      say "suite-quarantine: ticket create for $s failed (HTTP ${GH_REST_STATUS:-?}); the row stays NULL, retried next tick"; continue ;; esac
    if _sqh_link "$slug" "$s" "$t"; then say "suite-quarantine: filed #$t for $s"
    else say "suite-quarantine: #$t is open for $s, but the row link failed; the next tick links it by its marker"; fi
  done < "$rows"
  [ "${#over[@]}" -gt 0 ] && say "suite-quarantine: ${#over[@]} row(s) over SUITE_QUARANTINE_MAX_NEW=$max wait for the next tick: ${over[*]}"
  return 0
}

# _sqh_fetch <slug> <cache> <oldest epoch> — best effort: cache the nightly
# runs newer than the oldest row that bin/lib/flaky-tier-release.sh has not
# cached (ft_release fetches only when a flaky row is eligible). A listing it
# cannot read leaves the cache as it is.
_sqh_fetch() {
  local slug="$1" cache="$2" oldest="$3" root out runs id at sha e rc=0
  root=$(_sqh_root)
  command -v gh_ci_api >/dev/null 2>&1 && command -v _ftr_fetch >/dev/null 2>&1 || return 0
  out=$(gh_ci_api "$slug" "repos/$slug/actions/workflows/harness-nightly.yml/runs?branch=main&event=schedule&status=completed&per_page=${FLAKY_TIER_NIGHTLY_RUNS:-10}" 2>/dev/null) || rc=$?
  if [ "$rc" != 0 ]; then say "suite-quarantine: nightly run listing unknown (rc $rc); release reads the cache only"; return 0; fi
  runs=$(printf '%s' "$out" | jq -r '(.workflow_runs // []) | .[] | [(.id | tostring), (.created_at // ""), (.head_sha // "-")] | @tsv' 2>/dev/null) \
    || { say "suite-quarantine: nightly run listing unparseable; release reads the cache only"; return 0; }
  while IFS=$'\t' read -r id at sha; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [ -f "$cache/$id.tsv" ] && continue
    e=$(_ftr_epoch "$at") || continue
    [ "$e" -gt "$oldest" ] || continue
    _ftr_fetch "$root" "$slug" "$cache" "$id" "$at" "$sha" 2>/dev/null || break
  done <<< "$runs"
}

sqh_release() {
  local slug="$1" rows="$2" relout="$3" root cache s n red at ce f h fat fsha e v best_e best_v best_sha best_id oldest="" body
  root=$(_sqh_root); cache="$root/state/flaky-tier/nightly"
  [ -s "$rows" ] || return 0
  while IFS=$'\t' read -r s n red at; do
    ce=$(_ftr_epoch "$at") || continue
    { [ -z "$oldest" ] || [ "$ce" -lt "$oldest" ]; } && oldest=$ce
  done < "$rows"
  [ "${DRY:-0}" = 1 ] || [ -z "$oldest" ] || _sqh_fetch "$slug" "$cache" "$oldest"
  while IFS=$'\t' read -r s n red at; do
    ce=$(_ftr_epoch "$at") || { say "suite-quarantine: $s has created_at '$at'; kept"; continue; }
    best_e=0; best_v=""; best_sha=""; best_id=""
    for f in "$cache"/*.tsv; do
      [ -f "$f" ] || continue
      h=$(sed -n 1p "$f")
      case "$h" in "# created_at="*) ;; *) continue ;; esac   # `# unreadable …` decides nothing
      fat=$(sed -n '1s/.*created_at=\([^ ]*\).*/\1/p' "$f"); fsha=$(sed -n '1s/.* sha=\([^ ]*\).*/\1/p' "$f")
      e=$(_ftr_epoch "$fat") || continue
      [ "$e" -gt "$ce" ] && [ "$fsha" != "$red" ] && [ "$e" -gt "$best_e" ] || continue
      v=$(awk -F'\t' -v s="$s" '$1 == s { print $2; exit }' "$f")
      [ -n "$v" ] || continue
      best_e=$e; best_v=$v; best_sha=$fsha; best_id=$(basename "$f" .tsv)
    done
    [ "$best_v" = 0 ] || continue
    body=$(jq -cn --arg r "$slug" --arg s "$s" --arg g "$best_sha" '{repo: $r, suite: $s, main_sha_green: $g}') || continue
    if _ft_do "release suite-quarantine $s (green in nightly run $best_id on ${best_sha:0:12})" \
         bash "$root/bin/jobs-client.sh" suite-quarantine-release "$body" > "$TMPD/sq-rel.out" 2>/dev/null; then
      [ "${DRY:-0}" = 1 ] && continue
      if [ "$(jq -r '.released // empty' "$TMPD/sq-rel.out" 2>/dev/null)" = 1 ]; then
        printf '%s\n' "$s" >> "$relout"
        say "suite-quarantine: released $s (green in nightly run $best_id on ${best_sha:0:12}, newer than ${red:0:12})"
      else say "suite-quarantine: release of $s changed no row"; fi
    else say "suite-quarantine: release of $s failed; kept, retried next tick"; fi
  done < "$rows"
  return 0
}

sqh_project() {
  local rows="$1" rel="$2" want="$3" root s
  root=$(_sqh_root)
  while IFS=$'\t' read -r s _; do
    [ -n "$s" ] || continue
    grep -qxF -- "$s" "$rel" 2>/dev/null && continue
    [ -f "$root/$s" ] || { say "suite-quarantine: row names a missing suite: $s"; continue; }
    if tp_protected "$s" "$root" >/dev/null 2>&1; then
      say "suite-quarantine: protected $s is not projected (its row stays; fix it by hand)"; continue
    fi
    printf '%s\n' "$s" >> "$want"
  done < "$rows"
}
