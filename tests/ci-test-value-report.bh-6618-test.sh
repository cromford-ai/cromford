#!/bin/bash
# tests/ci-test-value-report.bh-6618-test.sh — BH-6640 (BH-6618.4): the extra
# sources and the report of the CI test value report. ctv_fetch_sources reads
# three jobs-worker aggregates (GET only) and the suite list on disk into
# <out>/cache/. The renderer writes ci-test-value.json (suites, lists, totals,
# sources), ci-test-value.html and summary-ste.md.
#
# Every case runs in place from this checkout with HARNESS=$T/h and a `curl`
# shim first on PATH. The shim serves tests/fixtures/bh-6618/report/worker/ and
# refuses (rc 99, one line in a refusals file) any call that is not a GET.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO_DIR/bin/lib/ci-test-value.sh"
SOURCES="$REPO_DIR/bin/lib/ci-test-value/sources.sh"
RENDER="$REPO_DIR/bin/lib/ci-test-value-render.py"
FIX="$REPO_DIR/tests/fixtures/bh-6618/report"

FAILS=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}
for f in "$LIB" "$SOURCES" "$RENDER"; do [ -f "$f" ] || bad "missing source file ${f#"$REPO_DIR"/}"; done

# ── the curl shim ───────────────────────────────────────────────────────────
mkdir -p "$T/bin" "$T/h/logs"
cat > "$T/bin/curl" <<'SHIM'
#!/bin/bash
# The jobs worker client (bin/lib/jobs/req.sh) sends `-X <method>` and `-w`
# '\n%{http_code}'. A GET of a known route prints its fixture and 200;
# SHIM_FAIL=<path> answers 503. Anything that is not a GET is refused.
log="${SHIM_LOG:?}"; m=GET prev= url=
for a in "$@"; do
  case "$prev" in -X|--request) m="$a" ;; esac
  case "$a" in -d|--data*|-F|--form|-T|--upload-file) echo "REFUSED curl data" >> "$log.refused"; exit 99 ;; esac
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
[ "$m" = GET ] || { echo "REFUSED curl $m $url" >> "$log.refused"; exit 99; }
echo "GET $url" >> "$log"
p=${url#http://*/}; p="/${p%%\?*}"
if [ -n "${SHIM_FAIL:-}" ] && [ "$p" = "$SHIM_FAIL" ]; then printf '{"error":"fixture 503"}\n503'; exit 0; fi
case "$p" in
  /api/ci/suite-durations) f=suite-durations.json ;;
  /api/suite-results/passes) f=suite-passes.json ;;
  /api/metrics/flakes) f=flakes.json ;;
  *) printf '\n404'; exit 0 ;;
esac
cat "${SHIM_FIX:?}/$f"; printf '\n200'
SHIM
chmod +x "$T/bin/curl"

# fetch <case> [env NAME=V ...]: ctv_fetch_sources $T/<case> in a subshell,
# with the window start and repo the driver sets. rc in RC.
RC=0
fetch() {
  local c="$1"; shift
  mkdir -p "$T/$c"
  RC=0
  env PATH="$T/bin:$PATH" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 HARNESS_SECRET=secret-fixture-ctv \
    JOBS_URL=http://192.0.2.10:8787 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 SHIM_LOG="$T/$c.curl" \
    SHIM_FIX="$FIX/worker" "$@" \
    bash -c '. "$1" || exit 70; CTV_REPO=example-org/cromford FROM=2026-09-15; ctv_fetch_sources "$2"' \
    _ "$LIB" "$T/$c" > "$T/$c.out" 2> "$T/$c.err" || RC=$?
}
# outdir <case> [coverage file]: a render input dir from the fixtures.
outdir() {
  local o="$T/$1"
  mkdir -p "$o/cache"
  cp "$FIX/occurrences.tsv" "$o/occurrences.tsv"
  cp "$FIX/${2:-coverage.json}" "$o/coverage.json"
  cp "$FIX/worker/suite-durations.json" "$FIX/worker/suite-passes.json" "$FIX/worker/flakes.json" "$o/cache/"
  cp "$FIX/suites-on-disk.txt" "$o/cache/suites-on-disk.txt"
  printf '%s\n' "$o"
}
render() { # render <out>: rc in RC
  RC=0
  python3 -I "$RENDER" "$1" "$1/day" > "$1.render.out" 2> "$1.render.err" || RC=$?
}
q() { jq -r "$2" "$1/day/ci-test-value.json" 2>/dev/null; } # q <out> <filter>

