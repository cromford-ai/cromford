#!/bin/bash
# bin/lib/spec-trace.sh — BH-6485: a ticket names the spec sections and the
# reference screens its slice must deliver, and the plan, the review, preview QA
# and the PR self-check check the slice against them.
# Sourced, never executed: functions only, no output at source time.
#
# WHY. project-6-os merged its launch cut line green and approved, and a PRD
# audit then found 29 missing and 3 contradicting requirements out of 98. Every
# stage judged a slice against its own ticket text. No stage read the spec the
# ticket came from.
#
# THE TICKET LINES (body only, never comments: a comment author must not be able
# to change a gate). The grammar of bin/lib/spec-repos.sh: the key at the start
# of a line, any case, after optional spaces, one `- ` or `* ` bullet and one
# backtick. Lines in a ``` or ~~~ fence do not count. Values split on commas,
# each optionally in backticks. At most ST_MAX_VALUES per field.
#   Spec: <path>[#<section>]   a spec section the slice must deliver. The path
#                              has no spaces and holds a `/` or a `.`; anything
#                              else is dropped, so a sentence is never a spec.
#   Reference: <path>          a reference screenshot the UI must match.
#   Cut: <token>               a named exemption: a section (J03) or a
#                              requirement id (SET-4).
# `Spec-repo:` is bin/lib/spec-repos.sh's key and never matches `Spec:`.
#
# THE FUNCTIONS
#   st_parse <spec|reference|cut> [file]   the values, one a line (stdin = body)
#   st_dropped <field> [file]              how many values the cap dropped
#   st_has [file]                          rc 0: a Spec or Reference value
#   st_plan_note <ticket>                  the planner's sentence, or nothing
#   st_plan_check <plan> <ticket>          the plan gate (rc 2 = refuse)
#   st_repair_note <plan-gate-out>         the repair pass's sentence
#   st_section <file> [section]            one section of a spec file, capped
#   st_review_note <repo> <ticket>         the reviewer's brief, sections verbatim
#   st_rereview_note <ticket>              "re-emit the rows for this head"
#   st_judge <review> <repo> <ticket>      the rule over the latest pass
#   st_enforce <review> <repo> <ticket>    APPROVE -> BLOCK on an untraced spec
#   st_qa_note <ticket>                    the preview-QA brief for the shots
#   st_shot_names <ticket>                 `<ref>\t<theme>\t<width>\t<file>` rows
#   st_ui_ref_applies <ticket> <files>     rc 0: Reference lines and a UI diff
#   st_conf [project]                      the knobs (ST_* variables)
# A <ticket> file is ticket-meta.json (its .body) or the body text itself.
#
# THE KNOBS (catalog/lanes.d/_lib.spec-trace.json, id spec-trace), read through
# lib_env_apply, else the env, else the ST_DEFAULT_* values below.

ST_MAX_VALUES=20
ST_DEFAULT_ENFORCE=1
ST_DEFAULT_SECTION_MAX_BYTES=12000
ST_DEFAULT_TOTAL_MAX_BYTES=40000
ST_DEFAULT_KEEP_DAYS=30
ST_DEFAULT_PRUNE=dry
ST_DEFAULT_PRUNE_MAX=20

_st_lib_dir() { (cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); }

# _st_body <ticket> — the body text: `.body` of a JSON object, else the file.
_st_body() {
  local f="${1:-}"
  [ -n "$f" ] && [ -r "$f" ] && [ -f "$f" ] || return 1
  if jq -e 'type == "object"' "$f" >/dev/null 2>&1; then jq -r '.body // ""' "$f" 2>/dev/null
  else cat "$f"; fi
}

