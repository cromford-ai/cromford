#!/bin/bash
# tests/tracker-direct-calls-ratchet.bh-7919-test.sh — BH-7919: no NEW script
# talks to a tracker directly. A lane that reads fleet.conf column 4 itself, or
# calls the GitHub issues API or a board's /tickets route by hand, decides
# "which tracker" on its own, and that is how a Linear project got `Closes #12`.
# The seam is bin/lib/tracker.sh (tracker_kind, tracker_context,
# trk_gh_issue_number) and the adapters under bin/lib/tracker/.
#
# THE SCAN. Every file under bin/ that is `*.sh` or has a bash shebang, with
# comment lines dropped (first non-blank character `#`), is a DIRECT CALLER when
# a line matches any of:
#   board_prefix                                (fleet.conf column 4, as a word)
#   gh_rest | gh api | gh-rest-shim  with  /issues
#   gh issue
#   curl  with  /tickets  or  /boards
# bin/lib/tracker.sh and bin/lib/tracker/*.sh are the seam and never count.
#
# THE ALLOWLIST tests/fixtures/tracker-direct-allowlist.txt is one repo-relative
# path per line, sorted, unique; `#` lines and blank lines are comments. It was
# seeded from this scan on the BH-7919 head: it is the map of today's direct
# callers. A later wave that moves a file onto the seam removes its line.
#   pass  every scanned file is on the list
#   fail  a scanned file that is not on the list (path and line printed)
#   NOTE  a listed file with no direct call left: printed, never a failure,
#         so an unrelated refactor does not have to edit the shared list
# The ratchet is per FILE: a new direct call in a file already on the list
# passes. That is the price of a list a reader can keep.
#
#   R1  the scan of this checkout is a subset of the allowlist
#   R2  the allowlist is sorted and unique, and comments parse
#   R3  a scratch copy with a new bin/new-lane.sh that reads board_prefix fails
#       and names it; the same call added to a listed file still passes
#   R4  the same strings on a `#` line do not match
#   R5  bin/lib/tracker/board.sh and bin/lib/tracker.sh are never reported
#   R6  a listed file with no direct call left prints the NOTE and passes
#   R7  the must-match and must-not-match shapes of each pattern
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
ALLOW="$SRC/tests/fixtures/tracker-direct-allowlist.txt"

# tdc_scan <tree> — `<repo-relative path>\t<line>` for every direct call under
# <tree>/bin, sorted.
tdc_scan() {
  local tree="$1" f rel
  while IFS= read -r f; do
    rel="${f#"$tree"/}"
    case "$rel" in bin/lib/tracker.sh|bin/lib/tracker/*.sh) continue ;; esac
    case "$rel" in
      *.sh) ;;
      *) head -1 "$f" 2>/dev/null | grep -qE '^#!.*\bbash\b' || continue ;;
    esac
    awk -v rel="$rel" '
      /^[[:space:]]*#/ { next }
      /(^|[^A-Za-z0-9_])board_prefix([^A-Za-z0-9_]|$)/ ||
      (/gh_rest|gh api|gh-rest-shim/ && /\/issues/) ||
      /(^|[^A-Za-z0-9_-])gh issue([^A-Za-z0-9_]|$)/ ||
      (/curl/ && (/\/tickets/ || /\/boards/)) { print rel "\t" $0 }
    ' "$f" 2>/dev/null
  done < <(find "$tree/bin" -type f 2>/dev/null | LC_ALL=C sort)
}

# tdc_list <allowlist> — its paths, comments and blank lines dropped.
tdc_list() { sed -e 's/[[:space:]]*$//' "$1" | grep -vE '^[[:space:]]*(#|$)'; }

# tdc_check <tree> <allowlist> — rc 0 when every scanned file is listed.
# Prints `ratchet: NEW <path>: <line>` for each failure and the NOTE for each
# listed file with nothing left.
tdc_check() {
  local tree="$1" list="$2" scan files listed p rc=0
  scan=$(tdc_scan "$tree")
  files=$(printf '%s\n' "$scan" | cut -f1 | grep . | LC_ALL=C sort -u)
  listed=$(tdc_list "$list" | LC_ALL=C sort -u)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! grep -qxF -- "$p" <<<"$listed"; then
      printf 'ratchet: NEW %s: %s\n' "$p" "$(printf '%s\n' "$scan" | awk -F'\t' -v p="$p" '$1 == p {sub(/^[^\t]*\t[[:space:]]*/, ""); print; exit}')"
      rc=1
    fi
  done <<<"$files"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -qxF -- "$p" <<<"$files" || printf 'ratchet: %s has no direct call left; remove its line\n' "$p"
  done <<<"$listed"
  return "$rc"
}

# ---- R1: this checkout ----------------------------------------------------------------
[ -r "$ALLOW" ] && ok || bad "R1 the allowlist $ALLOW is missing"
out=$(tdc_check "$SRC" "$ALLOW"); rc=$?
if [ "$rc" = 0 ]; then ok
else
  bad "R1 a script outside the allowlist calls a tracker directly. Move it onto bin/lib/tracker.sh (tracker_kind, tracker_context, trk_gh_issue_number):"
  grep '^ratchet: NEW' <<<"$out"
