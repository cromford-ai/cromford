#!/bin/bash
# tests/prequeue-invariants.bh-5429-test.sh — BH-5438 (#5429 child 0): the
# pre-queue gate runs the whole-repo invariant suites on every head.
#
# The 2026-10-08 incident: .github/workflows/prequeue-gate.yml ran only
# bin/test-impact-gate.sh, whose map never selects a suite that scans the whole
# tree (share-mirror-clean, lanes-registry, ...). A head that broke one got a
# green pre-queue verdict and the merge batch was the first thing to run it.
#
#   C1      catalog/prequeue-invariants.tsv: 17 rows, 5 TAB columns, and
#           the runner refuses a bad catalog with rc 2 before running anything
#   C5-C8   bin/prequeue-invariants.sh --run on stub suites: red, fail lines
#           (redacted, cut at 300), over budget reported not killed, the total
#           line, a missing suite is red
#   C6b     --overrides id=off|<n>, a malformed item is ignored
#   K1      a cmd row never reaches a shell
#   E1      HARNESS_TEST_SANDBOX=1 and RATCHET_BASE=$PQ_MAIN reach every row
#   E2      pq_gate exports PQ_PATH; pq_dispatch appends pq_invariants_args
#   G1      a gitleaks suite with no installable pinned gitleaks is rc 125
#   D1-D5   a dry run of the workflow's real verdict step (the BH-4548 W shape)
#   A1-A4   the REAL invariant suites: tests/prequeue-invariants-real.bh-5429-test.sh
#           (apart, so the retired tests/trap-target-safety-test.sh did not run
#           them nested; BH-5541 removed that guard)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-invariants.bh-5429-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

SCRIPT="$DIR/bin/prequeue-invariants.sh"
CATALOG="$DIR/catalog/prequeue-invariants.tsv"
WF="$DIR/.github/workflows/prequeue-gate.yml"
DISPATCH_LIB="$DIR/bin/lib/mc-prequeue.d/dispatch.sh"
# TEST-CHANGE (BH-5591): two new cmd rows, render-doc-sections and
# worker-jobs-schema, so 14 rows; the ids and two pins below follow.
# TEST-CHANGE (BH-6335): three new suite rows, flag-callsites-pool,
# mc-split-layout and gh-rest-no-subshell, so 17 rows.
IDS="share-mirror-clean share-publish-clean lanes-registry config-inventory rules-pack-contract hold-push-ratchet gh-graphql-reads-lint pr-trailers-sites scratch-closure determinism triage-state-pr-contract pr-scoped-tests render-doc-sections worker-jobs-schema flag-callsites-pool mc-split-layout gh-rest-no-subshell"
NL=$'\n'
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }
has() { [[ "$1" == *"$2"* ]]; }

# ============================================================================
# C1. The real catalog.
# ============================================================================
[ -r "$CATALOG" ] || bad "C1: catalog/prequeue-invariants.tsv is missing"
crows() { grep -v '^#' "$CATALOG" 2>/dev/null | grep -v '^$'; }
# TEST-CHANGE (BH-5591): 12 -> 14 rows. TEST-CHANGE (BH-6335): 14 -> 17 rows.
[ "$(crows | wc -l)" = 17 ] && ok || bad "C1: 17 non-comment rows (got $(crows | wc -l))"
[ "$(crows | awk -F'\t' 'NF != 5' | wc -l)" = 0 ] && ok || bad "C1: every row has 5 TAB fields"
[ "$(crows | cut -f1 | tr '\n' ' ')" = "$IDS " ] && ok || bad "C1: the ids, in order (got '$(crows | cut -f1 | tr '\n' ' ')')"
CBAD=""
while IFS=$'\t' read -r id kind argv budget guards; do
  case "$kind" in
    suite) [ -f "$DIR/$argv" ] || CBAD="$CBAD $id(no $argv)" ;;
    cmd) [ -f "$DIR/${argv%% *}" ] || CBAD="$CBAD $id(no ${argv%% *})" ;;
    *) CBAD="$CBAD $id(kind $kind)" ;;
  esac
  [[ "$budget" =~ ^[1-9][0-9]*$ ]] || CBAD="$CBAD $id(budget $budget)"
  [ -n "$guards" ] || CBAD="$CBAD $id(no guards)"
done < <(crows)
[ -z "$CBAD" ] && [ -r "$CATALOG" ] && ok || bad "C1: every kind is suite|cmd, every argv exists, every budget is a positive integer:$CBAD"
[ "$(crows | awk -F'\t' '$1 == "determinism" { print $2 " " $3 }')" = "cmd bin/test-determinism-lint.sh" ] && ok \
  || bad "C1: determinism is the cmd row bin/test-determinism-lint.sh"
[ "$(crows | awk -F'\t' '$1 == "pr-scoped-tests" { print $2 " " $3 }')" = "cmd bin/pr-scoped-test-lint.sh" ] && ok \
  || bad "C1: pr-scoped-tests is the cmd row bin/pr-scoped-test-lint.sh (BH-5684)"
# TEST-CHANGE (BH-5591): pins for the two new cmd rows.
[ "$(crows | awk -F'\t' '$1 == "render-doc-sections" { print $2 " " $3 }')" = "cmd bin/render-doc-sections.sh --check" ] && ok \
  || bad "C1: render-doc-sections is the cmd row bin/render-doc-sections.sh --check (BH-5591)"