# _st_scan <field> <mode> — body on stdin. mode values: the kept values; mode
# dropped: the count over the cap.
_st_scan() {
  tr -d '\r' | awk -v field="$1" -v mode="$2" -v max="$ST_MAX_VALUES" '
    {
      line = $0
      sub(/^[ \t]*/, "", line)
      m = substr(line, 1, 3)
      if (m == "```" || m == "~~~") {
        if (fence == "") fence = m; else if (fence == m) fence = ""
        next
      }
      if (fence != "") next
      sub(/^[-*][ \t]+/, "", line)
      sub(/^`/, "", line)
      k = tolower(line)
      key = field ":"
      if (substr(k, 1, length(key)) != key) next
      v = substr(line, length(key) + 1)
      sub(/^`/, "", v)
      n = split(v, w, ",")
      for (i = 1; i <= n; i++) {
        x = w[i]
        gsub(/^[ \t`]+|[ \t`]+$/, "", x)
        if (x == "" || x ~ /[ \t]/) continue
        if (field == "spec") {
          p = x; sub(/#.*/, "", p)
          if (p == "" || p !~ /[\/.]/ || x ~ /#.*#/ || x ~ /#$/) continue
        }
        if (x in seen) continue
        seen[x] = 1
        if (c < max) { c++; if (mode == "values") print x }
        else dropped++
      }
    }
    END { if (mode == "dropped") print dropped + 0 }'
}

st_parse() {
  case "${1:-}" in spec|reference|cut) ;; *) return 2 ;; esac
  if [ -n "${2:-}" ]; then _st_body "$2" | _st_scan "$1" values; else _st_scan "$1" values; fi
}

st_dropped() {
  case "${1:-}" in spec|reference|cut) ;; *) return 2 ;; esac
  if [ -n "${2:-}" ]; then _st_body "$2" | _st_scan "$1" dropped; else _st_scan "$1" dropped; fi
}

st_has() {
  local b
  b=$(if [ -n "${1:-}" ]; then _st_body "$1"; else cat; fi) || return 1
  [ -n "$(_st_scan spec values <<<"$b")$(_st_scan reference values <<<"$b")" ]
}

# _st_key <spec-value> — the section a spec value names, or its path when it
# names none.
_st_key() { case "$1" in *'#'*) printf '%s' "${1#*#}" ;; *) printf '%s' "$1" ;; esac; }

# _st_slug <reference-path> — the shot name stem: the basename without its
# extension, lower case, every byte outside [a-z0-9-] replaced by `-`.
_st_slug() {
  local b="${1##*/}"
  b="${b%.*}"
  printf '%s' "$b" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9-]/-/g'
}

# _st_int <var> <value> <default> <min> <max> — sets <var> to the value when it
# is a whole number in range, else to the default, with a warning in
# ST_CONF_WARN (never clamped: an out-of-range value is refused).
_st_int() {
  local v="${2:-}"
  case "$v" in
    ''|*[!0-9]*)
      [ -n "$v" ] && ST_CONF_WARN="${ST_CONF_WARN:+$ST_CONF_WARN; }$1='$v' is not a whole number"
      printf -v "$1" '%s' "$3" ;;
    *) if [ "$((10#$v))" -lt "$4" ] || [ "$((10#$v))" -gt "$5" ]; then
         ST_CONF_WARN="${ST_CONF_WARN:+$ST_CONF_WARN; }$1='$v' is outside $4-$5"; printf -v "$1" '%s' "$3"
       else printf -v "$1" '%s' "$((10#$v))"; fi ;;
  esac
}