# ── AT-9a: three GETs, three cache files ────────────────────────────────────
fetch a9a
check "AT-9a ctv_fetch_sources is rc 0" 0 "$RC"
for n in suite-durations suite-passes flakes; do
  [ -s "$T/a9a/cache/$n.json" ] && ok "AT-9a cache/$n.json written" || bad "AT-9a cache/$n.json missing"
done
cmp -s "$T/a9a/cache/suite-passes.json" "$FIX/worker/suite-passes.json" && ok "AT-9a suite-passes.json is the worker body" || bad "AT-9a suite-passes.json differs from the worker body"
[ -e "$T/a9a.curl.refused" ] && bad "AT-9a the curl shim refused: $(cat "$T/a9a.curl.refused")" || ok "AT-9a 0 refused (non-GET) calls"
check "AT-9a three worker GETs" 3 "$(grep -c '^GET ' "$T/a9a.curl" 2>/dev/null)"
grep -q '^GET http://192.0.2.10:8787/api/suite-results/passes?repo=example-org%2Fcromford&since=2026-09-15$' "$T/a9a.curl" \
  && ok "AT-9a the passes read names the repo and the window start" || bad "AT-9a passes URL: $(cat "$T/a9a.curl")"
grep -q '^GET http://192.0.2.10:8787/api/metrics/flakes?repo=example-org%2Fcromford&since=2026-09-15&limit=2000$' "$T/a9a.curl" \
  && ok "AT-9a the flakes read names the repo, the window start and limit 2000" || bad "AT-9a flakes URL: $(cat "$T/a9a.curl")"
check "AT-9a no stdout" "" "$(cat "$T/a9a.out")"

