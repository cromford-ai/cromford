#!/bin/bash
# tests/qa-personas-pick.bh-5204-test.sh — BH-5204: personas may be drafted from
# the code by an agent, so the validator carries the safety floor (every persona
# names what it must never touch), and the QA lanes drive the fewest roles that
# cover the diff: one persona per changed app area, least privileged first.
#
# Sources bin/lib/qa-personas.sh and calls the real functions; the lanes that
# call them are pinned by tests/postmerge-qa-pick.bh-5204-test.sh and
# tests/e2e-smoke-pick.bh-5204-test.sh.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/qa-personas.sh"
# shellcheck source=../bin/lib/qa-personas.sh
. "$LIB" || { echo "FAIL: lib missing"; exit 1; }

W="$T/pick"; mkdir -p "$W"
A="$W/apps.json"; P="$W/personas.json"; M="$W/m.json"; C="$W/changed.txt"; E="$W/err.txt"
cat > "$A" <<'JSON'
{"version":1,"apps":{"finance":["apps/web/app/finance/**"],"ops":["apps/web/app/ops/**"],"shared":["packages/**","apps/web/lib/**"]}}
JSON
cat > "$P" <<'JSON'
{"version":1,"personas":[
 {"id":"viewer","role":"qa-viewer","sign_in":"clerk-ticket","apps":["shared"],
  "out_of_bounds":["/settings"],
  "flows":[{"id":"home","route":"/","observable":"home renders","production_safe":true,"steps":[{"goto":"/"}]}]},
 {"id":"finance-lead","role":"qa-finance","sign_in":"clerk-ticket","apps":["finance","shared"],
  "out_of_bounds":["refunds","mark-paid"],
  "flows":[
   {"id":"invoices","apps":["finance"],"route":"/finance/invoices","observable":"invoice table","production_safe":true,"steps":[{"goto":"/finance/invoices"}]},
   {"id":"ledger","route":"/finance/ledger","observable":"ledger renders","production_safe":true,"steps":[{"goto":"/finance/ledger"}]},
   {"id":"close-month","apps":["finance"],"route":"/finance/close","observable":"month closed","production_safe":false,"cleanup":"reopen the month","steps":[{"goto":"/finance/close"},{"click":"button"}]}]},
 {"id":"ops-lead","role":"qa-ops","sign_in":"clerk-ticket","apps":["ops"],
  "out_of_bounds":["send SMS"],
  "flows":[{"id":"queue","route":"/ops/queue","observable":"queue renders","production_safe":true,"steps":[{"goto":"/ops/queue"}]}]},
 {"id":"admin","role":"qa-admin","sign_in":"clerk-ticket","apps":["finance","ops","shared"],
  "out_of_bounds":["role changes","deletes"],
  "flows":[
   {"id":"users","apps":["ops"],"route":"/ops/users","observable":"users table","production_safe":true,"steps":[{"goto":"/ops/users"}]},
   {"id":"billing","apps":["finance"],"route":"/finance/billing","observable":"billing renders","production_safe":true,"steps":[{"goto":"/finance/billing"}]}]}
]}
JSON

mut()     { jq "$1" "$P" > "$M"; }
changed() { printf '%s\n' "$@" > "$C"; }
refused() { # refused <label> <apps-or-empty> <substring...>
  local label="$1" af="$2" out rc want; shift 2
  out=$(qa_personas_validate "$M" "$af" 2>&1); rc=$?
  [ "$rc" = 1 ] || { bad "$label: rc $rc, want 1 ($out)"; return; }
  [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || { bad "$label: want one line: $out"; return; }
  for want in "$@"; do
    case "$out" in *"$want"*) ;; *) bad "$label: want '$want' in: $out"; return ;; esac
  done
  ok
}
# pick <label> <personas> <apps-or-empty> <mode> <per-area>  -> $W/out.json, $W/pick.err
pick() {
  PICK_OUT=$(qa_personas_pick "$2" "$3" "$C" "$4" "$5" 2>"$W/pick.err"); PICK_RC=$?
  printf '%s\n' "$PICK_OUT" > "$W/out.json"
}
ids() { jq -c '[.personas[].id]' "$W/out.json" 2>/dev/null; }
is()  { jq -e "$1" "$W/out.json" >/dev/null 2>&1; }

