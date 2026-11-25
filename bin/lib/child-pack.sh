#!/bin/bash
# bin/lib/child-pack.sh — a split child plans FROM its parent's plan (BH-9537).
# Sourced, never run. Sourcing only defines functions.
#
# BH-9417's three children each planned for longer than the parent did. Their
# context packs (bin/lib/context-pack-compose.sh) held 1 of 44 inventory paths,
# no commit and no sibling list, and the pack's WARM START line rode in front
# of a plan prompt that then ordered a full survey. Nothing told the child what
# the pack replaced, so every child re-surveyed. This lib completes the pack on
# the decompose side and tells the child plan what the pack replaces.
#
# Writer (bin/run-decompose.sh dcp_publish, after cp_compose):
#   cpk_extend <pack> <spec|""> <idx> <children.txt> <parent-plan.md> <sha>
#     Appends to <pack>, after cp_compose's bytes (which do not change):
#       ## File map            `Read at: <sha>` then one row per child path:
#                              `- <path> :: <the parent plan's Files to touch
#                              lines that name it, joined by " / ">` or
#                              `- <path> :: not in the parent plan's files to touch`
#       ## Siblings            `- <key> (<n> of <N>): <owns>, ...` or `(no owns list)`
#       Section: complete      or `Section: incomplete (<first missing item>)`
#     Child paths: the spec entry's .owns, then each `## Parent file inventory`
#     path the child's body names (dedup, order kept). Complete means: a spec
#     entry, .owns with 1+ paths, and a `##`/`###` heading `Acceptance tests`
#     and one `Observable outcome` in the body. The board lane passes "" (no
#     spec) and its packs say `Section: incomplete (no spec entry)`.
#     Cap: CP_MAX_BYTES (default 64000, the wire's 413 limit). Over it the map
#     drops to bare paths, then the Siblings list becomes one `omitted:` line,
#     then nothing is appended. rc 0 extended / rc 1 not (prints why); the pack
#     is then exactly cp_compose's bytes.
#
# Readers (bin/lib/rb/plan.sh):
#   cpk_complete <pack>      rc 0 only when the LAST line is exactly
#                            `Section: complete` and the Child scope section is
#                            not empty.
#   cpk_section <pack>       prints `## Child scope` through the line before
#                            `## Parent file inventory`, verbatim.
#   cpk_changed <pack> <repo> <baseref>
#                            prints each File map path that changed between the
#                            pack's `Read at:` commit and <baseref> (the path, or
#                            a file under it). No commit, or one the checkout
#                            cannot reach: every path with ` (unverifiable)`.
#   cpk_rule <pack> <repo> <baseref> <adopt 0|1>
#                            the "pack is the survey" prompt text. rc 1 and
#                            nothing printed for a pack with no File map.
#   cpk_tokens <project> <child> <parent> <build>
#                            `tokens child=<n> parent=<n> ratio=<x.xx> out=<c>/<p>`
#                            or `tokens UNMEASURED <why>`. Cache-read tokens of
#                            the PLAN stage: the child's from <build>/cost.csv
#                            (by header name), else the worker; the parent's
#                            from the worker, stages preplan and plan. No
#                            child plan row at all, a failed or full read, or
#                            a parent total of 0 is UNMEASURED, never 0.
#
# Fail-open: nothing here exits, alerts or writes a RESULT.

