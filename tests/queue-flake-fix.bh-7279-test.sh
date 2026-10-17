#!/bin/bash
# tests/queue-flake-fix.bh-7279-test.sh — BH-7279: a PR that changes a suite on
# the batch-fail list, and touches only the fix scope (test and doc paths),
# gets the `queue-flake-fix` label before `merge-queue`, so Mergify's size-1
# `flake-fix` queue takes it first after a hotfix. Every other PR routes default.
#
#   F1-F5   bin/lib/queue-flake-fix.sh qff_decide / qff_list on the real
#           bin/prequeue-learned.sh --list --why output (seeds + run records)
#   F6-F8   qff_enqueue_step: shadow, off, a conf without flake_fix_label=
#   F9-F11  the real mc_enqueue_mergify (bin/lib/mc/queue.sh) with a stub gh on
#           PATH: the label POST comes before merge-queue; a failed POST; a
#           stale label DELETE; fix-main-red and train skips
#   F12     no settings rows: mode enforce, min_fails 1, the default globs
#   F13     the rows and the list are read once per conductor tick
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/queue-flake-fix.bh-7279-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

QFF_LIB="$DIR/bin/lib/queue-flake-fix.sh"
[ -r "$QFF_LIB" ] || { echo "FAIL: $QFF_LIB does not exist (BH-7279 not built)"; echo "PASS=0 FAIL=1"; exit 1; }
NOW=1791000000; export NOW
SUITE=tests/staff-watchman.bh-5565-test.sh

# stub_lane_gate <root> — prequeue-learned's lane_knob reads the env only (the
# tests/prequeue-learned-seed.bh-6924-test.sh pattern): no settings read.
stub_lane_gate() {
  mkdir -p "$1/bin/lib"
  cat > "$1/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
lane_knob() { printf '%s' "${!2:-}"; }
SH
}
# A deployed-shaped root (no tests/ dir): the real prequeue-learned.sh, the real
# seed file, and run records in its own format.
R="$T/r"
stub_lane_gate "$R"
scratch_install_closure bin/prequeue-learned.sh "$R" >/dev/null || { echo "FAIL: cannot install bin/prequeue-learned.sh"; exit 1; }
mkdir -p "$R/catalog/prequeue-learned-seed.d" "$R/state/prequeue-learned/runs" "$R/config/mergify/repos"
cp "$DIR/catalog/prequeue-learned-seed.d/bh-6924.txt" "$R/catalog/prequeue-learned-seed.d/"
# rec <id> <suite>... — one failed-batch run record created a day before NOW.
rec() { local id="$1"; shift; { echo "run $id created $((NOW - 86400)) attempt 1"; printf '%s\n' "$@"; } > "$R/state/prequeue-learned/runs/$id"; }
rec 9001 "$SUITE" tests/other-flake.bh-1-test.sh
rec 9002 tests/other-flake.bh-1-test.sh

ROWS="$T/rows"; : > "$ROWS"
# setting_get from $ROWS (`key<TAB>value`): no line is rc 2 (no row), the value
# __RC1__ is rc 1 (an outage). Every key read is logged to $SETCNT.
SETTING_STUB='setting_get() { local v; printf "%s\n" "$1" >> "${SETCNT:-/dev/null}"; v=$(awk -F"\t" -v k="$1" '"'"'$1 == k { print $2; f = 1 } END { exit !f }'"'"' "$ROWS") || return 2; [ "$v" = __RC1__ ] && return 1; printf "%s" "$v"; }'
row() { printf '%s\t%s\n' "$1" "$2" >> "$ROWS"; }
# lib <cmd...> — the lib sourced on root $R with the rows stub, in a subshell.
lib() { ( HARNESS="$R"; unset H; eval "$SETTING_STUB"; . "$QFF_LIB"; "$@" ) 2>"$T/lib.err"; }
# dec <path>... — qff_decide on those files against the list qff_list prints,
# with the scope globs the rows give (the way qff_enqueue_step calls it).
dec() {
  printf '%s\n' "$@" > "$T/files"
  lib qff_list "$R" > "$T/list"
  lib eval 'qff_rules_load; qff_decide "$T/files" "$T/list" "$QFF_SCOPE_GLOBS"'
}
froute() { cut -f1 <<<"$1"; }
fsuite() { cut -f2 <<<"$1"; }
freason() { cut -f3 <<<"$1"; }

