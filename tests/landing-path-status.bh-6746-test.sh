#!/bin/bash
# tests/landing-path-status.bh-6746-test.sh — BH-6746 (wave 3 of #6541): the
# merge conductor mirrors the ledger's `path=direct` mark onto GitHub as the
# commit status `landing-path=success` / `path=direct` on the merge sha, so CI
# (bin/lib/ci-push-direct.sh cpd_landed) can plan the push as push-direct.
#
#   L1 landing_path_publish -> POST repos/o/r/statuses/<msha> with
#      context=landing-path, state=success, description=path=direct, and the
#      fields round-trip: cpd_landed accepts exactly what was sent
#   L2 mc_settle_merged with landing_direct_path true and a hex merge sha ->
#      one publish; with it false -> none
#   L3 a refused post (gh_rest rc 1, HTTP 403) -> rc 0 and one LANDING_PATH_OWED
#      line; no vs_publish loaded -> rc 0 and LANDING_PATH_OWED no-writer
#   L4 an empty merge sha -> no publish
#
# The real bin/lib/mc/landing.sh, bin/lib/mc/settle.sh, bin/lib/verdict-status.sh
# and bin/lib/ci-push-direct.sh are sourced; only gh_rest, gh_auth_for and the
# conductor's ledger/log helpers are stubs.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/landing-os
MSHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee6746
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa6746
URL="https://github.com/$SLUG/pull/6746"
KEY="$SLUG#6746"

# ── stubs (defined BEFORE the libs, so verdict-status.sh keeps them)
gh_rest() { printf '%s\n' "$*" >> "$T/rest.txt"; GH_REST_STATUS="${STUB_STATUS:-201}"; GH_REST_REASON="${STUB_REASON:-}"; return "${STUB_RC:-0}"; }
gh_auth_for() { return 0; }
mc_log() { printf '%s\n' "$*" >> "$T/log.txt"; }
# shellcheck source=bin/lib/verdict-status.sh
. "$DIR/bin/lib/verdict-status.sh" || exit 1
# shellcheck source=bin/lib/mc/landing.sh
. "$DIR/bin/lib/mc/landing.sh" || exit 1
# shellcheck source=bin/lib/mc/settle.sh
. "$DIR/bin/lib/mc/settle.sh" || exit 1
reset() { rm -f "$T/rest.txt" "$T/log.txt"; }

# ── L1. the writer's exact fields, and the reader accepts them.
reset
landing_path_publish "$SLUG" "$MSHA" "$URL" "$KEY"; RC=$?
[ "$RC" = 0 ] && ok || bad "L1: rc=$RC"
[ "$(grep -c . "$T/rest.txt" 2>/dev/null)" = 1 ] && ok || bad "L1: one POST expected: $(cat "$T/rest.txt" 2>/dev/null)"
R=$(cat "$T/rest.txt" 2>/dev/null)
case "$R" in "POST repos/$SLUG/statuses/$MSHA "*) ok ;; *) bad "L1: POST to the merge sha's statuses, got '$R'" ;; esac
for f in "state=success" "context=landing-path" "description=path=direct" "target_url=$URL"; do
  case " $R " in *" -f $f "*) ok ;; *) bad "L1: field '$f' missing in '$R'" ;; esac
done
grep -q "$KEY LANDING_PATH_PUBLISHED" "$T/log.txt" && ok || bad "L1: the log must say published: $(cat "$T/log.txt" 2>/dev/null)"
# Round trip: the sent fields, as a statuses-list entry, satisfy cpd_landed.
CTX=$(sed -n 's/.* -f context=\([^ ]*\) .*/\1/p' <<<"$R"); STA=$(sed -n 's/.* -f state=\([^ ]*\) .*/\1/p' <<<"$R")
DSC=$(sed -n 's/.* -f description=\([^ ]*\) .*/\1/p' <<<"$R")
jq -nc --arg c "$CTX" --arg s "$STA" --arg d "$DSC" '[{context:$c, state:$s, description:$d}]' > "$T/sent.json"
printf '#!/bin/bash\ncat "%s"\n' "$T/sent.json" > "$T/gh"; chmod +x "$T/gh"
(
  # shellcheck source=bin/lib/ci-push-direct.sh
  . "$DIR/bin/lib/ci-push-direct.sh" || exit 3
  CI_PLAN_GH="$T/gh" CI_REPO="$SLUG" CI_SHA="$MSHA" CI_PLAN_DIRECT_WAIT_S=1 CI_PLAN_DIRECT_POLL_S=1 cpd_landed
); RC=$?
[ "$RC" = 0 ] && ok || bad "L1: cpd_landed must accept what landing_path_publish sends (rc=$RC, sent $(cat "$T/sent.json"))"

