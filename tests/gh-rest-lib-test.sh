#!/bin/bash
# tests/gh-rest-lib-test.sh — bin/lib/gh-rest.sh on its own: the status/rc
# matrix, the five wrappers, the ALERTS line, temp-file hygiene, and four
# mutants.
#
# WHY THIS SUITE EXISTS (#768, 2026-09-18 02:49-03:05Z). `gh pr view` speaks
# GraphQL, got rate-limited, and answered an empty string. The decision path
# read that silence as "no such PR": five real PRs were rewritten
# RESULT_UNVERIFIED and TK-2302 was launched three times. The library under test
# is the one place that tells "GitHub said no such thing" (44) from "GitHub said
# come back later" (75), so every row here asserts the rc AND GH_REST_STATUS AND
# GH_REST_REASON AND what reached stdout. A suite that only read the rc would
# have been green on the incident.
#
# Nothing here touches the network or the wall clock: `gh` is a stub on PATH
# that replays queued fixture responses and records its own argv, and the one
# timestamp assertion is a shape match, never a comparison against `date`.
#
# Run from anywhere: bash tests/gh-rest-lib-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/gh-rest.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/tmp" "$T/bin" "$T/fx" "$T/mut"
export TMPDIR="$T/tmp"
export PATH="$T/bin:$PATH"
export GH_STUB_DIR="$T"

# ── the stub `gh` ────────────────────────────────────────────────────────────
# Records every argv line, copies any `-F body=@<file>` payload aside so the
# suite can byte-compare it, and replays the lowest-numbered queued fixture.
# No fixture queued = exit 1 with nothing on stdout, which is what a killed or
# missing `gh` looks like to the library (the 000/network row).
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
D="$GH_STUB_DIR"
printf '%s\n' "$*" >> "$D/gh-calls.txt"
for a in "$@"; do
  case "$a" in body=@*) cp "${a#body=@}" "$D/posted-body.txt" 2>/dev/null ;; esac
done
f=$(find "$D/fx" -maxdepth 1 -type f -name '[0-9][0-9]' 2>/dev/null | sort | head -1)
[ -n "$f" ] || exit 1
rc=0
[ -f "$f.rc" ] && rc=$(cat "$f.rc")
cat "$f"
rm -f "$f" "$f.rc"
exit "$rc"
STUB
chmod +x "$T/bin/gh"

# ── fixture helpers, shared with the mutation runner ─────────────────────────
cat > "$T/fxlib.sh" <<'FXLIB'
# Sourced by this suite and by core.sh. $T must already be set.
FXN=0
fx() { # fx <status> [body] [proto] [rc]
  FXN=$((FXN + 1))
  local f rc
  f="$T/fx/$(printf '%02d' "$FXN")"
  { printf '%s %s Status\r\n' "${3:-HTTP/2.0}" "$1"
    printf 'X-RateLimit-Remaining: 0\r\n'
    printf '\r\n'
    printf '%s' "${2:-}"
  } > "$f"
  rc="${4:-}"
  if [ -z "$rc" ]; then case "$1" in 2*) rc=0 ;; *) rc=1 ;; esac; fi
  printf '%s' "$rc" > "$f.rc"
}
reset() { # drop every queued fixture and every recording
  rm -rf "$T/fx"
  mkdir -p "$T/fx"
  FXN=0
  rm -f "$T/gh-calls.txt" "$T/posted-body.txt" "$T/out"
}
FXLIB
. "$T/fxlib.sh"

calls()  { cat "$T/gh-calls.txt" 2>/dev/null; }
ncalls() { if [ -f "$T/gh-calls.txt" ]; then wc -l < "$T/gh-calls.txt"; else echo 0; fi; }

notmp() { # no gh-rest.* survives a return, on any path
  local left
  left=$(find "$TMPDIR" -maxdepth 1 -name 'gh-rest.*' 2>/dev/null | wc -l)
  if [ "$left" = 0 ]; then ok; else bad "$1: $left temp file(s) left under TMPDIR"; fi
}