# ── AT-9b: a 503 leaves that file absent, the rest are read ────────────────
fetch a9b SHIM_FAIL=/api/ci/suite-durations
check "AT-9b ctv_fetch_sources is rc 0 on a 503" 0 "$RC"
[ -e "$T/a9b/cache/suite-durations.json" ] && bad "AT-9b suite-durations.json exists after a 503" || ok "AT-9b suite-durations.json absent after a 503"
[ -s "$T/a9b/cache/suite-passes.json" ] && [ -s "$T/a9b/cache/flakes.json" ] && ok "AT-9b the other two are written" || bad "AT-9b the other two are missing"
grep -q '^ctv: source suite_durations unread' "$T/a9b.err" && ok "AT-9b stderr names the unread source" || bad "AT-9b stderr: $(cat "$T/a9b.err")"
# A file from an earlier run is not trusted: the failed read removes it.
echo '{"rows":[]}' > "$T/a9b/cache/suite-durations.json"
fetch a9b SHIM_FAIL=/api/ci/suite-durations
[ -e "$T/a9b/cache/suite-durations.json" ] && bad "AT-9b a stale suite-durations.json survives a failed read" || ok "AT-9b a stale file is removed by a failed read"
# A body of the wrong shape is unread too.
mkdir -p "$T/fix-bad"; cp "$FIX"/worker/*.json "$T/fix-bad/"; echo '{"flakes":"no"}' > "$T/fix-bad/flakes.json"
fetch a9b2 SHIM_FIX="$T/fix-bad"
[ -e "$T/a9b2/cache/flakes.json" ] && bad "AT-9b a bad-shape flakes body was kept" || ok "AT-9b a bad-shape flakes body leaves the file absent"
# No worker configured: every worker source unread, rc 0, no curl call.
fetch a9b3 JOBS_URL=
check "AT-9b JOBS_URL empty: rc 0" 0 "$RC"
check "AT-9b JOBS_URL empty: no worker file" "" "$(ls "$T/a9b3/cache" 2>/dev/null | grep json)"
# An out dir that does not exist: rc 0, nothing created.
RC=0; ( . "$LIB" && ctv_fetch_sources "$T/no-such-dir" ) > /dev/null 2>&1 || RC=$?
check "AT-9b a missing out dir: rc 0" 0 "$RC"
[ -e "$T/no-such-dir" ] && bad "AT-9b a missing out dir was created" || ok "AT-9b a missing out dir is not created"

# ── AT-9c: the suite list on disk, then a render of the fetched dir ─────────
D9="$T/a9a/cache/suites-on-disk.txt"
grep -qx 'tests/ci-test-value.bh-6618-test.sh' "$D9" && ok "AT-9c the contract suite is on the disk list" || bad "AT-9c the contract suite is not on the disk list"
grep -q '^tests/mc/[^/]*\.sh$' "$D9" && ok "AT-9c a tests/mc suite is listed" || bad "AT-9c no tests/mc suite"
grep -q '^worker/jobs/test/.*\.test\.js$' "$D9" && ok "AT-9c a worker/jobs test is listed" || bad "AT-9c no worker/jobs test"
grep -q '^tests/lib/' "$D9" && bad "AT-9c a tests/lib path is listed" || ok "AT-9c no tests/lib path"
grep -q '^tests/fixtures/' "$D9" && bad "AT-9c a fixture path is listed" || ok "AT-9c no tests/fixtures path"
check "AT-9c the list is sorted and unique" "" "$(LC_ALL=C sort -u "$D9" | cmp -s - "$D9" || echo unsorted)"
cp "$FIX/occurrences.tsv" "$FIX/coverage.json" "$T/a9a/"
render "$T/a9a"
check "AT-9c render of the fetched dir is rc 0" 0 "$RC"
check "AT-9c ci_seconds = 42 x 7 end to end" 294 "$(q "$T/a9a" '.suites[] | select(.suite == "tests/false-only.bh-6618-fixture.sh") | .ci_seconds')"

# ── AT-9d: the JSON fields ──────────────────────────────────────────────────
O=$(outdir main); render "$O"
check "AT-9d render rc 0" 0 "$RC"
check "AT-9d every suites[] row has every field" true \
  "$(q "$O" '[.suites[] | has("suite") and has("ledger_runs") and has("runs_source") and has("seen_runs") and has("failures") and has("real") and has("false") and has("ci_seconds") and has("ci_seconds_source") and has("last_real_catch")] | (length > 0) and all')"
check "AT-9d no job: unit in suites[]" 0 "$(q "$O" '[.suites[] | select(.suite | startswith("job:"))] | length')"
check "AT-9d failures.unknown counted" 2 "$(q "$O" '.suites[] | select(.suite == "tests/unknown-only.bh-6618-fixture.sh") | .failures.unknown')"
check "AT-9d real-pr suite: real 1 false 1" "1 1" "$(q "$O" '.suites[] | select(.suite == "tests/real-pr.bh-6618-fixture.sh") | "\(.real) \(.false)"')"
check "AT-9d real-main suite: real 1 (real-main) false 1 (order), seen_runs 2 (two attempts)" "1 1 2" \
  "$(q "$O" '.suites[] | select(.suite == "tests/real-main.bh-6618-fixture.sh") | "\(.real) \(.false) \(.seen_runs)"')"
check "AT-9d ledger_runs = passes + fails" 50 "$(q "$O" '.suites[] | select(.suite == "tests/real-pr.bh-6618-fixture.sh") | .ledger_runs')"
check "AT-9d ledger_runs 0 for a read source with no row" 0 "$(q "$O" '.suites[] | select(.suite == "tests/never-ran.bh-6618-fixture.sh") | .ledger_runs')"
check "AT-9d runs_source names the window start" "suite-results passes+fails since 2026-09-15" \
  "$(q "$O" '.suites[] | select(.suite == "tests/real-pr.bh-6618-fixture.sh") | .runs_source')"
check "AT-9d last_real_catch is the day of the real row" 2026-10-01 "$(q "$O" '.suites[] | select(.suite == "tests/real-pr.bh-6618-fixture.sh") | .last_real_catch')"
check "AT-9d last_real_catch null with no real row" null "$(q "$O" '.suites[] | select(.suite == "tests/false-only.bh-6618-fixture.sh") | .last_real_catch')"
check "AT-9d ci_seconds null with no median" null "$(q "$O" '.suites[] | select(.suite == "tests/p17.bh-6618-fixture.sh") | .ci_seconds')"
check "AT-9d unattributed[0] is the job: unit" "job:harness-ci / lint 1" "$(q "$O" '.unattributed[0] | "\(.unit) \(.occurrences)"')"
check "AT-9d totals" "3 3 1 10" "$(q "$O" '.totals | "\(.red_runs) \(.red_runs_read) \(.unattributed_units) \(.occurrences)"')"
check "AT-9d totals.pct_by_class: unknown 30%, real-pr 10%" true "$(q "$O" '.totals.pct_by_class | .unknown == 30 and .["real-pr"] == 10')"
check "AT-9d sources has the six names, all read" "coverage:true flakes:true occurrences:true suite_durations:true suite_passes:true suites_on_disk:true" \
  "$(q "$O" '.sources | to_entries | map("\(.key):\(.value.read)") | join(" ")')"
check "AT-9d sources.flakes.rows" 2 "$(q "$O" '.sources.flakes.rows')"
check "AT-9d contract keys kept" "true true true true" \
  "$(q "$O" '"\(has("rules")) \(has("coverage")) \(has("window")) \(.totals | has("by_class"))"')"
check "AT-9d slugs are unique" "$(q "$O" '.suites | length')" "$(q "$O" '[.suites[].slug] | unique | length')"

# ── AT-9e: zero real with false ─────────────────────────────────────────────
check "AT-9e zero_real_with_false is the false-only suites, false desc" \
  "tests/false-only.bh-6618-fixture.sh tests/false-one.bh-6618-fixture.sh" "$(q "$O" '.lists.zero_real_with_false | join(" ")')"

# ── AT-9f: expensive zero real ──────────────────────────────────────────────
check "AT-9f expensive_zero_real is cut at 20" 20 "$(q "$O" '.lists.expensive_zero_real | length')"
check "AT-9f more than 20 candidates exist" true "$(q "$O" '[.suites[] | select(.real == 0)] | length > 20')"
check "AT-9f ci_seconds is non-increasing, nulls after every number" true \
  "$(q "$O" '. as $r | [.lists.expensive_zero_real[] as $s | $r.suites[] | select(.suite == $s) | .ci_seconds]
    | (map(select(. == null)) | length > 0) and ([.[] | if . == null then -1 else . end] as $v | [range(1; $v | length) | $v[. - 1] >= $v[.]] | all)')"
check "AT-9f the first is the largest real-0 cost" tests/p16.bh-6618-fixture.sh "$(q "$O" '.lists.expensive_zero_real[0]')"
check "AT-9f a suite with a real catch is not listed" false "$(q "$O" '.lists.expensive_zero_real | index("tests/real-pr.bh-6618-fixture.sh") != null')"

# ── AT-9g: never ran ────────────────────────────────────────────────────────
check "AT-9g never_ran" "tests/clash-a.bh-6618-fixture.sh tests/clash_a.bh-6618-fixture.sh tests/mc/disk-only.bh-6618-fixture.sh tests/never-ran.bh-6618-fixture.sh worker/jobs/test/disk-only.bh-6618-fixture.test.js" \
  "$(q "$O" '.lists.never_ran | join(" ")')"

# ── AT-9h: suite-passes unread ──────────────────────────────────────────────
O9h=$(outdir a9h); scratch_rm "$O9h/cache/suite-passes.json"; render "$O9h"
check "AT-9h render rc 0 without suite-passes" 0 "$RC"
check "AT-9h never_ran is null, suite_passes unread" "null false" "$(q "$O9h" '"\(.lists.never_ran) \(.sources.suite_passes.read)"')"
check "AT-9h ledger_runs and ci_seconds null" "null null null" \
  "$(q "$O9h" '.suites[] | select(.suite == "tests/false-only.bh-6618-fixture.sh") | "\(.ledger_runs) \(.ci_seconds) \(.runs_source)"')"
grep -q 'suite_passes' "$O9h/day/summary-ste.md" && ok "AT-9h the summary names the unread source" || bad "AT-9h the summary does not name suite_passes"
O9h2=$(outdir a9h2); scratch_rm "$O9h2/cache/suites-on-disk.txt"; render "$O9h2"
check "AT-9h never_ran is null when the disk list is unread" "null false" "$(q "$O9h2" '"\(.lists.never_ran) \(.sources.suites_on_disk.read)"')"

# ── AT-9i..l: the HTML ──────────────────────────────────────────────────────
HT="$O/day/ci-test-value.html"
[ -s "$HT" ] && ok "AT-9i the HTML is written" || bad "AT-9i no HTML"
n_th=$(grep -o '<th[ >]' "$HT" | wc -l)
n_th_sort=$(grep -o '<th [^>]*aria-sort="none"[^>]*tabindex="0"' "$HT" | wc -l)
[ "$n_th" -gt 0 ] && check "AT-9i every <th> carries aria-sort and tabindex" "$n_th" "$n_th_sort" || bad "AT-9i no <th>"
n_tab=$(grep -o '<table' "$HT" | wc -l)
check "AT-9i eight tables" 8 "$n_tab"
check "AT-9i one class=\"tw\" wrapper per table" "$n_tab" "$(grep -o 'class="tw"' "$HT" | wc -l)"
grep -q '<meta name="viewport" content="width=device-width,initial-scale=1">' "$HT" && ok "AT-9i viewport meta" || bad "AT-9i no viewport meta"
grep -q 'overflow-x:auto' "$HT" && ok "AT-9i the wrapper scrolls on its own" || bad "AT-9i no overflow-x:auto"
check "AT-9i no external resource (src= or link rel)" 0 "$(grep -c -E '<link |src="' "$HT")"
for r in 9200001 9200002 9200003; do
  check "AT-9j run $r: one run href per occurrence row" "$(grep -c "^$r	" "$FIX/occurrences.tsv")" \
    "$(grep -o "href=\"https://github.com/example-org/cromford/actions/runs/$r\"" "$HT" | wc -l)"
done
check "AT-9j one job href per occurrence row with a GitHub job URL" 9 "$(grep -o 'href="https://github.com/example-org/cromford/actions/runs/[0-9]*/job/[0-9]*"' "$HT" | wc -l)"
grep -q 'href="javascript' "$HT" && bad "AT-9j a non-GitHub URL became an href" || ok "AT-9j a non-GitHub URL is text, not an href"
miss=""
while IFS= read -r s; do grep -q "id=\"$s\"" "$HT" || miss="$miss $s"; done < <(grep -o 'href="#[^"]*"' "$HT" | sed 's/^href="#//; s/"$//' | sort -u)
check "AT-9k every in-page href has its anchor" "" "$miss"
check "AT-9k every id is unique" "" "$(grep -o ' id="[^"]*"' "$HT" | sort | uniq -d)"
check "AT-9k the false-only suite links to its anchor" 1 "$(grep -c 'id="suite-tests-false-only-bh-6618-fixture-sh"' "$HT")"
grep -q '&lt;script&gt;alert(1)&lt;/script&gt;' "$HT" && ok "AT-9l the why is escaped" || bad "AT-9l the escaped why is missing"
check "AT-9l one <script> element (the sort script)" 1 "$(grep -o '<script' "$HT" | wc -l)"
script=$(python3 -I -c 'import re, sys; m = re.search(r"<script>(.*?)</script>", open(sys.argv[1]).read(), re.S); print(m.group(1) if m else "")' "$HT")
[ -n "$script" ] && ok "AT-9l the sort script is inline" || bad "AT-9l no inline script"
check "AT-9l the script has no native dialog" 0 "$(grep -c -E 'confirm\(|alert\(|prompt\(' <<<"$script")"
# AT-9l2: a numeric cell whose data-v is not a number sorts as empty (last),
# never as NaN, which breaks the comparator and scrambles the column.
if command -v node >/dev/null 2>&1; then
  vfn=$(python3 -I -c 'import re, sys; m = re.search(r"(function val\(td,num\).*?)function go\(", sys.argv[1], re.S); print(m.group(1) if m else "")' "$script")
  check "AT-9l2 a non-number data-v reads as null in a num column" "null 5 null" "$(node -e '
    eval(process.argv[1]);
    function td(v){return {hasAttribute:function(){return true},getAttribute:function(){return v},textContent:v};}
    console.log([val(td("abc"),true), val(td("5"),true), val(td(""),true)].map(String).join(" "));' "$vfn" 2>&1)"
else
  echo "SKIP AT-9l2: node missing"
fi

# ── AT-9m / AT-9n: summary-ste.md ───────────────────────────────────────────
check "AT-9m the complete fixture: line 1" "COMPLETE: 3 red runs read" "$(head -1 "$O/day/summary-ste.md")"
grep -q '^- tests/false-only.bh-6618-fixture.sh: false=2 runs=7 ci_seconds=294$' "$O/day/summary-ste.md" \
  && ok "AT-9m the zero-real list line" || bad "AT-9m summary: $(cat "$O/day/summary-ste.md")"
grep -q '^Expensive zero real: 20 listed of 27 suites with real 0\. Top 10:$' "$O/day/summary-ste.md" \
  && ok "AT-9m the capped list names its cap" || bad "AT-9m no capped-list line"
O9n=$(outdir a9n coverage-incomplete.json); render "$O9n"
check "AT-9n render rc 0 on an incomplete coverage" 0 "$RC"
check "AT-9n the incomplete fixture: line 1" "INCOMPLETE: 2 red runs unread" "$(head -1 "$O9n/day/summary-ste.md")"
O9n2=$(outdir a9n2); jq '.red_runs_read = 2' "$FIX/coverage.json" > "$O9n2/coverage.json"; render "$O9n2"
check "AT-9n unread 0 but read < red: incomplete" "INCOMPLETE: 1 red runs unread" "$(head -1 "$O9n2/day/summary-ste.md")"
O9n3=$(outdir a9n3); jq '.incomplete = true | .days_unlisted = 1' "$FIX/coverage.json" > "$O9n3/coverage.json"; render "$O9n3"
check "AT-9n an unlisted day is never COMPLETE" "INCOMPLETE: 0 red runs unread" "$(head -1 "$O9n3/day/summary-ste.md")"

# ── AT-9o: a corrupt optional input ─────────────────────────────────────────
O9o=$(outdir a9o); echo '{"rows": [' > "$O9o/cache/suite-durations.json"; render "$O9o"
check "AT-9o render rc 0 on a corrupt suite-durations.json" 0 "$RC"
check "AT-9o ci_seconds null everywhere" 0 "$(q "$O9o" '[.suites[] | select(.ci_seconds != null)] | length')"
check "AT-9o suite_durations read false" false "$(q "$O9o" '.sources.suite_durations.read')"
# Valid JSON of the wrong shape is unread too, not a crash.
O9o3=$(outdir a9o3); echo '{"suites":[{"suite":"tests/p01.bh-6618-fixture.sh"}]}' > "$O9o3/cache/suite-passes.json"; render "$O9o3"
check "AT-9o render rc 0 on a wrong-shape suite-passes.json" 0 "$RC"
check "AT-9o suite_passes read false, ledger_runs null" "false null" \
  "$(q "$O9o3" '"\(.sources.suite_passes.read) \(.suites[] | select(.suite == "tests/p01.bh-6618-fixture.sh") | .ledger_runs)"')"
# A required input that is unreadable is still rc 1 with no output.
O9o2=$(outdir a9o2); scratch_rm "$O9o2/coverage.json"; render "$O9o2"
check "AT-9o a missing coverage.json is rc 1" 1 "$RC"
check "AT-9o and writes nothing" "" "$(ls "$O9o2/day" 2>/dev/null)"

# ── AT-9p: the production entry point, end to end ───────────────────────────
# bin/ci-test-value-report.sh with a gh shim that lists no failed run: the
# driver calls ctv_fetch_sources and the renderer, so the cache files, the HTML
# and the summary appear under --out. Deleting either call fails this case.
cat > "$T/bin/gh" <<'SHIM'
#!/bin/bash
[ "${1:-}" = api ] || { echo "REFUSED gh $*" >> "${SHIM_LOG:?}.refused"; exit 99; }
shift
inc=0 path= m=GET
for a in "$@"; do [ "$a" = --help ] && { echo "      --hostname string"; exit 0; }; done
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) m="${2:-}"; shift 2 ;;
    -i|--include) inc=1; shift ;;
    -H|--header|--jq|-q|--cache|-t|--template) shift 2 ;;
    -f|-F|--field|--raw-field|--input) echo "REFUSED gh field" >> "$SHIM_LOG.refused"; exit 99 ;;
    -*) shift ;;
    *) [ -z "$path" ] && path="$1"; shift ;;
  esac
