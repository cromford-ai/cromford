# shellcheck shell=bash
# bin/lib/additive-overlap.sh — BH-9922: a collision on an additive shared file
# alone does not serialize two builds.
# Sourced, never executed. Defines functions only; safe under `set -u`.
#
# WHY. On project-3, 2026-11-23, seven plans stood down behind TK-797 (PR #1326)
# for 2 hours. The shared file was prisma/schema.prisma: PR #1326 adds fields
# inside model Application, and the seven tickets were about recordings, credits
# and events. Both sides only add to the file. The merge queue rebases and
# checks each PR, and Schema Drift Check is a required check there, so a defer
# on that file bought nothing.
#
# THE RULE. A pair `<p> ~ <q>` is additive-safe when both sides match the SAME
# entry of the list (ao_paths) and:
#   - the entry is not a `.prisma` file (docs/API.md, a change-log fragment): safe;
#   - the entry is a `.prisma` file: the two sides touch no common
#     model/enum/type/view block, and neither side changes a datasource or
#     generator block. The candidate side is the main-schema blocks its plan.md
#     names (ao_plan_blocks). The other side is a blocks file: from the other
#     plan (ao_plan_blocks) or from the open PR's patch (ao_patch_blocks).
# An unknown side (no blocks file, a `?` in it, main's schema unreadable) is
# UNJUDGED and kept as a collision. A missed overlap costs one rebase; a
# guessed one is never a drop.
#
# Functions:
#   ao_paths <project>       the list, one entry per line (see THE KNOB)
#   ao_entry <path>          the entry that matches <path>; rc 1 for none
#   ao_schema_blocks <file>  `model:X` / `enum:X` / `type:X` / `view:X` /
#                            `datasource:X` / `generator:X` of a schema
#   ao_plan_blocks <plan.md> <schema file>
#                            the schema blocks the plan names (whole word,
#                            case-sensitive; a datasource or generator block
#                            only when the plan also names its kind word),
#                            plus `new:<X>` for `model <X>` the
#                            plan names that the schema has not got
#   ao_patch_blocks <patch file>
#                            the blocks a unified diff of a schema changes:
#                            model:X, enum:X, type:X, view:X, datasource:X,
#                            generator:X; `?` for an empty patch or a change
#                            outside any known block
#   ao_pair_judge "<p> ~ <q>" <cand plan.md> <other blocks file|->
#                            rc 0 safe; rc 1 collision (AO_SYMBOLS = up to 3
#                            comma-joined symbols, may be empty); rc 2 unjudged
#                            (kept as a collision, AO_WHY says why)
# The schema of main is "$AO_REPO_DIR/<entry>" (the caller sets AO_REPO_DIR).
#
# THE KNOB. PLAN_OVERLAP_ADDITIVE_FILES (lib plan-hotspot,
# catalog/lanes.d/_lib.plan-hotspot.knobs.d/PLAN_OVERLAP_ADDITIVE_FILES.json):
# the settings row lib.plan-hotspot.<project>.plan_overlap_additive_files, then
# lib.plan-hotspot.plan_overlap_additive_files (lib_env_apply), then env, then
# env/global.env, then AO_DEFAULT below. `off` = an empty list (the rule off).
# An entry that ends `/` is a directory: the bare dir or any path under it.

# The documented fallback of the knob PLAN_OVERLAP_ADDITIVE_FILES
# (catalog/lanes.d/_lib.plan-hotspot.knobs.d/PLAN_OVERLAP_ADDITIVE_FILES.json).
AO_DEFAULT='prisma/schema.prisma docs/DATABASE.md docs/API.md changelog.d/ .changeset/ docs/changes/'

ao_paths() {
  local p="${1:-${AO_PROJECT:-}}" v="" genv root="${HARNESS:-${H:-}}" e
  if [ -z "${_AO_LIST_SET:-}" ]; then
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply plan-hotspot "$p" >/dev/null 2>&1
    v="${PLAN_OVERLAP_ADDITIVE_FILES:-}"
    if [ -z "$v" ] && [ -n "$root" ]; then
      if ! command -v harness_env_dir >/dev/null 2>&1; then
        # shellcheck source=bin/lib/env-path.sh
        . "${BASH_SOURCE[0]%/*}/env-path.sh" 2>/dev/null || :
      fi
      if command -v harness_env_dir >/dev/null 2>&1; then genv="$(harness_env_dir "$root" 2>/dev/null)/global.env"
      else genv="$root/env/global.env"; fi
      if [ -r "$genv" ]; then
        v=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}PLAN_OVERLAP_ADDITIVE_FILES=//p' \
            "$genv" | tr -d "\"'" | tail -1)
      fi
    fi
    [ -n "$v" ] || v="$AO_DEFAULT"
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]' | tr -d ' \t')" in
      off|0|false|no|none) v="" ;;
    esac
    _AO_LIST=""
    # Split on white space only: an entry is never globbed.
    local -a _ao_w=()
    read -r -a _ao_w <<<"$v"
    for e in ${_ao_w[@]+"${_ao_w[@]}"}; do
      [ -n "$e" ] && _AO_LIST="$_AO_LIST$e"$'\n'
    done
    _AO_LIST_SET=1
  fi
  printf '%s' "$_AO_LIST"
}

ao_entry() {
  local path="${1:-}" e d
  path="${path%/}"
  [ -n "$path" ] || return 1
  [ -n "${_AO_LIST_SET:-}" ] || ao_paths "${AO_PROJECT:-}" >/dev/null
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in
      */) d="${e%/}"
          if [ "$path" = "$d" ] || [ "${path#"$d"/}" != "$path" ]; then printf '%s\n' "$e"; return 0; fi ;;
      *)  [ "$path" = "$e" ] && { printf '%s\n' "$e"; return 0; } ;;
    esac
  done <<<"$_AO_LIST"
  return 1
}

