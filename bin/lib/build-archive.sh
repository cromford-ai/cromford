#!/bin/bash
# bin/lib/build-archive.sh — the builds/ archive: where bin/builds-retention.sh
# moves a settled build-dir group, and how a reader by key finds it again.
#
# Layout (under the harness root <h>):
#   builds-archive/<YYYYMM>/<dir>   the moved dir, byte for byte (a rename)
#   builds-archive/index.tsv        one row per moved dir, append-only
#
# Index row, tab-separated (a header line starts with #):
#   archived_at  dir  relpath  project  key  ticket_id  result1
# relpath is <YYYYMM>/<dir>. ticket_id is job.json .ticket_id or `-`. result1
# is RESULT line 1, tabs and newlines stripped, at most 200 chars. A row whose
# result1 is MOVE_FAILED is a tombstone: the move after its row failed.
#
# EVERY READER CHECKS [ -d ]. A row is written BEFORE its move, so a row with
# no dir (a failed or interrupted move) is skipped, and the live dir under
# builds/ still answers the live globs. A missing or unreadable index means
# "nothing archived": rc 2, never an error that blocks the caller.
#
# Readers: bin/fetch-artifact.sh, bin/launch-fastpath.sh,
# bin/lib/ticket-identity.sh, bin/lib/starved-ready.sh,
# bin/merged-ticket-advance.sh, bin/lib/br/discovery.sh.
# Writer: bin/builds-retention.sh.
# Doc: docs/notes/2026-10-19-BH-7437-builds-retention.md.

ba_root()  { [ -n "${1:-}" ] || return 1; printf '%s/builds-archive' "$1"; }
ba_index() { [ -n "${1:-}" ] || return 1; printf '%s/builds-archive/index.tsv' "$1"; }

# ba_parse <dirname> — rc 0 and BA_P, BA_K, BA_STAMP (YYYYMMDDHHMMSS) when the
# name is <p>-<K>-..., pool-<p>-<K>-... or fly-<p>-<K>-... AND ends in a build
# stamp. The stamp shapes are bin/lib/lane-run-inputs.sh _lri_name_stamp's:
# -<12 digits>, -<14 digits>, -remote<14 digits>[-<n>], -r2-/-rerun-<stamp>.
# The project is lower case and the key starts upper case
# ([A-Z][A-Z0-9]*-<n>[.<n>]...), so the split between them is unambiguous.
# rc 1 for anything else (no key, no stamp, a hand-made name). No fork.
ba_parse() {
  local n="${1##*/}"
  local kre='^(pool-|fly-)?([a-z0-9][a-z0-9-]*)-([A-Z][A-Z0-9]*-[0-9]+(\.[0-9]+)*)-.'
  local sre='[[:lower:][:digit:]](-|-remote)(20[0-9][0-9](0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])([01][0-9]|2[0-3])[0-5][0-9])([0-5][0-9])?(-[0-9]{1,2})?$'
  BA_P=""; BA_K=""; BA_STAMP=""
  [[ $n =~ $kre ]] || return 1
  BA_P="${BASH_REMATCH[2]}"; BA_K="${BASH_REMATCH[3]}"
  [[ $n =~ $sre ]] || { BA_P=""; BA_K=""; return 1; }
  BA_STAMP="${BASH_REMATCH[2]}${BASH_REMATCH[6]:-00}"
}

# ba_index_append <h> <dir> <relpath> <project> <key> <ticket_id> <result1>
#   One row under flock on locks/builds-archive-index.lock (a few-ms critical
#   section). Tabs, CR and newlines in any field are stripped. rc 1 when the
#   row could not be written.
ba_index_append() {
  local h="${1:-}" idx f row="" i
  [ -n "$h" ] || return 1
  idx=$(ba_index "$h") || return 1
  mkdir -p "$h/builds-archive" "$h/locks" 2>/dev/null || return 1
  shift
  for i in 1 2 3 4 5 6; do
    f="${1:-}"; shift 2>/dev/null
    f="${f//$'\t'/ }"; f="${f//$'\r'/}"; f="${f//$'\n'/ }"
    [ "$i" = 6 ] && f="${f:0:200}"
    [ -n "$f" ] || f="-"
    row="$row"$'\t'"$f"
  done
  (
    flock -w 10 9 || exit 1
    [ -s "$idx" ] || printf '#archived_at\tdir\trelpath\tproject\tkey\tticket_id\tresult1\n' >> "$idx"
    printf '%s%s\n' "${BA_NOW_ISO:-$(date -u +%FT%TZ)}" "$row" >> "$idx"
  ) 9>>"$h/locks/builds-archive-index.lock"
}

