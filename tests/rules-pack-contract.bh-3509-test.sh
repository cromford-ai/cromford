#!/bin/bash
# tests/rules-pack-contract.bh-3509-test.sh — the rules-pack contract slice
# (BH-3509, BH-3477.0): the stub entry point, its catalog, the snapshot lib
# stubs, the date-bomb lint stub and the three fly-pool knobs.
#
#   R0a. --list prints exactly the 23 catalog ids.
#   R0b. every catalog row has 6 TAB fields with valid shape/kind/needs.
#   R0c. every suite/cmd argv script path exists in the repo.
#   C1.  bad args -> rc 2; a valid run answers the pack contract.
#   C2.  the snapshot lib sources cleanly and defines its three functions
#        (their behavior: tests/rules-pack-snapshot.bh-3511-test.sh).
#   C3.  the date-bomb lint: bad args rc 2, and (BH-3512, the stub is now the
#        real lint) a run is never the stub's 125: rc 2 outside a git tree,
#        rc 0/1 on a real --all inventory.
#   R16. the three knobs in fly-pool.json, each read_in naming its env.
# Run from anywhere: tests/rules-pack-contract.bh-3509-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RP="$DIR/bin/rules-pack.sh"
SNAP="$DIR/bin/lib/rules-pack-snapshot.sh"
DBL="$DIR/bin/test-date-bomb-lint.sh"
CAT="$DIR/catalog/rules-pack.tsv"
FP="$DIR/catalog/lanes.d/fly-pool.json"