# st_conf [project] — sets ST_ENFORCE (0|1), ST_SECTION_MAX, ST_TOTAL_MAX,
# ST_KEEP_DAYS, ST_PRUNE (dry|on|off), ST_PRUNE_MAX. The knob rows come through
# lib_env_apply in a subshell, so a registry that fails closed cannot end the
# caller; then the env; then the ST_DEFAULT_* values.
st_conf() {
  local p="${1:-${PROJECT:-}}" root out e s t k pr pm
  root="${HARNESS:-${H:-}}"
  ST_CONF_WARN=""
  out=$(
    if ! command -v lib_env_apply >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
      # shellcheck source=/dev/null
      . "$root/bin/lib/lane-gate.sh" >/dev/null 2>&1
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply spec-trace "$p" >/dev/null 2>&1
    # \037, not a tab: read collapses empty tab-separated fields.
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' "${SPEC_TRACE_ENFORCE:-}" "${SPEC_TRACE_SECTION_MAX_BYTES:-}" \
      "${SPEC_TRACE_TOTAL_MAX_BYTES:-}" "${REFERENCE_SHOTS_KEEP_DAYS:-}" "${REFERENCE_SHOTS_PRUNE:-}" \
      "${REFERENCE_SHOTS_PRUNE_MAX:-}"
  ) || out=""
  IFS=$'\037' read -r e s t k pr pm <<<"$out"
  case "$(printf '%s' "${e:-$ST_DEFAULT_ENFORCE}" | tr 'A-Z' 'a-z')" in
    0|off|false|no) ST_ENFORCE=0 ;;
    1|on|true|yes) ST_ENFORCE=1 ;;
    *) ST_ENFORCE=1; ST_CONF_WARN="SPEC_TRACE_ENFORCE='$e' is not on/off, so it enforces" ;;
  esac
  _st_int ST_SECTION_MAX "${s:-}" "$ST_DEFAULT_SECTION_MAX_BYTES" 1000 200000
  _st_int ST_TOTAL_MAX "${t:-}" "$ST_DEFAULT_TOTAL_MAX_BYTES" 4000 400000
  _st_int ST_KEEP_DAYS "${k:-}" "$ST_DEFAULT_KEEP_DAYS" 1 365
  _st_int ST_PRUNE_MAX "${pm:-}" "$ST_DEFAULT_PRUNE_MAX" 0 200
  case "${pr:-$ST_DEFAULT_PRUNE}" in
    dry|on|off) ST_PRUNE="${pr:-$ST_DEFAULT_PRUNE}" ;;
    *) ST_PRUNE=dry; ST_CONF_WARN="${ST_CONF_WARN:+$ST_CONF_WARN; }REFERENCE_SHOTS_PRUNE='$pr' is not dry|on|off — dry" ;;
  esac
  return 0
}

# _st_list <ticket> <field> — the values joined with ", ".
_st_list() { st_parse "$2" "$1" | paste -sd, - | sed 's/,/, /g'; }

st_plan_note() {
  local tk="${1:-}" sp rf cut
  sp=$(st_parse spec "$tk" 2>/dev/null); rf=$(st_parse reference "$tk" 2>/dev/null)
  [ -n "$sp$rf" ] || return 0
  cut=$(_st_list "$tk" cut)
  printf 'SPEC TRACE (BH-6485, prompts/plan-contract.md §17): this ticket body names'
  [ -n "$sp" ] && printf ' spec sections %s' "$(paste -sd, - <<<"$sp" | sed 's/,/, /g')"
  [ -n "$sp" ] && [ -n "$rf" ] && printf ' and'
  [ -n "$rf" ] && printf ' reference screens %s' "$(paste -sd, - <<<"$rf" | sed 's/,/, /g')"
  printf '. Read each named section in this repo. plan.md MUST carry a '"'"'## Spec trace'"'"' section with at least one line per named section, each in the form '"'"'S<section>: <requirement> → <task / file>'"'"' (for a Spec line with no #section, the section is its path)'
  [ -n "$rf" ] && printf ', and MUST list each Reference path in '"'"'## QA screens'"'"' next to the screen that must match it'
  [ -n "$cut" ] && printf '. The ticket names these as cut, so the slice does not deliver them: %s' "$cut"
  printf '. The plan gate refuses a plan without these lines.'
  [ "$(st_dropped spec "$tk")" -gt 0 ] 2>/dev/null && printf ' (%s Spec value(s) over the cap of %s were dropped.)' "$(st_dropped spec "$tk")" "$ST_MAX_VALUES"
  [ "$(st_dropped reference "$tk")" -gt 0 ] 2>/dev/null && printf ' (%s Reference value(s) over the cap of %s were dropped.)' "$(st_dropped reference "$tk")" "$ST_MAX_VALUES"
  printf ' '
}

