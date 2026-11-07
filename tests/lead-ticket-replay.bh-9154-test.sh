#!/bin/bash
# tests/lead-ticket-replay.bh-9154-test.sh — Fix 3 and AT3 of #9066 (BH-9154):
# one lead review per ticket per real diff in 24 h.
#   bin/lib/patch-fp.sh            patch_review_fp, patch_ticket_key
#   bin/lib/lead-review/result.sh  finish_done stores the lead's word under
#                                  (repo, ticket key, patch fp)
#   bin/lib/lead-gates.d/52-ticket-replay.sh  a second PR of the ticket with
#                                  the same fp, inside the window, gets that
#                                  word with no model call
# The e2e cases run bin/lead-review.sh tick WHOLE over
# tests/lib/lead-worklist-fixture.bh-4956.sh; a curl wrapper on PATH plays the
# harness-jobs lead_ticket_verdicts route (store under $FX/ltv, the server's
# window rule) and passes every other request to the fixture's curl.
#   F1  patch_review_fp is equal across a rebase and across a schema restamp
#   F2  it differs on one code line, on a trailing space, on a mode change, and
#       on a fragment whose suffix changed; rc 1 on an empty diff
#   K1  patch_ticket_key: ticket/<key>, ticket/<key>-rN, a title key, none
#   T3  PR 301 (ticket/bh-77) is reviewed (1 agent call) and its MERGE is
#       POSTed with ticket BH-77 and the fp of its head
#   T4  PR 302 (ticket/bh-77-r2), the same patch rebased onto a newer main:
#       0 agent calls, one lead MERGE post on its head with the note
#       `lead-replay:<sha12> how:ticket-replay rebound: ticket-replay 301@<sha12>`,
#       no lr-302 job, one review-saving job, the log line
#   T5  a stored BLOCK is not replayed: the review runs
#   T6  a stored MERGE 86401 s old: the review runs; 86399 s old: replayed
#   T7  on a hit no pr-attempts row is read or written
#   T8  the route answers 500: the review runs, one log line
#   T9  another ticket key with the same fp: the review runs
#   T10 the same ticket, one code line different: the review runs
#   T11 LEAD_TICKET_REPLAY=0: the route is never read, the review runs
#   T12 no lead token on the box: no post, the review runs
#   T13 the verdict post fails: the review runs (never done without a verdict)
#   T14 a model BLOCK is stored too (it replaces a stored MERGE of that fp)
#   T15 the knob defaults in catalog/lanes.d/_lib.lead-ticket-replay.json
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-ticket-replay.bh-9154-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 missing"; exit 1; }
for f in bin/lib/patch-fp.sh bin/lib/lead-gates.d/52-ticket-replay.sh bin/lib/lead-review/result.sh \
         worker/jobs/src/routes/lead-ticket-verdicts.js worker/jobs/src/routes/retention.d/bh-9154-lead-ticket-verdicts.js \
         catalog/lanes.d/_lib.lead-ticket-replay.json; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_TICKET_REPLAY LEAD_TICKET_REPLAY_WINDOW_S

