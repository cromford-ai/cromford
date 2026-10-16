# shellcheck shell=bash
# bin/lib/lane-run-inputs.sh — the hub-local inputs a lane reads, carried to a
# Fly lane machine and its writes carried back (BH-6128, BH-6047 part 5 of 5).
#
# A lane placed `fly` (bin/lib/lane-placement.sh) runs on a machine whose
# harness root has no builds/, state/ or logs/ of the hub. Each lane names
# the hub files one run for one project reads and writes in a manifest pair,
# catalog/lane-run-inputs.d/<lane>.rw and <lane>.ro; this lib holds
# no lane's list. The hub publishes those as ONE snapshot per (lane, project)
# through the jobs worker (worker/jobs/src/routes/lane-snapshots.js); the
# machine fetches it before the run and posts back the files the run changed
# as a write-back row; the hub applies the write-backs with compare-and-set.
# Nothing here uses ssh. The inventory and its choices are in
# docs/notes/2026-10-12-BH-6128-blocked-resolver-offhub.md.
#
#   lri_paths <lane> <project> ro|rw
#       prints the allow-list, globs relative to the root: <lane>.rw, then
#       for ro the <lane>.ro lines. rw is what a write-back may carry. A lane
#       with no manifest prints nothing (rc 0). A malformed manifest prints
#       one `lri: <file>:<line>: <why>` line to stderr and returns rc 1, and
#       every entry point below refuses rather than reading it as no inputs.
#   lri_member_ok <project> <relpath> [type] [ro|rw] [lane]
#       rc 0 when one archive member may be read (ro) or written back (rw).
#       type is the tar type letter: `-` (regular, the default) or `d`. The
#       lane is the argument, else $LRI_LANE, else LRI_LANE_DEFAULT.
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
# of the lane's `@row` file) and .lri/log-append (the bytes the run added to
# logs/<lane>.log).
#
# Manifest format: one entry a line; blank and `#` lines are skipped. A path
# line is `<glob>[ <comment>]` and lri_paths prints it whole, with $p replaced
# by the project and $repokey by the project's fleet.conf repo with every
# character outside [A-Za-z0-9._-] folded to `_`, case kept (the mc_safe_name
# fold; a project with no repo is a parse error, _lri_repokey). In a glob `*`
# is any run of non-`/` characters, `**` (the
# whole LAST segment only) is one or more segments, <KEY> is a ticket key,
# <KEY>-* is a ticket key alone or followed by `-` and more, and <name> is a
# set from `@token`. The directives are not printed:
#   @token <name> <glob>...  <name> is any of the one-segment globs
#   @lines <path> <ERE>      (.ro only) the snapshot carries <path> as its
#                            lines matching <ERE> only, with a fixed mtime
#   @row <path> <lockname>   (.rw only, once) <path> is a fleet-wide TSV keyed
#                            by project in column 1; a write-back carries this
#                            project's row, merged under locks/<lockname>.lock
#   @rows <path> <ERE>       (.rw only, once a path; <path> is a literal path
#                            line of the .rw and not the @row path) <path> is a
#                            fleet-wide file that rides as this project's lines
#                            only: the snapshot holds the lines <ERE> matches,
#                            the machine writes back its copy whole, and
#                            .lri/base.tsv holds the sha256 of those lines at
#                            fetch time. The hub replaces the project's lines
#                            under <path>.lock (the lock mc_row_put takes) when
#                            its own project lines still have that sha, else it
#                            counts a conflict. A write-back line <ERE> does not
#                            match, a deletion of <path>, or a base line with no
#                            member rejects the write-back. In <ERE> $p is the
#                            project and $slug its lower-case fleet.conf repo,
#                            each with `.` escaped. Every match is
#                            case-insensitive (`grep -iE`, _lri_rows_lines).
# A record dir member (type d) is allowed for the parent dir of a glob whose
# parent segment holds <KEY>. A file under a glob whose last segment has a
# wildcard or a token is capped at LRI_FILE_MAX bytes. The manifest dir is
# $LRI_MANIFEST_DIR, else <root>/catalog/lane-run-inputs.d, else the catalog
# beside this lib. Each (lane, project) is parsed once per process.
#
# The settings rows lane_snapshot.max_age_s (1200), lane_snapshot.max_bytes
# (33554432) and lane_snapshot.builds_days (30) are the knobs; the numbers in
# brackets are the code fallbacks. The root is ${HARNESS:-${H:-}}. Defines
# functions only. Nothing runs on source.

LRI_PART_BYTES=1000000
LRI_B64_MAX=1400000
LRI_FILE_MAX=262144
LRI_LOG_APPEND_MAX=262144
# The lane of the call forms that name none (lri_member_ok with four
# arguments, _lri_validate, _lri_base_line). It selects a manifest only.
LRI_LANE_DEFAULT=blocked-resolver
_LRI_KEY_ERE='[A-Z][A-Za-z0-9]*-[0-9]+'
declare -gA _LRI_M=()

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

