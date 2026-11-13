#!/bin/bash
# tests/gh-ledger-report.bh-9417-test.sh — BH-9455 (BH-9417.4): the
# `--per-merged-pr` flag of bin/gh-ledger-report.sh.
#
# WHY. BH-9417's observable outcome is "GitHub requests per merged PR". The
# report already sums the counted requests of a window; this flag divides that
# sum by the PRs merged in the same window over every registry repo, and it
# prints NO number when one repo's merged count is unknown: a ratio over a
# partial count is a wrong number, not a rough one.
#
# What is pinned (fixture ledger in the writer's 14-column shape,
# GH_LEDGER_REPORT_NOW fixed, a `gh` stub on PATH that records any call):
#   1. 3000 counted / (2 + 3) merged => per_merged_pr=600 counted=3000 merged=5;
#   2. 0 merged => per_merged_pr=n/a (0 merged);
#   3. one repo unreadable => per_merged_pr=unknown (<repo> unreadable), no number;
#   4. a missing seam file => per_merged_pr=unknown (merged file unreadable);
#   5. flag absent => byte-identical to main's report (pinned golden text);
#   6. live path (no seam): stub gh_rest / gh_repo_use_token / fleet-conf in a
#      scratch HARNESS; one read per repo, rc 75 or incomplete_results => unknown;
#   7. an empty window with the flag => counted=0;
#   8. half-up rounding: 7 / 2 => 4.
# Every case: 0 `gh` calls.
#
# Run from anywhere: bash tests/gh-ledger-report.bh-9417-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
REPORT="$DIR/bin/gh-ledger-report.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -x "$REPORT" ] || { echo "FAIL: $REPORT missing or not executable"; exit 1; }

unset GH_TOKEN GITHUB_TOKEN GH_LEDGER_REPORT_MERGED_FILE HARNESS H
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh-calls.txt"\nexit 1\n' "$T" > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

NOW=$(date -u -d '2026-10-04T19:30:00Z' +%s)   # determinism: ok pinned
export GH_LEDGER_REPORT_NOW="$NOW"

# row <dir> <ts> <caller> <counted> [status] — one writer-shaped line
row() {
  local h=${2%%:*}
  printf '%s\t%s\tcromford\tGET\trepos/F/R/pulls/N\t%s\t%s\t4000\t1791147755\tapp-1\tcore\trest\t100\t6600\n' \
    "$2" "$3" "${5:-200}" "$4" >> "$1/$h.tsv"
}
run() { OUT=$("$REPORT" "$@" 2>&1); RC=$?; }

# The ledger: 3000 counted rows, plus a 304 (counted 0) and a cache row that
# the TOTAL already excludes.
D1="$T/l1"; mkdir -p "$D1"
for i in $(seq 1 3000); do
  printf '2026-10-04T19:10:00Z\tmerge-conductor.sh\tcromford\tGET\trepos/F/R/pulls/N\t200\t1\t4000\t1791147755\tapp-1\tcore\trest\t100\t6600\n'
done > "$D1/2026-10-04T19.tsv"
row "$D1" 2026-10-04T19:11:00Z stuck-work.sh 0 304
row "$D1" 2026-10-04T19:12:00Z stuck-work.sh 1 cache

MF="$T/merged.tsv"

# ---- 1. 3000 / 5 => 600 -----------------------------------------------------
printf 'A/x\t2\nB/y\t3\n' > "$MF"
GH_LEDGER_REPORT_MERGED_FILE="$MF" run --last 1h --dir "$D1" --per-merged-pr
[ "$RC" = 0 ] && ok || bad "1: rc $RC: $OUT"
grep -qx 'per_merged_pr=600 counted=3000 merged=5' <<<"$OUT" && ok || bad "1: expected per_merged_pr=600 counted=3000 merged=5, got: $(tail -2 <<<"$OUT")"
[ "$(grep -c '^per_merged_pr=' <<<"$OUT")" = 1 ] && ok || bad "1: exactly one per_merged_pr line, got: $OUT"
[ "$(tail -1 <<<"$OUT" | cut -c1-14)" = "per_merged_pr=" ] && ok || bad "1: the per_merged_pr line comes last, got: $(tail -1 <<<"$OUT")"

# ---- 2. 0 merged => n/a ------------------------------------------------------
printf 'A/x\t0\nB/y\t0\n' > "$MF"
GH_LEDGER_REPORT_MERGED_FILE="$MF" run --last 1h --dir "$D1" --per-merged-pr
[ "$RC" = 0 ] && ok || bad "2: rc $RC: $OUT"
grep -qx 'per_merged_pr=n/a (0 merged) counted=3000 merged=0' <<<"$OUT" && ok || bad "2: expected n/a (0 merged), got: $(tail -1 <<<"$OUT")"

