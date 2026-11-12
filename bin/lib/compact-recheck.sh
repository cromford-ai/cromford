#!/bin/bash
# shellcheck shell=bash
# bin/lib/compact-recheck.sh — the iron-law re-check after context compaction
# (BH-9049). Sourced by bin/agent-call.sh (compact_recheck_settings) and by the
# hook bin/compact-recheck.sh (cr_rls_hits), never run.
#
# THE POINT. A long plan, execute or fix session hits context compaction, and
# the summary can drop the iron rules. A Claude Code SessionStart hook with
# matcher "compact" runs bin/compact-recheck.sh after each compaction: it puts
# the iron-law block back into the context and scans the working-tree diff. No
# model call. The merge-time scan stays the real gate.
#
# The root is ${HARNESS:-${H:-}} and nothing else (D43): no root, no install.

# Code fallbacks. Each one equals its seed row in
# worker/jobs/schema.d/202611121538-bh-9049-compact-recheck-knobs.sql.
CR_TIMEOUT_FALLBACK=30 # build.compact_recheck.timeout_s: the CLI hook timeout, seconds
CR_MAX_HITS_FALLBACK=50 # build.compact_recheck.max_hits: hit lines put in the context

# _cr_pos_int <key> <fallback> — a positive-integer knob, else the fallback.
_cr_pos_int() {
  local v="" rc=1
  if command -v setting_get >/dev/null 2>&1; then v=$(setting_get "$1" 2>/dev/null); rc=$?; fi
  case "$v" in ''|*[!0-9]*) rc=1 ;; esac
  if [ "$rc" = 0 ] && [ "$((10#$v))" -gt 0 ]; then printf '%s' "$((10#$v))"; else printf '%s' "$2"; fi
}

# compact_recheck_settings <stage> <project> <out-file>
#   Sets CR_SETTINGS to the hook settings file when <stage> is plan, execute or
#   fix AND the row build.compact_recheck.<project>.enabled reads 1 (the env
#   COMPACT_RECHECK_ENABLED, when set, decides instead of the row), and exports
#   the per-call values the hook reads (COMPACT_RECHECK_*). Every other answer
#   (no row, an outage, no setting_get, any other value, another stage, no
#   root, no hook) leaves CR_SETTINGS empty and exports nothing. Runs in the
#   caller's shell, never in $( ), because the exports must reach claude.
#   Always rc 0.
compact_recheck_settings() {
  local stage="${1:-}" project="${2:-}" out="${3:-}" root="${HARNESS:-${H:-}}"
  local v rc to mh f job="" bdir="" rest
  CR_SETTINGS=""
  case "$stage" in plan|execute|fix) ;; *) return 0 ;; esac
  [ -n "$project" ] && [ -n "$root" ] && [ -x "$root/bin/compact-recheck.sh" ] || return 0
  # COMPACT_RECHECK_ENABLED (tests, a canary box) is read before the row.
  if [ -n "${COMPACT_RECHECK_ENABLED:-}" ]; then
    [ "$COMPACT_RECHECK_ENABLED" = 1 ] || return 0
  else
    command -v setting_get >/dev/null 2>&1 || return 0
    v=$(setting_get "build.compact_recheck.$project.enabled" 2>/dev/null); rc=$?
    [ "$rc" = 0 ] && [ "$v" = 1 ] || return 0
  fi
  to=$(_cr_pos_int build.compact_recheck.timeout_s "$CR_TIMEOUT_FALLBACK")
  mh=$(_cr_pos_int build.compact_recheck.max_hits "$CR_MAX_HITS_FALLBACK")
  f="$root/state/compact-recheck-settings.json"
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  # Only the command path and the timeout: parallel builds write the same bytes.
  if ! jq -n --arg c "$root/bin/compact-recheck.sh" --argjson t "$to" \
        '{hooks:{SessionStart:[{matcher:"compact",hooks:[{type:"command",command:$c,timeout:$t}]}]}}' \
        > "$f.tmp.$$" 2>/dev/null || ! mv -f "$f.tmp.$$" "$f" 2>/dev/null; then
    rm -f "$f.tmp.$$" 2>/dev/null; return 0
  fi
  case "$out" in
    */builds/*/*) rest="${out#*/builds/}"; bdir="${out%%/builds/*}/builds/${rest%%/*}"; job="${rest%%/*}" ;;
    *) job="${out##*/}"; job="${job%%.*}" ;;
  esac
  export HARNESS="$root" COMPACT_RECHECK_JOB="${job:-?}" COMPACT_RECHECK_PHASE="$stage" \
         COMPACT_RECHECK_PROJECT="$project" COMPACT_RECHECK_BUILD_DIR="$bdir" \
         COMPACT_RECHECK_TIMEOUT_S="$to" COMPACT_RECHECK_MAX_HITS="$mh"
  CR_SETTINGS="$f"
  return 0
}

