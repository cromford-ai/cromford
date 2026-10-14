#!/bin/bash
# tests/eject-clash-report.bh-1669-test.sh — BH-1679 (BH-1669.3): the ejection
# file-clash report. Before any file is declared generated, measure which files
# each ejected PR shares with the PR whose merge ejected it.
#
# Driven, not grepped: every case runs the shipped bin/eject-clash-report.sh
# through its CLI against a fixture merge-conductor.log and a fake `gh` on PATH
# that answers gh_rest's `gh api -i -X GET …` reads from fixture JSON. The
# assertions are on stdout rows, the footer, the rc and the recorded gh argv.
# Every fixture value is a literal. Nothing here reads the wall clock.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/eject-clash-report.bh-1669-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
TAB=$(printf '\t')
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/fakebin" "$T/fix"
cp "$DIR/bin/eject-clash-report.sh" "$T/h/bin/"
for f in gh-rest.sh gh-rest-var.sh gh-rest-list.sh gh-rest-etag.sh gh-rest-ledger.sh gh-budget.sh gh-quota.sh gh-pr-list.sh; do
  [ -r "$DIR/bin/lib/$f" ] && cp "$DIR/bin/lib/$f" "$T/h/bin/lib/"
done
LOG="$T/h/logs/merge-conductor.log"

