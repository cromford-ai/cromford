#!/bin/bash
# tests/blocked-resolver-builds-walk.bh-6044-test.sh — br_from_builds walks the
# build records without a fork per record (BH-6044).
#
# WHY. On 2026-10-11 the hub sat at load 80 on 8 vCPUs and the merge conductor's
# workers died at their 600 s deadline before their first log line. Every
# per-project blocked-resolver run (BH-5913) spent ~4,700 s in discovery:
# br_from_builds globbed ALL of builds/ (7,887 dirs, every pool-* dir twice),
# forked bin/project-of.sh for each record, and only then dropped the rows of
# the 12 other projects. Thirteen runs did that walk at once.
#
#   W1  a fleet run forks project-of.sh for no record
#   W2  a fleet run prints each candidate once (a pool record was offered twice)
#   W3  a fleet run's rows are the expected set: every project, pool and plain
#   W4  a project run forks project-of.sh for no record and reads the project
#       list at most once
#   W5  a project run (`project-6`) offers its own rows, pool included, and never
#       a row of the project whose name it prefixes (`project-6-os`)
#   W6  a project run globs only its own records (builds/<p>-*/,
#       builds/pool-<p>-*/)
#   W7  a project list that cannot be read offers nothing (project-of.sh's
#       answer when fleet-conf fails)
#   R1-R2 br_from_rebuilds forks no basename/dirname for another project's
#       state file (it forked two per file, in each of 13 project runs)
#   L1-L2 br_handoff_lines calls `date` at most twice per call, never once per
#       log line, and returns the same rows: the newest line per PR inside the
#       window, no line of another word, no line with an invalid stamp
#   P1  bin/pipeline-health.sh and bin/rebase-train.sh read a record's line 1
#       without `head`/`grep` forks
#
# HOW IT DRIVES. The shipped function text is extracted from
# bin/blocked-resolver.sh and run with the REAL bin/fleet-conf.sh and the REAL
# record layer (bin/lib/br/record.sh), no ledger lib (the glob path). The one
# stub is bin/project-of.sh: it counts its calls and then runs the real one.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-builds-walk.bh-6044-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib/br" "$H/builds" "$H/state/blocked-resolver"
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/project-of.sh" "$H/bin/project-of.real.sh"
# scratch-closure-allow: the record layer (bin/lib/br/) is sourced into the test shell to unit-test the extracted source functions; no script is run
cp "$DIR"/bin/lib/br/*.sh "$H/bin/lib/br/"
# The counting stub: one line per call, then the real answer.
cat > "$H/bin/project-of.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$POF_SINK"
exec "$(dirname "$0")/project-of.real.sh" "$@"
STUB
# A counting wrapper around the real fleet-conf.sh, for the --projects reads.
mv "$H/bin/fleet-conf.sh" "$H/bin/fleet-conf.real.sh"
cat > "$H/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
[ "${1:-}" = --projects ] && printf 'projects\n' >> "$FC_SINK"
[ -f "${FC_DOWN:-/nonexistent}" ] && exit 1
exec "$(dirname "$0")/fleet-conf.real.sh" "$@"
STUB
chmod +x "$H/bin/"*.sh
# Three GitHub-Issues lanes (board prefix "-"); project-6 is a prefix of
# project-6-os, which is the case project-of.sh's longest-name-first order is for.
printf '%s\n' 'project-6 o/project-6 - - 2 box-a 100.0.0.9' \
              'project-6-os o/project-6-os - - 2 box-a 100.0.0.9' \
              'tproj o/tproj - - 2 box-a 100.0.0.9' > "$H/fleet.conf"
ST="$H/state/blocked-resolver"

# BH-6461: the key family moved to bin/lib/br/keys.sh; the corpus is the driver
# plus bin/lib/br/*.sh (tests/lib/br-corpus.sh), so the extraction finds it there.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
extract() { # extract <out-file>
  : > "$1"
  for fn in br_from_builds br_key_shape; do
    awk -v f="^$fn\\\\(\\\\) \\\\{" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$1"
  done
}
extract "$T/fn.sh"
grep -q '^br_from_builds() {' "$T/fn.sh" && ok || bad "setup: could not extract br_from_builds"

# drive: br_from_builds with ONLY=$ONLY, the glob path (no bor_union).
drive() {
  ( export H="$H" HARNESS="$H" ST="$ST" FLEET_CONF="$H/fleet.conf" \
           POF_SINK="$T/pof.txt" FC_SINK="$T/fc.txt" FC_DOWN="${FC_DOWN:-}"
    ONLY="${ONLY:-}"; OBSERVE=0; PER_TICK=10; EFF_PER_TICK=10
    # shellcheck source=/dev/null
    . "$H/bin/lib/br/record.sh" || exit 99
    # shellcheck source=/dev/null
    . "$T/fn.sh" || exit 99
    say() { :; }
    br_from_builds ) 2>/dev/null
}
rec() { # rec <dir-name> — a test-tamper park, 8 h old (past every floor)
  mkdir -p "$H/builds/$1"
  printf 'REVIEW_BLOCKED test-tamper\n' > "$H/builds/$1/RESULT"
  touch -d "@$((NOW - 28800))" "$H/builds/$1/RESULT"
}
calls() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
reset() { rm -f "$T/pof.txt" "$T/fc.txt"; }

rec project-6-TK-1-20261011T0100
rec pool-project-6-TK-2-20261011T0200
rec project-6-os-TK-3-20261011T0300
rec pool-project-6-os-TK-4-20261011T0400
rec tproj-BH-5-20261011T0500
rec pool-tproj-BH-6-20261011T0600

rk() { # rk <project> <key> — the row's rkey, from the real record layer
  ( . "$H/bin/lib/br/record.sh" >/dev/null 2>&1; br_rkey "$1-$2" )
}
TAB=$'\t'
row() { # row <project> <key> <dir-name>
  printf 'build%s%s%s%s%stest-tamper%s-%s%s%s%s%s-\n' "$TAB" "$1" "$TAB" "$(rk "$1" "$2")" "$TAB" \
    "$TAB" "$TAB" "$H/builds/$3" "$TAB" "$2" "$TAB"
}
EXP_ALL=$( { row project-6 TK-1 project-6-TK-1-20261011T0100
             row project-6 TK-2 pool-project-6-TK-2-20261011T0200
             row project-6-os TK-3 project-6-os-TK-3-20261011T0300
             row project-6-os TK-4 pool-project-6-os-TK-4-20261011T0400
             row tproj BH-5 tproj-BH-5-20261011T0500
             row tproj BH-6 pool-tproj-BH-6-20261011T0600; } | sort)
EXP_MK=$( { row project-6 TK-1 project-6-TK-1-20261011T0100
            row project-6 TK-2 pool-project-6-TK-2-20261011T0200; } | sort)

# ── W1-W3. the fleet run ─────────────────────────────────────────────────────
reset
OUT=$(ONLY="" drive)
[ "$(calls "$T/pof.txt")" = 0 ] && ok \
  || bad "W1: a fleet run must fork project-of.sh for no record (forked $(calls "$T/pof.txt") times)"
[ -z "$(printf '%s\n' "$OUT" | sort | uniq -d)" ] && ok \
  || bad "W2: a fleet run must offer each record once — repeated: $(printf '%s\n' "$OUT" | sort | uniq -d | cut -f3 | tr '\n' ' ')"
[ "$(printf '%s\n' "$OUT" | sort -u)" = "$EXP_ALL" ] && ok \
  || bad "W3: fleet rows differ — got:$(printf '\n%s' "$OUT" | sort -u | cut -f2,3,6)"

# ── W4-W5. the project-6 project run ─────────────────────────────────────────
reset
OUT=$(ONLY=project-6 drive)
[ "$(calls "$T/pof.txt")" = 0 ] && ok \
  || bad "W4: a project run must fork project-of.sh for no record (forked $(calls "$T/pof.txt") times)"
[ "$(calls "$T/fc.txt")" -le 1 ] && ok \
  || bad "W4: a project run must read the project list at most once (read $(calls "$T/fc.txt") times)"
[ "$(printf '%s\n' "$OUT" | sort -u)" = "$EXP_MK" ] && ok \
  || bad "W5: project-6 run rows differ — got:$(printf '\n%s' "$OUT" | sort -u | cut -f2,3,6)"

# ── W6. a project run never opens another project's record ───────────────────
# The tests run as root, which reads any mode, so this is the structural check:
# the walk names this project's records only.
grep -qF '"$H"/builds/"$ONLY"-*/' "$T/fn.sh" && grep -qF '"$H"/builds/pool-"$ONLY"-*/' "$T/fn.sh" && ok \
  || bad "W6: a project run must glob builds/<ONLY>-*/ and builds/pool-<ONLY>-*/ only"