# ── the list: real --why rows (seeds and counts), suites only ───────────────
: > "$ROWS"
L=$(lib qff_list "$R")
grep -qx "$SUITE" <<<"$L" && grep -qx tests/route-keyed-merge.bh-5788-test.sh <<<"$L" \
  && grep -qx tests/other-flake.bh-1-test.sh <<<"$L" && ok || bad "list: seeds and counted suites are listed: '$L' $(cat "$T/lib.err")"
grep -qE $'\t|^seed|^[0-9]' <<<"$L" && bad "list: one bare suite path a line, no --why columns: '$L'" || ok
[ "$L" = "$(LC_ALL=C sort -u <<<"$L")" ] && ok || bad "list: sorted and unique: '$L'"

# ── F1: the suite is listed and the PR is tests only → flake-fix ────────────
O=$(dec "$SUITE")
[ "$O" = "flake-fix"$'\t'"$SUITE"$'\t'"in-scope" ] && ok || bad "F1 a listed suite alone routes flake-fix: '$O' $(cat "$T/lib.err")"
# F1b: the suite plus its plan and a note stay in scope
O=$(dec "$SUITE" .harness/specs/BH-1/plan.md docs/notes/x.md)
[ "$(froute "$O")" = flake-fix ] && [ "$(fsuite "$O")" = "$SUITE" ] && ok || bad "F1b the suite + plan + note routes flake-fix: '$O'"
# F1c: a seed suite (the real committed seed file, no run record)
O=$(dec tests/route-keyed-merge.bh-5788-test.sh)
[ "$(froute "$O")" = flake-fix ] && [ "$(fsuite "$O")" = tests/route-keyed-merge.bh-5788-test.sh ] && ok || bad "F1c a seed suite routes flake-fix: '$O'"
# two listed suites: the first in sort order is named
O=$(dec tests/route-keyed-merge.bh-5788-test.sh "$SUITE")
[ "$(fsuite "$O")" = tests/route-keyed-merge.bh-5788-test.sh ] && ok || bad "F1 two listed suites name the first sorted: '$O'"

# ── F2: the suite is not on the list → default ──────────────────────────────
O=$(dec tests/not-listed.bh-2-test.sh)
[ "$O" = "default"$'\t'"-"$'\t'"no-batch-fail-suite" ] && ok || bad "F2 an unlisted suite routes default no-batch-fail-suite: '$O'"
# F2b: the suite counted once, min_fails 2 → off the list
: > "$ROWS"; row flake_fix.min_fails 2
O=$(dec "$SUITE")
[ "$(froute "$O")" = default ] && [ "$(freason "$O")" = no-batch-fail-suite ] && ok || bad "F2b a count below flake_fix.min_fails routes default: '$O'"
O=$(dec tests/other-flake.bh-1-test.sh)
[ "$(froute "$O")" = flake-fix ] && ok || bad "F2b a suite counted 2 times at min_fails 2 stays listed: '$O'"
O=$(dec tests/route-keyed-merge.bh-5788-test.sh)
[ "$(froute "$O")" = flake-fix ] && ok || bad "F2b min_fails never cuts a seed: '$O'"
: > "$ROWS"

# ── F3: the listed suite plus non-test code → default ───────────────────────
O=$(dec "$SUITE" bin/lib/rt/gate.sh)
[ "$O" = "default"$'\t'"$SUITE"$'\t'"out-of-scope:bin/lib/rt/gate.sh" ] && ok || bad "F3 suite + bin code routes default out-of-scope: '$O'"
# F3b: #7194's real 13 files (git diff --name-only 4eae5c7a^1 4eae5c7a)
printf '%s\n' .harness/specs/BH-7117/plan.md bin/launch-fastpath.sh bin/lib/rt/gate.sh bin/lib/rt/scope.sh \
  bin/lib/triage-hotfix-lib.sh catalog/switches.d/hotfix-intake-off.json docs/notes/2026-10-16-BH-7117-hotfix-intake-first.md \
  docs/verification-map/entries/BH-7117.md docs/verification-map/hotfix-lane.md tests/hold-parse-shared.bh-6297-test.sh \
  tests/hotfix-intake.bh-7117-test.sh tests/launch-fastpath-hotfix-spec.bh-7117-test.sh "$SUITE" > "$T/f7194"
