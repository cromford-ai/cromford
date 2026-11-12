#!/bin/bash
# bin/compact-recheck.sh — the iron-law re-check after context compaction
# (BH-9049). A Claude Code SessionStart hook, matcher "compact", installed by
# bin/agent-call.sh (compact_recheck_settings in bin/lib/compact-recheck.sh) on
# the build stages plan, execute and fix when the row
# build.compact_recheck.<project>.enabled reads 1. No model call.
#
# Input: the SessionStart hook JSON on stdin (session_id, source, cwd).
# Output: {"hookSpecificOutput":{"hookEventName":"SessionStart",
#         "additionalContext":<text>}} on stdout. The text is the iron-law block,
#         read now from rules/topics (01-iron-guardrails.md, and the "### Data &
#         config iron laws" part of 04-building-software.md; else the same two
#         parts of ~/.claude/CLAUDE.md), then one line per scan hit:
#           iron-law scan after compaction: <file:line> <class>
#         With no jq the same text goes to stdout as plain text.
# Scan: the working-tree diff (committed, uncommitted and untracked) against
#       merge-base(HEAD, origin/$BASE_BRANCH or $BASE_BRANCH, default main):
#       mc_iron_law_lines (bin/lib/mc/classify.sh, the merge-sweep literal
#       scan), bin/checks-run.sh (slug and file:line only; the reason text can
#       quote a secret) and cr_rls_hits (CREATE TABLE with no RLS).
# Log:  one line per compaction to $HARNESS/logs/compact-recheck.log, and to
#       $COMPACT_RECHECK_BUILD_DIR/compact-recheck.log when that dir exists:
#       <iso> compact-recheck job= phase= project= session= compaction= hits=
#       rules=<ok|missing> scan=<ok|missing:<why>|skipped:<why>|failed:<why>>
#       [checks=could-not-run] [rls=missing] [out=plain]
# FAIL OPEN. Exit 0 always. Each step is bounded by COMPACT_RECHECK_TIMEOUT_S/4
# (the CLI hook timeout, row build.compact_recheck.timeout_s). An abort still
# writes the log line, from the EXIT trap. The merge-time scan is the gate.
# Internal modes (bounded subprocesses of this script): --probe <dir>,
# --diff <top> <base> <out>, --scan <diff>.
set -u
SELF="${BASH_SOURCE[0]}"
HARNESS="${HARNESS:-/root/harness}"

# --- internal modes -----------------------------------------------------------
case "${1:-}" in
  --probe) # print "BASE <sha> <toplevel>" or "SKIP <why>"
    cd "$2" 2>/dev/null || { echo "SKIP no-cwd"; exit 0; }
    [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || { echo "SKIP not-a-git-tree"; exit 0; }
    top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "SKIP not-a-git-tree"; exit 0; }
    bb="${BASE_BRANCH:-main}"; ref=""
    for r in "origin/$bb" "$bb"; do git rev-parse -q --verify "$r^{commit}" >/dev/null 2>&1 && { ref="$r"; break; }; done
    [ -n "$ref" ] || { echo "SKIP no-base"; exit 0; }
    base=$(git merge-base HEAD "$ref" 2>/dev/null) && [ -n "$base" ] || { echo "SKIP no-base"; exit 0; }
    echo "BASE $base $top"; exit 0 ;;
  --diff) # the working-tree diff plus each untracked file; rc != 0 on a git failure
    cd "$2" || exit 3
    git diff --no-color --no-ext-diff --no-renames "$3" > "$4" || exit 4
    git ls-files --others --exclude-standard -z > "$4.untracked" || exit 5
    while IFS= read -r -d '' u; do
      git diff --no-index --no-color --no-ext-diff -- /dev/null "$u" >> "$4"
      [ $? -le 1 ] || exit 6
    done < "$4.untracked"
    exit 0 ;;
  --scan) # print "HIT <file:line> <class>", "STATUS missing:<why>", "CHECKS could-not-run", "RLS missing"
    d="$2"
    if [ ! -r "$HARNESS/bin/lib/mc/classify.sh" ]; then echo "STATUS missing:no-classify.sh"; exit 0; fi
    # shellcheck source=bin/lib/mc/classify.sh
    . "$HARNESS/bin/lib/mc/classify.sh" >/dev/null 2>&1
    declare -F mc_iron_law_lines >/dev/null || { echo "STATUS missing:no-mc_iron_law_lines"; exit 0; }
    mc_iron_law_lines "$d" | while IFS="$(printf '\t')" read -r loc m; do
      case "$m" in claude-*) c=model-id ;; window.*) c=native-dialog ;; VERCEL"_URL") c=vercel-url ;; *) c=iron-law ;; esac
      echo "HIT $loc $c"
    done
    if [ -x "$HARNESS/bin/checks-run.sh" ] && [ -s "$d" ]; then
      out=$("$HARNESS/bin/checks-run.sh" "$d" 2>/dev/null); rc=$?
      if [ "$rc" = 2 ]; then echo "CHECKS could-not-run"
      else printf '%s\n' "$out" | awk '$1 == "CHECK-HIT" { print "HIT " $3 " check:" $2 }'; fi
    fi
    # shellcheck source=bin/lib/compact-recheck.sh
    if [ -r "$HARNESS/bin/lib/compact-recheck.sh" ] && . "$HARNESS/bin/lib/compact-recheck.sh" 2>/dev/null \
       && declare -F cr_rls_hits >/dev/null; then
      cr_rls_hits "$d" | while IFS="$(printf '\t')" read -r loc c; do echo "HIT $loc $c"; done
    else echo "RLS missing"; fi
    exit 0 ;;
