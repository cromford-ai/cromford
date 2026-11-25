#!/bin/bash
# tests/bor-union-scale.bh-9952-test.sh — BH-9952: bor_union in linear time,
# byte-equal to the old algorithm.
#
# The hub's cromford discovery spent 603 s in br_from_builds and 571 s in
# br_from_rebuilds with the discovery cache hitting. The cost was bor_union's
# duplicate check: `case "$seen" in *$'\n'"$name"$'\n'*` over a string that
# grows by one name per local RESULT, plus one `date -u -r` fork per RESULT.
#
#   S1  4,000 local RESULT dirs and an empty ledger: bor_union finishes inside
#       `timeout 20` (the REPRO: on the old lib it does not).
#   S2  a 300-dir edge fixture: stdout and rc equal bor_union_ref (the old
#       function, copied below) with and without ledger rows, with
#       TZ=Asia/Tokyo, for project project-4, and with a find that answers nothing
#       (every RESULT takes the date -u -r fallback).
#   S3  bdb_epoch (bin/blocked-resolver.d/bh-9952-discovery-batch.sh) equals
#       `date -u -d` on every row of the plan's table, near misses included;
#       an empty stamp answers rc 1 (date answers today's 00:00Z).
#   S4  bdb_state_batch equals the old per-row state jq on every pair: seen,
#       not seen, pool-/fly- forms, an attempt list, a held attempt, a filter
#       error, a parse error in the middle, an empty file, two JSON values.
#   S5  bdb_rec equals the old per-field reads of br_from_rebuilds, or answers
#       rc 1 so the caller takes them (a value with a newline, two values).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/bor-union-scale.bh-9952-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

mkdir -p "$T/h" "$T/fix" "$T/nofind"
scratch_install_closure bin/lib/builds-of-record.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
scratch_install_closure bin/blocked-resolver.d/bh-9952-discovery-batch.sh "$T/h" >/dev/null 2>&1 || true

# The old bor_union, verbatim from main a45911aa (the reference for S2).
cat > "$T/ref.sh" <<'REF'
bor_union_ref() {
  local p="${1:-}" rows rc b f name rest seen ts line out="" results
  [ -n "$p" ] || return 1
  rows=$(bor_list "$p"); rc=$?
  [ "$rc" = 1 ] && return 1
  b="${H:-${HARNESS:-}}"; results=()
  [ -n "$b" ] && b="$b/builds" && results=("$b/$p"-*/RESULT "$b/pool-$p"-*/RESULT "$b/fly-$p"-*/RESULT)
  seen=$'\n'"$(printf '%s\n' "$rows" | cut -f2)"$'\n'
  for f in ${results[@]+"${results[@]}"}; do
    [ -f "$f" ] || continue
    name="${f%/RESULT}"; name="${name##*/}"; name="${name#pool-}"; name="${name#fly-}"
    rest="${name#"$p"-}"
    [[ "$rest" =~ ^([A-Z][A-Z0-9]*-[0-9]+) ]] || continue
    case "$seen" in *$'\n'"$name"$'\n'*) continue ;; esac
    seen="$seen$name"$'\n'
    ts=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts=-
    line=""; IFS= read -r line < "$f"
    out="$out${BASH_REMATCH[1]}"$'\t'"$name"$'\t-\t'"$ts"$'\t'"${line//$'\t'/ }"$'\t-\t-\n'
  done
  [ -n "$rows" ] && printf '%s\n' "$rows"
  printf '%s' "$out"
  [ -n "$rows$out" ] || return 2
}
REF

# The ledger stub: job_artifact_feed answers from $FIX/<kind>.tsv (absent = 0
# rows, rc 0). No worker, no network.
cat > "$T/feed.sh" <<'FEED'
job_artifact_feed() {
  local f="$FIX/$1.tsv"
  [ -f "$f" ] && cat "$f"
  return 0
}
FEED

# run <builds-root> <project> <fn> [extra env...] — stdout, then "rc=<n>".
run() {
  local h="$1" p="$2" fn="$3"; shift 3
  ( export H="$h" HARNESS="$h" FIX="$FIX" LANE_GATE_DISABLE=1 "$@"
    . "$T/h/bin/lib/builds-of-record.sh" || exit 99
    . "$T/ref.sh"; . "$T/feed.sh"
    "$fn" "$p"; echo "rc=$?" )
}

