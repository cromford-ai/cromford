#!/bin/bash
# tests/br-ironlaw-adj.bh-9437-test.sh — reason iron-law goes to adjudication
# only, never to a fix round; an ACCEPT binds to the head it read; a moved head
# gets a new scan, not a fix round (BH-9437 item 5; project-4#2205 took 156 fix
# rounds after one ACCEPT). The driver's br_adjudicate and br_fix_round are
# lifted verbatim and driven; bin/blocked-resolver.d/bh-9437-ironlaw-adj.sh is
# the real fragment. GitHub, the model, the DB accept and the carry ledger are
# local stubs.
#   §I1 br_fix_round with reason iron-law -> no fix round, the hold ran;
#       a REJECT -> the ruling is carried as a build note, one rebuild, no round
#   §I2 the head read before the diff is the head the ACCEPT binds to, even
#       when the PR moved during the model call; a head that moved during the
#       diff read buys nothing
#   §I3 a moved head: carried hits -> an ACCEPT for the new head, no model;
#       a new hit -> exactly one more adjudication; undecidable -> hold;
#       BR_ILA_ADJ_MAX ruled heads -> rebuild
#   §I4 the project-4#2205 replay (tests/fixtures/bh-9437/project-4-2205.json):
#       1 adjudication, 0 fix rounds, 0 execute calls; test-tamper keeps its path
#   §Z  0 vendor calls
# Run: bash tests/br-ironlaw-adj.bh-9437-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: br-ironlaw-adj.bh-9437: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
. "$DIR/tests/lib/br-9437.sh" || exit 1
FRAG="$DIR/bin/blocked-resolver.d/bh-9437-ironlaw-adj.sh"
FIX="$DIR/tests/fixtures/bh-9437/project-4-2205.json"
[ -r "$FRAG" ] && ok || bad "I0 $FRAG is missing"
[ -r "$FIX" ] && ok || bad "I0 $FIX is missing"
[ -r "$DIR/catalog/lanes.d/blocked-resolver.knobs.d/BR_ILA_ADJ_MAX.json" ] && ok || bad "I0 the BR_ILA_ADJ_MAX knob row is missing"

bl9_extract "$DIR" "$T" br_adjudicate br_fix_round br_fix_cap br_cap_key br_rkey br_file br_load br_save br_record br_num \
  br_json_edit br_set_field br_slug_of_url br_pr_field || exit 1
