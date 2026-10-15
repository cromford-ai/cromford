#!/bin/bash
# bin/test-determinism-lint.sh [--warn-only] [--list] [--rules] [--changed <ref>] [path ...]
#
# A TEST THAT READS THE WALL CLOCK IS A TEST THAT PICKS ITS OWN RED DAY.
#
# 2026-09-15: worker/jobs/test/cost-anchored.test.js asked the route for a
# rolling 24h window while its fixtures were pinned to 2026-09-14. It was green
# when it merged and green all night. At ~14:00Z the window slid past the
# fixtures, tests 17 and 19 went red ON MAIN, every open PR (#355-#359)
# inherited the red, four "Harness CI failure" alerts fired at PR authors, and
# nothing anywhere said "main itself is red" (that half is bin/main-red-detector.sh).
# #360 fixed it in three lines by pinning ?day=. This is the lint that would
# have refused the original.
#
# WHAT IT SCANS: every test file (catalog/determinism-lint.conf `file` lines —
# tests/*.sh, **/test/*.js, *.test.*, *-test.sh), plus whatever a `scope` line
# hands to ONE rule (BH-1248: race-sigpipe also reads bin/**.sh, because the
# pipeline that flakes a test flakes a lane the same way). A file reached only
# by `scope` runs only the rules that named it; a test file runs all of them.
# BH-1897: date-empty-stamp is the second rule a `scope` line takes into bin/.
# BH-6109: race-sigpipe-echo is race-sigpipe for a printf/echo producer.
# BH-6508: race-wall-bound warns on an elapsed wall-clock capture in a test.
# WHAT IT LOOKS FOR: clock reads, randomness and sleep-based races
# (`rule` lines). Rules are `error` (rc 1) or `warn` (printed, rc 0).
# WHAT MAKES IT QUIET:
#   - the file pins time            (a `pin` line: FAKE_NOW, NOW=, useFakeTimers, ...)
#   - the line carries a waiver     `# determinism: ok <reason>`
#   - the file carries a waiver     `# determinism: ok-file [<rule>] <reason>`
# A waiver with no reason is itself a finding: the point of the escape hatch is
# the sentence, not the silence.
#
# Every pattern, severity and threshold lives in the conf, never here:
#   $DETERMINISM_LINT_CONF > flags/determinism-lint.conf > catalog/determinism-lint.conf,
# with the settings rows conf.determinism-lint.{rule,opt,scope}.<id>[.<box>]
# replacing the chosen file's line of the same name (not with $DETERMINISM_LINT_CONF).
# No conf = rc 2 and a message. A lint that scans for nothing must never report
# green.
#
#   --warn-only   report findings, always exit 0 (a local look, and the PR job
#                 since BH-6838; the nightly run on main is strict)
#   --list        print the files that WOULD be scanned, and exit
#   --rules       print the resolved conf path and rule table, and exit
#   --changed <ref>  scan only the files that differ from <ref> (committed,
#                 uncommitted and untracked; deleted files skipped). The rules
#                 pack passes the fork here: a full-tree scan takes 70-113 s
#                 against its 120 s component timeout, so a loaded runner
#                 reported could_not_run (BH-6049). Every rule is per file, so
#                 an unchanged file cannot carry a new finding. It scans the
#                 FULL tree when <ref> does not resolve, when nothing differs
#                 (the pack's base re-run), or when the lint or its conf changed.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DEFAULT="$(cd "$SELF_DIR/.." && pwd)"

WARN_ONLY=0; MODE=lint
PATHS=(); CHANGED_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --warn-only) WARN_ONLY=1 ;;
    --list)      MODE=list ;;
    --rules)     MODE=rules ;;
    --changed)   [ $# -ge 2 ] || { echo "test-determinism-lint.sh: --changed needs a ref" >&2; exit 2; }
                 CHANGED_REF="$2"; shift ;;
    -h|--help)   sed -n '2,36p' "$0"; exit 0 ;;   # through the last header line, before `set`
    -*)          echo "test-determinism-lint.sh: unknown flag $1" >&2; exit 2 ;;
    *)           PATHS+=("$1") ;;
  esac
  shift
