#!/bin/bash
# bin/lib/mc-batch-impact.sh — WHICH MEMBER OF A FAILED BATCH CAN REACH THE
# TEST THAT FAILED (BH-4980, BH-4974.2). Sourced by bin/lib/mc-batch-eject.sh,
# never executed.
#
# THE RULE. When a Mergify batch draft fails, the failing tests are mapped back
# through bin/test-impact.sh's map to the members whose changed files reach
# them. Exactly one member: it is the culprit, and the others never needed a
# bisect. None (main red, a flake) or several: nothing here decides, and the
# batch's solo re-run (bs_batch, BH-4550) runs as before. bej_reentry_gate asks
# this only for a PR Mergify did NOT name in a multi-PR draft (`bystander`):
# when Mergify has a word of its own, that word wins.
#
# A FAILING TEST is one of two units:
#   S <tests/x.sh>           a suite, from the draft's solo facts (_bs_facts'
#                            `ok <base> <suites> <members>`: complete, paths only)
#   P <check> <prefix>       on `skip job-only` (the logs named jobs, not
#                            suites): a failing check, mapped to repo path
#                            prefixes by MC_BATCH_IMPACT_CHECK_PATHS
#                            (`<check>=<prefix>[,<prefix>]`, `;`-separated)
# Any other answer (no facts, another skip reason, a check not in the map) is
# unknown, and unknown is never a culprit and never a bystander.
#
# A MEMBER REACHES an S unit when `test-impact.sh select --why` on its files
# names that suite, always-suites included (a failing always-suite is reached
# by every member, so it is `several`). The select runs as a BATCH select
# (TI_BATCH_SELECT=1, BH-6688), the same rules the batch's own selection
# used: a catalog/ or tests/lib/ path reaches the suites the map ties to it,
# not the corpus. Without it, 17 of 20 replayed members reached `*` and the
# decision was never `eject`. A `full` row (a runner or workflow path, a file
# main's map cannot place, a file the PR adds) reaches everything: `*`, and
# the row's reason goes to `<files>.full`, logged as BATCH_IMPACT_FULL. Each
# draft logs BATCH_IMPACT_REACH, the members that reached `*`. It
# reaches a P unit when one of its files is under the prefix, or its reach is
# `*`. A member whose head, dequeue comment or file list cannot be read, or
# whose newest dequeue comment is not this draft's at its current head, is `?`,
# and one `?` makes the whole draft unknown.
#
# THE MAP IS THE HARNESS REPO'S OWN (the root _fr_ti_root picks, else
# ${HARNESS:-${H:-}}), so a draft in any other repo is unknown, as it is for
# mc-foreign-red. It is built once per draft (`test-impact.sh map`, ~3 s).
# MC_BATCH_IMPACT_MAP replaces it under HARNESS_TEST_SANDBOX=1 only.
#
# State. The draft's decision is $MC_STATE_DIR/batch-impact/<owner_repo>_<draft>
# (`<decision>` then `members <n…>`), written with tmp + mv and ONLY when every
# read succeeded: a memo of a pure computation over a draft that never
# changes. Losing it costs one recompute. An incomplete answer is memoised for
# the tick only (MC_TICK_DIR), so the members asking in one tick cost one pass.
#
#   bim_mode                                   0 off | 1 shadow | 2 enforce
#   bim_reach <files-list> <map>               the suites, or `*`; rc 1 unknown
#   bim_units <slug> <draft> <checks-enc>      the failing units; rc 1 unknown
#   bim_candidates <units> <reach-dir> <members>   pure: `<pr>\t<units>` | `?\t<pr>`
#   bim_decide <candidates> [units]            pure: the decision line
#   bim_verdict <slug> <draft> <checks-enc>    sets BIM_DECISION and BIM_MEMBERS
#
# A decision line is `eject <pr> <units>` or `bisect none|several|unknown
# <prs or -> <units or ->`, units %-encoded and comma-joined.

BIM_CHECK_PATHS_DEFAULT='Jobs worker — routes + schema=worker/jobs/;Mission Control SPA — unit tests + build=console-ui/'
BIM_DECISION=""; BIM_MEMBERS=""

_bim_log() { command -v mc_log >/dev/null 2>&1 && mc_log "$*"; return 0; }
_bim_dec() { local s="${1//%20/ }"; s="${s//%2C/,}"; printf '%s' "${s//%25/%}"; }

# _bim_raw_knob <ENV> — the lane knob as written (lane_knob, else the env).
_bim_raw_knob() {
  if command -v lane_knob >/dev/null 2>&1; then lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null
  else printf '%s' "${!1:-}"; fi
}