lib qff_list "$R" > "$T/list"
O=$(lib qff_decide "$T/f7194" "$T/list")
[ "$O" = "default"$'\t'"$SUITE"$'\t'"out-of-scope:bin/launch-fastpath.sh" ] && ok || bad "F3b #7194's 13 files route default out-of-scope:bin/launch-fastpath.sh: '$O'"
# a wider scope row lets it through, with no code change
: > "$ROWS"; row flake_fix.scope_globs 'tests/* docs/* .harness/specs/* bin/* catalog/*'
O=$(dec "$SUITE" bin/lib/rt/gate.sh)
[ "$(froute "$O")" = flake-fix ] && ok || bad "F3 a scope_globs row that names bin/* routes the F3 PR flake-fix: '$O'"
: > "$ROWS"

# ── F4: near misses route default ───────────────────────────────────────────
O=$(dec "$SUITE.orig")
[ "$(froute "$O")" = default ] && [ "$(freason "$O")" = no-batch-fail-suite ] && ok || bad "F4 a prefix match is not the suite: '$O'"
O=$(dec tests/mc/staff-watchman.bh-5565-test.sh)
[ "$(froute "$O")" = default ] && ok || bad "F4b the same name in another dir is not the suite: '$O'"
O=$(dec tests/lib/scratch.sh)
[ "$(froute "$O")" = default ] && [ "$(freason "$O")" = no-batch-fail-suite ] && ok || bad "F4c tests only, no listed suite: '$O'"
O=$(dec tests/fixtures/bh-5565/x.json)
[ "$(froute "$O")" = default ] && ok || bad "F4d a fixture of the suite only is not the suite: '$O'"
# a cwd file must not expand a glob (read -a, not an unquoted expansion)
mkdir -p "$T/cwd/docs"; touch "$T/cwd/docs/zz.md"
O=$(cd "$T/cwd" && dec "$SUITE" docs/a.md)
[ "$(froute "$O")" = flake-fix ] && ok || bad "F4 the globs do not expand against the cwd: '$O'"

# ── F5: unreadable inputs route default with the reason ─────────────────────
: > "$T/empty"; lib qff_list "$R" > "$T/list"
O=$(lib qff_decide "$T/empty" "$T/list")
[ "$O" = "default"$'\t'"-"$'\t'"files-unavailable" ] && ok || bad "F5 an empty file list is default files-unavailable: '$O'"
O=$(lib qff_decide "$T/nonexistent" "$T/list")
[ "$(freason "$O")" = files-unavailable ] && ok || bad "F5 a missing file list is files-unavailable: '$O'"
printf '%s\n' "$SUITE" > "$T/files"
O=$(lib qff_decide "$T/files" "$T/empty")
[ "$O" = "default"$'\t'"-"$'\t'"list-empty" ] && ok || bad "F5b an empty list is default list-empty: '$O'"
# F5b: the list script fails → qff_list prints nothing
BR="$T/broken"; mkdir -p "$BR/bin"; printf '#!/bin/bash\necho "seed\ttests/x.sh"\nexit 1\n' > "$BR/bin/prequeue-learned.sh"
L=$(lib qff_list "$BR"); [ -z "$L" ] && ok || bad "F5b a non-zero list script prints nothing: '$L'"
L=$(lib qff_list "$T/no-such-root"); [ -z "$L" ] && ok || bad "F5b a missing list script prints nothing: '$L'"
# a row that is not a suite path is dropped
printf '#!/bin/bash\nprintf "seed\\ttests/ok.sh\\nseed\\tbin/x.sh\\n3\\ttests/mc/m.sh\\nnot a row\\n"\n' > "$BR/bin/prequeue-learned.sh"
L=$(lib qff_list "$BR"); [ "$L" = $'tests/mc/m.sh\ntests/ok.sh' ] && ok || bad "list: only tests/(mc/)?*.sh rows are kept: '$L'"

