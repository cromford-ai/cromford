#!/bin/bash
# tests/br-fresh-first.bh-9369-test.sh — BH-9369 fix 5: a live PR parked in the
# last BR_FRESH_PARK_MIN (1440) minutes is offered before the OVERDUE rows when
# one of them is BR_STALE_OVERDUE_DAYS (7) days old.
#
# THE BUG (hub, 2026-11-09). br_overdue_first offers every overdue row oldest
# first. With 200 week-old parks on the list, a RED_TWICE park 30 min old sat
# behind all of them, and BR_PER_TICK=50 never reached it: the fresh red PR
# waited hours for its first rung.
#
#   F1  1 fresh row (30 min) + 200 rows 8 days overdue, BR_PER_TICK=50: the
#       fresh row is the first row after the hot prefix (function), and the
#       driver tick dispatches it first
#   F2  23 h is lifted; 25 h, parked `-`, a future epoch and a url `-` are not
#   F3  only 2-day overdue rows: the output is today's order, byte for byte
#   F4  BR_FRESH_PARK_MIN=0 or BR_STALE_OVERDUE_DAYS=0: today's order; a
#       non-number knob falls back to the default with one line
#   F5  a hotfix row stays first
#
# WHAT IS DRIVEN. F1's tick runs the real bin/blocked-resolver.sh end to end
# against a scratch $HARNESS (the rig of tests/blocked-resolver-overdue.bh-7555-test.sh).
# F1-F5 also call br_overdue_first directly, sourced from the fragment.
# No vendor is called (BH-7563): gh is a local stub, GH_TOKEN is empty.
# Run from anywhere: tests/br-fresh-first.bh-9369-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
FRAG="$DIR/bin/blocked-resolver.d/bh-7555-overdue-first.sh"
[ -r "$FRAG" ] || { echo "FAIL: bin/blocked-resolver.d/bh-7555-overdue-first.sh is missing"; exit 1; }