# _ba_rows <h> <awk-filter-var> ... — internal: the relpaths of the rows that
# match, deduped, newest row first (index order reversed). One awk pass.
_ba_rel() {
  local h="$1" mode="$2" a="$3" b="${4:-}" idx
  idx=$(ba_index "$h") || return 2
  [ -r "$idx" ] || return 2
  awk -F'\t' -v m="$mode" -v a="$a" -v b="$b" '
    /^#/ || NF < 7 || $7 == "MOVE_FAILED" { next }
    m == "key" && $4 == a && $5 == b { r[++n] = $3; next }
    m == "dir" && ($2 == a || $2 == "pool-" a || $2 == "fly-" a) { r[++n] = $3 }
    END { for (i = n; i >= 1; i--) if (!(r[i] in s)) { s[r[i]] = 1; print r[i] } }
  ' "$idx" 2>/dev/null
}

# ba_dirs <h> <project> <key> — the absolute archive paths of the dirs of
# EXACTLY that key (prefixes '', pool-, fly-), newest stamp first. Matches the
# project and key FIELDS, never a prefix, so TK-8 never collects TK-88. Prints
# only paths that are dirs. rc 0 when it printed one, rc 2 otherwise.
ba_dirs() {
  local h="${1:-}" p="${2:-}" k="${3:-}" r root out=""
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 2
  root=$(ba_root "$h") || return 2
  while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$root/$r" ] || continue
    ba_parse "$r" && out="$out$BA_STAMP"$'\t'"$root/$r"$'\n'
  done < <(_ba_rel "$h" key "$p" "$k")
  [ -n "$out" ] || return 2
  printf '%s' "$out" | sort -r -k1,1 | cut -f2-
}

# ba_has_key <h> <project> <key> — rc 0 when an archived dir of the key exists.
ba_has_key() { [ -n "$(ba_dirs "$@" 2>/dev/null)" ]; }

# ba_path <h> <dirname> — the archive path of one dir, given its basename with
# or without the pool-/fly- prefix (the same three names bor_local_dir tries).
# rc 0 + the path, rc 2 when it is not archived.
ba_path() {
  local h="${1:-}" n="${2:-}" r root
  [ -n "$h" ] && [ -n "$n" ] || return 2
  root=$(ba_root "$h") || return 2
  while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$root/$r" ] && { printf '%s\n' "$root/$r"; return 0; }
  done < <(_ba_rel "$h" dir "$n")
  return 2
}

# ba_merged_other <h> <project> <ticket_id> <normalized-key> — for
# ticket_identity_conflict: an archived key of the same project and board
# ticket id, under ANOTHER key, whose group holds a PR_MERGED row. Prints
# "<key>\t<archive path>" of the first one. rc 0 found, rc 2 none.
# The QUEUED_FLY stub carries the job.json (the ticket id) and the pool twin
# the PR_MERGED line, so the id and the result are joined per key.
ba_merged_other() {
  local h="${1:-}" p="${2:-}" tid="${3:-}" keyn="${4:-}" idx root k r
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$tid" ] || return 2
  idx=$(ba_index "$h") || return 2
  [ -r "$idx" ] || return 2
  root=$(ba_root "$h") || return 2
  while IFS=$'\t' read -r k r; do
    [ -n "$k" ] && [ -d "$root/$r" ] || continue
    printf '%s\t%s\n' "$k" "$root/$r"; return 0
  done < <(awk -F'\t' -v p="$p" -v t="$tid" -v kn="$keyn" '
    /^#/ || NF < 7 || $4 != p || $7 == "MOVE_FAILED" { next }
    { lk = tolower($5); gsub(/[[:space:]]/, "", lk); if (lk == kn) next }
    $6 == t { hit[$5] = 1 }
    $7 ~ /^PR_MERGED/ { mg[$5] = $3 }
    END { for (k in hit) if (k in mg) print k "\t" mg[k] }
  ' "$idx" 2>/dev/null | sort)
  return 2
}
