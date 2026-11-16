#!/bin/bash
# tests/br-red-sig.bh-9437-test.sh — no third rebuild on the same red (BH-9437
# item 1). Before br_rebuild_fresh closes a ci-red PR and buys a build, the
# fragment bin/blocked-resolver.d/bh-9437-red-sig.sh (brlad_red_gate) reads the
# failing required checks of the PR's head, stores them on the record
# (.red_sigs) and compares them with the PR before it. The same set twice stops
# the ladder: no close, no enqueue, ONE warn alert that names the checks.
#   §S1 the row: sorted names, the required filter applied
#   §S2 PR1 {unit,lint} rebuilt, PR2 {lint,unit} -> rc 3, nothing closed or
#       enqueued, one alert naming "lint, unit" and both PRs; ticks 2-3 quiet
#   §S3 near misses go on: a partial set, a green head, the same PR at a new
#       head, a rebase-conflict reason, an unreadable check-runs read
#   §S4 the gate sits after the cap check and before the close
#   §K  BR_RED_SIG_STOP=0 -> the rebuild goes on
#   §Z  0 vendor calls
# Run: bash tests/br-red-sig.bh-9437-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: br-red-sig.bh-9437: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
. "$DIR/tests/lib/br-9437.sh" || exit 1
FRAG="$DIR/bin/blocked-resolver.d/bh-9437-red-sig.sh"
[ -r "$FRAG" ] && ok || bad "S0 $FRAG is missing"
[ -r "$DIR/catalog/lanes.d/blocked-resolver.knobs.d/BR_RED_SIG_STOP.json" ] && ok || bad "S0 the BR_RED_SIG_STOP knob row is missing"

bl9_extract "$DIR" "$T" br_rebuild_fresh br_cap_key br_rkey br_file br_load br_save br_record br_num \
  br_json_edit br_set_field br_ladder_class br_slug_of_url || exit 1