# _lri_mdir — sets LRI_MD to the manifest dir (see the header). It forks
# nothing: the matcher calls it once per archive member.
_lri_mdir() {
  local root="${HARNESS:-${H:-}}" s="${BASH_SOURCE[0]}"
  if [ -n "${LRI_MANIFEST_DIR:-}" ]; then LRI_MD="$LRI_MANIFEST_DIR"
  elif [ -n "$root" ] && [ -d "$root/catalog/lane-run-inputs.d" ]; then LRI_MD="$root/catalog/lane-run-inputs.d"
  else
    case "$s" in */*) s="${s%/*}" ;; *) s=. ;; esac
    LRI_MD="$s/../../catalog/lane-run-inputs.d"
  fi
}

# _lri_load <lane> <project> — parses the lane's manifests for <project> into
# _LRI_M under the key LRI_K, once per process. rc 0 = loaded, or the lane has
# no manifest (every list empty). rc 1 = malformed: _LRI_M[$LRI_K|err] holds
# the one-line reason, and the key stays bad for the process.
_lri_load() {
  local lane="${1:-}" p="${2:-}"
  _lri_mdir
  LRI_K="$LRI_MD|$lane|$p"
  case "${_LRI_M[$LRI_K]:-}" in ok) return 0 ;; bad) return 1 ;; esac
  if _lri_name_ok "$lane" && _lri_name_ok "$p" && ! _lri_compile "$lane" "$p"; then
    _LRI_M[$LRI_K]=bad; return 1
  fi
  _LRI_M[$LRI_K]=ok
}

# _lri_has [rw] — rc 0 when the lane loaded under LRI_K lists any path (in rw
# mode: any rw path).
_lri_has() {
  [ -n "${_LRI_M[$LRI_K|print.rw]:-}" ] || { [ "${1:-ro}" = ro ] && [ -n "${_LRI_M[$LRI_K|print.ro]:-}" ]; }
}

_lri_bad() { _LRI_M[$LRI_K|err]="lri: $1: $2"; }

# _lri_seg_ere <segment> — one glob segment as an ERE in LRI_SE. LRI_SW = 1
# when it holds a wildcard or a token, LRI_SK = 1 when it holds <KEY>. rc 1
# with LRI_WHY for an undefined token or a character no member name can hold.
# Reads the caller's `tok` (name -> ERE alternation).
_lri_seg_ere() {
  local s="$1" out="" c name
  LRI_SW=0; LRI_SK=0
  while [ -n "$s" ]; do
    case "$s" in
      '<KEY>-*'*) out+="$_LRI_KEY_ERE(-[^/]*)?"; s="${s:7}"; LRI_SW=1; LRI_SK=1 ;;
      '<KEY>'*) out+="$_LRI_KEY_ERE"; s="${s:5}"; LRI_SW=1; LRI_SK=1 ;;
      '<'*'>'*)
        name="${s#<}"; name="${name%%>*}"
        [ -n "${tok[$name]+x}" ] || { LRI_WHY="undefined token <$name>"; return 1; }
        out+="${tok[$name]}"; s="${s#"<$name>"}"; LRI_SW=1 ;;
      '*'*) out+='[^/]*'; s="${s:1}"; LRI_SW=1 ;;
      *)
        c="${s:0:1}"; s="${s:1}"
        case "$c" in
          [A-Za-z0-9_@=,-]) out+="$c" ;;
          [.+]) out+="\\$c" ;;
          *) LRI_WHY="the character '$c' cannot be in a member name"; return 1 ;;
        esac ;;
    esac
  done
  LRI_SE="$out"
}

# _lri_glob <glob> — compiles one path glob. Sets LRI_GE (its ERE), LRI_GD
# (the ERE of its record dir when the parent segment holds <KEY>, else
# empty), LRI_GL (the path when every segment is literal, else empty) and
# LRI_GW (the walk spec _lri_list reads: kind TAB cap TAB prefix TAB depth
# TAB dir-ERE). rc 1 with LRI_WHY when the glob is malformed.
_lri_glob() {
  local g="$1" segs=() eres=() wilds=() keys=() n i k=0 pre="" cap
  case "$g" in /*) LRI_WHY="an absolute path"; return 1 ;; esac
  case "/$g/" in *//*|*/../*|*/./*) LRI_WHY="an empty, . or .. segment"; return 1 ;; esac
  IFS=/ read -ra segs <<<"$g"
  n=${#segs[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${segs[i]}" = '**' ] && [ "$i" = $((n - 1)) ]; then
      eres+=('[^/]+(/[^/]+)*'); wilds+=(1); keys+=(0); continue
    fi
    case "${segs[i]}" in *'**'*) LRI_WHY="** is allowed only as the whole last segment"; return 1 ;; esac
    _lri_seg_ere "${segs[i]}" || return 1
    eres+=("$LRI_SE"); wilds+=("$LRI_SW"); keys+=("$LRI_SK")
  done
  while [ "$k" -lt "$n" ] && [ "${wilds[k]}" = 0 ]; do pre+="${pre:+/}${segs[k]}"; k=$((k + 1)); done
  LRI_GE=$(IFS=/; printf '%s' "${eres[*]}")
  LRI_GD=""; LRI_GL=""; cap="${wilds[n - 1]}"
  [ "$n" -ge 2 ] && [ "${keys[n - 2]}" = 1 ] && LRI_GD="^$(IFS=/; printf '%s' "${eres[*]:0:n-1}")\$"
  if [ "$k" = "$n" ]; then
    LRI_GL="$g"; LRI_GW="exact"$'\t'"0"$'\t'"$g"$'\t'"0"$'\t'
  elif [ -n "$LRI_GD" ] && [ "${segs[n - 1]}" != '**' ] && [ "$k" = $((n - 2)) ]; then
    LRI_GW="rec"$'\t'"$cap"$'\t'"${pre:-.}"$'\t'"1"$'\t'"$LRI_GD"
  elif [ "${segs[n - 1]}" = '**' ]; then
    LRI_GW="find"$'\t'"$cap"$'\t'"${pre:-.}"$'\t'"0"$'\t'
  else
    LRI_GW="find"$'\t'"$cap"$'\t'"${pre:-.}"$'\t'"$((n - k))"$'\t'
  fi
}

# _lri_compile <lane> <project> — reads <lane>.rw then <lane>.ro from LRI_MD
# into _LRI_M[$LRI_K|...]: print.rw/print.ro (the lines lri_paths prints),
# re.rw/re.ro and dre.rw/dre.ro (anchored file and record-dir EREs; ro holds
# rw too), walk.rw/walk.ro (_lri_list's specs), lines (path TAB ERE per
# @lines), rows (path TAB ERE per @rows), row and rowlock. rc 1 via _lri_bad
# on the first malformed line.
_lri_compile() {
  local lane="$1" p="$2" pe mode f n line where name g e words=() paths=() lines="" row="" rowlock="" rowat=""
  local rows="" slug="" repokey=""
  local -A tok=() lit=() lp=() rp=()
  local pr_rw="" pr_ro="" re_rw="" re_ro="" dr_rw="" dr_ro="" wk_rw="" wk_ro=""
  local re_glob='^(([<][^>]*[>]|[^[:space:]<])+)([[:space:]].*)?$'
  pe="${p//./\\.}"
  for mode in rw ro; do
    f="$LRI_MD/$lane.$mode"
    [ -f "$f" ] || continue
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1)); where="$f:$n"
      [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
      case "$line" in
        '@token'[[:space:]]*)
          [[ $line =~ ^@token[[:space:]]+[\<]([A-Za-z0-9\ _-]+)[\>][[:space:]]+(.+)$ ]] && [ "${BASH_REMATCH[1]}" != KEY ] \
            || { _lri_bad "$where" "@token needs <name> and at least one glob"; return 1; }
          name="${BASH_REMATCH[1]}"; e=""
          read -ra words <<<"${BASH_REMATCH[2]}"
          for g in "${words[@]}"; do
            g="${g//\$p/$p}"
            case "$g" in */*|*'<'*|*'**'*) _lri_bad "$where" "a token glob is one segment with no token"; return 1 ;; esac
            _lri_seg_ere "$g" || { _lri_bad "$where" "$LRI_WHY"; return 1; }
            e+="${e:+|}$LRI_SE"
          done
          tok[$name]="($e)" ;;
        '@lines'[[:space:]]*)
          [ "$mode" = ro ] || { _lri_bad "$where" "@lines is allowed in .ro only"; return 1; }
          [[ $line =~ ^@lines[[:space:]]+([^[:space:]]+)[[:space:]]+(.+)$ ]] \
            || { _lri_bad "$where" "@lines needs a path and an ERE"; return 1; }
          g="${BASH_REMATCH[1]//\$p/$p}"; e="${BASH_REMATCH[2]//\$p/$pe}"
          grep -qE -- "$e" /dev/null 2>/dev/null; [ $? -le 1 ] || { _lri_bad "$where" "the @lines ERE does not compile"; return 1; }
          lines+="$g"$'\t'"$e"$'\t'"$where"$'\n'; lp[$g]=1 ;;
        '@rows'[[:space:]]*)
          [ "$mode" = rw ] || { _lri_bad "$where" "@rows is allowed in .rw only"; return 1; }
          [[ $line =~ ^@rows[[:space:]]+([^[:space:]]+)[[:space:]]+(.+)$ ]] \
            || { _lri_bad "$where" "@rows needs a path and an ERE"; return 1; }
          g="${BASH_REMATCH[1]//\$p/$p}"; e="${BASH_REMATCH[2]}"
          case "$e" in
            *"\$slug"*)
              [ -n "$slug" ] || slug=$(_lri_slug "$p") || { _lri_bad "$where" "@rows: no repo for $p in fleet.conf"; return 1; }
              e="${e//\$slug/$slug}" ;;
          esac
          e="${e//\$p/$pe}"
          grep -qiE -- "$e" /dev/null 2>/dev/null; [ $? -le 1 ] || { _lri_bad "$where" "the @rows ERE does not compile"; return 1; }
          [ -z "${rp[$g]:-}" ] || { _lri_bad "$where" "a second @rows for $g (the first is at ${rp[$g]})"; return 1; }
          rp[$g]="$where"; rows+="$g"$'\t'"$e"$'\t'"$where"$'\n' ;;
        '@row'[[:space:]]*)
          [ "$mode" = rw ] || { _lri_bad "$where" "@row is allowed in .rw only"; return 1; }
          [ -z "$row" ] || { _lri_bad "$where" "a second @row (the first is at $rowat)"; return 1; }
          [[ $line =~ ^@row[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]] \
            || { _lri_bad "$where" "@row needs a path and a lock name"; return 1; }
          row="${BASH_REMATCH[1]//\$p/$p}"; rowlock="${BASH_REMATCH[2]}"; rowat="$where"
          _lri_name_ok "$rowlock" || { _lri_bad "$where" "the @row lock name is not a plain name"; return 1; } ;;
        '@'*) _lri_bad "$where" "unknown directive ${line%%[[:space:]]*}"; return 1 ;;
        *) paths+=("$mode"$'\t'"$where"$'\t'"$line") ;;
      esac
    done < "$f"
  done
  for e in "${paths[@]}"; do
    IFS=$'\t' read -r mode where line <<<"$e"
    line="${line//\$p/$p}"
    case "$line" in
      *"\$repokey"*)
        [ -n "$repokey" ] || repokey=$(_lri_repokey "$p") || { _lri_bad "$where" "\$repokey: no repo for $p in fleet.conf"; return 1; }
        line="${line//\$repokey/$repokey}" ;;
    esac
    [[ $line =~ $re_glob ]] || { _lri_bad "$where" "no glob before the first space"; return 1; }
    _lri_glob "${BASH_REMATCH[1]}" || { _lri_bad "$where" "$LRI_WHY"; return 1; }
    [ -z "$LRI_GL" ] || lit[$mode:$LRI_GL]=1
    if [ "$mode" = rw ]; then
      pr_rw+="$line"$'\n'; re_rw+="${re_rw:+|}$LRI_GE"; dr_rw+="${LRI_GD:+${dr_rw:+|}$LRI_GD}"; wk_rw+="$LRI_GW"$'\n'
    else
      pr_ro+="$line"$'\n'; re_ro+="${re_ro:+|}$LRI_GE"; dr_ro+="${LRI_GD:+${dr_ro:+|}$LRI_GD}"
      # An @lines path rides as its filtered copy, never walked as a file.
      [ -n "$LRI_GL" ] && [ -n "${lp[$LRI_GL]:-}" ] || wk_ro+="$LRI_GW"$'\n'
    fi
  done
  if [ -n "$row" ] && [ -z "${lit[rw:$row]:-}" ]; then
    _lri_bad "$rowat" "the @row path is not a path line of the .rw"; return 1
  fi
  while IFS=$'\t' read -r g e where; do
    [ -n "$g" ] || continue
    [ -n "${lit[ro:$g]:-}" ] || { _lri_bad "$where" "the @lines path is not a path line of the .ro"; return 1; }
  done <<<"$lines"
  while IFS=$'\t' read -r g e where; do
    [ -n "$g" ] || continue
    [ -n "${lit[rw:$g]:-}" ] || { _lri_bad "$where" "the @rows path is not a path line of the .rw"; return 1; }
    [ "$g" != "$row" ] || { _lri_bad "$where" "the @rows path is the @row path"; return 1; }
  done <<<"$rows"
  _LRI_M[$LRI_K|walk.rw]="$wk_rw"; _LRI_M[$LRI_K|walk.ro]="$wk_rw$wk_ro"
  _LRI_M[$LRI_K|print.rw]="$pr_rw"; _LRI_M[$LRI_K|print.ro]="$pr_ro"
  re_ro="$re_rw${re_rw:+${re_ro:+|}}$re_ro"; dr_ro="$dr_rw${dr_rw:+${dr_ro:+|}}$dr_ro"
  _LRI_M[$LRI_K|re.rw]="${re_rw:+^($re_rw)\$}"; _LRI_M[$LRI_K|re.ro]="${re_ro:+^($re_ro)\$}"
  _LRI_M[$LRI_K|dre.rw]="${dr_rw:+^($dr_rw)\$}"; _LRI_M[$LRI_K|dre.ro]="${dr_ro:+^($dr_ro)\$}"
  _LRI_M[$LRI_K|lines]="$(printf '%s' "$lines" | cut -f1,2)"
  _LRI_M[$LRI_K|rows]="$(printf '%s' "$rows" | cut -f1,2)"
  _LRI_M[$LRI_K|row]="$row"; _LRI_M[$LRI_K|rowlock]="$rowlock"
}

