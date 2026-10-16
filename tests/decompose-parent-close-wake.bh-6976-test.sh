#!/bin/bash
# tests/decompose-parent-close-wake.bh-6976-test.sh — BH-6976 lane B: past its
# 600 s cooldown, `decompose-parent-close.sh <p> --cooled` runs the GitHub-board
# pass only on an issue wake for a key in state/parent-close-<p>.keys, a
# `retry` line, or once the last pass is PARENT_CLOSE_BACKSTOP_S (1800) old.
#
# The REAL script runs as its callers run it, against a file-backed REST `gh`
# that logs every call. prs_wake_seen is an exported table double (lines
# `kind key rc`, `*` matches anything, first match wins, no match rc 1). The
# clock is the box's own: "+700 s" is a MARK written 700 s ago.
#
#   P1  first run (no MARK) -> both lists read, the keys file names open child
#       11 and parent 10 and not closed child 12
#   P2  +700 s, no wake -> zero calls; MARK content and mtime unchanged
#   P3  +700 s, keys file deleted -> lists read
#   P4  child 11 closed + merged, a wake `issue 11` at +700 s -> lists read,
#       prints 10, closes it, logs `pass on wake:issue:11`
#   P5  +1800 s, no wake -> lists read, logs `pass on backstop`; +1700 s quiet
#   P6  +300 s with a wake -> zero calls (the floor holds)
#   P7  an in-app project (no repo) -> the cooldown alone: +700 s runs with no
#       wake question, +300 s does not
#   P8  a close that did not land writes `retry` -> +700 s runs with no wake
#   P9  a hand run (no --cooled) is never held; WAKE_BACKSTOP=0 runs at +700 s
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/decompose-parent-close-wake.bh-6976-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date +%s)

REPO="example-org/cromford"
mkdir -p "$T/stub"
( cd "$DIR" && scratch_install_closure bin/decompose-parent-close.sh "$T" ) >/dev/null \
  || { echo "setup: could not install bin/decompose-parent-close.sh"; exit 1; }

# gh: the two REST lists from $CASE, a parent by number, comment + close
# writes. $CASE/patch-fail makes the close answer 403.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/calls"
M=""; P=""; prev=""; page=1
for a in "$@"; do
  [ "$prev" = -X ] && M="$a"
  case "$a" in repos/*) P="$a" ;; page=*) page="${a#page=}" ;; esac
  prev="$a"
done
pg() {
  printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' \
    "$(jq -c --argjson p "$page" "$2 | .[(\$p-1)*100:\$p*100]" "$1" 2>/dev/null || echo '[]')"
}
case "$M $P" in
  "GET repos/$GH_ISSUES_REPO/issues")
    pg "$CASE/issues.json" 'map(.state |= ascii_downcase
      | .state_reason = ((.stateReason // null) | if . == null then null else ascii_downcase end)
      | del(.stateReason))'; exit 0 ;;
  "GET repos/$GH_ISSUES_REPO/pulls")
    pg "$CASE/prs.json" 'map({number, html_url:.url, title, head:{ref:.headRefName},
      state:(if .state == "OPEN" then "open" else "closed" end),
      merged_at:(if .state == "MERGED" then "2026-09-20T10:00:00Z" else null end)})'; exit 0 ;;
esac
if [ "$#" = 2 ] && [ "$1" = api ]; then
  case "$2" in
    repos/"$GH_ISSUES_REPO"/issues/[0-9]*)
      n="${2##*/issues/}"
      [ -f "$CASE/issue-$n.json" ] || { echo '{"message":"Not Found"}'; exit 1; }
      jq -c '.state |= ascii_downcase' "$CASE/issue-$n.json"; exit 0 ;;
  esac
fi
case "$*" in
  *"-X POST"*"/comments"*)
    printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n' ;;
  *"-X PATCH"*"/issues/"*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    if [ -f "$CASE/patch-fail" ]; then printf 'HTTP/2.0 403 Forbidden\nx-stub: 1\n\n{"message":"no"}\n'; exit 1; fi
    echo "$n" >> "$CASE/closed"
    jq -c '.state="CLOSED"' "$CASE/issue-$n.json" > "$CASE/issue-$n.tmp" && mv "$CASE/issue-$n.tmp" "$CASE/issue-$n.json"
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed"}\n' ;;
  *"-X GET"*"/issues/"*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"%s"}\n' "$(jq -r '.state | ascii_downcase' "$CASE/issue-$n.json")" ;;
  "api "*"/issues/"*"/comments"*) echo '[]' ;;
  *) echo '[]' ;;
esac
SH
chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH" PARENT_CLOSE_COOLDOWN_S=600 GH_ISSUES_REPO="$REPO" REVDEP_WAKE=1