# _cpk_files_to_touch <plan> — the body lines of every `## Files to touch`
# section (heading excluded), outside fences, same section rule as
# bin/lib/context-pack-compose.sh:_cpc_sections.
_cpk_files_to_touch() {
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; if (on) print; next }
    !fence && /^#+[[:space:]]/ {
      lvl = match($0, /[^#]/) - 1
      t = tolower($0); sub(/^#+[[:space:]]+/, "", t)
      if (index(t, "sibling claims") == 1) { on = 0; next }
      if (lvl <= 2) { on = (lvl == 2 && index(t, "files to touch") == 1); next }
    }
    on { print }
  ' "$1" 2>/dev/null
}

# _cpk_inventory <pack> — the path lines of the pack's `## Parent file inventory`.
_cpk_inventory() {
  awk '
    $0 == "## Parent file inventory" { on = 1; next }
    on && /^## / { exit }
    on && NF && $0 !~ /^(filtered: |unfiltered)/ { print }
  ' "$1" 2>/dev/null
}

# _cpk_owns <spec> <idx> — the entry's .owns strings, one per line.
_cpk_owns() {
  jq -r --argjson i "$2" '(.[$i].owns // []) | if type == "array" then .[] | select(type == "string" and . != "") else empty end' "$1" 2>/dev/null
}

# _cpk_why <spec> <idx> <bodyfile> — empty when the section is complete,
# else the first missing item.
_cpk_why() {
  local spec="$1" i="$2" bf="$3"
  if [ -z "$spec" ] || ! jq -e --argjson i "$i" '.[$i] | type == "object"' "$spec" >/dev/null 2>&1; then
    echo "no spec entry"; return
  fi
  [ -n "$(_cpk_owns "$spec" "$i")" ] || { echo "no owns list"; return; }
  grep -Eiq '^#{2,3}[[:space:]]+acceptance tests([[:space:](:].*)?$' "$bf" 2>/dev/null \
    || { echo "no Acceptance tests heading"; return; }
  grep -Eiq '^#{2,3}[[:space:]]+observable outcome([[:space:](:].*)?$' "$bf" 2>/dev/null \
    || { echo "no Observable outcome heading"; return; }
}

cpk_extend() {
  local pack="${1:-}" spec="${2:-}" idx="${3:-}" kids="${4:-}" plan="${5:-}" sha="${6:-}"
  local cap tmp bf p rows ftt why n=0 total k o map_full map_bare sibs add lvl base
  [ -n "$pack" ] && [ -s "$pack" ] || { echo "no pack"; return 1; }
  case "$idx" in ""|*[!0-9]*) echo "bad index"; return 1 ;; esac
  [ -n "$spec" ] && { [ -r "$spec" ] || spec=""; }
  cap="${CP_MAX_BYTES:-64000}"; case "$cap" in ""|*[!0-9]*) cap=64000 ;; esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/cpk-extend.XXXXXX") || { echo "no temp dir"; return 1; }
  bf="$tmp/body"; : > "$bf"
  [ -n "$spec" ] && jq -r --argjson i "$idx" '.[$i].body // empty' "$spec" > "$bf" 2>/dev/null

  # The child's paths: .owns, then each inventory path its body names.
  { [ -n "$spec" ] && _cpk_owns "$spec" "$idx"
    if [ -s "$bf" ]; then
      _cpk_inventory "$pack" | while IFS= read -r p; do grep -qF -- "$p" "$bf" && printf '%s\n' "$p"; done
    fi; } | awk 'NF && !seen[$0]++' > "$tmp/paths"

  ftt="$tmp/ftt"
  if [ -n "$plan" ] && [ -r "$plan" ]; then _cpk_files_to_touch "$plan" > "$ftt"; else : > "$ftt"; fi
  map_full="## File map"$'\n'"Read at: ${sha:-unknown}"$'\n'
  map_bare="$map_full"
  while IFS= read -r p; do
    rows=$(grep -F -- "$p" "$ftt" 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'BEGIN{ORS=""} NR>1{print " / "} {print}')
    [ -n "$rows" ] || rows="not in the parent plan's files to touch"
    map_full="$map_full- $p :: $rows"$'\n'
    map_bare="$map_bare- $p"$'\n'
  done < "$tmp/paths"

  sibs="## Siblings"$'\n'
  if [ -n "$kids" ] && [ -r "$kids" ]; then
    total=$(grep -c . "$kids")
    while IFS= read -r k || [ -n "$k" ]; do
      n=$((n + 1))
      [ -n "$k" ] && [ "$n" != "$((idx + 1))" ] || continue
      o=""
      [ -n "$spec" ] && o=$(_cpk_owns "$spec" "$((n - 1))" | paste -sd, - | sed 's/,/, /g')
      sibs="$sibs- $k ($n of $total): ${o:-(no owns list)}"$'\n'
    done < "$kids"
  fi

  why=$(_cpk_why "$spec" "$idx" "$bf")
  if [ -n "$why" ]; then lvl="Section: incomplete ($why)"; else lvl="Section: complete"; fi

  base=$(LC_ALL=C wc -c < "$pack" | tr -d ' ')
  for n in 0 1 2; do
    case "$n" in
      0) add=$'\n'"$map_full"$'\n'"$sibs"$'\n'"$lvl" ;;
      1) add=$'\n'"$map_bare"$'\n'"$sibs"$'\n'"$lvl" ;;
      2) add=$'\n'"$map_bare"$'\n'"omitted: siblings (pack cap)"$'\n\n'"$lvl" ;;
    esac
    if [ $((base + $(printf '%s\n' "$add" | LC_ALL=C wc -c | tr -d ' '))) -le "$cap" ]; then
      { cat "$pack"; printf '%s\n' "$add"; } > "$tmp/out" && mv -f "$tmp/out" "$pack" \
        || { rm -rf "$tmp"; echo "write failed"; return 1; }
      rm -rf "$tmp"
      return 0
    fi
  done
  rm -rf "$tmp"
  echo "over the pack cap"
  return 1
}