bl9_tripwire "$T" || exit 1
H="$T/h"; mkdir -p "$H/bin" "$H/state/blocked-resolver"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
HA=$(printf 'a%.0s' {1..40}); HB=$(printf 'b%.0s' {1..40}); HC=$(printf 'c%.0s' {1..40})
U1=https://github.com/o/r/pull/11; U2=https://github.com/o/r/pull/12
cat > "$T/drv.sh" <<EOF
set -u
PATH="$T/fakebin:\$PATH"
H="$H"; ST="$H/state/blocked-resolver"; LOG="$T/say.txt"; OBSERVE="\${OBSERVE:-0}"
STAMP() { date -u +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok a record stamp; no assertion reads it
say() { printf '%s\n' "\$*" >> "\$LOG"; }
mc_slug_of_url() { printf '%s' "\${1#https://github.com/}" | sed 's#/pull/.*##'; }
mc_num_of_url() { grep -oE '[0-9]+\$' <<<"\$1"; }
br_pr_field() { local n; n=\$(mc_num_of_url "\$1"); [ -s "$T/head-\$n" ] || return 75; cat "$T/head-\$n"; }
gh_rest() {
  case "\$2" in
    repos/o/r/commits/*/check-runs*) local h=\${2#repos/o/r/commits/}; h=\${h%%/*}
      [ -s "$T/checks-\$h.json" ] || return 1; cat "$T/checks-\$h.json" ;;
    *) printf 'unexpected gh_rest %s\n' "\$*" >> "$T/vendor.txt"; return 1 ;;
  esac
}
mc_mergify_required_checks() { [ -s "$T/required" ] || return 75; cat "$T/required"; }
br_is_external() { return 1; }
br_pr_state() { printf open; }
br_hold_gate() { return 0; }
br_board_done_gate() { return 0; }
br_cap_rows() { printf '%s' "\$4"; }
br_rebuild_cap() { printf 3; }
br_rebuild_inflight() { return 1; }
br_supersede_guard() { return 0; }
br_abandon() { printf '%s\n' "\$*" >> "$T/abandon.txt"; }
br_jobs_why() { :; }
br_close_pr() { printf '%s\n' "\$1" >> "$T/closed.txt"; }
br_close_facts() { :; }
br_event() { :; }
br_quiet() { :; }
br_jobs_count() { printf null; }
br_enqueue_fresh() { printf '%s\n' "\$*" >> "$T/enqueue.txt"; }
br_rebuild_settle() { br_json_edit "\$1" "\$2" '.rebuilds = ((.rebuilds // 0) + 1)'; }
. "$T/fns.sh"
for f in "$DIR"/bin/blocked-resolver.d/bh-9437-*.sh; do [ -r "\$f" ] && . "\$f"; done
EOF
REC() { cat "$H/state/blocked-resolver/tproj/tproj-TP-9.json" 2>/dev/null; }
n() { cat "$T/$1.txt" 2>/dev/null | grep -c .; }
RESET() { local f; for f in "$H/state/blocked-resolver/tproj" "$T"/{say,alerts,abandon,closed,enqueue}.txt "$T"/head-* "$T"/checks-* "$T/required"; do scratch_rm "$f" 2>/dev/null; done
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc '{project:"tproj",rkey:"tproj-TP-9",rebuilds:0,fixrounds:1,outcome:"",attempts:[]}' > "$H/state/blocked-resolver/tproj/tproj-TP-9.json"; }
# checks <head> <name:conclusion>... — the check-runs page of one head
checks() { local h="$1" out='[]' a; shift
  for a in "$@"; do out=$(jq -c --arg n "${a%%:*}" --arg c "${a#*:}" '. + [{name:$n, status:"completed", conclusion:$c}]' <<<"$out"); done
  jq -nc --argjson r "$out" '{total_count:($r|length), check_runs:$r}' > "$T/checks-$h.json"; }
head_of() { printf '%s' "$2" > "$T/head-$1"; }
REBUILD() { ( . "$T/drv.sh"; br_rebuild_fresh tproj "$2" "${3:-red-twice}" "$1" - TP-9 ); }

# ── §S1: the row ───────────────────────────────────────────────────────────
RESET; printf 'unit\nlint\n' > "$T/required"
head_of 11 "$HA"; checks "$HA" unit:failure e2e-optional:failure lint:timed_out build:success
REBUILD "$U1" o-r-11; RC=$?
[ "$RC" = 0 ] && ok || bad "S1 the first red rebuild goes on, rc $RC ($(cat "$T/say.txt" 2>/dev/null))"
[ "$(n enqueue)" = 1 ] && ok || bad "S1 the first rebuild enqueues, got $(n enqueue)"
[ "$(REC | jq -c '.red_sigs')" = "[{\"url\":\"$U1\",\"head\":\"$HA\",\"checks\":[\"lint\",\"unit\"],\"at\":$(REC | jq -c '.red_sigs[0].at')}]" ] && ok \
  || bad "S1 one row {url,head,checks} with the required failing names, sorted: $(REC | jq -c '.red_sigs')"
# no required list: every failing check counts
RESET; head_of 11 "$HA"; checks "$HA" unit:failure e2e:startup_failure build:success
REBUILD "$U1" o-r-11
[ "$(REC | jq -c '.red_sigs[0].checks')" = '["e2e","unit"]' ] && ok || bad "S1 no required list: every failing name counts: $(REC | jq -c '.red_sigs')"

# ── §S2: the same set on the next PR stops the ladder ─────────────────────
RESET; head_of 11 "$HA"; checks "$HA" unit:failure lint:failure
REBUILD "$U1" o-r-11
head_of 12 "$HB"; checks "$HB" lint:failure unit:failure
REBUILD "$U2" o-r-12; RC=$?
[ "$RC" = 3 ] && ok || bad "S2 the same red set twice: br_rebuild_fresh rc 3 (held), got $RC ($(tail -3 "$T/say.txt"))"
[ "$(n enqueue)" = 1 ] && ok || bad "S2 no third build: enqueues $(n enqueue), want 1"
[ "$(n closed)" = 1 ] && ok || bad "S2 PR2 is not closed: closes $(n closed), want 1 ($(cat "$T/closed.txt"))"
[ "$(n alerts)" = 1 ] && ok || bad "S2 exactly one alert, got $(n alerts)"
grep -q 'lint, unit' "$T/alerts.txt" 2>/dev/null && ok || bad "S2 the alert names the checks 'lint, unit': $(cat "$T/alerts.txt" 2>/dev/null)"
grep -q "$U1" "$T/alerts.txt" 2>/dev/null && grep -q "$U2" "$T/alerts.txt" 2>/dev/null && ok || bad "S2 the alert names both PRs"
grep -q -- '--severity warn' "$T/alerts.txt" 2>/dev/null && ok || bad "S2 the alert is a warn"
grep -q -- "--id red-repeat:tproj:tproj-TP-9:${HB:0:12}" "$T/alerts.txt" 2>/dev/null && ok || bad "S2 the alert id is red-repeat:<p>:<ck>:<head12>: $(cat "$T/alerts.txt" 2>/dev/null)"
[ "$(REC | jq -r '.red_stop.head')" = "$HB" ] && ok || bad "S2 red_stop names the head: $(REC | jq -c .red_stop)"
[ "$(REC | jq '[.attempts[] | select(.action == "red-repeat")] | length')" = 1 ] && ok || bad "S2 one red-repeat attempt row"
[ "$(n abandon)" = 0 ] && ok || bad "S2 nothing abandoned"
grep -q 'RED REPEAT' "$T/say.txt" && ok || bad "S2 the log says RED REPEAT"
REBUILD "$U2" o-r-12; RC2=$?; REBUILD "$U2" o-r-12; RC3=$?
[ "$RC2$RC3" = 33 ] && ok || bad "S2 ticks 2-3 still held, rc $RC2 $RC3"
[ "$(n alerts)" = 1 ] && [ "$(n enqueue)" = 1 ] && [ "$(n closed)" = 1 ] && ok || bad "S2 ticks 2-3: still one alert, one enqueue, one close (alerts $(n alerts), enqueue $(n enqueue), closed $(n closed))"
[ "$(REC | jq '[.attempts[] | select(.action == "red-repeat")] | length')" = 1 ] && ok || bad "S2 ticks 2-3 add no attempt row"
# a new push on PR2 restarts the compare: a different set goes on
head_of 12 "$HC"; checks "$HC" e2e:failure
REBUILD "$U2" o-r-12; RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 2 ] && ok || bad "S2 a new head with a different set rebuilds (rc $RC, enqueue $(n enqueue))"

# ── §S3: near misses go on ────────────────────────────────────────────────
RESET; head_of 11 "$HA"; checks "$HA" unit:failure; REBUILD "$U1" o-r-11
head_of 12 "$HB"; checks "$HB" unit:failure lint:failure; REBUILD "$U2" o-r-12; RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 2 ] && [ "$(n alerts)" = 0 ] && ok || bad "S3 {unit} then {unit,lint} is not the same set (rc $RC, enqueue $(n enqueue), alerts $(n alerts))"
RESET; head_of 11 "$HA"; checks "$HA" unit:failure; REBUILD "$U1" o-r-11
head_of 12 "$HB"; checks "$HB" unit:success; REBUILD "$U2" o-r-12; RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 2 ] && ok || bad "S3 a green head goes on (rc $RC, enqueue $(n enqueue))"
[ "$(REC | jq '.red_sigs | length')" = 1 ] && ok || bad "S3 an empty failing set writes no row: $(REC | jq -c .red_sigs)"
RESET; head_of 11 "$HA"; checks "$HA" unit:failure; REBUILD "$U1" o-r-11
head_of 11 "$HB"; checks "$HB" unit:failure; REBUILD "$U1" o-r-11; RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 2 ] && [ "$(n alerts)" = 0 ] && ok || bad "S3 the same PR at a new head has no PR before it (rc $RC, enqueue $(n enqueue))"
RESET; head_of 11 "$HA"; checks "$HA" unit:failure; REBUILD "$U1" o-r-11 conflict-unresolvable
head_of 12 "$HB"; checks "$HB" unit:failure; REBUILD "$U2" o-r-12 conflict-unresolvable; RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 2 ] && ok || bad "S3 a rebase-conflict reason is not compared (rc $RC, enqueue $(n enqueue))"
[ "$(REC | jq '.red_sigs // [] | length')" = 0 ] && ok || bad "S3 a rebase-conflict reason writes no row"
RESET; head_of 11 "$HA"; checks "$HA" unit:failure; REBUILD "$U1" o-r-11
head_of 12 "$HB"; REBUILD "$U2" o-r-12; RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 2 ] && ok || bad "S3 an unreadable check-runs read keeps today's rebuild (rc $RC, enqueue $(n enqueue))"
grep -q 'check runs' "$T/say.txt" && ok || bad "S3 the unreadable read is said: $(tail -2 "$T/say.txt")"

# ── §S4: where the gate sits ──────────────────────────────────────────────
BODY=$(bl9_fn_body "$T" br_rebuild_fresh)
LCAP=$(grep -n 'if \[ "\$cap" -ge "\$lim" \]; then' <<<"$BODY" | tail -1 | cut -d: -f1)
LGATE=$(grep -n 'brlad_red_gate' <<<"$BODY" | head -1 | cut -d: -f1)
LCLOSE=$(grep -n 'br_close_pr "\$url"' <<<"$BODY" | head -1 | cut -d: -f1)
[ -n "$LGATE" ] && [ -n "$LCAP" ] && [ -n "$LCLOSE" ] && [ "$LGATE" -gt "$LCAP" ] && [ "$LGATE" -lt "$LCLOSE" ] && ok \
  || bad "S4 brlad_red_gate must sit after the cap check ($LCAP) and before br_close_pr ($LCLOSE), at '${LGATE:-absent}'"
# at the cap the ladder still abandons as before (the gate is never asked)
RESET; jq -c '.rebuilds = 3' <<<"$(REC)" > "$H/state/blocked-resolver/tproj/tproj-TP-9.json"
head_of 12 "$HB"; checks "$HB" unit:failure; REBUILD "$U2" o-r-12
[ "$(n abandon)" = 1 ] && ok || bad "S4 a spent ladder still abandons"

# ── §K: the knob ──────────────────────────────────────────────────────────
RESET; head_of 11 "$HA"; checks "$HA" unit:failure; REBUILD "$U1" o-r-11
head_of 12 "$HB"; checks "$HB" unit:failure
( export BR_RED_SIG_STOP=0; REBUILD "$U2" o-r-12 ); RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 2 ] && [ "$(n alerts)" = 0 ] && ok || bad "K BR_RED_SIG_STOP=0 compares nothing (rc $RC, enqueue $(n enqueue), alerts $(n alerts))"
( export BR_RED_SIG_STOP=bogus; REBUILD "$U2" o-r-12 )
grep -q "BR_RED_SIG_STOP='bogus'" "$T/say.txt" && ok || bad "K a non-number knob is said and falls back"
# observe mode writes nothing and buys nothing
RESET; head_of 11 "$HA"; checks "$HA" unit:failure; REBUILD "$U1" o-r-11
head_of 12 "$HB"; checks "$HB" unit:failure
( export OBSERVE=1; REBUILD "$U2" o-r-12 )
[ "$(n alerts)" = 0 ] && [ "$(REC | jq '.red_stop // null')" = null ] && grep -q 'WOULD' "$T/say.txt" && ok || bad "K observe mode: a WOULD line, no alert, no red_stop"

# ── §Z: no vendor ─────────────────────────────────────────────────────────
[ "$(bl9_vendor_calls "$T")" = 0 ] && ok || bad "Z vendor calls: $(cat "$T/vendor.txt")"
grep -q 'rtc_mark' "$FRAG" 2>/dev/null && bad "S0 the gate must not need #9425's rtc_mark (not on main)" || ok

echo "br-red-sig.bh-9437: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