# _st_plan_section <plan> <heading-start> — the lines under the first heading
# whose text starts with the words, to the next heading of the same or a higher
# level, fences skipped.
_st_plan_section() {
  awk -v want="$2" '
    /^[ \t]*(```|~~~)/ { fence = !fence; if (on) print; next }
    fence { if (on) print; next }
    /^#+[ \t]/ {
      match($0, /^#+/); lv = RLENGTH
      if (on && lv <= lvl) exit
      if (on) { print; next }
      t = $0; sub(/^#+[ \t]*/, "", t); t = tolower(t)
      if (substr(t, 1, length(want)) == want) { on = 1; lvl = lv }
      next
    }
    on' "$1"
}

st_plan_check() {
  local plan="${1:-}" tk="${2:-}" sp rf trace qa k r gaps=0 out="" pfx
  if [ -z "$tk" ] || ! [ -r "$tk" ]; then echo "PLAN_SPEC_TRACE: unread"; return 0; fi
  sp=$(st_parse spec "$tk"); rf=$(st_parse reference "$tk")
  if [ -z "$sp$rf" ]; then echo "PLAN_SPEC_TRACE: n/a"; return 0; fi
  st_conf
  trace=$(_st_plan_section "$plan" "spec trace")
  qa=$(_st_plan_section "$plan" "qa screens")
  pfx="  UNTRACED: spec trace — "
  [ "$ST_ENFORCE" = 0 ] && pfx="  NOTE: spec trace (SPEC_TRACE_ENFORCE=0) — "
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    k=$(_st_key "$k")
    if ! awk -v k="$(printf '%s' "$k" | tr 'A-Z' 'a-z')" '
        /^[ \t]*(```|~~~)/ { fence = !fence; next }
        fence { next }
        {
          l = $0; sub(/^[ \t]*([-*][ \t]+)?/, "", l); gsub(/`/, "", l)
          i = index(l, ":"); if (i < 2) next
          h = tolower(substr(l, 1, i - 1)); r = substr(l, i + 1)
          if ((h == k || h == "s" k) && (index(r, "→") || index(r, "->"))) { f = 1; exit }
        }
        END { exit !f }' <<<"$trace"; then
      if [ -z "$trace" ]; then out+="${pfx}${k}: no '## Spec trace' section in the plan"$'\n'
      else out+="${pfx}${k}: no 'S${k}: <requirement> → <task / file>' line under '## Spec trace'"$'\n'; fi
      gaps=$((gaps + 1))
    fi
  done <<<"$sp"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if ! grep -qF -- "$r" <<<"$qa"; then
      out+="${pfx}${r}: Reference not listed under '## QA screens'"$'\n'
      gaps=$((gaps + 1))
    fi
  done <<<"$rf"
  printf '%s' "$out"
  if [ "$gaps" = 0 ]; then echo "PLAN_SPEC_TRACE: ok"; return 0; fi
  if [ "$ST_ENFORCE" = 0 ]; then echo "PLAN_SPEC_TRACE: missing (not enforced, SPEC_TRACE_ENFORCE=0)"; return 0; fi
  echo "PLAN_SPEC_TRACE: missing"
  return 2
}

st_repair_note() {
  local g="${1:-}" l
  [ -r "$g" ] || return 0
  grep -q '^PLAN_SPEC_TRACE: missing$' "$g" 2>/dev/null || return 0
  l=$(sed -n 's/^  UNTRACED: spec trace — //p' "$g" | head -8 | paste -sd';' - | sed 's/;/; /g')
  printf ' SPEC TRACE: the ticket names spec sections or reference screens, and the plan does not trace them (%s). Add a '"'"'## Spec trace'"'"' section with one line per named section in the form '"'"'S<section>: <requirement> → <task / file>'"'"', and list each Reference path in '"'"'## QA screens'"'"'.' "$l"
}

st_section() {
  local f="${1:-}" sec="${2:-}" txt n
  [ -n "$f" ] && [ -r "$f" ] && [ -f "$f" ] || return 1
  [ -n "${ST_SECTION_MAX:-}" ] || st_conf
  if [ -z "$sec" ]; then txt=$(cat "$f")
  else
    txt=$(awk -v want="$(printf '%s' "$sec" | tr 'A-Z' 'a-z')" '
      function slug(s) { s = tolower(s); gsub(/[^a-z0-9 _-]/, "", s); gsub(/ /, "-", s); return s }
      /^[ \t]*(```|~~~)/ { fence = !fence; if (on) print; next }
      fence { if (on) print; next }
      /^#+[ \t]/ {
        match($0, /^#+/); lv = RLENGTH
        if (on && lv <= lvl) exit
        if (on) { print; next }
        t = $0; sub(/^#+[ \t]*/, "", t); sub(/[ \t#]+$/, "", t)
        lt = tolower(t); nx = substr(lt, length(want) + 1, 1)
        if ((substr(lt, 1, length(want)) == want && nx !~ /[a-z0-9_]/) || slug(t) == want) { on = 1; lvl = lv; print; found = 1 }
        next
      }
      on { print }
      END { exit !found }' "$f") || return 2
  fi
  n=$(printf '%s' "$txt" | wc -c | tr -d ' ')
  if [ "$n" -gt "$ST_SECTION_MAX" ]; then
    printf '%s\n[truncated at %s bytes]\n' "$(head -c "$ST_SECTION_MAX" <<<"$txt")" "$ST_SECTION_MAX"
  else
    printf '%s\n' "$txt"
  fi
}

# _st_resolve <repo> <path> — the file a spec path names inside the repo, or rc
# 1 with the reason on stdout. An absolute path, a `..` or a link that leaves
# the repo is refused: the ticket is client text, and the note goes into a
# model prompt.
_st_resolve() {
  local repo="$1" p="$2" top real
  case "$p" in /*|..|../*|*/..|*/../*) printf 'the path leaves the repo'; return 1 ;; esac
  top=$(cd "$repo" 2>/dev/null && pwd -P) || { printf 'the repo is unreadable'; return 1; }
  [ -f "$top/$p" ] || { printf 'no file %s in the repo' "$p"; return 1; }
  real=$(realpath -e "$top/$p" 2>/dev/null) || { printf 'the path does not resolve'; return 1; }
  case "$real" in "$top"/*) printf '%s' "$real" ;; *) printf 'the path leaves the repo'; return 1 ;; esac
}

# _st_sections <repo> <ticket> — one row per Spec value:
#   key<TAB>value<TAB>ok|unreadable<TAB>why
_st_sections() {
  local repo="$1" tk="$2" v p s f
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    p="${v%%#*}"; s=""; case "$v" in *'#'*) s="${v#*#}" ;; esac
    if ! f=$(_st_resolve "$repo" "$p"); then
      printf '%s\t%s\tunreadable\t%s\n' "$(_st_key "$v")" "$v" "$f"; continue
    fi
    if st_section "$f" "$s" >/dev/null 2>&1; then
      printf '%s\t%s\tok\t-\n' "$(_st_key "$v")" "$v"
    else
      printf '%s\t%s\tunreadable\t%s has no heading %s\n' "$(_st_key "$v")" "$v" "$p" "$s"
    fi
  done < <(st_parse spec "$tk")
}

# The row format, ONE definition: the note shows it and st_enforce parses it.
ST_ROW_FORMAT='SPEC-TRACE: <section> | <requirement> | <delivered|partial|missing|contradicts|cut> | <file:line or ->'
ST_ROW_EXAMPLE='SPEC-TRACE: J01 | ACC-1 the first run shows the welcome card | delivered | src/app/page.tsx:12'

st_review_note() {
  local repo="${1:-.}" tk="${2:-}" k v st why f p s txt used=0 n cut
  [ -n "$(st_parse spec "$tk" 2>/dev/null)" ] || return 0
  st_conf
  cut=$(_st_list "$tk" cut)
  printf 'This ticket body names the spec sections below. They are the spec this slice must deliver, beside plan.md. For EVERY requirement in each section write one row at the start of a line, outside any code fence or quote, above your TIER and VERDICT lines:\n%s\nExample: %s\nThe status is delivered, partial, missing, contradicts or cut, and the evidence is the file:line that delivers it, or -. A missing or contradicts row is a BLOCK unless a Cut: token below equals its section or is a whole word in its requirement column. A cut row needs such a Cut: token. A named section with no row is a BLOCK. The harness reads these rows mechanically after your verdict, so a row you leave out is a BLOCK even when your verdict says APPROVE.\nCut tokens (the ticket names these as cut): %s\n' \
    "$ST_ROW_FORMAT" "$ST_ROW_EXAMPLE" "${cut:-none}"
  [ "$(st_dropped spec "$tk")" -gt 0 ] && printf 'NOTE: %s Spec value(s) over the cap of %s were dropped and are not judged.\n' "$(st_dropped spec "$tk")" "$ST_MAX_VALUES"
  while IFS=$'\t' read -r k v st why; do
    [ -n "$k" ] || continue
    if [ "$st" != ok ]; then
      printf 'UNREADABLE: %s (%s): %s. The harness BLOCKs this section.\n' "$k" "$v" "$why"; continue
    fi
    p="${v%%#*}"; s=""; case "$v" in *'#'*) s="${v#*#}" ;; esac
    f=$(_st_resolve "$repo" "$p")
    txt=$(st_section "$f" "$s")
    n=$(printf '%s' "$txt" | wc -c | tr -d ' ')
    if [ $((used + n)) -gt "$ST_TOTAL_MAX" ]; then
      printf 'NOT INCLUDED: %s (%s): the spec text is over the total cap of %s bytes. Read %s yourself.\n' "$k" "$v" "$ST_TOTAL_MAX" "$p"
      continue
    fi
    used=$((used + n))
    printf '=== spec section %s (%s) ===\n%s\n=== end of %s ===\n' "$k" "$v" "$txt" "$k"
  done < <(_st_sections "$repo" "$tk")
}

st_rereview_note() {
  [ -n "$(st_parse spec "${1:-}" 2>/dev/null)" ] || return 0
  printf ' SPEC TRACE: this ticket names spec sections (%s). Re-emit the WHOLE SPEC-TRACE block for the CURRENT head, one row per requirement, in the form %s, above the TIER line. Rows from an earlier pass are not read, so a section with no row in this pass is a BLOCK.' \
    "$(_st_list "$1" spec)" "$ST_ROW_FORMAT"
}

# _st_log <line> — one pipeline.log line when the caller has a build dir.
_st_log() {
  [ -n "${BUILD:-}" ] && [ -d "$BUILD" ] || return 0
  printf '%s [%s/%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PROJECT:-?}" "${KEY:-?}" "$1" >> "$BUILD/pipeline.log" 2>/dev/null
  return 0
}

# st_judge <review> <repo> <ticket> — the rule over the LATEST pass's rows,
# whatever the verdict says: `OK|BLOCK<TAB><cut-exempt><TAB><reasons>`, `SKIP`
# when there is nothing to judge (no verdict line, or this gate's own restated
# verdict with an unchanged answer), and also one `ROWS<TAB>d<TAB>p<TAB>m<TAB>c<TAB>x`
# line (delivered, partial, missing, contradicts, cut) when ST_JUDGE_ROWS=1.
st_judge() {
  local rf="${1:-}" repo="${2:-.}" tk="${3:-}" keys cuts unread
  [ -r "$rf" ] && [ -f "$rf" ] || return 1
  keys=$(st_parse spec "$tk" | while IFS= read -r v; do _st_key "$v"; echo; done)
  cuts=$(st_parse cut "$tk")
  unread=$(_st_sections "$repo" "$tk" | awk -F'\t' '$3 != "ok" { print $1 "\t" $2 }')
  awk -v keys="$keys" -v cuts="$cuts" -v unread="$unread" -v rowsout="${ST_JUDGE_ROWS:-0}" '
    function trim(s) { gsub(/^[ \t`*]+|[ \t`*.]+$/, "", s); return s }
    function word(tok, s,   i, b, a, ls, lt) {
      ls = tolower(s); lt = tolower(tok)
      while ((i = index(ls, lt)) > 0) {
        b = (i > 1) ? substr(ls, i - 1, 1) : ""
        a = substr(ls, i + length(lt), 1)
        if (b !~ /[a-z0-9_-]/ && a !~ /[a-z0-9_-]/) return 1
        ls = substr(ls, i + 1)
      }
      return 0
    }
    function cutby(sec, req,   j) {
      for (j = 1; j <= nc; j++) if (tolower(C[j]) == tolower(sec) || word(C[j], req)) return 1
      return 0
    }
    function verdict(l) {
      return l ~ /^[ \t]*(#+[ \t]*)?(\*\*|__)?VERDICT(\*\*|__)?:?(\*\*|__)?[ \t]*(\*\*|__|`)?(APPROVE|BLOCK)([^A-Za-z0-9_-]|$)/
    }
    BEGIN {
      nk = split(keys, K, "\n"); nc = split(cuts, C, "\n")
      nu = split(unread, U0, "\n")
      for (j = 1; j <= nu; j++) if (U0[j] != "") { split(U0[j], uf, "\t"); UR[tolower(uf[1])] = uf[2] }
    }
    { raw[NR] = $0 }
    END {
      fence = 0; nv = 0
      for (i = 1; i <= NR; i++) {
        l = raw[i]
        if (l ~ /^[ \t]*(```|~~~)/) { fence = !fence; infence[i] = 1; continue }
        infence[i] = fence
        if (!fence && verdict(l)) V[++nv] = i
      }
      if (nv == 0) { print "SKIP"; exit }
      last = V[nv]; prev = (nv > 1) ? V[nv - 1] : 0
      # This gate'"'"'s own restated verdict: `SPEC-TRACE-GATE: ok (...)` right
      # after a verdict line, then the verdict again. The pass it judged is the
      # one before, judged again here, so a line a reviewer forges in that
      # shape buys nothing; an unchanged answer appends nothing.
      restated = 0
      if (nv > 1) {
        for (i = last - 1; i > prev && raw[i] ~ /^[ \t]*$/; i--) ;
        if (i > prev && raw[i] ~ /^SPEC-TRACE-GATE: ok \(cut-exempt=[0-9]+\)$/) {
          for (j = i - 1; j > prev && raw[j] ~ /^[ \t]*$/; j--) ;
          if (j == prev) { restated = 1; last = prev; prev = (nv > 2) ? V[nv - 2] : 0 }
        }
      }
      for (i = prev + 1; i < last; i++) {
        if (infence[i]) continue
        l = raw[i]
        if (l !~ /^[ \t]*([-*][ \t]+)?SPEC-TRACE:/) continue
        sub(/^[ \t]*([-*][ \t]+)?SPEC-TRACE:[ \t]*/, "", l)
        n = split(l, f, "|")
        if (n < 3) continue
        sec = trim(f[1]); req = trim(f[2]); st = tolower(trim(f[3]))
        ls = tolower(sec)
        for (j = 1; j <= nk; j++) {
          lk = tolower(K[j]); if (lk == "") continue
          if (ls == lk || ls == "s" lk) {
            seen[lk]++; cnt[st]++
            r = substr(req, 1, 80)
            if (st == "delivered" || st == "partial") break
            if (st == "missing" || st == "contradicts") {
              if (cutby(K[j], req)) exempt++; else out = out "; " K[j] " " r ": " st
            } else if (st == "cut") {
              if (cutby(K[j], req)) exempt++; else out = out "; " K[j] " " r ": cut, but no Cut: line names it"
            } else out = out "; " K[j] " " r ": status \"" st "\" is not delivered|partial|missing|contradicts|cut"
            break
          }
        }
      }
      for (j = 1; j <= nk; j++) {
        lk = tolower(K[j]); if (lk == "" || done[lk]++) continue
        if (lk in UR) out = out "; " K[j] " unreadable at " UR[lk]
        else if (!seen[lk]) out = out "; " K[j] " not traced"
      }
      sub(/^; /, "", out)
      if (rowsout == 1) printf "ROWS\t%d\t%d\t%d\t%d\t%d\n", cnt["delivered"], cnt["partial"], cnt["missing"], cnt["contradicts"], cnt["cut"]
      if (restated && out == "") { print "SKIP"; exit }
      print (out == "" ? "OK" : "BLOCK") "\t" exempt + 0 "\t" out
    }' "$rf"
}

