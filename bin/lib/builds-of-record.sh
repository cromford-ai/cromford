#!/bin/bash
# bin/lib/builds-of-record.sh — THE BUILDS OF RECORD, READ FROM THE LEDGER
# (BH-2347, slice 1 of BH-2312). Sourced, never executed; defines functions only.
#
# Four lanes used to learn "which builds did this project record" by scanning
# builds/*/RESULT on one box. The binding (result, pr_url) is already written to
# the jobs ledger; this is its read side. The caller sources bin/jobs-client.sh
# first (as bin/merge-sweep.sh does). Without job_artifact_feed every call is rc 1.
#
# bor_list <project> [since] [limit]
#   Two feed calls (kind result, kind pr_url) joined on job_id in one awk pass.
#   TSV: key, build_dir, box, updated_at, result_line, pr_url (or -), job_id.
#   key and build_dir come from the result row's detail JSON; build_dir loses the
#   hub's pool-/fly- copy prefix (as job_for_record does) and only its newest row
#   is kept. A result row with no build_dir cannot be keyed and is skipped.
#   rc 0 rows printed, rc 2 the worker answered with none, rc 1 outage on EITHER
#   feed or no client: NOTHING is printed, since a half join reads as "no PR".
#   limit: arg, else BOR_LIMIT (the lib knob lib.builds-of-record.bor_limit,
#   applied when the caller has sourced bin/lib/lane-gate.sh), else 500.
#   A feed that returns `limit` rows was cut off: BOR_TRUNCATED=1 goes to stderr
#   AND is exported. The export only reaches a caller that calls bor_list
#   directly, not inside $(...), which is why the stderr line exists.
#   Refs stay exactly as jq @tsv wrote them: an escaped \t or \n in a ref is two
#   literal characters here and never an extra column or row.
#
# bor_local_dir <build_dir>
#   The on-disk dir under $H/builds for a ledger build_dir: the exact name, then
#   pool-<name>, then fly-<name>. rc 2 and nothing printed when none exists.
#
# bor_union <project>
#   bor_list's rows, then one row per local <project>-<KEY>-*/RESULT (bare, pool-
#   or fly- copy) the ledger does not name: box, pr_url and job_id are `-`,
#   updated_at is the RESULT mtime, result_line its first line (tabs made spaces).
#   A record in both appears once, with the ledger's row. The rest of the dir
#   name must start with a ticket key, so project `project-4` never takes in
#   `project-4-TK-1-1`. rc 1 from bor_list is rc 1 here with nothing printed, so a
#   caller keeps its file path on an outage. bor_list runs in a subshell here:
#   its BOR_TRUNCATED stderr line passes through, the export does not.

