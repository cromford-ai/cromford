#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/stale-parent-rest.bh-6892-test.sh — the REST twin of sp_stale_commits
# (BH-6892). A lane-run machine has no /root/repos checkout, so the stale-parent
# check reads the PR commit list, the base commit list and the commit diffs from
# GitHub REST and takes patch-ids from `git patch-id --stable` over those diffs.
#
# The fixtures are REAL git repos with fixed dates. A fake `gh` on PATH answers
# each REST path from the repo named in $FAKE_REPO: a commit diff is
# `git diff <sha>^ <sha>` and a compare is `git diff <from>...<to>`, the shape
# of GitHub's application/vnd.github.diff. Every argv goes to $T/gh.log; a path
# that matches a glob line in $T/gh.fail answers rc 1; $T/gh.full makes every
# base page full.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/stale-parent-rest.sh"
SLUG="o/r"

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name tester
git config --global commit.gpgsign false
git config --global init.defaultBranch main

# Fixed clock: every git write takes the next minute after 2026-10-01 10:00Z.
TICK=0
when() { TICK=$((TICK+1)); printf '2026-10-01T%02d:%02d:00Z' $((10 + TICK / 60)) $((TICK % 60)); }
g() { local d; d=$(when); GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git -C "$@"; }
# commit <repo> <file> <subject>
commit() { echo "$3" > "$1/$2" && git -C "$1" add "$2" && g "$1" commit -qm "$3"; }
sha() { git -C "$1" rev-parse "$2"; }
# SPR_NOW: a fixed epoch two days after the fixtures.
NOW=$(date -u -d '2026-10-03T00:00:00Z' +%s)

# ── the fake gh ───────────────────────────────────────────────────────────
mkdir -p "$T/bin" "$T/pr"
cat > "$T/bin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_T/gh.log"
[ "${1:-}" = api ] || exit 2
shift
acc=""
while [ $# -gt 1 ]; do
  case "$1" in -H) acc="$2"; shift 2 ;; *) shift ;; esac
done
path="$1"
if [ -f "$FAKE_T/gh.fail" ]; then
  while IFS= read -r pat; do
    # shellcheck disable=SC2254 # a glob line on purpose
    case "$path" in $pat) exit 1 ;; esac
  done < "$FAKE_T/gh.fail"
