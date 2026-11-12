#!/bin/bash
# bin/lib/migration-hold.sh — A MIGRATION NOT IN PRODUCTION IS NOT READY
# (BH-7785). Sourced by bin/merge-conductor.d/bh-7785-migration-hold.sh, never
# executed. No `exit`, no side effect at source time, safe under `set -u`.
#
# The merge conductor asks this lib, for a READY PR, whether the PR adds a
# migration file that production has not applied yet. The answer lands in four
# globals (no subshell, so a GitHub read keeps its GH_REST_STATUS):
#   MMH_VERDICT  none | applied | missing | unreadable | lane | off
#   MMH_NAMES    the migration names the verdict is about, space-separated
#   MMH_DETAIL   one line, no tab or newline
#   MMH_SRC      probed | cached
#
# Settings rows (DB-driven, never a constant in code):
#   mc_migration_hold.globs.<project>       space-separated path globs; no row = off
#   mc_migration_hold.apply_lane.<project>  a lane that applies migrations before
#                                           it merges. Set: the conductor still asks
#                                           the ledger (BH-9368). Every file at the
#                                           head checksum = applied; anything else =
#                                           lane (leave the PR to that lane, no alert)
#   mc_migration_hold.cache_s               answer cache window (default 300)
#   mc_migration_hold.probe_timeout_s       probe curl -m, 1..60 (default 15)
# The probe host and token come from env/<project>.env (DATA_LANE_APP_BASE,
# MIGRATION_TOKEN), the same as dlp_probe in bin/lib/data-lane-pending.sh: the
# host the token is sent to is never a settings row.
#
# The root comes from HARNESS or H only (D43). With neither set, every read
# answers "unreadable", never "applied".
#
# THE LEDGER MATCH IS NAME PLUS CHECKSUM (BH-9368). A ledger row whose name is
# the file's and that carries a `checksum` matches only when the checksum is
# the sha256 of the PR's head file (mmh_head_sums, the same sum dlp_probe and
# the migration lane compare). Another checksum is `changed`: the file counts as
# missing. A row with no checksum is a name match, as before. Under an apply
# lane the match is strict: every file needs a row at the head checksum.

MMH_CACHE_S_DEFAULT=300
MMH_TIMEOUT_DEFAULT=15
MMH_VERDICT=""; MMH_NAMES=""; MMH_DETAIL=""; MMH_SRC=""
# mmh_decide sets these for mmh_probe: one `name<TAB>path` line per migration
# file, the repo and head the paths are read at, and 1 for the strict match.
MMH_PATHS=""; MMH_SLUG=""; MMH_HEAD=""; MMH_STRICT=0

_mmh_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_mmh_log() { command -v mc_log >/dev/null 2>&1 && mc_log "$*"; return 0; }
_mmh_now() { printf '%s' "${MMH_NOW:-$(date -u +%s)}"; }
_mmh_flat() { printf '%s' "$*" | tr '\t\r\n' '   ' | cut -c1-400; }

# _mmh_ensure_client — setting_get, the same way _mg_ensure_client does it.
_mmh_ensure_client() {
  local h pf
  command -v setting_get >/dev/null 2>&1 && return 0
  h=$(_mmh_root)
  [ -n "$h" ] && [ -r "$h/bin/jobs-client.sh" ] || return 1
  pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
  # shellcheck disable=SC1091
  . "$h/bin/jobs-client.sh" >/dev/null 2>&1 || true
  [ "$pf" = off ] && set +o pipefail
  command -v setting_get >/dev/null 2>&1
}

# _mmh_int <key> <default> <min> <max> — an integer knob; anything else is the default.
_mmh_int() {
  local v
  v=$(setting_get "$1" 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) printf '%s' "$2"; return 0 ;; esac
  if [ "$v" -lt "$3" ] || [ "$v" -gt "$4" ]; then printf '%s' "$2"; return 0; fi
  printf '%s' "$v"
}

