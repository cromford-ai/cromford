# shellcheck shell=bash
# bin/lib/lane-run-inputs.sh — the hub-local inputs a lane reads, carried to a
# Fly lane machine and its writes carried back (BH-6128, BH-6047 part 5 of 5).
#
# A lane placed `fly` (bin/lib/lane-placement.sh) runs on a machine whose
# harness root has no builds/, state/ or logs/ of the hub. Only
# blocked-resolver is placed there today, and it reads hub files: its ladder
# records, build records, build notes, the conductor's hand-off lines, flags
# and fleet.conf. The hub publishes those as ONE snapshot per (lane, project)
# through the jobs worker (worker/jobs/src/routes/lane-snapshots.js); the
# machine fetches it before the run and posts back the files the run changed
# as a write-back row; the hub applies the write-backs with compare-and-set.
# Nothing here uses ssh. The inventory and its choices are in
# docs/notes/2026-10-12-BH-6128-blocked-resolver-offhub.md.
#
#   lri_paths <lane> <project> ro|rw
#       prints the allow-list, globs relative to the root. rw is the subset a
#       write-back may carry. Any lane but blocked-resolver prints nothing.
#   lri_member_ok <project> <relpath> [type] [ro|rw]
#       rc 0 when one archive member may be read (ro) or written back (rw).
#       type is the tar type letter: `-` (regular, the default) or `d`.
#   lri_publish <lane> <project>                                 (hub)
#       prints `published <sha12> <bytes>` or `unchanged <sha12> <bytes>`.
#       rc 3 = over lane_snapshot.max_bytes (prints `oversize <bytes>`),
#       rc 1 = any other failure. The previous generation stays on a failure.
#   lri_fetch <lane> <project> <dir>                             (machine)
#       overlays the snapshot and every pending write-back onto the root and
#       prints `inputs: snapshot <sha12> + <k> write-backs, age <s>s`.
#       rc 0 = done, or a lane with no inputs (nothing fetched). rc 1 = no
#       client, no snapshot (404) or a transport error. rc 2 = refused: the
#       root is a live harness, the snapshot is stale or truncated, a sha
#       does not match, or a member is outside the allow-list. On rc 1 or 2
#       the overlay is unchanged. <dir> is the contract's argument and is not
#       read: the overlay root is the harness root, because the lane reads
#       $H-relative paths.
#   lri_checkpoint <lane> <project>                              (machine)
#       posts the rw files changed since the last fetch or checkpoint as one
#       write-back. rc 0 = posted, or nothing changed (no request); rc 1 =
#       not posted (no manifest, no LANE_RUN_ID, too large, or a non-2xx).
#   lri_apply_pending <lane> <project>                           (hub)
#       applies the unapplied write-backs in id order and acks them. Prints
#       `applied=<n> conflicts=<c> rejected=<r>`; rc 1 = the list or the ack
#       failed (what was applied stays applied; a re-apply is a no-op).
#
# Formats. A snapshot is a deterministic tar.gz of the ro allow-list (sorted
# names, owner 0, gzip -n, mtimes kept: the lane sorts records with `ls -td`).
# A write-back is a tar.gz of the changed files plus control members:
# .lri/base.tsv (relpath TAB the sha256 the machine started from, or `-`),
# .lri/deletions (one relpath per line), .lri/visited.tsv (this project's row
# of state/blocked-resolver/.last-visited.tsv) and .lri/log-append (the bytes
# the run added to logs/<lane>.log).
#
# The settings rows lane_snapshot.max_age_s (1200), lane_snapshot.max_bytes
# (33554432) and lane_snapshot.builds_days (30) are the knobs; the numbers in
# brackets are the code fallbacks. The root is ${HARNESS:-${H:-}}. Defines
# functions only. Nothing runs on source.

LRI_PART_BYTES=1000000
LRI_B64_MAX=1400000
LRI_FILE_MAX=262144
LRI_LOG_APPEND_MAX=262144

_lri_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _lri_client — rc 0 when _jobs_req, _jobs_req_file and setting_get exist.
# Sources bin/jobs-client.sh when they do not, and restores pipefail, which the
# client switches on (the lib/lane-placement.sh _lp_client pattern).
_lri_client() {
  local root pf
  command -v _jobs_req >/dev/null 2>&1 && command -v _jobs_req_file >/dev/null 2>&1 \
    && command -v setting_get >/dev/null 2>&1 && return 0
  root=$(_lri_root)
  [ -n "$root" ] && [ -r "$root/bin/jobs-client.sh" ] || return 1
  pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
  # shellcheck source=bin/jobs-client.sh
  . "$root/bin/jobs-client.sh" >/dev/null 2>&1 || true
  [ "$pf" = off ] && set +o pipefail
  command -v _jobs_req >/dev/null 2>&1 && command -v _jobs_req_file >/dev/null 2>&1 \
    && command -v setting_get >/dev/null 2>&1
}

# _lri_setting <key> <fallback> — a positive integer settings row, else the
# fallback.
_lri_setting() {
  local v
  v=$(setting_get "$1" 2>/dev/null) || v=""
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*|0) v="$2" ;; esac
  printf '%s' "$v"
}