fi
grep 'has no direct call left' <<<"$out" | sed 's/^/NOTE: /'

# ---- R2: the allowlist's own shape -------------------------------------------------------
paths=$(tdc_list "$ALLOW")
[ "$paths" = "$(printf '%s\n' "$paths" | LC_ALL=C sort -u)" ] && ok || bad "R2 the allowlist is not sorted and unique"
[ -n "$paths" ] && ok || bad "R2 the allowlist lists nothing"
bads=$(grep -vE '^bin/' <<<"$paths")
[ -z "$bads" ] && ok || bad "R2 an allowlist line is not a bin/ path: $bads"
printf '# a comment\n\nbin/b.sh\n  # indented comment\nbin/a.sh\n' > "$T/parse.txt"
[ "$(tdc_list "$T/parse.txt" | paste -sd' ' -)" = "bin/b.sh bin/a.sh" ] && ok || bad "R2 comments and blank lines are not dropped: $(tdc_list "$T/parse.txt")"

# ---- R3-R6: a scratch tree --------------------------------------------------------------
X="$T/x"; mkdir -p "$X/bin/lib/tracker"
printf '#!/bin/bash\nprefix=$(fleet-conf.sh "$p" board_prefix)\n' > "$X/bin/listed.sh"
printf '#!/bin/bash\necho fine\n' > "$X/bin/clean.sh"
printf '#!/bin/bash\ncurl -s "$TRK_BOARD_BASE/tickets/$id"\n' > "$X/bin/lib/tracker/board.sh"
printf '#!/bin/bash\nprefix=$(fleet-conf.sh "$p" board_prefix)\n' > "$X/bin/lib/tracker.sh"
printf 'bin/listed.sh\n' > "$T/allow.txt"
out=$(tdc_check "$X" "$T/allow.txt"); rc=$?
[ "$rc" = 0 ] && ok || bad "R3 baseline scratch tree must pass: $out"
grep -q 'tracker' <<<"$(tdc_scan "$X")" && bad "R5 the seam was reported: $(tdc_scan "$X")" || ok

printf '#!/bin/bash\nprefix=$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)\n' > "$X/bin/new-lane.sh"
out=$(tdc_check "$X" "$T/allow.txt"); rc=$?
[ "$rc" != 0 ] && ok || bad "R3 a new direct caller must fail the ratchet"
grep -q '^ratchet: NEW bin/new-lane.sh: prefix=' <<<"$out" && ok || bad "R3 the failure must name bin/new-lane.sh and its line: $out"
rm -f "$X/bin/new-lane.sh"
printf 'gh issue comment "$n" --body x\n' >> "$X/bin/listed.sh"
out=$(tdc_check "$X" "$T/allow.txt"); rc=$?
[ "$rc" = 0 ] && ok || bad "R3 a second call in a listed file passes (file granularity): $out"

printf '#!/bin/bash\n# prefix=$(fleet-conf.sh "$p" board_prefix)\n  # gh issue comment 12\n# curl "$b/tickets/1"\n' > "$X/bin/commented.sh"
[ -z "$(tdc_scan "$X" | grep commented)" ] && ok || bad "R4 a comment line matched: $(tdc_scan "$X" | grep commented)"

printf 'bin/clean.sh\nbin/listed.sh\n' > "$T/allow2.txt"
out=$(tdc_check "$X" "$T/allow2.txt"); rc=$?
[ "$rc" = 0 ] && ok || bad "R6 a stale line must not fail: $out"
grep -qx 'ratchet: bin/clean.sh has no direct call left; remove its line' <<<"$out" && ok || bad "R6 the stale NOTE is missing: $out"

# ---- R7: the patterns -------------------------------------------------------------------
Y="$T/y"; mkdir -p "$Y/bin"
m() { printf '#!/bin/bash\n%s\n' "$2" > "$Y/bin/$1"; }
m m1.sh 'bp=$(fleet-conf.sh "$p" board_prefix)'
m m2.sh 'gh_rest GET "repos/$r/issues/$n"'
m m3.sh 'gh issue comment "$n" --repo "$r" --body-file f'
m m4.sh 'curl -s -H "Authorization: Bearer $t" "$base/tickets/$id"'
m m5.sh 'curl -s "$base/boards"'
m m6.sh 'gh api "repos/$r/issues?state=open"'
m n1.sh 'gh_rest GET "repos/$r/pulls/$n"'
m n2.sh 'curl -s "$base/api/health"'
m n3.sh 'local my_board_prefix_x=1'
m n4.sh 'echo board_prefixes'
printf 'board_prefix here\n' > "$Y/bin/notes.txt"
printf '#!/usr/bin/env bash\nbp=$(fleet-conf.sh "$p" board_prefix)\n' > "$Y/bin/shebang-only"
got=$(tdc_scan "$Y" | cut -f1 | paste -sd' ' -)
[ "$got" = "bin/m1.sh bin/m2.sh bin/m3.sh bin/m4.sh bin/m5.sh bin/m6.sh bin/shebang-only" ] && ok \
  || bad "R7 the scan matched '$got', expected the six m*.sh shapes and the bash shebang file, none of the n*.sh or the .txt"

echo "tracker-direct-calls-ratchet.bh-7919: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
