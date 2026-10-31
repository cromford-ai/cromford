#!/bin/bash
# bin/lib/lead-authority.sh — BH-3683: who may publish `lead-verdict: success`.
# Sourced (by bin/lib/verdict-status.sh, so every writer of the status has it),
# never executed.
#
# THE RULE. The hub's lead-review lane is the verdict authority: its MERGE
# publishes the gating status with no Mac involved. A PROTECTED PATH is the glob
# of a live lead_protected_paths row of the PR's repo, a table in the jobs worker
# (BH-4146) read with GET /api/lead-protected-paths?repo=<owner/name, lowercased>
# (BH-4148). Rows are added and removed from SETTINGS -> PROTECTED PATHS in the
# console (BH-4147). A glob cannot contain whitespace; a row that has one is
# ignored here.
# THE CACHE. Every successful read, an empty one too, is written atomically to
# state/lead-authority/globs-<owner_name>.cache. It is read ONLY when the GET
# fails (an outage, a 404 from a worker without the route, a body whose rows is
# not an array, no jobs client loaded), and only while it is younger than the
# settings row lead_protected_paths_cache_max_s (DB-driven; at least 60, code
# fallback 86400 s). An older cache file, of any content, is rc 2: a hold, never
# "not governed".
# NO CACHE FILE (BH-6695). A failed read with no cache file at all asks the
# seed file. A repo with a seed line is governed: rc 2, a hold. A repo with no
# seed line (a commented line does not count) has never been governed on this
# host: rc 0 with no globs, LA_GLOBS_SRC `none (rows unreadable; no seed line,
# no cache)`, and no cache file is written. A seed file that cannot be read is
# rc 2 for every repo: nobody can tell which repos it names. So an outage holds
# the governed repos and leaves every other fleet repo free to merge. A repo
# whose rows were added in the console and that must stay held on a host that
# never read it needs a seed line.
# THE MEMO (BH-6695). Every answer of _la_db_globs (rc 0 or rc 2) is kept for
# the rest of the process, keyed by the lowercased slug: one GET of the rows per
# repo per process. A $(...) subshell reads the memo of its parent but cannot
# write it back; a child process reads fresh. A row added in the console governs
# the next process. la_memo_reset forgets every entry of this shell.
# THE SEED FLOOR (BH-4148 review). catalog/lead-protected-paths.seed.tsv
# (<owner/repo><TAB><glob>, the globs the deleted TSV held) is what
# bin/lead-protected-paths-seed.sh PUTs. Until a glob of it has been DECIDED in
# the DB, meaning a row for it exists, live or removed (the GET asks all=1), it
# stays protected. So an unseeded table, a partial seed or a D1 reset holds
# those paths instead of silently ungoverning them, and a console remove
# still un-protects one, because the removed row is a decision. Once every
# glob has a row, the file changes no answer. A missing file is no floor.
# The file is read under the harness root ($HARNESS, else $H). With no root (the
# lead's Mac, through verdict-status.sh) it is read next to this lib, at
# ../../catalog/. A set root never falls back to the lib's tree.
# What a protected path does depends on THE MODE (BH-4145), the settings row
# lead_authority_mode.<owner>.<name>, else the global lead_authority_mode:
#   lane   (the default: neither row exists) — a protected hit is REPORTED, not
#          withheld: rc 0 with LA_PROTECTED_HIT=1, LA_PROTECTED_PATHS and a
#          reason ending `cleared to merge on the lead verdict (lead_authority_mode=lane)`,
#          so the lane MERGE publishes. The authority row is not read.
#   human  the rule before BH-4145: two things take the lane's authority away
#          for one PR head, and then a `--source human` verdict is the one
#          writer that publishes success: 1. the PR touches a protected path; 2. the repo's authority
#          row lead_authority.<owner>.<name> is `human` (an operator) or
#          `human:precision` (bin/lead-review-precision.sh, after a precision
#          drop). No authority row, or `lane`, leaves the lane authoritative.
#          lead_authority.<owner>.<name> only bites under this mode.
#   An unreadable mode row, or a value other than lane|human after trimming and
#   lowercasing, is rc 2 (hold), never coerced to lane.
#   Set it: bin/jobs-client.sh setting-set lead_authority_mode[.<owner>.<name>] lane|human
# A repo with no live rows is not governed at all: it costs the one GET of its
# rows and no other read (not even the mode row).
#
# la_decide <owner/repo> <pr> <head-sha> <lead|conductor|human>
#   rc 0  this writer may publish success. Under lane, LA_PROTECTED_HIT=1 when
#         the PR touches a protected path (empty otherwise), and
#         LA_PROTECTED_PATHS names up to five of them (`, +N more`).
#   rc 1  (mode human only) a human verdict is required; LA_REASON names the
#         protected path(s), or says the lane authority is revoked.
#   rc 2  could not decide; LA_REASON says what was unreadable. Callers publish
#         nothing on rc 2.
# _la_mode <owner/repo>   LA_MODE (lane|human) and LA_MODE_SRC; rc 2 unreadable.
#   source=human is rc 0 with no read. A BLOCK is never asked: failure is the
#   safe direction and any writer may publish it. For source=conductor a
#   standing human MERGE / MERGE-WITH-NOTES on this exact head is rc 0 (a human
#   already cleared it). The PR's files are read over REST (filename AND
#   previous_filename, so a rename or delete out of a protected path counts),
#   then its head is read again: a head that moved during the read is rc 2, so
#   the answer is bound to the sha being published.
# la_scope <owner/repo>   rc 0 governed (live rows), 1 not (a successful empty
#   answer), 2 the rows are unreadable (worker down and no fresh cache).
# la_globs <owner/repo>   the globs in force, one per line (rc 2 = unreadable).
# _la_db_globs <owner/repo> — runs in the caller's shell: LA_GLOBS (the globs,
#   one per line, may be empty: live rows plus the undecided seed floor),
#   LA_GLOBS_FLOOR (the floor part alone) and LA_GLOBS_SRC (`db`,
#   `cache <path>`, or `none (...)` for an unreadable, ungoverned repo); rc 0
#   read or not governed, rc 2 unreadable. Memoized per process (THE MEMO).
# la_memo_reset — forget every memo entry of this shell.
# la_human_needed <owner/repo> <pr> <head> <reason> <lane> — under mode lane,
#   rc 0 with no beat and no marker. Under human, or an unreadable mode, ONE warn beat per
#   head naming the command that publishes the status, deduped by
#   state/lead-authority/human-needed-<owner_name>-<pr>-<sha12>, written only
#   after lane-alert.sh returned 0. While the head still waits it beats again
#   once the marker is older than LA_HUMAN_REBEAT_S (default 86400, BH-3777:
#   the one beat on #3753/#3758 was buried among 270 open alerts), under an id
#   suffixed -r<YYYYMMDD> (lane-alert only counts a repeat of an open id), and
#   the marker is re-stamped only after that send returned 0.
#
# Bash 3.2 safe (the lead's Mac sources it through verdict-status.sh): no arrays,
# no mapfile, no ${x,,}. tests/lead-authority.bh-3683-test.sh pins it.
# gh-rest: no-graphql

