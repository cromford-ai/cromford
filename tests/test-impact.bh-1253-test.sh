#!/bin/bash
# tests/test-impact.bh-1253-test.sh — BH-1253: the four ways bin/test-impact.sh
# answered wrongly, and the one way the orphan ratchet counted a citation it
# should not have.
#
# All five were found reviewing #1212 and every one of them is invisible on a
# gawk desktop, which is why they sat: the fleet's awk is mawk (1.3.4), so is
# debian:trixie-slim's in bin/run-tests-in-docker.sh, and mawk is where four of
# the five bite.
#
#   1  mawk — `RV_[$1] = (($1 in RV_) ? …)` creates the array element for the
#      LVALUE before it evaluates the right side, so the very first row of a
#      suite's root-variable list starts the alternation with an empty branch
#      and every `map`/`audit` dies on "regular expression compile failed".
#      And with that patched, mawk's match() on TOK returns the UNROOTED
#      `fleet.conf` because TI_PREFIX_AWK listed it twice over.
#   2  source edges — `ti_source_edges` splits on `$`, so the unbraced
#      `. "$HARNESS/bin/lib/rb/$_m.sh"` tokenised to `HARNESS/bin/lib/rb/` and
#      resolved to nothing. Thirty source lines in bin/ reached no file.
#   3  a tree with no suites HUNG: `$(ls tests/*.sh …)` unquoted as awk's argv
#      is an empty argv, and awk with no file argument reads stdin.
#   4  the orphan ratchet counted a script as "named" when the only suite that
#      mentioned it did so on a `#` comment line.
#
# HOW IT DRIVES (D2): every case runs the real bin/test-impact.sh as a command,
# against the real repo or against a scratch tree built here. No function is
# sourced out of it and no assertion reads its source text (D3) — the answers
# are map rows, orphan lists, reason lines and exit codes.
#
# Self-contained: no network, no secrets, no $HARNESS, no clock read.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

TI="$DIR/bin/test-impact.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$TI" ] || { echo "FAIL: bin/test-impact.sh is missing or not executable"
                  echo "test-impact.bh-1253: 0 passed, 1 failed"; exit 1; }
command -v git >/dev/null || { echo "test-impact.bh-1253: git is required for this suite"; exit 2; }

sgit() { git -C "$1" -c user.email=t@example.com -c user.name=t "${@:2}"; }

# ── 1. mawk builds the same map as whatever awk is on PATH ─────────────────
# The mawk half runs only where mawk exists. On the Fly test host (gawk only)
# it prints one visible line and counts nothing — a skip that says what was not
# exercised is not the same as a pass.
MAWK=$(command -v mawk 2>/dev/null || true)
AWKSHIM=""
if [ -n "$MAWK" ]; then
  mkdir -p "$T/awkbin"
  ln -sf "$MAWK" "$T/awkbin/awk"
  AWKSHIM="$T/awkbin"
else
  echo "test-impact.bh-1253: SKIP: mawk not on PATH — the mawk cases were not exercised here"
fi

# 1a. the real repo's map builds under mawk, and is byte-identical to the one
# the box's own awk builds. A map that differs by awk implementation would make
# CI's selection depend on which image ran it.
"$TI" map --out "$T/awk-map.tsv" 2>"$T/awk-map.err"; RC=$?
if [ "$RC" -eq 0 ] && [ -s "$T/awk-map.tsv" ]; then ok
else bad "1a: map with the box's own awk came back rc=$RC / $(wc -l <"$T/awk-map.tsv" 2>/dev/null || echo 0) rows: $(head -3 "$T/awk-map.err" | tr '\n' ' ')"; fi

if [ -n "$AWKSHIM" ]; then
  PATH="$AWKSHIM:$PATH" "$TI" map --out "$T/mawk-map.tsv" 2>"$T/mawk-map.err"; RC=$?
  if [ "$RC" -eq 0 ] && [ -s "$T/mawk-map.tsv" ]; then ok
  else bad "1a: map under mawk came back rc=$RC: $(head -3 "$T/mawk-map.err" | tr '\n' ' ')"; fi
  if cmp -s "$T/awk-map.tsv" "$T/mawk-map.tsv"; then ok
  else bad "1a: the map under mawk differs from the map under the box's awk:
$(diff "$T/awk-map.tsv" "$T/mawk-map.tsv" 2>/dev/null | head -6)"; fi

  # 1b. and the corpus audit — the second RV_ site — prints nothing under mawk.
  # An audit that dies is an audit that reports no missing rows.
  AUD=$(PATH="$AWKSHIM:$PATH" "$TI" audit 2>"$T/mawk-audit.err"); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$AUD" ]; then ok
  else bad "1b: audit under mawk rc=$RC with $(grep -c . <<<"$AUD") row(s): $(head -3 <<<"$AUD" | tr '\n' ' ')"; fi
  if [ ! -s "$T/mawk-audit.err" ]; then ok
  else bad "1b: the audit wrote to stderr under mawk: $(head -2 "$T/mawk-audit.err" | tr '\n' ' ')"; fi