# _lri_slug <project> — the project's repo from fleet.conf (bin/fleet-conf.sh
# beside this lib), lower-cased, `.` escaped for an ERE. rc 1 when the repo is
# empty or `-`.
_lri_slug() {
  local s="${BASH_SOURCE[0]}" r
  case "$s" in */*) s="${s%/*}" ;; *) s=. ;; esac
  r=$(bash "$s/../fleet-conf.sh" "$1" repo 2>/dev/null) || r=""
  r=$(printf '%s' "$r" | tr -d '[:space:]')
  case "$r" in ''|-) return 1 ;; esac
  r="${r,,}"
  printf '%s' "${r//./\\.}"
}

# _lri_repokey <project> — the project's repo from fleet.conf (bin/fleet-conf.sh
# beside this lib) with every character outside [A-Za-z0-9._-] folded to `_`,
# case kept: the conductor's marker-name fold (mc_safe_name, mc_handoff_id).
# rc 1 when the repo is empty or `-`.
_lri_repokey() {
  local s="${BASH_SOURCE[0]}" r
  case "$s" in */*) s="${s%/*}" ;; *) s=. ;; esac
  r=$(bash "$s/../fleet-conf.sh" "$1" repo 2>/dev/null) || r=""
  r=$(printf '%s' "$r" | tr -d '[:space:]')
  case "$r" in ''|-) return 1 ;; esac
  printf '%s' "${r//[^A-Za-z0-9._-]/_}"
}