[ "$(crows | awk -F'\t' '$1 == "worker-jobs-schema" { split($3, a, " "); print $2 " " a[1] }')" = "cmd bin/prequeue-worker-schema.sh" ] && ok \
  || bad "C1: worker-jobs-schema is a cmd row whose argv[0] is bin/prequeue-worker-schema.sh (BH-5591)"

# The scratch tree the runner cases drive: the REAL runner and the REAL
# bin/test-suite-run.sh, stub suites under $R/tests.
R="$T/r"; mkdir -p "$R/tests" "$R/bin"
if [ -f "$SCRIPT" ]; then
  scratch_install_closure bin/prequeue-invariants.sh "$R" >/dev/null || bad "setup: could not install bin/prequeue-invariants.sh"
else
  bad "setup: bin/prequeue-invariants.sh is missing"
fi
scratch_install_closure bin/test-suite-run.sh "$R" >/dev/null || bad "setup: could not install bin/test-suite-run.sh"
scratch_install_closure bin/ci-tool-present.sh "$R" >/dev/null || bad "setup: could not install bin/ci-tool-present.sh"
RUN="$R/bin/prequeue-invariants.sh"
# inv <case> <catalog body> [args...] — the real runner; $T/<case>.{out,err,rc}, DIR $T/<case>.d
inv() {
  local c="$1"; printf '%s' "$2" > "$T/$c.tsv"; shift 2
  ( cd "$T" && env -u PQ_MAIN -u RATCHET_BASE ${INV_ENV:-} bash "$RUN" --run --catalog "$T/$c.tsv" --out "$T/$c.d" "$@" ) > "$T/$c.out" 2> "$T/$c.err"
  echo $? > "$T/$c.rc"
}
rc() { cat "$T/$1.rc" 2>/dev/null; }
nlog() { find "$T/$1.d/log" -type f 2>/dev/null | wc -l; }

printf '#!/bin/bash\necho fine\nexit 0\n' > "$R/tests/green.sh"
GOOD=$(row green suite tests/green.sh 5 "a green stub")

# C1 refusals: rc 2 and nothing run.
for c in "4col:$(printf 'green\tsuite\ttests/green.sh\t5\n')" \
         "6col:$(printf 'green\tsuite\ttests/green.sh\t5\tg\textra\n')" \
         "dup:$GOOD${NL}$GOOD" \
         "kind:$(row green shell tests/green.sh 5 g)" \
         "frac:$(row green suite tests/green.sh 1.5 g)" \
         "dotdot:$(row green suite tests/../tests/green.sh 5 g)" \
         "noguard:$(printf 'green\tsuite\ttests/green.sh\t5\t\n')" \
         "badid:$(row Green suite tests/green.sh 5 g)"; do
  n="${c%%:*}"; inv "c1-$n" "${c#*:}"$'\n'
  [ "$(rc "c1-$n")" = 2 ] && ok || bad "C1 $n: a bad catalog exits 2 (rc $(rc "c1-$n"); err $(cat "$T/c1-$n.err"))"
  [ -d "$T/c1-$n.d/log" ] && bad "C1 $n: nothing runs on a bad catalog (a log/ exists)" || ok
done
has "$(cat "$T/c1-6col.err")" "bad catalog line 1" && ok || bad "C1: the refusal names the line (got '$(cat "$T/c1-6col.err")')"
inv c1-off "$GOOD"$'\n' --overrides green=off
[ "$(rc c1-off)" = 2 ] && [ ! -d "$T/c1-off.d/log" ] && ok || bad "C1 every row off: an empty set exits 2 (rc $(rc c1-off))"
( cd "$T" && bash "$RUN" --run --out "$T/c1-nocat.d" ) > /dev/null 2>&1; NC=$?
[ "$NC" = 2 ] && [ ! -d "$T/c1-nocat.d/log" ] && ok || bad "C1 no --catalog: exits 2 (rc $NC)"
# The real catalog parses: with every row off it is an empty set (rc 2), never a bad line.
ALLOFF=$(crows | cut -f1 | sed 's/$/=off/' | paste -sd, -)
( cd "$T" && bash "$RUN" --run --catalog "$CATALOG" --out "$T/c1-real.d" --overrides "$ALLOFF" ) > /dev/null 2> "$T/c1-real.err"; RRC=$?
[ "$RRC" = 2 ] && ! has "$(cat "$T/c1-real.err")" "bad catalog" && ok \
  || bad "C1: the real catalog parses (rc $RRC: $(cat "$T/c1-real.err"))"

# ============================================================================
# C5. A red stub: rc 1, fail lines, redaction, 300-char cut.
# ============================================================================
# Token shapes are assembled at run time: written whole they would be a hit for
# the share-mirror and gitleaks scans of this very file.
TOK_GHP=$(printf 'gh%s_%s' p "$(printf 'A%.0s' $(seq 36))")
TOK_PAT=$(printf 'github%s_%s' _pat 11ABCDEFG0123456789_abcdefghij)
TOK_SKA=$(printf 'sk-%s-%s' ant api03-Zz9-Yy8_Xx7)
TOK_BRR=$(printf 'beare%s.%s' rval abc123def456)
LONG=$(printf 'x%.0s' $(seq 400))
{ echo '#!/bin/bash'
  echo 'echo "noise before"'
  printf 'echo %q\n' "FAIL: one $TOK_GHP here" "FAIL: two $TOK_PAT" "FAIL: three $TOK_SKA" \
    "FAIL: four Authorization: Bearer $TOK_BRR end" "FAIL: five $LONG" \
    "FAIL: six" "FAIL: seven" "FAIL: eight" "FAIL: nine" "FAIL: ten"
  echo 'exit 1'; } > "$R/tests/red.sh"
