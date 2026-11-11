# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9467-record-age-out.sh — BH-9467 (#9369 fix 2): a
# build or rebuild row whose ticket has no open PR, and whose RESULT and record
# are both older than BR_RECORD_MAX_AGE_DAYS, leaves the candidate list in the
# pre-pass and is not discovered again.
#
# WHY. On 2026-11-09 the hub's cromford tick found 783 candidates and ran
# 2 rungs: build and rebuild rows of tickets nobody works on any more stayed
# candidates for ever, because br_prepass dropped a row only on a closed PR or
# a finished record.
#
# WHAT IS AGED. All of these, per row:
#   - the source is `build` or `rebuild`;
#   - the record outcome is not HELD or DATA_LANE (a human step or a data-lane
#     probe can still lift it);
#   - the record is old: its `.updated` age in days (br_record_index) is at
#     least the knob. A build row with no record passes; a record whose
#     `.updated` does not read does not (absent is not old);
#   - the RESULT is old: the row's build dir has a RESULT older than the knob
#     (one find per tick, bra_old_dirs). A rebuild row with no dir (`-`, the
#     enqueue that did not land) passes on its record age alone; a build row
#     with no local dir (a ledger-only row) does not;
#   - no open PR names the ticket: the row url is not in the open list, and no
#     open head branch carries the ticket key (bra_has_open). An open list that
#     does not read keeps every row.
#
# THE MARK. A build row: `.blocked-resolver-retired` (`aged-out\t<stamp>`) in
# the dir, which br_from_builds skips from the next tick. A rebuild row: one
# `aged-out` attempt on the record, so its last attempt is no longer
# `rebuild-fresh*` and br_from_rebuilds reads past it. A new build dir or a new
# rebuild-fresh attempt brings the ticket back. One resolver_retired line per
# row, said once: the mark keeps the row out of discovery after it.
#
# Knob (catalog/lanes.d/blocked-resolver.knobs.d/BR_RECORD_MAX_AGE_DAYS.json):
#   BR_RECORD_MAX_AGE_DAYS 14   0 = off
# Call site, one line in br_prepass, after bcr_prepass_row: bra_prepass_row.
# BR_OPT_OFF=bh-9467-record-age-out does not source this file.

# bra_days — the knob, checked, into $_BRA_DAYS. A non-number is said once per
#   run and the fallback 14 is used.
bra_days() {
  local k="${BR_RECORD_MAX_AGE_DAYS:-14}"
  case "$k" in
    ''|*[!0-9]*)
      if [ "${_BRA_DAYS_SAID:-0}" = 0 ]; then
        say "BR_RECORD_MAX_AGE_DAYS is '$k', not a number — the fallback 14 is used"
        _BRA_DAYS_SAID=1
      fi
      k=14 ;;
  esac
  _BRA_DAYS="$k"
}

# bra_old_dirs — ONE find for the build dirs whose RESULT is older than the
#   knob, into _BRA_OLD[<dir>]=1. A project run looks at its own dirs only.
#   Called once per pre-pass (the first row that needs it).
bra_old_dirs() {
  local d mins
  declare -gA _BRA_OLD=()
  _BRA_OLD_LOADED=1
  [ -d "$H/builds" ] || return 0
  mins=$(( _BRA_DAYS * 1440 ))   # minutes per day: a unit, not a knob
  while IFS= read -r d; do
    [ -n "$d" ] && _BRA_OLD["$d"]=1
  done < <(if [ -n "${ONLY:-}" ]; then
             find "$H/builds" -mindepth 2 -maxdepth 2 -name RESULT -mmin +"$mins" \
               \( -path "$H/builds/$ONLY-*/RESULT" -o -path "$H/builds/pool-$ONLY-*/RESULT" \
                  -o -path "$H/builds/fly-$ONLY-*/RESULT" \) -printf '%h\n' 2>/dev/null
           else
             find "$H/builds" -mindepth 2 -maxdepth 2 -name RESULT -mmin +"$mins" -printf '%h\n' 2>/dev/null
           fi)
  return 0
}

# bra_open <project> — the project's open PRs, once per pre-pass:
#   _BRA_OURL[<url>]=1, _BRA_OHEAD[<project>] (lowercased head branches, one per
#   line), _BRA_OPEN_OK[<project>] 1 or 0. br_open_prs is the tick's cached read
#   (br_from_reviews and bcr_load filled it), so the steady state makes no new
#   GitHub call. An unreadable list is said once per project.
bra_open() {
  local p="$1" slug list u hd
  [ -n "${_BRA_OPEN_OK["$p"]+x}" ] && return 0
  _BRA_OPEN_OK["$p"]=0
  slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null </dev/null)
  case "$slug" in
    ''|-|*[!A-Za-z0-9._/-]*)
      say "$p: no repo slug — no build or rebuild row is aged out this tick"; return 0 ;;
  esac
  command -v br_use_token >/dev/null 2>&1 && br_use_token "$slug" </dev/null
  if ! list=$(br_open_prs "$slug" </dev/null); then
    command -v br_reset_token >/dev/null 2>&1 && br_reset_token
    say "open-PR list for $slug unreadable — no build or rebuild row is aged out this tick"
    return 0
  fi
  command -v br_reset_token >/dev/null 2>&1 && br_reset_token
  _BRA_OHEAD["$p"]=""
  while IFS=$'\t' read -r u hd; do
    [ -n "$u" ] && _BRA_OURL["$u"]=1
    [ -n "$hd" ] && _BRA_OHEAD["$p"]+="${hd,,}"$'\n'
  done < <(printf '%s' "$list" | jq -r '.[]? | [(.url // ""), (.headRefName // "")] | @tsv' 2>/dev/null)
  _BRA_OPEN_OK["$p"]=1
  return 0
}

