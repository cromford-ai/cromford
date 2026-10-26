#!/bin/bash
# tests/pr-self-check-outcome-replay.bh-6372-test.sh — BH-6380 (BH-6372.2): the
# pre-review self-check refuses a perf/cost PR whose body has no `## Outcome
# replay` section with a target line and a measured number. The rule is the
# row in catalog/pr-self-check.d/bh-6372-outcome-replay.tsv; the trigger is
# `perf` in bin/lib/pr-self-check.sh, which asks pt_classify
# (bin/lib/perf-ticket.sh) and makes at most ONE parent hop.
#
#   S1-S3b  the shipped row: refused with no section, with words for numbers,
#           with only a target, with only a measured number, with both outside
#           the section; passes with both inside it (plain and bullet form)
#   RT1     pt_parse_target reads the S3 and S3b bodies the row passes
#   RT2     a target line with junk after the `to` number: the row refuses it,
#           and pt_parse_target cannot read it either; a unit after it passes
#   S4      the non-perf fixtures and phrase near misses give no line
#   S5/S6   no ticket text / an unreadable classifier catalog: a NOTE with its
#           true reason, never a refusal
#   H1-H5   the parent hop: one read; a 500 is a NOTE; never a second hop; no
#           repo = no hop and no gh call; two perf rows cost one hop
#   H6      an empty ticket body, a plain title and a repo: no parent marker,
#           so no line and rc 0 under the CLI's set -u (review F1)
#   R1      the #5454 body on the #5368 ticket, through the CLI
#   F1-F3   catalog fragments in pr-self-check.d/: same output as the main
#           file, C filename order, non-.tsv ignored, no main = no catalog
#   U1-U5   _psc_body_shows: `under=` and `&`
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-self-check-outcome-replay.bh-6372-test.sh
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
for n in 5354 5368 6049 5797 5591 5544; do
  [ -r "$FX/issue-$n.json" ] || { echo "FAIL: fixture missing: $FX/issue-$n.json"; exit 1; }