inv c5 "$(row red suite tests/red.sh 30 "a red stub")"$'\n'
D5D="$T/c5.d"
[ "$(rc c5)" = 1 ] && ok || bad "C5: a red row exits 1 (rc $(rc c5); $(cat "$T/c5.err"))"
[ "$(cat "$D5D/failed.txt" 2>/dev/null)" = red ] && ok || bad "C5: failed.txt is the id (got '$(cat "$D5D/failed.txt" 2>/dev/null)')"
FT=$(cat "$D5D/fail/red.txt" 2>/dev/null)
[ "$(grep -c . <<<"$FT")" = 8 ] && ok || bad "C5: fail/red.txt is the first 8 FAIL lines (got $(grep -c . <<<"$FT"): $FT)"
[ "$(head -n1 <<<"$FT" | cut -c1-9)" = "FAIL: one" ] && [ "$(tail -n1 <<<"$FT")" = "FAIL: eight" ] && ok \
  || bad "C5: fail/red.txt runs FAIL: one .. FAIL: eight (got $FT)"
LEAK=""
for k in "$TOK_GHP" "$TOK_PAT" "$TOK_SKA" "$TOK_BRR"; do has "$FT" "$k" && LEAK="$LEAK ${k:0:6}"; done
[ -z "$LEAK" ] && ok || bad "C5: no raw token in fail/red.txt:$LEAK"
[ "$(grep -o REDACTED <<<"$FT" | wc -l)" = 4 ] && ok || bad "C5: each of the 4 token shapes is REDACTED (got $FT)"
[ "$(awk 'length > 300' <<<"$FT" | wc -l)" = 0 ] && ok || bad "C5: no fail line over 300 chars"
[ -s "$D5D/log/red.log" ] && has "$(cat "$D5D/log/red.log")" "noise before" && ok || bad "C5: log/red.log holds the suite's output"
[ "$(cat "$D5D/suites.txt" 2>/dev/null)" = tests/red.sh ] && ok || bad "C5: a red suite that ran is in suites.txt (got '$(cat "$D5D/suites.txt" 2>/dev/null)')"
grep -qx 'prequeue-invariant: red rc=1 [0-9]*s budget 30s' "$T/c5.out" && ok || bad "C5: the row line (got $(cat "$T/c5.out"))"
# No FAIL line: the last 8 lines of the log.
{ echo '#!/bin/bash'; echo 'for i in $(seq 20); do echo "noise $i"; done'; echo 'exit 1'; } > "$R/tests/noisy.sh"
inv c5n "$(row noisy suite tests/noisy.sh 30 "a red stub with no FAIL line")"$'\n'
[ "$(rc c5n)" = 1 ] && [ -s "$T/c5n.d/fail/noisy.txt" ] && [ "$(cat "$T/c5n.d/fail/noisy.txt")" = "$(tail -n8 "$T/c5n.d/log/noisy.log")" ] \
  && has "$(cat "$T/c5n.d/fail/noisy.txt")" "noise 20" && [ "$(grep -c . "$T/c5n.d/fail/noisy.txt")" = 8 ] && ok \
  || bad "C5 noisy: no FAIL line gives the log's last 8 lines (got '$(cat "$T/c5n.d/fail/noisy.txt" 2>/dev/null)')"

# ============================================================================
# C6. Over budget: reported, never killed, never red for being slow.
# ============================================================================
cat > "$R/tests/slow.sh" <<'SH'
#!/bin/bash
end=$((SECONDS + 3)); while [ "$SECONDS" -lt "$end" ]; do :; done
touch "$SLOW_MARK"
echo done
SH
SLOWROW=$(row slow suite tests/slow.sh 1 "a busy-wait stub")
INV_ENV="SLOW_MARK=$T/c6.mark" inv c6 "$SLOWROW"$'\n'
[ "$(rc c6)" = 0 ] && ok || bad "C6: slow is not red (rc $(rc c6))"
grep -qE '^prequeue-invariant: slow rc=0 [0-9]+s budget 1s OVER BUDGET$' "$T/c6.out" && ok || bad "C6: the row line says OVER BUDGET (got $(cat "$T/c6.out"))"
[ -e "$T/c6.mark" ] && ok || bad "C6: the slow suite ran to the end (never killed)"
[ "$(cut -f1,2,5 "$T/c6.d/timings.tsv" 2>/dev/null)" = "slow	0	yes" ] && ok || bad "C6: timings.tsv says over=yes (got '$(cat "$T/c6.d/timings.tsv" 2>/dev/null)')"
# C6b. --overrides.
INV_ENV="SLOW_MARK=$T/c6b.mark" inv c6b "$SLOWROW"$'\n' --overrides slow=10
[ "$(rc c6b)" = 0 ] && grep -qE '^prequeue-invariant: slow rc=0 [0-9]+s budget 10s$' "$T/c6b.out" && ok \
  || bad "C6b: slow=10 raises the budget, no OVER BUDGET (got $(cat "$T/c6b.out"))"