# ── L3. a refused post is a record, never a failure.
reset
STUB_RC=1 STUB_STATUS=403 STUB_REASON="Resource not accessible" landing_path_publish "$SLUG" "$MSHA" "$URL" "$KEY"; RC=$?
[ "$RC" = 0 ] && ok || bad "L3: a refused post must still be rc 0 (rc=$RC)"
[ "$(grep -c "LANDING_PATH_OWED" "$T/log.txt" 2>/dev/null)" = 1 ] && grep -q "HTTP 403" "$T/log.txt" && ok \
  || bad "L3: one LANDING_PATH_OWED line naming the HTTP answer: $(cat "$T/log.txt" 2>/dev/null)"
reset
( unset -f vs_publish; landing_path_publish "$SLUG" "$MSHA" "$URL" "$KEY" ); RC=$?
[ "$RC" = 0 ] && grep -q "$KEY LANDING_PATH_OWED no-writer" "$T/log.txt" && [ ! -s "$T/rest.txt" ] && ok \
  || bad "L3: no vs_publish -> rc 0, a no-writer line, no POST (rc=$RC log=$(cat "$T/log.txt" 2>/dev/null))"

# ── L2/L4. mc_settle_merged: the production caller.
MC_H="$T/h"; MC_STATE_DIR="$T/state"; mkdir -p "$MC_H/bin" "$MC_STATE_DIR" || exit 1
printf '#!/bin/bash\necho demo\n' > "$MC_H/bin/fleet-conf.sh"   # not "-": no issue close
printf '#!/bin/bash\nexit 0\n' > "$MC_H/bin/beat.sh"
chmod +x "$MC_H/bin/"*
mc_pr_view() { printf '%s' "${STUB_PR_MSHA:-}"; }
mc_attempt_has() { return 0; }   # the deploy hand-off is already done: no deploy lane here
mc_attempt_put() { :; }
DIRECT=no
landing_direct_path() { [ "$DIRECT" = yes ]; }

reset; DIRECT=yes
OUT=$(mc_settle_merged "$KEY" "$URL" landing "$SLUG" ticket/bh-6746 "" - "$HEAD" "$MSHA"); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = "$MSHA" ]; } && ok || bad "L2: settle rc=$RC out='$OUT'"
[ "$(grep -c "statuses/$MSHA" "$T/rest.txt" 2>/dev/null)" = 1 ] && grep -q "context=landing-path" "$T/rest.txt" && ok \
  || bad "L2: a direct landing posts exactly one landing-path status: $(cat "$T/rest.txt" 2>/dev/null)"

reset; DIRECT=no
mc_settle_merged "$KEY" "$URL" landing "$SLUG" ticket/bh-6746 "" - "$HEAD" "$MSHA" >/dev/null
[ ! -s "$T/rest.txt" ] && ok || bad "L2: a queue landing posts no landing-path status: $(cat "$T/rest.txt")"

reset; DIRECT=yes
STUB_PR_MSHA="" mc_settle_merged "$KEY" "$URL" landing "$SLUG" ticket/bh-6746 "" - "$HEAD" "" >/dev/null
[ ! -s "$T/rest.txt" ] && ok || bad "L4: no merge sha -> no publish: $(cat "$T/rest.txt")"

echo "landing-path-status: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
