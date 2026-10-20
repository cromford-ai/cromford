#!/bin/bash
# bin/suite-reach-check.sh — run every shell suite that names a file this PR
# changes, on the PR head and on the merge base. A suite green on base and red
# on head stops the build (bin/lib/suite-reach-gate.sh).
#
# Usage:
#   bin/suite-reach-check.sh --base <ref> [--tree <dir>] [--runner auto|isolated|local]
#                            [--cap N] [--budget S] [--suite-timeout S]
#                            [--table <file>] [--list-only]
#
# The reach list. The changed set is `git diff --name-status -M <fork> HEAD`
# (a rename counts both paths), where <fork> is `git merge-base <base> HEAD`.
# Only committed HEAD is read. Deleted paths also imply:
#   - a package.json tracked at <fork> whose "test" script holds a path token
#     (relative to the package dir) equal to, a directory of, or a glob over a
#     deleted path;
#   - a file under a fixtures/ directory at <fork> whose text names a deleted
#     path.
# The candidates are tests/*.sh and tests/mc/*.sh at HEAD, plus the ones only
# <fork> has (shown as deleted). A suite is listed when its text names a target:
#   self      the suite itself is changed
#   path      the target path, with path boundaries, on a non-comment line
#   implied   any match of an implied target (package.json, fixture)
#   glob      a token with `*` and a `/` and a lettered segment that matches
#   basename  the target's basename, when only one tracked file has it
#   comment   any of the above only on comment lines
# The list is ranked in that order, then by name. The test selection
# (bin/test-impact.sh) is not read.
#
# The runs. Each listed suite runs on HEAD, inside --cap suites and until
# --budget seconds have passed (later suites print `NOT RUN: <suite> (cap|budget)`).
#   head rc 0                   green; no base run
#   head rc 75, 124 or 137      TRANSIENT (rate limit, timeout, kill)
#   head red, absent at base    [NOTE] new at head and red
#   head red, base rc 75/124/137  TRANSIENT (base)
#   head red, base red          [NOTE] red on base and head
#   head red, base green        HEAD runs again: red → `RED:` (green→red);
#                               green → TRANSIENT flaky
# Counts are the last summary line (the bin/test-suite-run.sh SUMMARY_RE shape)
# as <pass>/<fail>, else ?/?. The case is the first FAIL / not ok line of the
# head output that the base output does not have.
#
# Runners: isolated runs a snapshot as nobody (bin/lib/rules-pack-snapshot.sh),
# HEAD in <w>/repo and base in <w>/base. local runs HEAD in --tree and base in a
# one-commit extract of <fork>, with the caller's environment. auto is isolated
# as root beside ${HARNESS_ROOT_OVERRIDE:-/root/harness}, else local.
#
# Exit: 0 clean, 1 at least one green→red, 2 bad arguments or base, 125 nothing
# could run. On 0 and 1 the last stdout line is
# `SUITE_REACH_VERDICT: clean|red (<counts>)`. --list-only prints
# `<suite><TAB><why>` per listed suite and runs nothing.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TREE=. BASE_REF="" RUNNER=auto CAP=60 BUDGET=600 STO=300 TABLE="" LIST_ONLY=0

die2() { echo "suite-reach: $*" >&2; exit 2; }
isint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tree|--base|--runner|--cap|--budget|--suite-timeout|--table)
      [ "$#" -ge 2 ] || die2 "$1 needs a value" ;;
  esac
  case "$1" in
    --tree) TREE=$2; shift 2 ;;
    --base) BASE_REF=$2; shift 2 ;;
    --runner) case "$2" in auto|isolated|local) RUNNER=$2 ;; *) die2 "--runner $2 (want auto|isolated|local)" ;; esac; shift 2 ;;
    --cap) isint "$2" || die2 "--cap $2 is not a whole number"; CAP=$2; shift 2 ;;
    --budget) isint "$2" || die2 "--budget $2 is not a whole number"; BUDGET=$2; shift 2 ;;
    --suite-timeout) isint "$2" && [ "$2" -gt 0 ] || die2 "--suite-timeout $2 is not a number >= 1"; STO=$2; shift 2 ;;
    --table) TABLE=$2; shift 2 ;;
    --list-only) LIST_ONLY=1; shift ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    *) die2 "unknown argument $1" ;;
  esac