inv c6c "$GOOD${NL}$SLOWROW"$'\n' --overrides slow=off
[ "$(rc c6c)" = 0 ] && [ ! -e "$T/c6c.d/log/slow.log" ] && [ -e "$T/c6c.d/log/green.log" ] && ok \
  || bad "C6b: slow=off drops the row (rc $(rc c6c), logs $(ls "$T/c6c.d/log" 2>/dev/null | tr '\n' ' '))"
INV_ENV="SLOW_MARK=$T/c6d.mark" inv c6d "$SLOWROW"$'\n' --overrides slow=fast,nope=3,slow
[ "$(rc c6d)" = 0 ] && grep -qE '^prequeue-invariant: slow rc=0 [0-9]+s budget 1s OVER BUDGET$' "$T/c6d.out" && ok \
  || bad "C6b: malformed and unknown items change nothing (got $(cat "$T/c6d.out"))"
[ "$(grep -c . "$T/c6d.err")" -ge 3 ] && ok || bad "C6b: each ignored item gets a stderr note (got $(cat "$T/c6d.err"))"

# ============================================================================
# C7. The total line.
# ============================================================================
INV_ENV="SLOW_MARK=$T/c7.mark" inv c7 "$GOOD${NL}$(row red suite tests/red.sh 30 r)${NL}$SLOWROW"$'\n'
[ "$(rc c7)" = 1 ] && ok || bad "C7: one red row makes rc 1 (rc $(rc c7))"
TOT=$(tail -n1 "$T/c7.out")
grep -qE '^prequeue-invariants: total [0-9]+s wall [0-9]+s \(3 run, 1 red\) OVER BUDGET: slow$' <<<"$TOT" && ok || bad "C7: the total line (got '$TOT')"
SUM=$(awk -F'\t' '{ s += $3 } END { print s + 0 }' "$T/c7.d/timings.tsv" 2>/dev/null)
[ "${TOT#prequeue-invariants: total }" != "$TOT" ] && [ "$(sed -E 's/^prequeue-invariants: total ([0-9]+)s.*/\1/' <<<"$TOT")" = "$SUM" ] && ok \
  || bad "C7: total equals the sum of timings.tsv column 3 ($SUM)"
[ "$(tr '\n' ' ' < "$T/c7.d/suites.txt" 2>/dev/null)" = "tests/green.sh tests/red.sh tests/slow.sh " ] && ok \
  || bad "C7: suites.txt holds the 3 paths (got '$(cat "$T/c7.d/suites.txt" 2>/dev/null)')"
# A green run leaves the three files present and empty.
inv c7g "$GOOD"$'\n'
[ "$(rc c7g)" = 0 ] && [ -f "$T/c7g.d/failed.txt" ] && [ ! -s "$T/c7g.d/failed.txt" ] && [ -s "$T/c7g.d/timings.tsv" ] && ok \
  || bad "C7: a green run: rc 0, failed.txt present and empty (rc $(rc c7g))"

# ============================================================================
# C8. A suite missing from the tree is red, not skipped.
# ============================================================================
inv c8 "$GOOD${NL}$(row gone suite tests/gone.sh 5 "a suite that is not there")"$'\n'
[ "$(rc c8)" = 1 ] && ok || bad "C8: a missing suite is red (rc $(rc c8))"
[ "$(cat "$T/c8.d/fail/gone.txt" 2>/dev/null)" = "suite missing on the merged tree" ] && ok || bad "C8: the missing line (got '$(cat "$T/c8.d/fail/gone.txt" 2>/dev/null)')"
[ "$(cat "$T/c8.d/failed.txt" 2>/dev/null)" = gone ] && ok || bad "C8: failed.txt names it"
[ "$(cat "$T/c8.d/suites.txt" 2>/dev/null)" = tests/green.sh ] && ok || bad "C8: a missing suite is not in suites.txt (got '$(cat "$T/c8.d/suites.txt" 2>/dev/null)')"

# ============================================================================
# K1. A cmd row is split on spaces and never reaches a shell.
# ============================================================================
printf '#!/bin/bash\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "$K1_ARGS"\n' > "$R/bin/echo-args.sh"
mkdir -p "$T/k1cwd"
INV_ENV="K1_ARGS=$T/k1.args" inv k1 "$(row echo cmd 'bin/echo-args.sh a;touch PWNED $(id)' 5 "argv probe")"$'\n'
[ "$(rc k1)" = 0 ] && [ "$(tr '\n' '|' < "$T/k1.args" 2>/dev/null)" = 'a;touch|PWNED|$(id)|' ] && ok \
  || bad "K1: the args arrive literally (rc $(rc k1), args '$(tr '\n' '|' < "$T/k1.args" 2>/dev/null)')"
[ -z "$(find "$T" "$R" -name PWNED 2>/dev/null)" ] && ok || bad "K1: no PWNED file was created"