bl9_tripwire "$T" || exit 1
H="$T/h"; mkdir -p "$H/bin" "$H/state/blocked-resolver" "$H/state/build-notes"
printf '#!/bin/bash\necho o/r\n' > "$H/bin/fleet-conf.sh"
# The model: writes its verdict ($T/verdict) to the run file, logs the stage,
# and moves the PR head when $T/move-on-model holds a sha.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$T/model.txt"
printf 'reasoning\n%s\n' "\$(cat "$T/verdict" 2>/dev/null)" > "\$5"
[ -s "$T/move-on-model" ] && mv "$T/move-on-model" "$T/head-now"
exit 0
EOF
chmod +x "$H/bin/"*.sh
HA=$(printf 'a%.0s' {1..40}); HB=$(printf 'b%.0s' {1..40})
URL=https://github.com/o/r/pull/9
cat > "$T/drv.sh" <<EOF
set -u
PATH="$T/fakebin:\$PATH"
H="$H"; ST="$H/state/blocked-resolver"; NOTES="$H/state/build-notes"; LOG="$T/say.txt"; OBSERVE=0
ADJ_TIMEOUT=60; BR_REVIEW_MODEL_ENV=X; GH_REST_STATUS=000; GH_REST_REASON=""
STAMP() { date -u +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok a record stamp; no assertion reads it
say() { printf '%s\n' "\$*" >> "\$LOG"; }
mc_slug_of_url() { printf '%s' "\${1#https://github.com/}" | sed 's#/pull/.*##'; }
mc_num_of_url() { grep -oE '[0-9]+\$' <<<"\$1"; }
# GitHub: the PR (its head is \$T/head-now) and its diff; the diff read moves
# the head when \$T/move-on-diff holds a sha.
gh_rest() {
  case "\$*" in
    *application/vnd.github.v3.diff*) printf '+++ b/src/ui.js\n+window.confirm("x")\n'
       [ -s "$T/move-on-diff" ] && mv "$T/move-on-diff" "$T/head-now"; return 0 ;;
    "GET repos/o/r/pulls/9") [ -s "$T/head-now" ] || return 1; jq -nc --arg h "\$(cat "$T/head-now")" '{state:"open", head:{sha:\$h}}'; return 0 ;;
  esac
  printf 'unexpected gh_rest %s\n' "\$*" >> "$T/vendor.txt"; return 1
}
br_model() { printf model-x; }
br_count() { :; }
br_ironlaw_context() { cat "\$1"; }
br_pr_comment() { :; }
br_opt_family_store() { :; }
br_quiet() { printf '%s\n' "\$*" >> "$T/quiet.txt"; }
br_cap_rows() { [ "\$6" = fixround ] && { printf 'FIXROUND\n' >> "$T/fixround.txt"; printf 99; return 0; }; printf '%s' "\$4"; }
br_fix_terminal_word() { printf 'terminal'; }
br_fix_terminal() { printf '%s\n' "\$*" >> "$T/terminal.txt"; }
br_rebuild_fresh() { printf '%s\n' "\$*" >> "$T/rebuild.txt"; }
ilc_hits() { cat "$T/hits"; }
ilc_covered() { printf 'covered stub\n'; return "\$(cat "$T/covered-rc" 2>/dev/null || echo 2)"; }
ilc_record() { printf 1; }
ila_key() { printf '%s@%s' "\$1" "\$2"; }
ila_put() { printf '%s %s %s\n' "\$1" "\$2" "\$4" >> "$T/ila.txt"
  local n; n=\$(cat "$T/ila-fail" 2>/dev/null || echo 0)
  if [ "\$n" -gt 0 ]; then echo \$((n - 1)) > "$T/ila-fail"; return 1; fi; return 0; }
bn_put() { printf '%s\n' "\$*" >> "$T/bn.txt"; return 0; }
. "$T/fns.sh"
. "$DIR/bin/blocked-resolver.d/bh-7804-ila-pending.sh"
for f in "$DIR"/bin/blocked-resolver.d/bh-9437-*.sh; do [ -r "\$f" ] && . "\$f"; done
EOF
printf 'no-dialog\tsrc/ui.js\th1\n' > "$T/hits"
RECF="$H/state/blocked-resolver/tproj/o-r-9.json"
REC() { cat "$RECF" 2>/dev/null; }
n() { cat "$T/$1.txt" 2>/dev/null | grep -c .; }
RESET() { local f; for f in "$H/state/blocked-resolver/tproj" "$H/state/build-notes/tproj" "$T"/{say,model,quiet,fixround,terminal,rebuild,ila,bn}.txt \
            "$T"/{head-now,move-on-diff,move-on-model,verdict,covered-rc,ila-fail}; do scratch_rm "$f" 2>/dev/null; done
  mkdir -p "$H/state/blocked-resolver/tproj"; }
# ruled <adjudications> <head:verdict>... — a record that already holds rulings
ruled() { local a="$1" r='[]' x; shift; for x in "$@"; do r=$(jq -c --arg h "${x%%:*}" --arg v "${x#*:}" '. + [{head:$h, verdict:$v, url:"'"$URL"'"}]' <<<"$r"); done
  jq -nc --argjson a "$a" --argjson r "$r" '{project:"tproj",rkey:"o-r-9",adjudications:$a,fixrounds:0,outcome:"",attempts:[],ila_ruled:$r}' > "$RECF"; }
ADJ() { ( . "$T/drv.sh"; br_adjudicate tproj o-r-9 "${1:-iron-law}" "$URL" - TP-9 ); }
FIXR() { ( . "$T/drv.sh"; br_fix_round tproj o-r-9 "${1:-iron-law}" "$URL" - TP-9 ); }