# ── V1-V6 the validator: the out_of_bounds floor and flow-level apps ─────────
mut 'del(.personas[2].out_of_bounds)'
refused "V1 persona with no out_of_bounds" "$A" ".personas[2].out_of_bounds" "non-empty array"
mut '.personas[1].out_of_bounds=[]'
refused "V2 empty out_of_bounds" "$A" ".personas[1].out_of_bounds" "must list at least one"
mut '.personas[0].out_of_bounds=["","/x"]'
refused "V3 empty-string entry" "$A" ".personas[0].out_of_bounds[0]" "non-empty string"
mut '.personas[0].out_of_bounds="refunds"'
refused "V3b out_of_bounds a string" "$A" ".personas[0].out_of_bounds" "must be a non-empty array"
mut '.personas[2].flows[0].apps=["finance"]'
refused "V4 flow app outside the persona's apps" "$A" ".personas[2].flows[0].apps[0]" "is not one of this persona's apps"
mut '.personas[2].apps=null | .personas[2].flows[0].apps=["nope"]'
refused "V5 flow app not in apps.json" "$A" ".personas[2].flows[0].apps[0]" "unknown app \"nope\""
mut '.personas[2].flows[0].apps=[]'
refused "V5b flow apps empty" "$A" ".personas[2].flows[0].apps" "must be a non-empty array of strings"
mut '.personas[2].flows[0].apps=[3]'
refused "V5c flow apps not strings" "$A" ".personas[2].flows[0].apps" "must be a non-empty array of strings"
# a no-apps persona with a flow app and NO apps.json is not refused for it
mut '.personas[2].apps=null | .personas[2].flows[0].apps=["anything"]'
qa_personas_validate "$M" 2>"$E" && ok || bad "V5d flow app with no apps.json and no persona apps: $(cat "$E")"
qa_personas_validate "$P" "$A" 2>"$E" && [ ! -s "$E" ] && ok || bad "V6 shared fixture must validate: $(cat "$E")"
qa_personas_validate "$DIR/tests/fixtures/qa-personas/valid.json" "$DIR/tests/fixtures/qa-personas/apps.json" 2>"$E" \
  && ok || bad "V6 tests/fixtures/qa-personas/valid.json must validate: $(cat "$E")"

# ── P1/P2/P5 finance-only diff: one role ─────────────────────────────────────
changed apps/web/app/finance/a.tsx
pick P1 "$P" "$A" preview 1
[ "$PICK_RC" = 0 ] && [ "$(ids)" = '["finance-lead"]' ] && ok || bad "P1 finance diff picks finance-lead only, got rc=$PICK_RC $(ids)"
is '.pick.per_area==1 and .pick.areas==[{"area":"finance","personas":["finance-lead"]}]' \
  && ok || bad "P1 pick.areas: $(jq -c .pick "$W/out.json")"
is '.pick.skipped==[{"id":"viewer","why":"not relevant to the diff"},{"id":"ops-lead","why":"not relevant to the diff"},{"id":"admin","why":"area already covered"}]' \
  && ok || bad "P1 pick.skipped: $(jq -c .pick.skipped "$W/out.json")"
is '[.personas[0].flows[].id]==["invoices","ledger","close-month"] and .pick.flows_dropped==[] and (.personas[0].flows[2]|has("steps"))' \
  && ok || bad "P2 finance-lead keeps all three flows in preview: $(jq -c '[.personas[0].flows[].id]' "$W/out.json")"
cp "$W/out.json" "$W/p1.json"
pick P2 "$P" "$A" production 1
is '.mode=="production" and .personas[0].flows[2].skipped=="write flow, production" and (.personas[0].flows[2]|has("steps")|not)' \
  && ok || bad "P2 production keeps the write flow skipped without steps"

# ── P3 finance + ops: two roles, file order ──────────────────────────────────
changed apps/web/app/finance/a.tsx apps/web/app/ops/q.tsx
pick P3 "$P" "$A" preview 1
[ "$(ids)" = '["finance-lead","ops-lead"]' ] && ok || bad "P3 finance+ops picks finance-lead,ops-lead, got $(ids)"
is '.pick.areas==[{"area":"finance","personas":["finance-lead"]},{"area":"ops","personas":["ops-lead"]}]' \
  && ok || bad "P3 areas: $(jq -c .pick.areas "$W/out.json")"
P3IDS=$(ids)

# ── P4 shared-only: the least privileged role ────────────────────────────────
changed packages/ui/x.ts
pick P4 "$P" "$A" preview 1
[ "$(ids)" = '["viewer"]' ] && ok || bad "P4 shared-only picks viewer, got $(ids)"
P4IDS=$(ids)

# ── P5 admin never driven for an area someone less privileged covers ────────
case "$(cat "$W/p1.json" | jq -c '[.personas[].id]') $P3IDS $P4IDS" in
  *admin*) bad "P5 admin was picked in P1/P3/P4" ;; *) ok ;; esac
case "$(jq -c '[.personas[].id]' "$W/p1.json") $P4IDS" in
  *ops-lead*) bad "P5 ops-lead picked for a diff with no ops change" ;; *) ok ;; esac