done
[ "$m" = GET ] || { echo "REFUSED gh $m $path" >> "$SHIM_LOG.refused"; exit 99; }
[ "$inc" = 1 ] && printf 'HTTP/2.0 200 fixture\r\nContent-Type: application/json\r\n\r\n'
case "$path" in
  rate_limit) cat "$SHIM_CORE/rate-limit-healthy.json" ;;
  *) printf '{"total_count":0,"workflow_runs":[]}\n' ;;
esac
SHIM
chmod +x "$T/bin/gh"
mkdir -p "$T/h9p/state" "$T/h9p/logs"
RC=0
env PATH="$T/bin:$PATH" HARNESS="$T/h9p" HARNESS_TEST_SANDBOX=1 HARNESS_SECRET=secret-fixture-ctv \
  JOBS_URL=http://192.0.2.10:8787 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 CTV_NOW=1791979200 \
  GH_TOKEN=tok-fixture-ctv SHIM_LOG="$T/a9p.curl" SHIM_FIX="$FIX/worker" SHIM_CORE="$REPO_DIR/tests/fixtures/bh-6618/core" \
  "$REPO_DIR/bin/ci-test-value-report.sh" --days 1 --no-model --out "$T/a9p" > "$T/a9p.out" 2> "$T/a9p.err" || RC=$?