fi

# 1c. the `fleet.conf` row. mawk's match() picked the shorter, LATER alternative
# out of TI_PREFIX_AWK and handed back the unrooted token, which the extractor
# then dropped as a scratch path — so every suite naming "$DIR/fleet.conf" lost
# its row while the map still looked healthy.
C="$T/conf"
mkdir -p "$C/bin" "$C/tests"
printf 'boxa project-1\n' > "$C/fleet.conf"
printf '#!/bin/bash\necho x\n' > "$C/bin/x.sh"
cat > "$C/tests/conf-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
export FLEET_CONF="$DIR/fleet.conf"
grep -q . "$FLEET_CONF"
echo "conf: 1 passed, 0 failed"
SH
CONFROW=$(printf 'tests/conf-test.sh\tfleet.conf')
"$TI" --root "$C" map --out "$T/conf-awk.tsv" 2>/dev/null
if grep -qxF "$CONFROW" "$T/conf-awk.tsv" 2>/dev/null; then ok
else bad "1c: the rooted fleet.conf citation has no map row under the box's awk:
$(cat "$T/conf-awk.tsv" 2>/dev/null)"; fi
if [ -n "$AWKSHIM" ]; then
  PATH="$AWKSHIM:$PATH" "$TI" --root "$C" map --out "$T/conf-mawk.tsv" 2>/dev/null
  if grep -qxF "$CONFROW" "$T/conf-mawk.tsv" 2>/dev/null; then ok
  else bad "1c: the rooted fleet.conf citation has no map row under mawk:
$(cat "$T/conf-mawk.tsv" 2>/dev/null)"; fi
  if cmp -s "$T/conf-awk.tsv" "$T/conf-mawk.tsv"; then ok
  else bad "1c: the scratch map differs between mawk and the box's awk"; fi
fi

# ── 2. unbraced $VAR/ source edges ─────────────────────────────────────────
# `. "$HARNESS/bin/lib/alpha.sh"` is how thirty lines in bin/ source a library,
# and the map saw none of them: the split treats `$` as a separator, so the
# token was `HARNESS/bin/lib/alpha.sh`, which is not a path in this tree.
S="$T/src"
mkdir -p "$S/bin/lib/mod" "$S/tests"
printf 'alpha() { echo alpha; }\n' > "$S/bin/lib/alpha.sh"
printf 'one() { echo one; }\n' > "$S/bin/lib/mod/one.sh"
cat > "$S/bin/delta.sh" <<'SH'
#!/bin/bash
m=one
. "$HARNESS/bin/lib/alpha.sh"
. "$HARNESS/bin/lib/mod/$m.sh"
. "$SOMEWHERE/nowhere/other.sh"
alpha; one
SH
cat > "$S/tests/delta-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/delta.sh" >/dev/null
echo "delta: 1 passed, 0 failed"
SH
sgit "$S" init -q -b main >/dev/null 2>&1 || git -C "$S" init -q >/dev/null 2>&1
sgit "$S" add -A; sgit "$S" commit -qm base
SBASE=$(git -C "$S" rev-parse HEAD)

"$TI" --root "$S" map --out "$T/src-map.tsv" 2>"$T/src-map.err"
for ROW in "$(printf 'tests/delta-test.sh\tbin/lib/alpha.sh')" \
           "$(printf 'tests/delta-test.sh\tbin/lib/mod/')"; do
  if grep -qxF "$ROW" "$T/src-map.tsv" 2>/dev/null; then ok
  else bad "2: no map row '$(printf '%s' "$ROW" | tr '\t' ' ')' — an unbraced \$VAR/ source line reached nothing:
$(cat "$T/src-map.tsv" 2>/dev/null)"; fi
done

# Negative: the source line that names a path this tree does not hold must
# yield no row at all. Blanking the variable must not invent files.
SBOGUS=$(cut -f2 "$T/src-map.tsv" 2>/dev/null | LC_ALL=C sort -u | while IFS= read -r p; do
  [ "$p" = "*" ] && continue
  [ -e "$S/$p" ] || printf '%s\n' "$p"
done)
if [ -z "$SBOGUS" ]; then ok
else bad "2: the map names paths this tree does not hold: $(printf '%s' "$SBOGUS" | tr '\n' ' ')"; fi

