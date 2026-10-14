#!/bin/bash
# tests/test-tiers-quarantine.bh-3686-test.sh — the batch side of flaky
# quarantine (BH-3699, the BH-3686.1 slice): bin/test-tiers.sh --quarantine
# drops a flaky suite from the merge-queue batch and hands it to the nightly
# run, bin/ci-plan.sh turns the repo variable CI_QUARANTINE into that flag, and
# the two workflows carry the variable as env only.
#
# THE FAILURE TO FEAR is a batch that silently tests less: a guard, a protected
# suite, a junk token or a broken contract lib must never shorten it, and an
# unset variable must change nothing at all. So every "no" case here is a
# byte-for-byte or suite-by-suite check against the run without the flag.
#
#   Q1  batch drops a quarantined batch/no-row suite, says so, counts it
#   Q2  nightly adds it
#   Q3  guard / named / glob / unreadable-protected-list: refused, kept
#   Q4  `-`, empty, blank-only: byte-identical to no flag
#   Q5  missing list: nothing dropped, one line; junk tokens ignored
#   Q6  a broken join still hands back the whole batch (FAIL-SAFE), rc 2 nightly
#   Q7  check validates the protected list
#   Q8  no bin/lib/test-protected.sh: every quarantine refused, said once
#   Q9  --help documents it on both scripts
#   C1-C4  bin/ci-plan.sh normalises CI_QUARANTINE and writes quarantine=
#   C5  the workflows pass it as env only
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TT="$DIR/bin/test-tiers.sh"
PLAN="$DIR/bin/ci-plan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
cnt() { grep -cF -- "$1" <<<"$2"; }

# ── fixtures ──────────────────────────────────────────────────────────────
printf 'tests/a-test.sh\tbatch\t5\t-\tr\ntests/g-test.sh\tguard\t5\tbin/x.sh\tr\ntests/n-test.sh\tnightly\t5\t-\tr\n' > "$T/tiers.tsv"
printf 'tests/p-test.sh  pinned\ntests/*keep*  glob\n' > "$T/prot.txt"
printf 'tests/a-test.sh\ntests/b-test.sh\ntests/c-test.sh\n' > "$T/abc"
printf 'tests/b-test.sh\n' > "$T/qb"
BASE=(--tiers "$T/tiers.tsv" --protected "$T/prot.txt")

