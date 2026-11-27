#!/bin/bash
# bin/lib/br/opt/unchanged.sh — the persisted "unchanged since the last look"
# skip of bin/blocked-resolver.sh (BH-5946). Optional module of the BH-1468
# seam; see bin/lib/br/opt/README.md.
#
# WHY. Most of the 600+ rows a hub run offers end on a quiet exit: a HELD
# ticket, an ESCALATED or STALLED terminal, a hold the rung gate respected. The
# next run reads each of them again from the start (the hold issue and its
# comment pages, the merged-PR search, the PR) and ends on the same exit.
#
# WHAT. At a quiet exit br_one calls br_quiet <class>, which stores ONE ledger
# line for the row: a fingerprint of its LOCAL inputs, the class and the epoch.
# On the next run br_opt_unchanged_skip is asked at the top of br_one, before
# the repo token and before any GitHub, D1 or model call. It answers 0 (br_one
# returns 3: no rung, no PER_TICK slot) only when the ledger line exists, its
# class is on BR_UNCHANGED_CLASSES, the look is younger than
# BR_UNCHANGED_RECHECK_S and a fresh fingerprint is equal to the stored one.
#
# THE FINGERPRINT reads local files, no _jobs_req, and at most ONE GitHub list
# read per repo per run (br_open_prs, below, only for a PR with no conductor
# line). br_one asks after br_use_token, so that read uses the repo's own
# credential, the same one the mark used (lead review of a102133f3):
#   - the row: reason, source, PR url, ticket key, build record path;
#   - the ticket's whole state json ($ST/<p>/<cap-key>.json, `jq -S -c .`), so
#     any counter, outcome, stall fingerprint or attempt re-arms the row;
#   - for a PR url: the conductor's pr-state.tsv line for the PR (head, reviewed
#     sha = the verdict, park reason, state) and the mtime of its hand-off file;
#     with no conductor line, the PR's head from br_open_prs (the per-run
#     open-PR list, one list read per repo per run at most);
#   - the newest mtime among the build record's top-level files;
#   - the mtimes of state/build-queue/<p>/<key>.json and <key>.failed.json.
# What it does not see is what the TTL is for: a RESUME comment on a held
# issue, a person's answer on a needs-human hold, a newer job row for an
# abandoned ticket. Those are seen at most BR_UNCHANGED_RECHECK_S late.
#
# THE LEDGER is one file per row, $ST/<p>/.looks/<rkey>, one line
# `fp<TAB>class<TAB>epoch<TAB>wm<TAB>rv` (wm and rv: the BH-10198 change mark,
# bin/blocked-resolver.d/bh-10198-read-after-change.sh), written by temp file + mv. br_opt_unchanged_forget
# removes it at the dispatch line, so a row that took a rung is always looked
# at on the next run. Lines older than twice BR_UNCHANGED_RECHECK_S are pruned,
# once per BR_UNCHANGED_RECHECK_S per project.
#
# Off: BR_UNCHANGED_RECHECK_S=0 or the br-unchanged-off switch (lane_switch: a
# switch.br-unchanged-off row, else flags/br-unchanged-off). Then nothing is
# defined, every hook is a `command -v` miss and br_quiet does nothing.

command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply br-repeat-cuts >/dev/null 2>&1
if [ "${BR_UNCHANGED_RECHECK_S:-1800}" = 0 ] || [ "${BR_FIX_HERE:-0}" = 1 ] \
   || { command -v lane_switch >/dev/null 2>&1 && lane_switch br-unchanged-off file; }; then
  return 0
fi

_br_uc_ledger() { printf '%s/%s/.looks/%s' "$ST" "$1" "$2"; }

# _br_uc_class_ok <class> — rc 0 when the class is on the allowlist.
_br_uc_class_ok() {
  case " ${BR_UNCHANGED_CLASSES:-held escalated stalled job-abandoned hv-stands rung-hold needs-human ci-parked} " in
    *" ${1:-} "*) return 0 ;;
  esac
  return 1
}