# mmh_glob_ok <glob> — rc 0 for a glob this lib can match: relative, each
# segment [A-Za-z0-9_.*-]+, no `.`/`..` segment, no `**`.
mmh_glob_ok() {
  local g="${1:-}" s
  [ -n "$g" ] || return 1
  case "$g" in /*|*/|*//*|*'**'*) return 1 ;; esac
  [[ $g =~ ^[A-Za-z0-9_.*/-]+$ ]] || return 1
  local IFS=/
  for s in $g; do
    case "$s" in ''|.|..) return 1 ;; esac
  done
  return 0
}

# mmh_glob_match <glob> <path> — segment-wise: the same number of segments, and
# each path segment matches its glob segment. `*` never crosses `/`.
mmh_glob_match() {
  local g="${1:-}" p="${2:-}" i
  local -a gs ps
  IFS=/ read -r -a gs <<<"$g"
  IFS=/ read -r -a ps <<<"$p"
  [ "${#gs[@]}" -gt 0 ] && [ "${#gs[@]}" = "${#ps[@]}" ] || return 1
  for ((i = 0; i < ${#gs[@]}; i++)); do
    # shellcheck disable=SC2254 # the glob segment is a pattern on purpose
    case "${ps[$i]}" in ${gs[$i]}) ;; *) return 1 ;; esac
  done
  return 0
}

# mmh_name <path> — the migration's name: strip /migration.sql (the Prisma
# folder shape), take the last segment, strip .sql.
mmh_name() {
  local p="${1:-}"
  case "$p" in */migration.sql) p="${p%/migration.sql}" ;; esac
  p="${p##*/}"
  printf '%s\n' "${p%.sql}"
}

# mmh_globs <project> — the valid globs, one per line.
#   rc 0 gated; rc 2 off (no row, empty, or every glob invalid); rc 1 unreadable.
mmh_globs() {
  local p="${1:-}" v rc=0 g n=0 nf=1
  case "$p" in ''|*[!a-z0-9_.-]*) return 2 ;; esac
  _mmh_ensure_client || return 1
  v=$(setting_get "mc_migration_hold.globs.$p") || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  [[ $- == *f* ]] && nf=0
  set -f
  for g in $v; do
    if mmh_glob_ok "$g"; then printf '%s\n' "$g"; n=$((n + 1))
    else _mmh_log "migration hold: $p glob '$(_mmh_flat "$g")' is not valid (relative, [A-Za-z0-9_.*-] segments, no ** or ..); dropped"; fi
  done
  [ "$nf" = 1 ] && set +f
  [ "$n" -gt 0 ] || return 2
  return 0
}

# mmh_applied_has <body-file> <name> — rc 0 when an object in .applied[] has a
# .filename whose mmh_name is <name> (exact, case-sensitive).
mmh_applied_has() {
  local f
  while IFS= read -r f; do
    [ "$(mmh_name "$f")" = "${2:-}" ] && return 0
  done < <(jq -r '.applied[]? | select(type == "object") | .filename | strings' "${1:-/dev/null}" 2>/dev/null)
  return 1
}