# ---- 3. one repo unreadable => unknown, no number ----------------------------
printf 'A/x\t2\nB/y\tunreadable\n' > "$MF"
GH_LEDGER_REPORT_MERGED_FILE="$MF" run --last 1h --dir "$D1" --per-merged-pr
[ "$RC" = 0 ] && ok || bad "3: rc $RC: $OUT"
grep -qx 'per_merged_pr=unknown (B/y unreadable)' <<<"$OUT" && ok || bad "3: expected unknown (B/y unreadable), got: $(tail -1 <<<"$OUT")"
grep -q '^per_merged_pr=[0-9]' <<<"$OUT" && bad "3: a number over a partial count: $OUT" || ok

# ---- 4. a missing seam file => unknown ---------------------------------------
GH_LEDGER_REPORT_MERGED_FILE="$T/no-such-file.tsv" run --last 1h --dir "$D1" --per-merged-pr
[ "$RC" = 0 ] && ok || bad "4: rc $RC: $OUT"
grep -qx 'per_merged_pr=unknown (merged file unreadable)' <<<"$OUT" && ok || bad "4: expected unknown (merged file unreadable), got: $(tail -1 <<<"$OUT")"

# ---- 5. flag absent => byte-identical to the report before BH-9455 ----------
# Golden outputs captured from main's report (9dc520de2) on this exact fixture,
# with the scratch path written as @T@. A pinned text, not a git read: the test
# must not depend on a moving ref (build discipline D60).
golden() {
  case "$1" in
    l1-1h) printf '%s\n' \
      'gh-ledger-report: @T@/l1 window 2026-10-04T18:30:00Z..2026-10-04T19:30:00Z (1h) — 1 hour file(s)' \
      'TOTAL  calls=3001  counted=3000  uncounted=1  per_hour=3001' \
      'RANK   CALLS  COUNTED  UNCOUNTED  CALLER                          ENDPOINT' \
      '   1    3000     3000          0  merge-conductor.sh              GET repos/F/R/pulls/N' \
      '   2       1        0          1  stuck-work.sh                   GET repos/F/R/pulls/N' 'rc=0' ;;
    l1-1m) printf '%s\n' \
      'gh-ledger-report: @T@/l1 window 2026-10-04T19:29:00Z..2026-10-04T19:30:00Z (1m) — 1 hour file(s)' \
      'no ledger rows in window' 'rc=0' ;;
    empty) printf '%s\n' \
      'gh-ledger-report: @T@/l5-empty window 2026-10-04T18:30:00Z..2026-10-04T19:30:00Z (1h) — 0 hour file(s)' \
      'no ledger rows in window' 'rc=0' ;;
  esac
}
mkdir -p "$T/l5-empty"
printf 'A/x\t2\nB/y\t3\n' > "$MF"
for c in "l1-1h:--last 1h --dir $D1" "l1-1m:--last 1m --dir $D1" "empty:--last 1h --dir $T/l5-empty"; do
  # shellcheck disable=SC2086
  new=$(GH_LEDGER_REPORT_MERGED_FILE="$MF" "$REPORT" ${c#*:} 2>&1; echo "rc=$?")
  new=${new//$T/@T@}
  [ "$new" = "$(golden "${c%%:*}")" ] && ok || bad "5: flag absent must be byte-identical to main for [${c#*:}]; diff: $(diff <(golden "${c%%:*}") <(printf '%s\n' "$new"))"
done
RC=0; "$REPORT" --bogus >/dev/null 2>&1 || RC=$?
[ "$RC" = 2 ] && ok || bad "5: a bad argument still exits 2, got $RC"

# ---- 6. live path: one gh_rest read per registry repo ------------------------
# A scratch HARNESS whose bin/ holds stubs for fleet-conf.sh, lib/gh-rest.sh and
# lib/gh-repo-token.sh. The stub gh_rest answers from $T/answers/<owner>_<repo>
# (body; a first line `rc=<n>` sets its exit code) and logs every path.
LH="$T/lh"; mkdir -p "$LH/bin/lib" "$T/answers"
cat > "$LH/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --projects) printf 'alpha\nbeta\ngamma\nlocal-only\n' ;;
  alpha) [ "$2" = repo ] && echo Org/alpha-os ;;
  beta)  [ "$2" = repo ] && echo Org/beta-os ;;
  gamma) [ "$2" = repo ] && echo Org/alpha-os ;;
  local-only) [ "$2" = repo ] && echo - ;;
esac
exit 0
SH
chmod +x "$LH/bin/fleet-conf.sh"
cat > "$LH/bin/lib/gh-repo-token.sh" <<SH
gh_repo_use_token() { printf '%s\n' "\$1" >> "$T/use-token.log"; [ "\$1" != Org/hidden ]; }
SH
cat > "$LH/bin/lib/gh-rest.sh" <<SH
gh_rest() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/rest.log"
  local r=\${2#*repo:}; r=\${r%%+*}; local f="$T/answers/\${r/\//_}"
  [ -f "\$f" ] || return 75
  local first; first=\$(head -1 "\$f")
  case "\$first" in rc=*) return "\${first#rc=}" ;; esac
  cat "\$f"; return 0
}
SH
answer() { printf '%s\n' "$2" > "$T/answers/${1/\//_}"; }
live() { rm -f "$T/rest.log" "$T/use-token.log"; OUT=$(HARNESS="$LH" "$REPORT" --last 1h --dir "$D1" --per-merged-pr 2>&1); RC=$?; }