# _bim_root — where the map is built: a checkout with bin/test-impact.sh AND a
#   tests/ dir. rc 1 when there is none (the hub's own tree has no tests/).
_bim_root() {
  local r=""
  declare -F _fr_ti_root >/dev/null && r=$(_fr_ti_root 2>/dev/null)
  [ -n "$r" ] || r="${HARNESS:-${H:-}}"
  [ -n "$r" ] && [ -f "$r/bin/test-impact.sh" ] && [ -d "$r/tests" ] || return 1
  printf '%s\n' "$r"
}

# bim_mode — MC_BATCH_IMPACT: 0 off, 1 shadow (the default: compute and log,
#   decide nothing), 2 enforce. Anything else is 0, with ONE log line per
#   value, never clamped into a mode nobody chose.
bim_mode() {
  local v d
  v=$(_bim_raw_knob MC_BATCH_IMPACT)
  case "$v" in '') echo 1; return 0 ;; 0|1|2) echo "$v"; return 0 ;; esac
  d="${MC_STATE_DIR:-}/batch-impact"
  if [ -n "${MC_STATE_DIR:-}" ] && mkdir -p "$d" 2>/dev/null; then
    ( set -C; : > "$d/badmode_$(printf '%s' "$v" | tr -c 'A-Za-z0-9._-' '_')" ) 2>/dev/null \
      && _bim_log "BATCH_IMPACT_MODE_INVALID MC_BATCH_IMPACT=$v is not 0, 1 or 2: read as 0 (off), the impact map is not asked"
  else
    _bim_log "BATCH_IMPACT_MODE_INVALID MC_BATCH_IMPACT=$v is not 0, 1 or 2: read as 0 (off), the impact map is not asked"
  fi
  echo 0
}

# bim_reach <files-list> <map> — the suites those files reach, one per line,
#   or the single line `*` for any `full` row, whose reason (`full: unmapped
#   path (<p>)`) is written to <files-list>.full. rc 1 when the list is empty
#   or unreadable, there is no root, or test-impact fails or answers nothing.
bim_reach() {
  local files="${1:-}" map="${2:-}" root rows rc=0
  [ -n "$files" ] && [ -r "$files" ] && grep -q . "$files" 2>/dev/null || return 1
  [ -n "$map" ] && [ -s "$map" ] || return 1
  root=$(_bim_root) || return 1
  rm -f "$files.full"
  rows=$(TI_BATCH_SELECT=1 bash "$root/bin/test-impact.sh" select --why --changed "$files" --map "$map" --root "$root" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] && [ -n "$rows" ] || return 1
  if awk -F'\t' '$2 == "full" { f = 1 } END { exit !f }' <<<"$rows"; then
    awk -F'\t' '$2 == "full" { print $3; exit }' <<<"$rows" > "$files.full" 2>/dev/null || :
    echo '*'; return 0
  fi
  awk -F'\t' '$1 != "" { print $1 }' <<<"$rows" | LC_ALL=C sort -u
}

# bim_units <slug> <draft> <checks-enc> — `S\t<suite>` per failing suite, or
#   `P\t<check>\t<prefix>` per mapped check on `skip job-only`. rc 1 unknown.
bim_units() {
  local slug="$1" d="$2" checks="${3:-}" s c e pfx found map out=""
  local -a cs ents ps
  declare -F _bs_facts >/dev/null || return 1
  _bs_f=""
  _bs_facts "$slug" "$d" || return 1
  case "$_bs_f" in
    "ok "*)
      read -r _ _ s _ <<<"$_bs_f"
      [ -n "$s" ] || return 1
      tr ',' '\n' <<<"$s" | sed '/^$/d' | LC_ALL=C sort -u | awk '{ print "S\t" $0 }'
      return 0 ;;
    "skip job-only") ;;
    *) return 1 ;;
  esac
  [ -n "$checks" ] && [ "$checks" != - ] || return 1
  map=$(_bim_raw_knob MC_BATCH_IMPACT_CHECK_PATHS)
  [ -n "$map" ] || map="$BIM_CHECK_PATHS_DEFAULT"
  IFS=';' read -ra ents <<<"$map"
  IFS=, read -ra cs <<<"$checks"
  for c in "${cs[@]}"; do
    c=$(_bim_dec "$c"); found=0
    [ -n "$c" ] || return 1
    for e in "${ents[@]}"; do
      [ "${e%%=*}" = "$c" ] && [ "$e" != "${e#*=}" ] || continue
      IFS=, read -ra ps <<<"${e#*=}"
      for pfx in "${ps[@]}"; do
        [ -n "$pfx" ] || continue
        out+="P"$'\t'"$c"$'\t'"$pfx"$'\n'; found=1
      done
    done
    [ "$found" = 1 ] || return 1
  done
  printf '%s' "$out"
}