# ── §I1: never a fix round ────────────────────────────────────────────────
RESET; printf '%s' "$HA" > "$T/head-now"; ruled 1 "$HA:ACCEPT"
FIXR
[ "$(n fixround)" = 0 ] && ok || bad "I1 br_fix_round on iron-law must not run a round, entered $(n fixround)"
grep -q 'ACCEPT stands on' "$T/say.txt" && ok || bad "I1 the hold says the ACCEPT stands: $(tail -2 "$T/say.txt")"
grep -q "$URL $HA" "$T/ila.txt" 2>/dev/null && ok || bad "I1 the standing ACCEPT is written for the current head (idempotent, no model)"
[ "$(n model)" = 0 ] && ok || bad "I1 no model call"
# a REJECT: the ruling is carried, the ticket is rebuilt, no round
RESET; printf '%s' "$HA" > "$T/head-now"; printf REJECT > "$T/verdict"
ADJ
[ "$(n model)" = 1 ] && ok || bad "I1 one adjudication bought, got $(n model)"
[ "$(n fixround)" = 0 ] && ok || bad "I1 a REJECT never reaches a fix round, entered $(n fixround)"
[ "$(n rebuild)" = 1 ] && ok || bad "I1 a REJECT rebuilds once, got $(n rebuild)"
grep -q 'REJECTED' "$H/state/build-notes/tproj/TP-9.md" 2>/dev/null && ok || bad "I1 the REJECT ruling is carried as a build note: $(cat "$H/state/build-notes/tproj/TP-9.md" 2>/dev/null)"
[ "$(REC | jq -r '.ila_ruled[0].head + " " + .ila_ruled[0].verdict')" = "$HA REJECT" ] && ok || bad "I1 the ruling is bound to the head it read: $(REC | jq -c .ila_ruled)"
# the next tick (already adjudicated, same head): no model, no round
ADJ
[ "$(n model)" = 1 ] && [ "$(n fixround)" = 0 ] && ok || bad "I1 the next tick buys nothing (model $(n model), fixround $(n fixround))"

# ── §I2: the ACCEPT binds to the head it read ─────────────────────────────
RESET; printf '%s' "$HA" > "$T/head-now"; printf ACCEPT > "$T/verdict"; printf '%s' "$HB" > "$T/move-on-model"
ADJ
[ "$(n model)" = 1 ] && ok || bad "I2 one adjudication, got $(n model)"
grep -q "$URL $HA" "$T/ila.txt" 2>/dev/null && ok || bad "I2 the ACCEPT is written for the head read before the diff ($HA): $(cat "$T/ila.txt" 2>/dev/null)"
grep -q "$HB" "$T/ila.txt" 2>/dev/null && bad "I2 the ACCEPT must never bind to the head the PR moved to during the call ($HB)" || ok
[ "$(REC | jq -r '.ila_ruled[0].head')" = "$HA" ] && ok || bad "I2 the ruling row names the head it read"
RESET; printf '%s' "$HA" > "$T/head-now"; printf ACCEPT > "$T/verdict"; printf '%s' "$HB" > "$T/move-on-diff"
ADJ
[ "$(n model)" = 0 ] && ok || bad "I2 a head that moved during the diff read buys no adjudication, got $(n model)"
[ "$(REC | jq -rs '.[0].adjudications // 0')" = 0 ] && ok || bad "I2 and spends no counter"
grep -q 'moved during the diff read' "$T/say.txt" && ok || bad "I2 the move is said"
RESET; printf ACCEPT > "$T/verdict"
ADJ
[ "$(n model)" = 0 ] && ok || bad "I2 an unreadable head buys no adjudication"