# mmh_applied_sums <body-file> <name> — the .checksum of every object in
# .applied[] whose .filename has mmh_name <name>, one per line (`-` for a row
# with no checksum). rc 1 when no row has the name.
mmh_applied_sums() {
  local f c hit=1
  while IFS=$'\t' read -r f c; do
    [ "$(mmh_name "$f")" = "${2:-}" ] || continue
    hit=0; printf '%s\n' "${c:--}"
  done < <(jq -r '.applied[]? | select(type == "object" and (.filename | type) == "string")
                  | [.filename, ((.checksum // "") | tostring)] | @tsv' "${1:-/dev/null}" 2>/dev/null)
  return "$hit"
}

# mmh_head_sums <slug> <head> <path>... — one `name<TAB>sha256` line per path:
# the sha256 of the raw bytes of the file at <head>, read through gh_rest
# (contents API, base64). rc 1 when any file cannot be read: no gh_rest, a
# failed read, no base64 content (a file over 1 MB), or a bad sum. MMH_SUMS_WHY
# names the first failure.
mmh_head_sums() {
  local slug="${1:-}" head="${2:-}" p t rc sum out=""
  shift 2
  MMH_SUMS_WHY=""
  command -v gh_rest >/dev/null 2>&1 || { MMH_SUMS_WHY="no GitHub reader (gh_rest)"; return 1; }
  t=$(mktemp "${TMPDIR:-/tmp}/mmh-sum.XXXXXX") || { MMH_SUMS_WHY="no temp file"; return 1; }
  for p in "$@"; do
    rc=0; gh_rest GET "repos/$slug/contents/$p?ref=$head" > "$t" || rc=$?
    if [ "$rc" != 0 ]; then MMH_SUMS_WHY="$p is not readable at ${head:0:12} (HTTP ${GH_REST_STATUS:-000})"; rm -f "$t"; return 1; fi
    if ! jq -e '.encoding == "base64" and (.content | type) == "string" and (.content | length) > 0' "$t" >/dev/null 2>&1; then
      MMH_SUMS_WHY="$p at ${head:0:12} has no base64 content"; rm -f "$t"; return 1
    fi
    sum=$(jq -r '.content' "$t" | base64 -d 2>/dev/null | sha256sum | cut -c1-64)
    [[ $sum =~ ^[0-9a-f]{64}$ ]] || { MMH_SUMS_WHY="$p at ${head:0:12} did not decode"; rm -f "$t"; return 1; }
    out="${out}$(mmh_name "$p")"$'\t'"$sum"$'\n'
  done
  rm -f "$t"
  printf '%s' "$out"
  return 0
}

# mmh_probe <project> <name>... — one GET of the app's migration status. Sets
# MMH_VERDICT applied | missing | unreadable, MMH_NAMES (for missing: the
# absent ones) and MMH_DETAIL. The token rides a 0600 header file, never argv.
# With MMH_PATHS set (mmh_decide), a row that carries a checksum must equal the
# head file's sha256, and MMH_STRICT=1 needs that for every file. The head files
# are read only when a row with the name exists and a checksum is to be
# compared. A head file that cannot be read is `unreadable`.
mmh_probe() {
  local p="${1:-}" envd envf base tok t code to n miss="" chg="" sums="" need sumsok=1 hs rs rc
  shift
  MMH_NAMES="$*"
  envd="${HENV:-}"
  # The env dir comes from the one resolver (env-path-test): HARNESS_ENV_DIR,
  # then <root>/env, then /etc/harness/env. No resolver -> no env -> unreadable.
  if [ -z "$envd" ] && [ -n "$(_mmh_root)" ]; then
    command -v harness_env_dir >/dev/null 2>&1 || . "$(_mmh_root)/bin/lib/env-path.sh" 2>/dev/null
    command -v harness_env_dir >/dev/null 2>&1 && envd=$(harness_env_dir "$(_mmh_root)")
  fi
  envf="${envd:+$envd/$p.env}"
  base=$(sed -n 's/^DATA_LANE_APP_BASE=//p' "$envf" 2>/dev/null | sed -n '$p' | tr -d "\"' ")
  tok=$(sed -n 's/^MIGRATION_TOKEN=//p' "$envf" 2>/dev/null | sed -n '$p' | tr -d "\"' ")
  if [ -z "$base" ] || [ -z "$tok" ]; then
    MMH_VERDICT=unreadable; MMH_DETAIL="probe not configured: set DATA_LANE_APP_BASE and MIGRATION_TOKEN in env/$p.env"; return 0
  fi
  to=$(_mmh_int mc_migration_hold.probe_timeout_s "$MMH_TIMEOUT_DEFAULT" 1 60)
  t=$(mktemp -d "${TMPDIR:-/tmp}/mmh-probe.XXXXXX") || { MMH_VERDICT=unreadable; MMH_DETAIL="probe: no temp dir"; return 0; }
  ( umask 077; printf 'Authorization: Bearer %s\n' "$tok" > "$t/auth" )
  code=$(curl -sS -m "$to" -H @"$t/auth" -o "$t/body" -w '%{http_code}' "${base%/}/api/internal/migrations/status" 2>/dev/null) || code=000
  case "$code" in
    2??) ;;
    401|403) rm -rf "$t"; MMH_VERDICT=unreadable; MMH_DETAIL="probe unreadable: the migration token was refused (HTTP $code)"; return 0 ;;
    *) rm -rf "$t"; MMH_VERDICT=unreadable; MMH_DETAIL="probe unreadable: migrations/status answered HTTP ${code:-000}"; return 0 ;;
  esac
  if ! jq -e 'type == "object" and (.applied | type == "array")' "$t/body" >/dev/null 2>&1; then
    rm -rf "$t"; MMH_VERDICT=unreadable; MMH_DETAIL="probe unreadable: migrations/status did not answer a JSON applied list"; return 0
  fi
  if [ -z "$MMH_PATHS" ]; then
    for n in "$@"; do
      mmh_applied_has "$t/body" "$n" || miss="${miss:+$miss }$n"
    done
    rm -rf "$t"
    if [ -n "$miss" ]; then
      MMH_VERDICT=missing; MMH_NAMES="$miss"; MMH_DETAIL="not in the production migration ledger"
    else
      MMH_VERDICT=applied; MMH_DETAIL="every name is in the production migration ledger"
    fi
    return 0
  fi
  # Name plus checksum (BH-9368). Pass 1: is a head sum needed at all?
  need=0
  for n in "$@"; do
    rs=$(mmh_applied_sums "$t/body" "$n") || continue
    if [ "$MMH_STRICT" = 1 ] || grep -qv '^-$' <<<"$rs"; then need=1; fi
  done
  if [ "$need" = 1 ]; then
    # A plain command into a file, never $( ), so MMH_SUMS_WHY stays here.
    # shellcheck disable=SC2046 # one path per line, no spaces (mmh_glob_ok)
    mmh_head_sums "$MMH_SLUG" "$MMH_HEAD" $(cut -f2 <<<"$MMH_PATHS") > "$t/sums" || sumsok=0
    sums=$(cat "$t/sums" 2>/dev/null)
  fi
  for n in "$@"; do
    rc=0; rs=$(mmh_applied_sums "$t/body" "$n") || rc=$?
    if [ "$rc" != 0 ]; then miss="${miss:+$miss }$n"; continue; fi
    # A row with no checksum is a name match, unless the match is strict.
    if [ "$MMH_STRICT" != 1 ] && grep -qx -- '-' <<<"$rs"; then continue; fi
    if [ "$sumsok" != 1 ]; then
      rm -rf "$t"; MMH_VERDICT=unreadable; MMH_NAMES="$*"; MMH_DETAIL="head file unreadable: ${MMH_SUMS_WHY:-no sum}"; return 0
    fi
    hs=$(awk -F'\t' -v n="$n" '$1 == n {print $2; exit}' <<<"$sums")
    [ -n "$hs" ] && grep -qxF -- "$hs" <<<"$rs" && continue
    miss="${miss:+$miss }$n"
    [ -n "$chg" ] || chg="$n applied at checksum $(grep -v '^-$' <<<"$rs" | head -1 | cut -c1-12), the PR's file is ${hs:0:12}"
  done
  rm -rf "$t"
  if [ -n "$miss" ]; then
    MMH_VERDICT=missing; MMH_NAMES="$miss"
    if [ -n "$chg" ]; then MMH_DETAIL="$chg"; else MMH_DETAIL="not in the production migration ledger"; fi
  else
    MMH_VERDICT=applied
    if [ "$need" = 1 ]; then MMH_DETAIL="every file is in the production migration ledger at the head checksum"
    else MMH_DETAIL="every name is in the production migration ledger"; fi
  fi
  return 0
}

_mmh_cache_dir() {
  local r; r=$(_mmh_root)
  if [ -n "${MC_STATE_DIR:-}" ]; then printf '%s/migration-hold' "$MC_STATE_DIR"
  elif [ -n "$r" ]; then printf '%s/state/merge-conductor/migration-hold' "$r"
  else return 1; fi
}
_mmh_cache_file() { local d; d=$(_mmh_cache_dir) || return 1; printf '%s/%s' "$d" "${1//[^A-Za-z0-9._-]/_}"; }

# mmh_cache_get <key> <head> <fp> <ttl> — rc 0 on a hit, and sets MMH_VERDICT,
# MMH_NAMES, MMH_DETAIL. A hit is the same head, the same fingerprint, a
# well-formed line and 0 <= age < ttl.
mmh_cache_get() {
  local f h e fp v n d x now
  f=$(_mmh_cache_file "${1:-}") || return 1
  [ -r "$f" ] || return 1
  IFS=$'\t' read -r h e fp v n d x < "$f" || return 1
  [ -z "${x:-}" ] && [ -n "${v:-}" ] && [ -n "${d:-}" ] || return 1
  [ "$h" = "${2:-}" ] && [ "$fp" = "${3:-}" ] || return 1
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  case "$v" in none|applied|missing|unreadable|lane) ;; *) return 1 ;; esac
  now=$(_mmh_now)
  [ $((now - e)) -ge 0 ] && [ $((now - e)) -lt "${4:-0}" ] || return 1
  [ "$n" = - ] && n=""
  [ "$d" = - ] && d=""
  MMH_VERDICT="$v"; MMH_NAMES="$n"; MMH_DETAIL="$d"
  return 0
}