# ── F12: no rows at all → enforce, min 1, the default globs ────────────────
: > "$ROWS"
O=$( ( HARNESS="$R"; eval "$SETTING_STUB"; . "$QFF_LIB"; qff_rules_load; printf '%s|%s|%s' "$QFF_MODE" "$QFF_MIN_FAILS" "$QFF_SCOPE_GLOBS" ))
[ "$O" = "enforce|1|tests/* worker/jobs/test/* console-ui/tests/* docs/* .harness/specs/*" ] && ok || bad "F12 no rows: enforce, 1, the default globs: '$O'"
row flake_fix.mode __RC1__; row flake_fix.min_fails abc
O=$( ( HARNESS="$R"; eval "$SETTING_STUB"; . "$QFF_LIB"; qff_rules_load; printf '%s|%s' "$QFF_MODE" "$QFF_MIN_FAILS" ) )
[ "$O" = "enforce|1" ] && ok || bad "F12 an outage is enforce, a non-integer min_fails is 1: '$O'"
: > "$ROWS"; row flake_fix.mode bogus
O=$( ( HARNESS="$R"; eval "$SETTING_STUB"; mc_log() { echo "LOG $*" >&2; }; . "$QFF_LIB"; qff_mode ) 2>"$T/m.err")
[ "$O" = off ] && grep -q "flake_fix.mode 'bogus' is not off|shadow|enforce" "$T/m.err" && ok || bad "F12 a bogus mode is off with one log line: '$O' $(cat "$T/m.err")"
O=$( ( unset HARNESS H; eval "$SETTING_STUB"; . "$QFF_LIB"; qff_enqueue_step example-org/cromford 41 "$(printf 'a%.0s' {1..40})" ); echo "rc=$?")
[ "$O" = rc=0 ] && ok || bad "D43 an empty root is a silent rc 0: '$O'"

# ============================================================================
# F6-F11, F13: through the real mc_enqueue_mergify
# ============================================================================
SLUG=example-org/cromford
HEAD1=aaaaaaaa11111111111111111111111111111111
HEAD2=bbbbbbbb22222222222222222222222222222222
H="$T/h"; mkdir -p "$H/logs" "$H/state/merge-conductor" "$H/config/mergify/repos" "$T/tmp" "$T/fakebin"
stub_lane_gate "$H"
scratch_install_closure bin/prequeue-learned.sh "$H" >/dev/null || { echo "FAIL: cannot install bin/prequeue-learned.sh into \$H"; exit 1; }
mkdir -p "$H/catalog/prequeue-learned-seed.d" "$H/state/prequeue-learned/runs"
cp "$DIR/catalog/prequeue-learned-seed.d/bh-6924.txt" "$H/catalog/prequeue-learned-seed.d/"
cp "$R/state/prequeue-learned/runs/"* "$H/state/prequeue-learned/runs/"
G="$T/gh"; mkdir -p "$G"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The stub gh: the PR read ($G/labels, $G/title), its files ($G/files), the
# status POST, the label POST ($G/post-fail fails the queue-flake-fix one) and
# the label DELETE. Every call is logged to $G/calls.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$*" in
  *"-X GET repos/"*"/pulls/"*"/files"*)
    restpr --raw 200 "\$(jq -R -s -c 'split("\n") | map(select(length > 0)) | map({filename: ., additions: 1, deletions: 0})' < "$G/files")" ;;
  *"-X GET repos/"*"/pulls/"[0-9]*)
    [ -f "$G/pr-500" ] && { restpr --raw 500 '{"message":"boom"}'; exit 0; }
    restpr --raw 200 "\$(jq -nc --arg t "\$(cat "$G/title" 2>/dev/null || echo 'BH-1: a change')" --arg l "\$(cat "$G/labels" 2>/dev/null)" \
      --argjson n "\$(grep -c . "$G/files")" \
      '{title:\$t, head:{ref:"ticket/bh-1", sha:"x"}, additions:10, deletions:0, changed_files:\$n,
        labels:(if \$l == "" then [] else (\$l | split(",") | map({name:.})) end)}')" ;;
  *"-X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"-X POST repos/"*"/labels"*"labels[]=queue-flake-fix"*) [ -f "$G/post-fail" ] && { echo "HTTP 422: fixture refusal" >&2; exit 1; }; exit 0 ;;
  *"-X POST repos/"*"/labels"*) exit 0 ;;
  *"-X DELETE repos/"*"/labels/"*) exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