tt() { # tt <stdin-file> <args...> — sets RC, OUT, ERR
  local in="$1"; shift
  OUT=$(bash "$TT" "$@" < "$in" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
}

# ── Q1. batch drops a quarantined, unprotected no-row suite.
tt "$T/abc" batch "${BASE[@]}" --quarantine "$T/qb"
[ "$RC" = 0 ] && [ "$OUT" = "$(printf 'tests/a-test.sh\ntests/c-test.sh')" ] && ok \
  || bad "Q1: b must be dropped and a, c kept in order (rc=$RC): $OUT"
has "tiers: quarantine tests/b-test.sh — out of the batch (flaky; the nightly runs it)" "$ERR" && ok \
  || bad "Q1: the drop must be said: $ERR"
[ "$(grep '^tiers: batch — ' <<<"$ERR" | grep -c ', 1 quarantined$')" = 1 ] && ok \
  || bad "Q1: the summary must end ', 1 quarantined': $ERR"

# ── Q2. nightly adds it; without the flag it does not.
tt "$T/abc" nightly "${BASE[@]}" --quarantine "$T/qb"
{ [ "$RC" = 0 ] && grep -qx 'tests/b-test.sh' <<<"$OUT"; } && ok || bad "Q2: nightly must run quarantined b (rc=$RC): $OUT"
tt "$T/abc" nightly "${BASE[@]}"
grep -qx 'tests/b-test.sh' <<<"$OUT" && bad "Q2: without --quarantine b is not nightly: $OUT" || ok

# ── Q3. protected suites are refused, never dropped.
printf 'tests/g-test.sh\ntests/p-test.sh\ntests/x-keep-test.sh\n' > "$T/gpx"
tt "$T/gpx" batch "${BASE[@]}" --quarantine "$T/gpx"
[ "$OUT" = "$(cat "$T/gpx")" ] && ok || bad "Q3: guard, named and glob suites must all stay: $OUT"
[ "$(grep -c '^tiers: quarantine refused for .* — protected (' <<<"$ERR")" = 3 ] && ok \
  || bad "Q3: three refusal lines expected: $ERR"
for why in "guard tier" "named list" "named glob tests/*keep*"; do
  has "protected ($why)" "$ERR" && ok || bad "Q3: reason '$why' missing: $ERR"
done
has "quarantined" "$(grep '^tiers: batch — ' <<<"$ERR")" && bad "Q3: nothing was quarantined: $ERR" || ok
tt "$T/abc" batch --tiers "$T/tiers.tsv" --protected "$T/missing" --quarantine "$T/qb"
{ grep -qx 'tests/b-test.sh' <<<"$OUT" && has "protected (protected list unreadable)" "$ERR"; } && ok \
  || bad "Q3: an unreadable protected list protects everything: $OUT / $ERR"

# ── Q4. `-`, an empty file and a blank-only file are byte-identical to no flag.
bash "$TT" batch "${BASE[@]}" < "$T/abc" > "$T/ref.out" 2> "$T/ref.err"
: > "$T/empty"; printf '  \n\n\t\n' > "$T/blank"
for q in - "$T/empty" "$T/blank"; do
  bash "$TT" batch "${BASE[@]}" --quarantine "$q" < "$T/abc" > "$T/q.out" 2> "$T/q.err"
  { cmp -s "$T/ref.out" "$T/q.out" && cmp -s "$T/ref.err" "$T/q.err"; } && ok \
    || bad "Q4: --quarantine '$q' must change nothing: $(cat "$T/q.out" "$T/q.err")"
done

# ── Q5. an unreadable list quarantines nothing and says it once; junk is ignored.
tt "$T/abc" batch "${BASE[@]}" --quarantine "$T/nope"
{ [ "$OUT" = "$(cat "$T/abc")" ] && [ "$(grep -c '^tiers: quarantine list ' <<<"$ERR")" = 1 ]; } && ok \
  || bad "Q5: a missing list drops nothing, one line: $OUT / $ERR"
if [ "$(id -u)" != 0 ]; then
  printf 'tests/b-test.sh\n' > "$T/q000"; chmod 000 "$T/q000"
  tt "$T/abc" batch "${BASE[@]}" --quarantine "$T/q000"
  { [ "$OUT" = "$(cat "$T/abc")" ] && [ "$(grep -c '^tiers: quarantine list ' <<<"$ERR")" = 1 ]; } && ok \
    || bad "Q5: an unreadable list drops nothing: $OUT / $ERR"
fi
printf 'bin/x.sh junk\ntests/b-test.sh\n' > "$T/qjunk"
tt "$T/abc" batch "${BASE[@]}" --quarantine "$T/qjunk"
[ "$OUT" = "$(printf 'tests/a-test.sh\ntests/c-test.sh')" ] && ok || bad "Q5: b must still drop past junk: $OUT"
[ "$(grep -c "^tiers: quarantine token '.*' ignored — not a tests/ suite" <<<"$ERR")" = 2 ] && ok \
  || bad "Q5: two ignored lines expected: $ERR"
printf 'tests/*.sh tests/../tests/a-test.sh\n' > "$T/qglob"
tt "$T/abc" batch "${BASE[@]}" --quarantine "$T/qglob"
[ "$OUT" = "$(cat "$T/abc")" ] && ok || bad "Q5: a glob or ../ token must quarantine nothing: $OUT"
[ "$(grep -c "^tiers: quarantine token '.*' ignored — not a tests/ suite" <<<"$ERR")" = 2 ] && ok \
  || bad "Q5: a glob and a ../ token are each ignored out loud: $ERR"

# ── Q6. a broken join hands the WHOLE batch back, b included; nightly is rc 2.
printf '#!/bin/bash\nawk "$@" | head -1\n' > "$T/awk-truncates"; chmod +x "$T/awk-truncates"  # determinism: ok race-sigpipe-echo printf writes a stub; the pipe is awk | head inside it, and the stub exists to truncate
OUT=$(TEST_TIERS_AWK="$T/awk-truncates" bash "$TT" batch "${BASE[@]}" --quarantine "$T/qb" < "$T/abc" 2>"$T/err"); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = "$(cat "$T/abc")" ] && grep -q 'FAIL-SAFE' "$T/err"; } && ok \
  || bad "Q6: the fail-safe must return a, b and c (rc=$RC): $OUT / $(cat "$T/err")"
TEST_TIERS_AWK="$T/awk-truncates" bash "$TT" nightly "${BASE[@]}" --quarantine "$T/qb" < "$T/abc" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "Q6: a broken nightly join is rc 2 (rc=$RC)"

# ── Q7. check validates the protected list.
printf 'tests/zz-nothing-*  r\n' > "$T/bad-glob.txt"
printf 'tests/test-tiers-test.sh\n' > "$T/no-reason.txt"
printf 'tests/nope-test.sh  r\n' > "$T/missing-path.txt"
for f in bad-glob no-reason missing-path; do
  bash "$TT" check --protected "$T/$f.txt" > "$T/ck" 2>&1; RC=$?
  [ "$RC" = 1 ] && ok || bad "Q7: check --protected $f.txt must be rc 1 (rc=$RC): $(cat "$T/ck")"
