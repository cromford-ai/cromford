#!/bin/bash
# tests/mc-eject-unknown.bh-9695-test.sh — BH-9695: a head that Mergify ejects
# a second time with the recorded cause `unknown` gets ONE read of Mergify's
# activity log. A named cause parks it as before, with the cause in the reason.
# Still unknown: ONE more requeue, not a park. The ejection after that parks
# BLOCKED_HUMAN with "no named cause after the Mergify event read and one more
# requeue (BH-9695)". That is the cap.
#
# Driven, not grepped. The fragment, the eject-cause lib and the Mergify seam
# are the real files. The conductor's blocks (the settle arm from its
# `ejected` mark to the arm's `fi ;;`, the `parked merged settle` block and the
# two re-entry-arm park decisions) are extracted VERBATIM; so are
# mc_requeued_mark / mc_ejection_live / mc_bv_requeue_live (classify lib) and
# the strike counters (queue lib). Every gh, GitHub and Mergify call is a
# stub or the seam's fake (HARNESS_VENDOR_FAKE=1, a per-case seed dir). curl
# and gh on PATH record and fail. Each case has its own scratch dir, ledger,
# record and key. The clock is pinned.
#   V1-V8   the seam (bin/lib/vendor/mergify.sh)
#   E1-E17  mc_eu_event_cause over tests/fixtures/bh-9695/queue-leave-events.json
#   D1-D22  mc_eu_decide
#   S1-S12  mc_eu_requeue exit paths, marks and budgets
#   A1-A8   the settle arm
#   B1-B5   the parked-row pass
#   R1-R4   the ticks after the extra requeue (re-entry arm)
#   W1-W5   writer/reader round trips of the record and the ledger
#   K1-K4   knobs
#   M1      mutation guard: no fragment = today's park
#   Z1      0 vendor calls
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-eject-unknown.bh-9695-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
unset GH_TOKEN GITHUB_TOKEN MERGIFY_API_TOKEN MERGIFY_API_URL MC_EJECT_UNKNOWN_REQUEUE MC_EJECT_EVENT_READS \
  MERGIFY_API_TIMEOUT_S MERGIFY_EVENTS_PER_PAGE VENDOR_CALL_LOG HARNESS_VENDOR_FAKE HARNESS_VENDOR_FAKE_DIR

FRAG="$DIR/bin/merge-conductor.d/bh-9695-eject-unknown.sh"
BVFRAG="$DIR/bin/merge-conductor.d/bh-9253-batch-victim.sh"
EC="$DIR/bin/lib/mc-eject-cause.sh"
SEAM="$DIR/bin/lib/vendor/mergify.sh"
MC="$DIR/bin/merge-conductor.sh"
FX="$DIR/tests/fixtures/bh-9695/queue-leave-events.json"
BVFX="$DIR/tests/fixtures/bh-9229/pr9189-mergify-comments.json"
SLUG=example-org/cromford
TAB=$'\t'
CAP=' — no named cause after the Mergify event read and one more requeue (BH-9695)'

fnx() { # fnx <file> <name> — one function, verbatim
  awk -v n="$2" '!f && $0 ~ "^"n"\\(\\)[[:space:]]*\\{" {f=1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next} f {print} f && /^}/ {exit}' "$1"
}
blk() { awk -v b="$2" 'index($0, "# >>> " b) {f=1; next} index($0, "# <<< " b) {exit} f' "$1"; }

# --- the extracted pieces ----------------------------------------------------------
{ for fn in mc_requeued_mark mc_requeued_record mc_ejection_live mc_bv_requeue_live mc_label_add; do fnx "$DIR/bin/lib/mc/classify.sh" "$fn"; done
  for fn in mc_eject_nv_heads mc_eject_strikes mc_eject_head_strikes mc_mergify_payload_dequeue; do fnx "$DIR/bin/lib/mc/queue.sh" "$fn"; done
} > "$T/fns.sh"
for fn in mc_requeued_mark mc_requeued_record mc_ejection_live mc_bv_requeue_live mc_label_add mc_eject_nv_heads mc_eject_strikes mc_eject_head_strikes mc_mergify_payload_dequeue; do
  grep -q "^$fn()" "$T/fns.sh" || bad "could not extract $fn"
done
# The settle arm: from its `ejected` mark to the arm's closing `fi ;;`.
awk 'index($0, "mc_attempt_has \"ejected $QKEY $QHEAD\" || mc_attempt_put \"ejected $QKEY $QHEAD\"") {f=1}
     f {print} f && /^[[:space:]]*fi ;;[[:space:]]*$/ {exit}' "$MC" | sed '$ s/fi ;;[[:space:]]*$/fi/' > "$T/settle.sh"
blk "$MC" "parked merged settle" > "$T/parked.sh"
# The re-entry arm, first park site: from the batch-victim comment to the
# this-tick-ejected test (so the `requeued … waiting` answer is in), closed
# with `fi`.
awk 'index($0, "# A batch victim requeued solo on this head (BH-9253)") {f=1}
     f && index($0, "elif mc_tick_ejected_now") {exit} f' "$MC" > "$T/reentry.sh"
printf 'fi\n' >> "$T/reentry.sh"
# The re-entry arm, culprit park site: its `if EJN >= 2 … fi` lines.
awk 'index($0, "# >>> eject culprit") {g=1} g && index($0, "if [ \"${EJN:-0}\" -ge 2 ]; then STATE=BLOCKED_HUMAN") {f=1}
     f {print} f && /; fi$/ {exit}' "$MC" > "$T/culprit.sh"
for b in settle parked reentry culprit; do
  [ -s "$T/$b.sh" ] && bash -n "$T/$b.sh" && ok || bad "could not extract the conductor's $b block"
done
grep -q 'mc_bv_solo' "$T/settle.sh" && grep -q 'ec_record' "$T/settle.sh" && ok || bad "the settle extraction lost the batch-victim or record step"

mkdir -p "$T/fakebin"
for b in gh curl; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "%s/unstubbed"\nexit 1\n' "$b" "$T" > "$T/fakebin/$b"; chmod +x "$T/fakebin/$b"
done
: > "$T/unstubbed"
: > "$T/vcalls"
jq '[.[] | select(.id != 6715131096)]' "$BVFX" > "$T/c-bm.json"   # newest mergify comment = BATCH_MAX
printf '[]\n' > "$T/c-none.json"

key_of() { printf '%s#%s' "$SLUG" "$((9000 + $(printf '%s' "$1" | cksum | cut -c1-4) % 900))"; }
head_of() { printf '%s' "$1" | sha1sum | cut -c1-40; }