# ── F1/F2/K1: the pure lib, on its own git fixture ──
FPG="$T/fpgit"; git init -q -b main "$FPG"
fg=(git -C "$FPG" -c user.email=t@t -c user.name=t)
mkdir -p "$FPG/worker/jobs/schema.d" "$FPG/bin"
printf 'one\n' > "$FPG/a.txt"; printf '#!/bin/bash\necho hi\n' > "$FPG/bin/x.sh"
"${fg[@]}" add -A; "${fg[@]}" commit -qm base; M0=$("${fg[@]}" rev-parse HEAD)
# P1: a code line and a stamped fragment, named in a doc line
"${fg[@]}" checkout -q -b p1
printf 'one\ntwo\n' > "$FPG/a.txt"
printf 'CREATE TABLE IF NOT EXISTS t (a TEXT);\n' > "$FPG/worker/jobs/schema.d/202611010000-bh-77-t.sql"
printf 'see 202611010000-bh-77-t.sql\n' > "$FPG/notes.md"
"${fg[@]}" add -A; "${fg[@]}" commit -qm p1; P1=$("${fg[@]}" rev-parse HEAD)
# main moves
"${fg[@]}" checkout -q main; printf 'm\n' > "$FPG/m.txt"; "${fg[@]}" add -A; "${fg[@]}" commit -qm "main moves"; M1=$("${fg[@]}" rev-parse HEAD)
# P2: P1 rebased onto M1, fragment restamped and its reference rewritten
"${fg[@]}" checkout -q -b p2 "$M1"
mkdir -p "$FPG/worker/jobs/schema.d"
printf 'one\ntwo\n' > "$FPG/a.txt"
printf 'CREATE TABLE IF NOT EXISTS t (a TEXT);\n' > "$FPG/worker/jobs/schema.d/202611050000-bh-77-t.sql"
printf 'see 202611050000-bh-77-t.sql\n' > "$FPG/notes.md"
"${fg[@]}" add -A; "${fg[@]}" commit -qm p2; P2=$("${fg[@]}" rev-parse HEAD)
# P3: P1 rebased with no restamp
"${fg[@]}" checkout -q -b p3 "$M1"; "${fg[@]}" cherry-pick "$P1" >/dev/null; P3=$("${fg[@]}" rev-parse HEAD)
# P4: P2 plus one code line
"${fg[@]}" checkout -q -b p4 "$P2"; printf 'one\ntwo\nthree\n' > "$FPG/a.txt"; "${fg[@]}" commit -qam p4; P4=$("${fg[@]}" rev-parse HEAD)
# P5: P2 with a trailing space on the code line
"${fg[@]}" checkout -q -b p5 "$P2"; printf 'one\ntwo \n' > "$FPG/a.txt"; "${fg[@]}" commit -qam p5; P5=$("${fg[@]}" rev-parse HEAD)
# P6: P2 plus a mode change of bin/x.sh
"${fg[@]}" checkout -q -b p6 "$P2"; chmod +x "$FPG/bin/x.sh"; "${fg[@]}" update-index --chmod=+x bin/x.sh; "${fg[@]}" commit -qm p6; P6=$("${fg[@]}" rev-parse HEAD)
# P7: P2 with the fragment's suffix changed
"${fg[@]}" checkout -q -b p7 "$M1"
mkdir -p "$FPG/worker/jobs/schema.d"
printf 'one\ntwo\n' > "$FPG/a.txt"
printf 'CREATE TABLE IF NOT EXISTS t (a TEXT);\n' > "$FPG/worker/jobs/schema.d/202611050000-bh-77-u.sql"
printf 'see 202611050000-bh-77-u.sql\n' > "$FPG/notes.md"
"${fg[@]}" add -A; "${fg[@]}" commit -qm p7; P7=$("${fg[@]}" rev-parse HEAD)
# P8: no fragment, a plain code line, and the same rebased
"${fg[@]}" checkout -q -b p8 "$M0"; printf 'one\nplain\n' > "$FPG/a.txt"; "${fg[@]}" commit -qam p8; P8=$("${fg[@]}" rev-parse HEAD)
"${fg[@]}" checkout -q -b p9 "$M1"; "${fg[@]}" cherry-pick "$P8" >/dev/null; P9=$("${fg[@]}" rev-parse HEAD)
"${fg[@]}" checkout -q main
fp() { ( . "$SRC/bin/lib/patch-fp.sh" && patch_review_fp "$FPG" main "$1" ); }
F1=$(fp "$P1"); F2=$(fp "$P2"); F3=$(fp "$P3"); F4=$(fp "$P4"); F5=$(fp "$P5"); F6=$(fp "$P6"); F7=$(fp "$P7"); F8=$(fp "$P8"); F9=$(fp "$P9")
[[ "$F1" =~ ^v1-[0-9a-f]{64}$ ]] && ok || bad "F1 fp of P1 is not v1-<64 hex>: '$F1'"
[ -n "$F1" ] && [ "$F1" = "$F2" ] && ok || bad "F1 restamp changed the fp: $F1 / $F2"
[ -n "$F1" ] && [ "$F1" = "$F3" ] && ok || bad "F1 a plain rebase changed the fp: $F1 / $F3"
[[ "$F8" =~ ^v1-[0-9a-f]{64}$ ]] && [ "$F8" = "$F9" ] && ok || bad "F1 no-fragment rebase: '$F8' / '$F9'"
[ -n "$F4" ] && [ "$F4" != "$F2" ] && ok || bad "F2 one code line kept the fp: '$F4'"
[ -n "$F5" ] && [ "$F5" != "$F2" ] && ok || bad "F2 a trailing space kept the fp: '$F5'"
[ -n "$F6" ] && [ "$F6" != "$F2" ] && ok || bad "F2 a mode change kept the fp: '$F6'"
[ -n "$F7" ] && [ "$F7" != "$F2" ] && ok || bad "F2 a new fragment suffix kept the fp: '$F7'"
[ "$F8" != "$F1" ] && ok || bad "F2 two different patches share an fp"
( . "$SRC/bin/lib/patch-fp.sh" && patch_review_fp "$FPG" main "$M1" ) >/dev/null 2>&1 && bad "F2 an empty diff has an fp" || ok
( . "$SRC/bin/lib/patch-fp.sh" && patch_review_fp "$FPG" main "0000000000000000000000000000000000000000" ) >/dev/null 2>&1 && bad "F2 a missing commit has an fp" || ok
key() { ( . "$SRC/bin/lib/patch-fp.sh" && patch_ticket_key "$@" ); }
[ "$(key ticket/bh-77)" = BH-77 ] && ok || bad "K1 ticket/bh-77 -> '$(key ticket/bh-77)'"
[ "$(key ticket/bh-77-r2)" = BH-77 ] && ok || bad "K1 ticket/bh-77-r2 -> '$(key ticket/bh-77-r2)'"
[ "$(key ticket/BH-77-r3)" = BH-77 ] && ok || bad "K1 ticket/BH-77-r3 -> '$(key ticket/BH-77-r3)'"
[ "$(key ticket/ab2-9)" = AB2-9 ] && ok || bad "K1 ticket/ab2-9 (a digit in the prefix) -> '$(key ticket/ab2-9)'"
key ticket/bh-77-R2 "" >/dev/null && bad "K1 ticket/bh-77-R2 counted (the shared ticket_branch_key refuses it)" || ok
[ "$(key feature/x "BH-78: a title")" = BH-78 ] && ok || bad "K1 title key -> '$(key feature/x "BH-78: a title")'"
[ "$(key feature/x "fix(bh-79): a title")" = BH-79 ] && ok || bad "K1 type(key) title -> '$(key feature/x "fix(bh-79): a title")'"
key feature/x "Rest of BH-80" >/dev/null && bad "K1 a key inside a title counted" || ok
key ticket/bh-77-x "" >/dev/null && bad "K1 ticket/bh-77-x counted" || ok