# _lri_fresh <age_s> <max_age_s> — rc 0 when a snapshot is fresh enough to run
# on: age <= max. Any non-number is stale.
_lri_fresh() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -le "$2" ]
}

_lri_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
_lri_name_ok() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }
_lri_state() { printf '%s/state/lane-run-inputs/%s/%s' "$(_lri_root)" "$1" "$2"; }

lri_paths() {
  local lane="${1:-}" p="${2:-}" mode="${3:-ro}"
  [ "$lane" = blocked-resolver ] && _lri_name_ok "$p" || return 0
  cat <<EOF
state/blocked-resolver/$p/**
state/blocked-resolver/rounds/$p-*
state/blocked-resolver/.tick-budget-$p
state/blocked-resolver/.saturation-$p.tsv
state/blocked-resolver/.saturated-project-$p
state/blocked-resolver/.untouched-$p
state/blocked-resolver/unmapped/*
state/blocked-resolver/unmapped-family/*
state/blocked-resolver/handoffs/**
state/blocked-resolver/.last-visited.tsv
builds/$p-<KEY>-*/<record file>
builds/pool-$p-<KEY>-*/<record file>
builds/fly-$p-<KEY>-*/<record file>
state/build-notes/$p/*
EOF
  [ "$mode" = rw ] && return 0
  cat <<EOF
state/build-queue/$p/*.json
state/merge-conductor/pr-state.tsv
logs/merge-conductor.log (hand-off lines only)
plans/$p-*/planned-files.txt
flags/*
fleet.conf
EOF
}

# _lri_record_file <name> — rc 0 for a file the lane reads or writes in a build
# record dir. Anything else in a record (transcripts, worktrees) stays out.
_lri_record_file() {
  case "$1" in
    RESULT|COMMENTED|REAPED|job.json|ticket-meta.json|plan.md|review.md|checks.txt) return 0 ;;
    reviewed-sha|carried-note.md|test-tamper*.txt|iron-law-accepted-*) return 0 ;;
    .blocked-resolver-*|.review-rescued|.adjudicate-noverdict-paged|.pruned) return 0 ;;
  esac
  return 1
}

# _lri_record_dir <project> <dirname> — rc 0 when <dirname> is a build record
# of <project>: <p>-, pool-<p>- or fly-<p>- and then an upper-case ticket key.
# `p10-BH-1-x` is not p1's, and `project-4-TK-1-x` is not project-4's.
_lri_record_dir() {
  local p="$1" d="$2" rest
  case "$d" in
    "pool-$p-"*) rest="${d#"pool-$p-"}" ;;
    "fly-$p-"*) rest="${d#"fly-$p-"}" ;;
    "$p-"*) rest="${d#"$p-"}" ;;
    *) return 1 ;;
  esac
  [[ $rest =~ ^[A-Z][A-Za-z0-9]*-[0-9]+(-|$) ]]
}

lri_member_ok() {
  local p="${1:-}" rel="${2:-}" type="${3:--}" mode="${4:-ro}" a b c rest
  _lri_name_ok "$p" || return 1
  # Absolute, `..`, empty segments and any character outside the set the
  # lane's own names use are refused before any pattern is read.
  case "$rel" in ''|/*|*//*|*/) return 1 ;; esac
  [[ $rel =~ ^[A-Za-z0-9._@+=,/-]+$ ]] || return 1
  case "/$rel/" in */../*|*/./*) return 1 ;; esac
  case "$type" in -|d) ;; *) return 1 ;; esac
  IFS=/ read -r a b c rest <<<"$rel"
  if [ "$type" = d ]; then
    # Directories ride only so a record dir keeps its mtime.
    [ "$a" = builds ] && [ -n "$b" ] && [ -z "$c" ] && _lri_record_dir "$p" "$b"
    return
  fi
  case "$rel" in
    "state/blocked-resolver/$p/"?*) return 0 ;;
    "state/blocked-resolver/rounds/$p-"*) _lri_leaf "$rel" state/blocked-resolver/rounds/; return ;;
    "state/blocked-resolver/.tick-budget-$p"|"state/blocked-resolver/.saturation-$p.tsv") return 0 ;;
    "state/blocked-resolver/.saturated-project-$p"|"state/blocked-resolver/.untouched-$p") return 0 ;;
    state/blocked-resolver/unmapped/*) _lri_leaf "$rel" state/blocked-resolver/unmapped/; return ;;
    state/blocked-resolver/unmapped-family/*) _lri_leaf "$rel" state/blocked-resolver/unmapped-family/; return ;;
    state/blocked-resolver/handoffs/?*) return 0 ;;
    state/blocked-resolver/.last-visited.tsv) return 0 ;;
    "state/build-notes/$p/"*) _lri_leaf "$rel" "state/build-notes/$p/"; return ;;
    builds/*) [ -n "$c" ] && [ -z "$rest" ] && _lri_record_dir "$p" "$b" && _lri_record_file "$c"; return ;;
  esac
  [ "$mode" = ro ] || return 1
  case "$rel" in
    "state/build-queue/$p/"*.json) _lri_leaf "$rel" "state/build-queue/$p/"; return ;;
    state/merge-conductor/pr-state.tsv|logs/merge-conductor.log|fleet.conf) return 0 ;;
    "plans/$p-"*/planned-files.txt) [ -z "$rest" ]; return ;;
    flags/*) [ -z "$c" ]; return ;;
  esac
  return 1
}

# _lri_leaf <relpath> <prefix> — rc 0 when <relpath> is <prefix> plus one
# non-empty name with no further `/`.
_lri_leaf() {
  local n="${1#"$2"}"
  [ -n "$n" ] && [ "$n" != "$1" ] && [[ $n != */* ]]
}

