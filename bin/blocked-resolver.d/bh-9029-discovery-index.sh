# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9029-discovery-index.sh — BH-9029: a retired row
# leaves discovery, a finished record costs br_from_rebuilds no fork, a
# finished record with no PR url retires by age, and an unparseable record is
# named once and moved to .bad/.
#
# WHY. On 2026-11-03 the cromford tick spent 13 minutes in discovery.
# br_prepass wrote `.retired=true` on about 108 records a tick, and no source
# read that flag: each retired row was discovered, read from GitHub and dropped
# again on the next tick. br_from_rebuilds forked cat + 2 jq on each of 2,367
# state files before it dropped the finished ones. And one record that did not
# parse put `+index-short` on every tick with no path named.
#
# THE INDEX. bdi_load runs ONE find | awk | jq pass over the run's records
# before br_candidates, in the parent shell, so the sources (which run inside
# `RAW=$(br_candidates)`) inherit two arrays:
#   _BDI_OC[<record path>]  the outcome (`-` for none, `!PARSE` for a bad record)
#   _BDI_RURL[<pr url>]     1 when a record with retired=true and outcome
#                           RESOLVED_MERGED or ABANDONED names that PR as its
#                           outcome url: the same url br_finished compares.
# A PR url is the key, not the ticket, so another PR of a retired ticket (the
# bpr_scope case, BH-8339) is still discovered.
#
# Call sites, one line each in the driver and in bin/lib/br/discovery.sh:
#   driver, before RAW=$(br_candidates)     -> bdi_load
#   br_from_conductor (both loops), br_from_reviews -> bdi_url_retired
#   br_from_rebuilds, before the cat        -> bdi_rec_skip
#   br_candidates, around each source       -> bdi_src_secs
#   br_from_builds                          -> the .blocked-resolver-retired marker, bdi_count
#   br_prepass, finished rows               -> bdi_mark_build, bdi_aged_finished
#   br_prepass, after the index loop        -> bdi_bad_records
# BR_OPT_OFF=bh-9029-discovery-index does not source this file; each call site
# then does what it did before.