# ============================================================================
# E1. The env every row sees.
# ============================================================================
printf '#!/bin/bash\necho "sandbox=${HARNESS_TEST_SANDBOX:-unset} base=${RATCHET_BASE-unset}" > "$E1_OUT"\n' > "$R/tests/env.sh"
E1M=$(printf 'e%.0s' $(seq 40))
INV_ENV="E1_OUT=$T/e1a.txt PQ_MAIN=$E1M HARNESS_TEST_SANDBOX=0" inv e1a "$(row env suite tests/env.sh 5 "env probe")"$'\n'
[ "$(cat "$T/e1a.txt" 2>/dev/null)" = "sandbox=1 base=$E1M" ] && ok || bad "E1: HARNESS_TEST_SANDBOX=1 RATCHET_BASE=\$PQ_MAIN (got '$(cat "$T/e1a.txt" 2>/dev/null)')"
INV_ENV="E1_OUT=$T/e1b.txt" inv e1b "$(row env suite tests/env.sh 5 "env probe")"$'\n'
[ "$(cat "$T/e1b.txt" 2>/dev/null)" = "sandbox=1 base=unset" ] && ok || bad "E1: no PQ_MAIN, no RATCHET_BASE (got '$(cat "$T/e1b.txt" 2>/dev/null)')"

# ============================================================================
# G1. A suite that needs gitleaks, and the pinned one cannot be had: rc 125.
# ============================================================================
no_gitleaks_path() {
  local out="" d i=0 f
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    i=$((i+1))
    if [ -e "$d/gitleaks" ]; then
      mkdir -p "$T/shadow/$i"
      for f in "$d"/*; do
        [ "${f##*/}" = gitleaks ] || ln -sf "$f" "$T/shadow/$i/" 2>/dev/null
      done
      d="$T/shadow/$i"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}
NOGL=$(no_gitleaks_path)
mkdir -p "$T/glcache" "$T/glstub"
echo "not a tarball" > "$T/glcache/gitleaks_8.30.1_linux_x64.tar.gz"
printf '#!/bin/bash\nexit 22\n' > "$T/glstub/curl"; chmod +x "$T/glstub/curl"
printf '#!/bin/bash\ncommand -v gitleaks >/dev/null || exit 1\necho ok\n' > "$R/tests/needs-gl.sh"
GLROW=$(row needs-gl suite tests/needs-gl.sh 5 "uses gitleaks")
INV_ENV="PATH=$T/glstub:$NOGL GITLEAKS_PIN_CACHE=$T/glcache" inv g1 "$GOOD${NL}$GLROW"$'\n'
[ "$(rc g1)" = 125 ] && ok || bad "G1: no installable gitleaks is rc 125 (rc $(rc g1); err $(cat "$T/g1.err"))"
has "$(cat "$T/g1.err")" gitleaks && ok || bad "G1: the stderr line names gitleaks (got '$(cat "$T/g1.err")')"
[ "$(nlog g1)" = 0 ] && ok || bad "G1: nothing ran (logs: $(ls "$T/g1.d/log" 2>/dev/null))"

# ============================================================================
# E2. The conductor hooks: PQ_PATH, and pq_invariants_args.
# ============================================================================
E2S=example-org/demo-os; E2H=$(printf 'a%.0s' $(seq 40)); E2M=$(printf 'c%.0s' $(seq 40)); E2O=$(printf 'd%.0s' $(seq 40))
# e2 <name> <body> — source the real tracer (and its hooks) with stubbed reads, run body.
e2() {
  ( export MC_STATE_DIR="$T/e2-$1/state" MC_H="$T/e2-$1/h" GH_ARGV="$T/e2-$1/gh.argv"
    mkdir -p "$MC_STATE_DIR" "$MC_H/locks" "$T/e2-$1/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$GH_ARGV"\n' > "$T/e2-$1/bin/gh"; chmod +x "$T/e2-$1/bin/gh"
    PATH="$T/e2-$1/bin:$PATH"
    mc_rest_var() { case "$*" in *"/commits/"*) printf -v "$1" '{"sha":"%s"}' "$E2M" ;; *) printf -v "$1" '{}' ;; esac; return 0; }
    mc_log() { :; }; mc_use_token() { :; }; mc_safe_name() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
    . "$DIR/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 9
    eval "$2" ) > "$T/e2-$1.out" 2>&1
}
e2 own 'pq_cache_put "$(pq_key "$E2S" 7 "$E2H" "$E2M")" red 1 - tests/a.sh
  pq_gate "$E2S" 7 u "$E2H" main >/dev/null
  [ "$PQ_VERDICT" = red ] && [ "${PQ_PATH-}" = "$(pq_key "$E2S" 7 "$E2H" "$E2M")" ] && echo E2OK || echo "verdict=$PQ_VERDICT path=${PQ_PATH-unset}"'
[ "$(tail -n1 "$T/e2-own.out")" = E2OK ] && ok || bad "E2: a cached red sets PQ_PATH to its own key (got $(cat "$T/e2-own.out"))"
e2 sib 'pq_cache_put "$(pq_key "$E2S" 7 "$E2H" "$E2O")" red "$(date +%s)" 77 tests/b.sh
  pq_gate "$E2S" 7 u "$E2H" main >/dev/null
  [ "$PQ_VERDICT" = red ] && [ "${PQ_PATH-}" = "$(pq_key "$E2S" 7 "$E2H" "$E2O")" ] && echo E2OK || echo "verdict=$PQ_VERDICT path=${PQ_PATH-unset}"'