# --- S1: 4,000 local dirs, empty ledger -----------------------------------
FIX="$T/fix/empty"; mkdir -p "$FIX"
B1="$T/big/builds"; mkdir -p "$B1"
dirs=(); for i in $(seq 1 4000); do dirs+=("$B1/p1-BH-$i-20261120$(printf '%06d' "$i")"); done
mkdir -p "${dirs[@]}"
for d in "${dirs[@]}"; do printf 'PR_CREATED https://x/%s\n' "${d##*-}" > "$d/RESULT"; done
s1=$(timeout 20 bash -c '
  export H="$1" HARNESS="$1" FIX="$2" LANE_GATE_DISABLE=1
  . "$3/bin/lib/builds-of-record.sh" || exit 99
  . "$4"
  bor_union p1 | wc -l' _ "$T/big" "$FIX" "$T/h" "$T/feed.sh"); rc=$?
if [ "$rc" = 124 ]; then
  bad "S1 bor_union over 4000 local records did not finish inside timeout 20"
elif [ "$rc" != 0 ] || [ "$s1" != 4000 ]; then
  bad "S1 bor_union over 4000 local records: rc $rc, $s1 rows (want rc 0, 4000 rows)"
else ok; fi

# --- S2: the 300-dir edge fixture, byte-equal to the reference -------------
E="$T/edge"; EB="$E/builds"; mkdir -p "$EB"
mk() { # mk <dir> <content|-none> [touch-date]
  mkdir -p "$EB/$1"
  if [ "$2" != -none ]; then printf '%b' "$2" > "$EB/$1/RESULT"; fi
  [ -n "${3:-}" ] && [ -e "$EB/$1/RESULT" ] && touch -d "$3" "$EB/$1/RESULT"
  return 0
}
for i in $(seq 1 240); do
  mk "p1-BH-$i-202611200000$((i % 10))" "PLAN_BLOCKED see x $i\n" "2026-11-2$((i % 9)) 0$((i % 10)):1$((i % 6)):2$((i % 7))"
done
for i in $(seq 1 20); do mk "pool-p1-BH-$i-202611210000" "BUILD_DEAD pool $i\n" "2026-10-01 12:00:0$((i % 10))"; done   # pool twin of a bare name
for i in $(seq 241 255); do mk "pool-p1-BH-$i-202611210000" "PR_CREATED pool $i\n"; mk "fly-p1-BH-$i-202611210000" "PR_CREATED fly $i\n"; done
mk "p1-notes-1" "PR_CREATED no key\n"                       # no ticket key
mk "p1-BH-900-20261122000000" "REVIEW_BLOCKED\twith\ttabs\n"  # a RESULT with tabs
mk "p1-BH-901-20261122000000" "PR_CREATED no newline"       # no trailing newline
mk "p1-BH-902-20261122000000" ""                            # empty RESULT
mk "p1-BH-903-20261122000000" -none                         # a dir with no RESULT
mkdir -p "$EB/p1-BH-904-20261122000000/RESULT"              # RESULT is a dir
mk "p1-AB1-905-20261122000000" "PR_CREATED digits in key\n"
mk "p1-lower-906-1" "PR_CREATED lower case\n"
mk "project-4-TK-1-20261122000000" "PR_CREATED project-4\n"
mk "project-4-TK-1-20261122000000" "PR_CREATED project-4\n"     # never project-4's
mk "pool-project-4-TK-2-20261122000000" "PR_CREATED project-4 pool\n"
mkdir -p "$EB/p1-BH-907-20261122000000"; ln -s "$EB/p1-BH-2-2026112000002/RESULT" "$EB/p1-BH-907-20261122000000/RESULT"  # symlinked RESULT
ndirs=$(find "$EB" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$ndirs" -ge 300 ] && ok || bad "S2 fixture: $ndirs dirs, want >= 300"

# The ledger: rows that name local dirs (the ledger row wins), rows with no
# local dir, a pool- build_dir, a row with no key.
FL="$T/fix/ledger"; mkdir -p "$FL"
{ for i in 3 5 7 241; do
    printf 'j%s\tPR_CREATED ledger %s\tboxA\tt\t2026-11-23T01:0%s:00Z\t{"build_dir":"p1-BH-%s-202611200000%s","key":"BH-%s"}\n' "$i" "$i" "$((i % 10))" "$i" "$((i % 10))" "$i"
  done
  printf 'j800\tPLAN_BLOCKED remote\tboxB\tt\t2026-11-23T02:00:00Z\t{"build_dir":"pool-p1-BH-800-20261123000000","key":"BH-800"}\n'
  printf 'j801\tBUILD_DEAD remote\tboxB\tt\t2026-11-23T03:00:00Z\t{"build_dir":"p1-BH-801-20261123000000"}\n'
} > "$FL/result.tsv"
printf 'j3\thttps://github.com/o/r/pull/3\n' > "$FL/pr_url.tsv"

s2case() { # s2case <label> <fixdir> <project> [env...]
  local label="$1" fx="$2" p="$3" a b; shift 3
  a=$(FIX="$fx" run "$E" "$p" bor_union "$@")
  b=$(FIX="$fx" run "$E" "$p" bor_union_ref "$@")
  if [ "$a" = "$b" ] && [ -n "$a" ]; then ok
  else bad "S2 $label: bor_union differs from the reference"; diff <(printf '%s\n' "$b") <(printf '%s\n' "$a") | head -10; fi
}
s2case "no ledger" "$T/fix/empty" p1
s2case "with ledger rows" "$FL" p1
s2case "TZ=Asia/Tokyo" "$FL" p1 TZ=Asia/Tokyo
s2case "project project-4" "$T/fix/empty" project-4
s2case "project project-4" "$T/fix/empty" project-4
# A find that answers nothing: every RESULT takes the per-file fallback.
printf '#!/bin/sh\nexit 0\n' > "$T/nofind/find"; chmod +x "$T/nofind/find"
s2case "find answers nothing" "$FL" p1 PATH="$T/nofind:$PATH"
# A ledger outage is rc 1 with nothing printed, as before.
cat > "$T/feed-down.sh" <<'FEED'
job_artifact_feed() { return 1; }
FEED
o=$( export H="$E" FIX="$FL" LANE_GATE_DISABLE=1; . "$T/h/bin/lib/builds-of-record.sh"; . "$T/feed-down.sh"; bor_union p1; echo "rc=$?")
[ "$o" = "rc=1" ] && ok || bad "S2 outage: want only rc=1, got: $(printf '%.80s' "$o")"
# No root: the ledger rows only.
a=$( unset H HARNESS; export FIX="$FL" LANE_GATE_DISABLE=1; . "$T/h/bin/lib/builds-of-record.sh"; . "$T/ref.sh"; . "$T/feed.sh"; bor_union p1; echo "rc=$?")
b=$( unset H HARNESS; export FIX="$FL" LANE_GATE_DISABLE=1; . "$T/h/bin/lib/builds-of-record.sh"; . "$T/ref.sh"; . "$T/feed.sh"; bor_union_ref p1; echo "rc=$?")
[ "$a" = "$b" ] && ok || bad "S2 no root: differs from the reference"

# --- S3: bdb_epoch equals date -u -d ----------------------------------------
FRAG="$T/h/bin/blocked-resolver.d/bh-9952-discovery-batch.sh"
if [ ! -f "$FRAG" ]; then
  bad "S3 no fragment bin/blocked-resolver.d/bh-9952-discovery-batch.sh (bdb_epoch)"
else
  s3=$( say() { :; }; . "$FRAG" || exit 99
    for v in '2026-11-24T03:35:43Z' '2026-11-24 03:35:43' '2026-11-24 03:35:43Z' '2026-11-24T03:35:43.123Z' \
             '2024-02-29T23:59:59Z' '1970-01-01T00:00:00Z' '2026-12-31T23:59:59Z' \
             '2026-11-24T03:35:43' '2000-02-29 00:00:00' '2100-03-01T00:00:00Z' \
             '2026-11-24T03:35:43+02:00' '2026-11-24' '-' '' '2026-13-01T00:00:00Z' \
             '2026-02-30T00:00:00Z' '2025-02-29T00:00:00Z' '2026-11-24T24:00:00Z' \
             '2026-11-24T23:60:00Z' 'garbage'; do
      _BDB_EP=""; bdb_epoch "$v"; grc=$?
      # GNU date -d "" answers today's 00:00Z with rc 0; bdb_epoch refuses an
      # empty stamp (rc 1) instead of copying that answer.
      if [ -z "$v" ]; then [ "$grc" != 0 ] || echo "MISMATCH '': empty stamp answered $_BDB_EP"; continue; fi
      want=$(date -u -d "$v" +%s 2>/dev/null); wrc=$?
      if [ "$wrc" = 0 ]; then [ "$grc" = 0 ] && [ "$_BDB_EP" = "$want" ] || echo "MISMATCH '$v': date=$want bdb=$_BDB_EP rc=$grc"
      else [ "$grc" != 0 ] || echo "MISMATCH '$v': date fails, bdb answered $_BDB_EP"; fi
    done; echo done)
  case "$s3" in
    done) ok ;;
    *) bad "S3 bdb_epoch: $(printf '%s' "$s3" | grep MISMATCH | head -5 | tr '\n' ';')" ;;
  esac