done
bash "$TT" check --protected "$T/missing" > "$T/ck" 2>&1; RC=$?
[ "$RC" != 0 ] && ok || bad "Q7: an unreadable protected list fails check"
bash "$TT" check > "$T/ck" 2>&1; RC=$?
{ [ "$RC" = 0 ] && grep -q 'protected line(s) ok' "$T/ck"; } && ok || bad "Q7: the shipped files must check clean (rc=$RC): $(cat "$T/ck")"

# ── Q8. no contract lib: every quarantine is refused, and said once.
mkdir -p "$T/nolib/bin"; cp "$TT" "$T/nolib/bin/test-tiers.sh"
OUT=$(bash "$T/nolib/bin/test-tiers.sh" batch "${BASE[@]}" --quarantine "$T/qb" < "$T/abc" 2>"$T/err"); ERR=$(cat "$T/err")
[ "$OUT" = "$(cat "$T/abc")" ] && ok || bad "Q8: without the lib b must stay: $OUT"
[ "$(grep -c 'quarantine refused — bin/lib/test-protected.sh could not be loaded' <<<"$ERR")" = 1 ] && ok \
  || bad "Q8: one refusal line expected: $ERR"
OUT=$(bash "$T/nolib/bin/test-tiers.sh" nightly "${BASE[@]}" --quarantine "$T/qb" < "$T/abc" 2>/dev/null)
grep -qx 'tests/b-test.sh' <<<"$OUT" && bad "Q8: without the lib nightly adds nothing: $OUT" || ok

# ── Q9. both scripts document it.
has "QUARANTINE" "$(bash "$TT" --help)" && ok || bad "Q9: test-tiers --help must document QUARANTINE"
has "CI_QUARANTINE" "$(bash "$PLAN" --help)" && ok || bad "Q9: ci-plan --help must document CI_QUARANTINE"