# _lri_list <project> ro|rw <days> — the allow-listed paths under the root, one
# per line, type letter TAB relpath, sorted. Record dirs older than <days> stay
# out (0 = no window); a file over LRI_FILE_MAX bytes stays out.
_lri_list() {
  local p="$1" mode="$2" days="$3" root d f rel age=()
  root=$(_lri_root)
  [ "$days" -gt 0 ] 2>/dev/null && age=(-mtime "-$days")
  (
    cd "$root" 2>/dev/null || exit 0
    for d in builds/"$p"-* builds/pool-"$p"-* builds/fly-"$p"-*; do
      [ -d "$d" ] && [ ! -L "$d" ] || continue
      lri_member_ok "$p" "$d" d || continue
      [ "${#age[@]}" = 0 ] || [ -n "$(find "$d" -maxdepth 0 "${age[@]}" 2>/dev/null)" ] || continue
      printf 'd\t%s\n' "$d"
      find "$d" -mindepth 1 -maxdepth 1 -type f -size -$((LRI_FILE_MAX + 1))c 2>/dev/null | sed 's#^#-\t#'
    done
    for f in state/blocked-resolver/"$p" state/blocked-resolver/rounds state/blocked-resolver/unmapped \
             state/blocked-resolver/unmapped-family state/blocked-resolver/handoffs state/build-notes/"$p"; do
      [ -d "$f" ] && find "$f" -type f -size -$((LRI_FILE_MAX + 1))c 2>/dev/null | sed 's#^#-\t#'
    done
    find state/blocked-resolver -maxdepth 1 -type f 2>/dev/null | sed 's#^#-\t#'
    if [ "$mode" = ro ]; then
      for f in state/build-queue/"$p" flags; do
        [ -d "$f" ] && find "$f" -maxdepth 1 -type f -size -$((LRI_FILE_MAX + 1))c 2>/dev/null | sed 's#^#-\t#'
      done
      find plans -mindepth 2 -maxdepth 2 -type f -name planned-files.txt -path "plans/$p-*" 2>/dev/null | sed 's#^#-\t#'
      for f in state/merge-conductor/pr-state.tsv fleet.conf; do [ -f "$f" ] && printf -- '-\t%s\n' "$f"; done
    fi
  ) | while IFS=$'\t' read -r d rel; do
    lri_member_ok "$p" "$rel" "$d" "$mode" && printf '%s\t%s\n' "$d" "$rel"
  done | LC_ALL=C sort -t$'\t' -k2,2 -u
}

# _lri_members <archive> — prints `<type> TAB <name>` per member, or rc 1 when
# the archive does not list. GNU tar's verbose listing starts with the type
# letter; the name list comes from the plain listing, in the same order.
_lri_members() {
  local names types
  names=$(tar -tzf "$1" 2>/dev/null) || return 1
  types=$(tar -tvzf "$1" 2>/dev/null | cut -c1) || return 1
  paste <(printf '%s\n' "$types") <(printf '%s\n' "$names") | awk -F'\t' 'NF == 2 && $2 != ""'
}

# _lri_validate <project> <archive> snapshot|writeback — rc 0 when every member
# passes lri_member_ok (ro for a snapshot, rw plus the .lri/ control members
# for a write-back). A trailing `/` on a directory member is dropped first.
_lri_validate() {
  local p="$1" f="$2" kind="$3" t n mode=ro bad=0 list
  [ "$kind" = writeback ] && mode=rw
  list=$(_lri_members "$f") || return 1
  [ -n "$list" ] || return 1
  while IFS=$'\t' read -r t n; do
    n="${n%/}"
    if [ "$kind" = writeback ]; then
      case "$n" in .lri) [ "$t" = d ] && continue ;; esac
      case "$n" in .lri/base.tsv|.lri/deletions|.lri/visited.tsv|.lri/log-append) [ "$t" = - ] && continue ;; esac
    fi
    lri_member_ok "$p" "$n" "$t" "$mode" || { bad=1; break; }
  done <<<"$list"
  [ "$bad" = 0 ] || return 1
  [ "$kind" = writeback ] || return 0
  # The control members name paths too: a deletion or a base line outside the
  # rw allow-list refuses the whole write-back. The visit ledger travels only
  # as .lri/visited.tsv, never as a file. base.tsv is parsed by _lri_base_line,
  # the same parser the hub apply uses, so no line passes here unread.
  tar -xzOf "$f" .lri/base.tsv 2>/dev/null | while IFS= read -r n || [ -n "$n" ]; do
    _lri_base_line "$p" "$n" || exit 1
  done || return 1
  tar -xzOf "$f" .lri/deletions 2>/dev/null | while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$n" != state/blocked-resolver/.last-visited.tsv ] && lri_member_ok "$p" "$n" - rw || exit 1
  done
}