# The fake gh. It records argv, then answers the two REST reads the report
# makes: pulls/<n>/files (paged: <n>.files.json is page 1, <n>.files.p2.json
# page 2, any later page is []) and issues/<n>/comments (404 when there is no
# fixture). A <n>.files.500 marker makes every files read answer HTTP 500.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-argv.txt"
P=""; PAGE=1
while [ \$# -gt 0 ]; do
  case "\$1" in
    -F|-f) case "\$2" in page=*) PAGE="\${2#page=}" ;; esac; shift 2 ;;
    -X|-H) shift 2 ;;
    repos/*) P="\$1"; shift ;;
    *) shift ;;
  esac
done
ok200() { printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "\$1"; exit 0; }
case "\$P" in
  repos/$SLUG/pulls/*/files)
    n=\${P#repos/$SLUG/pulls/}; n=\${n%/files}
    [ -e "$T/fix/\$n.files.500" ] && { printf 'HTTP/1.1 500 Internal Server Error\r\n\r\n{"message":"fixture"}'; exit 0; }
    f="$T/fix/\$n.files.json"; [ "\$PAGE" = 1 ] || f="$T/fix/\$n.files.p\$PAGE.json"
    [ -r "\$f" ] && ok200 "\$(cat "\$f")"
    [ "\$PAGE" = 1 ] && { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 0; }
    ok200 '[]' ;;
  repos/$SLUG/issues/*/comments)
    n=\${P#repos/$SLUG/issues/}; n=\${n%/comments}
    [ "\$PAGE" = 1 ] && [ -r "$T/fix/\$n.comments.json" ] && ok200 "\$(cat "$T/fix/\$n.comments.json")"
    [ "\$PAGE" = 1 ] || ok200 '[]'
    printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 0 ;;
esac
printf 'UNEXPECTED %s\n' "\$P" >> "$T/gh-argv.txt"
exit 1
EOF
chmod +x "$T/fakebin/gh"

files_json() { # files_json <path>... -> a GitHub pulls/<n>/files page
  local p out='['
  for p in "$@"; do out="$out{\"filename\":\"$p\",\"status\":\"modified\"},"; done
  out="${out%,}]"
  printf '%s' "$out"
}

# ── fixtures ────────────────────────────────────────────────────────────────
# Three real ejections of demo-os: #12 (first ejection, `ejected … on`), #21
# (`EJECTED … again on`) and #31 (the contract's EJECTED_CONFLICT). A second
# EJECTED_CONFLICT for #12 on the same head is the same event and counts once.
# Every distractor shape merge-conductor.sh writes next to them is present, and
# so is an ejection of a different repo sharing the PR number.
cat > "$LOG" <<'EOF'
2026-09-20 10:00:00Z MERGED example-org/demo-os#10 by conductor (record none)
2026-09-20 10:01:00Z example-org/demo-os#12 ejected from the merge queue on aaaaaaaa — the batch build went red (provider mergify)
2026-09-20 10:01:01Z example-org/demo-os#12 ejected — removed the queue label
2026-09-20 10:01:02Z example-org/demo-os#12 ejected but the queue label could not be removed — the next tick reads it as queued until it goes
2026-09-20 10:02:00Z example-org/other#12 ejected from the merge queue on ffffffff — the batch build went red (provider mergify)
2026-09-20 10:02:30Z MERGED example-org/other#20 by conductor (record none)
2026-09-20 10:03:00Z MERGED example-org/demo-os#20 by conductor (record none)
2026-09-20 10:04:00Z example-org/demo-os#21 EJECTED from the merge queue again on bbbbbbbb (ejections: 2, provider mergify)
2026-09-20 10:04:01Z example-org/demo-os#21 BLOCKED_AGENT queue-ejected-twice — its batch build fails against current main
2026-09-20 10:05:00Z DEQUEUED_RED example-org/demo-os#22 cccccccc — ejected from the queue and a required check is genuinely failed at this head; left alone, the red ladder owns it
2026-09-20 10:05:30Z example-org/demo-os#23 ejected by this same tick on dddddddd — the re-entry waits one tick, so the row says queue-ejected and Mergify's check can move off the failure
2026-09-20 10:06:00Z MERGED example-org/demo-os#30 by conductor (record none)
2026-09-20 10:07:00Z EJECTED_CONFLICT example-org/demo-os#31 eeeeeeee1234567890abcdef
2026-09-20 10:07:30Z EJECTED_CONFLICT example-org/demo-os#12 aaaaaaaa99990000
EOF
cp "$LOG" "$T/log.orig"

# #12: Mergify names #9, the log's fallback would say #10. A human comment
# naming #99 is not Mergify and does not count.
cat > "$T/fix/12.comments.json" <<'EOF'
[{"user":{"login":"mergify[bot]"},"body":"This pull request has been queued"},
 {"user":{"login":"someone"},"body":"it went out after #99 merged"},
 {"user":{"login":"mergify[bot]"},"body":"## Reason\n\nThe pull request was removed from the queue after #9 merged and the batch failed."}]
EOF
# #21 has a readable comment list with no culprit text; #31 has none at all
# (404), so both fall back to the log.
printf '[{"user":{"login":"mergify[bot]"},"body":"Queued"}]' > "$T/fix/21.comments.json"

files_json scripts/worker-import-set.json src/a.ts only/nine.ts > "$T/fix/9.files.json"
files_json scripts/worker-import-set.json src/a.ts only/twelve.ts > "$T/fix/12.files.json"
files_json src/zz.ts > "$T/fix/10.files.json"
files_json scripts/worker-import-set.json src/b.ts only/twenty.ts > "$T/fix/20.files.json"
files_json src/b.ts scripts/worker-import-set.json > "$T/fix/21.files.json"
# #30 changes 101 files: 100 on page 1, late/page2.ts alone on page 2.
P1=(scripts/worker-import-set.json)
for i in $(seq 1 99); do P1+=("filler/f$i.ts"); done
files_json "${P1[@]}" > "$T/fix/30.files.json"
files_json late/page2.ts > "$T/fix/30.files.p2.json"
files_json late/page2.ts scripts/worker-import-set.json > "$T/fix/31.files.json"

run() { # run <log> <args...> ; sets OUT ERR RC
  : > "$T/gh-argv.txt"
  local lg="$1"; shift
  OUT=$(PATH="$T/fakebin:$PATH" HARNESS="$T/h" EJECT_CLASH_LOG="$lg" bash "$T/h/bin/eject-clash-report.sh" "$@" 2>"$T/err.txt"); RC=$?
  ERR=$(cat "$T/err.txt")
}
footer() { printf '%s\n' "$OUT" | grep '^# repo=' ; }
row1()   { printf '%s\n' "$OUT" | sed -n 2p; }

# Age every fixture to a literal past date, so anything the run writes is
# newer than the stamp without the test ever reading the clock.
find "$T/h" -type f -exec touch -d '2000-01-01 00:00:00' {} +
touch -d '2001-01-01 00:00:00' "$T/stamp"
run "$LOG" "$SLUG" 50

# ── A: three ejections, distractors and the other repo ignored, dedup ────────
[ "$RC" = 0 ] && ok || bad "A: rc=$RC (want 0); err=$ERR"
case "$(footer)" in *" ejections=3 of_requested=50 "*) ok ;; *) bad "A: footer wants ejections=3 of_requested=50: $(footer)" ;; esac
[ "$(printf '%s\n' "$OUT" | sed -n 1p)" = "path${TAB}pairs" ] && ok || bad "A: header wrong: $(printf '%s\n' "$OUT" | sed -n 1p)"
grep -q 'repos/example-org/other/' "$T/gh-argv.txt" && bad "A: read the other repo" || ok
grep -qE 'pulls/(22|23)/files|issues/(22|23)/comments' "$T/gh-argv.txt" && bad "A: a distractor line was counted as an ejection" || ok

# ── B: Mergify's "after #9 merged" beats the log's MERGED #10 ────────────────
grep -q "api -i -X GET repos/$SLUG/issues/12/comments" "$T/gh-argv.txt" && ok || bad "B: #12's comments were not read"
grep -q "repos/$SLUG/pulls/9/files" "$T/gh-argv.txt" && ok || bad "B: culprit #9 (Mergify) was not read"
grep -qE "repos/$SLUG/pulls/(10|99)/files" "$T/gh-argv.txt" && bad "B: read #10 or #99 though Mergify named #9" || ok
grep -q "repos/$SLUG/pulls/20/files" "$T/gh-argv.txt" && ok || bad "B: #21's fallback culprit #20 was not read"
grep -q "repos/$SLUG/pulls/30/files" "$T/gh-argv.txt" && ok || bad "B: #31's fallback culprit #30 was not read"
case "$(footer)" in *" pairs=3 unresolved=0 unreadable=0 "*) ok ;; *) bad "B: footer wants pairs=3 unresolved=0 unreadable=0: $(footer)" ;; esac

# ── C: the ranked table ──────────────────────────────────────────────────────
[ "$(row1)" = "scripts/worker-import-set.json${TAB}3" ] && ok || bad "C: first row is '$(row1)', want 'scripts/worker-import-set.json<TAB>3'"
WANT="path${TAB}pairs
scripts/worker-import-set.json${TAB}3
late/page2.ts${TAB}1
src/a.ts${TAB}1
src/b.ts${TAB}1"
GOT=$(printf '%s\n' "$OUT" | grep -v '^# ')
[ "$GOT" = "$WANT" ] && ok || bad "C: table is
$GOT
want
$WANT"
[ "$(grep -c "repos/$SLUG/pulls/30/files" "$T/gh-argv.txt")" = 2 ] && ok || bad "G: #30 files should be read across exactly 2 pages"

# ── H: read-only. The log is byte-identical and nothing new was written
# outside gh_rest's own ledger/ETag/budget files.
cmp -s "$LOG" "$T/log.orig" && ok || bad "H: the log changed"
NEW=$(find "$T/h" -type f -newer "$T/stamp" | grep -vE '/(state|logs|flags)/gh-|/state/gh-|/flags/' || true)
[ -z "$NEW" ] && ok || bad "H: the report wrote files: $NEW"

# ── B2: no Mergify text and no earlier MERGED line → unresolved, no files read
printf '%s\n' '2026-09-20 09:00:00Z example-org/demo-os#40 ejected from the merge queue on 40404040 — the batch build went red (provider mergify)' > "$T/log2"
run "$T/log2" "$SLUG"
[ "$RC" = 0 ] && ok || bad "B2: rc=$RC"
case "$(footer)" in *" ejections=1 of_requested=50 pairs=0 unresolved=1 "*) ok ;; *) bad "B2: footer wants unresolved=1: $(footer)" ;; esac
grep -q '/files' "$T/gh-argv.txt" && bad "B2: an unresolved ejection spent a files read" || ok

# ── D: an unreadable file list is an n/a row, never a crash ─────────────────
touch "$T/fix/20.files.500"
run "$LOG" "$SLUG" 50
rm -f "$T/fix/20.files.500"
[ "$RC" = 0 ] && ok || bad "D: rc=$RC (want 0); err=$ERR"
grep -qxF "n/a${TAB}$SLUG#21~#20" <<<"$OUT" && ok || bad "D: no n/a row for #21~#20: $OUT"
[ "$(row1)" = "scripts/worker-import-set.json${TAB}2" ] && ok || bad "D: first row '$(row1)', want worker-import-set.json<TAB>2"
case "$(footer)" in *" pairs=3 unresolved=0 unreadable=1 "*) ok ;; *) bad "D: footer wants unreadable=1: $(footer)" ;; esac

# ── N=2 keeps only the last two ejections (#21, #31) ─────────────────────────
run "$LOG" "$SLUG" 2
[ "$RC" = 0 ] && ok || bad "N2: rc=$RC"
case "$(footer)" in *" ejections=2 of_requested=2 pairs=2 "*) ok ;; *) bad "N2: footer: $(footer)" ;; esac
[ "$(row1)" = "scripts/worker-import-set.json${TAB}2" ] && ok || bad "N2: first row '$(row1)'"
grep -q "pulls/12/files" "$T/gh-argv.txt" && bad "N2: read #12, which is not in the last 2" || ok

# ── E: bad arguments are rc 2 ────────────────────────────────────────────────
for args in "not-a-slug" "example-org/demo-os 0" "example-org/demo-os x" ""; do
  # shellcheck disable=SC2086
  run "$LOG" $args
  [ "$RC" = 2 ] && ok || bad "E: args '$args' gave rc=$RC, want 2"
  [ -z "$OUT" ] && ok || bad "E: args '$args' printed a table"
done

# ── F: a missing log is rc 1, never "0 ejections" ────────────────────────────
run "$T/h/logs/nope.log" "$SLUG"
[ "$RC" = 1 ] && ok || bad "F: missing log gave rc=$RC, want 1"
[ -z "$OUT" ] && ok || bad "F: missing log printed a table: $OUT"
[ -n "$ERR" ] && ok || bad "F: missing log said nothing on stderr"

echo "eject-clash-report: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
