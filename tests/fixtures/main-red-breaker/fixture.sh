# tests/fixtures/main-red-breaker/fixture.sh — BH-8706: the recording fakes
# bin/main-red-breaker.sh sources through MAIN_RED_BREAKER_FIXTURE (sandbox
# only). $MRBK_F is the case directory. 0 network calls: gh_rest goes to
# fake_gh.py, and a path the fake does not know answers rc 99 plus an UNFAKED
# line in $MRBK_F/calls.
local_box_name() { echo hub-fixture; }
is_hub_box() { [ ! -e "$MRBK_F/not-hub" ]; }
mc_queue_provider() { cat "$MRBK_F/provider" 2>/dev/null || printf mergify; }
main_red_label_resolve() { echo fix-main-red; }
gh_default_auth_for_slug() { [ ! -e "$MRBK_F/noauth" ]; }
gh_rest() {
  local st
  python3 -I "$MRBK_FAKE" "$MRBK_F" gh "$@" > "$MRBK_F/gh.out" 2>>"$MRBK_F/gh.err"
  st=$(head -1 "$MRBK_F/gh.out")
  GH_REST_STATUS="${st:-000}"; GH_REST_REASON=
  case "$st" in
    2??) tail -n +2 "$MRBK_F/gh.out"; return 0 ;;
    404) return 44 ;;
    99) echo "UNFAKED $1 $2" >> "$MRBK_F/calls"; GH_REST_STATUS=000; return 99 ;;
    *) return 75 ;;
  esac
}
# The ledger: one JSON object per line in $MRBK_F/ledger, last write wins.
# $MRBK_F/ledger-rc.<kind> holds the rc a row read of that kind answers.
# $MRBK_F/put-fail fails every put; $MRBK_F/put-fail.<status> fails the puts of that status.
job_ledger_row() {
  echo "row $1 $2" >> "$MRBK_F/ledger.calls"
  local rc; rc=$(cat "$MRBK_F/ledger-rc.$1" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] || return "$rc"
  jq -ce --arg k "$1" --arg v "$2" 'select(.kind == $k and .key == $v) | {status, detail}' "$MRBK_F/ledger" 2>/dev/null \
    | tail -1 | grep . || return 2
}
job_ledger_put() {
  echo "put $1 $2 $3" >> "$MRBK_F/ledger.calls"
  [ -e "$MRBK_F/put-fail" ] && return 1
  [ -e "$MRBK_F/put-fail.$3" ] && return 1
  jq -nc --arg k "$1" --arg v "$2" --arg s "$3" --arg d "${4:-}" '{kind:$k, key:$v, status:$s, detail:$d}' >> "$MRBK_F/ledger"
}
# The resume's conductor calls. mc_requeue_mergify records "<slug> <url> <head>"
# in $MRBK_F/requeues and answers the rc in $MRBK_F/requeue-rc (default 0).
# mc_attempt_put/has keep their marks in $MRBK_F/attempts.
mc_requeue_mergify() {
  echo "$1 $2 $3" >> "$MRBK_F/requeues"
  return "$(cat "$MRBK_F/requeue-rc" 2>/dev/null || echo 0)"
}
mc_requeued_record() { echo "requeued $*" >> "$MRBK_F/attempts"; }
mc_attempt_put() { echo "$1" >> "$MRBK_F/attempts"; }
mc_attempt_has() { grep -qxF "$1" "$MRBK_F/attempts" 2>/dev/null; }