# ── the e2e fixture ──
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" LEAD_REVIEW_MERGE_CARRY=0
for f in bin/lib/patch-fp.sh bin/lib/lead-gates.d/52-ticket-replay.sh bin/lib/review-saving.sh; do
  [ -r "$H/$f" ] || { echo "FAIL: the closure of bin/lead-review.sh did not install $f"; exit 1; }
done
lwf_main_merge
gc=(git -C "$W" -c user.email=t@t -c user.name=t)
"${gc[@]}" checkout -q -b rebased "$NEWMAIN"; "${gc[@]}" cherry-pick "$SHA" >/dev/null; H2=$("${gc[@]}" rev-parse HEAD)
"${gc[@]}" checkout -q -b more "$H2"; echo three >> "$W/a.txt"; "${gc[@]}" commit -qam "one more line"; H3=$("${gc[@]}" rev-parse HEAD)
refs=("$SHA:refs/pull/301/head" "$H3:refs/pull/310/head")
for n in 302 303 304 305 306 307 308 309 311 312 313; do refs+=("$H2:refs/pull/$n/head"); done
git -C "$W" push -q "$O" "${refs[@]}"
git -C "$T/repos/demo-os" fetch -q origin main "$SHA" "$H2" "$H3" 2>/dev/null
efp() { ( . "$SRC/bin/lib/patch-fp.sh" && patch_review_fp "$T/repos/demo-os" origin/main "$1" ); }
FPS=$(efp "$SHA"); FPH2=$(efp "$H2"); FPH3=$(efp "$H3")
[[ "$FPS" =~ ^v1- ]] && [ "$FPS" = "$FPH2" ] && [ "$FPH3" != "$FPS" ] && ok \
  || { bad "fixture fps: SHA=$FPS H2=$FPH2 H3=$FPH3"; }
S12=${SHA:0:12}; H212=${H2:0:12}