# ── W7. no project list, no rows ─────────────────────────────────────────────
reset
: > "$T/fc-down"
OUT=$(FC_DOWN="$T/fc-down" ONLY="" drive)
[ -z "$OUT" ] && ok || bad "W7: an unreadable project list must offer nothing (got $(printf '%s\n' "$OUT" | grep -c .) rows)"
rm -f "$T/fc-down"

# ═════════════════════════════════════════════════════════════════════════════
# R. br_from_rebuilds forks nothing for another project's state file
# ═════════════════════════════════════════════════════════════════════════════
# basename/dirname stubs count every call; a project run over 40 state files of
# OTHER projects must make none (it made two per file).
mkdir -p "$T/fakebin"
for b in basename dirname; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FORK_SINK"\nexec %s "$@"\n' "$(command -v "$b")" > "$T/fakebin/$b"
done
chmod +x "$T/fakebin/"*
: > "$T/fnr.sh"
for fn in br_from_rebuilds br_key_shape; do
  awk -v f="^$fn\\\\(\\\\) \\\\{" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/fnr.sh"
done
grep -q '^br_from_rebuilds() {' "$T/fnr.sh" && ok || bad "setup: could not extract br_from_rebuilds"
for i in $(seq 1 20); do
  mkdir -p "$ST/tproj" "$ST/project-6-os"
  printf '{"outcome":"","attempts":[]}\n' > "$ST/tproj/tproj-BH-$i.json"
  printf '{"outcome":"","attempts":[]}\n' > "$ST/project-6-os/project-6-os-TK-$i.json"