# _lri_base_line <project> <line> — rc 0 when one .lri/base.tsv line is
# exactly `relpath TAB sha` (sha is 64 hex digits or `-`) and relpath is in
# the rw allow-list. Sets LRI_REL and LRI_BASE. The validator and the hub
# apply both parse base.tsv with this function only (BH-6128 security review:
# a leading TAB once read as an empty path here and as a real path there).
_lri_base_line() {
  local re=$'^([^\t]+)\t(-|[0-9a-f]{64})$'
  LRI_REL=""; LRI_BASE=""
  [[ ${2:-} =~ $re ]] || return 1
  LRI_REL="${BASH_REMATCH[1]}"; LRI_BASE="${BASH_REMATCH[2]}"
  [ "$LRI_REL" != state/blocked-resolver/.last-visited.tsv ] && lri_member_ok "$1" "$LRI_REL" - rw
}

# _lri_get <path> <out-file> — GET into a file (JOBS_HTTP survives). rc as
# _jobs_req: 0 2xx, 2 = 404, any other = failure.
_lri_get() { _jobs_req GET "$1" > "$2"; }

# _lri_b64_file <json-file> <out> — decode the .b64 field of an answer.
_lri_b64_file() { jq -j '.b64 // empty' "$1" 2>/dev/null | base64 -d > "$2" 2>/dev/null && [ -s "$2" ]; }

lri_publish() {
  local lane="${1:-}" p="${2:-}" root api tmp maxb days list sha bytes cur cur_at through n=0 part rc lk
  root=$(_lri_root)
  [ -n "$root" ] && [ -n "$(lri_paths "$lane" "$p" ro)" ] || return 1
  _lri_client || return 1
  maxb=$(_lri_setting lane_snapshot.max_bytes 33554432)
  days=$(_lri_setting lane_snapshot.builds_days 30)
  api="/api/lane-snapshots/$lane/$p"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lri-publish.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; trap - RETURN" RETURN
  # The apply lock is held from the file list to applied_through, so a hub
  # apply cannot land a write-back the tar lacks but the watermark covers.
  mkdir -p "$root/locks" 2>/dev/null
  exec {lk}>"$root/locks/lane-snapshot-$lane-$p.lock" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; exec $lk>&-; trap - RETURN" RETURN
  flock -w 10 "$lk" || return 1
  list=$(_lri_list "$p" ro "$days")
  printf '%s\n' "$list" | awk -F'\t' 'NF == 2 {print $2}' > "$tmp/list"
  mkdir -p "$tmp/x/logs"
  # The conductor's log rides as its hand-off lines only, with a fixed mtime,
  # so a busy log does not change the snapshot's sha.
  grep -F 'handed to bin/blocked-resolver.sh' "$root/logs/merge-conductor.log" 2>/dev/null \
    | tail -n 20000 > "$tmp/x/logs/merge-conductor.log"
  touch -d @0 "$tmp/x/logs/merge-conductor.log"
  grep -vx 'logs/merge-conductor.log' "$tmp/list" > "$tmp/list.files"
  tar --no-recursion --sort=name --owner=0 --group=0 --numeric-owner --format=gnu \
      -cf "$tmp/snap.tar" -C "$root" -T "$tmp/list.files" -C "$tmp/x" logs/merge-conductor.log 2>/dev/null || return 1
  gzip -n -c "$tmp/snap.tar" > "$tmp/snap.tgz" || return 1
  bytes=$(stat -c %s "$tmp/snap.tgz")
  if [ "$bytes" -gt "$maxb" ]; then printf 'oversize %s\n' "$bytes"; return 3; fi
  sha=$(_lri_sha "$tmp/snap.tgz")
  # applied_through is the newest write-back this hub tree already holds: the
  # last applied id, read from the unapplied list's lower edge.
  _lri_get "$api" "$tmp/cur.json"; rc=$?
  case "$rc" in 0|2) ;; *) return 1 ;; esac
  cur=""; [ "$rc" = 0 ] && cur=$(jq -r '.sha // empty' "$tmp/cur.json" 2>/dev/null)
  through=$(_lri_through "$lane" "$p" "$(jq -r '.applied_through // 0' "$tmp/cur.json" 2>/dev/null)") || return 1
  flock -u "$lk"
  cur_at="unchanged"
  if [ "$cur" != "$sha" ]; then
    cur_at="published"
    split -b "$LRI_PART_BYTES" -d -a 3 "$tmp/snap.tgz" "$tmp/part."
    for part in "$tmp"/part.*; do
      base64 -w0 "$part" > "$part.b64"
      jq -n --arg s "$sha" --rawfile b "$part.b64" '{sha:$s, b64:$b}' > "$part.json" || return 1
      _jobs_req_file PUT "$api/parts/$n" "$part.json" > /dev/null || return 1
      n=$((n + 1))
    done
  else
    n=$(jq -r '.parts' "$tmp/cur.json")
  fi
  _jobs_req POST "$api/commit" "$(jq -nc --arg s "$sha" --argjson n "$n" --argjson t "$through" \
    '{sha:$s, parts:$n, applied_through:$t}')" > /dev/null || return 1
  printf '%s %s %s\n' "$cur_at" "${sha:0:12}" "$bytes"
}