# br_opt_unchanged_fp <p> <rkey> <reason> <url> <rec> <tkey> <src> <ck> — the
# fingerprint (40 hex) of the row's local inputs.
br_opt_unchanged_fp() {
  local p="$1" reason="${3:--}" url="${4:--}" rec="${5:--}" tkey="${6:--}" src="${7:--}" ck="$8"
  local f slug num key row hf head=""
  {
    printf 'reason=%s\nsrc=%s\nurl=%s\ntkey=%s\nrec=%s\n' "$reason" "$src" "$url" "$tkey" "$rec"
    f="$ST/$p/$ck.json"
    if [ -s "$f" ]; then printf 'state=%s\n' "$(jq -S -c . "$f" 2>/dev/null || echo unparsable)"
    else echo 'state=-'; fi
    if [[ "$url" =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
      slug="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"; key="$slug#$num"
      row=""
      command -v mc_row_get >/dev/null 2>&1 && row=$(mc_row_get "$key")
      printf 'row=%s\n' "$row"
      if [ -n "$row" ]; then
        hf=""
        command -v mc_handoff_file >/dev/null 2>&1 && hf=$(mc_handoff_file "$key")
        printf 'handoff=%s\n' "$( [ -n "$hf" ] && stat -c %Y "$hf" 2>/dev/null || echo -)"
      else
        command -v br_open_prs >/dev/null 2>&1 \
          && head=$(br_open_prs "$slug" 2>/dev/null | jq -r --argjson n "$num" '.[] | select(.number == $n) | .headRefOid // empty' 2>/dev/null)
        printf 'openhead=%s\n' "${head:--}"
      fi
    fi
    if [ "$rec" != - ] && [ -d "$rec" ]; then
      printf 'rec=%s\n' "$(find "$rec" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
    fi
    if [ "$tkey" != - ]; then
      # D43: no path from an empty root. With H unset the queue is unknown, `-`.
      # The two stats are reads; the path is spelled inline, never assigned, so
      # bin/state-paths-guard.sh does not read it as a write of the rows path.
      if [ -n "${H:-}" ]; then
        printf 'queue=%s %s\n' "$(stat -c %Y "$H/state/build-queue/$p/$tkey.json" 2>/dev/null || echo -)" \
                                "$(stat -c %Y "$H/state/build-queue/$p/$tkey.failed.json" 2>/dev/null || echo -)"
      else
        echo 'queue=- -'
      fi
    fi
  } | sha1sum | cut -c1-40
}

# br_opt_unchanged_skip <p> <rkey> <reason> <url> <rec> <tkey> <src> — rc 0:
# this row is unchanged since a quiet look younger than BR_UNCHANGED_RECHECK_S,
# and br_one returns 3 with no call. Counts `unchanged`; writes no log line
# (600 lines a run would bury the log; the `prof:` line carries the count).
br_opt_unchanged_skip() {
  # BH-10198 (bin/blocked-resolver.d/bh-10198-read-after-change.sh): prime the
  # wakes mirror; a row that will be read takes its change mark (the wakes
  # watermark and the PR record version) here, before any GitHub read.
  command -v br_rac_begin >/dev/null 2>&1 && br_rac_begin "${1:-}"
  _br_uc_skip "$@" && return 0
  command -v br_rac_pre >/dev/null 2>&1 && br_rac_pre "${1:-}" "${2:-}" "${4:--}"
  return 1
}

# _br_uc_skip — the decision of br_opt_unchanged_skip, same arguments and rc.
_br_uc_skip() {
  local p="$1" rkey="$2" tkey="${6:--}" ck lf line fp class epoch wm rv rac=unknown now age max
  case "${3:-}" in external-*) return 1 ;; esac
  lf=$(_br_uc_ledger "$p" "$rkey")
  [ -s "$lf" ] || return 1
  IFS=$'\t' read -r fp class epoch wm rv < "$lf" || return 1
  _br_uc_class_ok "$class" || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  max="${BR_UNCHANGED_RECHECK_S:-1800}"
  case "$max" in ''|*[!0-9]*) max=1800 ;; esac
  now="${EPOCHSECONDS:-$(date -u +%s)}"
  age=$(( now - epoch ))
  [ "$age" -ge 0 ] || return 1
  # BH-10198: asked only past today's window (inside it the skip already
  # holds, and the record peek would cost a jobs GET a row). changed = read
  # now; quiet = skip up to the backstop; unknown (a source that cannot
  # answer, no PR record, an old ledger line) = read, as today.
  [ "$age" -ge "$max" ] && command -v br_rac_due >/dev/null 2>&1 \
    && rac=$(br_rac_due "$p" "$tkey" "${4:--}" "${wm:-}" "${rv:-}" "$class")
  case "$rac" in
    changed) br_count rac-changed; return 1 ;;
    quiet)   [ "$age" -lt "$max" ] || [ "$age" -lt "$(br_rac_backstop)" ] || return 1 ;;
    *)       [ "$age" -lt "$max" ] || return 1 ;;
  esac
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  line=$(br_opt_unchanged_fp "$p" "$rkey" "${3:--}" "${4:--}" "${5:--}" "$tkey" "${7:--}" "$ck")
  [ -n "$line" ] && [ "$line" = "$fp" ] || return 1
  br_count unchanged
  [ "$rac" = quiet ] && [ "$age" -ge "$max" ] && br_count rac-quiet
  return 0
}