cpk_section() {
  local pack="${1:-}"
  [ -n "$pack" ] && [ -s "$pack" ] || return 1
  awk '
    !on && $0 == "## Child scope" { on = 1 }
    on && $0 == "## Parent file inventory" { exit }
    on { print }
  ' "$pack"
}

cpk_complete() {
  local pack="${1:-}" sec
  [ -n "$pack" ] && [ -s "$pack" ] || return 1
  [ "$(tail -n1 "$pack")" = "Section: complete" ] || return 1
  sec=$(cpk_section "$pack" | sed '1d' | tr -d '[:space:]')
  [ -n "$sec" ]
}

# _cpk_map_paths <pack> — the File map paths, one per line.
_cpk_map_paths() {
  awk '
    $0 == "## File map" { on = 1; next }
    on && /^## / { exit }
    on && /^- / { p = substr($0, 3); i = index(p, " :: "); if (i) p = substr(p, 1, i - 1); if (p != "") print p }
  ' "$1" 2>/dev/null
}

_cpk_sha() { awk '$0 == "## File map" { on = 1; next } on && /^Read at: / { print $3; exit } on && /^## / { exit }' "$1" 2>/dev/null; }

cpk_changed() {
  local pack="${1:-}" repo="${2:-}" ref="${3:-}" sha p q d hit
  [ -n "$pack" ] && [ -s "$pack" ] || return 1
  sha=$(_cpk_sha "$pack")
  if [ -z "$sha" ] || [ -z "$repo" ] \
     || ! git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null \
     || ! d=$(git -C "$repo" diff --name-only "$sha" "$ref" -- 2>/dev/null); then
    _cpk_map_paths "$pack" | while IFS= read -r p; do printf '%s (unverifiable)\n' "$p"; done
    return 0
  fi
  _cpk_map_paths "$pack" | while IFS= read -r p; do
    q="${p%/}"; hit=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in "$q"|"$q"/*) hit=1; break ;; esac
    done <<<"$d"
    [ "$hit" = 1 ] && printf '%s\n' "$p"
  done
  return 0
}

cpk_rule() {
  local pack="${1:-}" repo="${2:-}" ref="${3:-}" adopt="${4:-0}" sha ch
  [ -n "$pack" ] && [ -s "$pack" ] && grep -qx '## File map' "$pack" || return 1
  sha=$(_cpk_sha "$pack"); sha="${sha:0:12}"
  ch=$(cpk_changed "$pack" "$repo" "$ref" | paste -sd, - | sed 's/,/, /g')
  printf '%s\n' "THE PACK IS THE SURVEY. It replaces the primer read, the codegraph pass and the repo survey for every path in its File map. Read a file only when the pack does not cover it or it is listed below as changed since the pack. Do not plan a path a sibling in the Siblings list owns. Still read the ticket thread, newest first."
  printf 'CHANGED SINCE THE PACK (%s): %s\n' "${sha:-no commit}" "${ch:-none}"
  [ "$adopt" = 1 ] && printf '%s\n' "YOUR DRAFT PLAN IS THE CHILD SCOPE SECTION ABOVE. Check it against the changed files and the thread, amend it, and write it to plan.md in the contract shape below. Do not plan this child from nothing."
  return 0
}

# _cpk_csv_sum <cost.csv> — `<cache_read> <output_toks> <rows>` over stage=plan.
_cpk_csv_sum() {
  awk -F, '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; if (!c["stage"] || !c["cache_read"]) exit 1; next }
    $c["stage"] == "plan" { n++; cr += $c["cache_read"] + 0; if (c["output_toks"]) o += $c["output_toks"] + 0 }
    END { printf "%d %d %d\n", cr, o, n }
  ' "$1" 2>/dev/null
}

# _cpk_worker_sum <project> <ticket> <stage> — `<cache_read> <output_toks> <rows>`, or the reason on rc 1.
_cpk_worker_sum() {
  local resp n
  resp=$(_jobs_req GET "/api/metrics/cost-rows?project=$(jq -rn --arg v "$1" '$v|@uri')&ticket=$(jq -rn --arg v "$2" '$v|@uri')&stage=$(jq -rn --arg v "$3" '$v|@uri')&limit=2000" 2>/dev/null) \
    || { echo "read failed"; return 1; }
  n=$(printf '%s' "$resp" | jq -er '.cost_rows | if type == "array" then length else error end' 2>/dev/null) \
    || { echo unparseable; return 1; }
  [ "$n" -ge 2000 ] && { echo "truncated (2000-row page)"; return 1; }
  printf '%s' "$resp" | jq -r --arg s "$3" '[.cost_rows[] | select(type == "object" and .stage == $s)]
    | def n(f): [.[] | f | if type == "number" then . elif type == "string" then (tonumber? // empty) else empty end] | add // 0;
      "\(n(.cache_read) | floor) \(n(.output_toks) | floor) \(length)"' 2>/dev/null \
    || { echo unparseable; return 1; }
}

cpk_tokens() {
  local p="${1:-}" c="${2:-}" pa="${3:-}" b="${4:-}" v cc=0 co=0 pc=0 po=0 rows=0 s
  case "$p$c$pa" in *[!A-Za-z0-9._-]*) echo "tokens UNMEASURED bad arguments"; return 0 ;; esac
  [ -n "$p" ] && [ -n "$c" ] && [ -n "$pa" ] && [ "$c" != "$pa" ] || { echo "tokens UNMEASURED bad arguments"; return 0; }
  if [ -n "$b" ] && [ -s "$b/cost.csv" ] && v=$(_cpk_csv_sum "$b/cost.csv") && [ -n "$v" ]; then
    read -r cc co rows <<<"$v"
  fi
  if ! command -v _jobs_req >/dev/null 2>&1; then
    { command -v _cpt_ensure_client >/dev/null 2>&1 && _cpt_ensure_client; } \
      || { command -v _cp_ensure_client >/dev/null 2>&1 && _cp_ensure_client; } \
      || { echo "tokens UNMEASURED no jobs client"; return 0; }
  fi
  if [ "${rows:-0}" -eq 0 ]; then
    v=$(_cpk_worker_sum "$p" "$c" plan) || { echo "tokens UNMEASURED $c plan $v"; return 0; }
    read -r cc co rows <<<"$v"
    # No plan row anywhere is not a child that spent 0 tokens (D11).
    [ "${rows:-0}" -gt 0 ] || { echo "tokens UNMEASURED no child plan rows"; return 0; }
  fi
  for s in preplan plan; do
    v=$(_cpk_worker_sum "$p" "$pa" "$s") || { echo "tokens UNMEASURED $pa $s $v"; return 0; }
    set -- $v
    pc=$((pc + $1)); po=$((po + $2))
  done
  [ "$pc" -gt 0 ] || { echo "tokens UNMEASURED no parent baseline"; return 0; }
  LC_ALL=C printf 'tokens child=%d parent=%d ratio=%s out=%d/%d\n' "$cc" "$pc" \
    "$(awk -v a="$cc" -v b="$pc" 'BEGIN { printf "%.2f", a / b }')" "$co" "$po"
}