# _lri_rows <project> — LRI_ROWS, the lane's @rows (path TAB ERE a line),
# empty when it has none. The lane is $LRI_LANE, else LRI_LANE_DEFAULT. rc 1
# when the manifest is malformed.
_lri_rows() {
  LRI_ROWS=""
  _lri_load "${LRI_LANE:-$LRI_LANE_DEFAULT}" "$1" || return 1
  LRI_ROWS="${_LRI_M[$LRI_K|rows]:-}"
}

# _lri_rows_ere <relpath> — rc 0 when <relpath> is an @rows path of LRI_ROWS
# (set by _lri_rows), with its ERE in LRI_RE.
_lri_rows_ere() {
  local g e
  LRI_RE=""
  while IFS=$'\t' read -r g e; do
    [ -n "$g" ] && [ "$g" = "$1" ] && { LRI_RE="$e"; return 0; }
  done <<<"$LRI_ROWS"
  return 1
}

# _lri_rows_lines <ERE> <file> — the project's lines of <file>, in file order.
# THE one matcher of an @rows file: the snapshot, the validate and the hub
# apply all read lines through it. A missing file has no lines.
_lri_rows_lines() {
  [ -f "$2" ] || return 0
  grep -iE -- "$1" "$2" 2>/dev/null
  return 0
}

