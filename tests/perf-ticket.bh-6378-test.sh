#!/bin/bash
# tests/perf-ticket.bh-6378-test.sh — bin/lib/perf-ticket.sh, the perf/cost
# ticket classifier and the `Target metric:` parser (BH-6378, the BH-6372 tracer).
#
# WHAT THIS SUITE PROVES. Each row asserts the stdout line and the rc, nothing
# else:
#   C/E  pt_classify fires on a label row, a phrase row or a target line, and
#        not on the near misses (#6049, #5797, #5591, #5544, "CI failed after 30
#        minutes", "lane spend", label `costs`). pt_classify_issue hops ONCE to a
#        parent, never twice, and a failed REST read is rc 3, never `no`.
#   T    pt_parse_target reads `Target metric: <id> from <n> to <n> [<unit>]`.
#   D    the CLI, run as an executable, gives the same lines.
#   F    the shared fixtures in tests/fixtures/bh-6372/ carry what the sibling
#        slices read.
#   M    each rule, broken once in a copy of the lib, turns its case red (D1).
#
# THE REST PATH IS REAL. tests/lib/gh-rest-fx.sh installs a fake `gh` that
# answers HTTP status lines; the lib reads through the real bin/lib/gh-rest.sh.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/perf-ticket.bh-6378-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$(dirname "$0")/lib/gh-rest-fx.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/bh-6372"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/catalog" "$T/tmp"
scratch_install_closure bin/lib/perf-ticket.sh "$T/h" >/dev/null || { echo "FAIL: cannot install bin/lib/perf-ticket.sh"; exit 1; }
cp "$SRC/catalog/perf-ticket.tsv" "$T/h/catalog/perf-ticket.tsv"
ghfx_init
unset GH_TOKEN GH_LIMIT_IDENTITY GH_TOKEN_INSTALLATION_ID PERF_TICKET_CATALOG
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" GH_ETAG=0
LIB="$T/h/bin/lib/perf-ticket.sh"
R=example-org/cromford

# run <lib> <fn> [args...] — one call in a fresh shell; sets OUT and RC.
run() { local lib="$1"; shift; OUT=$(bash -c '. "$1" || exit 9; shift; "$@"' pt-run "$lib" "$@" 2>"$T/err"); RC=$?; }
expect() { # expect <case> <want-out> <want-rc>
  [ "$OUT" = "$2" ] && [ "$RC" = "$3" ] && ok || bad "$1: want '$2' rc $3, got '$OUT' rc $RC ($(head -1 "$T/err"))"
}
body() { printf '%s\n' "$1" > "$T/body"; }
issue() { # issue <n> <title> <body> [labels-csv] — one REST issue object
  jq -nc --argjson n "$1" --arg t "$2" --arg b "$3" --arg l "${4-}" \
    '{number:$n,title:$t,body:$b,labels:(if $l=="" then [] else ($l|split(",")|map({name:.})) end)}'
}
route() { ghfx_route GET "repos/$R/issues/$1" "${2:-200}" "${3-}"; }
route_fx() { route "$1" 200 "$(cat "$FX/issue-$1.json")"; }
reads() { grep -c "repos/$R/issues/" "$T/gh-argv.log"; }
have_fx() { [ -r "$FX/$1.json" ] && return 0; bad "fixture missing: tests/fixtures/bh-6372/$1.json (the README has the fetch command)"; return 1; }
fx_run() { # fx_run <lib> <fixture-name> — pt_classify on one fixture's title, body and labels
  jq -r '.body' "$FX/$2.json" > "$T/fxbody"
  run "$1" pt_classify "$T/fxbody" "$(jq -r '.title' "$FX/$2.json")" "$(jq -r '[.labels[].name]|join(",")' "$FX/$2.json")"
}