# bim_candidates <units-file> <reach-dir> <members> — PURE. For each member,
#   `<pr>\t<units it reaches, enc, comma-joined>` when it reaches one, nothing
#   when it reaches none, `?\t<pr>` when <reach-dir>/<pr>.reach or .files is
#   missing (unknown).
bim_candidates() {
  local units="$1" rd="$2" m
  [ -r "$units" ] && grep -q . "$units" || return 1
  for m in $3; do
    if [ ! -r "$rd/$m.reach" ] || [ ! -r "$rd/$m.files" ]; then printf '?\t%s\n' "$m"; continue; fi
    awk -F'\t' -v m="$m" -v rf="$rd/$m.reach" -v ff="$rd/$m.files" '
      function enc(x) { gsub(/%/, "%25", x); gsub(/ /, "%20", x); gsub(/,/, "%2C", x); return x }
      BEGIN { while ((getline l < rf) > 0) { if (l == "*") all = 1; R[l] = 1 }
              while ((getline l < ff) > 0) if (l != "") F[++nf] = l }
      $1 == "S" && !(("S" $2) in seen) { if (all || ($2 in R)) { seen["S" $2] = 1; hit[++h] = $2 } }
      $1 == "P" && !(("P" $2) in seen) {
        ok = all; for (i = 1; i <= nf && !ok; i++) if (index(F[i], $3) == 1) ok = 1
        if (ok) { seen["P" $2] = 1; hit[++h] = $2 } }
      END { if (h) { s = ""; for (i = 1; i <= h; i++) s = s (i > 1 ? "," : "") enc(hit[i]); print m "\t" s } }
    ' "$units"
  done
}

# _bim_units_label <units-file> — every unit's name, enc, comma-joined, or -.
_bim_units_label() {
  local l
  [ -r "${1:-}" ] || { echo -; return 0; }
  l=$(awk -F'\t' '$2 != "" && !seen[$2]++ { x = $2; gsub(/%/, "%25", x); gsub(/ /, "%20", x); gsub(/,/, "%2C", x); print x }' "$1" | paste -sd, -)
  echo "${l:--}"
}

# bim_decide <candidates> [units-file] — PURE. `eject <pr> <units>` for
#   exactly one candidate and no unknown, else `bisect none|several|unknown`.
bim_decide() {
  local c="$1" unk cands n lab
  unk=$(awk -F'\t' '$1 == "?" { print $2 }' <<<"$c" | paste -sd, -)
  if [ -n "$unk" ]; then echo "bisect unknown $unk $(_bim_units_label "${2:-}")"; return 0; fi
  n=$(awk -F'\t' '$1 != ""' <<<"$c" | grep -c .)
  case "$n" in
    0) echo "bisect none - $(_bim_units_label "${2:-}")" ;;
    1) awk -F'\t' '$1 != "" { print "eject " $1 " " $2 }' <<<"$c" ;;
    *) cands=$(awk -F'\t' '$1 != "" { print $1 }' <<<"$c" | sort -n | paste -sd, -)
       lab=$(awk -F'\t' '$1 != "" { print $2 }' <<<"$c" | tr ',' '\n' | awk '!seen[$0]++' | paste -sd, -)
       echo "bisect several $cands $lab" ;;
  esac
}

