#!/bin/bash
# tests/prepush-durations-fetch.bh-7210-test.sh — BH-7210: the builder fetches
# catalog/ci-suite-durations.tsv before the pre-push gate.
#
# The file is git-ignored (BH-5518), so a fresh checkout has none, fast-lints
# finds an empty fast set and is could-not-run. The '# >>> prepush gate' span of
# bin/lib/rb/pr.sh now runs 'bin/ci-durations.sh fetch --out
# catalog/ci-suite-durations.tsv' (bounded, PREPUSH_DURATIONS_FETCH_S, default
# 60 s) before the first gate run, only when the file is absent.
#   D1  no file, the fetch writes one -> the gate sees it, fast-lints green
#   D2  the fetch fails -> fast-lints stays could-not-run, the push goes on
#   D3  the fetch hangs -> killed at the bound, the push goes on
#   D4  the file is present (D4b: 0 bytes) -> no fetch
#   D5  no bin/ci-durations.sh in the checkout -> no fetch, no error
#   D6  prepush.gate_mode=off -> no fetch; the gate table names no ci-durations
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/prepush-durations-fetch.bh-7210-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }

span() { awk '/^# >>> prepush gate/{f=1} f{print} /^# <<< prepush gate/{exit}' "$1"; }
span "$DIR/bin/lib/rb/pr.sh" > "$T/span.sh"
[ -s "$T/span.sh" ] && ok || bad "no '# >>> prepush gate' span in bin/lib/rb/pr.sh"