# And the edge is load-bearing: a diff on either sourced file selects the suite
# that only ever names bin/delta.sh.
ssel() { # <path to touch> -> prints the selection, reason into $T/src-reason
  sgit "$S" reset -q --hard "$SBASE"
  echo '# touched' >> "$S/$1"
  sgit "$S" add -A; sgit "$S" commit -qm "touch $1"
  "$TI" --root "$S" select "$SBASE..HEAD" 2>"$T/src-reason"
}
for P in bin/lib/alpha.sh bin/lib/mod/one.sh; do
  GOT=$(ssel "$P")
  if grep -qxF tests/delta-test.sh <<<"$GOT" &&
     grep -q 'selected:' "$T/src-reason"; then ok
  else bad "2: a diff on $P did not SELECT tests/delta-test.sh (it reaches it only through the unbraced source line in bin/delta.sh): '$(printf '%s' "$GOT" | tr '\n' ' ')' / '$(cat "$T/src-reason")'"; fi
done

# ── 3. a tree with no suites refuses, and never blocks on stdin ────────────
# `awk -v … 'prog' $(ls tests/*.sh)` with an empty glob is `awk 'prog'`, which
# reads stdin. Under CI that is a closed pipe and looks like a fast failure;
# under a terminal, a cron lane or any caller that leaves stdin open it hangs
# until the job times out.
E="$T/empty-tree"
mkdir -p "$E/bin" "$E/tests"
printf '#!/bin/bash\necho hi\n' > "$E/bin/x.sh"
L="$T/lib-only-tree"
mkdir -p "$L/bin" "$L/tests/lib"
printf '#!/bin/bash\necho hi\n' > "$L/bin/x.sh"
printf 'helper() { :; }\n' > "$L/tests/lib/helper.sh"

no_suite_refuses() { # <label> <root> <cmd>
  local root="$2" cmd="$3" fifo="$T/fifo.$1" rc
  rm -f "$fifo"; mkfifo "$fifo"
  sleep 30 > "$fifo" &
  local holder=$!
  timeout 20 "$TI" --root "$root" "$cmd" > "$T/nos.$1.out" 2>"$T/nos.$1.err" < "$fifo"
  rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  rm -f "$fifo"
  if [ "$rc" -eq 2 ] && grep -qi 'no suites' "$T/nos.$1.err"; then ok
  elif [ "$rc" -eq 124 ]; then
    bad "3: '$cmd' on a tree with no suites HUNG on stdin (rc 124 under timeout 20), root $root"
  else
    bad "3: '$cmd' on a tree with no suites should be rc 2 naming 'no suites', got rc=$rc: $(head -2 "$T/nos.$1.err" | tr '\n' ' ')"
  fi
}
no_suite_refuses map   "$E" map
no_suite_refuses orph  "$E" orphans
no_suite_refuses audit "$E" audit
no_suite_refuses libmap "$L" map

# ── 4. comment citations do not count for the orphan ratchet ───────────────
# A suite that mentions a script in a `#` line is not a test of that script.
# Counting it made the ratchet report a hole as covered — which is the one
# direction a ratchet must never round.
O="$T/orepo"
mkdir -p "$O/bin" "$O/tests"
printf '#!/bin/bash\necho mapped\n' > "$O/bin/mapped.sh"
printf '#!/bin/bash\necho lonely\n' > "$O/bin/lonely.sh"
cat > "$O/tests/mapped-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/mapped.sh" >/dev/null # the trailing comment names nothing new
echo "mapped: 1 passed, 0 failed"
SH
cat > "$O/tests/comment-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
# see $DIR/bin/lonely.sh for the real thing
echo "comment: 1 passed, 0 failed"
SH
git -C "$O" init -q -b main >/dev/null 2>&1 || git -C "$O" init -q
sgit "$O" add -A; sgit "$O" commit -qm base
OBASE=$(git -C "$O" rev-parse HEAD)
sgit "$O" checkout -q -b work
owork() { sgit "$O" reset -q --hard "$OBASE" && sgit "$O" clean -qfd; }

# 4a. the comment-only citation leaves the script an orphan; the trailing-comment
# citation does not.
OLIST=$("$TI" --root "$O" orphans 2>"$T/o.err")
if [ "$OLIST" = "bin/lonely.sh" ]; then ok
else bad "4a: orphans should be exactly bin/lonely.sh (its only mention is a # line), got '$(printf '%s' "$OLIST" | tr '\n' ' ')' $(head -2 "$T/o.err" | tr '\n' ' ')"; fi

# 4c. and the MAP is unchanged: a comment citation still selects the suite. The
# ticket's own "safe for selection: one extra suite runs" has to stay true.
"$TI" --root "$O" map --out "$T/o-map.tsv" 2>/dev/null
if grep -qxF "$(printf 'tests/comment-test.sh\tbin/lonely.sh')" "$T/o-map.tsv" 2>/dev/null; then ok
else bad "4c: the comment citation was dropped from the MAP too — selection narrowed, which this ticket must not do:
$(cat "$T/o-map.tsv" 2>/dev/null)"; fi
echo '# touched' >> "$O/bin/lonely.sh"
sgit "$O" add -A; sgit "$O" commit -qm "touch lonely"
GOT=$("$TI" --root "$O" select "$OBASE..HEAD" 2>"$T/o-reason")
if grep -qxF tests/comment-test.sh <<<"$GOT"; then ok
else bad "4c: a diff on bin/lonely.sh no longer selects the suite that names it in a comment: '$(printf '%s' "$GOT" | tr '\n' ' ')' / '$(cat "$T/o-reason")'"; fi
owork