[ "$(tail -n1 "$T/e2-sib.out")" = E2OK ] && ok || bad "E2: a fresh-sibling red sets PQ_PATH to the sibling's file (got $(cat "$T/e2-sib.out"))"
e2 args 'pq_invariants_args() { echo -f invariants=x; }
  pq_dispatch "$E2S" 7 "$E2H" "$E2M"; echo "rc=$?"'
has "$(cat "$T/e2-args/gh.argv" 2>/dev/null)" "-f main=$E2M -f invariants=x" && ok \
  || bad "E2: with suites empty pq_dispatch appends pq_invariants_args (argv '$(cat "$T/e2-args/gh.argv" 2>/dev/null)'; $(cat "$T/e2-args.out"))"
e2 named 'pq_invariants_args() { echo -f invariants=x; }
  pq_dispatch "$E2S" 7 "$E2H" "$E2M" tests/a.sh fp1; echo "rc=$?"'
A2V=$(cat "$T/e2-named/gh.argv" 2>/dev/null)
[ -n "$A2V" ] && ! has "$A2V" invariants && has "$A2V" "suites=tests/a.sh" && ok || bad "E2: named suites carry no invariants args (argv '$A2V')"
e2 undef 'pq_dispatch "$E2S" 7 "$E2H" "$E2M"; echo "rc=$?"'
[ "$(cat "$T/e2-undef/gh.argv" 2>/dev/null)" = "workflow run prequeue-gate.yml -R $E2S --ref main -f pr=7 -f head=$E2H -f main=$E2M" ] && ok \
  || bad "E2: no pq_invariants_args, the argv is unchanged (got '$(cat "$T/e2-undef/gh.argv" 2>/dev/null)')"

