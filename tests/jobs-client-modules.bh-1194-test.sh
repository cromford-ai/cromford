#!/bin/bash
# tests/jobs-client-modules.bh-1194-test.sh — the jobs/ module seam (BH-1194):
# bin/jobs-client.sh is a SHIM over bin/lib/jobs/, every verb keeps its name and
# its module, a half-synced box refuses to half-load the client, and every
# fixture that copies the client into a scratch harness copies the modules too.
#
# WHY A MAP AND NOT "the files exist". The split is a no-op only if every
# function came out the other side, exactly once, in a named place. A test that
# checked the eight files exist would pass on a split that dropped
# job_verdict_rebind, defined queue_claim twice, or left half the client in the
# shim — and the first symptom of any of those is a lane that silently stops
# coordinating, because this client is FAIL-OPEN by contract: a missing function
# is an unbound-variable error inside someone else's subshell, swallowed by the
# `2>/dev/null` every caller wraps it in. So the map below pins WHICH module
# owns each function, the suite asserts the union is exactly that
# map, and it sources the real shim and asks bash — `declare -F` — rather than
# trusting a grep.
#
# WHY THE SNAPSHOT IS WRITTEN TO A FILE. The pipeline that asks bash for the
# defined function names is captured inside a command substitution in the test.
# Under parallel fork load that capture intermittently drops a single line, so
# a function that is really defined can be absent from the variable. Writing
# the same pipeline to a scratch file and grepping the file is stable under the
# same load because the consumer reads after the producer has closed the file.
#
# WHY THE MISSING-MODULE CASE IS DRIVEN. `grep -q JC_MODULES` passes just as
# happily on a loop that sources what it finds and shrugs at what it does not,
# which is a lane running with half a client on a box whose bin/ arrived in two
# pieces. So a module is really removed from a real copy, the shim is really
# sourced, and the case asserts on artifacts: the rc, the stderr line naming the
# path, and that the caller's next command never ran.
#
# Run from anywhere: tests/jobs-client-modules.bh-1194-test.sh  (exit 0 = pass)
# No network, no clock, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SHIM="$DIR/bin/jobs-client.sh"
LIB="$DIR/bin/lib/jobs"