# _lri_through <lane> <project> <current applied_through> — the highest
# write-back id this hub tree already holds: one below the first unapplied id,
# else the larger of the id lri_apply_pending last acked and the current
# snapshot's applied_through. Never lower than the current one when nothing is
# pending, so a lost state file cannot replay old write-backs over newer files.
_lri_through() {
  local st first last cur="${3:-0}"
  st=$(_lri_state "$1" "$2")
  last=$(cat "$st/applied-through" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  [ "$cur" -le "$last" ] || last="$cur"
  first=$(_jobs_req GET "/api/lane-snapshots/$1/$2/writebacks" | jq -r '.writebacks[0].id // empty' 2>/dev/null)
  [ -n "${JOBS_HTTP:-}" ] || return 1
  case "$first" in ''|*[!0-9]*) printf '%s' "$last" ;; *) printf '%s' "$((first - 1))" ;; esac
}

lri_fetch() {
  local lane="${1:-}" p="${2:-}" root st dl api age maxage sha parts n wb k=0 ids f
  [ -n "$(lri_paths "$lane" "$p" ro)" ] || return 0
  root=$(_lri_root)
  [ -n "$root" ] || return 1
  # A LIVE HARNESS IS NEVER OVERLAID. A root with build records that this lib
  # did not put there is a hub or a box, not a lane machine.
  if [ -n "$(ls -A "$root/builds" 2>/dev/null)" ] && [ ! -e "$root/state/lane-run-inputs/.managed" ]; then
    echo "inputs: refused — $root/builds is populated and this root is not a lane machine" >&2; return 2
  fi
  _lri_client || return 1
  st=$(_lri_state "$lane" "$p"); dl="$st/dl"; api="/api/lane-snapshots/$lane/$p"
  mkdir -p "$st" || return 1
  rm -rf "$dl"; mkdir -p "$dl" || return 1
  _lri_get "$api" "$dl/snap.json" || { echo "inputs: no snapshot for $lane/$p (http ${JOBS_HTTP:-none})" >&2; return 1; }
  maxage=$(_lri_setting lane_snapshot.max_age_s 1200)
  age=$(jq -r '.age_s' "$dl/snap.json" 2>/dev/null); sha=$(jq -r '.sha // empty' "$dl/snap.json" 2>/dev/null)
  parts=$(jq -r '.parts' "$dl/snap.json" 2>/dev/null)
  case "$age$parts" in ''|*[!0-9]*) echo "inputs: unreadable snapshot answer" >&2; return 2 ;; esac
  _lri_fresh "$age" "$maxage" || { echo "inputs: snapshot is ${age}s old (lane_snapshot.max_age_s=$maxage)" >&2; return 2; }
  [ "$(jq -r '.truncated' "$dl/snap.json")" = false ] || { echo "inputs: the write-back list is truncated" >&2; return 2; }
  : > "$dl/snap.tgz"
  for ((n = 0; n < parts; n++)); do
    _lri_get "$api/parts/$n?sha=$sha" "$dl/part.json" || { echo "inputs: part $n not fetched" >&2; return 1; }
    jq -j '.b64 // empty' "$dl/part.json" | base64 -d >> "$dl/snap.tgz" 2>/dev/null || return 2
  done
  [ "$(_lri_sha "$dl/snap.tgz")" = "$sha" ] || { echo "inputs: snapshot sha mismatch" >&2; return 2; }
  _lri_validate "$p" "$dl/snap.tgz" snapshot || { echo "inputs: snapshot member outside the allow-list" >&2; return 2; }
  ids=$(jq -r '.writebacks[] | "\(.id)\t\(.sha)"' "$dl/snap.json" 2>/dev/null)
  while IFS=$'\t' read -r wb f; do
    [ -n "$wb" ] || continue
    _lri_get "$api/writebacks/$wb" "$dl/wb.json" || { echo "inputs: write-back $wb not fetched" >&2; return 1; }
    _lri_b64_file "$dl/wb.json" "$dl/wb-$wb.tgz" || return 2
    [ "$(_lri_sha "$dl/wb-$wb.tgz")" = "$f" ] || { echo "inputs: write-back $wb sha mismatch" >&2; return 2; }
    _lri_validate "$p" "$dl/wb-$wb.tgz" writeback || { echo "inputs: write-back $wb member outside the allow-list" >&2; return 2; }
    printf '%s\n' "$wb" >> "$dl/wb.order"; k=$((k + 1))
  done <<<"$ids"
  # Every check passed: now, and only now, the previous overlay goes, with
  # every rw file a run left behind that never reached the hub.
  _lri_unoverlay "$st/manifest.tsv"
  _lri_list "$p" rw 0 | awk -F'\t' '$1 == "-" {print $2}' | while IFS= read -r f; do rm -f "$root/$f"; done
  tar -xzf "$dl/snap.tgz" -C "$root" --no-same-owner 2>/dev/null || return 1
  _lri_members "$dl/snap.tgz" > "$dl/members"
  if [ -s "$dl/wb.order" ]; then
    while read -r wb; do _lri_overlay_wb "$p" "$dl/wb-$wb.tgz" "$dl" || return 1; done < "$dl/wb.order"
  fi
  _lri_manifest "$dl/members" > "$st/manifest.tsv.tmp" && mv -f "$st/manifest.tsv.tmp" "$st/manifest.tsv"
  stat -c %s "$root/logs/$lane.log" 2>/dev/null > "$st/log-offset" || echo 0 > "$st/log-offset"
  : > "$root/state/lane-run-inputs/.managed"
  rm -rf "$dl"
  printf 'inputs: snapshot %s + %s write-backs, age %ss\n' "${sha:0:12}" "$k" "$age"
}