answer Org/alpha-os '{"total_count":2,"incomplete_results":false}'
answer Org/beta-os  '{"total_count":4,"incomplete_results":false}'
live
[ "$RC" = 0 ] && ok || bad "6a: rc $RC: $OUT"
grep -qx 'per_merged_pr=500 counted=3000 merged=6' <<<"$OUT" && ok || bad "6a: expected per_merged_pr=500 counted=3000 merged=6, got: $(tail -1 <<<"$OUT")"
[ "$(grep -c . "$T/rest.log" 2>/dev/null)" = 2 ] && ok || bad "6a: one read per DISTINCT registry repo (2), got: $(cat "$T/rest.log" 2>/dev/null)"
grep -q 'GET search/issues?q=repo:Org/alpha-os+is:pr+is:merged+merged:2026-10-04T18:30:00Z..2026-10-04T19:30:00Z&per_page=1' "$T/rest.log" 2>/dev/null \
  && ok || bad "6a: the search read names the repo and the exact window, got: $(cat "$T/rest.log" 2>/dev/null)"
[ "$(grep -c . "$T/use-token.log" 2>/dev/null)" = 2 ] && ok || bad "6a: a token is armed per repo, got: $(cat "$T/use-token.log" 2>/dev/null)"

answer Org/beta-os 'rc=75'
live
[ "$RC" = 0 ] && ok || bad "6b: rc $RC: $OUT"
grep -qx 'per_merged_pr=unknown (Org/beta-os unreadable)' <<<"$OUT" && ok || bad "6b: rc 75 => unknown (Org/beta-os unreadable), got: $(tail -1 <<<"$OUT")"

answer Org/beta-os '{"total_count":4,"incomplete_results":true}'
live
grep -qx 'per_merged_pr=unknown (Org/beta-os unreadable)' <<<"$OUT" && ok || bad "6c: incomplete_results => unknown, got: $(tail -1 <<<"$OUT")"

answer Org/beta-os '{"message":"Validation Failed"}'
live
grep -qx 'per_merged_pr=unknown (Org/beta-os unreadable)' <<<"$OUT" && ok || bad "6d: no numeric total_count => unknown, got: $(tail -1 <<<"$OUT")"

answer Org/alpha-os 'rc=44'
answer Org/beta-os '{"total_count":4,"incomplete_results":false}'
live
grep -qx 'per_merged_pr=unknown (Org/alpha-os unreadable)' <<<"$OUT" && ok || bad "6e: a 404 is unreadable, never 0, got: $(tail -1 <<<"$OUT")"
[ "$(grep -c . "$T/rest.log" 2>/dev/null)" = 1 ] && ok || bad "6e: stop at the first unreadable repo, got: $(cat "$T/rest.log" 2>/dev/null)"

# A registry that cannot be read => unknown.
cat > "$LH/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
exit 1
SH
live
grep -qx 'per_merged_pr=unknown (registry unreadable)' <<<"$OUT" && ok || bad "6f: a failed --projects => unknown (registry unreadable), got: $(tail -1 <<<"$OUT")"
[ -s "$T/rest.log" ] && bad "6f: no read without a registry, got: $(cat "$T/rest.log")" || ok

# ---- 7. an empty window with the flag ----------------------------------------
D7="$T/l7"; mkdir -p "$D7"
printf 'A/x\t2\nB/y\t3\n' > "$MF"
GH_LEDGER_REPORT_MERGED_FILE="$MF" run --last 1h --dir "$D7" --per-merged-pr
[ "$RC" = 0 ] && ok || bad "7: rc $RC: $OUT"
[ "$(sed -n 2p <<<"$OUT")" = "no ledger rows in window" ] && ok || bad "7: the empty-window line stays, got: $OUT"
grep -qx 'per_merged_pr=0 counted=0 merged=5' <<<"$OUT" && ok || bad "7: expected per_merged_pr=0 counted=0 merged=5, got: $(tail -1 <<<"$OUT")"

# ---- 8. half-up rounding: 7 / 2 => 4 -----------------------------------------
D8="$T/l8"; mkdir -p "$D8"
for i in 1 2 3 4 5 6 7; do row "$D8" 2026-10-04T19:20:00Z a.sh 1; done
printf 'A/x\t2\n' > "$MF"
GH_LEDGER_REPORT_MERGED_FILE="$MF" run --last 1h --dir "$D8" --per-merged-pr
grep -qx 'per_merged_pr=4 counted=7 merged=2' <<<"$OUT" && ok || bad "8: 7/2 rounds half up to 4, got: $(tail -1 <<<"$OUT")"

# ---- usage names the flag ----------------------------------------------------
HELP=$("$REPORT" --help 2>&1)
grep -q -- '--per-merged-pr' <<<"$HELP" && ok || bad "usage: --help names --per-merged-pr"

# ---- 0 GitHub calls in every case ---------------------------------------------
[ -s "$T/gh-calls.txt" ] && bad "gh was called: $(cat "$T/gh-calls.txt")" || ok

echo "gh-ledger-report.bh-9417: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