CONF="$H/config/mergify/repos/cromford.conf"
# conf <with|without> — the committed conf minus queue_mode (the partition
# block stays out of the call log) and solo_label (the risk block's own calls
# stay out), with or without flake_fix_label=.
conf() {
  grep -vE '^(queue_mode|scope_default_capacity|solo_label|flake_fix_label)=' "$DIR/config/mergify/repos/cromford.conf" > "$CONF"
  [ "$1" = with ] && echo 'flake_fix_label=queue-flake-fix' >> "$CONF"
  return 0
}
U41="https://github.com/$SLUG/pull/41"
ereset() { rm -f "$G"/*; scratch_rm "$H/state/merge-conductor/pr-files"; : > "$H/logs/merge-conductor.log"; printf '%s\n' "$SUITE" > "$G/files"; }
LIBROOT="$DIR"
# enq <head> — the real conductor lib and the real mc_enqueue_mergify. The
# Mergify witness/command reads are replaced; setting_get answers from $ROWS.
enq() { local head="$1"; (
  export PATH="$T/fakebin:$PATH" HARNESS="$H" TMPDIR="$T/tmp" GH_APP_TOKENS=0
  . "$LIBROOT/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_mergify_command() { return 0; }
  mc_queue_state() { printf 'queued'; }
  mc_mergify_witness() { return 0; }
  eval "$SETTING_STUB"
  _jobs_req() { return 0; }
  MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 mc_enqueue_mergify "$SLUG" "$U41" "$head"
) 2>"$T/enq.err"; }
qlog() { grep 'QFLAKE' "$H/logs/merge-conductor.log"; }
lineof() { grep -n -F -- "$1" "$G/calls" 2>/dev/null | head -1 | cut -d: -f1; }
ncalls() { grep -c . "$G/calls" 2>/dev/null || echo 0; }

# ── F9 (+F1 end to end): the label is POSTed BEFORE merge-queue ─────────────
conf with; ereset; : > "$ROWS"
OUT=$(enq "$HEAD1"); RC=$?
[ "$RC" = 0 ] && ok || bad "F9 the enqueue rc is unchanged (rc $RC, out $OUT, err $(cat "$T/enq.err"))"
F=$(lineof 'labels[]=queue-flake-fix'); M=$(lineof 'labels[]=merge-queue')
[ -n "$F" ] && [ -n "$M" ] && [ "$F" -lt "$M" ] && ok || bad "F9 queue-flake-fix is POSTed before merge-queue (flake line ${F:-none}, merge-queue line ${M:-none}): $(cat "$G/calls" 2>/dev/null)"
[ "$(qlog | grep -c .)" = 1 ] && qlog | grep -qF "QFLAKE $SLUG#41@${HEAD1:0:12} suite=$SUITE queue=flake-fix mode=enforce reason=in-scope" && ok \
  || bad "F1 exactly one QFLAKE line naming the PR, the suite and queue=flake-fix: $(cat "$H/logs/merge-conductor.log")"
# the label is already on the PR: no second POST
ereset; echo queue-flake-fix > "$G/labels"
enq "$HEAD1" >/dev/null
grep -q 'labels\[\]=queue-flake-fix' "$G/calls" && bad "F9 no POST when the PR already carries queue-flake-fix: $(cat "$G/calls")" || ok

# ── F2/F3 end to end: default, no label call ───────────────────────────────
ereset; printf 'tests/not-listed.bh-2-test.sh\n' > "$G/files"
enq "$HEAD1" >/dev/null
qlog | grep -qF "QFLAKE $SLUG#41@${HEAD1:0:12} suite=- queue=default mode=enforce reason=no-batch-fail-suite" && ok || bad "F2 the QFLAKE line says queue=default: $(qlog)"
grep -qE 'labels\[\]=queue-flake-fix|-X DELETE' "$G/calls" && bad "F2 no flake label call: $(cat "$G/calls")" || ok
grep -q 'labels\[\]=merge-queue' "$G/calls" && ok || bad "F2 the PR still gets merge-queue"
ereset; printf '%s\nbin/lib/rt/gate.sh\n' "$SUITE" > "$G/files"
enq "$HEAD1" >/dev/null
qlog | grep -qF "suite=$SUITE queue=default mode=enforce reason=out-of-scope:bin/lib/rt/gate.sh" && ok || bad "F3 the QFLAKE line names the suite and the out-of-scope file: $(qlog)"
grep -q 'labels\[\]=queue-flake-fix' "$G/calls" && bad "F3 no flake label POST" || ok

# ── F11: a default route removes a stale label; fix-main-red and train skip ─
ereset; printf 'docs/a.md\n' > "$G/files"; echo queue-flake-fix > "$G/labels"
enq "$HEAD1" >/dev/null
[ "$(grep -c -- '-X DELETE repos/example-org/cromford/issues/41/labels/queue-flake-fix' "$G/calls")" = 1 ] && ok \
  || bad "F11 a default route DELETEs the stale queue-flake-fix once: $(cat "$G/calls")"
ereset; echo fix-main-red > "$G/labels"
enq "$HEAD1" >/dev/null
qlog | grep -qF "suite=- queue=hotfix mode=enforce reason=fix-main-red" && ok || bad "F11 a fix-main-red PR logs queue=hotfix: $(qlog)"
grep -qE 'labels\[\]=queue-flake-fix|-X DELETE' "$G/calls" && bad "F11 fix-main-red: no flake label call: $(cat "$G/calls")" || ok
ereset; echo 'fix-main-red,queue-flake-fix' > "$G/labels"
enq "$HEAD1" >/dev/null
grep -q -- '-X DELETE' "$G/calls" && bad "F11 fix-main-red: a carried flake label is not touched" || ok
ereset; echo 'batch(cromford): land 3 approved siblings as one train' > "$G/title"
enq "$HEAD1" >/dev/null
qlog | grep -qF "queue=default mode=enforce reason=train" && ok || bad "F11 a train PR is skipped: $(qlog)"
grep -qE 'labels\[\]=queue-flake-fix|-X DELETE' "$G/calls" && bad "F11 train: no flake label call" || ok
# an unreadable PR: one line, no label call, merge-queue still runs
ereset; touch "$G/pr-500"
enq "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 0 ] && qlog | grep -qF "queue=default mode=enforce reason=pr-unreadable" && ok || bad "F11 an unreadable PR logs pr-unreadable (rc $RC): $(qlog)"
grep -qE 'labels\[\]=queue-flake-fix|-X DELETE' "$G/calls" && bad "F11 pr-unreadable: no flake label call" || ok
grep -q 'labels\[\]=merge-queue' "$G/calls" && ok || bad "F11 pr-unreadable: the PR still gets merge-queue"

# ── F10: the POST fails → one line, rc 0, merge-queue still runs ────────────
ereset; touch "$G/post-fail"
enq "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "F10 a failed flake label POST leaves the enqueue rc 0 (rc $RC)"
grep -qF "QFLAKE $SLUG#41: label queue-flake-fix could not be added (HTTP 422: fixture refusal) — it queues in default" "$H/logs/merge-conductor.log" && ok \
  || bad "F10 the failure line is logged: $(cat "$H/logs/merge-conductor.log")"
qlog | grep -qF "queue=flake-fix mode=enforce" && ok || bad "F10 the decision line is still there next to the failure: $(qlog)"
grep -q 'labels\[\]=merge-queue' "$G/calls" && ok || bad "F10 merge-queue is still POSTed"

# ── F6: shadow logs, writes nothing ─────────────────────────────────────────
ereset; : > "$ROWS"; row flake_fix.mode shadow
enq "$HEAD1" >/dev/null
qlog | grep -qF "queue=flake-fix mode=shadow (would route flake-fix) reason=in-scope" && ok || bad "F6 shadow says it would route flake-fix: $(qlog)"
grep -qE 'labels\[\]=queue-flake-fix|-X DELETE' "$G/calls" && bad "F6 shadow writes no label: $(cat "$G/calls")" || ok
ereset; echo queue-flake-fix > "$G/labels"; printf 'docs/a.md\n' > "$G/files"
enq "$HEAD1" >/dev/null
grep -q -- '-X DELETE' "$G/calls" && bad "F6 shadow never DELETEs" || ok

# ── F7 off / F8 no conf key: no read, no line, zero extra gh calls ──────────
MUT="$T/mut"; mkdir -p "$MUT/bin"
cp -r "$DIR/bin/lib" "$MUT/bin/lib"
grep -q '^  # >>> queue flake-fix (BH-7279)' "$MUT/bin/lib/mc/queue.sh" && ok || bad "F9 the marked block is in bin/lib/mc/queue.sh"
sed -i '/# >>> queue flake-fix (BH-7279)/,/# <<< queue flake-fix (BH-7279)/d' "$MUT/bin/lib/mc/queue.sh"
ereset; : > "$ROWS"
LIBROOT="$MUT" enq "$HEAD1" >/dev/null; N_MUT=$(ncalls)
! grep -q . <<<"$(qlog)" && ! grep -q 'labels\[\]=queue-flake-fix' "$G/calls" && ok \
  || bad "F9 with the block deleted there is no QFLAKE line and no queue-flake-fix POST (the mutation)"
ereset; : > "$ROWS"; row flake_fix.mode off
enq "$HEAD1" >/dev/null; RC=$?; N_OFF=$(ncalls)
[ "$RC" = 0 ] && ! grep -q . <<<"$(qlog)" && ok || bad "F7 mode off logs no QFLAKE line (rc $RC): $(qlog)"
[ "$N_OFF" = "$N_MUT" ] && [ "$N_MUT" -gt 0 ] && ok || bad "F7 mode off makes zero extra gh calls ($N_OFF vs $N_MUT with the block deleted)"
conf without; ereset; : > "$ROWS"
enq "$HEAD1" >/dev/null; N_NOKEY=$(ncalls)
! grep -q . <<<"$(qlog)" && ok || bad "F8 no flake_fix_label= logs no QFLAKE line: $(qlog)"
[ "$N_NOKEY" = "$N_MUT" ] && ok || bad "F8 no flake_fix_label= makes zero extra gh calls ($N_NOKEY vs $N_MUT)"
conf with

# ── F13: the rows and the list are read once per conductor tick ─────────────
: > "$ROWS"; SETCNT="$T/setcnt"; export SETCNT
ereset; : > "$SETCNT"
MC_TICK_ID=qff-tick-1 enq "$HEAD1" >/dev/null
N1=$(grep -c '^flake_fix\.' "$SETCNT")
# the run records go away mid-tick: the tick's cached list still names the suite
mv "$H/state/prequeue-learned/runs" "$T/runs-away"
ereset; : > "$SETCNT"
MC_TICK_ID=qff-tick-1 enq "$HEAD2" >/dev/null
N2=$(grep -c '^flake_fix\.' "$SETCNT")
qlog | grep -qF "QFLAKE $SLUG#41@${HEAD2:0:12} suite=$SUITE queue=flake-fix" && ok || bad "F13 the cached rows and list still route in the same tick: $(qlog)"
ereset; : > "$SETCNT"
MC_TICK_ID=qff-tick-2 enq "$HEAD1" >/dev/null
N3=$(grep -c '^flake_fix\.' "$SETCNT")
qlog | grep -qF "suite=- queue=default mode=enforce reason=no-batch-fail-suite" && ok || bad "F13 a new tick reads the list again: $(qlog)"
mv "$T/runs-away" "$H/state/prequeue-learned/runs"
[ "$N1" = 3 ] && ok || bad "F13 the first enqueue of a tick reads the 3 flake_fix rows ($N1 reads)"
[ "$N2" = 0 ] && ok || bad "F13 a second enqueue in the same tick reads no row ($N2 reads)"
[ "$N3" = "$N1" ] && ok || bad "F13 a new tick reads the rows again ($N3 reads, want $N1)"
unset SETCNT

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