# ── P6 flow narrowing: admin first, ops-only diff ────────────────────────────
jq '.personas = ([.personas[3]] + .personas[0:3])' "$P" > "$W/admin-first.json"
changed apps/web/app/ops/q.tsx
pick P6 "$W/admin-first.json" "$A" preview 1
[ "$(ids)" = '["admin"]' ] && ok || bad "P6 admin-first ops diff picks admin, got $(ids)"
is '[.personas[0].flows[].id]==["users"] and .pick.flows_dropped==[{"persona":"admin","flow":"billing"}]' \
  && ok || bad "P6 billing dropped from admin: $(jq -c '{f:[.personas[0].flows[].id],d:.pick.flows_dropped}' "$W/out.json")"
cp "$W/out.json" "$W/p6.json"

# ── P7 zero-flow fallback: narrowing never empties a picked persona ─────────
jq '.personas[0].flows |= map(select(.id=="billing"))' "$W/admin-first.json" > "$W/admin-billing.json"
pick P7 "$W/admin-billing.json" "$A" preview 1
is '[.personas[0].flows[].id]==["billing"] and .pick.flows_dropped==[]' \
  && ok || bad "P7 all flows kept when narrowing would leave none: $(jq -c '{f:[.personas[0].flows[].id],d:.pick.flows_dropped}' "$W/out.json")"

# ── P8 per-area 2 ────────────────────────────────────────────────────────────
changed apps/web/app/finance/a.tsx
pick P8 "$P" "$A" preview 2
[ "$(ids)" = '["finance-lead","admin"]' ] && ok || bad "P8 per-area 2 picks finance-lead,admin, got $(ids)"
is '.pick.per_area==2' && ok || bad "P8 pick.per_area"

# ── P9 a bad per-area is 1, said once on stderr ──────────────────────────────
for BADN in x 0 -2 ""; do
  pick P9 "$P" "$A" preview "$BADN"
  if [ "$(ids)" = '["finance-lead"]' ] && grep -q 'using 1' "$W/pick.err" && [ "$(wc -l < "$W/pick.err")" = 1 ]; then ok
  else bad "P9 per-area '$BADN' should fall back to 1 with one stderr line: $(ids) / $(cat "$W/pick.err")"; fi
done

# ── P10 no apps map, empty diff, unmapped path ───────────────────────────────
changed apps/web/app/finance/a.tsx
pick P10a "$P" "" preview 1
[ "$(ids)" = '["viewer"]' ] && is '.pick.areas==[{"area":"*","personas":["viewer"]}]' \
  && ok || bad "P10 no apps.json: one area *, first persona: $(ids) $(jq -c .pick.areas "$W/out.json")"
: > "$C"
pick P10b "$P" "$A" preview 1
[ "$PICK_RC" = 0 ] && [ "$PICK_OUT" = NONE ] && ok || bad "P10 empty diff with an apps map is NONE, got rc=$PICK_RC $PICK_OUT"
jq '.personas += [{"id":"guest","role":"qa-guest","sign_in":"clerk-ticket","out_of_bounds":["/admin"],
     "flows":[{"id":"landing","route":"/","observable":"renders","production_safe":true,"steps":[{"goto":"/"}]}]}]' "$P" > "$W/guest.json"
changed README.md
pick P10c "$W/guest.json" "$A" preview 1
[ "$(ids)" = '["guest"]' ] && is '.pick.areas==[{"area":"(unmapped)","personas":["guest"]}]' \
  && ok || bad "P10 unmapped path picks the no-apps persona: $(ids) $(jq -c .pick.areas "$W/out.json")"
# an area nobody owns is recorded with an empty list
pick P10d "$P" "$A" preview 1
[ "$PICK_OUT" = NONE ] && ok || bad "P10 unmapped path with no no-apps persona is NONE, got $(ids)"
changed README.md apps/web/app/ops/q.tsx
pick P10e "$P" "$A" preview 1
is '.pick.areas==[{"area":"ops","personas":["ops-lead"]},{"area":"(unmapped)","personas":[]}]' \
  && ok || bad "P10 ownerless area recorded empty: $(jq -c .pick.areas "$W/out.json")"
[ "$(qa_personas_pick_note "$W/out.json")" = 'picked ops:ops-lead (unmapped):none; skipped (not relevant to the diff): viewer finance-lead; skipped (area already covered): admin' ] \
  && ok || bad "N0 ownerless area prints none: $(qa_personas_pick_note "$W/out.json")"