# The ownership map, as fragments (Lane E, 2026-09-24): every
# tests/jobs-client-modules.d/*.tsv holds `module<TAB>function` rows, the base
# in 00-base.tsv and one NN-<TICKET-KEY>.tsv (NN 10-99) per later change. They are assembled
# below into the same `<module> <function>...` lines, one per module, in the
# order each module first appears — which is the order the shim sources them
# in. A function moving between modules is still a deliberate edit, and the
# table is still the contract the state-to-DB slices (#1025–#1033) build
# against; what changed is only that two PRs adding verbs no longer share a line.
# TEST-CHANGE (Lane E): the map's data source moved from a heredoc to the
# fragment files; every assertion below reads the same assembled lines.
# TEST-CHANGE (BH-1957): req gains _jobs_not_configured, the empty-JOBS_URL
# fail-open log — a new function in req.sh, so the map names it there.
jc_map_from_fragments() { # <dir> — print one `<module> <fn>...` line per module
  local d="$1" f; local -a frags=()
  while IFS= read -r f; do [ -n "$f" ] && frags+=("$f"); done \
    < <(find "$d" -maxdepth 1 -type f -name '*.tsv' 2>/dev/null | LC_ALL=C sort)
  [ "${#frags[@]}" -gt 0 ] || { echo "$d holds no *.tsv fragment" >&2; return 1; }
  local err="" n
  # Every entry must be a regular NN-<name>.tsv; only 00-base.tsv may be 00-,
  # so nothing can sort at or before the base and reorder its modules.
  for f in "$d"/* "$d"/.[!.]*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    n=${f##*/}
    if [ -L "$f" ] || [ ! -f "$f" ]; then err="$err$n is not a regular file (symlinks are refused); "
    elif ! [[ "$n" =~ ^[0-9][0-9]-[A-Za-z0-9._-]+\.tsv$ ]]; then err="$err$n is not an NN-<TICKET-KEY>.tsv fragment, so never read; "
    elif [ "${n:0:3}" = 00- ] && [ "$n" != 00-base.tsv ]; then err="$err$n: only 00-base.tsv may sort first (use 10-99); "
    fi
  done
  [ -f "$d/00-base.tsv" ] && [ ! -L "$d/00-base.tsv" ] || err="${err}00-base.tsv is missing; "
  err="$err"$(awk -F'\t' '/^[[:space:]]*(#|$)/{next}
    NF != 2 || $1 !~ /^[a-z_][a-z0-9_-]*$/ || $2 !~ /^[A-Za-z_][A-Za-z0-9_]*$/ {
      f = FILENAME; sub(/.*\//, "", f); printf "%s:%d not module<TAB>function; ", f, FNR }' "${frags[@]}")
  awk -F'\t' '/^[[:space:]]*(#|$)/{next} NF == 2 {
      if (!($1 in fns)) order[++n] = $1
      fns[$1] = fns[$1] " " $2 }
    END { for (i = 1; i <= n; i++) print order[i] fns[order[i]] }' "${frags[@]}"
  [ -z "$err" ] || { echo "$err" >&2; return 1; }
}
jc_map_from_fragments "$DIR/tests/jobs-client-modules.d" > "$T/jc-map.txt" 2> "$T/jc-map.err" && ok \
  || bad "tests/jobs-client-modules.d must assemble: $(tr '\n' ' ' < "$T/jc-map.err")"
MAP=$(cat "$T/jc-map.txt")
# The assembler refuses what it would otherwise skip or mis-order (review of
# #2226): a file that is not a fragment, a symlinked fragment, a name without
# the NN- prefix, and any fragment other than 00-base.tsv that would sort AT or
# before the base (only 00-base.tsv may be 00-, so the base's module order can
# never be reordered by a later file). A later fragment naming a base module
# must not move it.
jcf() { mkdir -p "$T/jcf/$1"; printf '%b' "$3" > "$T/jcf/$1/$2"; }
jc_refuses() { # <case> <want-in-stderr>
  jc_map_from_fragments "$T/jcf/$1" > /dev/null 2> "$T/jcf/$1.err" && bad "assembler must refuse case $1" || ok
  grep -qF "$2" "$T/jcf/$1.err" && ok || bad "case $1: the refusal must name '$2': $(tr '\n' ' ' < "$T/jcf/$1.err")"
}
jcf stray 00-base.tsv 'req\t_jobs_log\n'; jcf stray 10-BH-1.tsv.orig 'queue\tq_x\n'
jc_refuses stray "10-BH-1.tsv.orig"
jcf link 00-base.tsv 'req\t_jobs_log\n'; printf 'queue\tq_x\n' > "$T/jcf/elsewhere.tsv"; ln -s "$T/jcf/elsewhere.tsv" "$T/jcf/link/10-BH-2.tsv"
jc_refuses link "10-BH-2.tsv"
jcf noprefix 00-base.tsv 'req\t_jobs_log\n'; jcf noprefix BH-3.tsv 'queue\tq_x\n'
jc_refuses noprefix "BH-3.tsv"
jcf early 00-base.tsv 'req\t_jobs_log\nqueue\tq_a\n'; jcf early 00-aaa.tsv 'queue\tq_b\n'
jc_refuses early "00-aaa.tsv"
jcf order 00-base.tsv 'req\t_jobs_log\nqueue\tq_a\n'; jcf order 10-BH-4.tsv 'queue\tq_b\nreq\t_jobs_new\n'
[ "$(jc_map_from_fragments "$T/jcf/order" 2>/dev/null | awk '{printf "%s ", $1}')" = "req queue " ] && ok \
  || bad "a later fragment must not reorder the base modules: $(jc_map_from_fragments "$T/jcf/order" 2>&1 | tr '\n' '|')"
MODULES=$(printf '%s\n' "$MAP" | awk '{printf "%s ", $1}' | sed 's/ $//')

# ============================================================================
# 1. The seam: a literal module list, one file per module, all valid bash
# ============================================================================
# Literal, not computed: this suite and every fixture read the list off this
# line, so a command substitution here would be the client running code inside
# every reader. The spelling IS the contract.
if grep -q "^JC_MODULES=\"$MODULES\"\$" "$SHIM"; then ok; else
  bad "bin/jobs-client.sh must carry the literal JC_MODULES=\"$MODULES\" line; got: $(grep -m1 '^JC_MODULES=' "$SHIM")"
fi

for m in $MODULES; do
  if [ -r "$LIB/$m.sh" ]; then ok; else bad "bin/lib/jobs/$m.sh is missing"; continue; fi
  bash -n "$LIB/$m.sh" 2>/dev/null && ok || bad "bin/lib/jobs/$m.sh is not valid bash"
done
bash -n "$SHIM" 2>/dev/null && ok || bad "bin/jobs-client.sh is not valid bash"

# The shim is a shim: it defines no client function itself, so there is never a
# second copy of a verb shadowing the module that owns it.
SHIMFN=$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$SHIM")
[ "$SHIMFN" = 0 ] && ok || bad "bin/jobs-client.sh must define no functions of its own; got $SHIMFN"

# ============================================================================
# 2. The ownership map: each function defined exactly once, in its module
# ============================================================================
ALLFN=""
while read -r mod fns; do
  [ -n "$mod" ] || continue
  for fn in $fns; do
    ALLFN="$ALLFN $fn"
    # A missing file counts as 0 definitions, never as an empty string: the
    # "missing module" case is reported once, above, and must not also print a
    # second finding per function per sibling.
    n=$(grep -cE "^${fn}\(\) *\{" "$LIB/$mod.sh" 2>/dev/null); n=${n:-0}
    [ "$n" = 1 ] && ok || bad "$fn must be defined exactly once in bin/lib/jobs/$mod.sh (got $n)"
    for other in $MODULES; do
      [ "$other" = "$mod" ] && continue
      o=$(grep -cE "^${fn}\(\) *\{" "$LIB/$other.sh" 2>/dev/null); o=${o:-0}
      [ "$o" = 0 ] && ok || bad "$fn is also defined in bin/lib/jobs/$other.sh"
    done
  done
done <<< "$MAP"

# No module defines a function the map does not name: a verb added without a
# line in the table is a verb no fixture and no sibling slice knows about.
DEFINED=$(for m in $MODULES; do grep -oE "^[a-zA-Z_][a-zA-Z0-9_]*\(\)" "$LIB/$m.sh" 2>/dev/null | tr -d '()'; done | sort)
MAPPED=$(printf '%s\n' $ALLFN | sort)
if [ "$DEFINED" = "$MAPPED" ]; then ok; else
  bad "the modules define functions the map does not name (or vice versa): $(comm -3 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$MAPPED") | tr -s '[:space:]' ' ')"