# _bim_compute <slug> <draft> <checks-enc> — sets BIM_DECISION / BIM_MEMBERS.
#   rc 0 every read succeeded (cacheable), rc 1 not.
_bim_compute() {
  local slug="$1" d="$2" checks="$3" root work map raw st m stacked n max i h pl complete=1 c nr=0 nf=0
  BIM_DECISION="bisect unknown - -"; BIM_MEMBERS=""
  [ -n "$slug" ] && [ "$slug" = "${HARNESS_REPO:-}" ] || return 1
  root=$(_bim_root) || return 1
  work=$(mktemp -d "${TMPDIR:-/tmp}/bim.XXXXXX" 2>/dev/null) || return 1
  mkdir -p "$work/r"
  if ! bim_units "$slug" "$d" "$checks" > "$work/units" || ! grep -q . "$work/units"; then rm -rf "$work"; return 1; fi
  mc_rest_var raw gh_rest GET "repos/$slug/pulls/$d" || { rm -rf "$work"; return 1; }
  st=$(bej_draft_members "$(jq -r '.title // empty' <<<"$raw" 2>/dev/null)") || { rm -rf "$work"; return 1; }
  IFS=$'\t' read -r m _ _ stacked <<<"$st"
  n=$(wc -w <<<"$m" | tr -d ' ')
  max=$(_bim_raw_knob MC_BATCH_SOLO_MAX_MEMBERS); case "$max" in ''|*[!0-9]*) max=13 ;; esac
  # A stacked draft also holds the PR it is built on; a batch of one has no
  # one else to blame; past the cap the file lists would not all be read.
  if [ "$stacked" = 1 ] || [ "$n" -lt 2 ] || [ "$n" -gt "$max" ]; then rm -rf "$work"; return 1; fi
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${MC_BATCH_IMPACT_MAP:-}" ]; then map="$MC_BATCH_IMPACT_MAP"
  else map="$work/map"; bash "$root/bin/test-impact.sh" map --root "$root" --out "$map" >/dev/null 2>&1 || : > "$map"; fi
  [ -s "$map" ] || { rm -rf "$work"; return 1; }
  for i in $m; do
    h=""; mc_rest_var raw gh_rest GET "repos/$slug/pulls/$i" && h=$(jq -r '.head.sha // empty' <<<"$raw" 2>/dev/null)
    [[ "$h" =~ ^[0-9a-f]{40}$ ]] || { complete=0; continue; }
    # The head that was in THIS draft: its newest dequeue comment is bound to
    # the current head and names this draft. A member that moved on is `?`.
    mc_rest_var raw gh_rest_issue_comments "$slug" "$i" 1000 || { complete=0; continue; }
    pl=$(bej_parse_dequeue "$raw" "$h") || { complete=0; continue; }
    [ "${pl%%$'\t'*}" = "$d" ] || { complete=0; continue; }
    mc_rest_var raw mc_pr_files "$slug" "$i" "https://github.com/$slug/pull/$i" "$h" || { complete=0; continue; }
    printf '%s\n' "$raw" | sed '/^$/d' > "$work/r/$i.files"
    if ! bim_reach "$work/r/$i.files" "$map" > "$work/r/$i.reach.tmp"; then
      rm -f "$work/r/$i.files" "$work/r/$i.reach.tmp"; complete=0; continue
    fi
    mv -f "$work/r/$i.reach.tmp" "$work/r/$i.reach"
    nr=$((nr + 1))
    if [ "$(cat "$work/r/$i.reach")" = '*' ]; then
      nf=$((nf + 1))
      _bim_log "BATCH_IMPACT_FULL draft=$d pr=$i $(head -1 "$work/r/$i.files.full" 2>/dev/null)"
    fi
  done
  _bim_log "BATCH_IMPACT_REACH draft=$d full=$nf of $nr members"
  c=$(bim_candidates "$work/units" "$work/r" "$m")
  BIM_DECISION=$(bim_decide "$c" "$work/units"); BIM_MEMBERS="$m"
  rm -rf "$work"
  [ "$complete" = 1 ] && [ "${BIM_DECISION#bisect unknown}" = "$BIM_DECISION" ]
}

# bim_verdict <slug> <draft> <checks-enc> — one decision per draft (see the
#   header), printed and in BIM_DECISION; BIM_MEMBERS holds the draft's PRs.
bim_verdict() {
  local slug="$1" d="$2" checks="${3:-}" cf="" memo="" f fd=""
  BIM_DECISION="bisect unknown - -"; BIM_MEMBERS=""
  [ -n "${MC_STATE_DIR:-}" ] && cf="$MC_STATE_DIR/batch-impact/${slug//\//_}_$d"
  if [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ] && command -v mc_safe_name >/dev/null 2>&1; then
    memo="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").bim.${slug//\//_}_$d"
  fi
  _bim_cached "$cf" "$memo" && { echo "$BIM_DECISION"; return 0; }
  # Every member's PR worker asks in the same tick. One computes, the others
  # wait for it (a few seconds: the reads and one map build) and read its
  # answer, instead of all of them reading the same file lists at once. A wait
  # past BIM_LOCK_WAIT_S is unknown for this tick, never cached.
  if [ -n "$cf" ] && mkdir -p "${cf%/*}" 2>/dev/null && exec {fd}>>"$cf.lock" 2>/dev/null; then
    if ! flock -w "${BIM_LOCK_WAIT_S:-60}" "$fd" 2>/dev/null; then
      exec {fd}>&-; echo "$BIM_DECISION"; return 0
    fi
    if _bim_cached "$cf" "$memo"; then exec {fd}>&-; echo "$BIM_DECISION"; return 0; fi
  fi
  if _bim_compute "$slug" "$d" "$checks"; then f="$cf"; else f="$memo"; fi
  [ -n "$f" ] && mkdir -p "${f%/*}" 2>/dev/null \
    && printf '%s\nmembers %s\n' "$BIM_DECISION" "$BIM_MEMBERS" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
  [ -n "$fd" ] && exec {fd}>&-
  echo "$BIM_DECISION"
}

# _bim_cached <cache> <memo> — rc 0 with BIM_DECISION / BIM_MEMBERS set from
#   the first of the two that holds a decision.
_bim_cached() {
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -s "$f" ] || continue
    { read -r BIM_DECISION; read -r _ BIM_MEMBERS; } < "$f"
    [ -n "$BIM_DECISION" ] && return 0
  done
  BIM_DECISION="bisect unknown - -"; BIM_MEMBERS=""
  return 1
}