# drive <case> <mode> [VAR=val...] — one conductor path in a fresh shell.
#   mode: settle | parked | eu | reentry | culprit | why | ord
#   Case files under $T/<case>/: att log trans writes reads views rel fbh
#   fixnow seam rc out state/eject-cause/<repo>_<n>. DRIVE_KEEP=1 keeps the
#   ledger and the record (the next tick of the same head).
# Knobs: EV (fixture case for the fake seed, `-` = not seeded), SEED (ledger
#   lines `|`-separated, KEY/HEAD substituted), REC (record lines `ord:cause`,
#   `|`-separated, written by the real ec_record), EC (ec_cause answer), VERD,
#   VREV, LIVE, MERGES, ACTIONS, EVBUD (event budget left), RQBUD (requeue
#   budget left), RQRC, CF (comments), CI, FRAG_ON, ROWST, ROWWHY, PROVIDER_,
#   FAKE (1).
drive() {
  local c="$1" mode="$2"; shift 2
  mkdir -p "$T/$c"
  if [ "${DRIVE_KEEP:-0}" != 1 ]; then : > "$T/$c/att"; rm -rf "$T/$c/state" "$T/$c/seam-all"; fi
  rm -f "$T/$c/budget-"*   # a drive is one tick: the per-tick budgets start at 0
  for x in log trans writes reads views rel fbh fixnow seam rc out settled; do : > "$T/$c/$x"; done
  env EV=unknown SEED="" REC="" EC="unknown${TAB}no Mergify dequeue reason" VERD=APPROVE VREV="$(head_of "$c")" \
      LIVE="$(head_of "$c")" MERGES=1 ACTIONS=1 EVBUD=9 RQBUD=9 RQRC=0 CF="$T/c-none.json" CI=green FRAG_ON=1 \
      ROWST=BLOCKED_HUMAN ROWWHY="queue-ejected-twice: 1 unknown (no Mergify dequeue reason) on x" PROVIDER_=mergify FAKE=1 \
      "$@" BUDDIR="${BUDDIR:-}" PATH="$T/fakebin:$PATH" T="$T" C="$T/$c" FRAG="$FRAG" BVFRAG="$BVFRAG" EC_LIB="$EC" SEAM="$SEAM" FX="$FX" \
      HD="$(head_of "$c")" KY="$(key_of "$c")" MODE="$mode" SLUG="$SLUG" bash -c '
    set -uo pipefail
    . "$T/fns.sh"
    . "$EC_LIB"
    . "$BVFRAG"
    [ "$FRAG_ON" = 1 ] && . "$FRAG"
    NUM="${KY##*#}"
    # The seam: the real file in fake mode, seeded for this PR, every call counted.
    mkdir -p "$C/fake"
    # The fixture head (._head, and its 7-char prefix) becomes this case head.
    if [ "$EV" != - ]; then jq --arg n "$NUM" --arg e "$EV" --arg hd "$HD" "._head as \$fh | {queue_leave_events: {(\$n): (.[\$e] | walk(if type == \"string\" and . == \$fh then \$hd elif type == \"string\" and . == \$fh[:7] then \$hd[:7] else . end))}}" "$FX" > "$C/fake/mergify.json"
    else printf "{\"queue_leave_events\": {}}\n" > "$C/fake/mergify.json"; fi
    [ "$FAKE" = 1 ] && export HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$C/fake"
    export VENDOR_CALL_LOG="$T/vcalls"
    . "$SEAM"
    eval "_seam_$(declare -f mergify_queue_leave_events)"
    mergify_queue_leave_events() { printf "%s\n" "$*" | tee -a "$C/seam-all" >> "$C/seam"; _seam_mergify_queue_leave_events "$@"; }
    MC_STATE_DIR="$C/state"
    mc_now() { printf 1763460000; }
    mc_log() { printf "%s\n" "$*" >> "$C/log"; }
    mc_attempt_has() { grep -qxF "$1" "$C/att" 2>/dev/null; }
    mc_attempt_put() { printf "%s\n" "$1" >> "$C/att"; }
    mc_attempt_clear() { grep -vxF "$1 $2 $3" "$C/att" > "$C/att.tmp"; mv -f "$C/att.tmp" "$C/att"; }
    mc_attempt_tail() { awk -v k="$1 $2 $3" "index(\$0, k\" \")==1 { sub(/^[^ ]+ [^ ]+ [^ ]+ ?/, \"\"); print; exit }" "$C/att"; }
    mc_attempt_lines() { : > "$3"; awk -v ks="$1" -v k="$2" "BEGIN { n = split(ks, a, \"|\"); for (i = 1; i <= n; i++) m[a[i]] = 1 } (\$1 in m) && \$2 == k" "$C/att" > "$3"; [ -s "$3" ] || return 2; }
    mc_attempt_count() { awk -v k="$2" -v h="${3:-}" -v ks="$1" "BEGIN { n = split(ks, a, \"|\"); for (i = 1; i <= n; i++) m[a[i]] = 1 } (\$1 in m) && \$2 == k && (h == \"\" || \$3 == h) { c++ } END { print c + 0 }" "$C/att"; }
    mc_tick_budget_take() { local f="${BUDDIR:-$C}/budget-$2" n lim="${3:-0}"
      printf "budget %s %s\n" "$2" "$lim" >> "$C/reads"
      case "$lim" in ""|*[!0-9]*) lim=0 ;; esac; [ "$lim" -gt 0 ] || return 1
      n=$(cat "$f" 2>/dev/null || echo 0); [ "$n" -lt "$lim" ] || return 1
      case "$2" in ejevent) [ "$n" -lt "$EVBUD" ] || return 1 ;; requeue) [ "$n" -lt "$RQBUD" ] || return 1 ;; esac
      echo $((n + 1)) > "$f"; }
    mc_record_for() { printf "%s" "$C/rec"; }
    mc_verdict() { printf "verdict\n" >> "$C/reads"; printf "%s\t-\t%s\t-\t-" "$VERD" "$VREV"; }
    mc_pr_view() { printf "%s\n" "$2" >> "$C/views"
      case "$2" in *STATE*) printf "OPEN ticket/bh-1" ;; *) printf "%s" "$LIVE" ;; esac; }
    mc_ci_state() { printf "ci %s\n" "$*" >> "$C/reads"; printf "%s" "$CI"; }
    gh_rest_issue_comments() { printf "comments %s\n" "$*" >> "$C/reads"; cat "$CF"; }
    mc_rest_var() { local __v="$1"; shift; local __o; __o=$("$@") || return 1; printf -v "$__v" "%s" "$__o"; }
    prr_write() { shift 4; printf "%s\n" "$*" >> "$C/writes"; return 0; }
    mc_requeue_mergify() { printf "requeue %s\n" "$*" >> "$C/writes"; return "$RQRC"; }
    mc_transition() { printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$C/trans"; }
    mc_handoff_release() { printf "%s\n" "$*" >> "$C/rel"; }
    mc_fbh_clear() { printf "%s\n" "$*" >> "$C/fbh"; }
    mc_eject_fix_now() { printf "%s\n" "$*" >> "$C/fixnow"; }
    mc_tick_eject_note() { :; }
    mc_eject_conflict_note() { :; }
    mc_dequeue_label() { return 0; }
    mc_dequeue_reason() { printf ""; }
    mc_dequeue_surface() { :; }
    ec_cause() { printf "%s\n" "$EC"; }
    mc_only_has() { return 0; }
    mc_pr_lock() { printf "%s" "$C/lock"; }
    conductor_settle() { printf "%s\n" "$*" >> "$C/settled"; }
    P=cromford; PROVIDER="$PROVIDER_"; MC_MERGIFY_LABEL=merge-queue
    EJWHY="queue-ejected — push a fix; the next head is enqueued on its own merits"
    QKEY="$KY"; QHEAD="$HD"; QURL="https://github.com/$SLUG/pull/$NUM"
    QREV="$HD"; QVERDICT=APPROVE; QREC="$C/rec"; QLIVE="$HD"
    if [ -n "$SEED" ]; then
      IFS="|" read -r -a L <<<"$SEED"
      for l in "${L[@]}"; do l="${l//KEY/$KY}"; printf "%s\n" "${l//HEAD/$HD}" >> "$C/att"; done
    fi
    if [ -n "$REC" ]; then
      IFS="|" read -r -a L <<<"$REC"
      for l in "${L[@]}"; do o="${l%%:*}"; r="${l#*:}"; ec_record "$SLUG" "$NUM" "$HD" "$o" "${r%%:*}" "$( [ "${r#*:}" != "$r" ] && printf "%s" "${r#*:}")"; done
    fi
    case "$MODE" in
      settle) . "$T/settle.sh" ;;
      parked)
        MC_ROWS="$C/rows"
        printf "%s\t%s\t1762560000\t%s\t%s\t-\t%s\t%s\n" "$QKEY" "$ROWST" "$HD" "$HD" "$ROWWHY" "$QURL" > "$MC_ROWS"
        . "$T/parked.sh" ;;
      eu) rc=0; mc_eu_requeue "$P" "$SLUG" "$QKEY" "$QHEAD" "$QURL" || rc=$?; printf "%s" "$rc" > "$C/rc" ;;
      reentry|culprit)
        KEY="$QKEY"; HEAD="$HD"; STATE=READY; WHY=""; EJN=$(mc_eject_head_strikes "$KEY" "$HEAD")
        e=0; mc_ejection_live "$KEY" "$HEAD" || e=$?
        if [ "$MODE" = reentry ]; then . "$T/reentry.sh"; else . "$T/culprit.sh"; fi
        printf "%s %s|%s|%s" "$e" "$EJN" "$STATE" "$WHY" > "$C/out" ;;
    esac'
}
f() { cat "$T/$1/$2" 2>/dev/null; }
has() { grep -qF -- "$3" "$T/$1/$2" 2>/dev/null; }
n_of() { local n; n=$(grep -c . "$T/$1/$2" 2>/dev/null) || true; printf '%s' "${n:-0}"; }
recf() { local k; k=$(key_of "$1"); printf '%s/%s/state/eject-cause/%s_%s' "$T" "$1" "${SLUG//\//_}" "${k##*#}"; }
UNK_SEED="ejected KEY HEAD|requeued KEY HEAD 1763450000"      # one requeue done
UNK_REC="first:unknown:no Mergify dequeue reason"