_la_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _la_key <owner/repo> — `owner.name`, lowercased; rc 2 when the longest key
# built on it (lead_authority_mode.<owner>.<name>) would not be a legal settings key.
_la_key() {
  local k
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  k=$(printf '%s' "$1" | tr 'A-Z/' 'a-z.')
  [ $(( ${#k} + 20 )) -le 64 ] || return 2
  printf '%s' "$k"
}

# _la_match <path> <glob> — `**` reads as `*`, and a bash `*` already crosses `/`.
_la_match() {
  local p="$1" g="$2"
  g="${g//\*\*/*}"
  # shellcheck disable=SC2053
  [[ $p == $g ]]
}

# _la_cache_max — seconds a last-good cache may answer for: the settings row
# lead_protected_paths_cache_max_s when it is digits and at least 60, else 86400.
_la_cache_max() {
  local v=""
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get lead_protected_paths_cache_max_s 2>/dev/null | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) v=86400 ;; esac
  [ "$v" -ge 60 ] 2>/dev/null || v=86400
  printf '%s' "$v"
}

# _la_seed_file — the seed file's path: under the harness root, else (no root)
# next to this lib. rc 1 when there is no path at all.
_la_seed_file() {
  local root f
  root=$(_la_root)
  if [ -n "$root" ]; then
    f="$root/catalog/lead-protected-paths.seed.tsv"
  else
    f="${BASH_SOURCE[0]:-}"
    case "$f" in */*) f="${f%/*}" ;; '') return 1 ;; *) f=. ;; esac
    f="$f/../../catalog/lead-protected-paths.seed.tsv"
  fi
  printf '%s' "$f"
}

# _la_seed_floor <owner/repo, lowercased> <decided globs> — the seed file's
# globs for the repo that have no row in the DB yet, one per line.
_la_seed_floor() {
  local f
  f=$(_la_seed_file) || return 0
  [ -r "$f" ] || return 0
  printf '%s\n' "$2" | awk -F'\t' -v r="$1" '
    FNR == NR { if (NF) seen[$0] = 1; next }
    /^#/ || NF != 2 || $2 ~ /[[:space:]]/ { next }
    tolower($1) == r && !($2 in seen) && !out[$2]++ { print $2 }' - "$f" 2>/dev/null
}

# _la_memo_var <owner/repo, lowercased> — the memo's variable prefix for the
# slug. `_` is encoded first, so two slugs never share a prefix.
_la_memo_var() {
  printf '_LA_MEMO_%s' "$(printf '%s' "$1" | sed 's/_/_5f/g; s/\./_2e/g; s/-/_2d/g; s/\//_2f/g')"
}

la_memo_reset() {
  local k
  for k in ${_LA_MEMO_KEYS:-}; do unset "${k}_RC" "${k}_G" "${k}_F" "${k}_S"; done
  _LA_MEMO_KEYS=""
}

_la_db_globs() {
  local slug k v rc=0
  LA_GLOBS=""; LA_GLOBS_SRC=""; LA_GLOBS_FLOOR=""
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  slug=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  k=$(_la_memo_var "$slug")
  v="${k}_RC"
  if [ -n "${!v:-}" ]; then
    v="${k}_G"; LA_GLOBS="${!v}"
    v="${k}_F"; LA_GLOBS_FLOOR="${!v}"
    v="${k}_S"; LA_GLOBS_SRC="${!v}"
    v="${k}_RC"; return "${!v}"
  fi
  _la_read_globs "$slug" || rc=$?
  printf -v "${k}_RC" '%s' "$rc"
  printf -v "${k}_G" '%s' "$LA_GLOBS"
  printf -v "${k}_F" '%s' "$LA_GLOBS_FLOOR"
  printf -v "${k}_S" '%s' "$LA_GLOBS_SRC"
  _LA_MEMO_KEYS="${_LA_MEMO_KEYS:+$_LA_MEMO_KEYS }$k"
  return "$rc"
}

# _la_read_globs <owner/repo, lowercased> — the read behind the memo: the GET,
# else the cache file, else the no-cache rule (NO CACHE FILE).
_la_read_globs() {
  local slug="$1" on root c="" resp rc=1 g d tmp max f
  on=$(printf '%s' "$slug" | tr '/' '_')
  root=$(_la_root)
  [ -z "$root" ] || c="$root/state/lead-authority/globs-$on.cache"
  if command -v _jobs_req >/dev/null 2>&1; then
    rc=0; resp=$(_jobs_req GET "/api/lead-protected-paths?repo=$slug&all=1" 2>/dev/null) || rc=$?
  fi
  if [ "$rc" = 0 ] && printf '%s' "$resp" | jq -e '.rows | type == "array"' >/dev/null 2>&1 \
    && g=$(printf '%s' "$resp" | jq -r --arg r "$slug" '.rows[] | select(.removed_at == null)
         | select((.repo // "" | ascii_downcase) == $r) | .glob
         | select(type == "string" and length > 0 and (test("\\s") | not))' 2>/dev/null) \
    && d=$(printf '%s' "$resp" | jq -r --arg r "$slug" '.rows[] | select((.repo // "" | ascii_downcase) == $r)
         | .glob | select(type == "string")' 2>/dev/null); then
    LA_GLOBS_FLOOR=$(_la_seed_floor "$slug" "$d")
    LA_GLOBS=$(printf '%s\n%s\n' "$g" "$LA_GLOBS_FLOOR" | awk 'NF && !seen[$0]++'); LA_GLOBS_SRC=db
    # A failed cache write is ignored: the worker answered.
    if [ -n "$c" ] && mkdir -p "${c%/*}" 2>/dev/null && tmp=$(mktemp "${c%/*}/.globs.XXXXXX" 2>/dev/null); then
      { [ -z "$LA_GLOBS" ] || printf '%s\n' "$LA_GLOBS"; } > "$tmp" 2>/dev/null && mv -f "$tmp" "$c" 2>/dev/null || rm -f "$tmp"
    fi
    return 0
  fi
  if [ -n "$c" ] && [ -f "$c" ]; then
    max=$(_la_cache_max)
    # find -mmin, not stat: stat's flags differ between GNU and BSD (the Mac).
    [ -n "$(find "$c" -mmin -$((max / 60)) 2>/dev/null)" ] || return 2
    LA_GLOBS=$(awk 'NF' "$c" 2>/dev/null) || return 2
    LA_GLOBS_SRC="cache $c"
    return 0
  fi
  # NO CACHE FILE: a seed line (or an unreadable seed file) holds; else not governed.
  f=$(_la_seed_file) && [ -r "$f" ] || return 2
  [ -z "$(_la_seed_floor "$slug" "")" ] || return 2
  LA_GLOBS_SRC="none (rows unreadable; no seed line, no cache)"
  return 0
}

la_globs() {
  _la_db_globs "$1" || return 2
  [ -z "$LA_GLOBS" ] || printf '%s\n' "$LA_GLOBS"
}

la_scope() {
  _la_db_globs "$1" || return 2
  [ -n "$LA_GLOBS" ]
}

# _la_authority <owner/repo> — the authority row's value into LA_AUTH (`lane`
# when there is no row) and LA_AUTH_SRC (row|no row). rc 2 unreadable.
_la_authority() {
  local k v rc=0
  LA_AUTH=""; LA_AUTH_SRC=""
  k=$(_la_key "$1") || return 2
  command -v setting_get >/dev/null 2>&1 || return 2
  v=$(setting_get "lead_authority.$k") || rc=$?
  case "$rc" in
    0) LA_AUTH=$(printf '%s' "$v" | tr -d '[:space:]'); LA_AUTH_SRC=row ;;
    2) LA_AUTH=lane; LA_AUTH_SRC="no row" ;;
    *) return 2 ;;
  esac
}

# _la_mode <owner/repo> — BH-4145: the lead_authority_mode row in force into
# LA_MODE (`lane` when neither row exists) and LA_MODE_SRC (the key read, or
# `no row`). The per-repo row lead_authority_mode.<owner>.<name> beats the
# global lead_authority_mode. Trimmed and lowercased once, here. rc 2 when a
# read fails or the value is not exactly lane|human (LA_MODE keeps the value).
_la_mode() {
  local k v rc=0
  LA_MODE=""; LA_MODE_SRC=""
  k=$(_la_key "$1") || return 2
  command -v setting_get >/dev/null 2>&1 || return 2
  v=$(setting_get "lead_authority_mode.$k") || rc=$?
  case "$rc" in
    0) LA_MODE_SRC="lead_authority_mode.$k" ;;
    2) rc=0; v=$(setting_get lead_authority_mode) || rc=$?
       case "$rc" in
         0) LA_MODE_SRC=lead_authority_mode ;;
         2) v=lane; LA_MODE_SRC="no row" ;;
         *) return 2 ;;
       esac ;;
    *) return 2 ;;
  esac
  LA_MODE=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr 'A-Z' 'a-z')
  case "$LA_MODE" in lane|human) return 0 ;; *) return 2 ;; esac
}

# _la_files <owner/repo> <pr> — every filename and previous_filename of the PR,
# one per line. rc 2 on a failed page, a non-array page or a full 30th page.
_la_files() {
  local f page n grc
  command -v gh_rest >/dev/null 2>&1 || return 2
  f=$(mktemp "${TMPDIR:-/tmp}/lead-authority.XXXXXX") || return 2
  for page in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    grc=0; GH_ETAG=0 gh_rest GET "repos/$1/pulls/$2/files?per_page=100&page=$page" > "$f" 2>/dev/null || grc=$?
    if [ "$grc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then rm -f "$f"; return 2; fi
    jq -r '.[] | .filename, (.previous_filename // empty)' "$f" 2>/dev/null || { rm -f "$f"; return 2; }
    n=$(jq length "$f" 2>/dev/null)
    [ "${n:-0}" -lt 100 ] && { rm -f "$f"; return 0; }
  done
  rm -f "$f"
  return 2
}

la_decide() {
  local slug="${1:-}" pr="${2:-}" head="${3:-}" source="${4:-}" globs files line g hit="" n=0 live f grc
  LA_REASON=""; LA_PROTECTED_HIT=""; LA_PROTECTED_PATHS=""
  case "$source" in human) LA_REASON="a human verdict"; return 0 ;; lead|conductor) ;; *) LA_REASON="unknown source '$source'"; return 2 ;; esac
  head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  # One read of the rows per decision: the scope and the match both use it.
  _la_db_globs "$slug" || { LA_REASON="the protected paths of $slug could not be read (jobs worker, no cache younger than $(_la_cache_max)s)"; return 2; }
  if [ -z "$LA_GLOBS" ]; then
    case "$LA_GLOBS_SRC" in none*) LA_REASON="not governed (rows unreadable; no seed line, no cache)" ;; *) LA_REASON="not governed" ;; esac
    return 0
  fi
  globs="$LA_GLOBS"
  if [ "$source" = conductor ] && command -v vd_standing >/dev/null 2>&1; then
    line=$(vd_standing "$slug" "$pr" "$head" 2>/dev/null) || line=""
    if [ "$(printf '%s' "$line" | cut -f2)" = human ]; then
      case "$(printf '%s' "$line" | cut -f1)" in
        MERGE|MERGE-WITH-NOTES) LA_REASON="a human verdict stands on ${head:0:12}"; return 0 ;;
      esac
    fi
  fi
  _la_mode "$slug" || { LA_REASON="the mode row ${LA_MODE_SRC:-lead_authority_mode[.$(_la_key "$slug")]} could not be read or reads '$LA_MODE', not lane|human"; return 2; }
  # Under lane the authority row is not even read: it revokes nothing.
  if [ "$LA_MODE" = human ]; then
    _la_authority "$slug" || { LA_REASON="the authority row lead_authority.$(_la_key "$slug") could not be read"; return 2; }
    case "$LA_AUTH" in
      lane) ;;
      human|human:precision) LA_REASON="lane authority revoked (lead_authority.$(_la_key "$slug") = $LA_AUTH)"; return 1 ;;
      *) LA_REASON="the authority row lead_authority.$(_la_key "$slug") reads '$LA_AUTH', not lane|human|human:precision"; return 2 ;;
    esac
  fi
  files=$(_la_files "$slug" "$pr") || { LA_REASON="the files of $slug#$pr could not be read whole"; return 2; }
  f=$(mktemp "${TMPDIR:-/tmp}/lead-authority.XXXXXX") || { LA_REASON="mktemp failed"; return 2; }
  grc=0; GH_ETAG=0 gh_rest GET "repos/$slug/pulls/$pr" > "$f" 2>/dev/null || grc=$?
  live=""; [ "$grc" = 0 ] && live=$(jq -r '.head.sha // ""' "$f" 2>/dev/null | tr 'A-F' 'a-f')
  rm -f "$f"
  [ -n "$live" ] || { LA_REASON="the head of $slug#$pr could not be re-read after its files"; return 2; }
  [ "$live" = "$head" ] || { LA_REASON="head moved during the file read (${live:0:12}, not ${head:0:12})"; return 2; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      if _la_match "$line" "$g"; then
        n=$((n + 1))
        [ "$n" -le 5 ] && hit="${hit:+$hit, }$line"
        break
      fi
    done <<EOF
$globs
EOF
  done <<EOF
$(printf '%s\n' "$files" | awk 'NF && !seen[$0]++')
EOF
  if [ "$n" -gt 0 ]; then
    [ "$n" -gt 5 ] && hit="$hit, +$((n - 5)) more"
    if [ "$LA_MODE" = lane ]; then
      LA_PROTECTED_HIT=1; LA_PROTECTED_PATHS="$hit"
      LA_REASON="touches protected paths: $hit; cleared to merge on the lead verdict (lead_authority_mode=lane)"
      return 0
    fi
    LA_REASON="touches protected paths: $hit"
    return 1
  fi
  LA_REASON="no protected path"
  return 0
}

la_human_needed() {
  local slug="$1" pr="$2" head="$3" reason="$4" lane="$5" root on mark
  root=$(_la_root)
  [ -n "$root" ] || return 1
  # BH-4145: under lane nobody is asked. An unreadable mode still pages.
  if _la_mode "$slug" && [ "$LA_MODE" = lane ]; then return 0; fi
  on=$(printf '%s' "$slug" | tr 'A-Z/' 'a-z_')
  mark="$root/state/lead-authority/human-needed-$on-$pr-${head:0:12}"
  local id="lead-human-needed-$on-$pr-${head:0:12}" again="" every
  if [ -e "$mark" ]; then
    every="${LA_HUMAN_REBEAT_S:-86400}"
    case "$every" in ''|*[!0-9]*) every=86400 ;; esac
    # find -mmin, not stat: stat's flags differ between GNU and BSD (the Mac).
    [ -n "$(find "$mark" -mmin +$((every / 60)) 2>/dev/null)" ] || return 0
    id="$id-r$(date -u +%Y%m%d)"; again="still waiting: "
  fi
  "$root/bin/lane-alert.sh" --severity warn --id "$id" "$lane" \
    "$again$slug#$pr @${head:0:12} needs a human verdict ($reason): a human verdict publishes lead-verdict: bin/lead-verdict.sh post $slug $pr $head MERGE --source human; https://github.com/$slug/pull/$pr" \
    >/dev/null 2>&1 || return 1
  mkdir -p "${mark%/*}" 2>/dev/null && touch "$mark" 2>/dev/null
  return 0
}