row() { # row <label> <rc> <status> <reason> <stdout> -- <command...>
  local label=$1 wrc=$2 wst=$3 wrs=$4 wout=$5; shift 5
  [ "${1:-}" = -- ] && shift
  local rc got why=""
  "$@" > "$T/out" 2>/dev/null; rc=$?
  got=$(cat "$T/out")
  [ "$rc"  = "$wrc" ]            || why="$why rc=$rc(want $wrc)"
  [ "$GH_REST_STATUS" = "$wst" ] || why="$why status=$GH_REST_STATUS(want $wst)"
  [ "$GH_REST_REASON" = "$wrs" ] || why="$why reason='$GH_REST_REASON'(want '$wrs')"
  [ "$got" = "$wout" ]           || why="$why stdout='$got'(want '$wout')"
  if [ -z "$why" ]; then ok; else bad "$label:$why"; fi
  notmp "$label"
}

if ! . "$LIB"; then
  bad "bin/lib/gh-rest.sh is missing or cannot be sourced — every row below is red"
fi

# ══ 1. the status/rc matrix ═════════════════════════════════════════════════
reset; fx 200 '{"a":1}'
row '200 object'        0  200 ''          '{"a":1}'   -- gh_rest GET repos/o/r/pulls/7
reset; fx 200 '{"a":1}' HTTP/1.1
row '200 over HTTP/1.1' 0  200 ''          '{"a":1}'   -- gh_rest GET repos/o/r/pulls/7
reset; fx 200 'HTTP/2.0 500 not a header'
row '200 body that looks like a status line' 0 200 '' 'HTTP/2.0 500 not a header' -- gh_rest GET repos/o/r/pulls/7
reset; fx 404 '{"message":"Not Found"}'
row '404'               44 404 ''          ''          -- gh_rest GET repos/o/r/pulls/7
reset; fx 403 '{"message":"API rate limit exceeded for user"}'
row '403 rate limit'    75 403 rate-limit  ''          -- gh_rest GET repos/o/r/pulls/7
reset; fx 403 '{"message":"Resource not accessible by integration"}'
row '403 not rate limit' 75 403 ''         ''          -- gh_rest GET repos/o/r/pulls/7
reset; fx 403 '{"message":"You have exceeded a secondary rate limit"}'
row '403 secondary'     75 403 rate-limit  ''          -- gh_rest GET repos/o/r/pulls/7
reset; fx 429 '{"message":"triggered an abuse detection mechanism"}'
row '429 abuse'         75 429 rate-limit  ''          -- gh_rest GET repos/o/r/pulls/7
reset; fx 401 '{"message":"Bad credentials"}'
row '401'               75 401 auth        ''          -- gh_rest GET repos/o/r/pulls/7
reset; fx 500 '{"message":"rate limit"}'
row '500 saying rate limit' 75 500 ''      ''          -- gh_rest GET repos/o/r/pulls/7
reset; fx 502 ''
row '502'               75 502 ''          ''          -- gh_rest GET repos/o/r/pulls/7
reset; fx 301 ''
row '301 first status line' 75 301 ''      ''          -- gh_rest GET repos/o/r/pulls/7
reset
row 'no status line at all' 75 000 network ''          -- gh_rest GET repos/o/r/pulls/7
reset; fx 200 ''
row '200 empty body on GET' 75 200 empty   ''          -- gh_rest GET repos/o/r/pulls/7
reset; fx 200 '{}'
row '200 {} is a body'  0  200 ''          '{}'        -- gh_rest GET repos/o/r/pulls/7
reset; fx 200 '[]'
row '200 [] via pr_list' 0 200 ''          '[]'        -- gh_rest_pr_list o/r open
case "$(calls)" in
  *"-f state=open"*) ok ;;
  *) bad "pr_list: -f state=open missing from argv: $(calls)" ;;
esac
case "$(calls)" in
  *"-F per_page=100"*) ok ;;
  *) bad "pr_list: -F per_page=100 missing from argv: $(calls)" ;;
esac
reset; fx 200 '[]'
row 'pr_list with head' 0  200 ''          '[]'        -- gh_rest_pr_list o/r open o:branch 50
case "$(calls)" in
  *"-f head=o:branch"*) ok ;;
  *) bad "pr_list: -f head=o:branch missing from argv: $(calls)" ;;
esac
case "$(calls)" in
  *"-F per_page=50"*) ok ;;
  *) bad "pr_list: explicit per_page not honoured: $(calls)" ;;
esac
reset; fx 200 ''
row '200 empty via pr_list is never []' 75 200 empty '' -- gh_rest_pr_list o/r open
reset; fx 200 '{"m":"abuse detection is only a word here"}'
row '2xx body carrying "abuse"' 0 200 ''   '{"m":"abuse detection is only a word here"}' -- gh_rest GET repos/o/r/pulls/7
reset; fx 204 ''
row '204 empty on a write' 0 204 ''        ''          -- gh_rest PATCH repos/o/r/issues/7