done
[ -r "$FX/pr-5454.json" ] || { echo "FAIL: fixture missing: $FX/pr-5454.json"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GH_TOKEN GH_LIMIT_IDENTITY GH_TOKEN_INSTALLATION_ID PERF_TICKET_CATALOG PR_SELF_CHECK_CATALOG PR_SELF_CHECK_ONLY
unset PSC_TICKET_FILE PSC_TICKET_TITLE PSC_TICKET_LABELS PSC_TICKET_REPO PSC_TICKET_N
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_REVIEW_REQUIRE_BUILDER_APPROVE

# ── the CLI under test, its closure, and the shipped catalogs ────────────────
H="$T/h"; mkdir -p "$H/catalog" "$T/tmp" "$T/b"
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-self-check.sh"; exit 1; }
cp "$SRC/catalog/perf-ticket.tsv" "$H/catalog/perf-ticket.tsv"
CAT="$SRC/catalog/pr-self-check.tsv"   # the real main file and its real .d/
ROW_FILE="$SRC/catalog/pr-self-check.d/bh-6372-outcome-replay.tsv"
ghfx_init
export HARNESS="$H" TMPDIR="$T/tmp" GH_ETAG=0

R="$T/repo"; mkdir -p "$R/bin"
git -C "$R" init -q -b main
echo a > "$R/bin/a.sh"; git -C "$R" add -A; git -C "$R" commit -qm M0
git -C "$R" checkout -qb pr; echo b > "$R/bin/a.sh"; git -C "$R" commit -qam pr

# run <body> [ticket-file] — the CLI, the rule alone; OUT, RC, LINE (the rule's line)
run() {
  local cat="${RUN_CAT:-$CAT}"
  OUT=$(PATH="$T/fakebin:$PATH" PR_SELF_CHECK_CATALOG="$cat" bash "$H/bin/pr-self-check.sh" check \
        --repo "$R" --base main --head pr --body "$1" ${2:+--ticket "$2"} --only '^body-outcome-replay$' 2>/dev/null); RC=$?
  LINE=$(grep -E '^(REFUSE|NOTE) body-outcome-replay:' <<<"$OUT")
}
reads() { grep -c 'issues/' "$T/gh-argv.log" 2>/dev/null || true; }
# fx <n> — the fixture's body, title and labels: $T/b/tk-<n>, TTL, LBL
fx() {
  jq -r '.body // ""' "$FX/$1.json" > "$T/b/tk-$1"
  TTL=$(jq -r '.title // ""' "$FX/$1.json"); LBL=$(jq -r '[.labels[]?.name] | join(",")' "$FX/$1.json")
}

TK_PLAIN="$T/b/tk-plain"; printf '## Done when\n- the suite passes\n' > "$TK_PLAIN"
WHY=$'## Why\nThe merge queue spends too long on this today.\n'
TGT='Target metric: mq-full-share from 0.92 to 0.30'
printf '%s\n' "$WHY" > "$T/b/none"
printf '%s\n## Outcome replay\n%s\n%s\n' "$WHY" 'Target metric: mq-full-share from tbd to tbd' 'measured: pending' > "$T/b/s2"
printf '%s\n## Outcome replay\n%s\n' "$WHY" "$TGT" > "$T/b/s2b"
printf '%s\n## Outcome replay\nmeasured 0.31 on the last 20 batches\n' "$WHY" > "$T/b/s2c"
printf '%s\n## Outcome replay\n\n## Evidence\n%s\nmeasured 0.31\n' "$WHY" "$TGT" > "$T/b/s2d"
printf '%s\n## Outcome replay\n%s\nmeasured 0.31\n' "$WHY" "$TGT" > "$T/b/s3"
printf '%s\n## Outcome replay\n- %s\n- measured 0.31\n' "$WHY" "$TGT" > "$T/b/s3b"

# ── S1: a perf label and no section: refused, rc 1 (red on the base branch) ──
PSC_TICKET_LABELS=perf run "$T/b/none" "$TK_PLAIN"
[ "$RC" = 1 ] && grep -q '^REFUSE body-outcome-replay: the body is missing an "Outcome replay" section' <<<"$LINE" && ok \
  || bad "S1 want REFUSE body-outcome-replay rc 1, got rc=$RC: $OUT"
PSC_TICKET_LABELS=cost run "$T/b/none" "$TK_PLAIN"
[ "$RC" = 1 ] && grep -q '^REFUSE body-outcome-replay' <<<"$LINE" && ok || bad "S1 label cost: rc=$RC $OUT"
printf '## Done when\n- cut CI minutes on the batch path\n' > "$T/b/tk-phrase"
run "$T/b/none" "$T/b/tk-phrase"
[ "$RC" = 1 ] && grep -q '^REFUSE body-outcome-replay' <<<"$LINE" && ok || bad "S1 phrase \"ci minutes\": rc=$RC $OUT"
# The fix-body round runs --only '^body-': the id is in it.
OUT=$(PATH="$T/fakebin:$PATH" PR_SELF_CHECK_CATALOG="$CAT" PSC_TICKET_LABELS=perf bash "$H/bin/pr-self-check.sh" check \
      --repo "$R" --base main --head pr --body "$T/b/none" --ticket "$TK_PLAIN" --only '^body-' 2>/dev/null)
grep -q '^REFUSE body-outcome-replay' <<<"$OUT" && ok || bad "S1 --only '^body-' must run the row: $OUT"

# ── S2-S2d: the section is not enough without both numbers, inside it ──
for c in s2 s2b s2c s2d; do
  PSC_TICKET_LABELS=perf run "$T/b/$c" "$TK_PLAIN"
  [ "$RC" = 1 ] && grep -q '^REFUSE body-outcome-replay' <<<"$LINE" && ok || bad "${c^^} want REFUSE rc 1, got rc=$RC: $OUT"
done

# ── S3/S3b: target and measured under the heading: no line, rc 0 ──
for c in s3 s3b; do
  PSC_TICKET_LABELS=perf run "$T/b/$c" "$TK_PLAIN"
  [ "$RC" = 0 ] && [ -z "$LINE" ] && ok || bad "${c^^} want no line rc 0, got rc=$RC: $OUT"
done

# ── RT1: the reader on the other side reads the same bodies ──
for c in s3 s3b; do
  got=$(bash "$H/bin/lib/perf-ticket.sh" parse-target "$T/b/$c" 2>/dev/null)
  [ "$got" = "mq-full-share 0.92 0.30" ] && ok || bad "RT1 $c: pt_parse_target printed '$got'"
done

# ── RT2: the row and the reader agree at the end of the target line ──
printf '%s\n## Outcome replay\n%s\nmeasured 0.31\n' "$WHY" 'Target metric: mq from 1 to 2.3.4' > "$T/b/rt2-junk"
PSC_TICKET_LABELS=perf run "$T/b/rt2-junk" "$TK_PLAIN"
[ "$RC" = 1 ] && grep -q '^REFUSE body-outcome-replay' <<<"$LINE" && ok || bad "RT2 'to 2.3.4' want REFUSE rc 1, got rc=$RC: $OUT"
bash "$H/bin/lib/perf-ticket.sh" parse-target "$T/b/rt2-junk" >/dev/null 2>&1 && bad "RT2 pt_parse_target must not read 'to 2.3.4'" || ok
printf '%s\n## Outcome replay\n%s\nmeasured 0.31\n' "$WHY" 'Target metric: mq from 1 to 2 minutes' > "$T/b/rt2-unit"
PSC_TICKET_LABELS=perf run "$T/b/rt2-unit" "$TK_PLAIN"
[ "$RC" = 0 ] && [ -z "$LINE" ] && ok || bad "RT2 a unit after the number want no line rc 0, got rc=$RC: $OUT"
got=$(bash "$H/bin/lib/perf-ticket.sh" parse-target "$T/b/rt2-unit" 2>/dev/null)
[ "$got" = "mq 1 2" ] && ok || bad "RT2 unit: pt_parse_target printed '$got'"

# ── S4: non-perf tickets give no line ──
for n in 6049 5797 5591 5544; do
  fx "issue-$n"
  PSC_TICKET_TITLE="$TTL" PSC_TICKET_LABELS="$LBL" run "$T/b/none" "$T/b/tk-issue-$n"
  [ "$RC" = 0 ] && [ -z "$LINE" ] && ok || bad "S4 #$n want no line rc 0, got rc=$RC: $OUT"
done
for p in 'the cost-rollup lane posts lane spend daily' 'CI failed after 30 minutes'; do
  printf '## Done when\n- %s\n' "$p" > "$T/b/tk-near"
  run "$T/b/none" "$T/b/tk-near"
  [ "$RC" = 0 ] && [ -z "$LINE" ] && ok || bad "S4 near miss '$p': rc=$RC $OUT"
done

# ── S5: no ticket text at all: a NOTE, never a refusal ──
run "$T/b/none"
[ "$RC" = 0 ] && grep -q '^NOTE body-outcome-replay: no ticket text' <<<"$LINE" && ! grep -q '^REFUSE' <<<"$OUT" && ok \
  || bad "S5 want NOTE no ticket text rc 0, got rc=$RC: $OUT"

# ── S6: the classifier cannot read its catalog: a NOTE with its own reason ──
PERF_TICKET_CATALOG=/nonexistent PSC_TICKET_LABELS=perf run "$T/b/none" "$TK_PLAIN"
[ "$RC" = 0 ] && grep -q '^NOTE body-outcome-replay: the perf/cost classifier could not decide' <<<"$LINE" && ! grep -q '^REFUSE' <<<"$OUT" && ok \
  || bad "S6 want NOTE classifier could not decide rc 0, got rc=$RC: $OUT"

# ── H1-H4: the one parent hop ──
fx issue-5368; T5368="$TTL"; L5368="$LBL"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/cromford/issues/5354' 200 "$(cat "$FX/issue-5354.json")"
ghfx_log_reset
PSC_TICKET_TITLE="$T5368" PSC_TICKET_LABELS="$L5368" PSC_TICKET_REPO=example-org/cromford PSC_TICKET_N=5368 run "$T/b/none" "$T/b/tk-issue-5368"
[ "$RC" = 1 ] && grep -q '^REFUSE body-outcome-replay' <<<"$LINE" && ok || bad "H1 want REFUSE via the parent hop, got rc=$RC: $OUT"
[ "$(reads)" = 1 ] && grep -q 'issues/5354' "$T/gh-argv.log" && ok || bad "H1 want exactly one issue read (5354): $(cat "$T/gh-argv.log")"

ghfx_routes_reset; ghfx_route GET 'repos/example-org/cromford/issues/5354' 500 '{"message":"fixture 500"}'
ghfx_log_reset
PSC_TICKET_TITLE="$T5368" PSC_TICKET_LABELS="$L5368" PSC_TICKET_REPO=example-org/cromford PSC_TICKET_N=5368 run "$T/b/none" "$T/b/tk-issue-5368"
[ "$RC" = 0 ] && grep -q '^NOTE body-outcome-replay: the perf/cost classifier could not decide' <<<"$LINE" && ! grep -q '^REFUSE' <<<"$OUT" && ok \
  || bad "H2 a 500 on the parent must be a NOTE rc 0, got rc=$RC: $OUT"

ghfx_routes_reset
ghfx_route GET 'repos/example-org/cromford/issues/5368' 200 "$(cat "$FX/issue-5368.json")"
ghfx_route GET 'repos/example-org/cromford/issues/5354' 200 "$(cat "$FX/issue-5354.json")"
ghfx_log_reset
printf 'Part of #5368\n\n## Done when\n- the suite passes\n' > "$T/b/tk-grand"
PSC_TICKET_TITLE='a plain child ticket' PSC_TICKET_REPO=example-org/cromford PSC_TICKET_N=7001 run "$T/b/none" "$T/b/tk-grand"
[ "$RC" = 0 ] && [ -z "$LINE" ] && ok || bad "H3 a grandparent chain must give no line, got rc=$RC: $OUT"
[ "$(reads)" = 1 ] && grep -q 'issues/5368' "$T/gh-argv.log" && ok || bad "H3 want exactly one issue read (5368): $(cat "$T/gh-argv.log")"
# a ticket that names itself as its parent: no hop
ghfx_log_reset
printf 'Part of #7002\n' > "$T/b/tk-self"
PSC_TICKET_TITLE='a plain ticket' PSC_TICKET_REPO=example-org/cromford PSC_TICKET_N=7002 run "$T/b/none" "$T/b/tk-self"
[ "$RC" = 0 ] && [ -z "$LINE" ] && [ "$(reads)" = 0 ] && ok || bad "H3 a self parent: rc=$RC reads=$(reads): $OUT"

ghfx_log_reset
PSC_TICKET_TITLE="$T5368" PSC_TICKET_LABELS="$L5368" PSC_TICKET_N=5368 run "$T/b/none" "$T/b/tk-issue-5368"
[ "$RC" = 0 ] && [ -z "$LINE" ] && ok || bad "H4 no repo must give no line, got rc=$RC: $OUT"
[ ! -s "$T/gh-argv.log" ] && ok || bad "H4 no repo must make no gh call: $(cat "$T/gh-argv.log")"

# ── H6: an empty ticket body with a plain title and a repo (review F1) ──
# No parent marker, so `par` stays empty. The CLI runs under set -u.
: > "$T/b/tk-empty"
ghfx_log_reset
OUT=$(PATH="$T/fakebin:$PATH" PR_SELF_CHECK_CATALOG="$CAT" PSC_TICKET_TITLE=plain PSC_TICKET_LABELS=bug \
      PSC_TICKET_REPO=example-org/cromford PSC_TICKET_N=7003 bash "$H/bin/pr-self-check.sh" check \
      --repo "$R" --base main --head pr --body "$T/b/s3" --ticket "$T/b/tk-empty" --only '^body-outcome-replay$' 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(reads)" = 0 ] && ok \
  || bad "H6 want no output rc 0 and no read, got rc=$RC reads=$(reads): $OUT"

# ── H5: two perf rows in one check cost one parent hop (the memo) ──
mkdir -p "$T/h5/main.d"; printf "# header\n" > "$T/h5/main.tsv"
cp "$ROW_FILE" "$T/h5/main.d/a.tsv"; sed "s/^body-outcome-replay\t/body-outcome-replay2\t/" "$ROW_FILE" > "$T/h5/main.d/b.tsv"
ghfx_routes_reset; ghfx_route GET "repos/example-org/cromford/issues/5354" 200 "$(cat "$FX/issue-5354.json")"
ghfx_log_reset
OUT=$(PATH="$T/fakebin:$PATH" PR_SELF_CHECK_CATALOG="$T/h5/main.tsv" PSC_TICKET_TITLE="$T5368" PSC_TICKET_LABELS="$L5368" \
      PSC_TICKET_REPO=example-org/cromford PSC_TICKET_N=5368 bash "$H/bin/pr-self-check.sh" check \
      --repo "$R" --base main --head pr --body "$T/b/none" --ticket "$T/b/tk-issue-5368" --only "^body-outcome-replay" 2>/dev/null)
[ "$(grep -c "^REFUSE body-outcome-replay" <<<"$OUT")" = 2 ] && [ "$(reads)" = 1 ] && ok \
  || bad "H5 want two refusals and one issue read, got reads=$(reads): $OUT"

# ── R1: the merged #5454 body on its real ticket #5368 ──
jq -r '.body // ""' "$FX/pr-5454.json" > "$T/b/pr-5454"
{ cat "$T/b/pr-5454"; printf '\n## Outcome replay\n%s\nmeasured 0.31\n' "$TGT"; } > "$T/b/pr-5454-full"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/cromford/issues/5354' 200 "$(cat "$FX/issue-5354.json")"
PSC_TICKET_TITLE="$T5368" PSC_TICKET_LABELS="$L5368" PSC_TICKET_REPO=example-org/cromford PSC_TICKET_N=5368 run "$T/b/pr-5454" "$T/b/tk-issue-5368"
[ "$RC" = 1 ] && grep -q '^REFUSE body-outcome-replay' <<<"$LINE" && ok || bad "R1 the #5454 body must be refused, got rc=$RC: $OUT"
PSC_TICKET_TITLE="$T5368" PSC_TICKET_LABELS="$L5368" PSC_TICKET_REPO=example-org/cromford PSC_TICKET_N=5368 run "$T/b/pr-5454-full" "$T/b/tk-issue-5368"
[ "$RC" = 0 ] && [ -z "$LINE" ] && ok || bad "R1 the #5454 body with the section must pass, got rc=$RC: $OUT"

# ── F1: a fragment row behaves as the same row in the main file ──
ROW=$(grep -v '^#' "$ROW_FILE" | grep .)
mkdir -p "$T/f1a" "$T/f1b/main.d"
printf '# header\n%s\n' "$ROW" > "$T/f1a/main.tsv"
printf '# header\n' > "$T/f1b/main.tsv"; cp "$ROW_FILE" "$T/f1b/main.d/"
RUN_CAT="$T/f1a/main.tsv" PSC_TICKET_LABELS=perf run "$T/b/none" "$TK_PLAIN"; L1="$LINE"
RUN_CAT="$T/f1b/main.tsv" PSC_TICKET_LABELS=perf run "$T/b/none" "$TK_PLAIN"; L2="$LINE"
[ -n "$L1" ] && [ "$L1" = "$L2" ] && ok || bad "F1 main '$L1' vs fragment '$L2'"

# ── F2: fragments in C filename order; a non-.tsv file is ignored ──
mkdir -p "$T/f2/main.d"
printf '# c\nm1\tnote\t-\tmain\n' > "$T/f2/main.tsv"
printf '# c\nb1\tnote\t-\tb\n' > "$T/f2/main.d/b.tsv"
printf 'a1\tnote\t-\ta\n' > "$T/f2/main.d/a.tsv"
printf 'c1\tnote\t-\tc\n' > "$T/f2/main.d/c.txt"
got=$(PR_SELF_CHECK_CATALOG="$T/f2/main.tsv" bash -c '. "$1" && _psc_rows' _ "$H/bin/lib/pr-self-check.sh" | cut -f1 | paste -sd' ' -)
[ "$got" = "m1 a1 b1" ] && ok || bad "F2 want 'm1 a1 b1', got '$got'"
mkdir -p "$T/f2b"
printf 'm1\tnote\t-\tmain\n' > "$T/f2b/main.tsv"
got=$(PR_SELF_CHECK_CATALOG="$T/f2b/main.tsv" bash -c '. "$1" && _psc_rows' _ "$H/bin/lib/pr-self-check.sh" | cut -f1 | paste -sd' ' -)
[ "$got" = m1 ] && ok || bad "F2 no .d/ must read the main file alone, got '$got'"

# ── F3: fragments with no main catalog: no catalog, rc 2 ──
mkdir -p "$T/f3/main.d"; cp "$ROW_FILE" "$T/f3/main.d/"
RUN_CAT="$T/f3/main.tsv" PSC_TICKET_LABELS=perf run "$T/b/none" "$TK_PLAIN"
[ "$RC" = 2 ] && grep -q '^pr-self-check: no catalog' <<<"$OUT" && ok || bad "F3 want no catalog rc 2, got rc=$RC: $OUT"

# ── U1-U5: _psc_body_shows ──
printf '## Evidence\n### Outcome replay\nfoo 1\n## Next\nbar 2\n' > "$T/b/u"
shows() { bash -c '. "$1" && _psc_body_shows "$2" "$3"' _ "$H/bin/lib/pr-self-check.sh" "$T/b/u" "$1"; }
shows 'under=outcome replay>>foo' && ok || bad "U1 under= must match a line under a ### heading"
shows 'under=outcome replay>>bar' && bad "U2 under= matched a line under the next ## heading" || ok
shows 'under=outcome replay>>foo&under=outcome replay>>zzz' && bad "U3 a&b held with b false" || ok
shows 'under=outcome replay>>zzz&line=zzz;line=bar' && ok || bad "U4 a&b;c must hold when c holds"
shows 'bogus=foo' && bad "U5 an unknown term kind held" || ok
shows 'under=outcome replay' && bad "U5 an under= with no >> held" || ok
shows 'line=foo' && ok || bad "U5 an old line= term no longer holds"

echo "pr-self-check-outcome-replay.bh-6372: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