# ============================================================================
# D1-D5. A dry run of the workflow's real verdict step.
# ============================================================================
python3 - "$WF" "$T/w" <<'PY' || bad "D: the workflow must parse and carry its verdict step"
import sys, yaml, os
wf = yaml.safe_load(open(sys.argv[1]))
os.makedirs(sys.argv[2], exist_ok=True)
step = [s for s in wf["jobs"]["gate"]["steps"] if s.get("id") == "verdict"][0]
open(sys.argv[2] + "/run.sh", "w").write(step["run"])
PY
O="$T/origin.git"; S="$T/seed"
git init -q --bare "$O"; git init -q "$S"
sg() { git -C "$S" -c user.email=t@example.com -c user.name=t "$@"; }
mkdir -p "$S/bin" "$S/tests" "$S/catalog"
if [ -f "$SCRIPT" ]; then scratch_install_closure bin/prequeue-invariants.sh "$S" >/dev/null || bad "D setup: install the runner"; fi
scratch_install_closure bin/test-suite-run.sh "$S" >/dev/null || bad "D setup: install test-suite-run"
scratch_install_closure bin/ci-tool-present.sh "$S" >/dev/null || bad "D setup: install ci-tool-present"
cat > "$S/bin/test-impact-gate.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" > "$GATE_ARGV"
f=""; while [ $# -gt 0 ]; do [ "$1" = --failed ] && f="$2"; shift; done
[ -n "$f" ] && printf '%s' "${STUB_FAILED:-}" > "$f"
exit "${STUB_RC:-0}"
SH
# The share-mirror-clean stub: red when any tracked file holds the fixture
# identifier, which it assembles at run time so it never matches itself.
cat > "$S/tests/share-mirror-clean-test.sh" <<'SH'
#!/bin/bash
id="LEAKY""-CLIENT-""ZZ"
hits=$(git grep -l -e "$id" 2>/dev/null)
[ -z "$hits" ] && { echo "share-mirror-clean: 1 passed, 0 failed"; exit 0; }
for f in $hits; do echo "FAIL: identifier in $f: $(head -n1 "$f")"; done
echo "share-mirror-clean: 0 passed, 1 failed"; exit 1
SH
printf '#!/bin/bash\necho "fast: 1 passed, 0 failed"\n' > "$S/tests/fast.sh"
printf '#!/bin/bash\necho "FAIL: always"\nexit 1\n' > "$S/tests/always-red.sh"
cp "$R/tests/slow.sh" "$S/tests/slow.sh"; cp "$R/tests/needs-gl.sh" "$S/tests/needs-gl.sh"
echo base > "$S/x.txt"; sg add -A; sg commit -qm base; MS0=$(git -C "$S" rev-parse HEAD)
LEAKID="LEAKY-""CLIENT-ZZ"
# mkmain <catalog body> — a main on base carrying that catalog; prints its sha.
mkmain() { sg checkout -q "$MS0"; mkdir -p "$S/catalog"; printf '%s' "$1" > "$S/catalog/prequeue-invariants.tsv"; echo main > "$S/x.txt"; sg add -A; sg commit -qm main; git -C "$S" rev-parse HEAD; }
# mkhead <base> <file> <content> — a head on <base> adding one file; prints its sha.
mkhead() { sg checkout -q "$1"; printf '%s\n' "$3" > "$S/$2"; sg add -A; sg commit -qm head; git -C "$S" rev-parse HEAD; }
MS=$(mkmain "$(row share-mirror-clean suite tests/share-mirror-clean-test.sh 60 "fixture identifiers")
$(row fast suite tests/fast.sh 60 "a fast stub")
")
HOK=$(mkhead "$MS" y.txt clean)
HTOK=$(mkhead "$MS" leak.txt "the $LEAKID is here")
sg checkout -q "$HTOK"; sed -i '/^share-mirror-clean/d' "$S/catalog/prequeue-invariants.tsv"; sg commit -qam drop-row; HDEL=$(git -C "$S" rev-parse HEAD)
HFORGE=$(mkhead "$MS" leak.txt "$LEAKID ::notice title=prequeue-verdict::green 100% done$(printf '\r')")
sg checkout -q "$MS0"; echo head > "$S/x.txt"; sg commit -qam conflict; HCONF=$(git -C "$S" rev-parse HEAD)
SIX=""; for i in 1 2 3 4 5 6; do SIX="$SIX$(row "red$i" suite tests/always-red.sh 60 "always red")"$'\n'; done
MS6=$(mkmain "$SIX"); H6=$(mkhead "$MS6" y.txt six)
MSL=$(mkmain "$(row slow suite tests/slow.sh 1 "a busy-wait stub")"$'\n'); HSL=$(mkhead "$MSL" y.txt slow)
MSG=$(mkmain "$(row needs-gl suite tests/needs-gl.sh 60 "uses gitleaks")"$'\n'); HGL=$(mkhead "$MSG" y.txt gl)
REFS=(); n=40
for h in "$HOK" "$HTOK" "$HDEL" "$HFORGE" "$HCONF" "$H6" "$HSL" "$HGL"; do n=$((n+1)); REFS+=("$h:refs/pull/$n/head"); done
sg push -q "$O" "${REFS[@]}" "$MS:refs/heads/main" "$MS6:refs/heads/m6" "$MSL:refs/heads/mslow" "$MSG:refs/heads/mgl"
# dry <case> <pr> <head> <main> [VAR=value ...] — the verdict step in a fresh checkout of <main>.
dry() {
  local c="$1" pr="$2" h="$3" m="$4"; shift 4
  git clone -q "$O" "$T/wd-$c" 2>/dev/null; git -C "$T/wd-$c" checkout -q "$m"
  mkdir -p "$T/rt-$c"
  ( cd "$T/wd-$c" && env PQ_PR="$pr" PQ_HEAD="$h" PQ_MAIN="$m" PQ_SUITES_IN="" RUNNER_TEMP="$T/rt-$c" \
      GATE_ARGV="$T/gate-$c" SLOW_MARK="$T/mark-$c" "$@" bash "$T/w/run.sh" ) > "$T/out-$c" 2>&1
  echo "rc=$?" >> "$T/out-$c"
}
# outside <case> — the lines printed outside the ::stop-commands:: window.
outside() {
  awk '/^::stop-commands::/ { tok = substr($0, 18); off = 1; next }
       off && $0 == "::" tok "::" { off = 0; next }
       !off { print }' "$T/out-$1"
}
verdict() { outside "$1" | sed -n 's/^::notice title=prequeue-verdict:://p'; }
nann() { outside "$1" | grep -c "^::$2 title=$3::"; }
annot() { outside "$1" | sed -n "s/^::$2 title=$3:://p"; }
dry d1 41 "$HOK" "$MS0"
dry d2 42 "$HTOK" "$MS"
dry d2b 43 "$HDEL" "$MS"
dry d2c 44 "$HFORGE" "$MS"
dry d2d 42 "$HTOK" "$MS" STUB_RC=1 STUB_FAILED=tests/fast.sh
dry d2e 46 "$H6" "$MS6"
dry d3 41 "$HOK" "$MS"
dry d4 47 "$HSL" "$MSL"
dry d5n 41 "$HOK" "$MS" PQ_SUITES_IN=tests/fast.sh
dry d5c 45 "$HCONF" "$MS"
dry d5g 48 "$HGL" "$MSG" PATH="$T/glstub:$NOGL" GITLEAKS_PIN_CACHE="$T/glcache"
for c in d1 d2 d2b d2c d2d d2e d3 d4 d5n d5c d5g; do
  [ "$(verdict "$c" | grep -c .)" = 1 ] && ok || bad "D $c: exactly one verdict outside the window (got: $(tr '\n' '|' < "$T/out-$c"))"
  grep -qx 'rc=0' "$T/out-$c" && ok || bad "D $c: the step exits 0 ($(tail -n1 "$T/out-$c"))"
done
# D1. No catalog on main: today's behaviour, byte for byte.
[ "$(verdict d1)" = "green main=$MS0 head=$HOK suites=" ] && ok || bad "D1: green (got '$(verdict d1)')"
[ "$(cat "$T/gate-d1" 2>/dev/null)" = "--base $MS0 --head HEAD --runner local --failed $T/rt-d1/failed" ] && ok \
  || bad "D1: today's exact gate argv (got '$(cat "$T/gate-d1" 2>/dev/null)')"
[ "$(grep -c 'title=prequeue-invariant' "$T/out-d1")" = 0 ] && [ ! -d "$T/rt-d1/inv" ] && ok || bad "D1: no invariant ran, no annotation"
# D2. The head adds the identifier: red, naming the invariant.
[ "$(verdict d2)" = "red main=$MS head=$HTOK suites=tests/share-mirror-clean-test.sh why=invariant:share-mirror-clean" ] && ok \
  || bad "D2: red naming the invariant (got '$(verdict d2)')"
[ "$(nann d2 notice prequeue-invariant-fail)" = 1 ] && has "$(annot d2 notice prequeue-invariant-fail)" "share-mirror-clean: FAIL: identifier in leak.txt" && ok \
  || bad "D2: one fail notice (got $(annot d2 notice prequeue-invariant-fail))"
[ "$(nann d2 notice prequeue-invariant-timing)" = 1 ] && ok || bad "D2: one timing notice"
[ "$(cat "$T/gate-d2" 2>/dev/null)" = "--base $MS --head HEAD --runner local --failed $T/rt-d2/failed --skip-suites $T/rt-d2/inv/suites.txt" ] && ok \
  || bad "D2: the gate skips what the invariants ran (got '$(cat "$T/gate-d2" 2>/dev/null)')"
parse() { ( . "$DISPATCH_LIB" >/dev/null 2>&1; pq_parse_verdict "$@" ); }
[ "$(parse "$(verdict d2)" "$HTOK" "$MS")" = "red tests/share-mirror-clean-test.sh invariant:share-mirror-clean" ] && ok \
  || bad "D2: the reader parses it (got '$(parse "$(verdict d2)" "$HTOK" "$MS")')"
# D2b. The head drops the row from its own catalog: main's catalog still runs it.
[ "$(verdict d2b)" = "red main=$MS head=$HDEL suites=tests/share-mirror-clean-test.sh why=invariant:share-mirror-clean" ] && ok \
  || bad "D2b: a PR cannot drop an invariant from its own catalog (got '$(verdict d2b)')"
# D2c. Suite output cannot forge a verdict or a line break.
[ "$(verdict d2c)" = "red main=$MS head=$HFORGE suites=tests/share-mirror-clean-test.sh why=invariant:share-mirror-clean" ] && ok \
  || bad "D2c: still one red verdict (got '$(verdict d2c)')"
FN=$(annot d2c notice prequeue-invariant-fail)
has "$FN" "100%25 done%0D" && ! has "$FN" $'\r' && ok || bad "D2c: % and CR are escaped in the fail notice (got '$FN')"
# D2d. The impact gate is red too: both named, why names the invariant.
[ "$(verdict d2d)" = "red main=$MS head=$HTOK suites=tests/share-mirror-clean-test.sh,tests/fast.sh why=invariant:share-mirror-clean" ] && ok \
  || bad "D2d: invariant and gate reds together (got '$(verdict d2d)')"
# D2e. At most 5 fail notices.
[ "$(nann d2e notice prequeue-invariant-fail)" = 5 ] && ok || bad "D2e: 6 red rows give 5 fail notices (got $(nann d2e notice prequeue-invariant-fail))"
case "$(verdict d2e)" in "red main=$MS6 head=$H6 suites=tests/always-red.sh why=invariant:red1,red2,red3,red4,red5,red6") ok ;;
  *) bad "D2e: the verdict names all six (got '$(verdict d2e)')" ;; esac