# ══ 2. malformed arguments: 75, never 44, and ZERO network calls ════════════
for BAD in 'https://github.com/o/r|7' 'o/r|7x' 'o|7' 'o/r/x|7' 'o/r|' '|7'; do
  SLUG=${BAD%%|*}; NUM=${BAD#*|}
  reset
  row "bad args '$SLUG' '$NUM'" 75 000 bad-args '' -- gh_rest_pr_state "$SLUG" "$NUM"
  if [ "$(ncalls)" = 0 ]; then ok; else bad "bad args '$SLUG' '$NUM': $(ncalls) gh call(s) were made"; fi
done
reset
row 'bad slug via issue_state' 75 000 bad-args '' -- gh_rest_issue_state 'o' 7
reset
row 'bad slug via pr_list'     75 000 bad-args '' -- gh_rest_pr_list 'o' open
reset
row 'bad slug via close'       75 000 bad-args '' -- gh_rest_close 'o/r/x' 7
if [ "$(ncalls)" = 0 ]; then ok; else bad "bad args reached the network: $(calls)"; fi

# ══ 3. gh_rest_pr_state ═════════════════════════════════════════════════════
reset; fx 200 '{"state":"open","merged_at":null}'
row 'pr open'       0  200 '' open   -- gh_rest_pr_state o/r 7
reset; fx 200 '{"state":"closed","merged_at":"2026-09-18T04:00:00Z"}'
row 'pr merged'     0  200 '' merged -- gh_rest_pr_state o/r 7
reset; fx 200 '{"state":"closed","merged_at":null}'
row 'pr closed'     0  200 '' closed -- gh_rest_pr_state o/r 7
reset; fx 200 'not json at all'
row 'pr unparseable' 75 200 '' ''    -- gh_rest_pr_state o/r 7
reset; fx 404 '{"message":"Not Found"}'
row 'pr 404'        44 404 '' ''     -- gh_rest_pr_state o/r 7

# ══ 4. gh_rest_issue_state ══════════════════════════════════════════════════
reset; fx 200 '{"state":"open"}'
row 'issue open'    0  200 '' open   -- gh_rest_issue_state o/r 20
reset; fx 200 '{"state":"closed"}'
row 'issue closed'  0  200 '' closed -- gh_rest_issue_state o/r 20
reset; fx 404 '{"message":"Not Found"}'
row 'issue 404'     44 404 '' ''     -- gh_rest_issue_state o/r 20

# ══ 5. the status reaches the CALLER's shell, and errexit reaches the map ═══
reset; fx 403 '{"message":"API rate limit exceeded for user"}'
gh_rest_pr_state o/r 7 > "$T/out" 2>/dev/null; RC=$?
if [ "$RC" = 75 ] && [ "$GH_REST_STATUS" = 403 ] && [ "$GH_REST_REASON" = rate-limit ]; then ok
else bad "plain-command call: want rc 75 status 403 rate-limit, got rc=$RC status=$GH_REST_STATUS reason=$GH_REST_REASON"; fi
reset; fx 403 '{"message":"API rate limit exceeded for user"}'
S=$(gh_rest_pr_state o/r 7 2>/dev/null); RC=$?
if [ "$RC" = 75 ] && [ -z "$S" ]; then ok; else bad "captured call: the rc must survive \$( ), got rc=$RC out='$S'"; fi
reset; fx 404 '{"message":"Not Found"}'
OUT=$( set -e; gh_rest GET repos/o/r/pulls/9 >/dev/null 2>&1 || echo "rc=$?" )
if [ "$OUT" = "rc=44" ]; then ok; else bad "an errexit caller must reach the 44 mapping, got '$OUT'"; fi
reset; fx 403 '{"message":"API rate limit exceeded for user"}'
( set -e; gh_rest GET repos/o/r/pulls/9 >/dev/null 2>&1 ); RC=$?
if [ "$RC" = 75 ]; then ok; else bad "an errexit subshell must exit 75, not gh's own rc, got $RC"; fi
# A WRAPPER called as a plain statement under errexit. The caller dies on the
# 44/75 — that is what errexit is for — but the library must not take its temp
# file down with it: `cmd; rc=$?` inside the wrapper would be killed before its
# own `rm -f` and leak one gh-rest.XXXXXX per failing tick.
reset; fx 403 '{"message":"API rate limit exceeded for user"}'
( set -e; gh_rest_pr_state o/r 7 > "$T/out" 2>/dev/null ); RC=$?
if [ "$RC" = 75 ]; then ok; else bad "errexit + plain-statement wrapper: want rc 75, got $RC"; fi
notmp 'errexit + plain-statement wrapper'
reset; fx 200 'not json at all'
( set -e; gh_rest_pr_state o/r 7 >/dev/null 2>&1 ); RC=$?
if [ "$RC" = 75 ]; then ok; else bad "errexit + unparseable JSON: want rc 75, got $RC"; fi
notmp 'errexit + unparseable JSON'
reset; fx 200 '{"state":"closed"}'; fx 403 '{"message":"API rate limit exceeded for user"}'
( set -e; gh_rest_close o/r 20 >/dev/null 2>&1 ); RC=$?
if [ "$RC" = 75 ]; then ok; else bad "errexit + close whose re-read is unverifiable: want rc 75, got $RC"; fi
notmp 'errexit + close re-read'

# ══ 6. gh_rest_comment: the body goes by FILE, byte for byte ════════════════
cat > "$T/body.md" <<'BODY'
He said "double" and 'single' and $NOT_EXPANDED and `backticks`.

Two newlines above this line.
BODY
reset; fx 201 '{"id":1}'
row 'comment 201' 0 201 '' '' -- gh_rest_comment o/r 20 "$T/body.md"
case "$(calls)" in
  *"-F body=@$T/body.md"*) ok ;;
  *) bad "comment: the POST must pass -F body=@<file>, got: $(calls)" ;;