fi

# ============================================================================
# 3. Sourcing the shim really defines them — asked of bash, not of grep
# ============================================================================
mkdir -p "$T/h/logs"
GOT_FILE="$T/h/declared-functions.txt"
HARNESS="$T/h" bash -c '. "$1" >/dev/null 2>&1; declare -F | awk "{print \$3}" | sort > "$2"' _ "$SHIM" "$GOT_FILE" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "sourcing bin/jobs-client.sh for declare -F capture exited non-zero (rc=$RC)"
[ -s "$GOT_FILE" ] && ok || bad "declare -F snapshot is empty after sourcing bin/jobs-client.sh"
for fn in $ALLFN; do
  grep -qx "$fn" "$GOT_FILE" && ok || bad "sourcing bin/jobs-client.sh does not define $fn"
done

# Every CLI verb still resolves to a function that exists after the source. The
# dispatch block is the one place the split could leave a verb pointing at a
# function that moved out and never arrived.
VERBFN=$(awk '/^if \[ "\${BASH_SOURCE\[0\]}" = "\$0" \]; then/{f=1} f' "$SHIM" \
  | grep -oE '^ *[a-z0-9|-]+\) +[a-z_]+[a-z_0-9]* "\$@"' \
  | awk '{print $2}' | sort -u)