done
# --changed: the files that differ from the ref, relative to the repo root.
# Any doubt (no git, unknown ref, an empty diff, the lint or conf edited) is a
# full scan, never an empty one.
if [ -n "$CHANGED_REF" ] && [ "${#PATHS[@]}" -eq 0 ] \
   && git -C "$ROOT_DEFAULT" rev-parse --verify -q "$CHANGED_REF^{commit}" >/dev/null 2>&1; then
  CH=$( { git -C "$ROOT_DEFAULT" diff --name-only --diff-filter=d "$CHANGED_REF" --
          git -C "$ROOT_DEFAULT" ls-files --others --exclude-standard; } 2>/dev/null | sort -u)
  if [ -n "$CH" ] && ! grep -qE '^(bin/test-determinism-lint\.sh|catalog/determinism-lint\.conf|flags/determinism-lint\.conf)$' <<<"$CH"; then
    while IFS= read -r c; do [ -f "$ROOT_DEFAULT/$c" ] && PATHS+=("$ROOT_DEFAULT/$c"); done <<<"$CH"
    [ "${#PATHS[@]}" -gt 0 ] || { echo "test-determinism-lint: no files to scan (nothing changed since $CHANGED_REF)"; exit 0; }
  fi
fi
[ "${#PATHS[@]}" -gt 0 ] || PATHS=("$ROOT_DEFAULT")

# ── the conf, or nothing ─────────────────────────────────────────────────────
CONF=""
for C in "${DETERMINISM_LINT_CONF:-}" "$H/flags/determinism-lint.conf" \
         "$ROOT_DEFAULT/catalog/determinism-lint.conf" "/root/harness/catalog/determinism-lint.conf"; do
  [ -n "$C" ] && [ -r "$C" ] && { CONF="$C"; break; }
done
if [ -z "$CONF" ]; then
  echo "test-determinism-lint: no rule file found (tried \$DETERMINISM_LINT_CONF, $H/flags/determinism-lint.conf, $ROOT_DEFAULT/catalog/determinism-lint.conf)." >&2
  echo "Refusing to scan for nothing and report green." >&2
  exit 2
fi
# THE SETTINGS ROWS (BH-2411, bin/lib/conf-row.sh), unless
# $DETERMINISM_LINT_CONF names a fixture: `conf.determinism-lint.rule.<id>`,
# `.opt.<name>` and `.scope.<rule>` (box row first) each REPLACE the chosen
# file's line with the same first two words, as `<kw> <id> <value>`. The
# scan then reads that effective copy. `pin`, `file` and `skip` are lists with
# no key, so they stay file-only.
CONF_SHOWN="$CONF"
EFF=""
# shellcheck source=lib/conf-row.sh
. "$SELF_DIR/lib/conf-row.sh" 2>/dev/null || true
if [ -z "${DETERMINISM_LINT_CONF:-}" ] && command -v conf_rows >/dev/null 2>&1; then
  ROWS=$(conf_rows determinism-lint "$H" | awk -F'\t' '$1 ~ /^(rule|opt|scope)\.[^.]+$/')
  if [ -n "$ROWS" ]; then
    EFF=$(mktemp) || exit 2
    trap 'rm -f "$EFF"' EXIT
    awk 'NR == FNR { split($1, p, "."); drop[p[1] " " p[2]] = 1; next }
         !(($1 " " $2) in drop)' FS='\t' - FS=' ' "$CONF" <<<"$ROWS" > "$EFF"
    printf '%s\n' "$ROWS" | awk -F'\t' '{ i = index($1, "."); print substr($1, 1, i - 1), substr($1, i + 1), $2 }' >> "$EFF"
    # shellcheck disable=SC2046  # the key list, one word per key
    conf_row_note_file determinism-lint "$H/flags/determinism-lint.conf" $(printf '%s\n' "$ROWS" | cut -f1)
    CONF_SHOWN="$CONF + settings conf.determinism-lint.*"
    CONF="$EFF"
  fi