check "AT-9p the driver is rc 0" 0 "$RC"
[ -e "$T/a9p.curl.refused" ] && bad "AT-9p a shim refused: $(cat "$T/a9p.curl.refused")" || ok "AT-9p 0 refused (non-GET) calls"
grep -q '^GET http://192.0.2.10:8787/api/suite-results/passes?repo=example-org%2Fcromford&since=2026-10-14$' "$T/a9p.curl" \
  && ok "AT-9p the driver's FROM and repo reach the passes read" || bad "AT-9p passes URL: $(cat "$T/a9p.curl" 2>/dev/null)"
check "AT-9p the report reads the fetched sources" "true true true true" \
  "$(jq -r '[.sources.suite_durations.read, .sources.suite_passes.read, .sources.flakes.read, .sources.suites_on_disk.read] | map(tostring) | join(" ")' "$T/a9p/2026-10-14/ci-test-value.json" 2>/dev/null)"
[ -s "$T/a9p/2026-10-14/ci-test-value.html" ] && ok "AT-9p the HTML is written" || bad "AT-9p no HTML"
check "AT-9p summary line 1 on an empty window" "COMPLETE: 0 red runs read" "$(head -1 "$T/a9p/2026-10-14/summary-ste.md" 2>/dev/null)"
check "AT-9p the stdout line is the contract line" 1 "$(grep -c '^ctv: occurrences=0 red_runs=0 read=0 unread=0 ' "$T/a9p.out")"

# ── empty window: zero occurrences still renders every file ─────────────────
OE=$(outdir empty); head -1 "$FIX/occurrences.tsv" > "$OE/occurrences.tsv"; render "$OE"
check "empty window: render rc 0" 0 "$RC"
check "empty window: pct_by_class is {}" "{}" "$(q "$OE" '.totals.pct_by_class | tojson')"
[ -s "$OE/day/ci-test-value.html" ] && [ -s "$OE/day/summary-ste.md" ] && ok "empty window: HTML and summary written" || bad "empty window: a file is missing"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS ci-test-value-report.bh-6618"; exit 0; fi
echo "FAILED $FAILS check(s)"; exit 1
