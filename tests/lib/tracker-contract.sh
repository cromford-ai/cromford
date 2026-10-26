#!/bin/bash
# tests/lib/tracker-contract.sh — the tracker contract cases (bin/lib/tracker.sh,
# BH-4075), adapter-agnostic. tests/tracker-contract-test.sh runs them against
# every adapter; a new tracker (Jira, Linear) adds its setup there and passes
# the same eleven cases unchanged.
#
#   tracker_contract_run <adapter>
#
# The suite provides, per adapter, a function tc_setup_<adapter with - as _>
# that loads the adapter, seeds its stub and sets:
#   TC_PROJECT   the fleet.conf project tracker_waiting_on asks the gate about
#   TC_T TC_Q TC_M  a feature ticket with 3 comments, a ticket waiting on the
#                client, and an id that does not exist
#   TC_TERMINAL  the status close_out moves to by default
#   TC_Q_WAIT    what tracker_waiting_on answers for TC_Q
#   TC_LABELS    1 = label verbs supported, 0 = they answer 3
#   TC_SECRET    a string that must reach no file under TC_SCAN_ROOT
#   TC_SCAN_ROOT the directories C11 scans, space-separated
# and these stub hooks:
#   tc_reset        clear the write log and every arm
#   tc_arm <name>   transition_fail | comment_fail | ratelimit
#   tc_writes       the writes the stub received, one per line, in order:
#                   `comment <id>`, `status <id> <status>`, `label_add <id> <l>`,
#                   `label_remove <id> <l>`, `attachment <id>`
#   tc_body <n>     the body of the n-th comment (or attachment) the stub received
# and, optionally:
#   TC_LINK_WRITE   the write link_pr makes: `comment` (the default) or
#                   `attachment` for a tracker with a real PR link (Linear)
#
# Counts go into TC_PASS / TC_FAIL; each failure prints one FAIL line.

TC_PASS=${TC_PASS:-0}; TC_FAIL=${TC_FAIL:-0}
_tc_ok()  { TC_PASS=$((TC_PASS+1)); }
_tc_bad() { TC_FAIL=$((TC_FAIL+1)); echo "FAIL ${TC_A:+[$TC_A] }$1"; }
_tc_nw()  { tc_writes | grep -c .; }