# br_opt_unchanged_mark <class> <p> <rkey> <reason> <url> <rec> <tkey> <src> <ck>
#   — store the row's fingerprint as it is NOW, after the quiet look. A class
#   that is not on the allowlist stores nothing.
br_opt_unchanged_mark() {
  local class="$1" p="${2:-}" rkey="${3:-}" lf fp now wm=- rv=-
  [ -n "$p" ] && [ -n "$rkey" ] && [ -n "${9:-}" ] || return 0
  _br_uc_class_ok "$class" || return 0
  fp=$(br_opt_unchanged_fp "$p" "$rkey" "${4:--}" "${5:--}" "${6:--}" "${7:--}" "${8:--}" "$9")
  [ -n "$fp" ] || return 0
  # BH-10198: the change mark br_rac_pre took before the reads (`-` and empty
  # when it did not run for this row: the next skip then answers unknown).
  command -v br_rac_mark >/dev/null 2>&1 && IFS=$'\t' read -r wm rv <<<"$(br_rac_mark "$rkey")"
  lf=$(_br_uc_ledger "$p" "$rkey")
  now="${EPOCHSECONDS:-$(date -u +%s)}"
  mkdir -p "$(dirname "$lf")" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$fp" "$class" "$now" "${wm:--}" "$rv" > "$lf.tmp.$BASHPID" 2>/dev/null \
    && mv -f "$lf.tmp.$BASHPID" "$lf" 2>/dev/null
  rm -f "$lf.tmp.$BASHPID" 2>/dev/null
  _br_uc_prune "$(dirname "$lf")" "$now"
  return 0
}

# _br_uc_prune <looks-dir> <now> — at most once per BR_UNCHANGED_RECHECK_S per
# project (the .pruned marker's mtime), remove the ledger lines older than twice
# that, or than BR_RAC_BACKSTOP_S when the BH-10198 fragment is on and that is
# longer. A line that old can never answer a skip, and a row no source offers any
# more would otherwise leave its file behind for good.
_br_uc_prune() {
  local d="$1" now="$2" max m mt keep b
  max="${BR_UNCHANGED_RECHECK_S:-1800}"
  case "$max" in ''|*[!0-9]*|0) return 0 ;; esac
  m="$d/.pruned"
  mt=$(stat -c %Y "$m" 2>/dev/null) || mt=0
  [ $(( now - mt )) -ge "$max" ] || return 0
  : > "$m" 2>/dev/null || return 0
  # BH-10198: a quiet skip does not rewrite the line, so with the
  # read-after-change fragment on a line must live to its backstop
  # (BR_RAC_BACKSTOP_S), the longest a line can still answer a skip.
  keep=$(( 2 * max ))
  if command -v br_rac_backstop >/dev/null 2>&1; then
    b=$(br_rac_backstop)
    case "$b" in ''|*[!0-9]*) ;; *) [ "$b" -gt "$keep" ] && keep="$b" ;; esac
  fi
  find "$d" -maxdepth 1 -type f ! -name .pruned ! -name '*.tmp.*' -mmin +$(( (keep + 59) / 60 )) -delete 2>/dev/null
  return 0
}

# br_opt_unchanged_forget <p> <rkey> — the row reached its dispatch line.
br_opt_unchanged_forget() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  rm -f "$(_br_uc_ledger "$1" "$2")" 2>/dev/null
  return 0
}