[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1

# run <cmd...> — sets RC, OUT, ERR
run() {
  "$@" >"$T/out" 2>"$T/err"; RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}

# --- R0a ------------------------------------------------------------------
# TEST-CHANGE (BH-5797): the pack gained fast-lints-data (the builder verify
# step runs the CI fast lints) and marker-reason (a marker carries its reason).
# TEST-CHANGE (BH-5789): and fixture-hygiene (the delta lint for test fixtures).
# TEST-CHANGE (BH-4582): and tier-wording (no "tier-2 waits for a human" wording).
# TEST-CHANGE (BH-4987): and lanes-knob-delta (a new knob is its own fragment file).
# TEST-CHANGE (BH-5788): and schema-fragment, schema-fragment-name and
# discipline-dupes (three builtins).
# TEST-CHANGE (BH-6730): and index-on-create-table (a delta builtin).
# TEST-CHANGE (BH-6293): and split-host-growth (a split host's growth limit).
# TEST-CHANGE (BH-5945): and project-loop (a new hub lane uses the per-project runner).
# The list still pins every id exactly.
WANT="agent-push alert-writers changelog-headers checks-tree date-bomb determinism discipline-dupes fast-lints-data fixture-hygiene grep-q index-on-create-table jobs-client-modules lanes-knob-delta lib-root marker-reason model-id-delta model-literal project-loop route-fragments schema-fragment schema-fragment-name scratch-closure split-host-growth switch test-sources tier-wording"
run bash "$RP" --list
LIST_IDS=$(printf '%s\n' "$OUT" | awk 'NF {print $1}' | sort | tr '\n' ' ' | sed 's/ $//')
CAT_IDS=$( [ -r "$CAT" ] && grep -v '^#' "$CAT" | awk -F'\t' 'NF {print $1}' | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$RC" -eq 0 ]; then ok; else bad "R0a --list rc $RC (want 0): $ERR"; fi
if [ "$LIST_IDS" = "$WANT" ]; then ok; else bad "R0a --list ids [$LIST_IDS] != [$WANT]"; fi
if [ -n "$CAT_IDS" ] && [ "$CAT_IDS" = "$WANT" ]; then ok; else bad "R0a catalog ids [$CAT_IDS] != [$WANT]"; fi

# --- R0b ------------------------------------------------------------------
if [ -r "$CAT" ]; then
  rows=$(grep -v '^#' "$CAT" | grep -c .)
  # TEST-CHANGE (BH-5788): three new rows, 20 -> 23.
  # TEST-CHANGE (BH-6293): split-host-growth, 24 -> 25.
  # TEST-CHANGE (BH-5945): project-loop, 25 -> 26.
  [ "$rows" -eq 26 ] && ok || bad "R0b catalog has $rows rows (want 26)"
  badnf=$(grep -v '^#' "$CAT" | grep . | awk -F'\t' 'NF!=6 {print $1}')
  [ -z "$badnf" ] && ok || bad "R0b rows without exactly 6 TAB fields: $badnf"
  badval=$(grep -v '^#' "$CAT" | grep . | awk -F'\t' '
    $2 !~ /^(delta|tree)$/ || $3 !~ /^(suite|cmd|builtin)$/ || $5 !~ /^(-|[a-z0-9]+(,[a-z0-9]+)*)$/ {print $1}')
  [ -z "$badval" ] && ok || bad "R0b rows with a bad shape/kind/needs: $badval"
  field() { grep -v '^#' "$CAT" | awk -F'\t' -v id="$1" -v c="$2" '$1==id {print $c}'; }
  [ "$(field alert-writers 5)" = python3 ] && ok || bad "R0b alert-writers needs '$(field alert-writers 5)' (want python3)"
  [ "$(field switch 5)" = jq ] && ok || bad "R0b switch needs '$(field switch 5)' (want jq)"
  [ "$(field route-fragments 5)" = node ] && ok || bad "R0b route-fragments needs '$(field route-fragments 5)' (want node)"
  [ "$(field grep-q 3)|$(field grep-q 4)" = "builtin|rp_grep_q" ] && ok || bad "R0b grep-q is not builtin rp_grep_q"
  [ "$(field model-id-delta 3)|$(field model-id-delta 4)" = "builtin|rp_model_id_delta" ] && ok || bad "R0b model-id-delta is not builtin rp_model_id_delta"
  [ "$(field schema-fragment 2)|$(field schema-fragment 3)|$(field schema-fragment 4)" = "delta|builtin|rp_schema_fragment" ] && ok || bad "R0b schema-fragment is not delta builtin rp_schema_fragment"
  [ "$(field schema-fragment-name 2)|$(field schema-fragment-name 3)|$(field schema-fragment-name 4)" = "delta|builtin|rp_schema_fragment_name" ] && ok || bad "R0b schema-fragment-name is not delta builtin rp_schema_fragment_name"
  [ "$(field discipline-dupes 2)|$(field discipline-dupes 3)|$(field discipline-dupes 4)" = "tree|builtin|rp_discipline_dupes" ] && ok || bad "R0b discipline-dupes is not tree builtin rp_discipline_dupes"
else
  bad "R0b no catalog at $CAT"
fi

# --- R0c ------------------------------------------------------------------
if [ -r "$CAT" ]; then
  checked=0
  while IFS=$'\t' read -r id _shape kind argv _needs _reason; do
    case "$id" in ''|'#'*) continue ;; esac
    case "$kind" in suite|cmd) ;; *) continue ;; esac
    sub=""
    if [[ "$argv" =~ ^cd[[:space:]]+([^[:space:]]+)[[:space:]]*\&\&[[:space:]]*(.*)$ ]]; then
      sub="${BASH_REMATCH[1]}/"; argv="${BASH_REMATCH[2]}"
    fi
    for tok in $argv; do
      case "$tok" in *.sh|*.js)
        checked=$((checked+1))
        [ -f "$DIR/$sub$tok" ] && ok || bad "R0c $id: $sub$tok does not exist"
      esac
    done
  done < "$CAT"
  [ "$checked" -ge 11 ] && ok || bad "R0c only $checked argv paths checked (want >= 11)"
else
  bad "R0c no catalog at $CAT"
fi

# --- C1 -------------------------------------------------------------------
run bash "$RP" --bogus
[ "$RC" -eq 2 ] && ok || bad "C1a --bogus rc $RC (want 2)"
[ -z "$OUT" ] && ok || bad "C1a --bogus wrote stdout: $OUT"

# BH-3510 replaced the stub: a valid run is judged now, so C1b pins the pack's
# own answers (rc 2 on an unresolvable base; rc 0 and summary.json otherwise).
run bash "$RP" --base nosuchref-bh3509
[ "$RC" -eq 2 ] && ok || bad "C1b unresolvable base rc $RC (want 2)"
case "$ERR" in *nosuchref-bh3509*) ok ;; *) bad "C1b unresolvable base stderr does not name it: $ERR" ;; esac
[ -z "$OUT" ] && ok || bad "C1b unresolvable base wrote stdout: $OUT"