# _lri_rows_apply <relpath> <ERE> <base sha|-> <new-file> — the hub
# compare-and-set of one project's lines of an @rows file, under
# <relpath>.lock (fd 8: fd 9 holds the lane-snapshot lock, always taken
# first). rc 0 = applied, or the hub lines already equal <new-file> (a
# re-apply); rc 1 = conflict, the file is untouched; rc 2 = the lock is busy
# or the file cannot be written. Every other line stays in place; the new
# lines go where the first old project line was, else at the end.
_lri_rows_apply() {
  local rel="$1" ere="$2" base="$3" new="$4" root f empty want
  root=$(_lri_root); f="$root/$rel"
  empty=$(printf '' | sha256sum | awk '{print $1}')
  [ "$base" = - ] && base="$empty"
  want=$(_lri_sha "$new")
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 2
  (
    exec 8>>"$f.lock" || exit 2
    flock -w 10 8 || exit 2
    cur=$(_lri_rows_lines "$ere" "$f" | sha256sum | awk '{print $1}')
    [ "$cur" = "$want" ] && exit 0
    [ "$cur" = "$base" ] || exit 1
    src="$f"; [ -f "$f" ] || src=/dev/null
    nums=$(grep -niE -- "$ere" "$src" 2>/dev/null | cut -d: -f1 | paste -sd, -)
    awk -v nums="$nums" -v newf="$new" '
      BEGIN { n = split(nums, a, ","); for (i = 1; i <= n; i++) m[a[i]] = 1; first = (n ? a[1] : 0) }
      FNR == first { while ((getline l < newf) > 0) print l; next }
      FNR in m { next }
      { print }
      END { if (!first) while ((getline l < newf) > 0) print l }
    ' "$src" > "$f.tmp.$$" || { rm -f "$f.tmp.$$"; exit 2; }
    mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; exit 2; }
  )
}

# _lri_row <project> — LRI_ROW and LRI_ROWLOCK from the lane's @row, empty
# when it has none. The lane is $LRI_LANE, else LRI_LANE_DEFAULT. rc 1 when
# the manifest is malformed.
_lri_row() {
  LRI_ROW=""; LRI_ROWLOCK=""
  _lri_load "${LRI_LANE:-$LRI_LANE_DEFAULT}" "$1" || return 1
  LRI_ROW="${_LRI_M[$LRI_K|row]:-}"; LRI_ROWLOCK="${_LRI_M[$LRI_K|rowlock]:-}"
}