fi
if [ "$MODE" = rules ]; then
  echo "conf: $CONF_SHOWN"
  grep -E '^[[:space:]]*(rule|pin|opt|file|skip|scope)[[:space:]]' "$CONF"
  exit 0
fi

# ── which files ──────────────────────────────────────────────────────────────
# find, not `git ls-files`: the fixtures drive this against a scratch tree that
# is not a repo, and a scanner that silently scans nothing outside git is the
# same vacuous-green shape the lint exists to stop.
FILE_RE=$(awk '$1=="file"{ $1=""; sub(/^[ \t]+/,""); printf "%s%s", (n++?"|":""), $0 }' "$CONF")
SKIP_RE=$(awk '$1=="skip"{ $1=""; sub(/^[ \t]+/,""); printf "%s%s", (n++?"|":""), $0 }' "$CONF")
# `scope <rule> <ERE>`: a path ONE rule also reads. Fields 1 and 2 are dropped
# with an explicit sub rather than `$1=""; $2=""` so an ERE that contains a
# space survives the strip.
SCOPE_RE=$(awk '$1=="scope"{ sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+/,""); printf "%s%s", (n++?"|":""), $0 }' "$CONF")
[ -n "$FILE_RE" ] || { echo "test-determinism-lint: $CONF has no 'file' selectors" >&2; exit 2; }
SELECT_RE="$FILE_RE"; [ -n "$SCOPE_RE" ] && SELECT_RE="$FILE_RE|$SCOPE_RE"

LIST=$(mktemp) || exit 2
trap 'rm -f "$LIST" ${EFF:+"$EFF"}' EXIT
for P in "${PATHS[@]}"; do
  if [ -f "$P" ]; then printf '%s\n' "$P"
  elif [ -d "$P" ]; then
    find "$P" \( -name .git -o -name node_modules -o -name dist -o -name .wrangler \) -prune -o -type f -print
  fi
done | sed "s|^$ROOT_DEFAULT/||" | grep -E "$SELECT_RE" | { [ -n "$SKIP_RE" ] && grep -vE "$SKIP_RE" || cat; } | sort -u > "$LIST"

if [ "$MODE" = list ]; then cat "$LIST"; exit 0; fi
[ -s "$LIST" ] && ok=1 || { echo "test-determinism-lint: no files to scan under ${PATHS[*]}"; exit 0; }