done
[ -n "$BASE_REF" ] || die2 "--base <ref> is required"
TREE=$(cd "$TREE" 2>/dev/null && pwd) || die2 "--tree is not a directory"
HEAD_SHA=$(git -C "$TREE" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || die2 "$TREE has no HEAD commit"
git -C "$TREE" rev-parse -q --verify "$BASE_REF^{commit}" >/dev/null 2>&1 || die2 "--base $BASE_REF is not a commit in $TREE"
FORK=$(git -C "$TREE" merge-base "$BASE_REF" "$HEAD_SHA" 2>/dev/null) || die2 "no merge base of $BASE_REF and HEAD"

W=$(mktemp -d "${TMPDIR:-/tmp}/suite-reach.XXXXXX") || { echo "suite-reach: cannot make a work dir" >&2; exit 125; }
SW=""  # the isolated snapshot's own dir, when it cannot live in $W
trap 'rm -rf "$W" ${SW:+"$SW"}' EXIT

# ── the target set ─────────────────────────────────────────────────────────
declare -A TGT_WHY=()   # target path -> "" (changed) or the implied reason
declare -a TARGETS=() DELETED=()
add_target() { [ -n "${TGT_WHY[$1]+x}" ] && return 0; TGT_WHY[$1]=$2; TARGETS+=("$1"); }
while IFS=$'\t' read -r st a b; do
  case "$st" in
    R*|C*) add_target "$a" ""; add_target "$b" ""; [ "${st:0:1}" = R ] && DELETED+=("$a") ;;
    D) add_target "$a" ""; DELETED+=("$a") ;;
    ?*) add_target "$a" "" ;;
  esac
done < <(git -C "$TREE" diff --name-status -M "$FORK" "$HEAD_SHA")

# re_esc <text> — the text as a literal ERE.
re_esc() { sed -e 's/[][\.*^$+?(){}|]/\\&/g' <<< "$1"; }
LB='(^|[^A-Za-z0-9_-])'
RB='($|[^A-Za-z0-9_.-]|\.([^A-Za-z0-9]|$))'
# A basename is not part of a longer path: nothing path-like on its left, and
# a `/` on its left only after a non-path char or a $VAR ($LIB/x.sh, "$d"/x.sh).
BLB='(^|[^A-Za-z0-9_./-]|(^|[^A-Za-z0-9_./-])/|[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?/)'

# glob_re <token> — an anchored ERE for a path glob; `*` stays in one segment.
glob_re() { printf '^%s$' "$(sed -e 's/[][\.^$+?(){}|]/\\&/g' -e 's/\*/[^\/]*/g' <<< "$1")"; }