ao_schema_blocks() {
  [ -r "${1:-}" ] || return 1
  awk '
    { sub(/\r$/, "") }
    match($0, /^[[:space:]]*(model|enum|type|view|datasource|generator)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\{/) {
      split($0, w, /[[:space:]{]+/); k = (w[1] == "" ? w[2] : w[1]); n = (w[1] == "" ? w[3] : w[2])
      if (!s[k":"n]++) print k":"n
    }' "$1"
}

ao_plan_blocks() {
  local plan="${1:-}" schema="${2:-}"
  [ -r "$plan" ] || return 1
  ao_schema_blocks "$schema" > "${_AO_TMP:=$(mktemp "${TMPDIR:-/tmp}/ao.XXXXXX")}" 2>/dev/null || : > "$_AO_TMP"
  awk -v blocks="$_AO_TMP" '
    BEGIN { while ((getline l < blocks) > 0) { split(l, a, ":"); have[a[2]] = l; kind[a[2]] = a[1]; order[++n] = a[2] } }
    {
      line = $0
      while (match(line, /[A-Za-z_][A-Za-z0-9_]*/)) {
        w = substr(line, RSTART, RLENGTH)
        if (prev == "model" && !(w in have) && !nw[w]++) newm[++nn] = w
        seen[w] = 1; prev = w
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END {
      # A datasource or generator block counts only when the plan also names
      # its kind word (`generator client`): `client` alone is ordinary prose.
      for (i = 1; i <= n; i++) {
        m = order[i]
        if (!(m in seen)) continue
        if ((kind[m] == "datasource" || kind[m] == "generator") && !(kind[m] in seen)) continue
        print have[m]
      }
      for (i = 1; i <= nn; i++) print "new:" newm[i]
    }' "$plan"
  rm -f "$_AO_TMP"; _AO_TMP=""
}

ao_patch_blocks() {
  local f="${1:-}"
  if [ ! -s "$f" ]; then echo '?'; return 0; fi
  awk '
    function blk(s,   w) {
      if (match(s, /^[[:space:]]*(model|enum|type|view|datasource|generator)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\{/)) {
        split(s, w, /[[:space:]{]+/)
        return (w[1] == "" ? w[2] ":" w[3] : w[1] ":" w[2])
      }
      return ""
    }
    function out(b) { if (b == "") b = "?"; if (!s[b]++) print b; n++ }
    { sub(/\r$/, "") }
    /^@@/ {
      ctx = $0; sub(/^@@[^@]*@@[[:space:]]?/, "", ctx)
      cur = blk(ctx); next
    }
    /^(\+\+\+|---) / { next }
    /^\\/ { next }
    {
      c = substr($0, 1, 1); body = substr($0, 2)
      b = blk(body)
      if (b != "") cur = b
      if (c == "+" || c == "-") {
        t = body; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
        if (t != "" && substr(t, 1, 2) != "//") out(cur)
      }
      if (body ~ /^[[:space:]]*\}/) cur = ""
    }
    END { if (!n) print "?" }' "$f"
}

ao_pair_judge() {
  local pr="${1:-}" cand="${2:-}" other="${3:--}" p q ep eq schema cb ob common
  AO_SYMBOLS=""; AO_WHY=""
  p="${pr%% ~ *}"; q="${pr#* ~ }"
  ep=$(ao_entry "$p") || { AO_WHY="not additive: $p"; return 1; }
  eq=$(ao_entry "$q") || { AO_WHY="not additive: $q"; return 1; }
  [ "$ep" = "$eq" ] || { AO_WHY="different entries"; return 1; }
  case "$ep" in *.prisma) ;; *) return 0 ;; esac
  if [ "$other" = - ] || [ ! -r "$other" ]; then AO_WHY="other side's blocks unknown"; return 2; fi
  if grep -qxF '?' "$other" 2>/dev/null; then AO_WHY="other side's patch unreadable"; return 2; fi
  ob=$(awk '/^(datasource|generator):/ && !s[$0]++ && ++n <= 3' "$other" 2>/dev/null | paste -sd, -)
  if [ -n "$ob" ]; then AO_SYMBOLS="$ob"; AO_WHY="datasource/generator edit"; return 1; fi
  schema="${AO_REPO_DIR:-}/$ep"
  [ -n "${AO_REPO_DIR:-}" ] && [ -r "$schema" ] || { AO_WHY="main schema unreadable"; return 2; }
  cb=$(ao_plan_blocks "$cand" "$schema" 2>/dev/null | sed 's/^new:/model:/' | sort -u)
  # The candidate's own datasource/generator edit is a collision too.
  ob=$(awk '/^(datasource|generator):/ && !s[$0]++ && ++n <= 3' <<<"$cb" 2>/dev/null | paste -sd, -)
  if [ -n "$ob" ]; then AO_SYMBOLS="$ob"; AO_WHY="datasource/generator edit"; return 1; fi
  common=$(awk 'NR == FNR { if (NF) c[$0] = 1; next } { sub(/^new:/, "model:") } ($0 in c) && !s[$0]++ && ++n <= 3' \
    /dev/stdin "$other" <<<"$cb" 2>/dev/null | paste -sd, -)
  if [ -n "$common" ]; then AO_SYMBOLS="$common"; AO_WHY="same block"; return 1; fi
  return 0
}