st_enforce() {
  local rf="${1:-}" repo="${2:-.}" tk="${3:-}" res reasons exempt
  [ -n "$(st_parse spec "$tk" 2>/dev/null)" ] || return 0
  [ -r "$rf" ] && [ -f "$rf" ] || return 0
  declare -F verdict_parse >/dev/null 2>&1 || . "$(_st_lib_dir)/verdict-parse.sh" 2>/dev/null || return 0
  [ "$(verdict_parse -L "$rf" 2>/dev/null)" = APPROVE ] || return 0
  st_conf
  res=$(ST_JUDGE_ROWS=0 st_judge "$rf" "$repo" "$tk")
  case "$res" in SKIP*|'') return 0 ;; esac
  IFS=$'\t' read -r res exempt reasons <<<"$res"
  if [ "$res" = BLOCK ]; then
    if [ "$ST_ENFORCE" = 0 ]; then
      _st_log "SPEC-TRACE-GATE: would BLOCK — $reasons (cut-exempt=$exempt); SPEC_TRACE_ENFORCE=0, the verdict stands"
      return 0
    fi
    printf '\nSPEC-TRACE-GATE: BLOCK — %s (cut-exempt=%s)\nVERDICT: BLOCK\n' "$reasons" "$exempt" >> "$rf"
    _st_log "SPEC-TRACE-GATE: BLOCK — $reasons (cut-exempt=$exempt)"
  elif [ "$exempt" -gt 0 ]; then
    # The verdict is restated, unchanged, so the last line of the file is still
    # the verdict line every reader expects.
    printf '\nSPEC-TRACE-GATE: ok (cut-exempt=%s)\nVERDICT: APPROVE\n' "$exempt" >> "$rf"
    _st_log "SPEC-TRACE-GATE: ok (cut-exempt=$exempt)"
  else
    _st_log "SPEC-TRACE-GATE: ok (cut-exempt=0)"
  fi
  return 0
}