if [ "${#DELETED[@]}" -gt 0 ]; then
  # (a) package.json test scripts at the fork.
  while IFS= read -r pkg; do
    script=$(git -C "$TREE" show "$FORK:$pkg" 2>/dev/null | jq -r '.scripts.test // empty' 2>/dev/null) || continue
    [ -n "$script" ] || continue
    pdir=$(dirname "$pkg"); [ "$pdir" = . ] && pdir="" || pdir="$pdir/"
    read -ra toks <<< "$script"  # no glob expansion of test/*.test.js
    for tok in ${toks[@]+"${toks[@]}"}; do
      tok=${tok//[\"\']/}
      case "$tok" in -*|'') continue ;; esac
      [[ $tok =~ ^[A-Za-z0-9_./*-]+$ ]] || continue
      tok=${tok#./}; tok=${tok%/}
      [ -n "$tok" ] && [ "$tok" != . ] || continue
      full="$pdir$tok"
      for d in "${DELETED[@]}"; do
        if [ "$d" = "$full" ] || [[ $d == "$full"/* ]] \
           || { [[ $full == *\** ]] && [[ $d =~ $(glob_re "$full") ]]; }; then
          add_target "$pkg" "test script names deleted $d"; break
        fi
      done
    done
  done < <(git -C "$TREE" ls-tree -r --name-only "$FORK" | grep -E '(^|/)package\.json$')
  # (b) fixture files at the fork that name a deleted path.
  for d in "${DELETED[@]}"; do
    while IFS= read -r hit; do
      f=${hit#"$FORK":}
      [ "$f" = "$d" ] || add_target "$f" "fixture names deleted $d"
    done < <(git -C "$TREE" grep -lE "$LB$(re_esc "$d")$RB" "$FORK" -- 'fixtures/**' '**/fixtures/**' 2>/dev/null)
  done
fi

# ── the candidate suites ───────────────────────────────────────────────────
mkdir -p "$W/head" "$W/fork"
git -C "$TREE" archive --format=tar "$HEAD_SHA" tests 2>/dev/null | tar -x -C "$W/head" 2>/dev/null
git -C "$TREE" archive --format=tar "$FORK" tests 2>/dev/null | tar -x -C "$W/fork" 2>/dev/null
declare -A SUITE_SRC=() AT_HEAD=() AT_FORK=()
for f in "$W"/fork/tests/*.sh "$W"/fork/tests/mc/*.sh; do
  [ -f "$f" ] || continue; s=${f#"$W"/fork/}; AT_FORK[$s]=1; SUITE_SRC[$s]=$f
done
for f in "$W"/head/tests/*.sh "$W"/head/tests/mc/*.sh; do
  [ -f "$f" ] || continue; s=${f#"$W"/head/}; AT_HEAD[$s]=1; SUITE_SRC[$s]=$f
done
ALL_SUITES=()
[ "${#SUITE_SRC[@]}" -gt 0 ] && mapfile -t ALL_SUITES < <(printf '%s\n' "${!SUITE_SRC[@]}" | LC_ALL=C sort)
FILES=()
declare -A FILE2S=()
for s in ${ALL_SUITES[@]+"${ALL_SUITES[@]}"}; do FILES+=("${SUITE_SRC[$s]}"); FILE2S[${SUITE_SRC[$s]}]=$s; done

# Basenames held by exactly one tracked path at HEAD ∪ fork.
declare -A UNIQ_BASE=()
while read -r n b; do [ "$n" = 1 ] && UNIQ_BASE[$b]=1; done < <(
  { git -C "$TREE" ls-tree -r --name-only "$HEAD_SHA"; git -C "$TREE" ls-tree -r --name-only "$FORK"; } \
    | LC_ALL=C sort -u | awk -F/ '{print $NF}' | LC_ALL=C sort | uniq -c)

declare -A RANK=() WHY=()
# hit <suite> <rank> <why> — keep the best rank per suite.
hit() {
  local cur=${RANK[$1]:-99}
  [ "$2" -lt "$cur" ] || return 0
  RANK[$1]=$2; WHY[$1]=$3
}
# rank_of <kind-rank> <target> — implied targets rank 3 whatever the match kind.
rank_of() { if [ -n "${TGT_WHY[$2]}" ]; then echo 3; else echo "$1"; fi; }
why_of() { if [ -n "${TGT_WHY[$2]}" ]; then echo "implied $2 (${TGT_WHY[$2]})"; else echo "$1"; fi; }

# grep_hits <ere> <rank> <why> <target> — every suite whose text matches,
# ranked as given on a non-comment line and as comment otherwise.
grep_hits() {
  local re="$1" r="$2" w="$3" t="$4" f s
  [ "${#FILES[@]}" -gt 0 ] || return 0
  while IFS= read -r f; do
    s=${FILE2S[$f]}
    # No `grep -q` at a pipe's end: under pipefail its early exit is a
    # SIGPIPE upstream, which reads as no match.
    if [ -n "$(grep -E "$re" "$f" | grep -vE '^[[:space:]]*#')" ]; then
      hit "$s" "$(rank_of "$r" "$t")" "$(why_of "$w" "$t")"
    else
      hit "$s" 6 "comment $t"
    fi
  done < <(grep -lE -- "$re" "${FILES[@]}" 2>/dev/null)
}

for t in "${TARGETS[@]}"; do
  [ -n "${SUITE_SRC[$t]:-}" ] && [ -z "${TGT_WHY[$t]}" ] && hit "$t" 1 self
  grep_hits "$LB$(re_esc "$t")$RB" 2 "path $t" "$t"
  b=${t##*/}
  if [ "$b" != "$t" ] && [ -n "${UNIQ_BASE[$b]:-}" ]; then
    grep_hits "$BLB$(re_esc "$b")$RB" 5 "basename $b ($t)" "$t"
  fi
done

# Globs: tokens with a `*`, a `/` and a lettered segment.
if [ "${#FILES[@]}" -gt 0 ] && [ "${#TARGETS[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r f cmt tok; do
    tok=${tok#./}; tok=${tok#/}
    [[ $tok == */* ]] || continue
    [[ $tok =~ (^|/)[^/]*[A-Za-z][^/]*(/|$) ]] || continue
    gre=$(glob_re "$tok")
    for t in "${TARGETS[@]}"; do
      [[ $t =~ $gre ]] || continue
      s=${FILE2S[$f]}
      if [ "$cmt" = 1 ]; then hit "$s" 6 "comment $t"
      else hit "$s" "$(rank_of 4 "$t")" "$(why_of "glob $tok ~ $t" "$t")"; fi
    done
  done < <(awk '{
      c = ($0 ~ /^[[:space:]]*#/) ? 1 : 0; line = $0
      while (match(line, /[A-Za-z0-9_.\/-]*\*[A-Za-z0-9_.*\/-]*/)) {
        print FILENAME "\t" c "\t" substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
    }' "${FILES[@]}" | LC_ALL=C sort -u)
fi

mapfile -t LISTED < <(for s in "${!RANK[@]}"; do printf '%s\t%s\n' "${RANK[$s]}" "$s"; done | LC_ALL=C sort -t$'\t' -k1,1n -k2,2 | cut -f2)

if [ "$LIST_ONLY" = 1 ]; then
  for s in ${LISTED[@]+"${LISTED[@]}"}; do printf '%s\t%s\n' "$s" "${WHY[$s]}"; done
  exit 0
fi

# ── the runner ─────────────────────────────────────────────────────────────
HROOT="${HARNESS_ROOT_OVERRIDE:-/root/harness}"
if [ "$RUNNER" = auto ]; then
  if [ "$(id -u)" -eq 0 ] && [ -d "$HROOT" ]; then RUNNER=isolated; else RUNNER=local; fi
fi
cnr() { echo "suite-reach: could not run: $*" >&2; exit 125; }
if [ "$CAP" -gt 0 ] && [ "${#LISTED[@]}" -gt 0 ]; then
  if [ "$RUNNER" = isolated ]; then
    # shellcheck source=bin/lib/rules-pack-snapshot.sh
    . "$ROOT/bin/lib/rules-pack-snapshot.sh" || cnr "cannot load the snapshot lib"
    rp_snapshot_probe || cnr "the snapshot probe failed"
    # Same rule as bin/rules-pack.sh: nobody must reach the snapshot by its
    # absolute path, else build it under SUITE_REACH_SNAPSHOT_TMP.
    chmod 711 "$W"; SD="$W/snap"; mkdir -p "$SD"; chmod 711 "$SD"
    if ! rp_snapshot_reachable "$SD"; then
      SP="${SUITE_REACH_SNAPSHOT_TMP:-/tmp}"
      SW=$(mktemp -d "$SP/suite-reach-snap.XXXXXX" 2>/dev/null) && chmod 711 "$SW" && rp_snapshot_reachable "$SW" \
        || cnr "no snapshot dir reachable by nobody (tried $W and $SP)"
      SD=$SW
    fi
    rp_snapshot_build "$TREE" "$FORK" "$HEAD_SHA" "$SD" >/dev/null || cnr "the snapshot build failed"
    HEAD_DIR="$SD/repo" BASE_DIR="$SD/base"
  else
    [ -z "$(git -C "$TREE" status --porcelain --untracked-files=no 2>/dev/null)" ] \
      || echo "suite-reach: warning: $TREE has uncommitted tracked changes; local mode runs head suites in the tree as it stands" >&2
    HEAD_DIR=$TREE BASE_DIR="$W/base"
    mkdir -p "$BASE_DIR"
    git -C "$TREE" archive --format=tar "$FORK" | tar -x -C "$BASE_DIR" || cnr "could not extract $FORK"
    { git -C "$BASE_DIR" init -q \
        && git -C "$BASE_DIR" add -A \
        && git -C "$BASE_DIR" -c user.email=suite-reach@harness -c user.name=suite-reach -c commit.gpgsign=false \
             commit -q --no-verify --allow-empty -m base; } >/dev/null 2>&1 || cnr "could not commit the base tree"
  fi
fi

# run_suite <dir> <suite> <out> — the suite's rc; output in <out>.
run_suite() {
  if [ "$RUNNER" = isolated ]; then
    rp_snapshot_run "$1" env HARNESS_TEST_SANDBOX=1 timeout -k 10 "$STO" bash "$2" < /dev/null > "$3" 2>&1
  else
    ( cd "$1" && timeout -k 10 "$STO" bash "$2" < /dev/null ) > "$3" 2>&1
  fi
}
SUMMARY_RE='(^|: )([0-9]+ pass(ed)?, [0-9]+ fail(ed)?|pass=[0-9]+ fail=[0-9]+)'  # bin/test-suite-run.sh SUMMARY_RE
counts() { # counts <out> <rc> — "<pass>/<fail> rc=<rc>"
  local l p f
  l=$(grep -E "$SUMMARY_RE" "$1" 2>/dev/null | tail -1)
  p=$(grep -oE '[0-9]+ pass|pass=[0-9]+' <<< "$l" | grep -oE '[0-9]+' | tail -1)
  f=$(grep -oE '[0-9]+ fail|fail=[0-9]+' <<< "$l" | grep -oE '[0-9]+' | tail -1)
  printf '%s/%s rc=%s' "${p:-?}" "${f:-?}" "$2"
}
transient_rc() { case "$1" in 75|124|137) return 0 ;; esac; return 1; }
FAIL_RE='^[[:space:]]*(FAIL([^A-Za-z]|$)|not ok)'
case_of() { # case_of <head out> [<base out>] — the first new FAIL line
  local c=""
  # An empty pattern line would match every line, so the base's are dropped.
  if [ -n "${2:-}" ] && [ -s "$2" ]; then c=$(grep -E "$FAIL_RE" "$1" | grep -vxF -f <(grep -v '^$' "$2") | head -1); fi
  [ -n "$c" ] || c=$(grep -E "$FAIL_RE" "$1" | head -1)
  [ -n "$c" ] || c="(no FAIL line)"
  c=$(sed -e 's/^[[:space:]]*//' <<< "$c")
  printf '%s' "${c:0:200}"
}

N_RAN=0 N_RED=0 N_NOTE=0 N_TR=0 N_NR=0
ROWS=()
row() { ROWS+=("| $1 | ${WHY[$1]} | $2 | $3 | $4 |"); }
START=$SECONDS
i=0
for s in ${LISTED[@]+"${LISTED[@]}"}; do
  if [ -z "${AT_HEAD[$s]:-}" ]; then
    echo "[NOTE] $s deleted at head (the test-tamper gate judges deleted tests)"
    N_NOTE=$((N_NOTE+1)); row "$s" "-" "absent" "deleted"; continue
  fi
  if [ "$i" -ge "$CAP" ]; then
    echo "NOT RUN: $s (cap)"; N_NR=$((N_NR+1)); row "$s" "-" "-" "not run (cap)"; continue
  fi
  if [ $((SECONDS - START)) -ge "$BUDGET" ]; then
    echo "NOT RUN: $s (budget)"; N_NR=$((N_NR+1)); row "$s" "-" "-" "not run (budget)"; continue
  fi
  i=$((i+1)); N_RAN=$((N_RAN+1))
  k="$W/out.$i"
  run_suite "$HEAD_DIR" "$s" "$k.h1"; h1=$?
  hc=$(counts "$k.h1" "$h1")
  if [ "$h1" = 0 ]; then row "$s" "not run (head green)" "$hc" "green"; continue; fi
  if transient_rc "$h1"; then
    echo "TRANSIENT: $s rc=$h1 (head: $([ "$h1" = 124 ] && echo "timeout after ${STO}s" || echo "rate limit or kill"))"
    N_TR=$((N_TR+1)); row "$s" "not run (head transient)" "$hc" "transient"; continue
  fi
  if [ -z "${AT_FORK[$s]:-}" ]; then
    echo "[NOTE] $s new at head and red ($hc) case: $(case_of "$k.h1")"
    N_NOTE=$((N_NOTE+1)); row "$s" "absent" "$hc" "new-red"; continue
  fi
  run_suite "$BASE_DIR" "$s" "$k.b"; br=$?
  bc=$(counts "$k.b" "$br")
  if transient_rc "$br"; then
    echo "TRANSIENT: $s rc=$br (base) head=$hc"
    N_TR=$((N_TR+1)); row "$s" "$bc" "$hc" "transient (base)"; continue
  fi
  if [ "$br" != 0 ]; then
    echo "[NOTE] $s red on base and head base=$bc head=$hc case: $(case_of "$k.h1" "$k.b")"
    N_NOTE=$((N_NOTE+1)); row "$s" "$bc" "$hc" "red-both"; continue
  fi
  run_suite "$HEAD_DIR" "$s" "$k.h2"; h2=$?
  hc2=$(counts "$k.h2" "$h2")
  if [ "$h2" = 0 ] || transient_rc "$h2"; then
    echo "TRANSIENT: $s rc=$h1 then rc=$h2 on a second head run (flaky) base=$bc"
    N_TR=$((N_TR+1)); row "$s" "$bc" "$hc; $hc2" "flaky"; continue
  fi
  echo "RED: $s base=$bc head=$hc case: $(case_of "$k.h2" "$k.b")"
  N_RED=$((N_RED+1)); row "$s" "$bc" "$hc; $hc2" "green→red"
done

if [ -n "$TABLE" ]; then
  { echo "| suite | why | base | head | state |"
    echo "|---|---|---|---|---|"
    for r in ${ROWS[@]+"${ROWS[@]}"}; do printf '%s\n' "$r"; done
  } > "$TABLE" || echo "suite-reach: warning: could not write $TABLE" >&2
fi

SUM="listed=${#LISTED[@]} ran=$N_RAN red=$N_RED note=$N_NOTE transient=$N_TR notrun=$N_NR"
if [ "$CAP" = 0 ]; then echo "SUITE_REACH_VERDICT: clean (cap 0: not run)"; exit 0; fi
if [ "$N_RED" -gt 0 ]; then echo "SUITE_REACH_VERDICT: red ($SUM)"; exit 1; fi
echo "SUITE_REACH_VERDICT: clean ($SUM)"
exit 0