# The route fake. $FX/ltv/<sha256 of repo|key|fp>.json holds the row plus age_s;
# GET answers it only when age_s <= window_s, as the worker does.
LTV="$T/ltv"; mkdir -p "$LTV" "$T/ltvwrap"
cat > "$T/ltvwrap/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in https://jobs.test/api/lead-ticket-verdicts*) ;; *) exec "$T/fakebin/curl" "\$@" ;; esac
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
( flock 9; printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/ltv" ) 9>"$T/ltv.lock"
if [ -e "$FX/ltv.fail" ]; then printf '%s\n%s' '{"error":"fixture outage"}' 500; exit 0; fi
qv() { printf '%s' "\$p" | sed -n "s/.*[?&]\$1=\\([^&]*\\).*/\\1/p" | sed 's/%2F/\\//g; s/%2f/\\//g'; }
k() { printf '%s|%s|%s' "\${1,,}" "\${2^^}" "\$3" | sha256sum | cut -c1-16; }
if [ "\$m" = POST ]; then
  f="$LTV/\$(k "\$(jq -r .repo <<<"\$body")" "\$(jq -r .ticket_key <<<"\$body")" "\$(jq -r .patch_fp <<<"\$body")").json"
  jq -c '. + {age_s: 0}' <<<"\$body" > "\$f"
  printf '%s\n%s' '{"ok":true}' 200; exit 0
fi
f="$LTV/\$(k "\$(qv repo)" "\$(qv ticket_key)" "\$(qv patch_fp)").json"
w=\$(qv window_s)
if [ -r "\$f" ] && [ "\$(jq -r .age_s "\$f")" -le "\$w" ]; then printf '%s\n%s' "\$(jq -c '{row:.}' "\$f")" 200
else printf '%s\n%s' '{"row":null}' 200; fi
EOF
chmod +x "$T/ltvwrap/curl"
export PATH="$T/ltvwrap:$PATH"
# ltv_seed <ticket> <fp> <verdict> <pr> <head> <age_s>
ltv_seed() {
  local k
  k=$(printf '%s|%s|%s' example-org/demo-os "${1^^}" "$2" | sha256sum | cut -c1-16)
  jq -nc --arg t "${1^^}" --arg f "$2" --arg v "$3" --argjson p "$4" --arg h "$5" --argjson a "$6" \
    '{repo:"example-org/demo-os", ticket_key:$t, patch_fp:$f, pr:$p, head_sha:$h, verdict:$v, review_mode:"full", age_s:$a}' > "$LTV/$k.json"
}
djobs() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
vposts() { grep '^POST /api/verdicts ' "$T/log/worker" 2>/dev/null | sed 's/^POST \/api\/verdicts //'; }
nvposts() { lwf_cnt '^POST /api/verdicts ' "$T/log/worker"; }
ltvposts() { grep '^POST /api/lead-ticket-verdicts ' "$T/log/ltv" 2>/dev/null | sed 's/^POST \/api\/lead-ticket-verdicts //'; }
nltvget() { lwf_cnt '^GET /api/lead-ticket-verdicts' "$T/log/ltv"; }
# pset <pr> <head> <ref> [token] — one worklist PR, builder APPROVE on its head
ltv_clear() { scratch_rm "$LTV"; mkdir -p "$LTV"; }
pset() {
  lwf_reset; scratch_rm "$H/state/lead-review-enqueue"; rm -f "$T/log/ltv"
  lwf_needs_at example-org/demo-os "$2" "$1"; echo "$2" > "$FX/head.$1"; echo "$3" > "$FX/ref.$1"
  if [ "${4:-token}" = token ]; then printf 'tok-fixture-lead\n' > "$FX/lead-token"; chmod 600 "$FX/lead-token"; fi
}
# reviewed <case> <pr> — the review ran: one agent call, one job, no ticket replay line
reviewed() {
  [ "$(lwf_agents)" = 1 ] && ok || bad "$1 agent calls=$(lwf_agents) (want 1): $(grep "#$2 " "$L" | tail -5)"
  [ "$(djobs "$2")" = 1 ] && ok || bad "$1 jobs=$(djobs "$2") (want 1)"
  grep -q "example-org/demo-os#$2 @.*rebound: ticket-replay" "$L" && bad "$1 a ticket replay line: $(cat "$L")" || ok
}
# replayed <case> <pr> <head12> — 0 agent calls, one lead post on the head, no job
replayed() {
  [ "$(lwf_agents)" = 0 ] && ok || bad "$1 agent calls=$(lwf_agents) (want 0): $(cat "$L")"
  [ "$(djobs "$2")" = 0 ] && ok || bad "$1 jobs=$(djobs "$2") (want 0)"
  [ "$(nvposts)" = 1 ] && ok || bad "$1 verdict posts=$(nvposts) (want 1): $(vposts)"
  grep -q "example-org/demo-os#$2 @$3: lead MERGE from 301@$S12 (ticket BH-77); rebound: ticket-replay 301@$S12; no review" "$L" && ok \
    || bad "$1 no replay line: $(grep "#$2 " "$L")"
}

# ── T3: the first PR of the ticket is reviewed, and its MERGE is stored ──
pset 301 "$SHA" ticket/bh-77; lwf_tick
reviewed T3 301
[ "$(ltvposts | wc -l | tr -d ' ')" = 1 ] && ok || bad "T3 ticket verdict posts: '$(ltvposts)'"
ltvposts | jq -e --arg f "$FPS" --arg s "$SHA" \
  '.repo == "example-org/demo-os" and .ticket_key == "BH-77" and .patch_fp == $f and .pr == 301 and .head_sha == $s
   and .verdict == "MERGE" and .review_mode == "full" and (.request_id | length) > 0' >/dev/null 2>&1 && ok \
  || bad "T3 the stored row: '$(ltvposts)' (want fp $FPS)"

# ── T4 + T7: the second PR, same patch on a newer main, inside the window ──
pset 302 "$H2" ticket/bh-77-r2; lwf_tick
replayed T4 302 "$H212"
case "$(vposts | jq -r '[.verdict, .head_sha, .source, .note] | @tsv')" in
  "MERGE	$H2	lead	lead-replay:$S12 how:ticket-replay rebound: ticket-replay 301@$S12 ticket:BH-77") ok ;;
  *) bad "T4 the post: $(vposts)" ;;