# _lri_unoverlay <manifest> — removes the files a previous overlay wrote, then
# the record dirs it wrote when they are empty.
_lri_unoverlay() {
  local root t rel
  root=$(_lri_root)
  [ -s "$1" ] || return 0
  while IFS=$'\t' read -r rel t; do
    [ "$t" = dir ] || rm -f "$root/$rel"
  done < "$1"
  while IFS=$'\t' read -r rel t; do
    [ "$t" = dir ] && rmdir "$root/$rel" 2>/dev/null
  done < "$1"
  return 0
}

# _lri_overlay_wb <project> <archive> <dl> — one write-back onto the machine
# root: its files, its deletions and its visit row. Its log bytes are the
# hub's, not the machine's. Appends its members to <dl>/members.
_lri_overlay_wb() {
  local p="$1" f="$2" dl="$3" root x rel
  root=$(_lri_root); x="$dl/x"
  rm -rf "$x"; mkdir -p "$x" || return 1
  tar -xzf "$f" -C "$x" --no-same-owner 2>/dev/null || return 1
  _lri_members "$f" | grep -v $'\t\\.lri' >> "$dl/members"
  ( cd "$x" && find . -path ./.lri -prune -o -type f -print | sed 's#^\./##' ) | while IFS= read -r rel; do
    [ "$rel" = state/blocked-resolver/.last-visited.tsv ] && continue
    mkdir -p "$root/$(dirname "$rel")" && cp -p "$x/$rel" "$root/$rel"
  done
  if [ -s "$x/.lri/deletions" ]; then
    while IFS= read -r rel; do
      lri_member_ok "$p" "$rel" - rw && rm -f "$root/$rel"
    done < "$x/.lri/deletions"
  fi
  [ -s "$x/.lri/visited.tsv" ] && _lri_visited_merge "$p" "$x/.lri/visited.tsv"
  return 0
}

# _lri_visited_merge <project> <row-file> — replaces <project>'s row of
# state/blocked-resolver/.last-visited.tsv; every other project's row stays.
# The same short lock br_visited_put takes.
_lri_visited_merge() {
  local p="$1" rowf="$2" root f
  root=$(_lri_root); f="$root/state/blocked-resolver/.last-visited.tsv"
  mkdir -p "$root/state/blocked-resolver" "$root/locks" 2>/dev/null
  (
    exec 9>"$root/locks/blocked-resolver-visited.lock" || exit 1
    flock -w 5 9 2>/dev/null || true
    [ -f "$f" ] || : > "$f"
    { awk -F'\t' -v p="$p" '$1 != p && NF' "$f"; awk -F'\t' -v p="$p" '$1 == p' "$rowf" | tail -n 1; } > "$f.tmp.$$" \
      && mv -f "$f.tmp.$$" "$f"
  )
}

# _lri_manifest <members-file> — relpath TAB sha256 for every regular file the
# overlay holds now, relpath TAB dir for each record dir. A deleted file is not
# listed.
_lri_manifest() {
  local root t rel
  root=$(_lri_root)
  while IFS=$'\t' read -r t rel; do
    rel="${rel%/}"
    if [ "$t" = d ]; then printf '%s\tdir\n' "$rel"
    elif [ -f "$root/$rel" ]; then printf '%s\t%s\n' "$rel" "$(_lri_sha "$root/$rel")"; fi
  done < "$1" | LC_ALL=C sort -u
}

lri_checkpoint() {
  local lane="${1:-}" p="${2:-}"
  [ -n "$(lri_paths "$lane" "$p" rw)" ] || return 0
  local root st
  root=$(_lri_root); st=$(_lri_state "$lane" "$p")
  [ -n "$root" ] && [ -s "$st/manifest.tsv" ] || { echo "checkpoint: no manifest for $lane/$p — nothing was fetched" >&2; return 1; }
  [ -n "${LANE_RUN_ID:-}" ] || { echo "checkpoint: LANE_RUN_ID is not set" >&2; return 1; }
  _lri_client || return 1
  mkdir -p "$st" || return 1
  (
    exec 9>"$st/.lock" || exit 1
    flock -w 10 9 || exit 1
    _lri_checkpoint_locked "$lane" "$p"
  )
}