# 4b. --check: a new script cited ONLY in a comment is refused by name, the
# base's own comment-only orphan is not dragged into the refusal, and making the
# citation real clears it.
ocheck() { TI_BASE="$OBASE" "$TI" --root "$O" orphans --check 2>&1; }
printf '#!/bin/bash\necho stray\n' > "$O/bin/stray.sh"
cat > "$O/tests/stray-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
# $DIR/bin/stray.sh is the thing this will test one day
echo "stray: 1 passed, 0 failed"
SH
sgit "$O" add -A; sgit "$O" commit -qm "a script cited only in a comment"
GOUT=$(ocheck); GRC=$?
if [ "$GRC" -eq 1 ] && grep -qF 'bin/stray.sh' <<<"$GOUT"; then ok
else bad "4b: a script whose only citation is a # line must be refused by name (rc=$GRC): $GOUT"; fi
if ! grep -qF 'bin/lonely.sh' <<<"$(printf '%s' "$GOUT")"; then ok
else bad "4b: the refusal names bin/lonely.sh, an orphan on BOTH sides — only what this diff adds is new: $GOUT"; fi

owork
printf '#!/bin/bash\necho stray\n' > "$O/bin/stray.sh"
cat > "$O/tests/stray-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/stray.sh" >/dev/null
echo "stray: 1 passed, 0 failed"
SH
sgit "$O" add -A; sgit "$O" commit -qm "a real citation for the stray script"
GOUT=$(ocheck); GRC=$?
if [ "$GRC" -eq 0 ] && grep -qF 'no new orphans' <<<"$GOUT"; then ok
else bad "4b: a real (non-comment) citation must clear the refusal (rc=$GRC): $GOUT"; fi
owork

# 4d. the real repo, without naming a script this suite would then be citing.
# The map built for SELECTION counts comment citations; the one built for the
# RATCHET does not, so the strict list is a strict superset — and every script
# in the difference has a `#`-led citation, which is exactly why it moved.
STRICT="$T/orph-strict"; LOOSE="$T/orph-loose"
"$TI" orphans 2>"$T/strict.err" | LC_ALL=C sort > "$STRICT"
"$TI" orphans --map "$T/awk-map.tsv" 2>"$T/loose.err" | LC_ALL=C sort > "$LOOSE"
if [ -s "$STRICT" ] && [ -s "$LOOSE" ]; then ok
else bad "4d: could not compute the real repo's orphan lists (strict $(wc -l <"$STRICT") / loose $(wc -l <"$LOOSE")): $(head -2 "$T/strict.err" "$T/loose.err" | tr '\n' ' ')"; fi
LOST=$(comm -13 "$STRICT" "$LOOSE")
if [ -z "$LOST" ]; then ok
else bad "4d: the ratchet's list DROPPED $(grep -c . <<<"$LOST") script(s) the map-built list holds — the strict rule may only ADD orphans (first 5): $(head -5 <<<"$LOST" | tr '\n' ' ')"; fi
ONLYCOMMENT=$(comm -13 "$LOOSE" "$STRICT")
# A hard failure, not a skip: the two lists being identical over a 450-script
# corpus means the strict rule moved nothing, which is what this ticket exists
# to change and what removing the `#`-led skip looks like. It does not pin a
# script BY NAME, so main is free to fix any of them; it only reds if the
# corpus ever runs out of comment-only citations entirely, and at that point
# this half has nothing left to prove and should be deleted with a reason.
if [ -n "$ONLYCOMMENT" ]; then
  ok
  MISCITED=""
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    ( cd "$DIR" && grep -rnF -- "$s" tests/*.sh tests/mc/*.sh 2>/dev/null ) |
      sed 's/^[^:]*:[0-9]*://' | grep -q '^[[:space:]]*#' || MISCITED="$MISCITED $s"
  done <<EOF
$ONLYCOMMENT
EOF
  if [ -z "$MISCITED" ]; then ok
  else bad "4d: these scripts became orphans under the strict rule but no suite cites them on a # line, so the rule is not what moved them:$MISCITED"; fi
else
  bad "4d: the ratchet's orphan list is identical to the one built from the selection map ($(grep -c . "$STRICT") scripts) — no script in this corpus is cited only on a # line, so the strict rule moved nothing"
fi

echo "test-impact.bh-1253: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