fi

# --- S4: bdb_state_batch equals the per-row jq --------------------------------
S="$T/st"; mkdir -p "$S"
printf '{"rebuild_seen":["b1"],"attempts":[{"at":"2026-10-21 05:00:00Z","action":"fix-round"}]}\n' > "$S/a.json"
printf '{"rebuild_seen":["pool-b2","fly-b3"],"attempts":[{"at":"x1","action":"fix-round"},{"at":"x2","action":"held"},{"at":"x3","action":"hold-lifted"}]}\n' > "$S/b.json"
printf '{"rebuild_seen":"not-a-list","attempts":[]}\n' > "$S/c.json"
printf '{"bad json\n' > "$S/d.json"
: > "$S/e.json"
printf '{"rebuild_seen":[],"attempts":[]}\n{"rebuild_seen":["b1"]}\n' > "$S/f.json"
printf '{"attempts":[{"at":"2026-10-19 05:00:00Z","action":"rebuild-fresh"}]}\n' > "$S/g.json"
if [ -f "$FRAG" ]; then
  s4=$( say() { :; }; . "$FRAG" || exit 99
    q='[
              ((.rebuild_seen // []) | any(. == $b or . == ("pool-" + $b) or . == ("fly-" + $b))),
              ([.attempts[]? | select((.action // "") | . != "held" and . != "stalled" and . != "stall-cleared" and (startswith("hold-") | not))] | last | (.at // ""))
            ] | @tsv'
    pairs=()
    for f in a b c d e f g; do for b in b1 b2 b3 zz; do pairs+=("$S/$f.json"$'\t'"$b"); done; done
    bdb_state_batch pairs
    for pr in "${pairs[@]}"; do
      f="${pr%%$'\t'*}"; b="${pr#*$'\t'}"
      if want=$(jq -r --arg b "$b" "$q" "$f" 2>/dev/null); then
        [ -n "${_BDB_ST[$pr]+x}" ] && [ "${_BDB_ST[$pr]}" = "$want" ] || echo "MISMATCH ${f##*/}/$b: want '$want' got '${_BDB_ST[$pr]-<none>}'"
      else
        [ -z "${_BDB_ST[$pr]+x}" ] || echo "MISMATCH ${f##*/}/$b: the per-row jq fails, the batch answered '${_BDB_ST[$pr]}'"
      fi
    done; echo done)
  [ "$s4" = done ] && ok || bad "S4 bdb_state_batch: $(grep MISMATCH <<<"$s4" | head -5 | tr '\n' ';')"
  # --- S5: bdb_rec equals the per-field reads ---------------------------------
  s5=$( say() { :; }; . "$FRAG" || exit 99
    la='[.attempts[]? | select((.action // "") | . != "held" and . != "stalled" and . != "stall-cleared" and (startswith("hold-") | not) and (startswith("data-lane") | not) and . != "escalate-data-lane")] | last'
    for st in '{"outcome":"","attempts":[{"at":"2026-11-01 00:00:00Z","action":"rebuild-fresh"},{"at":"y","action":"held"}],"parked_url":"https://github.com/o/r/pull/1","parked_rec":"/h/builds/x","rebuild_seen":["a","pool-b"],"nh_placed":"2026-11-02","wait_job":"K@2026"}' \
              '{"outcome":"HELD","attempts":[{"action":"data-lane-x","at":"z"},{"action":"rebuild-fresh-failed"}],"rebuild_seen":[]}' \
              '{"attempts":[],"parked_url":null,"nh_placed":false,"wait_job":3}' \
              '[]' '"x"' '{"parked_url":"a\nb"}' '{"a":1} {"b":2}'; do
      old="$(printf '%s' "$st" | jq -r "$la | (.action // \"\")" 2>/dev/null)|$(printf '%s' "$st" | jq -r "$la | (.at // \"\")" 2>/dev/null)|$(printf '%s' "$st" | jq -r '.parked_url // "-"' 2>/dev/null)|$(printf '%s' "$st" | jq -r '.parked_rec // "-"' 2>/dev/null)|$(printf '%s' "$st" | jq -r '(.rebuild_seen // []) | join(" ")' 2>/dev/null)|$(printf '%s' "$st" | jq -r '.nh_placed // ""' 2>/dev/null)|$(printf '%s' "$st" | jq -r '.wait_job // ""' 2>/dev/null)"
      if bdb_rec "$st"; then
        new="$_BDB_R_LAST|$_BDB_R_AT|$_BDB_R_URL|$_BDB_R_PREC|$_BDB_R_SEEN|$_BDB_R_NH|$_BDB_R_WJ"
        [ "$new" = "$old" ] || echo "MISMATCH $st: old '$old' new '$new'"
      else
        printf 'FALLBACK %s\n' "$st"
      fi
    done; echo done)
  case "$s5" in *MISMATCH*) bad "S5 bdb_rec: $(grep MISMATCH <<<"$s5" | head -3 | tr '\n' ';')" ;;
    *) [ "$(grep -c '^FALLBACK' <<<"$s5")" = 2 ] && grep -q 'FALLBACK {"parked_url"' <<<"$s5" && ok \
         || bad "S5 bdb_rec: want rc 1 for the newline value and the two values only ($(grep '^FALLBACK' <<<"$s5" | tr '\n' ';'))" ;;
  esac
fi

printf 'bor-union-scale.bh-9952: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