esac

# --- the hook -----------------------------------------------------------------
ACTIVE=0; SID=""; RULES=missing; SCAN="failed:aborted"; NHITS=0; EXTRA=""; TMPD=""
JOB="${COMPACT_RECHECK_JOB:-?}"; PHASE="${COMPACT_RECHECK_PHASE:-?}"; PROJ="${COMPACT_RECHECK_PROJECT:-?}"
LOG="$HARNESS/logs/compact-recheck.log"

finish() {
  local n="?" line sid="${SID:-?}"
  if [ "$ACTIVE" = 1 ]; then
    if [ -n "$SID" ]; then n=$(( $(grep -cF " session=$SID " "$LOG" 2>/dev/null || true) + 1 )); fi
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) compact-recheck job=$JOB phase=$PHASE project=$PROJ session=$sid compaction=$n hits=$NHITS rules=$RULES scan=$SCAN$EXTRA"
    mkdir -p "${LOG%/*}" 2>/dev/null && printf '%s\n' "$line" >> "$LOG" 2>/dev/null
    [ -n "${COMPACT_RECHECK_BUILD_DIR:-}" ] && [ -d "$COMPACT_RECHECK_BUILD_DIR" ] \
      && printf '%s\n' "$line" >> "$COMPACT_RECHECK_BUILD_DIR/compact-recheck.log" 2>/dev/null
  fi
  [ -n "$TMPD" ] && rm -rf "$TMPD" 2>/dev/null
  exit 0
}
trap finish EXIT

# One bounded step = the hook timeout / 4, so the four steps fit inside it.
TO="${COMPACT_RECHECK_TIMEOUT_S:-}"
case "$TO" in ''|*[!0-9]*|0) TO=30 ;; esac # 30 = build.compact_recheck.timeout_s seed
STEP=$(( TO / 4 )); [ "$STEP" -ge 1 ] || STEP=1
MAXH="${COMPACT_RECHECK_MAX_HITS:-}"
case "$MAXH" in ''|*[!0-9]*|0) MAXH=50 ;; esac # 50 = build.compact_recheck.max_hits seed
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

IN=$(timeout "$STEP" cat 2>/dev/null)
jfield() {
  if [ "$HAVE_JQ" = 1 ]; then printf '%s' "$IN" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
  else printf '%s' "$IN" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; fi
}
[ "$(jfield source)" = compact ] || exit 0
ACTIVE=1
SID=$(jfield session_id | tr -cd 'A-Za-z0-9._-')
CWD=$(jfield cwd); [ -n "$CWD" ] || CWD="$PWD"
[ "$HAVE_JQ" = 1 ] || EXTRA="$EXTRA out=plain"

# Rules block, read now: the topic files, else the rendered CLAUDE.md.
T1="$HARNESS/rules/topics/01-iron-guardrails.md"; T4="$HARNESS/rules/topics/04-building-software.md"
DATA_AWK='/^### Data & config iron laws/ { p = 1; print; next } p && /^##+ / { exit } p'
if [ -r "$T1" ] && [ -r "$T4" ]; then
  BLOCK="$(cat "$T1")"$'\n\n'"$(awk "$DATA_AWK" "$T4")"