# ── §I3: a moved head is scanned, not fixed ───────────────────────────────
RESET; printf '%s' "$HB" > "$T/head-now"; ruled 1 "$HA:ACCEPT"; printf 0 > "$T/covered-rc"
ADJ
[ "$(n model)" = 0 ] && [ "$(n fixround)" = 0 ] && ok || bad "I3 carried hits: no model, no round (model $(n model), fixround $(n fixround))"
grep -q "$URL $HB carried" "$T/ila.txt" 2>/dev/null && ok || bad "I3 carried hits write an ACCEPT for the new head: $(cat "$T/ila.txt" 2>/dev/null)"
RESET; printf '%s' "$HB" > "$T/head-now"; ruled 1 "$HA:ACCEPT"; printf 1 > "$T/covered-rc"; printf ACCEPT > "$T/verdict"
ADJ
[ "$(n model)" = 1 ] && [ "$(n fixround)" = 0 ] && ok || bad "I3 a new hit: exactly one more adjudication (model $(n model), fixround $(n fixround))"
[ "$(REC | jq -r '[.ila_ruled[].head] | join(",")')" = "$HA,$HB" ] && ok || bad "I3 the new head is ruled: $(REC | jq -c .ila_ruled)"
ADJ
[ "$(n model)" = 1 ] && ok || bad "I3 the ruled new head buys nothing more, got $(n model)"
RESET; printf '%s' "$HB" > "$T/head-now"; ruled 1 "$HA:ACCEPT"; printf 2 > "$T/covered-rc"
ADJ
[ "$(n model)" = 0 ] && [ "$(n fixround)" = 0 ] && [ "$(n rebuild)" = 0 ] && [ ! -s "$T/ila.txt" ] && ok || bad "I3 undecidable: hold (model $(n model), fixround $(n fixround), rebuild $(n rebuild))"
RESET; printf '%s' "$HB" > "$T/head-now"; ruled 1 "$HA:ACCEPT"; printf 1 > "$T/covered-rc"
( export BR_ILA_ADJ_MAX=1; ADJ )
[ "$(n model)" = 0 ] && [ "$(n rebuild)" = 1 ] && [ "$(n fixround)" = 0 ] && ok || bad "I3 BR_ILA_ADJ_MAX ruled heads: rebuild, no model (model $(n model), rebuild $(n rebuild))"

# ── §I4: the project-4#2205 replay ──────────────────────────────────────────
RESET
FH=$(jq -r .head "$FIX"); TICKS=$(jq -r .ticks "$FIX")
printf '%s' "$FH" > "$T/head-now"; jq -r .first_verdict "$FIX" > "$T/verdict"; jq -r .ila_put_fail_first "$FIX" > "$T/ila-fail"
for _ in $(seq "$TICKS"); do ADJ; done
[ "$(n model)" = "$(jq -r .expect.model_calls "$FIX")" ] && ok || bad "I4 model calls $(n model), want $(jq -r .expect.model_calls "$FIX")"
[ "$(REC | jq -r .adjudications)" = "$(jq -r .expect.adjudications "$FIX")" ] && ok || bad "I4 adjudications $(REC | jq -r .adjudications)"
[ "$(n fixround)" = "$(jq -r .expect.fix_rounds "$FIX")" ] && ok || bad "I4 fix rounds entered $(n fixround), want 0 (project-4#2205 took one per tick)"
[ "$(bl9_vendor_calls "$T")" = "$(jq -r .expect.execute_calls "$FIX")" ] && ok || bad "I4 execute calls: $(cat "$T/vendor.txt")"
[ "$(REC | jq -r '.ila_pending // empty')" = "" ] && ok || bad "I4 the pending ACCEPT was written in the end"
# test-tamper keeps today's path: the guard does not fire
( . "$T/drv.sh"; brlad_ila_no_fix tproj o-r-9 test-tamper "$URL" - TP-9 ); RC=$?
[ "$RC" = 1 ] && ok || bad "I4 test-tamper is not guarded, rc $RC"

# ── §Z: no vendor ─────────────────────────────────────────────────────────
[ "$(bl9_vendor_calls "$T")" = 0 ] && ok || bad "Z vendor calls: $(cat "$T/vendor.txt")"

echo "br-ironlaw-adj.bh-9437: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