# bdi_load — fill the index. One `say` line and _BDI_OK=0 when the pass fails:
#   every skip below then answers "no" and the tick runs as it did before.
bdi_load() {
  local out rc=0 p oc url
  declare -gA _BDI_OC=() _BDI_RURL=()
  _BDI_OK=0
  [ -d "$ST" ] || { _BDI_OK=1; return 0; }
  # The jq program carries the word bdi-index in a comment: one name for this
  # pass in a process list, and the handle the D8 test uses to fail it alone.
  out=$({ if [ -n "${ONLY:-}" ]; then
            [ -d "$ST/$ONLY" ] && find "$ST/$ONLY" -mindepth 1 -maxdepth 1 -name '*.json' -type f -print0 2>/dev/null
          else
            find "$ST" -mindepth 2 -maxdepth 2 -name '*.json' -type f -print0 2>/dev/null
          fi; } \
        | xargs -0 -r awk 'FNR==1 { printf "%s\t%s\n", FILENAME, $0 }' 2>/dev/null \
        | jq -R -r '# bdi-index (BH-9029)
            (index("\t")) as $i |
            if $i == null then empty else
              (.[:$i]) as $path |
              ((try (.[$i+1:] | fromjson) catch null)) as $r |
              if ($r | type) != "object" then $path + "\t!PARSE\t-"
              else
                (($r.outcome // "") | tostring | if . == "" then "-" else . end) as $oc |
                ( if $oc == "ABANDONED" then ($r.abandoned_url // "")
                  else ($r.resolved_url //
                        ([ $r.attempts[]? | select((.action // "") == "resolved-merged")
                           | (.detail // "")
                           | capture("^(?<u>https://github\\.com/[^ ]+) is already MERGED") .u ] | last) // "")
                  end ) as $u |
                $path + "\t" + $oc + "\t"
                + ( if ($r.retired // false) == true and ($oc == "RESOLVED_MERGED" or $oc == "ABANDONED")
                       and (($u | tostring) | test("^https://github\\.com/[^/]+/[^/]+/pull/[0-9]+$"))
                    then ($u | tostring) else "-" end )
              end
            end') || rc=$?
  if [ "$rc" != 0 ]; then
    say "the discovery index did not load (jq rc $rc) — no retired row is skipped this tick, discovery runs as before"
    return 0
  fi
  while IFS=$'\t' read -r p oc url; do
    [ -n "$p" ] || continue
    _BDI_OC["$p"]="$oc"
    [ "$url" = "-" ] || _BDI_RURL["$url"]=1
  done <<<"$out"
  _BDI_OK=1
  return 0
}

# bdi_count — one skip, counted in $BDI_SKIPS. A builtin append, because the
#   sources run inside $(...) and a variable would die with the subshell.
bdi_count() {
  [ -n "${BDI_SKIPS:-}" ] && printf '1\n' >> "$BDI_SKIPS" 2>/dev/null
  return 0
}

# bdi_src_secs <source> <start-SECONDS> — one `<source>:<secs>` line in
#   $BDI_SRC_SECS for the prof line's discovery_src=. Called by br_candidates.
bdi_src_secs() {
  [ -n "${BDI_SRC_SECS:-}" ] || return 0
  printf '%s:%s\n' "$1" "$(( SECONDS - $2 ))" >> "$BDI_SRC_SECS" 2>/dev/null
  return 0
}

# bdi_url_retired <pr-url> — rc 0 skip: the index loaded and a retired,
#   finished record names this exact PR url. Counted.
bdi_url_retired() {
  [ "${_BDI_OK:-0}" = 1 ] || return 1
  [ -n "${1:-}" ] && [ -n "${_BDI_RURL["$1"]:-}" ] || return 1
  bdi_count
  return 0
}

# bdi_rec_skip <record path> — rc 0 skip: br_from_rebuilds would drop this
#   record on its outcome anyway. Not counted: such a record was never a
#   candidate. A path the index does not hold (written after the pass) and an
#   unparseable one take today's path.
bdi_rec_skip() {
  [ "${_BDI_OK:-0}" = 1 ] || return 1
  local oc="${_BDI_OC["${1:-}"]:-}"
  case "$oc" in ''|-|HELD|DATA_LANE|'!PARSE') return 1 ;; esac
  return 0
}

# bdi_mark_build <src> <rec> <outcome> — a finished build row has no PR url,
#   so the build dir itself carries the retire: `.blocked-resolver-retired`
#   (`<outcome>\t<stamp>`), read by br_from_builds. Written once; observe mode
#   writes nothing.
bdi_mark_build() {
  [ "${1:-}" = build ] || return 0
  [ "${OBSERVE:-0}" = 1 ] && return 0
  local d="${2:-}"
  [ -n "$d" ] && [ "$d" != "-" ] && [ -d "$d" ] || return 0
  [ -e "$d/.blocked-resolver-retired" ] && return 0
  printf '%s\t%s\n' "${3:--}" "$(STAMP)" > "$d/.blocked-resolver-retired" 2>/dev/null \
    || say "$d: the retired marker was not written — this build row is discovered again next tick"
  return 0
}

# bdi_retire_days — BR_FINISHED_RECORD_RETIRE_DAYS, checked. Registry knob
#   lane.blocked-resolver.BR_FINISHED_RECORD_RETIRE_DAYS (catalog/lanes.d/
#   blocked-resolver.knobs.d/BR_FINISHED_RECORD_RETIRE_DAYS.json); 14 is its
#   documented fallback, 0 turns the aged retire off. The value goes to
#   $_BDI_DAYS, not to stdout: a $(...) call would lose the "said once" mark,
#   and a bad value would then be said once per row. The fragment defines
#   functions only, so both globals start here, on first use.
bdi_retire_days() {
  local k="${BR_FINISHED_RECORD_RETIRE_DAYS:-14}"
  case "$k" in
    ''|*[!0-9]*)
      if [ "${_BDI_DAYS_SAID:-0}" = 0 ]; then
        say "BR_FINISHED_RECORD_RETIRE_DAYS is '$k', not a number — the fallback 14 is used"
        _BDI_DAYS_SAID=1
      fi
      k=14 ;;
  esac
  _BDI_DAYS="$k"
}

# bdi_aged_finished <outcome> <row url> <reason> <age_days> <aged-flag> [days]
#   rc 0 retire: a RESOLVED_MERGED record whose row has no PR url (the D11
#   case br_finished never retires), untouched for at least the knob's days.
#   A rebuild-* reason is never retired (review I3: its ending is still owed).
#   <aged-flag> 1 means this arm already retired the record: the flag write
#   moved `.updated`, so the age alone would bring the row back. PURE: the
#   knob arrives as [days] from the caller, or is read here.
bdi_aged_finished() {
  local oc="${1:-}" url="${2:-}" reason="${3:-}" age="${4:--}" aged="${5:-0}" days="${6:-}"
  [ "$oc" = RESOLVED_MERGED ] || return 1
  case "$url" in ''|-) ;; *) return 1 ;; esac
  case "$reason" in rebuild-*) return 1 ;; esac
  [ -n "$days" ] || { bdi_retire_days; days="$_BDI_DAYS"; }
  [ "$days" = 0 ] && return 1
  [ "$aged" = 1 ] && return 0
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age" -ge "$days" ]
}

# bdi_quarantine_min — BR_BAD_RECORD_QUARANTINE_MIN, checked. Registry knob
#   lane.blocked-resolver.BR_BAD_RECORD_QUARANTINE_MIN (catalog/lanes.d/
#   blocked-resolver.knobs.d/BR_BAD_RECORD_QUARANTINE_MIN.json); 10 is its
#   documented fallback, 0 names a bad record and never moves it.
bdi_quarantine_min() {
  local k="${BR_BAD_RECORD_QUARANTINE_MIN:-10}"
  case "$k" in
    ''|*[!0-9]*) say "BR_BAD_RECORD_QUARANTINE_MIN is '$k', not a number — the fallback 10 is used"; k=10 ;;
  esac
  printf '%s' "$k"
}

# bdi_bad_records [<path>…] — the pre-pass's unparseable records. Prints the
#   paths that are NEW in this episode (space separated, nothing when the set
#   is the one the last tick saw); the episode file is $ST/.index-bad[-<p>], a
#   dotfile at depth 1 that no record glob reads. Then each bad record older
#   than the knob is moved to $ST/<p>/.bad/<key>.<stamp>.json, one line each.
#   br_load finds no file there next tick and restores the counters and the
#   outcome from the ledger row (BH-2317), so the move loses nothing.
bdi_bad_records() {
  local ef="$ST/.index-bad${ONLY:+-$ONLY}" cur old newp="" f min p ck qd qf stamp
  cur=$(printf '%s\n' "$@" | sed '/^$/d' | LC_ALL=C sort -u)
  if [ -z "$cur" ]; then
    rm -f "$ef" 2>/dev/null
    return 0
  fi
  old=$(cat "$ef" 2>/dev/null)
  if [ "$cur" != "$old" ]; then
    newp=$(LC_ALL=C comm -23 <(printf '%s\n' "$cur") <(printf '%s\n' "$old" | sed '/^$/d' | LC_ALL=C sort -u) | tr '\n' ' ')
    printf '%s\n' "$cur" > "$ef" 2>/dev/null
  fi
  min=$(bdi_quarantine_min)
  if [ "$min" != 0 ]; then
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      [ -n "$(find "$f" -mmin +"$((min - 1))" 2>/dev/null)" ] || continue
      p="${f%/*}"; p="${p##*/}"; ck="${f##*/}"; ck="${ck%.json}"
      qd="$ST/$p/.bad"; qf="$qd/$ck.$stamp.json"
      if [ "${OBSERVE:-0}" = 1 ]; then
        say "$p/$ck: WOULD quarantine the unparseable state record to $qf — observe mode"
        continue
      fi
      if mkdir -p "$qd" 2>/dev/null && mv -n "$f" "$qf" 2>/dev/null && [ ! -e "$f" ]; then
        say "$p/$ck: unparseable state record quarantined to $qf — the next tick restores its counters from the ledger row"
      else
        say "$p/$ck: unparseable state record could not be quarantined to $qd — it stays in place and the tick stays +index-short"
      fi
    done <<<"$cur"
  fi
  printf '%s' "${newp% }"
  return 0
}