esac
[ "$(lwf_cnt '^POST /api/jobs .*"ticket_id":"review-saving/lead-review/example-org/demo-os#302@' "$T/log/worker")" = 1 ] && ok \
  || bad "T4 review-saving job_open: $(grep 'review-saving' "$T/log/worker")"
[ "$(nltvget)" = 1 ] && grep -q "^GET /api/lead-ticket-verdicts?repo=example-org%2Fdemo-os&ticket_key=BH-77&patch_fp=$FPH2&window_s=86400 " "$T/log/ltv" && ok \
  || bad "T4 the route read: $(cat "$T/log/ltv")"
[ "$(ltvposts | wc -l | tr -d ' ')" = 0 ] && ok || bad "T4 a replay stored a ticket verdict: $(ltvposts)"
grep -q 'pr-attempts' "$T/log/worker" && bad "T7 a pr-attempts request on a hit: $(grep pr-attempts "$T/log/worker")" || ok
[ ! -e "$FX/attempts" ] && ok || bad "T7 the attempts file was written: $(cat "$FX/attempts")"

# ── T5: a stored BLOCK is not replayed ──
ltv_clear; ltv_seed BH-77 "$FPS" BLOCK 301 "$SHA" 10
pset 303 "$H2" ticket/bh-77-r3; lwf_tick
reviewed T5 303
grep -q "example-org/demo-os#303 @$H212: stored BLOCK from 301@$S12 (ticket BH-77) is not replayed; full review" "$L" && ok \
  || bad "T5 no BLOCK line: $(grep '#303 ' "$L")"

# ── T6: the window edge ──
ltv_clear; ltv_seed BH-77 "$FPS" MERGE 301 "$SHA" 86401
pset 304 "$H2" ticket/bh-77-r4; lwf_tick
reviewed "T6 (86401 s)" 304
grep -q "example-org/demo-os#304 @$H212: no stored lead word for ticket BH-77 at this fp inside 86400 s; full review" "$L" && ok \
  || bad "T6 no miss line: $(grep '#304 ' "$L")"
ltv_clear; ltv_seed BH-77 "$FPS" MERGE 301 "$SHA" 86399
pset 305 "$H2" ticket/bh-77-r5; lwf_tick
replayed "T6 (86399 s)" 305 "$H212"

# ── T8: the route answers 500 ──
ltv_clear; ltv_seed BH-77 "$FPS" MERGE 301 "$SHA" 10
pset 306 "$H2" ticket/bh-77-r6; : > "$FX/ltv.fail"; lwf_tick
reviewed T8 306
grep -q "example-org/demo-os#306 @$H212: ticket verdict read failed; full review" "$L" && ok || bad "T8 no read-failed line: $(grep '#306 ' "$L")"

# ── T9: another ticket key, the same fp ──
ltv_clear; ltv_seed BH-77 "$FPS" MERGE 301 "$SHA" 10
pset 307 "$H2" ticket/bh-78; lwf_tick
reviewed T9 307

# ── T10: the same ticket, one code line different ──
ltv_clear; ltv_seed BH-77 "$FPS" MERGE 301 "$SHA" 10
pset 310 "$H3" ticket/bh-77-r7; lwf_tick
reviewed T10 310

# ── T11: the switch off ──
ltv_clear; ltv_seed BH-77 "$FPS" MERGE 301 "$SHA" 10
pset 308 "$H2" ticket/bh-77-r8; LEAD_TICKET_REPLAY=0 lwf_tick
reviewed T11 308
[ "$(nltvget)" = 0 ] && ok || bad "T11 the route was read $(nltvget) time(s) with the switch off"

# ── T12: no lead token on the box ──
ltv_clear; ltv_seed BH-77 "$FPS" MERGE 301 "$SHA" 10
pset 309 "$H2" ticket/bh-77-r9 notoken; lwf_tick
reviewed T12 309
[ "$(nvposts)" = 0 ] && ok || bad "T12 posts=$(nvposts) with no token"

# ── T13: the verdict post fails ──
ltv_clear; ltv_seed BH-77 "$FPS" MERGE 301 "$SHA" 10
pset 311 "$H2" ticket/bh-77-r10; : > "$FX/verdictpost.fail"; lwf_tick
reviewed T13 311
grep -q "example-org/demo-os#311 @$H212: lead MERGE from 301@$S12 not recorded (post rc " "$L" && ok || bad "T13 no not-recorded line: $(grep '#311 ' "$L")"

# ── T14: a model BLOCK is stored too, over the stored MERGE ──
# The stored MERGE is PR 312's own (an earlier head), so gate 52 leaves the
# head to the review; the review's BLOCK replaces it, and PR 313 is reviewed.
ltv_clear; ltv_seed BH-77 "$FPS" MERGE 312 "$SHA" 10
cp "$H/bin/agent-call.sh" "$T/agent-call.merge"
sed -i 's/^printf .Findings.*$/printf "Findings\\n- [BLOCK wrong-data] fixture finding\\n\\nVERDICT: BLOCK\\n" > "$5"/' "$H/bin/agent-call.sh"
grep -q 'VERDICT: BLOCK' "$H/bin/agent-call.sh" || bad "T14 the BLOCK agent stub was not written"
pset 312 "$H2" ticket/bh-77-r11; lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "T14 agent calls=$(lwf_agents)"
ltvposts | jq -e --arg f "$FPH2" '.ticket_key == "BH-77" and .patch_fp == $f and .pr == 312 and .verdict == "BLOCK"' >/dev/null 2>&1 && ok \
  || bad "T14 the stored BLOCK: '$(ltvposts)' / $(grep '#312\|lr-312' "$L" | tail -3)"
cp "$T/agent-call.merge" "$H/bin/agent-call.sh"
# and the next PR of the ticket is reviewed, not replayed
pset 313 "$H2" ticket/bh-77-r12; lwf_tick
reviewed "T14 after the BLOCK" 313

# ── T15: the knob defaults ──
K="$SRC/catalog/lanes.d/_lib.lead-ticket-replay.json"
[ "$(jq -r '.libs[0].id' "$K")" = lead-ticket-replay ] && ok || bad "T15 lib id"
[ "$(jq -r '.libs[0].file' "$K")" = bin/lib/lead-gates.d/52-ticket-replay.sh ] && ok || bad "T15 lib file"
[ "$(jq -r '.libs[0].knobs[] | select(.env == "LEAD_TICKET_REPLAY") | .default' "$K")" = 1 ] && ok || bad "T15 LEAD_TICKET_REPLAY default"
[ "$(jq -r '.libs[0].knobs[] | select(.env == "LEAD_TICKET_REPLAY_WINDOW_S") | .default' "$K")" = 86400 ] && ok || bad "T15 window default"

echo "lead-ticket-replay.bh-9154: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