bor_list() {
  local p="${1:-}" since="${2:-}" limit res prs out
  unset BOR_TRUNCATED
  [ -n "$p" ] || return 1
  command -v job_artifact_feed >/dev/null 2>&1 || return 1
  if [ "${LANE_GATE_DISABLE:-0}" != 1 ] && command -v lib_env_apply >/dev/null 2>&1; then
    lib_env_apply builds-of-record >/dev/null 2>&1
  fi
  limit="${3:-${BOR_LIMIT:-500}}"
  case "$limit" in ''|*[!0-9]*|0) limit=500 ;; esac
  res=$(job_artifact_feed result "$p" "$since" "$limit") || return 1
  prs=$(job_artifact_feed pr_url "$p" "$since" "$limit") || return 1
  if [ "$(printf '%s\n' "$res" | grep -c .)" -ge "$limit" ] \
     || [ "$(printf '%s\n' "$prs" | grep -c .)" -ge "$limit" ]; then
    printf 'BOR_TRUNCATED=1\n' >&2
    export BOR_TRUNCATED=1
  fi
  out=$(awk -F'\t' '
    FILENAME == ARGV[1] { if (NF >= 2 && !($1 in pr)) pr[$1] = $2; next }
    NF >= 6 {
      b = ""; k = "-"
      if (match($6, /"build_dir":"[^"]*"/)) b = substr($6, RSTART + 13, RLENGTH - 14)
      sub(/^pool-/, "", b); sub(/^fly-/, "", b)
      if (b == "") next
      if (match($6, /"key":"[^"]*"/)) k = substr($6, RSTART + 7, RLENGTH - 8)
      if (k == "") k = "-"
      # Newest first from the feed; on a tie the first seen stays.
      if ((b in ts) && ts[b] >= $5) next
      if (!(b in ts)) order[++n] = b
      ts[b] = $5
      row[b] = k "\t" b "\t" $3 "\t" $5 "\t" $2 "\t" (($1 in pr) ? pr[$1] : "-") "\t" $1
    }
    END { for (i = 1; i <= n; i++) print row[order[i]] }
  ' <(printf '%s\n' "$prs") <(printf '%s\n' "$res"))
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

bor_local_dir() {
  local n="${1:-}" b d
  [ -n "$n" ] || return 1
  # No root: no local build dir can be found (rc 2, not found).
  [ -n "${H:-${HARNESS:-}}" ] || return 2
  b="${H:-${HARNESS:-}}/builds"
  for d in "$b/$n" "$b/pool-$n" "$b/fly-$n"; do
    [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 2
}

bor_union() {
  local p="${1:-}" rows rc b f name rest ts line out="" results k
  # LINEAR, NOT QUADRATIC (BH-9952). The duplicate check was a `case` match on
  # a string that grew by one name per RESULT, and each RESULT forked one
  # `date -u -r`, and `out="$out..."` copied the whole output once per row:
  # about 10,000 names on the hub, 600 s per call. Now `seen` is
  # an associative array, and ONE find gives every RESULT mtime. A RESULT the
  # find did not list (written after it, a symlink) takes the old date fork.
  # The output is appended with +=, which does not copy it.
  local -A seen=() mt=()
  [ -n "$p" ] || return 1
  rows=$(bor_list "$p"); rc=$?
  [ "$rc" = 1 ] && return 1
  # No root: the DB rows only, no local RESULT scan.
  b="${H:-${HARNESS:-}}"; results=()
  [ -n "$b" ] && b="$b/builds" && results=("$b/$p"-*/RESULT "$b/pool-$p"-*/RESULT "$b/fly-$p"-*/RESULT)
  # Column 2 of each ledger row (the whole line when it has no tab, as cut does).
  while IFS= read -r line; do
    k="${line#*$'\t'}"; k="${k%%$'\t'*}"
    [ -n "$k" ] && seen["$k"]=1
  done <<<"$rows"
  if [ "${#results[@]}" -gt 0 ]; then
    while IFS= read -r line; do
      f="${line%$'\t'*}"; ts="${line##*$'\t'}"
      [ -n "$f" ] && [ "$f" != "$line" ] && mt["$f"]="${ts%%.*}Z"
    done < <(TZ=UTC find "$b" -mindepth 2 -maxdepth 2 -type f -name RESULT \
               \( -path "$b/$p-*" -o -path "$b/pool-$p-*" -o -path "$b/fly-$p-*" \) \
               -printf '%p\t%TY-%Tm-%TdT%TH:%TM:%TS\n' 2>/dev/null)
  fi
  for f in ${results[@]+"${results[@]}"}; do
    [ -f "$f" ] || continue
    name="${f%/RESULT}"; name="${name##*/}"; name="${name#pool-}"; name="${name#fly-}"
    rest="${name#"$p"-}"
    [[ "$rest" =~ ^([A-Z][A-Z0-9]*-[0-9]+) ]] || continue
    k="${BASH_REMATCH[1]}"
    [ -n "${seen[$name]+x}" ] && continue
    seen["$name"]=1
    ts="${mt[$f]:-}"
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
      || { ts=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts=-; }
    line=""; IFS= read -r line < "$f"
    out+="$k"$'\t'"$name"$'\t-\t'"$ts"$'\t'"${line//$'\t'/ }"$'\t-\t-\n'
  done
  [ -n "$rows" ] && printf '%s\n' "$rows"
  printf '%s' "$out"
  [ -n "$rows$out" ] || return 2
}