_lri_checkpoint_locked() {
  local lane="$1" p="$2" root st tmp now base cur rel t off size machine changed=0
  root=$(_lri_root); st=$(_lri_state "$lane" "$p")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lri-ckpt.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; trap - RETURN" RETURN
  mkdir -p "$tmp/x/.lri"
  : > "$tmp/x/.lri/base.tsv"; : > "$tmp/x/.lri/deletions"; : > "$tmp/files"
  # The rw files now, with their sha.
  _lri_list "$p" rw 0 | awk -F'\t' '$1 == "-" {print $2}' | while IFS= read -r rel; do
    printf '%s\t%s\n' "$rel" "$(_lri_sha "$root/$rel")"
  done | LC_ALL=C sort > "$tmp/now"
  awk -F'\t' '$2 != "dir"' "$st/manifest.tsv" | while IFS=$'\t' read -r rel base; do
    lri_member_ok "$p" "$rel" - rw && printf '%s\t%s\n' "$rel" "$base"
  done | LC_ALL=C sort > "$tmp/base"
  # Changed or new files, then deleted ones. The visit ledger travels as a row.
  while IFS=$'\t' read -r rel cur; do
    base=$(awk -F'\t' -v r="$rel" '$1 == r {print $2; exit}' "$tmp/base")
    [ "$cur" = "$base" ] && continue
    if [ "$rel" = state/blocked-resolver/.last-visited.tsv ]; then
      awk -F'\t' -v p="$p" '$1 == p' "$root/$rel" | tail -n 1 > "$tmp/x/.lri/visited.tsv"
      [ -s "$tmp/x/.lri/visited.tsv" ] && changed=1
      continue
    fi
    printf '%s\t%s\n' "$rel" "${base:--}" >> "$tmp/x/.lri/base.tsv"
    printf '%s\n' "$rel" >> "$tmp/files"; changed=1
  done < "$tmp/now"
  while IFS=$'\t' read -r rel base; do
    [ "$rel" = state/blocked-resolver/.last-visited.tsv ] && continue
    awk -F'\t' -v r="$rel" '$1 == r {f = 1} END {exit !f}' "$tmp/now" && continue
    printf '%s\t%s\n' "$rel" "$base" >> "$tmp/x/.lri/base.tsv"
    printf '%s\n' "$rel" >> "$tmp/x/.lri/deletions"; changed=1
  done < "$tmp/base"
  # The bytes the run added to its log since the last fetch or checkpoint.
  off=$(cat "$st/log-offset" 2>/dev/null); case "$off" in ''|*[!0-9]*) off=0 ;; esac
  size=$(stat -c %s "$root/logs/$lane.log" 2>/dev/null || echo 0)
  [ "$size" -ge "$off" ] || off=0
  if [ "$size" -gt "$off" ]; then
    tail -c +"$((off + 1))" "$root/logs/$lane.log" | tail -c "$LRI_LOG_APPEND_MAX" > "$tmp/x/.lri/log-append"
    changed=1
  fi
  [ "$changed" = 1 ] || return 0
  tar --no-recursion --owner=0 --group=0 --numeric-owner --format=gnu -czf "$tmp/wb.tgz" \
      -C "$root" -T "$tmp/files" -C "$tmp/x" .lri/base.tsv .lri/deletions \
      $( [ -s "$tmp/x/.lri/visited.tsv" ] && echo .lri/visited.tsv ) \
      $( [ -s "$tmp/x/.lri/log-append" ] && echo .lri/log-append ) 2>/dev/null || return 1
  base64 -w0 "$tmp/wb.tgz" > "$tmp/wb.b64"
  [ "$(stat -c %s "$tmp/wb.b64")" -le "$LRI_B64_MAX" ] || { echo "checkpoint: write-back is over $LRI_B64_MAX base64 bytes" >&2; return 1; }
  machine="${FLY_MACHINE_ID:-$(_jobs_box_name 2>/dev/null)}"
  machine=$(printf '%s' "$machine" | tr -dc 'A-Za-z0-9._-' | head -c 64)
  jq -n --arg r "$LANE_RUN_ID" --arg m "${machine:-machine}" --arg s "$(_lri_sha "$tmp/wb.tgz")" \
    --rawfile b "$tmp/wb.b64" '{run_id:$r, machine:$m, sha:$s, b64:$b}' > "$tmp/body.json" || return 1
  # Into a file, not $( ): JOBS_HTTP must survive the call to be named.
  _jobs_req_file POST "/api/lane-snapshots/$lane/$p/writebacks" "$tmp/body.json" > "$tmp/resp.json" \
    || { echo "checkpoint: write-back not accepted (http ${JOBS_HTTP:-none})" >&2; return 1; }
  # Accepted: the manifest now describes the machine's files, and the log
  # offset moves past what was sent.
  now=$(awk -F'\t' '$2 == "dir"' "$st/manifest.tsv"; awk -F'\t' '$2 != "dir"' "$st/manifest.tsv" | while IFS=$'\t' read -r rel t; do
    lri_member_ok "$p" "$rel" - rw || printf '%s\t%s\n' "$rel" "$t"; done; cat "$tmp/now")
  printf '%s\n' "$now" | awk 'NF' | LC_ALL=C sort -u -t$'\t' -k1,1 > "$st/manifest.tsv.tmp" && mv -f "$st/manifest.tsv.tmp" "$st/manifest.tsv"
  echo "$size" > "$st/log-offset"
  printf 'checkpoint: write-back %s\n' "$(jq -r '.id // empty' "$tmp/resp.json" 2>/dev/null)"
  return 0
}