tracker_contract_run() {
  local TC_A="$1" out rc f n i
  "tc_setup_${TC_A//-/_}" || { _tc_bad "setup failed"; return 1; }
  [ "${TRK_ADAPTER:-}" = "$TC_A" ] && _tc_ok || _tc_bad "setup did not load the adapter (TRK_ADAPTER=${TRK_ADAPTER:-})"
  f=$(mktemp "${TMPDIR:-/tmp}/tc-body.XXXXXX")
  printf 'We shipped the export.\nIt is on the ledger page.\n' > "$f"

  # C1 list
  tc_reset
  out=$(tracker_list); rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e 'type == "array" and length > 0 and all(.[]; (.id | type == "string" and length > 0) and (.title | type == "string" and length > 0))' >/dev/null 2>&1; then _tc_ok
  else _tc_bad "C1 list must be an array of rows with id and title (rc=$rc): $out"; fi
  printf '%s' "$out" | jq -e --arg t "$TC_T" 'any(.[]; .id == $t)' >/dev/null 2>&1 && _tc_ok || _tc_bad "C1 $TC_T not in the list: $out"
  [ "$(_tc_nw)" = 0 ] && _tc_ok || _tc_bad "C1 a list wrote: $(tc_writes)"

  # C2 read
  out=$(tracker_read "$TC_T"); rc=$?
  [ "$rc" = 0 ] && _tc_ok || _tc_bad "C2 read $TC_T rc=$rc"
  [ "$(printf '%s' "$out" | jq -c 'keys' 2>/dev/null)" = '["body","comments","id","key","labels","state","status","title","triageVerdict","url","waitingOn"]' ] \
    && _tc_ok || _tc_bad "C2 the 11 normalized keys: $out"
  printf '%s' "$out" | jq -e '.state == "open" or .state == "closed"' >/dev/null 2>&1 \
    && _tc_ok || _tc_bad "C2 state must be open or closed: $out"
  [ "$(printf '%s' "$out" | jq -c '[.comments[].body]' 2>/dev/null)" = '["first","second","third"]' ] \
    && _tc_ok || _tc_bad "C2 three comments in the stub's order: $(printf '%s' "$out" | jq -c .comments 2>/dev/null)"
  printf '%s' "$out" | jq -e '[.waitingOn, .triageVerdict] | all(.[]; . == null or (type == "string" and length > 0))' >/dev/null 2>&1 \
    && _tc_ok || _tc_bad "C2 waitingOn/triageVerdict must be a string or null, never \"\": $out"
  printf '%s' "$out" | jq -e --arg t "$TC_T" '.id == $t and (.labels | type == "array") and (.comments | all(.[]; (.internal | type) == "boolean"))' >/dev/null 2>&1 \
    && _tc_ok || _tc_bad "C2 id/labels/internal shapes: $out"

  # C3 missing, and the rate-limit arm
  out=$(tracker_read "$TC_M"); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && _tc_ok || _tc_bad "C3 a missing ticket must be rc 1 with no output (rc=$rc out=$out)"
  tc_arm ratelimit
  out=$(tracker_read "$TC_T"); rc=$?
  case "$rc" in 1|75) [ -z "$out" ] && _tc_ok || _tc_bad "C3 rate-limited read printed: $out" ;; *) _tc_bad "C3 rate-limited read rc=$rc" ;; esac
  tc_reset

  # C4 comment
  tracker_comment "$TC_T" "$f" >/dev/null; rc=$?
  [ "$rc" = 0 ] && _tc_ok || _tc_bad "C4 comment rc=$rc"
  [ "$(tc_writes)" = "comment $TC_T" ] && _tc_ok || _tc_bad "C4 exactly one comment write: $(tc_writes)"
  [ "$(tc_body 1)" = "$(cat "$f")" ] && _tc_ok || _tc_bad "C4 the body the tracker received: [$(tc_body 1)]"

  # C5 transition
  tc_reset
  tracker_transition "$TC_T" "$TC_TERMINAL" >/dev/null; rc=$?
  [ "$rc" = 0 ] && _tc_ok || _tc_bad "C5 transition to $TC_TERMINAL rc=$rc"
  [ "$(tc_writes)" = "status $TC_T $TC_TERMINAL" ] && _tc_ok || _tc_bad "C5 one status write: $(tc_writes)"
  tc_reset; tc_arm transition_fail
  tracker_transition "$TC_T" "$TC_TERMINAL" >/dev/null; rc=$?
  [ "$rc" = 1 ] && _tc_ok || _tc_bad "C5 a transition that did not take must be rc 1 (rc=$rc)"
  tc_reset
  tracker_transition "$TC_T" shipped >/dev/null; rc=$?
  [ "$rc" = 3 ] && _tc_ok || _tc_bad "C5 an unknown status must be rc 3 (rc=$rc)"
  [ "$(_tc_nw)" = 0 ] && _tc_ok || _tc_bad "C5 an unknown status sent: $(tc_writes)"

  # C6 labels
  tc_reset
  if [ "$TC_LABELS" = 1 ]; then
    tracker_label_add "$TC_T" tc-x >/dev/null; rc=$?
    [ "$rc" = 0 ] && _tc_ok || _tc_bad "C6 label_add rc=$rc"
    tracker_label_remove "$TC_T" tc-x >/dev/null; rc=$?
    [ "$rc" = 0 ] && _tc_ok || _tc_bad "C6 label_remove rc=$rc"
    tracker_label_remove "$TC_T" tc-x >/dev/null; rc=$?
    [ "$rc" = 44 ] && _tc_ok || _tc_bad "C6 removing a label that is not there must be rc 44 (rc=$rc)"
    [ "$(tc_writes | head -2 | tr '\n' '|')" = "label_add $TC_T tc-x|label_remove $TC_T tc-x|" ] && _tc_ok || _tc_bad "C6 writes: $(tc_writes)"
  else
    tracker_label_add "$TC_T" tc-x >/dev/null; rc=$?
    [ "$rc" = 3 ] && _tc_ok || _tc_bad "C6 label_add must be UNSUPPORTED (rc=$rc)"
    tracker_label_remove "$TC_T" tc-x >/dev/null; rc=$?
    [ "$rc" = 3 ] && _tc_ok || _tc_bad "C6 label_remove must be UNSUPPORTED (rc=$rc)"
    [ "$(_tc_nw)" = 0 ] && _tc_ok || _tc_bad "C6 an unsupported label verb sent: $(tc_writes)"
  fi

  # C7 link_pr
  tc_reset
  tracker_link_pr "$TC_T" https://github.com/o/r/pull/9 >/dev/null; rc=$?
  [ "$rc" = 0 ] && _tc_ok || _tc_bad "C7 link_pr rc=$rc"
  [ "$(tc_writes)" = "${TC_LINK_WRITE:-comment} $TC_T" ] && _tc_ok || _tc_bad "C7 one ${TC_LINK_WRITE:-comment} write: $(tc_writes)"
  case "$(tc_body 1)" in *https://github.com/o/r/pull/9*) _tc_ok ;; *) _tc_bad "C7 the ${TC_LINK_WRITE:-comment} carries the URL: [$(tc_body 1)]" ;; esac
  tc_reset
  tracker_link_pr "$TC_T" https://example.com/o/r/pull/9 >/dev/null; rc=$?
  [ "$rc" = 1 ] && [ "$(_tc_nw)" = 0 ] && _tc_ok || _tc_bad "C7 a non-PR URL must be rc 1 with no write (rc=$rc, $(tc_writes))"

  # C8 close_out: the comment, then the status, and no status without the comment
  tc_reset
  tracker_close_out "$TC_T" "$f" >/dev/null; rc=$?
  [ "$rc" = 0 ] && _tc_ok || _tc_bad "C8 close_out rc=$rc"
  [ "$(tc_writes | tr '\n' '|')" = "comment $TC_T|status $TC_T $TC_TERMINAL|" ] && _tc_ok || _tc_bad "C8 comment then $TC_TERMINAL: $(tc_writes)"
  tc_reset; tc_arm comment_fail
  tracker_close_out "$TC_T" "$f" >/dev/null; rc=$?
  [ "$rc" = 1 ] && _tc_ok || _tc_bad "C8 a failed comment must fail the close_out (rc=$rc)"
  tc_writes | grep -q '^status ' && _tc_bad "C8 moved the ticket after its comment failed: $(tc_writes)" || _tc_ok
  tc_reset

  # C9 waiting_on, through the real bin/triage-gate.sh
  out=$(tracker_waiting_on "$TC_PROJECT" "$TC_Q"); rc=$?
  [ "$rc" = 0 ] && [ "$out" = "$TC_Q_WAIT" ] && _tc_ok || _tc_bad "C9 $TC_Q must answer '$TC_Q_WAIT' (rc=$rc out=$out)"
  out=$(tracker_waiting_on "$TC_PROJECT" "$TC_T"); rc=$?
  [ "$rc" = 0 ] && [ "$out" = OK ] && _tc_ok || _tc_bad "C9 $TC_T must answer OK (rc=$rc out=$out)"

  # C10 dry run: every write verb prints and sends nothing
  tc_reset
  _tc_dry() { # _tc_dry <label> <want DRYRUN lines> <verb> [args]
    local label="$1" want="$2" o r; shift 2
    o=$(TRK_DRY=1 "$@"); r=$?
    [ "$r" = 0 ] && _tc_ok || _tc_bad "C10 dry $label rc=$r"
    [ "$(printf '%s\n' "$o" | grep -c '^DRYRUN ')" = "$want" ] && _tc_ok || _tc_bad "C10 dry $label must print $want DRYRUN line(s): $o"
  }
  _tc_dry comment 1 tracker_comment "$TC_T" "$f"
  _tc_dry transition 1 tracker_transition "$TC_T" "$TC_TERMINAL"
  _tc_dry link_pr 1 tracker_link_pr "$TC_T" https://github.com/o/r/pull/9
  _tc_dry close_out 2 tracker_close_out "$TC_T" "$f"
  if [ "$TC_LABELS" = 1 ]; then
    _tc_dry label_add 1 tracker_label_add "$TC_T" tc-x
    _tc_dry label_remove 1 tracker_label_remove "$TC_T" tc-x
  fi
  [ "$(_tc_nw)" = 0 ] && _tc_ok || _tc_bad "C10 a dry run sent: $(tc_writes)"

  # C11 the secret reached no file (TC_SCAN_ROOT may name several directories)
  local roots=()
  read -ra roots <<<"$TC_SCAN_ROOT"
  n=$(grep -rlF -- "$TC_SECRET" "${roots[@]}" 2>/dev/null | grep -c .)
  [ "$n" = 0 ] && _tc_ok || _tc_bad "C11 the secret reached: $(grep -rlF -- "$TC_SECRET" "${roots[@]}")"
  i=$(find "${roots[@]}" -type f 2>/dev/null | grep -c .)
  [ "$i" -gt 0 ] && _tc_ok || _tc_bad "C11 scanned an empty tree"
  rm -f "$f"
  return 0
}