fi
R="$FAKE_REPO"
# cjson <sha> — one commit object in the REST list shape.
cjson() {
  local s="$1" msg date par
  msg=$(git -C "$R" log -1 --format=%B "$s")
  date=$(TZ=UTC git -C "$R" log -1 --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format=%cd "$s")
  par=$(git -C "$R" log -1 --format=%P "$s")
  jq -n --arg s "$s" --arg m "$msg" --arg d "$date" --arg p "$par" \
    '{sha:$s, commit:{message:$m, committer:{date:$d}}, parents:($p|split(" ")|map(select(length>0))|map({sha:.}))}'
}
case "$path" in
  repos/*/commits/*)
    case "$acc" in *vnd.github.diff*) ;; *) exit 3 ;; esac
    s="${path##*/}"
    # A root commit diffs against the empty tree, as GitHub's does.
    par=$(git -C "$R" rev-parse -q --verify "$s^" 2>/dev/null) || par=$(git -C "$R" hash-object -t tree /dev/null)
    git -C "$R" diff --no-color "$par" "$s" ;;
  repos/*/compare/*)
    r="${path##*/compare/}"
    git -C "$R" diff --no-color "${r%%...*}...${r##*...}" ;;
  repos/*/pulls/*/commits*)
    n="${path#*/pulls/}"; n="${n%%/*}"
    read -r b h < "$FAKE_T/pr/$n" || exit 1
    for s in $(git -C "$R" rev-list --reverse --topo-order "$b..$h"); do cjson "$s"; done | jq -s . ;;
  repos/*/commits\?*)
    q="${path#*\?}"; br=""; since=""; page=1
    IFS='&' read -ra kv <<<"$q"
    for x in "${kv[@]}"; do
      case "$x" in sha=*) br="${x#sha=}" ;; since=*) since="${x#since=}" ;; page=*) page="${x#page=}" ;; esac
    done
    br=$(printf '%b' "${br//%/\\x}")
    if [ -f "$FAKE_T/gh.full" ]; then
      s=$(git -C "$R" rev-parse "$br")
      for _ in $(seq 100); do cjson "$s"; done | jq -s .
      exit 0
    fi
    git -C "$R" log --format=%H --since="$since" "$br" | sed -n "$(( (page - 1) * 100 + 1 )),$(( page * 100 ))p" \
      | while read -r s; do cjson "$s"; done | jq -s . ;;
  *) exit 4 ;;
esac
GH
chmod +x "$T/bin/gh"

# spr <repo> <num> <cache> [env...] — spr_stale_commits in a subshell.
# stdout → $T/out, rc → $T/rc, "FETCHED CACHED LEFT" → $T/cnt. Saves the cache.
spr() {
  local repo="$1" num="$2" cache="$3"; shift 3
  : > "$T/gh.log"; echo "- - -" > "$T/cnt"
  # shellcheck disable=SC2163 # "$@" is NAME=value pairs, exported on purpose
  ( export FAKE_T="$T" FAKE_REPO="$repo" PATH="$T/bin:$PATH" HARNESS="$T" SPR_NOW="$NOW" "$@"
    [ -f "$LIB" ] || exit 99
    # shellcheck disable=SC1090
    . "$LIB" || exit 98
    spr_budget_init
    spr_stale_commits "$SLUG" main "$num" "$cache"; rc=$?
    echo "$SPR_FETCHED $SPR_CACHED $SPR_LEFT" > "$T/cnt"
    spr_cache_save "$cache"
    exit "$rc" ) > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
rows() { grep -c . "$T/out"; }
diffcalls() { grep -c 'vnd.github.diff' "$T/gh.log"; }

# ── the lib ───────────────────────────────────────────────────────────────
if [ -f "$LIB" ]; then
  ok
  SRC=$( # shellcheck disable=SC1090
         HARNESS="$T" . "$LIB" 2>&1 )
  [ -z "$SRC" ] && ok || bad "sourcing bin/lib/stale-parent-rest.sh printed output: $SRC"
  bash -n "$LIB" && ok || bad "bin/lib/stale-parent-rest.sh fails bash -n"
else
  bad "bin/lib/stale-parent-rest.sh does not exist (BH-6892)"
fi

# mkpick <repo> — main: base, m1, then p1 cherry-picked (another sha).
# Branch p: p1 off base. Branch child: c1 off p1. PR 1 = main..child.
mkpick() {
  local r="$1"
  git init -q "$r"
  commit "$r" base.txt "base"
  git -C "$r" checkout -q -b p
  commit "$r" p1.txt "p1: parent work"
  git -C "$r" checkout -q -b child
  commit "$r" c.txt "c1: child work"
  git -C "$r" checkout -q main
  commit "$r" m.txt "m1: other main work"
  g "$r" cherry-pick p >/dev/null
}

# S1 — p1 landed on main by cherry-pick: one row p1 → main's copy.
R1="$T/s1"; mkpick "$R1"
P1=$(sha "$R1" p); M1=$(sha "$R1" main)
echo "main child" > "$T/pr/1"
spr "$R1" 1 "$T/c1/cache.tsv"
[ "$(rc)" = 0 ] && ok || bad "S1: rc=$(rc) ($(cat "$T/err"))"
[ "$(rows)" = 1 ] && ok || bad "S1: expected one row, got: $(cat "$T/out")"
IFS=$'\t' read -r C1 C2 C3 < "$T/out"
[ "${C1:-}" = "$P1" ] && ok || bad "S1: col1 must be p1 $P1, got '${C1:-}'"
[ "${C2:-}" = "$M1" ] && ok || bad "S1: col2 must be main's copy $M1, got '${C2:-}'"
[ "${C3:-}" = "p1: parent work" ] && ok || bad "S1: col3 must be p1's subject, got '${C3:-}'"

# S7 — under budget: the counters match the diff calls in gh.log.
read -r F7 K7 L7 < "$T/cnt"
DC=$(diffcalls)
[ "$F7" = "$DC" ] && ok || bad "S7: SPR_FETCHED=$F7 but gh.log has $DC diff calls"
[ "$K7" = 0 ] && ok || bad "S7: SPR_CACHED must be 0 on a cold cache, got $K7"
[ "$DC" -gt 0 ] && [ "$L7" = $((120 - DC)) ] && ok || bad "S7: SPR_LEFT must be 120-$DC, got $L7"
[ -s "$T/c1/cache.tsv" ] && ok || bad "S7: spr_cache_save wrote no cache file"

# S9a — the same call again with the saved cache: zero diff calls.
spr "$R1" 1 "$T/c1/cache.tsv"
[ "$(rc)" = 0 ] && [ "$(rows)" = 1 ] && ok || bad "S9: warm run rc=$(rc) rows: $(cat "$T/out")"
[ "$(diffcalls)" = 0 ] && ok || bad "S9: warm run made $(diffcalls) diff calls: $(grep vnd "$T/gh.log")"
grep -q 'pulls/1/commits' "$T/gh.log" && grep -q 'commits?sha=main' "$T/gh.log" && ok \
  || bad "S9: warm run must still read both lists: $(cat "$T/gh.log")"
read -r F9 K9 _ < "$T/cnt"
[ "$F9" = 0 ] && [ "$K9" = "$F7" ] && ok || bad "S9: warm counters FETCHED=$F9 CACHED=$K9, want 0 and $F7"

# S8 — STALE_PARENT_REST_DIFF_MAX=2: rc 3 after exactly two diff calls, no rows.
spr "$R1" 1 "$T/c8/cache.tsv" STALE_PARENT_REST_DIFF_MAX=2
[ "$(rc)" = 3 ] && ok || bad "S8: rc must be 3 when the budget is spent, got $(rc) ($(cat "$T/err"))"
[ "$(diffcalls)" = 2 ] && ok || bad "S8: expected exactly 2 diff calls, got $(diffcalls)"
[ ! -s "$T/out" ] && ok || bad "S8: rc 3 must print nothing, got: $(cat "$T/out")"

# S2 — squash: p1+p2 landed as one squash commit; child = p1 p2 c3.
R2="$T/s2"; git init -q "$R2"
commit "$R2" base.txt "base"
git -C "$R2" checkout -q -b p
commit "$R2" p1.txt "p1: first half"
commit "$R2" p2.txt "p2: second half"
git -C "$R2" checkout -q -b child
commit "$R2" c.txt "c3: child work"
git -C "$R2" checkout -q main
commit "$R2" m.txt "m1: other main work"
git -C "$R2" merge -q --squash p >/dev/null 2>&1
g "$R2" commit -qm "parent (squashed)"
SQ=$(sha "$R2" main); S2P1=$(sha "$R2" p~1); S2P2=$(sha "$R2" p)
echo "main child" > "$T/pr/2"
spr "$R2" 2 "$T/c2/cache.tsv"
[ "$(rc)" = 0 ] && ok || bad "S2: rc=$(rc) ($(cat "$T/err"))"
[ "$(rows)" = 2 ] && ok || bad "S2: expected two rows, got: $(cat "$T/out")"
[ "$(sed -n 1p "$T/out")" = "$S2P1"$'\t'"$SQ"$'\t'"p1: first half" ] && ok || bad "S2: row 1 wrong: $(sed -n 1p "$T/out")"
[ "$(sed -n 2p "$T/out")" = "$S2P2"$'\t'"$SQ"$'\t'"p2: second half" ] && ok || bad "S2: row 2 wrong: $(sed -n 2p "$T/out")"
grep -q "compare/$(sha "$R2" p~2)...$S2P2" "$T/gh.log" && ok || bad "S2: no compare call from p1's parent to p2"

# S3 — the same sha on the base (main fast-forwarded to p1): no row.
R3="$T/s3"; git init -q "$R3"
commit "$R3" base.txt "base"
git -C "$R3" checkout -q -b p
commit "$R3" p1.txt "p1: parent work"
git -C "$R3" checkout -q -b child
commit "$R3" c.txt "c1: child work"
git -C "$R3" checkout -q main
git -C "$R3" merge -q --ff-only p
echo "main~1 child" > "$T/pr/3"
spr "$R3" 3 "$T/c3/cache.tsv"
[ "$(rc)" = 0 ] && ok || bad "S3: rc=$(rc) ($(cat "$T/err"))"
[ ! -s "$T/out" ] && ok || bad "S3: the same sha on the base is not a stale copy, got: $(cat "$T/out")"

# S4 — nothing of the child is on main: no row.
R4="$T/s4"; git init -q "$R4"
commit "$R4" base.txt "base"
git -C "$R4" checkout -q -b child
commit "$R4" c1.txt "c1: child work"
commit "$R4" c2.txt "c2: more child work"
git -C "$R4" checkout -q main
commit "$R4" m.txt "m1: other main work"
echo "main child" > "$T/pr/4"
spr "$R4" 4 "$T/c4/cache.tsv"
[ "$(rc)" = 0 ] && ok || bad "S4: rc=$(rc) ($(cat "$T/err"))"
[ ! -s "$T/out" ] && ok || bad "S4: no match must print no row, got: $(cat "$T/out")"

# S5 — the child sync-merged main: the merge commit is not read or reported.
R5="$T/s5"; mkpick "$R5"
git -C "$R5" checkout -q child
g "$R5" merge -q --no-edit main >/dev/null
MG=$(sha "$R5" child); S5P1=$(sha "$R5" p); S5M=$(sha "$R5" main)
git -C "$R5" checkout -q main
echo "main child" > "$T/pr/5"
spr "$R5" 5 "$T/c5/cache.tsv"
[ "$(rc)" = 0 ] && ok || bad "S5: rc=$(rc) ($(cat "$T/err"))"
[ "$(cat "$T/out")" = "$S5P1"$'\t'"$S5M"$'\t'"p1: parent work" ] && ok || bad "S5: expected only the p1 row, got: $(cat "$T/out")"
grep -q "$MG" "$T/gh.log" && bad "S5: a diff call named the merge commit $MG" || ok

# S6 — the diff of p1 (and the compare that ends at it) fails: no row, no cache row.
R6="$T/s6"; mkpick "$R6"
S6P1=$(sha "$R6" p); S6B=$(sha "$R6" main~2)
printf '%s\n' "repos/$SLUG/commits/$S6P1" "repos/$SLUG/compare/$S6B...$S6P1" > "$T/gh.fail"
echo "main child" > "$T/pr/6"
spr "$R6" 6 "$T/c6/cache.tsv"
rm -f "$T/gh.fail"
[ "$(rc)" = 0 ] && ok || bad "S6: rc=$(rc) ($(cat "$T/err"))"
[ ! -s "$T/out" ] && ok || bad "S6: a failed diff must give no row, got: $(cat "$T/out")"
grep -q "commits/$S6P1" "$T/gh.log" && ok || bad "S6: the diff of p1 was never asked for"
grep -q "^$S6P1"$'\t' "$T/c6/cache.tsv" 2>/dev/null && bad "S6: the failed sha $S6P1 was cached" || ok

# S10 — a base list longer than three full pages: rc 2, no rows.
touch "$T/gh.full"
spr "$R1" 1 "$T/c10/cache.tsv"
rm -f "$T/gh.full"
[ "$(rc)" = 2 ] && ok || bad "S10: a page cut must answer rc 2, got $(rc)"
[ "$(grep -c 'commits?sha=main' "$T/gh.log")" = 3 ] && ok || bad "S10: expected 3 base pages read, got $(grep -c 'commits?sha=main' "$T/gh.log")"

# S11 — an unreadable child list or base list: rc 1.
echo "repos/$SLUG/pulls/1/commits?per_page=100" > "$T/gh.fail"
spr "$R1" 1 "$T/c11/cache.tsv"
[ "$(rc)" = 1 ] && ok || bad "S11: an unreadable child list must answer rc 1, got $(rc)"
echo "repos/$SLUG/commits[?]sha=main*" > "$T/gh.fail"
spr "$R1" 1 "$T/c11b/cache.tsv"
rm -f "$T/gh.fail"
[ "$(rc)" = 1 ] && ok || bad "S11: an unreadable base list must answer rc 1, got $(rc)"

# S9b — retention on save: a row 15 days stale is dropped; 2100 rows cap at
#        the 1800 newest by last-used. A hit refreshes last-used, so it is kept.
#        spr_pid runs in THIS shell (no $(...)) so the refresh is not lost.
C9="$T/c9/cache.tsv"; mkdir -p "$T/c9"
{ printf 'dead\tpidold\t%s\n' $((NOW - 15 * 86400))
  for i in $(seq 1 2100); do printf 'abcdef%s\tpid%s\t%s\n' "$i" "$i" $((NOW - i)); done; } > "$C9"
: > "$T/gh.log"
( export HARNESS="$T" SPR_NOW="$NOW" PATH="$T/bin:$PATH" FAKE_T="$T" FAKE_REPO="$R1"
  [ -f "$LIB" ] || exit 99
  # shellcheck disable=SC1090
  . "$LIB" || exit 98
  spr_budget_init
  spr_pid "$SLUG" abcdef2100 "$C9" > "$T/v" || exit 97
  [ "$(cat "$T/v")" = pid2100 ] || exit 96
  [ "$SPR_CACHED" = 1 ] && [ "$SPR_FETCHED" = 0 ] || exit 95
  spr_cache_save "$C9" ) > "$T/out" 2> "$T/err"
R9=$?
[ "$R9" = 0 ] && ok || bad "S9: a cache hit + save answered rc $R9 ($(cat "$T/err"))"
[ ! -s "$T/gh.log" ] && ok || bad "S9: a cache hit made a gh call: $(cat "$T/gh.log")"
[ "$(grep -c . "$C9" 2>/dev/null)" = 1800 ] && ok || bad "S9: the cache must cap at 1800 rows, has $(grep -c . "$C9" 2>/dev/null)"
grep -q '^dead'$'\t' "$C9" && bad "S9: a row 15 days stale survived the save" || ok
grep -q '^abcdef1'$'\t' "$C9" && grep -q '^abcdef1799'$'\t' "$C9" && ok || bad "S9: the newest rows must be kept"
grep -q '^abcdef1800'$'\t' "$C9" && bad "S9: abcdef1800 is the 1801st newest and must be dropped" || ok
grep -q '^abcdef2100'$'\t'"pid2100"$'\t'"$NOW"'$' "$C9" && ok || bad "S9: a cache hit must update last-used to SPR_NOW"
# The 14-day rule on its own (a small cache, so the 1800 cap cannot hide it):
# 15 days unused goes, 13 days unused stays.
C9B="$T/c9b/cache.tsv"; mkdir -p "$T/c9b"
printf 'dead\tp15\t%s\nbeef\tp13\t%s\n' $((NOW - 15 * 86400)) $((NOW - 13 * 86400)) > "$C9B"
( export HARNESS="$T" SPR_NOW="$NOW"
  [ -f "$LIB" ] || exit 99
  # shellcheck disable=SC1090
  . "$LIB" || exit 98
  spr_cache_save "$C9B" ) > "$T/out" 2> "$T/err"
[ "$(cut -f1 "$C9B" 2>/dev/null | tr '\n' ' ')" = "beef " ] && ok \
  || bad "S9: retention must drop the 15-day row and keep the 13-day row, got: $(cat "$C9B" 2>/dev/null)"
[ -n "$(find "$T/c9" -type f ! -name cache.tsv)" ] && bad "S9: the save left a temp file: $(ls "$T/c9")" || ok

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