# mmh_cache_put <key> <head> <fp> <verdict> <names> <detail> — one TSV line,
# written atomically. Each put prunes files older than 7 days (retention: the
# value of a line is one tick's answer).
mmh_cache_put() {
  local d f tmp
  d=$(_mmh_cache_dir) || return 1
  f=$(_mmh_cache_file "${1:-}") || return 1
  mkdir -p "$d" 2>/dev/null || return 1
  tmp=$(mktemp "$d/.put.XXXXXX" 2>/dev/null) || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${2:-}" "$(_mmh_now)" "${3:-}" "${4:-}" \
    "$(_mmh_flat "${5:--}")" "$(_mmh_flat "${6:--}")" > "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  find "$d" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null
  return 0
}

# mmh_files <slug> <num> <outfile> — the PR's ADDED paths, one per line, into
# <outfile>. rc 0 only on a complete list. A plain command into a file, never
# inside $( ), so GH_REST_STATUS stays in the caller's shell.
mmh_files() {
  local raw rc=0 total
  if ! command -v _gh_rest_list >/dev/null 2>&1; then
    [ -n "$(_mmh_root)" ] || return 75
    # shellcheck source=bin/lib/gh-rest-list.sh
    . "$(_mmh_root)/bin/lib/gh-rest-list.sh" 2>/dev/null
    command -v _gh_rest_list >/dev/null 2>&1 || return 75
  fi
  raw=$(mktemp "${TMPDIR:-/tmp}/mmh-files.XXXXXX") || return 75
  _gh_rest_list "${1:-}" "pulls/${2:-}/files" 1000 '{f: .filename, s: .status}' > "$raw" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$raw"; return "$rc"; fi
  total=$(jq 'length' "$raw" 2>/dev/null) || total=""
  case "$total" in ''|*[!0-9]*) rm -f "$raw"; return 75 ;; esac
  # 1000 rows is _gh_rest_list's hard stop: a list that long may be cut.
  [ "$total" -lt 1000 ] || { rm -f "$raw"; return 76; }
  jq -r '.[] | select(.s == "added") | .f | strings' "$raw" > "${3:-/dev/null}" 2>/dev/null || rc=75
  rm -f "$raw"
  return "$rc"
}