# ════ C/E. pt_classify, one ticket text ═════════════════════════════════════
body ""
run "$LIB" pt_classify "$T/body" "plain title" "bug,cost";  expect C3 "perf label:cost" 0
run "$LIB" pt_classify "$T/body" "plain title" " PERF ";    expect E1a "perf label:perf" 0
run "$LIB" pt_classify "$T/body" "plain title" "costs";     expect E1b no 1
run "$LIB" pt_classify "$T/body" "plain title" "";          expect E1c no 1
body "Target metric: x from 1 to 2"
run "$LIB" pt_classify "$T/body" "plain title" "";          expect C4 "perf target:line" 0
body $'intro\n## Target metric\nthe share drops'
run "$LIB" pt_classify "$T/body" "plain title" "";          expect E2 "perf target:heading" 0
body $'This lane uses metered CI.\nIt costs too much.'
run "$LIB" pt_classify "$T/body" "plain title" "hotfix";    expect C1s "perf phrase:metered_ci" 0
run "$LIB" pt_classify /nonexistent "Cut CI minutes" "";    expect E6 "perf phrase:ci_minutes" 0
body "the CI job ran. It took 30 minutes."
run "$LIB" pt_classify "$T/body" "CI failed after 30 minutes" "";  expect C7 no 1
body "lane spend is up"
run "$LIB" pt_classify "$T/body" "cost-rollup lane fix" "";        expect C8 no 1
body "saves CI time"
run "$LIB" pt_classify "$T/body" "x" "";                    expect E7a "perf phrase:saves_ci" 0
body "saveci"
run "$LIB" pt_classify "$T/body" "x" "";                    expect E7b no 1
body "this cuts metered CI"
OUT=$(PERF_TICKET_CATALOG=/nonexistent bash -c '. "$1"; shift; pt_classify "$@"' pt-run "$LIB" "$T/body" x "" 2>"$T/err"); RC=$?
expect E5 "" 3

# ════ C. the real corpus (tests/fixtures/bh-6372) ═══════════════════════════
if have_fx issue-5354; then fx_run "$LIB" issue-5354
  case "$OUT" in "perf phrase:"*) [ "$RC" = 0 ] && ok || bad "C1: rc $RC" ;; *) bad "C1: #5354 want 'perf phrase:…', got '$OUT' rc $RC" ;; esac
fi
for n in 6049 5797 5591 5544; do
  have_fx "issue-$n" && { fx_run "$LIB" "issue-$n"; expect "C5 #$n" no 1; }
done

# ════ C/E. pt_classify_issue, the REST read and the hop ═════════════════════
ghfx_routes_reset; ghfx_log_reset
route 9010 200 "$(issue 9010 'Plain title' 'Part of #9011')"
route 9011 200 "$(issue 9011 'BH-9011: cut review spend' 'parent body')"
run "$LIB" pt_classify_issue "$R" 9010;  expect E3 "perf parent:#9011" 0
[ "$(reads)" = 2 ] && ok || bad "E3: want 2 issue reads, got $(reads)"

ghfx_routes_reset; ghfx_log_reset
route 9020 200 "$(issue 9020 'BH-9021.1: slice' 'Part of #9022')"
route 9021 200 "$(issue 9021 'parent' 'Target metric: mq-share from 1 to 0')"
route 9022 200 "$(issue 9022 'other' 'nothing')"
run "$LIB" pt_classify_issue "$R" 9020;  expect E8 "perf parent:#9021" 0

ghfx_routes_reset; ghfx_log_reset
route 9001 200 "$(issue 9001 'BH-9002.1: x' 'child')"
route 9002 200 "$(issue 9002 'Plain parent' 'Part of #9003')"
route 9003 200 "$(issue 9003 'Grandparent' 'cut CI minutes' perf)"
run "$LIB" pt_classify_issue "$R" 9001;  expect C6 no 1
[ "$(reads)" = 2 ] && ok || bad "C6: want exactly 2 issue reads (9001, 9002), got $(reads)"
grep -q "issues/9003" "$T/gh-argv.log" && bad "C6: the grandparent 9003 was read (a second hop)" || ok