# ── C. bin/ci-plan.sh. S is a real suite with no tier row that tp_protected
# does not protect, picked now so the case never pins a file that moves.
. "$DIR/bin/lib/test-protected.sh" || { bad "C: cannot source bin/lib/test-protected.sh"; exit 1; }
S=""
for f in $(cd "$DIR" && ls tests/*.sh); do
  cut -f1 "$DIR/catalog/test-tiers.tsv" | grep -qxF -- "$f" && continue
  tp_protected "$f" "$DIR" >/dev/null && continue
  S="$f"; break
done
[ -n "$S" ] || { bad "C: no unprotected, untiered real suite to quarantine — the C cases would check nothing"; exit 1; }
printf 'tests/a-test.sh\n%s\ntests/c-test.sh\n' "$S" > "$T/all.txt"
# c is nightly, so the nightly plan is never empty and the batch always drops one.
printf 'tests/c-test.sh\tnightly\t5\t-\tr\n' > "$T/ctiers.tsv"
cat > "$T/fake-impact.sh" <<'FAKE'
#!/bin/bash
OUT=""; while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; esac; shift; done
N=$(grep -c . "$FAKE_ALL"); echo "impact: $N of $N suites (fake)" >&2
cat "$FAKE_ALL" > "$OUT"
FAKE
chmod +x "$T/fake-impact.sh"
plan() { # plan <VAR=value ...> [-- args] — sets RC, OUT, GO
  rm -f "$T/go" "$T/list"
  OUT=$(env CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_ALL="$T/all.txt" CI_PLAN_TIER_FILE="$T/ctiers.tsv" \
          CI_PLAN_CHANGED_FILE="$T/empty" GITHUB_OUTPUT="$T/go" "$@" "$PLAN" --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
nplan() { # the nightly plan
  rm -f "$T/go" "$T/list"
  OUT=$(env CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_ALL="$T/all.txt" CI_PLAN_TIER_FILE="$T/ctiers.tsv" \
          GITHUB_OUTPUT="$T/go" "$@" "$PLAN" --tier nightly --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
MQ=(CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/x)

# C1. a batch drops S, and the output is S once.
plan "${MQ[@]}" CI_QUARANTINE="$S $S"
{ [ "$RC" = 0 ] && [ "$(cat "$T/list")" = "tests/a-test.sh" ]; } && ok \
  || bad "C1: the batch must drop $S (rc=$RC): $(cat "$T/list" 2>/dev/null) / $OUT"
[ "$(out quarantine)" = "$S" ] && ok || bad "C1: quarantine= must be '$S' deduped: '$(out quarantine)'"
has "tiers: quarantine $S — out of the batch" "$OUT" && ok || bad "C1: the drop must reach the log: $OUT"
# C1b. junk and globs are never expanded or kept.
plan "${MQ[@]}" CI_QUARANTINE="tests/*.sh bin/x.sh tests/does-not-exist-test.sh $S"
[ "$(out quarantine)" = "$S" ] && ok || bad "C1b: only the real suite survives: '$(out quarantine)'"
plan "${MQ[@]}" CI_QUARANTINE="tests/*.sh"
{ [ "$(out quarantine)" = "-" ] && [ "$(cat "$T/list")" = "$(printf 'tests/a-test.sh\n%s' "$S")" ]; } && ok \
  || bad "C1b: a glob alone quarantines nothing: '$(out quarantine)' $(cat "$T/list")"
# C2. unset: the full list and quarantine=-.
plan "${MQ[@]}"
{ [ "$RC" = 0 ] && [ "$(cat "$T/list")" = "$(printf 'tests/a-test.sh\n%s' "$S")" ] && [ "$(out quarantine)" = "-" ]; } && ok \
  || bad "C2: unset changes nothing (rc=$RC, quarantine='$(out quarantine)'): $(cat "$T/list")"
# C2b. the push corpus=0 path writes quarantine= too.
printf '#!/bin/bash\necho %s\n' "'{\"workflow_runs\":[]}'" > "$T/fake-gh"; chmod +x "$T/fake-gh"
plan CI_EVENT=push CI_ACTOR='mergify[bot]' CI_PLAN_GH="$T/fake-gh" CI_REPO=o/r CI_SHA=s0 \
     CI_PLAN_SETTLE_S=0 CI_PLAN_MAIN_HEAD_CMD="echo s9" CI_QUARANTINE="$S"
{ [ "$RC" = 0 ] && [ "$(out corpus)" = 0 ] && [ "$(out quarantine)" = "$S" ]; } && ok \
  || bad "C2b: corpus=0 must still write quarantine= (rc=$RC corpus=$(out corpus)): $GO / $OUT"
# C3. the nightly plan adds S.
nplan CI_QUARANTINE="$S"
{ [ "$RC" = 0 ] && grep -qxF -- "$S" "$T/list" && [ "$(out quarantine)" = "$S" ]; } && ok \
  || bad "C3: the nightly must run $S (rc=$RC): $(cat "$T/list" 2>/dev/null) / $OUT"
nplan
{ [ "$RC" = 0 ] && [ "$(cat "$T/list")" = "tests/c-test.sh" ]; } && ok || bad "C3: without CI_QUARANTINE only c is nightly (rc=$RC): $(cat "$T/list" 2>/dev/null)"
# C4. an ordinary PR still runs S.
plan CI_EVENT=pull_request TI_PR_HEAD_REF=ticket/x FAKE_SELECT="$T/all.txt" CI_QUARANTINE="$S"
{ [ "$RC" = 0 ] && grep -qxF -- "$S" "$T/list"; } && ok || bad "C4: an ordinary PR still runs $S (rc=$RC): $OUT"

# ── C5. the workflows carry it as env only (parsed YAML, not a grep).
python3 - "$DIR/.github/workflows/harness-ci.yml" "$DIR/.github/workflows/harness-nightly.yml" > "$T/c5" 2>&1 <<'PY'
import sys, yaml
bad = []
for f in sys.argv[1:]:
    jobs = yaml.safe_load(open(f))["jobs"]
    plan_job = None
    for name, job in jobs.items():
        for st in job.get("steps", []):
            run, env = str(st.get("run", "")), st.get("env") or {}
            if "quarantine }}" in run:
                bad.append(f"{f}: {name}: a run: interpolates the quarantine")
            if "bin/ci-plan.sh" not in run:
                continue
            if st.get("id") == "plan":
                plan_job = name
                if env.get("CI_QUARANTINE") != "${{ vars.CI_QUARANTINE }}":
                    bad.append(f"{f}: {name}: the plan step's CI_QUARANTINE is {env.get('CI_QUARANTINE')!r}")
            elif env.get("CI_QUARANTINE") != "${{ needs.plan.outputs.quarantine }}":
                bad.append(f"{f}: {name}: a re-plan's CI_QUARANTINE is {env.get('CI_QUARANTINE')!r}")
    if plan_job is None:
        bad.append(f"{f}: no plan step")
    elif (jobs[plan_job].get("outputs") or {}).get("quarantine") != "${{ steps.plan.outputs.quarantine }}":
        bad.append(f"{f}: the plan job does not export quarantine")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
[ "$?" = 0 ] && ok || bad "C5: $(cat "$T/c5")"

echo "test-tiers-quarantine: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