# bra_has_open <project> <ticket-key> <row-url> — rc 0 (keep the row) when the
#   row url is open, or an open head branch names the ticket key, or the open
#   list did not read, or there is no key. The key matches as a whole word on
#   the left and is not followed by a digit: bh-946 does not match
#   ticket/bh-9467; bh-9369 matches ticket/bh-9369.1 and ticket/bh-9369-r2.
bra_has_open() {
  local p="$1" k="${2:-}" url="${3:--}" re
  if [ "${_BRA_OPEN_INIT:-0}" != 1 ]; then
    declare -gA _BRA_OPEN_OK=() _BRA_OURL=() _BRA_OHEAD=()
    _BRA_OPEN_INIT=1
  fi
  case "$k" in ''|-) return 0 ;; esac
  bra_open "$p"
  [ "${_BRA_OPEN_OK["$p"]:-0}" = 1 ] || return 0
  [ "$url" != "-" ] && [ -n "${_BRA_OURL["$url"]:-}" ] && return 0
  k="${k,,}"; k="${k//./[.]}"
  re="(^|[^a-z0-9])${k}([^0-9]|\$)"
  [[ $'\n'"${_BRA_OHEAD["$p"]:-}" =~ $re ]]
}

# bra_aged <src> <outcome> <record-age-days> <rec> <has-record 0|1> [days]
#   rc 0 when the row is old enough to age out (see the header). PURE once
#   _BRA_OLD is loaded; [days] defaults to $_BRA_DAYS.
bra_aged() {
  local src="${1:-}" oc="${2:--}" age="${3:--}" rec="${4:--}" hasrec="${5:-0}" days="${6:-${_BRA_DAYS:-14}}"
  case "$src" in build|rebuild) ;; *) return 1 ;; esac
  case "$oc" in HELD|DATA_LANE) return 1 ;; esac
  [ "$days" != 0 ] || return 1
  if [ "$hasrec" = 1 ]; then
    case "$age" in ''|*[!0-9]*) return 1 ;; esac
    [ "$age" -ge "$days" ] || return 1
  else
    [ "$src" = build ] || return 1
  fi
  if [ "$rec" = "-" ] || [ -z "$rec" ]; then
    [ "$src" = rebuild ]
    return
  fi
  [ -n "${_BRA_OLD["$rec"]:-}" ]
}

# bra_prepass_row — br_prepass's one call, per keyed row. It reads the
#   pre-pass locals (src p rkey reason url rec tkey key ck roc rage, and the
#   index _BRIDX) by bash's dynamic scope, like bcr_prepass_row. rc 0: the row
#   is aged out (counted in the pre-pass $n, marked, said once) and the
#   pre-pass drops it. rc 1: the row goes on as before.
bra_prepass_row() {
  local hasrec=0 det wrote=1
  case "${src:-}" in build|rebuild) ;; *) return 1 ;; esac
  bra_days
  [ "$_BRA_DAYS" != 0 ] || return 1
  [ "${_BRA_OLD_LOADED:-0}" = 1 ] || bra_old_dirs
  [ -n "${_BRIDX["$key/$ck"]+x}" ] && hasrec=1
  bra_aged "$src" "${roc:--}" "${rage:--}" "${rec:--}" "$hasrec" "$_BRA_DAYS" || return 1
  bra_has_open "$key" "${tkey:--}" "${url:--}" && return 1
  n=$((n+1))
  det="no open PR, RESULT and record older than $_BRA_DAYS days (BR_RECORD_MAX_AGE_DAYS=$_BRA_DAYS) — aged out, no rung"
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "$key/$rkey [$reason]: WOULD age out — $det — observe mode"
    return 0
  fi
  # THE MARK FIRST, then the line: a line with no mark would repeat every tick
  # while it claims the row left the list.
  if [ "$src" = build ]; then
    printf 'aged-out\t%s\n' "$(STAMP)" > "$rec/.blocked-resolver-retired" 2>/dev/null || wrote=0
  else
    br_record "$key" "$ck" aged-out aged-out "$det" </dev/null || wrote=0
  fi
  if [ "$wrote" = 1 ]; then
    br_event resolver_retired "$key" "$ck" "$reason" "$det" </dev/null
  else
    say "$key/$rkey: the aged-out mark was not written — this row is aged out again next tick"
  fi
  return 0
}