st_shot_names() {
  local tk="${1:-}" r th w
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    for th in light dark; do for w in 1440 390; do
      printf '%s\t%s\t%s\t%s-%s-%s.png\n' "$r" "$th" "$w" "$(_st_slug "$r")" "$th" "$w"
    done; done
  done < <(st_parse reference "$tk" 2>/dev/null)
}

st_qa_note() {
  local tk="${1:-}" b names
  [ -n "$(st_parse reference "$tk" 2>/dev/null)" ] || return 0
  b="${BUILD:-$(dirname "$tk")}"
  names=$(st_shot_names "$tk" | awk -F'\t' '{print $4}' | paste -sd, - | sed 's/,/, /g')
  printf 'REFERENCE SCREENS (BH-6485): this ticket names reference screenshots the UI must match: %s. For EACH reference, open the screen plan.md lists it under in "## QA screens" and capture it four times: light and dark theme (set playwright colorScheme to "light" or "dark" on the browser context) at 1440px and 390px wide. Save each to %s/qa-shots/ref/<name>.png with exactly these names: %s. The names are read mechanically: a missing file shows the reference set as Missing in the PR body. Compare each shot with its reference and report every visible difference in qa.md.' \
    "$(_st_list "$tk" reference)" "$b" "$names"
}

st_ui_ref_applies() {
  local tk="${1:-}" files="${2:-}"
  [ -n "$(st_parse reference "$tk" 2>/dev/null)" ] || return 1
  declare -F e2e_ui_path_hit >/dev/null 2>&1 || . "$(_st_lib_dir)/e2e-ui-paths.sh" 2>/dev/null || return 1
  e2e_ui_path_hit <<<"$files"
}