else
  BLOCK=""
  CM="${HOME:-}/.claude/CLAUDE.md"
  [ -r "$CM" ] && BLOCK="$(awk '/^## Iron guardrails/ { p = 1; print; next } p && /^## / { exit } p' "$CM")"$'\n\n'"$(awk "$DATA_AWK" "$CM")"
fi
[ -n "$(printf '%s' "$BLOCK" | tr -d '[:space:]')" ] && RULES=ok

# Scan.
HITS=""; BASE=""
TMPD=$(mktemp -d 2>/dev/null) || TMPD=""
if [ -z "$TMPD" ]; then SCAN="failed:mktemp"
else
  # Output to a file, never $( ): a step killed at its timeout can leave a
  # grandchild (a hung git) holding a pipe open, and $( ) would wait for it.
  timeout "$STEP" bash "$SELF" --probe "$CWD" > "$TMPD/probe" 2>/dev/null; rc=$?
  PR=$(cat "$TMPD/probe" 2>/dev/null)
  if [ "$rc" = 124 ]; then SCAN="failed:timeout"
  elif [ "$rc" != 0 ]; then SCAN="failed:probe-rc$rc"
  else
    case "$PR" in
      "SKIP "*) SCAN="skipped:${PR#SKIP }" ;;
      "BASE "*)
        BASE=$(printf '%s' "$PR" | cut -d' ' -f2); TOP=$(printf '%s' "$PR" | cut -d' ' -f3-)
        timeout "$STEP" bash "$SELF" --diff "$TOP" "$BASE" "$TMPD/d.diff" >/dev/null 2>&1; rc=$?
        if [ "$rc" = 124 ]; then SCAN="failed:timeout"
        elif [ "$rc" != 0 ]; then SCAN="failed:git-diff-rc$rc"
        else
          timeout "$STEP" bash "$SELF" --scan "$TMPD/d.diff" > "$TMPD/scan" 2>/dev/null; rc=$?
          SO=$(cat "$TMPD/scan" 2>/dev/null)
          if [ "$rc" = 124 ]; then SCAN="failed:timeout"
          elif [ "$rc" != 0 ]; then SCAN="failed:scan-rc$rc"
          elif grep -q '^STATUS missing:' <<<"$SO"; then
            SCAN=$(printf '%s\n' "$SO" | sed -n 's/^STATUS //p' | head -1)
          else
            SCAN=ok
            HITS=$(printf '%s\n' "$SO" | sed -n 's/^HIT //p')
            grep -q '^CHECKS could-not-run' <<<"$SO" && EXTRA="$EXTRA checks=could-not-run"
            grep -q '^RLS missing' <<<"$SO" && EXTRA="$EXTRA rls=missing"
          fi
        fi ;;
      *) SCAN="failed:probe-output" ;;
    esac
  fi
fi
[ -n "$HITS" ] && NHITS=$(printf '%s\n' "$HITS" | grep -c .)

# Context text.
TXT="IRON LAWS, re-read after context compaction (BH-9049). They still bind this session."
[ "$RULES" = ok ] && TXT="$TXT"$'\n'"$BLOCK"
TXT="$TXT"$'\n'
case "$SCAN" in
  ok)
    if [ "$NHITS" -gt 0 ]; then
      TXT="$TXT$(printf '%s\n' "$HITS" | awk -v m="$MAXH" 'NR <= m { print "iron-law scan after compaction: " $0 }')"
      [ "$NHITS" -gt "$MAXH" ] && TXT="$TXT"$'\n'"iron-law scan after compaction: $((NHITS - MAXH)) more hit(s) not shown"
      TXT="$TXT"$'\n'"Fix each hit now, before you continue."
    else
      TXT="${TXT}iron-law scan after compaction: 0 hits against ${BASE:0:8}."
    fi ;;
  missing:*) TXT="${TXT}iron-law scan after compaction: not run (scanner missing: ${SCAN#missing:})." ;;
  *)         TXT="${TXT}iron-law scan after compaction: not run (${SCAN#*:})." ;;
esac

if [ "$HAVE_JQ" = 1 ]; then
  jq -n --arg t "$TXT" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$t}}'
else
  printf '%s\n' "$TXT"
fi
exit 0