done
rm -f "$T/forks.txt"
OUT=$( ( export PATH="$T/fakebin:$PATH" H="$H" ST="$ST" FORK_SINK="$T/forks.txt"
         ONLY=project-6; OBSERVE=0; PER_TICK=10; EFF_PER_TICK=10
         . "$H/bin/lib/br/record.sh" >/dev/null 2>&1
         . "$T/fnr.sh" || exit 99
         say() { :; }
         br_from_rebuilds ) 2>/dev/null)
[ "$(calls "$T/forks.txt")" = 0 ] && ok \
  || bad "R1: a project-6 run must fork basename/dirname for no other project's state file (forked $(calls "$T/forks.txt") times)"
[ -z "$OUT" ] && ok || bad "R2: a project-6 run with no project-6 state must offer nothing (got: $OUT)"

# ═════════════════════════════════════════════════════════════════════════════
# L. br_handoff_lines: one pass, no `date` per log line, the same rows
# ═════════════════════════════════════════════════════════════════════════════
REALDATE=$(command -v date)
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FORK_SINK"\nexec %s "$@"\n' "$REALDATE" > "$T/fakebin/date"
chmod +x "$T/fakebin/date"
: > "$T/fnl.sh"
awk '/^br_handoff_lines\(\) \{/ {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh" >> "$T/fnl.sh"
grep -q '^br_handoff_lines() {' "$T/fnl.sh" && ok || bad "setup: could not extract br_handoff_lines"
mkdir -p "$H/logs"
stamp() { "$REALDATE" -u -d "@$((NOW - $1))" '+%Y-%m-%d %H:%M:%S'; }   # determinism: ok date-empty-stamp fixture writer, NOW is fixed
hl() { # hl <age-secs> <key> <word> <reason> <url> — one hand-off line
  printf '%sZ %s %s %s: parked — handed to bin/blocked-resolver.sh (rung 1): %s\n' "$(stamp "$1")" "$2" "$3" "$4" "$5"
}
{ hl 3600   o/r#1 BLOCKED_AGENT ci-red          https://github.com/o/r/pull/1
  hl 1800   o/r#1 BLOCKED_AGENT review-blocked  https://github.com/o/r/pull/1
  hl 7200   o/r#2 RED_TWICE     red-twice       https://github.com/o/r/pull/2
  hl 259200 o/r#3 BLOCKED_AGENT ci-red          https://github.com/o/r/pull/3
  hl 600    o/r#4 WAITING       ci-red          https://github.com/o/r/pull/4
  printf '2026-10-11 99:99:99Z o/r#5 BLOCKED_AGENT ci-red: x — handed to bin/blocked-resolver.sh (r): https://github.com/o/r/pull/5\n'
  for i in $(seq 1 30); do hl $((100 + i)) "o/r#$((100 + i))" BLOCKED_AGENT ci-red "https://github.com/o/r/pull/$((100 + i))"; done
} > "$H/logs/merge-conductor.log"
rm -f "$T/forks.txt"
OUT=$( ( export PATH="$T/fakebin:$PATH" H="$H" FORK_SINK="$T/forks.txt"
         . "$T/fnl.sh" || exit 99
         br_handoff_lines ) 2>/dev/null | sort)