# --- V. the seam --------------------------------------------------------------------
seam() { # seam <env...> -- <args...> ; prints "rc|stdout|stderr"
  local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  env -i PATH="$T/vbin:$PATH" HOME="$T" "${e[@]}" bash -c '. "$1"; shift; o=$(mergify_queue_leave_events "$@" 2>"$T_ERR"); rc=$?; printf "%s|%s|%s" "$rc" "$o" "$(cat "$T_ERR")"' _ "$SEAM" "$@"
}
mkdir -p "$T/vbin" "$T/vfake"
# A curl stub that records argv and stdin, writes the -o body and the -w code.
cat > "$T/vbin/curl" <<'EOS'
#!/bin/bash
printf 'argv %s\n' "$*" >> "$V_LOG"; printf 'stdin %s\n' "$(cat)" >> "$V_LOG"
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && { out="$2"; shift; }; shift; done
[ -n "$out" ] && printf '%s' "${V_BODY:-}" > "$out"
printf '%s' "${V_CODE:-200}"; exit "${V_RC:-0}"
EOS
chmod +x "$T/vbin/curl"
jq '{queue_leave_events: {"42": .E1}}' "$FX" > "$T/vfake/mergify.json"
VTOK='mgf-fixture-token-0001'
o=$(seam T_ERR="$T/verr" HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/vfake" -- MERGIFY_API_TOKEN "$SLUG" 42)
[ "${o%%|*}" = 0 ] && [ "$(cut -d'|' -f2 <<<"$o" | jq -r '.events[0].metadata.dequeue_code')" = CHECKS_FAILED ] && ok || bad "V1 fake answer for a seeded PR: [$o]"
o=$(seam T_ERR="$T/verr" HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/vfake" -- MERGIFY_API_TOKEN "$SLUG" 43)
eq "V2 an unseeded PR is rc 70" "${o%%|*}" 70
o=$(seam T_ERR="$T/verr" V_LOG="$T/vlog" -- MERGIFY_API_TOKEN "$SLUG" 42)
eq "V3 the token unset is rc 3" "${o%%|*}" 3
[ ! -s "$T/vlog" ] && ok || bad "V3 no curl call with no token"
eq "V4 a bad slug is rc 2" "$(seam T_ERR="$T/verr" -- MERGIFY_API_TOKEN 'a/../b' 42 | cut -d'|' -f1)" 2
eq "V4 a bad slug shape is rc 2" "$(seam T_ERR="$T/verr" -- MERGIFY_API_TOKEN 'nope' 42 | cut -d'|' -f1)" 2
eq "V5 a bad number is rc 2" "$(seam T_ERR="$T/verr" -- MERGIFY_API_TOKEN "$SLUG" '4x' | cut -d'|' -f1)" 2
eq "V5 a bad variable name is rc 2" "$(seam T_ERR="$T/verr" -- 'bad-name' "$SLUG" 42 | cut -d'|' -f1)" 2
eq "V6 a bad vendor mode is rc 2" "$(seam T_ERR="$T/verr" HARNESS_VENDOR_FAKE=yes -- MERGIFY_API_TOKEN "$SLUG" 42 | cut -d'|' -f1)" 2
: > "$T/vlog"
BODY=$(jq -c .E1 "$FX")
o=$(seam T_ERR="$T/verr" V_LOG="$T/vlog" V_BODY="$BODY" MERGIFY_API_TOKEN="$VTOK" VENDOR_CALL_LOG="$T/vseamlog" -- MERGIFY_API_TOKEN "$SLUG" 42)
[ "${o%%|*}" = 0 ] && ok || bad "V7 real mode 200 is rc 0: [$o]"
grep -qF -- "$VTOK" <<<"$(grep '^argv ' "$T/vlog")" && bad "V7 the token is in curl's argv: [$(cat "$T/vlog")]" || ok
grep -qF -- "$VTOK" <<<"$(grep '^stdin ' "$T/vlog")" && ok || bad "V7 the token reaches curl on stdin"
grep -q "^argv .*https://api.mergify.com/v1/repos/$SLUG/logs?pull_request=42&event_type=action.queue.leave&per_page=10" "$T/vlog" && ok \
  || bad "V7 the URL: [$(grep '^argv' "$T/vlog")]"
grep -q -- '--max-time 10' "$T/vlog" && ok || bad "V7 the default timeout is 10 s"
eq "V7 one seam call is logged" "$(grep -c ' mergify queue_leave_events$' "$T/vseamlog")" 1
: > "$T/vlog"
o=$(seam T_ERR="$T/verr" V_LOG="$T/vlog" V_BODY='{"detail":"bad token"}' V_CODE=401 MERGIFY_API_TOKEN="$VTOK" -- MERGIFY_API_TOKEN "$SLUG" 42)
[ "${o%%|*}" = 1 ] && grep -q 'HTTP 401' <<<"$o" && ok || bad "V8 non-2xx is rc 1 with the code: [$o]"
grep -qF -- "$VTOK" <<<"$o" && bad "V8 the token is in the output" || ok
o=$(seam T_ERR="$T/verr" V_LOG="$T/vlog" V_BODY='not json' MERGIFY_API_TOKEN="$VTOK" -- MERGIFY_API_TOKEN "$SLUG" 42)
eq "V8 a 200 that is not JSON is rc 1" "${o%%|*}" 1
o=$(seam T_ERR="$T/verr" V_LOG="$T/vlog" V_RC=28 V_CODE=000 MERGIFY_API_TOKEN="$VTOK" -- MERGIFY_API_TOKEN "$SLUG" 42)
eq "V8 a curl error is rc 1" "${o%%|*}" 1
: > "$T/vlog"
seam T_ERR="$T/verr" V_LOG="$T/vlog" V_BODY="$BODY" MERGIFY_API_TOKEN="$VTOK" MERGIFY_API_TIMEOUT_S=abc MERGIFY_EVENTS_PER_PAGE=999 -- MERGIFY_API_TOKEN "$SLUG" 42 >/dev/null
grep -q -- '--max-time 10' "$T/vlog" && grep -q 'per_page=10$' "$T/vlog" && ok || bad "V8 out-of-range knobs read their fallbacks: [$(grep '^argv' "$T/vlog")]"

# --- E. mc_eu_event_cause -----------------------------------------------------------
HE=$(jq -r ._head "$FX")
evc() { jq -c --arg e "$1" '.[$e]' "$FX" | EC="$EC" FRAG="$FRAG" bash -c '. "$EC"; . "$FRAG"; mc_eu_event_cause "$1"' _ "${2:-$HE}"; }
e_fail=""
echk() { local got; got=$(evc "$1" "${3:-}"); [ "$got" = "$2" ] || e_fail="$e_fail [$1 -> '$got', want '$2']"; }
echk E1  "checks${TAB}Tests"
echk E2  "checks${TAB}Tests"
echk E3  "checks${TAB}Tests (shard 7/12), Lint"
echk E4  "conflict${TAB}CONFLICT_WITH_BASE_BRANCH"
echk E5  "timeout${TAB}CHECKS_TIMEOUT"
echk E6  "other${TAB}PR_DEQUEUED: The pull request has been manually dequeued by @x"
echk E7  "other${TAB}Queue rule conditions no longer match"
echk E8  "unknown${TAB}event names no cause"
echk E9  "timeout${TAB}CHECKS_TIMEOUT"
echk E10 "unknown${TAB}no queue.leave event for ${HE:0:8}"
echk E11 "unknown${TAB}no queue.leave event for ${HE:0:8}"
echk E12 "unknown${TAB}no queue.leave event for ${HE:0:8}"
echk E13 "timeout${TAB}CHECKS_TIMEOUT"
echk E14 "conflict${TAB}CONFLICT_WITH_BASE_BRANCH"
echk E15a "unknown${TAB}no queue.leave event for ${HE:0:8}"
echk E15b "unknown${TAB}no queue.leave event for ${HE:0:8}"
echk E16 "other${TAB}checks_failed: lower case code"
echk E17 "timeout${TAB}CHECKS_TIMEOUT"                     # same received_at: the higher id wins
got=$(printf 'not json' | EC="$EC" FRAG="$FRAG" bash -c '. "$EC"; . "$FRAG"; mc_eu_event_cause abcdef0')
[ "${got%%$TAB*}" = unknown ] || e_fail="$e_fail [not-json -> $got]"
got=$(printf '[1,2]' | EC="$EC" FRAG="$FRAG" bash -c '. "$EC"; . "$FRAG"; mc_eu_event_cause abcdef0')
[ "${got%%$TAB*}" = unknown ] || e_fail="$e_fail [array -> $got]"
# A check list with no names is not a checks cause: the code is still named.
got=$(jq -c '.E1 | .events[0].metadata.unsuccessful_checks = []' "$FX" | EC="$EC" FRAG="$FRAG" bash -c '. "$EC"; . "$FRAG"; mc_eu_event_cause "$1"' _ "$HE")
[ "$got" = "other${TAB}CHECKS_FAILED: The merge queue checks failed" ] || e_fail="$e_fail [no names -> $got]"
[ -z "$e_fail" ] && ok || bad "E mc_eu_event_cause:$e_fail"

# --- D. mc_eu_decide ----------------------------------------------------------------
dec() { FRAG="$FRAG" bash -c '. "$FRAG"; mc_eu_decide "$@"' _ "$@"; }
d_fail=""
dchk() { local want="$1"; shift; local got; got=$(dec "$@"); [ "$got" = "$want" ] || d_fail="$d_fail [$* -> $got, want $want]"; }
#                         knob prov    fin ext solo cul fix rec      ev       bnd mrg
dchk requeue              1 mergify 0 0 0 0 0 unknown unknown 1 1     # D1 the path
dchk park:off             0 mergify 0 0 0 0 0 unknown unknown 1 1     # D2
dchk park:provider        1 github  0 0 0 0 0 unknown unknown 1 1     # D3 the native queue
dchk park:provider        1 ""      0 0 0 0 0 unknown unknown 1 1     # D4
dchk park:final           1 mergify 1 0 0 0 0 unknown unknown 1 1     # D5 a cached final park
dchk park:extra-spent     1 mergify 0 1 0 0 0 unknown unknown 1 1     # D6 the cap
dchk park:solo-tried      1 mergify 0 0 1 0 0 unknown unknown 1 1     # D7 a batch victim's solo try
dchk park:culprit         1 mergify 0 0 0 1 0 unknown unknown 1 1     # D8 BH-5819 stands
dchk park:fix-round       1 mergify 0 0 0 0 1 unknown unknown 1 1     # D9 already handed over
dchk park:no-record       1 mergify 0 0 0 0 0 ""      unknown 1 1     # D10 a stale-dequeue park
dchk park:named           1 mergify 0 0 0 0 0 checks  unknown 1 1     # D11
dchk park:named           1 mergify 0 0 0 0 0 conflict unknown 1 1    # D12
dchk park:named-event     1 mergify 0 0 0 0 0 unknown checks 1 1      # D13
dchk park:named-event     1 mergify 0 0 0 0 0 unknown other 1 1      # D14 any named code
dchk requeue              1 mergify 0 0 0 0 0 unknown ""      1 1     # D15 an empty event word is unknown
dchk park:unbound         1 mergify 0 0 0 0 0 unknown unknown 0 1     # D16
dchk observe              1 mergify 0 0 0 0 0 unknown unknown 1 0     # D17
dchk park:extra-spent     1 mergify 0 1 1 1 1 unknown unknown 1 1     # D18 the order: extra before solo
dchk park:culprit         1 mergify 0 0 0 1 1 unknown unknown 1 1     # D19 culprit before fix-round
dchk park:fix-round       1 mergify 0 0 0 0 1 ""      unknown 1 1     # D20 fix-round before no-record
dchk park:named           1 mergify 0 0 0 0 0 Unknown unknown 1 1     # D21 near miss: case
dchk park:off             0 github  1 1 1 1 1 ""      ""      0 0     # D22 off first
[ -z "$d_fail" ] && ok || bad "D mc_eu_decide:$d_fail"

# --- S. mc_eu_requeue ---------------------------------------------------------------
# S1 the path: one read (unknown), one requeue, marks in order, reejected gone.
drive s1 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC|again:unknown:no Mergify dequeue reason"
eq "S1 rc 0" "$(f s1 rc)" 0
eq "S1 one seam call" "$(n_of s1 seam)" 1
H1=$(head_of s1); K1=$(key_of s1)
grep -q "^ejunkread $K1 $H1\$" "$T/s1/att" && grep -q "^ejunkrq $K1 $H1\$" "$T/s1/att" && ok || bad "S1 both marks: [$(f s1 att)]"
grep -q "^reejected " "$T/s1/att" && bad "S1 reejected is cleared: [$(f s1 att)]" || ok
eq "S1 two requeued lines" "$(grep -c "^requeued $K1 $H1 " "$T/s1/att")" 2
a=$(grep -n '^ejunkrq ' "$T/s1/att" | cut -d: -f1); b=$(grep -n '^requeued ' "$T/s1/att" | tail -1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok || bad "S1 ejunkrq is written before the requeued line"
grep -q "${TAB}QUEUED${TAB}queue-ejected: requeued once more on ${H1:0:8} (no named cause after the Mergify event read)" "$T/s1/trans" && ok || bad "S1 QUEUED: [$(f s1 trans)]"
has s1 log "EJECT_UNKNOWN_EVENT $K1 ${H1:0:8} unknown (event names no cause)" && has s1 log "EJECT_UNKNOWN_REQUEUE $K1 $H1" && ok || bad "S1 log lines: [$(f s1 log)]"
has s1 rel eject-unknown && has s1 fbh eject-unknown && ok || bad "S1 hand-off released and fbh cleared"
grep -q "${TAB}event${TAB}unknown${TAB}event names no cause\$" "$(recf s1)" && ok || bad "S1 the event record line: [$(cat "$(recf s1)")]"
eq "S1 one requeue write" "$(grep -c '^requeue ' "$T/s1/writes")" 1
# S2 one read per head across 3 ticks (the second and third answer from marks).
drive s2 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" RQBUD=0
eq "S2 tick 1 deferred on the requeue budget" "$(f s2 rc)" 2
DRIVE_KEEP=1 drive s2 eu RQBUD=0
eq "S2 tick 2 deferred again" "$(f s2 rc)" 2
DRIVE_KEEP=1 drive s2 eu
eq "S2 tick 3 requeues" "$(f s2 rc)" 0
eq "S2 exactly 1 seam call over 3 ticks" "$(n_of s2 seam-all)" 1
eq "S2 exactly 1 ejunkread mark" "$(grep -c '^ejunkread ' "$T/s2/att")" 1
eq "S2 exactly 1 event record line" "$(awk -F'\t' '$3=="event"' "$(recf s2)" | grep -c .)" 1
# S3 the event names a cause: park:named-event, cached, no requeue.
drive s3 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" EV=E1
eq "S3 rc 1" "$(f s3 rc)" 1
grep -q "^eupark $(key_of s3) $(head_of s3) park:named-event\$" "$T/s3/att" && ok || bad "S3 cached eupark: [$(f s3 att)]"
[ ! -s "$T/s3/writes" ] && [ ! -s "$T/s3/trans" ] && ok || bad "S3 no requeue, no transition"
has s3 log 'EJECT_UNKNOWN_PARK' && has s3 log 'named-event' && ok || bad "S3 park line: [$(f s3 log)]"
DRIVE_KEEP=1 drive s3 eu EV=E1
[ "$(f s3 rc)" = 1 ] && [ ! -s "$T/s3/seam" ] && [ ! -s "$T/s3/reads" ] && [ ! -s "$T/s3/log" ] && ok \
  || bad "S3 a cached final park reads, writes and logs nothing: reads=[$(f s3 reads)] log=[$(f s3 log)]"
# S4 the event budget is spent: rc 2, no mark, no read, asked again later.
drive s4 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" EVBUD=0
[ "$(f s4 rc)" = 2 ] && [ ! -s "$T/s4/seam" ] && ! grep -q '^ejunkread ' "$T/s4/att" && ok || bad "S4 event budget spent: rc=$(f s4 rc) att=[$(f s4 att)]"
has s4 log 'Mergify event reads' && ok || bad "S4 the deferral is logged"
# S5 the seam fails (unseeded fake, rc 70): unknown, read failed, still requeued.
drive s5 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" EV=-
eq "S5 rc 0" "$(f s5 rc)" 0
grep -q "${TAB}event${TAB}unknown${TAB}event read failed (rc 70)\$" "$(recf s5)" && ok || bad "S5 the failed read is recorded: [$(cat "$(recf s5)")]"
# S6 real mode with no token: rc 3, unknown, still requeued (the default on a box with no token).
drive s6 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" FAKE=0
[ "$(f s6 rc)" = 0 ] && grep -q "event read failed (rc 3)" "$(recf s6)" && ok || bad "S6 no token: rc=$(f s6 rc) rec=[$(cat "$(recf s6)")]"
# S7 observe mode: no requeue, no ejunkrq, no transition, rc 1.
drive s7 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" MERGES=0
[ "$(f s7 rc)" = 1 ] && [ ! -s "$T/s7/writes" ] && [ ! -s "$T/s7/trans" ] && ! grep -q '^ejunkrq ' "$T/s7/att" && has s7 log 'observe mode' && ok \
  || bad "S7 observe mode writes nothing: rc=$(f s7 rc) att=[$(f s7 att)]"
# S8 REQUEUE_FAILED: rc 1, ejunkrq kept, reejected back, no transition.
drive s8 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" RQRC=1
[ "$(f s8 rc)" = 1 ] && grep -q '^ejunkrq ' "$T/s8/att" && grep -q '^reejected ' "$T/s8/att" && [ ! -s "$T/s8/trans" ] && has s8 log REQUEUE_FAILED && ok \
  || bad "S8 a refused requeue: rc=$(f s8 rc) att=[$(f s8 att)] log=[$(f s8 log)]"
# S9 requeue rc 3: WAIT_CI awaiting the witness, rc 0.
drive s9 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" RQRC=3
[ "$(f s9 rc)" = 0 ] && grep -q "${TAB}WAIT_CI${TAB}.*awaiting Mergify's witness" "$T/s9/trans" && ok || bad "S9 rc 3: [$(f s9 trans)]"
# S10 unbound (verdict on an older head; a live head that moved): park, not cached.
drive s10 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" VREV=0000000000000000000000000000000000000000
[ "$(f s10 rc)" = 1 ] && [ ! -s "$T/s10/writes" ] && ! grep -q '^eupark ' "$T/s10/att" && ok || bad "S10 unbound parks, not cached: [$(f s10 att)]"
drive s10b eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" LIVE=2222222222222222222222222222222222222222
[ "$(f s10b rc)" = 1 ] && [ ! -s "$T/s10b/writes" ] && ok || bad "S10 a moved live head parks"
# S11 a named record cause: no read, park:named.
drive s11 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC|again:checks:Tests"
[ "$(f s11 rc)" = 1 ] && [ ! -s "$T/s11/seam" ] && grep -q 'park:named$' "$T/s11/att" && ok || bad "S11 named record: rc=$(f s11 rc) seam=[$(f s11 seam)]"
# S12 each mark alone parks with no read at all.
for m in "batchvictim:solo-tried" "dqwculprit:culprit" "ejectfix:fix-round" "ejunkrq:extra-spent"; do
  c="s12-${m%%:*}"
  drive "$c" eu SEED="$UNK_SEED|reejected KEY HEAD|${m%%:*} KEY HEAD" REC="$UNK_REC"
  [ "$(f "$c" rc)" = 1 ] && [ ! -s "$T/$c/seam" ] && [ ! -s "$T/$c/reads" ] && [ ! -s "$T/$c/writes" ] && ok \
    || bad "S12 ${m%%:*} parks with no read: rc=$(f "$c" rc) reads=[$(f "$c" reads)]"
done
drive s12-none eu SEED="$UNK_SEED|reejected KEY HEAD"
[ "$(f s12-none rc)" = 1 ] && [ ! -s "$T/s12-none/seam" ] && ok || bad "S12 no record line (stale dequeue) parks with no read"

# --- A. the settle arm --------------------------------------------------------------
# A1 the first ejection is unchanged: WAIT_CI queue-ejected, no read.
drive a1 settle
grep -q "${TAB}WAIT_CI${TAB}queue-ejected: unknown (no Mergify dequeue reason)" "$T/a1/trans" && [ ! -s "$T/a1/seam" ] && ok \
  || bad "A1 a first ejection: trans=[$(f a1 trans)] seam=[$(f a1 seam)]"
# A2 second ejection, unknown + event unknown: requeued, not parked.
drive a2 settle SEED="$UNK_SEED" REC="$UNK_REC"
grep -q BLOCKED_HUMAN "$T/a2/trans" && bad "A2 not parked: [$(f a2 trans)]" || ok
grep -q "${TAB}QUEUED${TAB}queue-ejected: requeued once more" "$T/a2/trans" && ok || bad "A2 QUEUED: [$(f a2 trans)]"
grep -q '^reejected ' "$T/a2/att" && bad "A2 reejected is gone: [$(f a2 att)]" || ok
[ ! -s "$T/a2/fixnow" ] && ok || bad "A2 no fix round: [$(f a2 fixnow)]"
has a2 log 'requeued once more instead of parked (BH-9695)' && ok || bad "A2 the settle log line"
eq "A2 one seam call" "$(n_of a2 seam)" 1
eq "A2 record ords" "$(awk -F'\t' '{print $3}' "$(recf a2)" | tr '\n' ' ')" "first again event "
# A3 the event names checks: parked, the reason names it, the fix round runs.
drive a3 settle SEED="$UNK_SEED" REC="$UNK_REC" EV=E1
grep -q "${TAB}BLOCKED_HUMAN${TAB}queue-ejected-twice: .*checks (Tests)" "$T/a3/trans" && ok || bad "A3 parked with the cause: [$(f a3 trans)]"
[ -s "$T/a3/fixnow" ] && [ ! -s "$T/a3/writes" ] && ok || bad "A3 the fix round, no requeue"
grep -qF 'BH-9695' "$T/a3/trans" && bad "A3 no cap suffix on a named first park" || ok
# A4 the record names a cause: park as today, 0 seam calls.
drive a4 settle SEED="$UNK_SEED" REC="$UNK_REC" EC="checks${TAB}Tests"
grep -q "${TAB}BLOCKED_HUMAN${TAB}queue-ejected-twice" "$T/a4/trans" && [ ! -s "$T/a4/seam" ] && [ -s "$T/a4/fixnow" ] && ok \
  || bad "A4 named record parks with 0 reads: trans=[$(f a4 trans)] seam=[$(f a4 seam)]"
# A5 the ejection after the extra requeue: parked with the cap reason, an `extra` record line, no second requeue.
DRIVE_KEEP=1 drive a2 settle
H2=$(head_of a2)
grep -q "${TAB}BLOCKED_HUMAN${TAB}queue-ejected-twice: .*${CAP}\$" "$T/a2/trans" && ok || bad "A5 the cap park: [$(f a2 trans)]"
grep -q "${TAB}${H2}${TAB}extra${TAB}unknown${TAB}" "$(recf a2)" && ok || bad "A5 an extra record line: [$(cat "$(recf a2)")]"
[ ! -s "$T/a2/writes" ] && [ ! -s "$T/a2/seam" ] && [ -s "$T/a2/fixnow" ] && ok || bad "A5 no requeue, no read, the fix round: writes=[$(f a2 writes)]"
grep -q "park:extra-spent" "$T/a2/att" && ok || bad "A5 cached park:extra-spent"
# A6 a budget spent: park with no fix round.
drive a6 settle SEED="$UNK_SEED" REC="$UNK_REC" RQBUD=0
grep -q "${TAB}BLOCKED_HUMAN${TAB}queue-ejected-twice" "$T/a6/trans" && [ ! -s "$T/a6/fixnow" ] && ok \
  || bad "A6 deferred: park, no fix round: trans=[$(f a6 trans)] fixnow=[$(f a6 fixnow)]"
# A7 a batch victim still wins: the solo requeue, no Mergify read.
drive a7 settle SEED="$UNK_SEED" REC="$UNK_REC" CF="$T/c-bm.json"
grep -q "${TAB}QUEUED${TAB}batch-victim: requeued solo" "$T/a7/trans" && [ ! -s "$T/a7/seam" ] && ok \
  || bad "A7 batch victim first: trans=[$(f a7 trans)] seam=[$(f a7 seam)]"
# A8 the knob off: today's park, byte for byte.
drive a8 settle SEED="$UNK_SEED" REC="$UNK_REC" MC_EJECT_UNKNOWN_REQUEUE=0
drive a8b settle SEED="$UNK_SEED" REC="$UNK_REC" FRAG_ON=0
eq "A8 the knob off = no fragment" "$(cut -f2- "$T/a8/trans" | sed "s/$(head_of a8 | cut -c1-8)/H/g")" "$(cut -f2- "$T/a8b/trans" | sed "s/$(head_of a8b | cut -c1-8)/H/g")"
[ ! -s "$T/a8/seam" ] && [ -s "$T/a8/fixnow" ] && ok || bad "A8 knob off: no read, the fix round"

# --- B. the parked-row pass ---------------------------------------------------------
# B1 a deferred park is requeued on the next tick.
DRIVE_KEEP=1 drive a6 parked
grep -q "${TAB}QUEUED${TAB}queue-ejected: requeued once more" "$T/a6/trans" && [ ! -s "$T/a6/fixnow" ] && ok \
  || bad "B1 the deferred park is requeued next tick: trans=[$(f a6 trans)] fixnow=[$(f a6 fixnow)]"
# B2 a park stamped ejectfix makes 0 reads, and the fix round call returns at once (stubbed).
drive b2 parked SEED="$UNK_SEED|reejected KEY HEAD|ejectfix KEY HEAD" REC="$UNK_REC"
[ ! -s "$T/b2/seam" ] && [ ! -s "$T/b2/writes" ] && [ -s "$T/b2/fixnow" ] && ok || bad "B2 stamped: 0 reads: seam=[$(f b2 seam)]"
# B3 a stale-dequeue park (no record line) gets the fix round.
drive b3 parked SEED="$UNK_SEED|reejected KEY HEAD" ROWWHY="queue-ejected-twice: stale dequeue"
[ -s "$T/b3/fixnow" ] && [ ! -s "$T/b3/seam" ] && [ ! -s "$T/b3/trans" ] && ok || bad "B3 stale dequeue: fix round"
# B4 five unstamped unknown parks in one tick (one shared budget dir): exactly
# 3 reads; the other 2 answer rc 2 and keep no ejunkread mark.
mkdir -p "$T/b4"; rm -f "$T/b4/budget-"*; b4r=0; b4d=0; b4q=0
for i in 1 2 3 4 5; do
  BUDDIR="$T/b4" drive "b4-$i" eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC"
  [ -s "$T/b4-$i/seam" ] && b4r=$((b4r + 1))
  case "$(f "b4-$i" rc)" in 0) b4q=$((b4q + 1)) ;; 2) grep -q '^ejunkread ' "$T/b4-$i/att" || b4d=$((b4d + 1)) ;; esac
done
eq "B4 3 reads" "$b4r" 3
eq "B4 3 requeues" "$b4q" 3
eq "B4 2 deferrals with no mark" "$b4d" 2
# B5 a batch victim in the parked-row pass: solo requeue, no Mergify read, no fix round.
drive b5 parked SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" CF="$T/c-bm.json"
grep -q "${TAB}QUEUED${TAB}batch-victim:" "$T/b5/trans" && [ ! -s "$T/b5/seam" ] && [ ! -s "$T/b5/fixnow" ] && ok \
  || bad "B5 batch victim skips the rest: trans=[$(f b5 trans)] seam=[$(f b5 seam)]"

# --- R. the ticks after the extra requeue -------------------------------------------
drive r1 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC|again:unknown:no Mergify dequeue reason"
eq "R setup: the extra requeue ran" "$(f r1 rc)" 0
DRIVE_KEEP=1 drive r1 reentry
case "$(f r1 out)" in "1 1|WAIT_CI|requeued on "*) ok ;; *) bad "R1-R2 not live, EJN 1, the re-entry arm waits: [$(f r1 out)]" ;; esac
grep -q BLOCKED_HUMAN "$T/r1/out" && bad "R2 the re-entry arm does not park" || ok
# R3 Mergify ejects it again (the settle arm's mark, without the settle pass): live, parked with the suffix.
printf 'reejected %s %s\n' "$(key_of r1)" "$(head_of r1)" >> "$T/r1/att"
DRIVE_KEEP=1 drive r1 reentry
case "$(f r1 out)" in "0 2|BLOCKED_HUMAN|queue-ejected-twice: "*"$CAP") ok ;; *) bad "R3 live again, parked with the cap suffix: [$(f r1 out)]" ;; esac
DRIVE_KEEP=1 drive r1 culprit
case "$(f r1 out)" in *"|BLOCKED_HUMAN|queue-ejected-twice: "*"$CAP") ok ;; *) bad "R3 the culprit park site adds the suffix: [$(f r1 out)]" ;; esac
# R4 no fourth requeue: mc_eu_requeue answers extra-spent with no read.
DRIVE_KEEP=1 drive r1 eu
[ "$(f r1 rc)" = 1 ] && [ ! -s "$T/r1/seam" ] && [ ! -s "$T/r1/writes" ] && ok || bad "R4 no fourth requeue: rc=$(f r1 rc)"
eq "R4 two requeued lines in all" "$(grep -c '^requeued ' "$T/r1/att")" 2
# A named suffix: the cause after the extra requeue was named.
drive r5 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC"
DRIVE_KEEP=1 drive r5 settle EC="checks${TAB}Tests"
grep -q "${TAB}BLOCKED_HUMAN${TAB}queue-ejected-twice: .*checks (Tests) on .* — after one more requeue (BH-9695)\$" "$T/r5/trans" && ok \
  || bad "R5 a named cause after the extra requeue: [$(f r5 trans)]"