# ── the scan ─────────────────────────────────────────────────────────────────
# One awk per file: the pin, the waivers and "is this file frozen in calendar
# time" are properties of the WHOLE file, so every line is buffered first and
# judged in END.
SCAN=$(mktemp) || exit 2
trap 'rm -f "$LIST" "$SCAN" ${EFF:+"$EFF"}' EXIT
: > "$SCAN"
while IFS= read -r F; do
  [ -n "$F" ] || continue
  SRC="$F"; [ -f "$SRC" ] || SRC="$ROOT_DEFAULT/$F"
  [ -r "$SRC" ] || continue
  case "$F" in
    *.js|*.mjs|*.cjs|*.ts|*.tsx) LANG=js ;;
    *.sh) LANG=sh ;;
    *.py) LANG=any ;;
    *) LANG=sh ;;
  esac
  # A test file runs every rule; a file reached only by a `scope` line runs only
  # the rules that named it. A path both selectors match is read as a test file
  # (the conservative side).
  if [[ $F =~ $FILE_RE ]]; then ISTEST=1; else ISTEST=0; fi
  awk -v CONF="$CONF" -v FNAME="$F" -v LANG="$LANG" -v ISTEST="$ISTEST" '
  function anymatch(arr, n, s,   i) { for (i = 1; i <= n; i++) if (s ~ arr[i]) return 1; return 0 }
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  # The text the shell itself parses: every quoted string and every $(…) body
  # becomes "_", so a pipe quoted in a bad "…" message, or inside a grep
  # pattern, is never read as a pipe. Nested quotes inside "$(…)" are tracked
  # on a stack; a backslash escapes the next character outside single quotes.
  function unquote(s,   out, i, n, c, c2, st, top) {
    out = ""; n = length(s); st = 0; top = "N"
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1); c2 = substr(s, i, 2)
      if (top == "S") { if (c == q1) { top = stk[st--] }; out = out "_"; continue }
      if (c == "\\") { out = out ((top == "N") ? "__" : "_"); i++; continue }
      if (top == "D") {
        if (c == "\"") top = stk[st--]
        else if (c2 == "$(") { stk[++st] = top; top = "C"; i++ }
        out = out "_"; continue
      }
      # N (top level) or C (inside a command substitution)
      if (c == q1)        { stk[++st] = top; top = "S" }
      else if (c == "\"") { stk[++st] = top; top = "D" }
      else if (c2 == "$(") { stk[++st] = top; top = "C"; i++; out = out "__"; continue }
      else if (c == ")" && top == "C") { top = stk[st--]; out = out "_"; continue }
      out = out ((top == "N") ? c : "_")
    }
    return out
  }
  # sigpipe-negative (BH-1818): 1 when a `| grep -q` in this statement feeds a
  # NEGATIVE check — negated with `!`, or the head of an && chain that ends in
  # an assertion verb (`… | grep -q X && bad … || ok`). s is unquote()d text.
  function signeg(s, assert,   rest, off, p, pre, g, gargs, t) {
    rest = s; off = 0
    while (match(rest, /(^|[^|])\|[ \t]*grep([ \t]|$)/)) {
      p = off + RSTART + ((substr(rest, RSTART, 1) == "|") ? 0 : 1)   # the pipe
      off += RSTART + RLENGTH - 1; rest = substr(s, off + 1)
      if (substr(s, p + 1, 1) == "|") continue                        # ||, not a pipe
      g = substr(s, p + 1); sub(/^[ \t]*grep/, "", g)
      gargs = g; sub(/[;&|].*$/, "", gargs)
      if (gargs !~ /(^|[ \t])(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([ \t]|$)/) continue
      # the pipeline this grep ends: back to the last statement boundary
      pre = substr(s, 1, p - 1)
      sub(/.*(&&|\|\||;|[({]|(^|[ \t])(then|do|else|elif|if|while|until)[ \t])/, "", pre)
      if (pre ~ /^[ \t]*![ \t]/) return 1
      # the && chain after it: every link stands between a false pipeline and ok
      t = substr(g, length(gargs) + 1)
      while (t ~ /^[ \t]*&&/) {
        sub(/^[ \t]*&&[ \t]*/, "", t)
        if (t ~ ("^(\\{[ \t]*)?" assert "([ \t;}]|$)")) return 1
        while (t ~ /^[^;&|]*\|[^|]/) sub(/^[^;&|]*\|/, "", t)       # a later pipe stage
        sub(/^[^;&|]*/, "", t)
      }
    }
    return 0
  }
  BEGIN {
    q1 = sprintf("%c", 39)
    while ((getline ln < CONF) > 0) {
      if (ln ~ /^[ \t]*#/ || ln ~ /^[ \t]*$/) continue
      kind = ln; sub(/[ \t].*$/, "", kind)
      rest = ln; sub(/^[^ \t]+[ \t]+/, "", rest)
      if (kind == "pin")  { pins[++npins] = trim(rest) }
      else if (kind == "opt") {
        k = rest; sub(/[ \t].*$/, "", k)
        v = rest; sub(/^[^ \t]+[ \t]+/, "", v)
        opt[k] = trim(v)
      }
      else if (kind == "rule") {
        n = split(rest, f, /[ \t]+/)
        nm = f[1]; sv = f[2]; lg = f[3]
        re = rest
        sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", re)
        nr++; rname[nr] = nm; rsev[nr] = sv; rlang[nr] = lg; rre[nr] = trim(re)
        known[nm] = 1
      }
      else if (kind == "scope") {
        sn = rest; sub(/[ \t].*$/, "", sn)
        sre = rest; sub(/^[^ \t]+[ \t]+/, "", sre); sre = trim(sre)
        # an explicit if, not a ternary: assigning to rscope[sn] creates the
        # element before the right-hand side is evaluated, so the ternary form
        # always saw an empty previous value and built a leading `|`.
        if (sn in rscope) rscope[sn] = rscope[sn] "|" sre
        else rscope[sn] = sre
      }
    }
    close(CONF)
    ABS = opt["absolute_date_re"]; REL = opt["relative_time_re"]
    DAYPIN = opt["day_pin_re"]; SLEEPSKIP = opt["race_sleep_skip_re"]
    SLEEPMIN = opt["race_sleep_min_s"] + 0
    ARMGATE = opt["branch_arm_gate_re"]; ARMASSERT = opt["branch_arm_assert_re"]
    ARMSKIP = opt["branch_arm_skip_re"]; ARMBREAK = opt["branch_arm_break_re"]
    DGLB = opt["date_guard_lookback"] + 0
    NEGASSERT = opt["sigpipe_negative_assert_re"]; if (NEGASSERT == "") NEGASSERT = "(bad|fail)"
    known["waiver-no-reason"] = 1                     # nameable in a waiver, like any rule
    msg["clock-now-js"]        = "reads the real clock (Date.now) — derive fixtures from one captured anchor and say so, or pin with fake timers"
    msg["clock-new-date"]      = "new Date() with no argument is the wall clock — pass the instant the test means"
    msg["clock-rolling-window"]= "a rolling window asked for by a file whose fixtures are frozen in calendar time — pin the call (?day=YYYY-MM-DD) or build the fixtures relative to now (this is the #360 failure, verbatim)"
    msg["clock-date-cmd"]      = "date renders a calendar field from the wall clock and this file pins no anchor — capture one NOW= and derive from it"
    msg["race-wall-bound"]     = "elapsed wall-clock time captured for a bound (SECONDS=0, $((SECONDS - t0))): a loaded runner stretches it and the check goes red on PRs that did not touch the code (BH-6508) — assert the order of events instead (a marker the slow stub sets, still unset when the call returns), or waive a hang-only ceiling: # determinism: ok race-wall-bound <why>"
    msg["rand-bash"]           = "$RANDOM makes the run unreproducible — use a fixed value, or the test name"
    msg["rand-js"]             = "Math.random makes the run unreproducible — use a fixed value"
    msg["race-sleep"]          = "a foreground sleep as synchronisation is a race that flakes under load — wait on the condition in a bounded loop"
    msg["branch-arm-ungated"]  = "a \"this branch must not touch X\" arm with no own-slice gate: it runs on EVERY PR'\''s CI and goes red on someone else'\''s ticket (#1158, #727, 2026-09-21) — gate the block on the ticket'\''s spec (.harness/specs/BH-N/) or declare the path it owns (own-slice: <path>)"
    msg["date-empty-stamp"]    = "GNU date -d \"\" exits 0 and answers today'\''s 00:00Z, so the || fallback never runs on an empty variable — guard it with [ -n \"$x\" ] || return 1 (or take the caller'\''s unparseable fallback), or waive it: # determinism: ok date-empty-stamp <why>"
    msg["sigpipe-negative"]    = "a NEGATIVE check fed by a pipe into grep -q (BH-1818): when the thing IS there, grep exits at the first match, the producer takes SIGPIPE, pipefail fails the pipeline and the ok branch fires, so the check passes in exactly the case it exists to catch — read the output first: grep -q X <<<\"$(cmd)\""
    msg["race-sigpipe"]        = "a short-circuiting consumer (grep -q, head) on the right of a git pipe: grep exits at the first match, git takes SIGPIPE on the rest, and pipefail turns a TRUE assertion red — capture the output first (<<<), ask git the question (merge-base --is-ancestor), or use a consumer that reads to EOF (grep -c)"
    msg["race-sigpipe-echo"]   = "a short-circuiting consumer (grep -q/-m, head) on the right of a printf/echo pipe: under pipefail the consumer exits at the first match, the writer takes SIGPIPE on the rest, and a TRUE match reads as a miss (BH-6109, tests/llm-call-ratchet-test.sh, PR #6108) — read from a here-string: grep -q X <<<\"$VAR\", or grep -q X < <(printf …) when the bytes must stay exact"
  }
  { line[NR] = $0 }
  END {
    # pass 1: file-level facts
    for (i = 1; i <= NR; i++) {
      l = line[i]
      if (!pinned && anymatch(pins, npins, l)) pinned = 1
      if (!hasabs && ABS != "" && l ~ ABS) hasabs = 1
      if (!hasrel && REL != "" && l ~ REL) hasrel = 1
      p = index(l, "determinism:")
      if (p == 0) continue
      pre = substr(l, 1, p - 1)
      if (pre !~ /(#|\/\/)[ \t]*$/) continue          # only in a comment
      rest = trim(substr(l, p + length("determinism:")))
      scope = ""; whole = 0
      if (rest ~ /^ok-file([ \t]|$)/)   { whole = 1; rest = trim(substr(rest, 8)) }
      else if (rest ~ /^ok([ \t]|$)/)   { rest = trim(substr(rest, 3)) }
      else continue
      nscope = 0
      while (1) {                                      # a waiver may name several rules
        first = rest; sub(/[ \t].*$/, "", first)
        if (!(first in known)) break
        scoped[++nscope] = first; rest = trim(substr(rest, length(first) + 1))
      }
      if (nscope == 0) { scoped[1] = "*"; nscope = 1 }
      if (length(rest) < 3) {                          # a waiver is its reason
        noreason[++nnoreason] = i                      # held: a file waiver may cover it
        continue
      }
      for (k = 1; k <= nscope; k++) {
        if (whole) fwaive[scoped[k]] = 1; else lwaive[i "|" scoped[k]] = 1
      }
    }
    for (k = 1; k <= nnoreason; k++) {
      if (("*" in fwaive) || ("waiver-no-reason" in fwaive)) break
      printf "E\t%s\t%d\t%s\t%s\t%s\n", FNAME, noreason[k], "waiver-no-reason", \
        "a determinism waiver with no reason is just silence — say why this is deterministic", trim(line[noreason[k]])
    }
    # pass 2: the lines
    # A PIPELINE SPLIT OVER PHYSICAL LINES IS STILL ONE PIPELINE. `git log … |`
    # with `grep -q …` on the next line is exactly the race race-sigpipe exists
    # to catch, and a rule that reads one physical line at a time never sees it
    # (review N2 on PR #1235). So each line is joined forward across a PIPE
    # BOUNDARY only — `|` at end of line, `| \`, or `\` with the next line
    # starting `|` — and the rules judge the joined text, reported at the line
    # the pipeline starts on. Only a pipe boundary, because a generic backslash
    # join would move findings of the other seven rules onto a different line.
    # `||` IS NOT A PIPE. Every `… && ok \` / `|| bad "…"` pair in this corpus
    # ends one line with `||` and starts the next with `||`, and reading either
    # as a pipe boundary moved four existing clock-date-cmd warnings onto the
    # wrong line the first time this was written. Hence the [^|] guards.
    for (i = 1; i <= NR; i++) {
      l = line[i]
      if (l ~ /^[ \t]*(#|\/\/|\*|\/\*)/) continue     # a comment calls no route and sleeps for nobody
      lj = l; j = i; njoin = 0
      while (njoin < 4 && j < NR) {
        nxt = line[j + 1]
        if (nxt ~ /^[ \t]*(#|\/\/)/) break
        if (lj ~ /(^|[^|])\|[ \t]*\\?[ \t]*$/) { }     # ends with a pipe (bare or continued)
        else if (lj ~ /\\[ \t]*$/ && trim(nxt) ~ /^\|([^|]|$)/) { }
        else break
        sub(/\\[ \t]*$/, "", lj)
        lj = lj " " trim(nxt)
        j++; njoin++
      }
      for (r = 1; r <= nr; r++) {
        nm = rname[r]
        # a file reached only by a `scope` line runs only the rules that named it
        if (!ISTEST && !((nm in rscope) && FNAME ~ rscope[nm])) continue
        if (rlang[r] != "any" && rlang[r] != LANG) continue
        if (("*" in fwaive) || (nm in fwaive)) continue
        if ((i "|" nm) in covered) continue            # already reported as part of a joined pipeline
        if (lj !~ rre[r]) continue
        jw = j
        # sigpipe-negative reads the whole STATEMENT, not just the pipeline: the
        # `&& bad …` that makes a check negative sits on the continuation line
        # after `| grep -q X \` more often than not. So it joins on across any
        # trailing backslash, and judges the shell-parsed text (quotes masked).
        if (nm == "sigpipe-negative") {
          lx = lj
          while (jw - i < 8 && jw < NR && lx ~ /\\[ \t]*$/ && line[jw + 1] !~ /^[ \t]*#/) {
            sub(/\\[ \t]*$/, "", lx); jw++; lx = lx " " trim(line[jw])
          }
          if (!signeg(unquote(lx), NEGASSERT)) continue
        }
        waived = 0                                     # a waiver on ANY line of the span waives it
        for (k = i; k <= jw; k++) if (((k "|*") in lwaive) || ((k "|" nm) in lwaive)) waived = 1
        if (waived) { for (k = i + 1; k <= j; k++) covered[k "|" nm] = 1; continue }
        if (nm ~ /^clock-/ && nm != "clock-rolling-window" && pinned) continue
        if (nm == "clock-rolling-window") {
          if (!hasabs || hasrel) continue              # fixtures are relative: the right pattern
          if (DAYPIN != "" && lj ~ DAYPIN) continue    # the call pins its own day
        }
        if (nm == "race-sleep") {
          if (SLEEPSKIP != "" && lj ~ SLEEPSKIP) continue
          if (!match(lj, /sleep[ \t]+[0-9]+(\.[0-9]+)?/)) continue
          s = substr(lj, RSTART, RLENGTH); sub(/sleep[ \t]+/, "", s)
          if (s + 0 < SLEEPMIN) continue
        }
        # bj, not j: j holds the last line of the joined pipeline (BH-1248) and
        # the covered[] marking below still reads it after this block has run.
        if (nm == "branch-arm-ungated") {
          if (ARMSKIP != "" && l ~ ARMSKIP) continue   # the command quoted as prose
          bs = 1; be = NR                              # "the same block", by the conf break re
          if (ARMBREAK != "") {
            bs = i; while (bs > 1 && line[bs-1] !~ ARMBREAK) bs--
            be = i; while (be < NR && line[be+1] !~ ARMBREAK) be++
          }
          gated = 0
          for (bj = bs; bj <= be && !gated; bj++) {     # a comment is never a gate
            if (line[bj] ~ /^[ \t]*(#|\/\/)/) continue
            if (ARMGATE != "" && line[bj] ~ ARMGATE) gated = 1
          }
          if (gated) continue
          asserted = 0
          for (bj = i; bj <= be && !asserted; bj++) {   # no judgement below it: a tree read
            if (line[bj] ~ /^[ \t]*(#|\/\/)/) continue
            if (ARMASSERT != "" && line[bj] ~ ARMASSERT) asserted = 1
          }
          if (!asserted) continue
        }
        # BH-1897. Scope first, even in a test file: suites plant stamps on
        # purpose. Then every `date` on the line is judged on its own segment (up
        # to the next | ; & or closing paren), so both vars on
        # metrics-collect.sh:53 are read and a `[ -d "$dir" ]` beside it never is.
        # RSTART/RLENGTH are copied out before the next match() overwrites them.
        if (nm == "date-empty-stamp") {
          if (!((nm in rscope) && FNAME ~ rscope[nm])) continue
          ds = lj; dbad = 0
          while (match(ds, /(^|[^A-Za-z_])date[ \t]/)) {
            ds = substr(ds, RSTART + RLENGTH)
            dseg = ds
            if (match(dseg, /[|;&)]/)) dseg = substr(dseg, 1, RSTART - 1)
            if (!match(dseg, /-d[ \t]*"\$\{?[A-Za-z_0-9]+(:-[^}"]*)?\}?"/)) continue
            darg = substr(dseg, RSTART, RLENGTH)
            match(darg, /\$\{?[A-Za-z_0-9]+/)
            dv = substr(darg, RSTART, RLENGTH); sub(/^\$\{?/, "", dv)
            # BH-1901: a guard is a TEST on dv, not in a comment. `-n` counts after
            # `[`, `[[` or `test` (so not `head -n "$x"`, `grep -n "$x"` or
            # `[ ! -n "$x" ]`). `-z` counts only when the line then leaves the
            # date call behind: `||`, or `&&` / `; then` into return, exit,
            # continue or break (so not `[ -z "$x" ] && e=$(date -d "$x")`).
            dtn = "(^|[^A-Za-z_])(\\[\\[?|test)[ \t]+-n[ \t]+\"?\\$\\{?" dv "[}:\" \t]"
            dtz = "(^|[^A-Za-z_])(\\[\\[?|test)[ \t]+-z[ \t]+\"?\\$\\{?" dv "[}:\" \t]"
            dguard = 0
            for (dk = (i - DGLB > 1 ? i - DGLB : 1); dk <= i && !dguard; dk++) {
              if (line[dk] ~ /^[ \t]*#/) continue
              if (line[dk] ~ dtn) { dguard = 1; continue }
              dz = line[dk]
              while (!dguard && match(dz, dtz)) {
                dz = substr(dz, RSTART + RLENGTH)
                if (dz ~ /^[^|&;]*(\|\||(&&|;[ \t]*then)[ \t]*\{?[ \t]*(return|exit|continue|break)([^A-Za-z_]|$))/) dguard = 1
              }
            }
            if (!dguard) dbad++
          }
          if (!dbad) continue
        }
        # only what is actually reported (or waived) suppresses the continuation
        # lines: a finding the guards below dropped must still be judged on its
        # own line, where the guards may answer differently.
        for (k = i + 1; k <= j; k++) covered[k "|" nm] = 1
        sev = (rsev[r] == "warn") ? "W" : "E"
        text = (nm in msg) ? msg[nm] : ("matches " nm)
        src = trim(lj); gsub(/\t/, " ", src)
        if (length(src) > 120) src = substr(src, 1, 117) "..."
        printf "%s\t%s\t%d\t%s\t%s\t%s\n", sev, FNAME, i, nm, text, src
      }
    }
  }' "$SRC" >> "$SCAN"
done < "$LIST"

# ── the report ───────────────────────────────────────────────────────────────
WARN_SHOW=$(awk '$1=="opt" && $2=="warn_show"{print $3}' "$CONF"); WARN_SHOW="${WARN_SHOW:-8}"
NFILES=$(wc -l < "$LIST" | tr -d ' ')
ERRS=$(awk -F'\t' '$1=="E"' "$SCAN" | wc -l | tr -d ' ')
WARNS=$(awk -F'\t' '$1=="W"' "$SCAN" | wc -l | tr -d ' ')

if [ "$ERRS" -gt 0 ]; then
  echo "── determinism findings (fail) ─────────────────────────────────────"
  awk -F'\t' '$1=="E"{ printf "%s:%s: %s: %s\n      %s\n", $2, $3, $4, $5, $6 }' "$SCAN"
fi
if [ "$WARNS" -gt 0 ]; then
  echo "── determinism warnings (do not fail the run) ──────────────────────"
  awk -F'\t' -v show="$WARN_SHOW" '
    $1=="W" { n[$4]++; if (n[$4] <= show) printf "%s:%s: %s: %s\n", $2, $3, $4, $6 }
    END { for (k in n) if (n[k] > show) printf "  ... and %d more %s warnings\n", n[k] - show, k }' "$SCAN"
fi
echo "test-determinism-lint: $NFILES files scanned, $ERRS findings, $WARNS warnings (rules: $CONF)"
[ "$ERRS" -eq 0 ] && exit 0
[ "$WARN_ONLY" = 1 ] && { echo "(--warn-only: not failing)"; exit 0; }
echo "Fix the line, pin the file's clock, or waive it with a reason:  # determinism: ok <why this is deterministic>"
exit 1