# cr_rls_hits <diff-file> — one "<file>:<line>\trls-missing" per added
#   CREATE TABLE in a .sql file with no added ALTER TABLE <same name> ENABLE ROW
#   LEVEL SECURITY anywhere in the diff. Names: quotes dropped, lower case, a
#   "public." prefix dropped (another schema is kept). Skipped: tests/,
#   __tests__/, .harness/specs/, docs/, worker/ (the harness's D1 schema:
#   SQLite has no RLS), comment lines, removed lines, CREATE TEMP TABLE.
cr_rls_hits() {
  awk 'function cnt(s) { return (s == "") ? 1 : s + 0 }
       function nm(s,   t) { sub(/^[ \t]+/, "", s)
         if (!match(s, /^[^ \t(;]+/)) return ""
         t = substr(s, RSTART, RLENGTH); gsub(/["`]/, "", t); sub(/^public\./, "", t); return t }
       function line(s, f, ln,   l, r, t) {
         if (s ~ /^\+[ \t]*(--|\/\*|\*)/) return
         l = tolower(substr(s, 2))
         if (match(l, /alter[ \t]+table[ \t]+/)) {
           r = substr(l, RSTART + RLENGTH); sub(/^only[ \t]+/, "", r); sub(/^if[ \t]+exists[ \t]+/, "", r)
           if (r ~ /enable[ \t]+row[ \t]+level[ \t]+security/) { t = nm(r); if (t != "") cov[t] = 1 }
         }
         if (!sql) return
         if (l ~ /create[ \t]+((global|local)[ \t]+)?(temp|temporary)[ \t]+table/) return
         if (match(l, /create[ \t]+(unlogged[ \t]+)?table[ \t]+/)) {
           r = substr(l, RSTART + RLENGTH); sub(/^if[ \t]+not[ \t]+exists[ \t]+/, "", r)
           t = nm(r); if (t != "") { nh++; hn[nh] = t; hl[nh] = f ":" ln }
         }
       }
       inh {
         ch = substr($0, 1, 1)
         if (ch == "+") { line($0, f, ln); ln++; nl-- }
         else if (ch == "-") { ol-- }
         else if (ch == " " || $0 == "") { ln++; ol--; nl-- }
         if (ol <= 0 && nl <= 0) inh = 0
         next
       }
       /^\+\+\+ / { p = substr($0, 5); sub(/\t.*$/, "", p); f = (p ~ /^b\//) ? substr(p, 3) : p
                    sql = (f ~ /\.sql$/) && (("/" f) !~ /\/(tests?|__tests__)\/|\/\.harness\/specs\/|^\/docs\/|^\/worker\//); next }
       /^@@ / { h = $0; sub(/^@@ -/, "", h); sub(/ @@.*$/, "", h)
                split(h, sides, " +"); split(sides[1], o, ","); split(sides[2], n, ",")
                ol = (2 in o) ? cnt(o[2]) : 1; nl = (2 in n) ? cnt(n[2]) : 1; ln = n[1] + 0
                inh = (ol > 0 || nl > 0); next }
       END { for (i = 1; i <= nh; i++) if (!(hn[i] in cov)) print hl[i] "\trls-missing" }' "$1" 2>/dev/null
}