# OF [env...] — br_overdue_first over stdin in a clean shell, `say` to $T/say.txt.
OF() { ( env "$@" bash -c '
    set -uo pipefail
    say() { printf "%s\n" "$*" >> "'"$T"'/say.txt"; }
    [ -n "${OF_RANK:-}" ] && eval "$OF_RANK"
    . "'"$FRAG"'" || exit 9
    br_overdue_first "'"$NOW"'"' ); }
# R <rkey> <parked> [url] [rec] — one 8-column candidate row; the url is a live
# PR url unless given.
R() { printf 'conductor\tp1\t%s\tred-twice\t%s\t%s\t-\t%s\n' "$1" "${3:-https://github.com/o/p1/pull/${1//[!0-9]/}9}" "${4:--}" "$2"; }
KEYS() { cut -f3 | tr '\n' ' '; }
STALE() { local i; for i in $(seq 1 "$1"); do R "s$i" "$((NOW - 8 * 86400 - i))"; done; }

# ============================================================================
# F1 (function). THE BUG. 200 stale rows, then the fresh one (the cost order
# put it last). Fixed: the fresh row is row 1.
# ============================================================================
: > "$T/say.txt"
IN=$( STALE 200; R fresh "$((NOW - 1800))" )
OUT=$(printf '%s\n' "$IN" | OF)
[ "$(sed -n 1p <<<"$OUT" | cut -f3)" = fresh ] && ok \
  || bad "F1: THE BUG: the 30-min park must be the first row (row 1: $(sed -n 1p <<<"$OUT" | cut -f3); row of fresh: $(grep -n $'\tfresh\t' <<<"$OUT" | cut -d: -f1))"
[ "$(grep -c . <<<"$OUT")" = 201 ] && ok || bad "F1: rows in = rows out (201)"
[ "$(sed -n 2p <<<"$OUT" | cut -f3)" = s200 ] && ok \
  || bad "F1: after the fresh row, the overdue rows stay oldest first (row 2: $(sed -n 2p <<<"$OUT" | cut -f3))"
grep -q '^fresh-first: 1 live park(s) parked < 1440 min offered before 200 overdue row(s) older than 7 days$' "$T/say.txt" && ok \
  || bad "F1: one fresh-first line ($(grep fresh-first "$T/say.txt"))"

# ============================================================================
# F2. 23 h is lifted (it is overdue itself); 25 h, `-`, a future epoch and a
#     url `-` are not.
# ============================================================================
: > "$T/say.txt"
IN=$( R s1 "$((NOW - 8 * 86400))"; R h25 "$((NOW - 25 * 3600))"; R h23 "$((NOW - 23 * 3600))"
      R dash "-"; R fut "$((NOW + 600))"; R nourl "$((NOW - 1800))" "-"; R m30 "$((NOW - 1800))" )
OUT=$(printf '%s\n' "$IN" | OF)
[ "$(printf '%s\n' "$OUT" | KEYS)" = "h23 m30 s1 h25 dash fut nourl " ] && ok \
  || bad "F2: the 23 h and 30 min rows first, then the overdue rows, then the rest (got '$(printf '%s\n' "$OUT" | KEYS)')"

# ============================================================================
# F3. No stale row: only 2-day overdue rows. Today's order, byte for byte.
# ============================================================================
: > "$T/say.txt"
IN=$( R d2a "$((NOW - 2 * 86400))"; R m30 "$((NOW - 1800))"; R d2b "$((NOW - 2 * 86400 - 60))" )
OUT=$(printf '%s\n' "$IN" | OF)
BASE=$(printf '%s\n' "$IN" | OF BR_FRESH_PARK_MIN=0)
[ "$OUT" = "$BASE" ] && [ "$(printf '%s\n' "$OUT" | KEYS)" = "d2b d2a m30 " ] && ok \
  || bad "F3: with no stale row the order is today's (got '$(printf '%s\n' "$OUT" | KEYS)')"
grep -q fresh-first "$T/say.txt" && bad "F3: no fresh-first line with no stale row" || ok

# ============================================================================
# F4. A knob at 0 turns the step off; a non-number is the default, said once.
# ============================================================================
IN=$( STALE 3; R fresh "$((NOW - 1800))" )
for KN in BR_FRESH_PARK_MIN=0 BR_STALE_OVERDUE_DAYS=0; do
  : > "$T/say.txt"
  OUT=$(printf '%s\n' "$IN" | OF "$KN")
  [ "$(printf '%s\n' "$OUT" | KEYS)" = "s3 s2 s1 fresh " ] && ok \
    || bad "F4: $KN keeps the oldest-first order (got '$(printf '%s\n' "$OUT" | KEYS)')"
done
: > "$T/say.txt"
OUT=$(printf '%s\n' "$IN" | OF BR_FRESH_PARK_MIN=abc)
[ "$(printf '%s\n' "$OUT" | KEYS)" = "fresh s3 s2 s1 " ] && ok \
  || bad "F4: a non-number BR_FRESH_PARK_MIN is the default 1440 (got '$(printf '%s\n' "$OUT" | KEYS)')"
[ "$(grep -c "BR_FRESH_PARK_MIN is 'abc', not a number — the fallback 1440 is used" "$T/say.txt")" = 1 ] && ok \
  || bad "F4: one line names the bad knob ($(cat "$T/say.txt"))"

: > "$T/say.txt"
OUT=$(printf '%s\n' "$IN" | OF BR_STALE_OVERDUE_DAYS=x7)
[ "$(printf '%s\n' "$OUT" | KEYS)" = "fresh s3 s2 s1 " ] && ok \
  || bad "F4: a non-number BR_STALE_OVERDUE_DAYS is the default 7 (got '$(printf '%s\n' "$OUT" | KEYS)')"
[ "$(grep -c "BR_STALE_OVERDUE_DAYS is 'x7', not a number — the fallback 7 is used" "$T/say.txt")" = 1 ] && ok \
  || bad "F4: one line names the bad BR_STALE_OVERDUE_DAYS ($(cat "$T/say.txt"))"

# ============================================================================
# F5. A hotfix row stays first, ahead of the fresh row.
# ============================================================================
RANKFN='priority_rank_meta() { case "$1" in hotrec/*) echo 0 ;; *) echo 2 ;; esac; }'
IN=$( R hot "$((NOW - 600))" "" hotrec; STALE 2; R fresh "$((NOW - 1800))" )
OUT=$(printf '%s\n' "$IN" | OF OF_RANK="$RANKFN")
[ "$(printf '%s\n' "$OUT" | KEYS)" = "hot fresh s2 s1 " ] && ok \
  || bad "F5: the hotfix row first, then the fresh row (got '$(printf '%s\n' "$OUT" | KEYS)')"

# ============================================================================
# F1 (driver). 200 conductor parks 8 days old and one RED_TWICE park 30 min
# old, BR_PER_TICK=50. The fresh park is the first rung of the tick.
# BR_TICK_MAX_SECS=1 ends the tick after the first row it looks at (the wall
# bound always lets one row through), so the suite does not pay for 50 rungs:
# the first rung is the whole question.
# ============================================================================
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" 2>/dev/null || true
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
{ printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh agent-call.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-p1"
ROWS="$H/state/merge-conductor/pr-state.tsv"
LOGF="$H/logs/blocked-resolver.log"
CONFLICT="conflict-unresolvable: CONFLICT (content): Merge conflict in src/a.ts"
: > "$ROWS"
for N in $(seq 1001 1200); do
  printf 'o/p1#%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\thttps://github.com/o/p1/pull/%s\n' \
    "$N" "$((NOW - 8 * 86400 - N))" "$CONFLICT" "$N" >> "$ROWS"
done
printf 'o/p1#77\tRED_TWICE\t%s\tabc123\tabc123\t-\t%s\thttps://github.com/o/p1/pull/77\n' \
  "$((NOW - 1800))" "red-twice: CI red after one rerun" >> "$ROWS"
( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH="$T/fakebin/br-ssh" \
  BR_PER_TICK=50 BR_PER_TICK_P1=50 BR_TICK_MAX_SECS=1 bash "$H/bin/blocked-resolver.sh" p1 >>"$T/run.log" 2>&1 ) || true
FIRST=$(grep -oE 'p1/o-p1-[0-9]+ \[[^]]*\] -> ' "$LOGF" | head -1 | sed -E 's#p1/o-p1-([0-9]+) .*#\1#')
[ "$FIRST" = 77 ] && ok \
  || bad "F1 (driver): THE BUG: the fresh RED_TWICE park must be the first rung of the tick (first: '${FIRST:-none}'; #77 lines: $(grep -c 'o-p1-77 ' "$LOGF"); tick: $(grep 'tick: candidates=' "$LOGF" | tail -1))"
grep -q 'fresh-first: 1 live park(s)' "$LOGF" && ok || bad "F1 (driver): the tick says fresh-first once"

echo "br-fresh-first.bh-9369: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