[ -n "$VERBFN" ] && ok || bad "could not read the CLI dispatch verbs out of the shim"
RECAPTURE_FILE="$T/h/declared-functions-recapture.txt"
for fn in $VERBFN; do
  if grep -qx "$fn" "$GOT_FILE"; then
    ok
  else
    HARNESS="$T/h" bash -c '. "$1" >/dev/null 2>&1; declare -F | awk "{print \$3}" | sort > "$2"' _ "$SHIM" "$RECAPTURE_FILE" >/dev/null 2>&1
    if grep -qx "$fn" "$RECAPTURE_FILE"; then
      bad "snapshot dropped a line: CLI verb handler $fn was missing from the first declare -F capture but present in the recapture"
    else
      bad "CLI verb handler $fn is not defined after sourcing the shim"
    fi
  fi
done

# ============================================================================
# 4. A half-synced box refuses to half-load the client
# ============================================================================
mkdir -p "$T/m/bin/lib/jobs" "$T/m/logs"
cp "$SHIM" "$T/m/bin/jobs-client.sh"
cp "$LIB"/*.sh "$T/m/bin/lib/jobs/"
# Whole tree: sourcing is silent and the caller runs on.
OUT=$(HARNESS="$T/m" bash -c '. "$1" >/dev/null 2>&1; echo REACHED' _ "$T/m/bin/jobs-client.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = REACHED ] && ok \
  || bad "a complete copy must source clean and let the caller run on (rc=$RC out=$OUT)"
# One module gone: nonzero, one line naming the missing path, and the caller's
# next command never runs.
rm -f "$T/m/bin/lib/jobs/queue.sh"
ERR=$(HARNESS="$T/m" bash -c '. "$1" 2>/dev/null; echo REACHED' _ "$T/m/bin/jobs-client.sh" 2>/dev/null); RC=$?
[ "$RC" != 0 ] && ok || bad "a missing module must exit nonzero, not half-load the client"
[ "$ERR" != REACHED ] && ok || bad "a missing module must stop the caller, not let it run on with half a client"
ERR2=$(HARNESS="$T/m" bash -c '. "$1"' _ "$T/m/bin/jobs-client.sh" 2>&1 >/dev/null)
grep -q 'bin/lib/jobs/queue.sh' <<<"$ERR2" \
  && ok || bad "the refusal must name the missing module path; got: $ERR2"
# It must also name the fixture rule, because the reader is almost always a test
# author whose scratch harness copied the client and not the modules.
grep -qi 'bin/lib/jobs' <<<"$ERR2" \
  && grep -qiE 'cop(y|ied)|fixture' <<<"$ERR2" \
  && ok || bad "the refusal must tell the reader to copy bin/lib/jobs/*.sh too; got: $ERR2"

# ============================================================================
# 5. The fixture rule, ratcheted: copy the client, copy the modules
# ============================================================================
# Every suite that copies bin/jobs-client.sh into a scratch tree must also carry
# bin/lib/jobs/. This is the same shape as the mc/ rule the conductor split left
# behind, and it is checked here so a NEW fixture cannot reintroduce the failure
# the refusal above exists to report.
# Only a cp whose SOURCE is the real client counts. A suite that writes its own
# stub and copies THAT into a scratch bin/ (tests/review-prs-gh-dedup-test.sh)
# needs no modules, and a rule that could not tell the two apart would be
# satisfied by pasting the string into a comment.
MISS=""
for t in "$DIR"/tests/*.sh; do
  grep -q 'bin/lib/jobs' "$t" && continue
  sed -e :a -e '/\\$/N; s/\\\n/ /; ta' "$t" \
    | awk '/(^|[;&|(]|[[:space:]])cp[[:space:]]/ {
             for (i = 1; i < NF; i++) if ($i ~ /bin\/jobs-client\.sh"?$/) { found = 1 }
           } END { exit found ? 0 : 1 }' \
    && MISS="$MISS $(basename "$t")"
done
[ -z "$MISS" ] && ok || bad "these fixtures copy bin/jobs-client.sh without bin/lib/jobs/*.sh:$MISS"

echo "jobs-client-modules.bh-1194-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