esac
if grep -q 'double' "$T/gh-calls.txt"; then bad "comment: the body text reached argv"; else ok; fi
if cmp -s "$T/body.md" "$T/posted-body.txt"; then ok; else bad "comment: the posted body is not byte-identical to the file"; fi
reset; fx 403 '{"message":"Resource not accessible"}'
row 'comment 403' 75 403 '' '' -- gh_rest_comment o/r 20 "$T/body.md"
reset; fx 404 '{"message":"Not Found"}'
row 'comment 404 is 75, not 44' 75 404 '' '' -- gh_rest_comment o/r 20 "$T/body.md"
reset
row 'comment with no body file' 75 000 bad-args '' -- gh_rest_comment o/r 20 "$T/nope.md"
if [ "$(ncalls)" = 0 ]; then ok; else bad "comment: a missing body file must cost zero gh calls"; fi

# ══ 7. gh_rest_close: rc 0 only when a fresh read says closed ═══════════════
reset; fx 200 '{"state":"closed"}'; fx 200 '{"state":"closed"}'
row 'close issue, re-read closed' 0 200 '' '' -- gh_rest_close o/r 20
if [ "$(calls | grep -c -- '-X PATCH')" = 1 ] && [ "$(calls | grep -c -- '-X GET')" = 1 ]; then ok
else bad "close: want one PATCH then one GET, got: $(calls)"; fi
reset; fx 200 '{"state":"closed"}'; fx 200 '{"state":"open"}'
row 'close issue, re-read still open' 75 200 '' '' -- gh_rest_close o/r 20
reset; fx 403 '{"message":"Resource not accessible"}'
row 'close refused by the PATCH' 75 403 '' '' -- gh_rest_close o/r 20
if [ "$(ncalls)" = 1 ]; then ok; else bad "close: a refused PATCH must not be re-read, got $(ncalls) call(s)"; fi
reset; fx 200 '{}'; fx 200 '{"state":"closed","merged_at":null}'
row 'close pr, re-read closed' 0 200 '' '' -- gh_rest_close o/r 41 pulls
reset; fx 200 '{}'; fx 200 '{"state":"closed","merged_at":"2026-09-18T04:00:00Z"}'
row 'close pr, re-read merged is NOT closed' 75 200 '' '' -- gh_rest_close o/r 41 pulls
reset; fx 200 '{}'; fx 404 '{"message":"Not Found"}'
row 'close pr, re-read 404' 75 404 '' '' -- gh_rest_close o/r 41 pulls
reset; fx 200 '{}'
row 'close pr, re-read unverifiable' 75 000 network '' -- gh_rest_close o/r 41 pulls