# ── P11 refusals are refusals, never NONE ────────────────────────────────────
changed apps/web/app/finance/a.tsx
mut 'del(.personas[0].out_of_bounds)'
pick P11 "$M" "$A" preview 1
[ "$PICK_RC" = 1 ] && [ -z "$PICK_OUT" ] && grep -q 'out_of_bounds' "$W/pick.err" \
  && ok || bad "P11 invalid file: rc=$PICK_RC out='$PICK_OUT'"
pick P11b "$P" "$A" staging 1
[ "$PICK_RC" = 1 ] && [ -z "$PICK_OUT" ] && ok || bad "P11 bad mode: rc=$PICK_RC out='$PICK_OUT'"
PICK_OUT=$(qa_personas_pick "$P" "$A" "$W/nope.txt" preview 1 2>/dev/null); PICK_RC=$?
[ "$PICK_RC" = 1 ] && [ -z "$PICK_OUT" ] && ok || bad "P11 missing changed-files: rc=$PICK_RC"

# ── N1 the note ──────────────────────────────────────────────────────────────
NOTE=$(qa_personas_pick_note "$W/p1.json")
[ "$NOTE" = 'picked finance:finance-lead; skipped (not relevant to the diff): viewer ops-lead; skipped (area already covered): admin' ] \
  && ok || bad "N1 note on P1: $NOTE"
NOTE=$(qa_personas_pick_note "$W/p6.json")
case "$NOTE" in *'; flows not relevant to the diff: admin/billing') ok ;; *) bad "N1 note on P6: $NOTE" ;; esac
[ "$(printf '%s' "$NOTE" | wc -l)" = 0 ] && ok || bad "N1 note must be one line"
changed apps/web/app/finance/a.tsx
pick N2 "$P" "$A" preview 2
case "$(qa_personas_pick_note "$W/out.json")" in 'picked finance:finance-lead+admin;'*) ok ;; *) bad "N2 per-area 2 joins with +: $(qa_personas_pick_note "$W/out.json")" ;; esac

# ── K1 the knob ──────────────────────────────────────────────────────────────
[ "$(env -u QA_PERSONAS_PER_AREA bash -c '. "$1"; qa_personas_per_area' _ "$LIB" 2>/dev/null)" = 1 ] \
  && ok || bad "K1 default is 1"
[ "$(QA_PERSONAS_PER_AREA=3 bash -c '. "$1"; qa_personas_per_area' _ "$LIB" 2>/dev/null)" = 3 ] \
  && ok || bad "K1 env 3"
[ "$(QA_PERSONAS_PER_AREA=3 bash -c '. "$1"; _lg_setting_lookup() { [ "$1" = qa.personas_per_area ] && echo 2; }; qa_personas_per_area' _ "$LIB" 2>/dev/null)" = 2 ] \
  && ok || bad "K1 settings row wins over env"
[ "$(QA_PERSONAS_PER_AREA=3 bash -c '. "$1"; _lg_setting_lookup() { return 1; }; qa_personas_per_area' _ "$LIB" 2>/dev/null)" = 3 ] \
  && ok || bad "K1 no row falls to env"
KO=$(QA_PERSONAS_PER_AREA=abc bash -c '. "$1"; qa_personas_per_area' _ "$LIB" 2>"$E")
[ "$KO" = 1 ] && grep -q 'using 1' "$E" && ok || bad "K1 env abc -> 1 + stderr: '$KO' / $(cat "$E")"

# ── D1 doc pins: the rule changed where people and agents read it ───────────
SK="$DIR/skills/qa-personas/SKILL.md"
grep -q 'Nothing here is generated by a model' "$SK" && bad "D1 skill still forbids model drafting" || ok
for W1 in out_of_bounds refund Stripe mark-paid SMS delete invite; do
  grep -qi -- "$W1" "$SK" && ok || bad "D1 skill missing '$W1'"
done
grep -q '^### Picking: one role per changed area' "$DIR/docs/E2E-POLICY.md" && ok || bad "D1 policy missing the Picking section"
grep -q 'qa.personas_per_area' "$DIR/docs/E2E-POLICY.md" && ok || bad "D1 policy missing the knob"
grep -q 'No model wrote these personas' "$DIR/bin/qa-personas.sh" && bad "D1 generator PR body still says no model wrote them" || ok

# ── S1 the knob ships as a D1 settings row ───────────────────────────────────
SQL="$DIR/worker/jobs/schema.sql"
[ "$(grep -c "'qa.personas_per_area','1'" "$SQL")" = 1 ] && ok || bad "S1 want exactly one qa.personas_per_area seed row"
awk "/INSERT OR IGNORE INTO settings/{s=1} s&&/'qa.personas_per_area','1'/{print; exit}" "$SQL" | grep -q "'seed'" \
  && ok || bad "S1 seed row must be in an INSERT OR IGNORE INTO settings with actor seed"

echo "qa-personas-pick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