# --base HEAD: the fork is HEAD, so a grep-q hit on this checkout is red at
# both ends (pre-existing) and the run is rc 0 on any checkout.
run bash "$RP" --tree "$DIR" --base HEAD --runner local --jobs 2 --out "$T/o" --only grep-q,model-id-delta --skip model-id-delta
[ "$RC" -eq 0 ] && ok || bad "C1b full valid run rc $RC (want 0): $ERR"
[ -z "$OUT" ] && ok || bad "C1b full valid run wrote stdout: $OUT"
ids=$(jq -r '[.components[].id]|join(",")' "$T/o/summary.json" 2>/dev/null)
[ "$ids" = grep-q ] && ok || bad "C1b full valid run components [$ids] (want grep-q)"

for args in "--runner bogus" "--jobs 0" "--jobs x" "--only nosuch" "--skip nosuch" "--tree $T/missing" "--tree" "--list --runner bogus" "--only lib-root,nosuch" "--base"; do
  # shellcheck disable=SC2086
  run bash "$RP" $args
  [ "$RC" -eq 2 ] && ok || bad "C1c '$args' rc $RC (want 2)"
  [ -z "$OUT" ] && ok || bad "C1c '$args' wrote stdout: $OUT"
done
run bash "$RP" --only ''
[ "$RC" -eq 2 ] && ok || bad "C1c --only '' rc $RC (want 2)"

# --- C2 -------------------------------------------------------------------
got=$(bash -c 'set -euo pipefail; . "$1"; declare -F rp_snapshot_probe rp_snapshot_build rp_snapshot_run' _ "$SNAP" 2>&1); src_rc=$?
[ "$src_rc" -eq 0 ] && ok || bad "C2 sourcing under set -euo pipefail rc $src_rc: $got"
for f in rp_snapshot_probe rp_snapshot_build rp_snapshot_run; do
  case "$got" in *"$f"*) ok ;; *) bad "C2 $f not defined" ;; esac
done
if [ -f "$SNAP" ] && ! grep -Eq ':-/root/harness|^[[:space:]]*(local )?[A-Z_]+=/root/harness' "$SNAP"; then ok
else bad "C2 $SNAP missing or carries a /root/harness default"; fi

# --- C3 -------------------------------------------------------------------
run bash "$DBL" --bogus
[ "$RC" -eq 2 ] && ok || bad "C3 --bogus rc $RC (want 2)"
run bash "$DBL" --base
[ "$RC" -eq 2 ] && ok || bad "C3 --base with no value rc $RC (want 2)"
run bash "$DBL" "$T/missing"
[ "$RC" -eq 2 ] && ok || bad "C3 missing root rc $RC (want 2)"
run bash "$DBL"
[ "$RC" -eq 2 ] && ok || bad "C3 plain run outside a git tree rc $RC (want 2)"
case "$ERR" in *"not a git work tree"*) ok ;; *) bad "C3 plain run stderr lacks 'not a git work tree': $ERR" ;; esac
run bash "$DBL" --base origin/main --all "$DIR"
case "$RC" in 0|1) ok ;; *) bad "C3 full valid run rc $RC (want 0 or 1): $ERR" ;; esac

# --- R16 ------------------------------------------------------------------
knob() { jq -r --arg e "$1" "[.knobs[] | select(.env==\$e)][0] | $2" "$FP" 2>/dev/null; }
[ "$(knob RULES_PACK_BUDGET_S '"\(.default) \(.min) \(.max)"')" = "60 10 600" ] && ok || bad "R16 RULES_PACK_BUDGET_S default/min/max"
[ "$(knob RULES_PACK_JOBS '"\(.default) \(.min) \(.max)"')" = "4 1 8" ] && ok || bad "R16 RULES_PACK_JOBS default/min/max"
[ "$(knob RULES_PACK_BLOCK '"\(.default) \(.min) \(.max)"')" = "1 0 1" ] && ok || bad "R16 RULES_PACK_BLOCK default/min/max"
[ "$(knob RULES_PACK_BLOCK '.zero_means')" != null ] && [ -n "$(knob RULES_PACK_BLOCK '.zero_means')" ] && ok || bad "R16 RULES_PACK_BLOCK zero_means not set"
case "$(knob RULES_PACK_BLOCK '.note')" in *"warn only"*) ok ;; *) bad "R16 RULES_PACK_BLOCK note lacks 'warn only'" ;; esac
for e in RULES_PACK_BUDGET_S RULES_PACK_JOBS RULES_PACK_BLOCK; do
  ri=$(knob "$e" '.read_in')
  if [ -n "$ri" ] && [ "$ri" != null ] && [ -f "$DIR/$ri" ] && grep -qw "$e" "$DIR/$ri"; then ok
  else bad "R16 $e read_in '$ri' missing or does not name it"; fi
done

echo "rules-pack-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