ghfx_routes_reset; ghfx_log_reset
route 9030 200 "$(issue 9030 'Plain' 'Part of #9030')"
run "$LIB" pt_classify_issue "$R" 9030;  expect E4 no 1
[ "$(reads)" = 1 ] && ok || bad "E4: want 1 issue read, got $(reads)"

ghfx_routes_reset
route 9040 200 "$(issue 9040 'Plain' 'nothing here' bug)"
run "$LIB" pt_classify_issue "$R" 9040;  expect E9 no 1
route 9041 200 "$(issue 9041 'Plain' 'x' cost)"
run "$LIB" pt_classify_issue "$R" 9041;  expect E10 "perf label:cost" 0

ghfx_routes_reset
route 9050 200 "$(issue 9050 'BH-9051.2: slice' 'child')"
route 9051 500 '{"message":"boom"}'
run "$LIB" pt_classify_issue "$R" 9050;  expect C9 "" 3
for st in 404 403; do
  ghfx_routes_reset; route 9060 "$st" '{"message":"no"}'
  run "$LIB" pt_classify_issue "$R" 9060;  expect "C10 $st" "" 3
done
ghfx_routes_reset; route 9070 200 'not json'
run "$LIB" pt_classify_issue "$R" 9070;  expect E11 "" 3
[ -z "$(find "$T/tmp" -mindepth 1 2>/dev/null)" ] && ok || bad "E12: temp files left in TMPDIR: $(find "$T/tmp" -mindepth 1 | head -3)"

if have_fx issue-5368 && have_fx issue-5354; then
  ghfx_routes_reset; route_fx 5368; route_fx 5354
  run "$LIB" pt_classify_issue "$R" 5368;  expect C2 "perf parent:#5354" 0
  ghfx_routes_reset; route_fx 5368; route 5354 500 '{"message":"boom"}'
  run "$LIB" pt_classify_issue "$R" 5368;  expect "C9 #5368" "" 3
fi
if have_fx issue-6049; then
  ghfx_routes_reset; route_fx 6049
  run "$LIB" pt_classify_issue "$R" 6049;  expect "C5 REST #6049" no 1
fi

# ════ T. pt_parse_target ════════════════════════════════════════════════════
body "Target metric: mq-full-share from 0.92 to 0.30"
run "$LIB" pt_parse_target "$T/body";  expect T1a "mq-full-share 0.92 0.30" 0
body "Target metric: mq-full-share from high to low"
run "$LIB" pt_parse_target "$T/body";  expect T1b "" 1
body $'intro\n  - Target metric: mq-full-share from 0.92 to 0.30 share'
run "$LIB" pt_parse_target "$T/body";  expect T1c "mq-full-share 0.92 0.30" 0
body "no target here"
run "$LIB" pt_parse_target "$T/body";  expect T1d "" 1
run "$LIB" pt_parse_target /nonexistent;  expect "T1d missing" "" 1
body "Target metric: MQ-Share from 1 to 2"
run "$LIB" pt_parse_target "$T/body";  expect T1e "" 1
body $'Target metric: bad from 0.9 to n/a\nTarget metric: ci-min from -3 to 12.5 min'
run "$LIB" pt_parse_target "$T/body";  expect T1f "ci-min -3 12.5" 0

# ════ D. the CLI, run as an executable ══════════════════════════════════════
[ -x "$LIB" ] && ok || bad "D0: bin/lib/perf-ticket.sh must be executable"
body "Target metric: mq-full-share from 0.92 to 0.30"
OUT=$("$LIB" parse-target "$T/body" 2>"$T/err"); RC=$?;  expect D1 "mq-full-share 0.92 0.30" 0
ghfx_routes_reset
route 9010 200 "$(issue 9010 'Plain title' 'Part of #9011')"
route 9011 200 "$(issue 9011 'BH-9011: cut review spend' 'parent body')"
OUT=$("$LIB" classify-issue "$R" 9010 2>"$T/err"); RC=$?;  expect "D2 synthetic" "perf parent:#9011" 0
if have_fx issue-5368 && have_fx issue-5354 && have_fx issue-6049; then
  ghfx_routes_reset; route_fx 5368; route_fx 5354; route_fx 6049
  OUT=$("$LIB" classify-issue "$R" 5368 2>"$T/err"); RC=$?;  expect "D2 #5368" "perf parent:#5354" 0
  OUT=$("$LIB" classify-issue "$R" 6049 2>"$T/err"); RC=$?;  expect "D2 #6049" no 1