[ "$(calls "$T/forks.txt")" -le 2 ] && ok \
  || bad "L1: br_handoff_lines must call date at most twice per call, not per line (called $(calls "$T/forks.txt") times for 36 lines)"
EXP_L=$( { printf 'o/r#1\treview-blocked\thttps://github.com/o/r/pull/1\n'
           printf 'o/r#2\tred-twice\thttps://github.com/o/r/pull/2\n'
           for i in $(seq 1 30); do printf 'o/r#%s\tci-red\thttps://github.com/o/r/pull/%s\n' $((100 + i)) $((100 + i)); done; } | sort)
[ "$OUT" = "$EXP_L" ] && ok \
  || bad "L2: rows differ — newest line per PR inside 48 h, no WAITING line, no bad stamp: got
$(head -5 <<<"$OUT")"

# ═════════════════════════════════════════════════════════════════════════════
# P. the other fleet-wide record walks fork nothing per record
# ═════════════════════════════════════════════════════════════════════════════
# bin/pipeline-health.sh (three walks, run once per tick over every project) and
# bin/rebase-train.sh (every project's records, per project) read line 1 of each
# RESULT. Their behaviour is pinned by their own suites; this pins the shape.
for f in bin/pipeline-health.sh bin/rebase-train.sh; do
  if grep -nE 'head -1 "\$D/RESULT"|grep -oE .https://github.com/.*<<<"\$R"|grep -q "/\$PROJECT/" <<<' "$DIR/$f" >/dev/null; then
    bad "P1: $f still forks per record: $(grep -nE 'head -1 "\$D/RESULT"|grep -oE .https://github.com/.*<<<"\$R"|grep -q "/\$PROJECT/" <<<' "$DIR/$f" | head -3 | tr '\n' ' ')"
  else ok; fi
done

echo "blocked-resolver-builds-walk.bh-6044-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