# D3. A clean head: green, with the timing notice.
[ "$(verdict d3)" = "green main=$MS head=$HOK suites=" ] && ok || bad "D3: green (got '$(verdict d3)')"
[ "$(nann d3 notice prequeue-invariant-timing)" = 1 ] && grep -qE '^prequeue-invariants: total [0-9]+s wall' <<<"$(annot d3 notice prequeue-invariant-timing)" && ok \
  || bad "D3: one timing notice (got '$(annot d3 notice prequeue-invariant-timing)')"
[ "$(nann d3 notice prequeue-invariant-fail)" = 0 ] && ok || bad "D3: no fail notice"
has "$(cat "$T/gate-d3" 2>/dev/null)" "--skip-suites $T/rt-d3/inv/suites.txt" && ok || bad "D3: --skip-suites on the gate (got '$(cat "$T/gate-d3" 2>/dev/null)')"
# D4. Over budget: green, one slow warning naming it.
[ "$(verdict d4)" = "green main=$MSL head=$HSL suites=" ] && ok || bad "D4: slow is still green (got '$(verdict d4)')"
[ "$(nann d4 warning prequeue-invariant-slow)" = 1 ] && grep -qE '^slow [0-9]+s over budget 1s$' <<<"$(annot d4 warning prequeue-invariant-slow)" && ok \
  || bad "D4: one slow warning naming the row (got '$(annot d4 warning prequeue-invariant-slow)')"
# D5. Named mode, conflict, and gitleaks that cannot be installed.
[ "$(verdict d5n)" = "green main=$MS head=$HOK suites=" ] && [ ! -d "$T/rt-d5n/inv" ] && [ "$(grep -c 'title=prequeue-invariant' "$T/out-d5n")" = 0 ] && ok \
  || bad "D5: named suites run no invariants (got '$(verdict d5n)')"
[ "$(verdict d5c)" = "conflict main=$MS head=$HCONF suites=" ] && [ ! -d "$T/rt-d5c/inv" ] && ok || bad "D5: a conflict runs no invariants (got '$(verdict d5c)')"
[ "$(verdict d5g)" = "could-not-run main=$MSG head=$HGL suites= why=invariants-rc-125" ] && ok || bad "D5: gitleaks unavailable is could-not-run (got '$(verdict d5g)')"

echo "prequeue-invariants.bh-5429: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