lri_paths() {
  local lane="${1:-}" p="${2:-}" mode="${3:-ro}"
  _lri_load "$lane" "$p" || { printf '%s\n' "${_LRI_M[$LRI_K|err]}" >&2; return 1; }
  printf '%s' "${_LRI_M[$LRI_K|print.rw]:-}"
  [ "$mode" = rw ] && return 0
  printf '%s' "${_LRI_M[$LRI_K|print.ro]:-}"
}

lri_member_ok() {
  local p="${1:-}" rel="${2:-}" type="${3:--}" mode="${4:-ro}" lane="${5:-${LRI_LANE:-$LRI_LANE_DEFAULT}}" re
  _lri_name_ok "$p" || return 1
  # Absolute, `..`, empty segments and any character outside the set the
  # lane's own names use are refused before any pattern is read.
  case "$rel" in ''|/*|*//*|*/) return 1 ;; esac
  [[ $rel =~ ^[A-Za-z0-9._@+=,/-]+$ ]] || return 1
  case "/$rel/" in */../*|*/./*) return 1 ;; esac
  case "$mode" in ro|rw) ;; *) return 1 ;; esac
  _lri_load "$lane" "$p" || return 1
  case "$type" in
    -) re="${_LRI_M[$LRI_K|re.$mode]:-}" ;;
    # Directories ride only so a record dir keeps its mtime.
    d) re="${_LRI_M[$LRI_K|dre.$mode]:-}" ;;
    *) return 1 ;;
  esac
  [ -n "$re" ] && [[ $rel =~ $re ]]
}

# _lri_list <project> ro|rw <days> — the allow-listed paths under the root, one
# per line, type letter TAB relpath, sorted. The lane is $LRI_LANE, else
# LRI_LANE_DEFAULT. Record dirs older than <days> stay out (0 = no window); a
# capped glob's file over LRI_FILE_MAX bytes stays out. An @lines path is not
# listed: lri_publish adds its filtered copy. rc 1 on a malformed manifest.
_lri_list() {
  local p="$1" mode="$2" days="$3" root walk age=()
  _lri_load "${LRI_LANE:-$LRI_LANE_DEFAULT}" "$p" || return 1
  walk="${_LRI_M[$LRI_K|walk.$mode]:-}"
  root=$(_lri_root)
  [ "$days" -gt 0 ] 2>/dev/null && age=(-mtime "-$days")
  (
    cd "$root" 2>/dev/null || exit 0
    while IFS=$'\t' read -r kind cap pre depth dre; do
      sz=(); [ "$cap" = 1 ] && sz=(-size "-$((LRI_FILE_MAX + 1))c")
      dp=(); [ "${depth:-0}" -gt 0 ] && dp=(-maxdepth "$depth")
      case "$kind" in
        exact) [ -f "$pre" ] && [ ! -L "$pre" ] && printf -- '-\t%s\n' "$pre" ;;
        rec)
          find "$pre" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
            d="${d#./}"
            [[ $d =~ $dre ]] || continue
            [ "${#age[@]}" = 0 ] || [ -n "$(find "$d" -maxdepth 0 "${age[@]}" 2>/dev/null)" ] || continue
            printf 'd\t%s\n' "$d"
            find "$d" -mindepth 1 -maxdepth 1 -type f ${sz[@]+"${sz[@]}"} 2>/dev/null | sed 's#^#-\t#'
          done ;;
        find)
          [ -d "$pre" ] && find "$pre" -mindepth 1 ${dp[@]+"${dp[@]}"} -type f ${sz[@]+"${sz[@]}"} 2>/dev/null \
            | sed -e 's#^\./##' -e 's#^#-\t#' ;;
      esac
    done <<<"$walk"
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
  local p="$1" f="$2" kind="$3" t n mode=ro bad=0 list g e
  [ "$kind" = writeback ] && mode=rw
  _lri_row "$p" || return 1
  _lri_rows "$p" || return 1
  list=$(_lri_members "$f") || return 1
  [ -n "$list" ] || return 1
  while IFS=$'\t' read -r t n; do
    n="${n%/}"
    if [ "$kind" = writeback ]; then
      case "$n" in .lri) [ "$t" = d ] && continue ;; esac
      case "$n" in .lri/base.tsv|.lri/deletions|.lri/log-append) [ "$t" = - ] && continue ;; esac
      # A visit row rides only for a lane with an @row file.
      [ "$n" = .lri/visited.tsv ] && [ "$t" = - ] && [ -n "$LRI_ROW" ] && continue
    fi
    lri_member_ok "$p" "$n" "$t" "$mode" || { bad=1; break; }
  done <<<"$list"
  [ "$bad" = 0 ] || return 1
  [ "$kind" = writeback ] || return 0
  # The control members name paths too: a deletion or a base line outside the
  # rw allow-list refuses the whole write-back. The @row file travels only
  # as .lri/visited.tsv, never as a file. base.tsv is parsed by _lri_base_line,
  # the same parser the hub apply uses, so no line passes here unread.
  tar -xzOf "$f" .lri/base.tsv 2>/dev/null | while IFS= read -r n || [ -n "$n" ]; do
    _lri_base_line "$p" "$n" || exit 1
  done || return 1
  tar -xzOf "$f" .lri/deletions 2>/dev/null | while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$n" != "$LRI_ROW" ] && lri_member_ok "$p" "$n" - rw || exit 1
  done || return 1
  # An @rows path carries this project's lines only: a member with any other
  # line, a deletion of it, or a base line with no member refuses it all.
  while IFS=$'\t' read -r g e; do
    [ -n "$g" ] || continue
    tar -xzOf "$f" .lri/deletions 2>/dev/null | grep -qxF -- "$g" && return 1
    if printf '%s\n' "$list" | awk -F'\t' -v g="$g" '$1 == "-" && $2 == g {f = 1} END {exit !f}'; then
      [ "$(tar -xzOf "$f" "$g" 2>/dev/null | grep -cviE -- "$e")" = 0 ] || return 1
    else
      tar -xzOf "$f" .lri/base.tsv 2>/dev/null | cut -f1 | grep -qxF -- "$g" && return 1
    fi
  done <<<"$LRI_ROWS"
  return 0
}

# _lri_base_line <project> <line> — rc 0 when one .lri/base.tsv line is
# exactly `relpath TAB sha` (sha is 64 hex digits or `-`) and relpath is in
# the rw allow-list and is not the lane's @row file. Sets LRI_REL and LRI_BASE. The validator and the hub
# apply both parse base.tsv with this function only (BH-6128 security review:
# a leading TAB once read as an empty path here and as a real path there).
_lri_base_line() {
  local re=$'^([^\t]+)\t(-|[0-9a-f]{64})$'
  LRI_REL=""; LRI_BASE=""
  [[ ${2:-} =~ $re ]] || return 1
  LRI_REL="${BASH_REMATCH[1]}"; LRI_BASE="${BASH_REMATCH[2]}"
  _lri_row "$1" || return 1
  [ "$LRI_REL" != "$LRI_ROW" ] && lri_member_ok "$1" "$LRI_REL" - rw
}

# _lri_get <path> <out-file> — GET into a file (JOBS_HTTP survives). rc as
# _jobs_req: 0 2xx, 2 = 404, any other = failure.
_lri_get() { _jobs_req GET "$1" > "$2"; }

# _lri_b64_file <json-file> <out> — decode the .b64 field of an answer.
_lri_b64_file() { jq -j '.b64 // empty' "$1" 2>/dev/null | base64 -d > "$2" 2>/dev/null && [ -s "$2" ]; }

lri_publish() {
  local lane="${1:-}" p="${2:-}" root api tmp maxb days list sha bytes cur cur_at through n=0 part rc lk
  local LRI_LANE="$lane" lines rows path ere logs=()
  root=$(_lri_root)
  [ -n "$root" ] || return 1
  _lri_load "$lane" "$p" || { printf '%s\n' "${_LRI_M[$LRI_K|err]}" >&2; return 1; }
  _lri_has || return 1
  lines="${_LRI_M[$LRI_K|lines]:-}"; rows="${_LRI_M[$LRI_K|rows]:-}"
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
  list=$(_lri_list "$p" ro "$days") || return 1
  printf '%s\n' "$list" | awk -F'\t' 'NF == 2 {print $2}' > "$tmp/list.files"
  # An @lines path rides as its matching lines only, with a fixed mtime, so a
  # busy log does not change the snapshot's sha.
  while IFS=$'\t' read -r path ere; do
    [ -n "$path" ] || continue
    mkdir -p "$tmp/x/$(dirname "$path")" || return 1
    grep -E -- "$ere" "$root/$path" 2>/dev/null | tail -n 20000 > "$tmp/x/$path"
    touch -d @0 "$tmp/x/$path"
    logs+=("$path")
  done <<<"$lines"
  # An @rows path rides as this project's lines only, whole (a cut copy would
  # give a wrong base sha), and never as the walked file.
  while IFS=$'\t' read -r path ere; do
    [ -n "$path" ] || continue
    grep -vxF -- "$path" "$tmp/list.files" > "$tmp/list.next"; mv -f "$tmp/list.next" "$tmp/list.files"
    mkdir -p "$tmp/x/$(dirname "$path")" || return 1
    _lri_rows_lines "$ere" "$root/$path" > "$tmp/x/$path" || return 1
    touch -d @0 "$tmp/x/$path"
    logs+=("$path")
  done <<<"$rows"
  [ "${#logs[@]}" = 0 ] || logs=(-C "$tmp/x" "${logs[@]}")
  tar --no-recursion --sort=name --owner=0 --group=0 --numeric-owner --format=gnu \
      -cf "$tmp/snap.tar" -C "$root" -T "$tmp/list.files" ${logs[@]+"${logs[@]}"} 2>/dev/null || return 1
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
  local LRI_LANE="$lane"
  _lri_load "$lane" "$p" || { printf '%s\n' "${_LRI_M[$LRI_K|err]}" >&2; return 2; }
  _lri_has || return 0
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
# root: its files, its deletions and its @row row. Its log bytes are the
# hub's, not the machine's. Appends its members to <dl>/members.
_lri_overlay_wb() {
  local p="$1" f="$2" dl="$3" root x rel
  root=$(_lri_root); x="$dl/x"
  _lri_row "$p" || return 1
  rm -rf "$x"; mkdir -p "$x" || return 1
  tar -xzf "$f" -C "$x" --no-same-owner 2>/dev/null || return 1
  _lri_members "$f" | grep -v $'\t\\.lri' >> "$dl/members"
  ( cd "$x" && find . -path ./.lri -prune -o -type f -print | sed 's#^\./##' ) | while IFS= read -r rel; do
    [ -n "$LRI_ROW" ] && [ "$rel" = "$LRI_ROW" ] && continue
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

# _lri_visited_merge <project> <row-file> — replaces <project>'s row of the
# lane's @row file; every other project's row stays. Under the @row lock (for
# blocked-resolver the same short lock br_visited_put takes). A lane with no
# @row merges nothing.
_lri_visited_merge() {
  local p="$1" rowf="$2" root f
  _lri_row "$p" || return 1
  [ -n "$LRI_ROW" ] || return 0
  root=$(_lri_root); f="$root/$LRI_ROW"
  mkdir -p "$(dirname "$f")" "$root/locks" 2>/dev/null
  (
    exec 9>"$root/locks/$LRI_ROWLOCK.lock" || exit 1
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
  local LRI_LANE="$lane"
  _lri_load "$lane" "$p" || { printf '%s\n' "${_LRI_M[$LRI_K|err]}" >&2; return 1; }
  _lri_has rw || return 0
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
  _lri_row "$p" || return 1
  _lri_rows "$p" || return 1
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lri-ckpt.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; trap - RETURN" RETURN
  mkdir -p "$tmp/x/.lri"
  : > "$tmp/x/.lri/base.tsv"; : > "$tmp/x/.lri/deletions"; : > "$tmp/files"
  # A missing @rows file is "no lines": it rides as an empty member, never as
  # a deletion.
  while IFS=$'\t' read -r rel t; do
    [ -n "$rel" ] && [ ! -e "$root/$rel" ] || continue
    mkdir -p "$root/$(dirname "$rel")" && : > "$root/$rel"
  done <<<"$LRI_ROWS"
  # The rw files now, with their sha.
  _lri_list "$p" rw 0 | awk -F'\t' '$1 == "-" {print $2}' | while IFS= read -r rel; do
    printf '%s\t%s\n' "$rel" "$(_lri_sha "$root/$rel")"
  done | LC_ALL=C sort > "$tmp/now"
  awk -F'\t' '$2 != "dir"' "$st/manifest.tsv" | while IFS=$'\t' read -r rel base; do
    lri_member_ok "$p" "$rel" - rw && printf '%s\t%s\n' "$rel" "$base"
  done | LC_ALL=C sort > "$tmp/base"
  # Changed or new files, then deleted ones. The @row file travels as a row.
  while IFS=$'\t' read -r rel cur; do
    base=$(awk -F'\t' -v r="$rel" '$1 == r {print $2; exit}' "$tmp/base")
    [ "$cur" = "$base" ] && continue
    if [ -n "$LRI_ROW" ] && [ "$rel" = "$LRI_ROW" ]; then
      awk -F'\t' -v p="$p" '$1 == p' "$root/$rel" | tail -n 1 > "$tmp/x/.lri/visited.tsv"
      [ -s "$tmp/x/.lri/visited.tsv" ] && changed=1
      continue
    fi
    printf '%s\t%s\n' "$rel" "${base:--}" >> "$tmp/x/.lri/base.tsv"
    printf '%s\n' "$rel" >> "$tmp/files"; changed=1
  done < "$tmp/now"
  while IFS=$'\t' read -r rel base; do
    [ -n "$LRI_ROW" ] && [ "$rel" = "$LRI_ROW" ] && continue
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
  local LRI_LANE="$lane"
  _lri_load "$lane" "$p" || { printf '%s\n' "${_LRI_M[$LRI_K|err]}" >&2; echo "applied=0 conflicts=0 rejected=0 (bad manifest)"; return 1; }
  _lri_has rw || { echo "applied=0 conflicts=0 rejected=0"; return 0; }
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
  local lane="$1" p="$2" root st api tmp list id sha applied=0 conflicts=0 rejected=0 through="" rej=() rc=0 x rel base cur line logs_through busy=0
  _lri_rows "$p" || return 1
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
        # An @rows path: compare-and-set of this project's lines only. A busy
        # file lock stops here unacked; the next tick re-applies it.
        if _lri_rows_ere "$rel"; then
          _lri_rows_apply "$rel" "$LRI_RE" "$base" "$x/$rel"
          case $? in 0) ;; 1) conflicts=$((conflicts + 1)) ;; *) busy=1; break ;; esac
          continue
        fi
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
    [ "$busy" = 0 ] || { rc=1; break; }
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