# _mmh_match_paths <globs> <files-file> — one `name<TAB>path` line per added
# path that a glob matches, the first path of each name only, in list order.
_mmh_match_paths() {
  local globs="$1" f g n names=" "
  while IFS= read -r f; do
    while IFS= read -r g; do
      if mmh_glob_match "$g" "$f"; then
        n=$(mmh_name "$f")
        case "$names" in *" $n "*) ;; *) names="$names$n "; printf '%s\t%s\n' "$n" "$f" ;; esac
        break
      fi
    done <<<"$globs"
  done < "${2:-/dev/null}"
}

# mmh_paths <project> <slug> <num> — sets MMH_PATHS (one `name<TAB>path` line
# per migration file the PR adds) without the ledger or the cache. rc 0 on a
# complete files list, rc 1 otherwise (MMH_PATHS empty). BH-9368: the
# WAIT_MIGRATION arm needs the paths on a tick whose mmh_decide was a cache hit.
mmh_paths() {
  local globs t rc=0
  MMH_PATHS=""
  globs=$(mmh_globs "${1:-}") || return 1
  t=$(mktemp "${TMPDIR:-/tmp}/mmh-added.XXXXXX") || return 1
  mmh_files "${2:-}" "${3:-}" "$t" || rc=$?
  [ "$rc" = 0 ] && MMH_PATHS=$(_mmh_match_paths "$globs" "$t")
  rm -f "$t"
  [ "$rc" = 0 ] && MMH_PATHS="${MMH_PATHS:+$MMH_PATHS$'\n'}"
  return "$rc"
}