# --- W. round trips -----------------------------------------------------------------
W=$(EC="$EC" FRAG="$FRAG" T="$T" bash -c '. "$EC"; . "$FRAG"; MC_STATE_DIR="$T/w"; mc_now() { printf 1763460000; }
  h=abcdef0123456789abcdef0123456789abcdef01
  ec_record o/r 7 "$h" first unknown "no Mergify dequeue reason"
  ec_record o/r 7 "$h" again unknown "no Mergify dequeue reason"
  ec_record o/r 7 "$h" event checks "Tests"
  ec_record o/r 7 "$h" event timeout "dup"
  printf "%s|%s|%s|" "$(ec_summary o/r 7)" "$(ec_head_why o/r 7 "$h")" "$(_mc_eu_cause o/r 7 "$h" -)"
  ec_record o/r 7 "$h" extra unknown "no Mergify dequeue reason"
  printf "%s|%s" "$(ec_head_why o/r 7 "$h")" "$(grep -c . "$(ec_file o/r 7)")"')
eq "W1-W4 summary, head why, rec cause, dedupe" "$W" "2 unknown (no Mergify dequeue reason) on abcdef01; 3 checks (Tests) on abcdef01|checks (Tests)|unknown|unknown (no Mergify dequeue reason)|4"
W5=$(FRAG="$FRAG" T="$T" bash -c '. "$FRAG"; A="$T/w5"; : > "$A"
  mc_attempt_has() { grep -qxF "$1" "$A"; }; mc_attempt_put() { printf "%s\n" "$1" >> "$A"; }
  printf "%s " "$(mc_eu_ord k h again)"; mc_attempt_put "ejunkrq k h"; printf "%s" "$(mc_eu_ord k h again)"')
eq "W5 mc_eu_ord reads the ejunkrq mark" "$W5" "again extra"

# --- K. knobs -----------------------------------------------------------------------
K1=$(MC_EJECT_EVENT_READS=7 FRAG="$FRAG" bash -c '. "$FRAG"; lane_knob() { [ "$2" = MC_EJECT_EVENT_READS ] && printf 2; }; _mc_eu_knob MC_EJECT_EVENT_READS 3')
eq "K1 the settings row wins" "$K1" 2
K2=$(MC_EJECT_EVENT_READS=7 FRAG="$FRAG" bash -c '. "$FRAG"; lane_knob() { printf ""; }; _mc_eu_knob MC_EJECT_EVENT_READS 3')
eq "K2 the env next" "$K2" 7
K3=$(FRAG="$FRAG" bash -c '. "$FRAG"; printf "%s|%s" "$(_mc_eu_knob MC_EJECT_EVENT_READS 3)" "$(_mc_eu_knob MC_EJECT_UNKNOWN_REQUEUE 1)"')
eq "K3 the fallbacks last" "$K3" "3|1"
K4=$(MC_EJECT_EVENT_READS=abc FRAG="$FRAG" bash -c '. "$FRAG"; _mc_eu_knob MC_EJECT_EVENT_READS 3')
eq "K4 a non-integer reads the fallback" "$K4" 3
# MC_EJECT_EVENT_READS=0: no read, the extra requeue still runs.
drive k5 eu SEED="$UNK_SEED|reejected KEY HEAD" REC="$UNK_REC" MC_EJECT_EVENT_READS=0
[ "$(f k5 rc)" = 0 ] && [ ! -s "$T/k5/seam" ] && ok || bad "K5 reads 0: no read, still requeued: rc=$(f k5 rc)"
for k in MC_EJECT_UNKNOWN_REQUEUE MC_EJECT_EVENT_READS; do
  jq -e --arg k "$k" '.env == $k and .read_in == "bin/merge-conductor.d/bh-9695-eject-unknown.sh"' "$DIR/catalog/lanes.d/merge-conductor.knobs.d/$k.json" >/dev/null && ok || bad "K the knob row $k"
done

# --- M1. mutation guard -------------------------------------------------------------
drive m1 settle SEED="$UNK_SEED" REC="$UNK_REC" FRAG_ON=0
grep -q "${TAB}BLOCKED_HUMAN${TAB}queue-ejected-twice" "$T/m1/trans" && ! grep -q QUEUED "$T/m1/trans" && ok \
  || bad "M1 with no fragment A2 parks (the test can fail): [$(f m1 trans)]"

# --- Z1. 0 vendor calls -------------------------------------------------------------
[ ! -s "$T/unstubbed" ] && ok || bad "Z1 a gh or curl call reached PATH: [$(cat "$T/unstubbed")]"
eq "Z1 VENDOR_CALL_LOG has 0 lines" "$(grep -c . "$T/vcalls")" 0

echo "mc-eject-unknown.bh-9695: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