prs_wake_seen() {
  local r
  printf 'WAKE %s %s %s %s\n' "$@" >> "$CASE/wake.calls"
  r=$(awk -v k="$2" -v key="$3" '($1 == k || $1 == "*") && ($2 == key || $2 == "*") { print $3; exit }' "$CASE/wake")
  return "${r:-1}"
}
export -f prs_wake_seen

kid() { # kid <n> <parent> <k> <of> <OPEN|CLOSED>
  printf '{"number":%s,"state":"%s","stateReason":"%s","title":"BH-%s.%s part","body":"Part of #%s\\nOrder: %s of %s"}' \
    "$1" "$5" "$([ "$5" = CLOSED ] && echo COMPLETED)" "$2" "$3" "$2" "$3" "$4"
}
mpr() { printf '{"number":%s,"url":"https://github.com/%s/pull/%s","title":"BH-%s: part","headRefName":"ticket/bh-%s","state":"MERGED"}' "$2" "$REPO" "$2" "$1" "$1"; }
newcase() { # newcase <name> — parent 10, child 11 open, child 12 closed + merged
  CASE="$T/cases/$1"; mkdir -p "$CASE/logs" "$CASE/state"; export CASE
  printf '[%s,%s]\n' "$(kid 11 10 1 2 OPEN)" "$(kid 12 10 2 2 CLOSED)" > "$CASE/issues.json"
  printf '[%s]\n' "$(mpr 12 22)" > "$CASE/prs.json"
  printf '{"number":10,"state":"OPEN","title":"the parent","labels":[]}\n' > "$CASE/issue-10.json"
  printf '* * 1\n' > "$CASE/wake"
  MARK="$CASE/state/parent-close-cromford.last"
  KEYS="$CASE/state/parent-close-cromford.keys"
}
dp() { rm -f "$CASE/calls"; OUT=$(HARNESS="$CASE" "$T/bin/decompose-parent-close.sh" cromford "$@" 2>/dev/null); }
ago() { echo "$((NOW - $1))" > "$MARK"; touch -d "@$((NOW - $1))" "$MARK"; }
lists() { cat "$CASE/calls" 2>/dev/null | grep -cE "repos/$REPO/(issues|pulls)( |\$|\?)"; }
ncalls() { cat "$CASE/calls" 2>/dev/null | grep -c .; }
plog() { cat "$CASE/logs/cromford.log" 2>/dev/null; }

# ── P1 ─────────────────────────────────────────────────────────────────────
newcase p1
dp --cooled
[ "$(lists)" -ge 2 ] && ok || bad "P1 the first run wanted both list reads: $(cat "$CASE/calls" 2>/dev/null)"
[ -s "$MARK" ] && ok || bad "P1 no MARK was written"
[ "$(sort -n "$KEYS" 2>/dev/null | tr '\n' ' ')" = "10 11 " ] && ok || bad "P1 the keys file is '$(cat "$KEYS" 2>/dev/null)', wanted 11 and 10"

# ── P2 ─────────────────────────────────────────────────────────────────────
ago 700
M0=$(cat "$MARK"); T0=$(stat -c %Y "$MARK")
dp --cooled
[ "$(ncalls)" = 0 ] && ok || bad "P2 a quiet run at +700 s made calls: $(cat "$CASE/calls")"
[ "$(cat "$MARK")" = "$M0" ] && [ "$(stat -c %Y "$MARK")" = "$T0" ] && ok || bad "P2 the quiet exit moved MARK"
[ -z "$OUT" ] && ok || bad "P2 a quiet run printed '$OUT'"
grep -q "^WAKE $REPO issue 11 $M0\$" "$CASE/wake.calls" && grep -q "^WAKE $REPO issue 10 $M0\$" "$CASE/wake.calls" && ok \
  || bad "P2 the feed was not asked about 11 and 10 since MARK: $(cat "$CASE/wake.calls" 2>/dev/null)"

# ── P3 ─────────────────────────────────────────────────────────────────────
rm -f "$KEYS"; ago 700
dp --cooled
[ "$(lists)" -ge 2 ] && ok || bad "P3 a missing keys file wanted the lists read: $(cat "$CASE/calls" 2>/dev/null)"
[ -s "$KEYS" ] && ok || bad "P3 the pass did not rewrite the keys file"