# mmh_decide <project> <slug> <num> <key> <head> — the whole question. Sets
# MMH_VERDICT/NAMES/DETAIL/SRC. MMH_VERDICT=off: the project is not gated (no
# globs row, or the row is unreadable this tick) and nothing else was read.
mmh_decide() {
  local p="${1:-}" slug="${2:-}" num="${3:-}" key="${4:-}" head="${5:-}"
  local globs rc=0 lane="" fp ttl t names="" paths=""
  MMH_VERDICT=off; MMH_NAMES=""; MMH_DETAIL=""; MMH_SRC=""
  MMH_PATHS=""; MMH_SLUG="$slug"; MMH_HEAD="$head"; MMH_STRICT=0
  globs=$(mmh_globs "$p") || rc=$?
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) _mmh_log "migration hold: $p globs row unreadable this tick (setting_get rc $rc); not gated this tick"; return 0 ;;
  esac
  lane=$(setting_get "mc_migration_hold.apply_lane.$p" 2>/dev/null) || lane=""
  lane=$(printf '%s' "$lane" | tr -d '[:space:]')
  if [ -n "$lane" ] && ! [[ $lane =~ ^[a-z0-9._-]{1,48}$ ]]; then
    _mmh_log "migration hold: $p apply_lane '$(_mmh_flat "$lane")' is not a lane name; ignored, the conductor probes"
    lane=""
  fi
  fp=$(printf '%s\n%s\n' "$globs" "$lane" | sha256sum | cut -c1-12)
  ttl=$(_mmh_int mc_migration_hold.cache_s "$MMH_CACHE_S_DEFAULT" 0 86400)
  if mmh_cache_get "$key" "$head" "$fp" "$ttl"; then MMH_SRC=cached; return 0; fi
  MMH_SRC=probed
  t=$(mktemp "${TMPDIR:-/tmp}/mmh-added.XXXXXX") || { MMH_VERDICT=unreadable; MMH_DETAIL="files read: no temp file"; return 0; }
  rc=0; mmh_files "$slug" "$num" "$t" || rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$t"
    MMH_VERDICT=unreadable
    if [ "$rc" = 76 ]; then MMH_DETAIL="files read: the list reached 1000 files and may be cut"
    else MMH_DETAIL="files read failed (rc $rc, HTTP ${GH_REST_STATUS:-000})"; fi
    # Not cached: the next tick reads the files again.
    return 0
  fi
  paths=$(_mmh_match_paths "$globs" "$t")
  rm -f "$t"
  [ -n "$paths" ] && names=$(cut -f1 <<<"$paths" | paste -sd' ')
  MMH_PATHS="${paths:+$paths$'\n'}"
  if [ -z "$names" ]; then
    MMH_VERDICT=none; MMH_DETAIL="no added file matches the globs"
  elif [ -n "$lane" ]; then
    # AN APPLY LANE IS ASKED THE LEDGER TOO (BH-9368, project-6 #3726): every
    # file at the head checksum = applied. Any other answer leaves the PR to the
    # lane, as before, with what the ledger said.
    MMH_STRICT=1
    # shellcheck disable=SC2086 # names are space-separated words on purpose
    mmh_probe "$p" $names
    MMH_STRICT=0
    if [ "$MMH_VERDICT" != applied ]; then
      MMH_DETAIL="left to the $lane lane, which applies migrations before it merges (ledger: $MMH_DETAIL)"
      MMH_VERDICT=lane; MMH_NAMES="$names"
    fi
  else
    # shellcheck disable=SC2086 # names are space-separated words on purpose
    mmh_probe "$p" $names
  fi
  mmh_cache_put "$key" "$head" "$fp" "$MMH_VERDICT" "$MMH_NAMES" "$MMH_DETAIL" \
    || _mmh_log "migration hold: $key cache write failed; the next tick asks again"
  return 0
}