lri_apply_pending() {
  local lane="${1:-}" p="${2:-}" root
  [ -n "$(lri_paths "$lane" "$p" rw)" ] || { echo "applied=0 conflicts=0 rejected=0"; return 0; }
  root=$(_lri_root)
  [ -n "$root" ] || return 1
  _lri_client || return 1
  mkdir -p "$root/locks" "$(_lri_state "$lane" "$p")" 2>/dev/null
  (
    exec 9>"$root/locks/lane-snapshot-$lane-$p.lock" || exit 1
    flock -w 10 9 || { echo "applied=0 conflicts=0 rejected=0 (lock busy)"; exit 1; }
    _lri_apply_locked "$lane" "$p"
  )
}

_lri_apply_locked() {
  local lane="$1" p="$2" root st api tmp list id sha applied=0 conflicts=0 rejected=0 through="" rej=() rc=0 x rel base cur line logs_through
  root=$(_lri_root); st=$(_lri_state "$lane" "$p"); api="/api/lane-snapshots/$lane/$p"
  logs_through=$(cat "$st/logs-through" 2>/dev/null); case "$logs_through" in ''|*[!0-9]*) logs_through=0 ;; esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lri-apply.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; trap - RETURN" RETURN
  _lri_get "$api/writebacks" "$tmp/list.json" || { echo "applied=0 conflicts=0 rejected=0 (list failed, http ${JOBS_HTTP:-none})"; return 1; }
  list=$(jq -r '.writebacks[] | "\(.id)\t\(.sha)"' "$tmp/list.json" 2>/dev/null)
  while IFS=$'\t' read -r id sha; do
    [ -n "$id" ] || continue
    _lri_get "$api/writebacks/$id" "$tmp/wb.json" || { rc=1; break; }
    if ! _lri_b64_file "$tmp/wb.json" "$tmp/wb.tgz" || [ "$(_lri_sha "$tmp/wb.tgz")" != "$sha" ] \
       || ! _lri_validate "$p" "$tmp/wb.tgz" writeback; then
      rej+=("$id"); rejected=$((rejected + 1)); through="$id"; continue
    fi
    x="$tmp/x-$id"; mkdir -p "$x"
    tar -xzf "$tmp/wb.tgz" -C "$x" --no-same-owner 2>/dev/null || { rc=1; break; }
    # COMPARE-AND-SET, per file: the hub's copy changes only when it is still
    # the copy the machine started from. Absent equals absent. A hub copy that
    # already equals the machine's (a re-apply) is a no-op, not a conflict.
    # Each line is parsed and checked against the rw allow-list again here,
    # by the parser _lri_validate used, before any cp or rm.
    if [ -s "$x/.lri/base.tsv" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        _lri_base_line "$p" "$line" || continue
        rel="$LRI_REL"; base="$LRI_BASE"
        cur=$(_lri_sha "$root/$rel"); cur="${cur:--}"
        if [ -f "$x/$rel" ]; then
          [ "$cur" = "$(_lri_sha "$x/$rel")" ] && continue
          if [ "$cur" = "$base" ]; then mkdir -p "$root/$(dirname "$rel")" && cp -p "$x/$rel" "$root/$rel"
          else conflicts=$((conflicts + 1)); fi
        else
          [ "$cur" = - ] && continue
          if [ "$cur" = "$base" ]; then rm -f "$root/$rel"; else conflicts=$((conflicts + 1)); fi
        fi
      done < "$x/.lri/base.tsv"
    fi
    [ -s "$x/.lri/visited.tsv" ] && _lri_visited_merge "$p" "$x/.lri/visited.tsv"
    # The log bytes are not idempotent: logs-through records the newest id
    # whose bytes are in the hub log, so a re-apply after a failed ack skips
    # them. The hub caps them too; a machine is not trusted to.
    if [ -s "$x/.lri/log-append" ] && [ "$id" -gt "$logs_through" ]; then
      mkdir -p "$root/logs"; tail -c "$LRI_LOG_APPEND_MAX" "$x/.lri/log-append" >> "$root/logs/$lane.log"
      logs_through="$id"; echo "$id" > "$st/logs-through"
    fi
    applied=$((applied + 1)); through="$id"
    rm -rf "$x"
  done <<<"$list"
  if [ -n "$through" ]; then
    if _jobs_req POST "$api/writebacks/ack" "$(jq -nc --argjson t "$through" '{through:$t, rejected:($ARGS.positional | map(tonumber))}' --args "${rej[@]}")" > /dev/null; then
      echo "$through" > "$st/applied-through"
    else
      rc=1
    fi
  fi
  echo "applied=$applied conflicts=$conflicts rejected=$rejected"
  return "$rc"
}