# ══ 8. gh_rest_alert: one line, the LABEL, never the value ══════════════════
ALOG="$T/h/logs/ALERTS.log"
rm -f "$ALOG"
reset; fx 403 '{"message":"API rate limit exceeded for user"}'
export GH_TOKEN=ghp_SECRETVALUE
gh_rest_pr_state o/r 7 > "$T/out" 2>/dev/null
gh_rest_alert proj "read pr state" "o/r#7"; ARC=$?
if [ "$ARC" = 0 ]; then ok; else bad "alert: a successful append must return 0, got $ARC"; fi
LINE=$(cat "$ALOG" 2>/dev/null)
case "$LINE" in
  *"[proj]"*) ok ;; *) bad "alert: no [proj] in '$LINE'" ;;
esac
case "$LINE" in
  *"gh-rest: read pr state o/r#7"*) ok ;; *) bad "alert: what/path missing from '$LINE'" ;;
esac
case "$LINE" in
  *"HTTP 403 (rate-limit)"*) ok ;; *) bad "alert: status/reason missing from '$LINE'" ;;
esac
case "$LINE" in
  *"token=explicit"*) ok ;; *) bad "alert: token label missing from '$LINE'" ;;
esac
if grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z ' <<<"$LINE"; then ok
else bad "alert: the line must open with a UTC stamp, got '$LINE'"; fi
if [ "$(grep -c ghp_SECRETVALUE "$ALOG")" = 0 ]; then ok; else bad "alert: THE TOKEN VALUE IS IN ALERTS.log"; fi
if [ "$(grep -c ghp_SECRETVALUE "$T/gh-calls.txt")" = 0 ]; then ok; else bad "the token value reached gh's argv"; fi
if [ "$(grep -c '—' "$ALOG")" = 0 ]; then ok; else bad "alert: em dash in the line (de-AI voice)"; fi
gh_rest_alert proj "read pr state" "o/r#7"
if [ "$(wc -l < "$ALOG")" = 2 ]; then ok; else bad "alert: the log must be appended, not rewritten ($(wc -l < "$ALOG") line(s))"; fi
unset GH_TOKEN
rm -f "$ALOG"
reset
gh_rest GET repos/o/r/pulls/7 > "$T/out" 2>/dev/null
gh_rest_alert proj "read pr state" "o/r#7"
LINE=$(cat "$ALOG" 2>/dev/null)
case "$LINE" in
  *"HTTP 000 (network)"*) ok ;; *) bad "alert: a dead gh must read as HTTP 000 (network), got '$LINE'" ;;
esac
case "$LINE" in
  *"token=default"*) ok ;; *) bad "alert: an unset GH_TOKEN must label as default, got '$LINE'" ;;
esac
mkdir -p "$T/h2"
: > "$T/h2/logs"
( HARNESS="$T/h2"; gh_rest_alert proj "read pr state" "o/r#7" ) 2>/dev/null; ARC=$?
if [ "$ARC" != 0 ]; then ok; else bad "alert: a failed append must return non-zero, got 0"; fi