# ── P4 ─────────────────────────────────────────────────────────────────────
newcase p4
dp --cooled
printf '[%s,%s]\n' "$(kid 11 10 1 2 CLOSED)" "$(kid 12 10 2 2 CLOSED)" > "$CASE/issues.json"
printf '[%s,%s]\n' "$(mpr 11 21)" "$(mpr 12 22)" > "$CASE/prs.json"
ago 700
dp --cooled
[ "$(lists)" = 0 ] && ok || bad "P4 before the wake a quiet run read the lists: $(cat "$CASE/calls")"
printf 'issue 11 0\n* * 1\n' > "$CASE/wake"
dp --cooled
[ "$(lists)" -ge 2 ] && ok || bad "P4 a wake on child 11 wanted the lists read: $(cat "$CASE/calls" 2>/dev/null)"
[ "$OUT" = 10 ] && ok || bad "P4 wanted parent 10 printed, got '$OUT'"
[ "$(cat "$CASE/closed" 2>/dev/null)" = 10 ] && ok || bad "P4 parent 10 was not closed"
plog | grep -q 'parent-close: pass on wake:issue:11' && ok || bad "P4 no reason line: $(plog)"
[ -e "$KEYS" ] && [ ! -s "$KEYS" ] && ok || bad "P4 a split with no open child left keys '$(cat "$KEYS" 2>/dev/null)'"

# ── P5 ─────────────────────────────────────────────────────────────────────
newcase p5
dp --cooled
ago 1800
dp --cooled
[ "$(lists)" -ge 2 ] && ok || bad "P5 the backstop wanted the lists read: $(cat "$CASE/calls" 2>/dev/null)"
plog | grep -q 'parent-close: pass on backstop' && ok || bad "P5 no backstop line: $(plog)"
# 1700, not 1799: this clock is the box's own (the exact edge is WB4's).
ago 1700
dp --cooled
[ "$(ncalls)" = 0 ] && ok || bad "P5b 1700 s with no wake made calls: $(cat "$CASE/calls")"

# ── P6 ─────────────────────────────────────────────────────────────────────
newcase p6
dp --cooled
printf 'issue 11 0\n* * 1\n' > "$CASE/wake"
ago 300
dp --cooled
[ "$(ncalls)" = 0 ] && ok || bad "P6 a wake inside the 600 s floor made calls: $(cat "$CASE/calls")"

# ── P7 ─────────────────────────────────────────────────────────────────────
newcase p7
mkdir -p "$CASE/bin"
ln -s "$DIR/bin/fleet-conf.sh" "$CASE/bin/fleet-conf.sh"
printf 'x-os    example-org/x-os    https://x.test  /api/board  3  local\n' > "$CASE/fleet.conf"
rm -f "$CASE/wake.calls"
P7MARK="$CASE/state/parent-close-x-os.last"
echo "$((NOW - 700))" > "$P7MARK"
( unset GH_ISSUES_REPO; HARNESS="$CASE" FLEET_CONF="$CASE/fleet.conf" "$T/bin/decompose-parent-close.sh" x-os --cooled >/dev/null 2>&1 )
[ "$(cat "$P7MARK")" != "$((NOW - 700))" ] && ok || bad "P7 an in-app board at +700 s did not run its pass"
[ ! -e "$CASE/wake.calls" ] && ok || bad "P7 an in-app board asked the wake feed: $(cat "$CASE/wake.calls")"
echo "$((NOW - 300))" > "$P7MARK"
( unset GH_ISSUES_REPO; HARNESS="$CASE" FLEET_CONF="$CASE/fleet.conf" "$T/bin/decompose-parent-close.sh" x-os --cooled >/dev/null 2>&1 )
[ "$(cat "$P7MARK")" = "$((NOW - 300))" ] && ok || bad "P7b an in-app board inside the cooldown ran"

# ── P8 ─────────────────────────────────────────────────────────────────────
newcase p8
printf '[%s,%s]\n' "$(kid 11 10 1 2 CLOSED)" "$(kid 12 10 2 2 CLOSED)" > "$CASE/issues.json"
printf '[%s,%s]\n' "$(mpr 11 21)" "$(mpr 12 22)" > "$CASE/prs.json"
: > "$CASE/patch-fail"
dp --cooled
plog | grep -q 'PARENT_CLOSE_FAILED #10' && ok || bad "P8 the close did not fail as staged: $(plog)"
grep -qx retry "$KEYS" 2>/dev/null && ok || bad "P8 a failed close wrote keys '$(cat "$KEYS" 2>/dev/null)', wanted retry"
rm -f "$CASE/patch-fail"
ago 700
dp --cooled
[ "$(lists)" -ge 2 ] && [ "$OUT" = 10 ] && ok || bad "P8 the retry at +700 s did not run and close 10 (out '$OUT')"
grep -qx retry "$KEYS" 2>/dev/null && bad "P8 the retry line survived a close that landed" || ok

# ── P9 ─────────────────────────────────────────────────────────────────────
newcase p9
dp --cooled
ago 60
dp
[ "$(lists)" -ge 2 ] && ok || bad "P9 a hand run was held: $(cat "$CASE/calls" 2>/dev/null)"
ago 700
WAKE_BACKSTOP=0 dp --cooled
[ "$(lists)" -ge 2 ] && ok || bad "P9b WAKE_BACKSTOP=0 at +700 s did not run: $(cat "$CASE/calls" 2>/dev/null)"

echo "decompose-parent-close-wake: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