# mk <case> <fetch: writes|fails|hangs|none> — a checkout with a stub gate that
# reports fast-lints green only when catalog/ci-suite-durations.tsv has a data row.
mk() {
  local d="$T/$1" f="$2"
  mkdir -p "$d/co/bin" "$d/co/catalog" "$d/build"
  { printf '#!/bin/bash\nD=%s\n' "$d"
    cat <<'EOS'
O=""; while [ $# -gt 0 ]; do case "$1" in --out) O=$2; shift ;; esac; shift; done
echo run >> "$D/calls"; mkdir -p "$O"
if grep -qv '^#' catalog/ci-suite-durations.tsv 2>/dev/null; then
  echo saw-file >> "$D/calls"; printf 'fast-lints\tgreen\t0\t3\t-\n' > "$O/summary.tsv"; exit 0
fi
printf 'fast-lints\tcould-not-run\t2\t3\t-\n' > "$O/summary.tsv"; exit 1
EOS
  } > "$d/co/bin/prepush-gate.sh"
  chmod +x "$d/co/bin/prepush-gate.sh"
  [ "$f" = none ] && return 0
  { printf '#!/bin/bash\nD=%s\nM=%s\n' "$d" "$f"
    cat <<'EOS'
echo "fetch $*" >> "$D/calls"
O=""; while [ $# -gt 0 ]; do case "$1" in --out) O=$2; shift ;; esac; shift; done
case "$M" in
  writes) printf '# source: stub\nsuite\tseconds\ntests/x.sh\t3\n' > "$O"; exit 0 ;;
  fails) echo "stub fetch failed" >&2; exit 1 ;;
  hangs) for _ in $(seq 300); do [ -e "$D/release" ] && exit 0; sleep 0.1; done ;;
esac
EOS
  } > "$d/co/bin/ci-durations.sh"
  chmod +x "$d/co/bin/ci-durations.sh"
}
spanrun() { # spanrun <case> — runs the span in the case's checkout; prints the exit code
  local d="$T/$1"
  ( cd "$d/co" && env BUILD="$d/build" PROJECT=cromford KEY=BH-1 BASE=origin/main HARNESS="$d/h" \
      bash -c '
        set -uo pipefail
        STAMP() { echo TS; }
        RESULT() { printf "%s\n" "$1" > "$BUILD/RESULT"; }
        escalate_block() { printf "%s\n%s\n" "$1" "$2" > "$BUILD/escalate"; }
        PREPR_SECTION=""
        if [ -n "${SETV+x}" ]; then setting_get() { printf "%s" "$SETV"; }; fi
        . "$0"
        echo "$PREPR_SECTION" > "$BUILD/section"
        echo PUSH_REACHED
      ' "$T/span.sh" > "$d/out.txt" 2>&1; echo $? )
}
calls()  { cat "$T/$1/calls" 2>/dev/null; }
pushed() { grep -q PUSH_REACHED "$T/$1/out.txt"; }

# D1: no file, the fetch writes one
mk d1 writes; RC=$(spanrun d1)
[ "$RC" = 0 ] && pushed d1 && ok || bad "D1: exit $RC, want 0 and the push: $(cat "$T/d1/out.txt")"
grep -qx 'fetch fetch --out catalog/ci-suite-durations.tsv' "$T/d1/calls" 2>/dev/null && ok \
  || bad "D1: the fetch did not get 'fetch --out catalog/ci-suite-durations.tsv': $(calls d1)"
[ "$(sed -n 1p "$T/d1/calls" 2>/dev/null | cut -d' ' -f1)" = fetch ] && ok || bad "D1: the fetch did not run before the gate: $(calls d1)"
grep -qx saw-file "$T/d1/calls" 2>/dev/null && ok || bad "D1: the gate did not see the durations file"
grep -q $'^fast-lints\tgreen' "$T/d1/build/prepush-gate/summary.tsv" 2>/dev/null && ok || bad "D1: fast-lints is not green"
grep -q could-not-run "$T/d1/build/section" && bad "D1: the PR section names could-not-run: $(cat "$T/d1/build/section")" || ok
grep -q 'PREPUSH-GATE durations fetch rc=0 file=present' "$T/d1/build/pipeline.log" 2>/dev/null && ok \
  || bad "D1: no 'durations fetch rc=0 file=present' line: $(cat "$T/d1/build/pipeline.log" 2>/dev/null)"

# D2: the fetch fails
mk d2 fails; RC=$(spanrun d2)
[ "$RC" = 0 ] && pushed d2 && ok || bad "D2: exit $RC, want 0 and the push: $(cat "$T/d2/out.txt")"
grep -q '^fetch ' "$T/d2/calls" 2>/dev/null && ok || bad "D2: the fetch was not called"
grep -q $'^fast-lints\tcould-not-run' "$T/d2/build/prepush-gate/summary.tsv" 2>/dev/null && ok || bad "D2: fast-lints is not could-not-run"
grep -q 'could-not-run.*fast-lints' "$T/d2/build/section" && ok || bad "D2: the PR section does not name fast-lints could-not-run"
grep -q 'PREPUSH-GATE durations fetch rc=1 file=absent' "$T/d2/build/pipeline.log" 2>/dev/null && ok \
  || bad "D2: no 'durations fetch rc=1 file=absent' line: $(cat "$T/d2/build/pipeline.log" 2>/dev/null)"

# D3: the fetch hangs, bound 2 s
mk d3 hangs; S0=$(date +%s); RC=$(PREPUSH_DURATIONS_FETCH_S=2 spanrun d3); EL=$(( $(date +%s) - S0 ))
[ "$EL" -lt 15 ] && ok || bad "D3: the span took ${EL}s with a 2 s bound"
[ "$RC" = 0 ] && pushed d3 && ok || bad "D3: exit $RC, want 0 and the push: $(cat "$T/d3/out.txt")"
grep -q '^fetch ' "$T/d3/calls" 2>/dev/null && ok || bad "D3: the fetch was not called"
grep -q $'^fast-lints\tcould-not-run' "$T/d3/build/prepush-gate/summary.tsv" 2>/dev/null && ok || bad "D3: fast-lints is not could-not-run"
grep -q 'durations fetch rc=[1-9][0-9]* file=absent' "$T/d3/build/pipeline.log" 2>/dev/null && ok || bad "D3: no failed-fetch line in pipeline.log"

# D4: the file is present; D4b: a 0-byte file is present
mk d4 writes; printf '# source: old\nsuite\tseconds\ntests/y.sh\t4\n' > "$T/d4/co/catalog/ci-suite-durations.tsv"; RC=$(spanrun d4)
grep -q '^fetch ' "$T/d4/calls" 2>/dev/null && bad "D4: the fetch ran with the file present" || ok
[ "$RC" = 0 ] && grep -q $'^fast-lints\tgreen' "$T/d4/build/prepush-gate/summary.tsv" 2>/dev/null && ok || bad "D4: exit $RC or fast-lints not green"
mk d4b writes; : > "$T/d4b/co/catalog/ci-suite-durations.tsv"; RC=$(spanrun d4b)
grep -q '^fetch ' "$T/d4b/calls" 2>/dev/null && bad "D4b: the fetch ran with a 0-byte file present" || ok
[ "$RC" = 0 ] && pushed d4b && ok || bad "D4b: exit $RC, want 0 and the push"

# D5: no bin/ci-durations.sh
mk d5 none; RC=$(spanrun d5)
[ "$RC" = 0 ] && pushed d5 && ok || bad "D5: exit $RC, want 0 and the push: $(cat "$T/d5/out.txt")"
grep -qx run "$T/d5/calls" 2>/dev/null && ok || bad "D5: the gate did not run"
grep -q 'durations fetch' "$T/d5/build/pipeline.log" 2>/dev/null && bad "D5: a fetch line with no fetch script" || ok
grep -qi 'command not found\|no such file' "$T/d5/out.txt" && bad "D5: an error: $(cat "$T/d5/out.txt")" || ok

# D6: gate mode off -> no fetch; the fetch is not a gate component
mk d6 writes; RC=$(SETV=off spanrun d6)
[ "$RC" = 0 ] && pushed d6 && ok || bad "D6: exit $RC, want 0 and the push"
[ -e "$T/d6/calls" ] && bad "D6: something ran with gate mode off: $(calls d6)" || ok
L=$(bash "$DIR/bin/prepush-gate.sh" --list 2>&1); LRC=$?
[ "$LRC" = 0 ] && ok || bad "D6: bin/prepush-gate.sh --list rc $LRC"
grep -q ci-durations <<<"$L" && bad "D6: the gate table names ci-durations: $(grep ci-durations <<<"$L")" || ok

echo "prepush-durations-fetch (BH-7210): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