# ══ 9. the marker line, and re-sourcing ═════════════════════════════════════
if grep -qx '# gh-rest: no-graphql' "$LIB"; then ok
else bad "the library must carry the exact marker line '# gh-rest: no-graphql'"; fi
GH_REST_STATUS=403
. "$LIB"
if [ "$GH_REST_STATUS" = 403 ]; then ok; else bad "re-sourcing the library clobbered a live GH_REST_STATUS"; fi
if command -v gh_rest >/dev/null && command -v gh_rest_alert >/dev/null; then ok
else bad "re-sourcing the library dropped its functions"; fi
# The library's SHAPE, not its size (BH-5228). Until BH-5228 this was
# GH_REST_LIB_CODE_LINE_CEILING (96 -> 110 -> 112 -> 113 code lines), there to
# stop the next caller-conversion growing a contract file into a lane: new
# logic goes in a sibling (bin/lib/gh-rest-ledger.sh, gh-rest-var.sh and
# gh-rest-etag.sh are the pattern) behind one guarded source line here. A line
# count was a proxy for that and cost a constant bump per honest line. The
# invariant itself is two facts, checked directly by ghr_shape:
#   F  the functions this file defines (read at runtime: extdebug + declare -F,
#      so a name in a comment is not a definition) are EXACTLY the contract
#      below. A new helper here fails; it lives in its own sibling lib.
#   T  every top-level line (outside a function body) is a comment, the
#      re-source guard, a plain assignment, or a guarded sibling source
#      `[ -r <path> ] && . <path> [2>/dev/null] [|| true]`, with no other
#      `;`, `|`, `&`, `<` or `>` on the line, and no `$`, `(` or `)` in a plain
#      assignment. Logic at source time fails, and so does a process
#      substitution (`X=<(cmd)` runs cmd when the file is sourced).
# Both are driven over fixtures first, so a green on the real file is not
# vacuous: 40 comment lines plus one new guarded sibling source pass, an extra
# function fails F, a top-level `if` fails T, a `<(…)` assignment or source
# fails T. Adding a contract function is a
# one-word edit to GH_REST_CONTRACT_FNS, argued for in the PR like the ceiling
# raises were.
GH_REST_CONTRACT_FNS="_gh_rest_args_ok _gh_rest_bad_args _gh_rest_field _gh_rest_sniff gh_rest gh_rest_alert gh_rest_close gh_rest_comment gh_rest_issue_state gh_rest_pr_list gh_rest_pr_state"
ghr_shape() { # ghr_shape <lib file> -> violations on stdout; rc 0 when none
  local f="$1" got want top rc=0
  got=$(env -i PATH="$PATH" HARNESS="$T/shape-h" bash --noprofile --norc -c '
    shopt -s extdebug; . "$1" >/dev/null 2>&1 || exit 3
    for n in $(declare -F | awk "{print \$3}"); do
      d=$(declare -F "$n"); [ "${d##* }" = "$1" ] && echo "$n"
    done' _ "$f" </dev/null | sort | tr '\n' ' ')
  want=$(printf '%s\n' $GH_REST_CONTRACT_FNS | sort | tr '\n' ' ')
  [ -n "$got" ] || { echo "F: sourcing $f defined nothing"; return 1; }
  [ "$got" = "$want" ] || { rc=1; echo "F: $f defines [$got], the contract is [$want] — a new helper goes in a sibling lib behind a guarded source line"; }
  top=$(awk '
    infn { if ($0 ~ /^}/) infn=0; next }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ { if ($0 !~ /\}[[:space:]]*(#.*)?$/) infn=1; next }
    /^if \[ -n "\$\{GH_REST_LIB:-\}" \]; then return 0 2>\/dev\/null; fi$/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*=[^;|&`$<>()]*$/ { next }
    /^\[ -r .+ \] && \. / { l=$0; sub(/( 2>\/dev\/null)?( \|\| true)?$/, "", l); sub(/ \] && \. /, " ", l)
      if (l !~ /[;|&`<>]/) next }
    { printf "T: line %d is logic at source time: %s\n", NR, $0 }' "$f")
  [ -z "$top" ] || { rc=1; printf '%s\n' "$top"; }
  return "$rc"
}
mkdir -p "$T/shape-h" "$T/shape"
{ cat "$LIB"; i=0; while [ "$i" -lt 40 ]; do echo "# padding $i"; i=$((i+1)); done
  echo '[ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest-new.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-new.sh" 2>/dev/null || true'
} > "$T/shape/gh-rest.sh"
if OUT=$(ghr_shape "$T/shape/gh-rest.sh"); then ok; else bad "the shape check refuses a lib grown by comments and a guarded sibling source: $OUT"; fi
{ cat "$LIB"; echo 'gh_rest_new_helper() { :; }'; } > "$T/shape/gh-rest.sh"
OUT=$(ghr_shape "$T/shape/gh-rest.sh")
if grep -q '^F:' <<<"$OUT"; then ok; else bad "the shape check accepts a new function in the contract file"; fi
{ cat "$LIB"; printf 'if [ -n "${X:-}" ]; then\n  GH_REST_REASON=x\nfi\n'; } > "$T/shape/gh-rest.sh"
OUT=$(ghr_shape "$T/shape/gh-rest.sh")
if grep -q '^T:' <<<"$OUT"; then ok; else bad "the shape check accepts top-level logic in the contract file"; fi
{ cat "$LIB"; echo 'GH_REST_X=<(date)'; } > "$T/shape/gh-rest.sh"
OUT=$(ghr_shape "$T/shape/gh-rest.sh")
if grep -q '^T:.*GH_REST_X=<(date)' <<<"$OUT"; then ok; else bad "the shape check accepts a process-substitution assignment in the contract file"; fi
{ cat "$LIB"; echo '[ -r /dev/null ] && . <(echo true)'; } > "$T/shape/gh-rest.sh"
OUT=$(ghr_shape "$T/shape/gh-rest.sh")
if grep -q '^T:.*<(echo true)' <<<"$OUT"; then ok; else bad "the shape check accepts a guarded source of a process substitution in the contract file"; fi
if OUT=$(ghr_shape "$LIB"); then ok
else bad "bin/lib/gh-rest.sh is past its contract: $OUT"; fi
if [ "$(grep -v '^[[:space:]]*#' "$LIB" | grep -c 'gh api')" = 1 ]; then ok
else bad "'gh api' must appear at exactly ONE command position in the library"; fi

# ══ 10. mutation checks (D1) ════════════════════════════════════════════════
# core.sh re-runs the load-bearing rows against an arbitrary copy of the
# library. It must pass against the real file and fail against every mutant; a
# mutant that stays green means the row above it is decorative.
cat > "$T/core.sh" <<'CORE'
#!/bin/bash
# core.sh <lib> <T> <label> — block 1's load-bearing rows, against one copy of
# the library. Exit code = the number of rows that failed.
set -uo pipefail
LIB=$1; T=$2; LABEL=$3
export HARNESS="$T/h-$LABEL"
. "$T/fxlib.sh"
F=0
say() { F=$((F + 1)); echo "  core($LABEL): $1"; }
. "$LIB" || { echo "  core($LABEL): cannot source $LIB"; exit 9; }

reset; fx 200 '{"a":1}'
O=$(gh_rest GET repos/o/r/pulls/7 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$O" = '{"a":1}' ] || say "2xx body row (rc=$RC out='$O')"

reset; fx 404 '{"message":"Not Found"}'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1; RC=$?
[ "$RC" = 44 ] || say "404 -> 44 row (rc=$RC)"

reset; fx 200 ''
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1; RC=$?
[ "$RC" = 75 ] && [ "$GH_REST_REASON" = empty ] || say "empty 2xx GET -> 75 row (rc=$RC reason=$GH_REST_REASON)"

reset; fx 200 '{"m":"abuse detection is only a word here"}'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && [ -z "$GH_REST_REASON" ] || say "2xx abuse body is not rate-limit (rc=$RC reason=$GH_REST_REASON)"

reset; fx 403 '{"message":"API rate limit exceeded for user"}'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1; RC=$?
[ "$RC" = 75 ] && [ "$GH_REST_REASON" = rate-limit ] || say "403 rate-limit row (rc=$RC reason=$GH_REST_REASON)"
export GH_TOKEN=ghp_SECRETVALUE
gh_rest_alert proj "read pr state" "o/r#7"
grep -q ghp_SECRETVALUE "$HARNESS/logs/ALERTS.log" 2>/dev/null && say "the alert printed the token VALUE"
exit "$F"
CORE
if bash "$T/core.sh" "$LIB" "$T" real >"$T/core.log" 2>&1; then ok
else bad "the mutation runner is red against the REAL library: $(cat "$T/core.log")"; fi

mut() { # mut <n> <label> <sed expression>
  local n=$1 label=$2 expr=$3
  local copy="$T/mut/m$n.sh"
  cp "$LIB" "$copy" 2>/dev/null || { bad "mutant $n ($label): no library to mutate"; return; }
  sed -i "$expr" "$copy"
  if cmp -s "$LIB" "$copy"; then
    bad "mutant $n ($label): the mutation changed nothing — the row it guards is untested"
    return
  fi
  if bash "$T/core.sh" "$copy" "$T" "m$n" >/dev/null 2>&1; then
    bad "mutant $n ($label): the suite stayed GREEN under the mutation"
  else
    echo "mutant $n caught ($label)"; ok
  fi
}
mut 1 '404 maps to success'          's/404) rm -f "\$tmp"; return 44/404) rm -f "$tmp"; return 0/'
mut 2 'the empty-body branch is gone' '/GH_REST_REASON=empty/d'
mut 3 'the rate-limit sniff runs on every status' 's/403|429)/*)/'
mut 4 'the alert prints the token value' 's/"\$label"/"${GH_TOKEN:-}"/'

echo "gh-rest-lib: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