fi
OUT=$("$LIB" 2>"$T/err"); RC=$?;              expect "D3 no argv" "" 2
OUT=$("$LIB" frobnicate x 2>"$T/err"); RC=$?; expect "D3 bad verb" "" 2
grep -q usage "$T/err" && ok || bad "D3: want a usage line on stderr"

# ════ F. the shared fixtures ════════════════════════════════════════════════
for f in issue-5354 issue-5368 issue-6049 issue-5797 issue-5591 issue-5544 pr-5454; do
  have_fx "$f" || continue
  jq -e '.title and (.body|type=="string") and (.labels|type=="array")' "$FX/$f.json" >/dev/null && ok || bad "F0: $f.json lacks the REST shape"
done
if have_fx pr-5454; then
  jq -r .body "$FX/pr-5454.json" | grep -qiE '^\|[[:space:]]*claim' && ok || bad "F1: pr-5454.json body has no evidence table (| claim row)"
fi

# ════ M. mutations (D1): break one rule in a copy, its case must go red ═════
mutant() { # mutant <name> <sed-expr> — a copy of the lib beside it, one rule broken
  sed -E "$2" "$LIB" > "$T/h/bin/lib/perf-ticket.$1.sh"
  cmp -s "$LIB" "$T/h/bin/lib/perf-ticket.$1.sh" && bad "$1: the mutation changed nothing"
  printf '%s' "$T/h/bin/lib/perf-ticket.$1.sh"
}
caught() { [ "$OUT $RC" != "$2" ] && ok || bad "$1: the mutation was not caught (still '$OUT' rc $RC)"; }

m=$(mutant M1 's/label\) labs\+=/label) labs_off+=/')
body ""; run "$m" pt_classify "$T/body" "plain title" "bug,cost";  caught M1 "perf label:cost 0"
grep -v '^phrase' "$T/h/catalog/perf-ticket.tsv" > "$T/nophrase.tsv"
body $'This lane uses metered CI.'
OUT=$(PERF_TICKET_CATALOG="$T/nophrase.tsv" bash -c '. "$1"; shift; pt_classify "$@"' pt-run "$LIB" "$T/body" x hotfix 2>"$T/err"); RC=$?
caught M2 "perf phrase:metered_ci 0"
m=$(mutant M3 "/grep -qiE '\\^.*target metric/d")
body "Target metric: x from 1 to 2"; run "$m" pt_classify "$T/body" "plain title" "";  caught M3 "perf target:line 0"
m=$(mutant M4 's/^( *)\[ -n "\$p" \]/\1false \&\& [ -n "$p" ]/')
ghfx_routes_reset
route 9010 200 "$(issue 9010 'Plain title' 'Part of #9011')"
route 9011 200 "$(issue 9011 'BH-9011: cut review spend' 'parent body')"
run "$m" pt_classify_issue "$R" 9010;  caught M4 "perf parent:#9011 0"
m=$(mutant M5 's/return 3; \}$/echo no; return 1; }/')
ghfx_routes_reset
route 9050 200 "$(issue 9050 'BH-9051.2: slice' 'child')"
route 9051 500 '{"message":"boom"}'
run "$m" pt_classify_issue "$R" 9050;  caught M5 " 3"
m=$(mutant M6 's/\(-\?\[0-9\]\+\(\\\.\[0-9\]\+\)\?\)/([^[:space:]]+)/g')
body "Target metric: mq-full-share from high to low"; run "$m" pt_parse_target "$T/body";  caught M6 " 1"

echo "perf-ticket: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
