#!/bin/bash
# tests/builder-carry-merge-only.bh-7043-test.sh — BH-7043: a PR head B that
# only took main in since the builder approved head A keeps the builder's
# APPROVE (bin/lib/builder-carry.sh), so the lead replay of BH-5294 fires on B
# with no model call; and a hub clone that cannot fetch `origin main <B>` in
# one call fetches B by sha or by the PR ref (bin/lib/patch-same.sh
# patch_same_fetch) before it gives up.
# Real git fixture repos over a bare origin, and a git shim on PATH that counts
# every fetch and, per $T/gitmode, refuses one fetch shape:
#   nocombined  `fetch origin main <sha>` fails (a held origin/main ref lock).
#   nosha       any fetch naming a bare sha fails (a server that refuses sha
#               wants; local git always serves a reachable sha, so only the
#               shim can make the PR-ref rung the one that works).
# The hub clone is `--single-branch -b main`, so it lacks A and every PR head.
#
#   patch_same_fetch (sourced from the repo)
#     F1  nocombined: rc 0, B resolves, origin/main resolves, the fallback ran.
#     F2  nosha, the head only at refs/pull/7/head: with PR number 7 rc 0;
#         without it rc 1.
#     F3  origin removed: rc 1, PS_FETCH_ERR non-empty. An https origin with
#         user:secret: rc 1, `secret` never in PS_FETCH_ERR; _ps_redact masks
#         `https://u:secret@host/x` as `https://***@host/x`.
#     F4  a second call in the same process for the same head: 0 fetches.
#   bc_carry (sourced from the repo)
#     B1  B = A + one clean main merge: rc 0, main-merge; two merges too;
#         B = A: identical.
#     B2  B = A rebased byte-identical onto a new main: rc 0, patch-id.
#     B3  rc 1 for each: one own line; a hand-resolved merge; a whitespace-only
#         .py change; a 644->755 mode change; an octopus merge; an A that is not
#         an ancestor with another patch. An A that no fetch can bring is rc 2.
#     B4  a repeat call in a new process answers from builder-carry.tsv with
#         0 fetches and the same HOW; rc 2 wrote no row.
#     B5  bc_prune drops a row 8 days old and keeps a row 1 day old.
#   bin/lead-review.sh tick (worklist gates 10 and 50,
#   tests/lib/lead-worklist-fixture.bh-4956.sh), CI NOT green on the head:
#     W1  builder APPROVE on $SHA, H1 = $SHA + main merge, lead MERGE on $SHA:
#         `builder APPROVE carried` from gate 10, one POST /api/verdicts (the
#         replay), 0 lead_review jobs.
#     W2  the same with a lead BLOCK on $SHA: no job, held=1, `CI not known
#         green`, no POST.
#     W3  the head is $SHA + one own line: no carry line, held=1.
#     W4  W1 with a human row on H1: `[skip verdict]`, no POST, no job.
#     W5  W1 with a truncated history: CI green = `verdicts read failed; full
#         review` and one job; CI not green = held=1, no job.
#   gates 10, 50 and 60 sourced in one shell, gate 10's globals set as gate
#   10 sets them for a carried head, risk tier low, mode enforce:
#     U1  a lead BLOCK on A, CI green: gate 50 rc 0; LGB_APPROVED=0,
#         LGB_CARRIED=0, LGB_REBOUND=0, LGB_REQFOR="CI green"; gate 60 makes no
#         risk-tier sign-off.
#     U2  a lead BLOCK on A, CI not green: rc 11; every gate 10 global reset.
#     U3  a truncated history, CI green: as U1.
#     U4  a carry that stands (no lead row): gate 60 makes no sign-off.
#     U5  control: an APPROVE bound to the head: gate 60 signs it off.
# tests/lead-gates-builder-carry.bh-8524-test.sh pins the rest of gate 10's
# carry on a whole tick: no second post over a replay row, the carried notes
# under LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1, and the redacted not-carried
# line when every fetch fails.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/builder-carry-merge-only.bh-7043-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/patch-same.sh; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
# Not an exit: without the lib each case below fails on its own (the red run).
[ -f "$SRC/bin/lib/builder-carry.sh" ] && ok || bad "bin/lib/builder-carry.sh does not exist"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_REVIEW_REQUIRE_BUILDER_APPROVE
ROOT_T="$T"

# ─────────────────────────── the fixture repo ───────────────────────────
OR="$T/origin/demo-os.git"; WK="$T/work"; mkdir -p "$T/origin" "$T/log"
g() { git -C "$WK" "$@"; }
git init -q -b main "$WK"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"; printf 'def f():\n    return 1\n' > "$WK/x.py"
printf '# demo\n\nNo contract here.\n' > "$WK/CLAUDE.md"
g add -A; g commit -qm base; BASE=$(g rev-parse HEAD)
g checkout -qb side "$BASE"; echo s > "$WK/s.txt"; g add s.txt; g commit -qm side
g checkout -qb pr "$BASE"; echo 'pr line' >> "$WK/f.txt"; g commit -qam "the pr"
A=$(g rev-parse HEAD); A12=${A:0:12}
g checkout -q main; echo m1 > "$WK/m1.txt"; g add m1.txt; g commit -qm "main moves"; M1=$(g rev-parse HEAD)
g branch -q m1 "$M1"
g checkout -qb b1 "$A"; g merge -q --no-edit m1; B1=$(g rev-parse HEAD); B112=${B1:0:12}
g checkout -q main; echo m2 > "$WK/m2.txt"; g add m2.txt; g commit -qm "main moves again"
g checkout -qb b2 "$B1"; g merge -q --no-edit main; B2=$(g rev-parse HEAD)
g checkout -qb reb "$M1"; g cherry-pick "$A" >/dev/null; BR=$(g rev-parse HEAD)
g checkout -qb own "$A"; echo 'own line' >> "$WK/f.txt"; g commit -qam "one own line"; BOWN=$(g rev-parse HEAD)
g checkout -qb hand "$A"; g merge -q --no-commit --no-ff m1 >/dev/null 2>&1; echo 'slipped in' >> "$WK/f.txt"
g add -A; g commit -qm "merge with a hand edit"; BHAND=$(g rev-parse HEAD)
g checkout -qb ws "$A"; printf 'def f():\n      return 1\n' > "$WK/x.py"; g commit -qam "indent"; BWS=$(g rev-parse HEAD)
g checkout -qb mode "$A"; chmod 755 "$WK/f.txt"; g -c core.fileMode=true commit -qam "mode"; BMODE=$(g rev-parse HEAD)
g checkout -qb oct "$A"; g merge -q --no-edit m1 side >/dev/null; BOCT=$(g rev-parse HEAD)
g checkout -qb na "$BASE"; echo 'another pr line' >> "$WK/f.txt"; g commit -qam "another patch"; BNA=$(g rev-parse HEAD)
g checkout -qb p7 "$A"; echo p7 > "$WK/p7.txt"; g add p7.txt; g commit -qm p7; P7=$(g rev-parse HEAD)
g checkout -q main
git clone -q --bare "$WK" "$OR"
git -C "$OR" update-ref refs/pull/7/head "$P7"; git -C "$OR" update-ref -d refs/heads/p7
git -C "$OR" update-ref refs/pull/41/head "$B1"
[ "$(git -C "$OR" rev-list --parents -n 1 "$BOCT" | wc -w)" = 4 ] && ok || bad "setup: the octopus merge has not 3 parents"

# The git shim: counts fetches, refuses the shape $T/gitmode names.
mkdir -p "$T/gitbin"; REALGIT=$(command -v git)
cat > "$T/gitbin/git" <<EOF
#!/bin/bash
f=0; m=0; s=0
for a in "\$@"; do
  case "\$a" in fetch) f=1 ;; main) m=1 ;; esac
  [[ "\$a" =~ ^[0-9a-f]{40}\$ ]] && s=1
done
if [ "\$f" = 1 ]; then
  printf '%s\n' "\$*" >> "\${GITLOG:-$T/log/fetches}"
  case "\$(cat "$T/gitmode" 2>/dev/null)" in
    nocombined) [ "\$m\$s" = 11 ] && { echo "error: cannot lock ref 'refs/remotes/origin/main': fixture" >&2; exit 1; } ;;
    nosha) [ "\$s" = 1 ] && { echo "fatal: remote error: upload-pack: not our ref (fixture)" >&2; exit 128; } ;;
  esac
fi
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/gitbin/git"
fresh() { scratch_rm "$1" || return 1; git clone -q --single-branch -b main "file://$OR" "$1"; }
nfetch() { [ -f "$T/log/fetches" ] && wc -l < "$T/log/fetches" | tr -d ' ' || echo 0; }

# ═══════════════════════ patch_same_fetch: F1-F4 ═══════════════════════
C="$T/clone"
# F1
fresh "$C"; echo nocombined > "$T/gitmode"; rm -f "$T/log/fetches"
OUT=$(PATH="$T/gitbin:$PATH"; . "$SRC/bin/lib/patch-same.sh"
  patch_same_fetch "$C" "$A" "$B1"; echo "rc=$?"
  git -C "$C" rev-parse -q --verify "$B1^{commit}" >/dev/null && echo head-ok
  git -C "$C" rev-parse -q --verify "origin/main^{commit}" >/dev/null && echo main-ok)
[[ "$OUT" == *rc=0*head-ok*main-ok* ]] && ok || bad "F1 nocombined: $OUT"
[ "$(nfetch)" -ge 2 ] && grep -q "fetch -q origin $B1\$" "$T/log/fetches" && ok || bad "F1 no by-sha fallback: $(cat "$T/log/fetches")"
# F2
fresh "$C"; echo nosha > "$T/gitmode"
OUT=$(PATH="$T/gitbin:$PATH"; . "$SRC/bin/lib/patch-same.sh"; patch_same_fetch "$C" "$A" "$P7"; echo "rc=$?")
[ "$OUT" = rc=1 ] && ok || bad "F2 without a PR number: $OUT (want rc=1)"
fresh "$C"
OUT=$(PATH="$T/gitbin:$PATH"; . "$SRC/bin/lib/patch-same.sh"; patch_same_fetch "$C" "$A" "$P7" 7; echo "rc=$?"
  git -C "$C" rev-parse -q --verify "$P7^{commit}" >/dev/null && echo head-ok)
[ "$OUT" = "rc=0"$'\n'"head-ok" ] && ok || bad "F2 with PR number 7: $OUT"
# F3
rm -f "$T/gitmode"; fresh "$C"; git -C "$C" remote set-url origin "$T/no-such-origin.git"
OUT=$(. "$SRC/bin/lib/patch-same.sh"; patch_same_fetch "$C" "$A" "$B1" 41; echo "rc=$? err=${PS_FETCH_ERR:-}")
[[ "$OUT" == "rc=1 err="?* ]] && ok || bad "F3 a removed origin: $OUT"
git -C "$C" remote set-url origin "https://u:secret@127.0.0.1:9/x"
OUT=$(. "$SRC/bin/lib/patch-same.sh"; patch_same_fetch "$C" "$A" "$B1"; echo "rc=$? err=${PS_FETCH_ERR:-}")
[[ "$OUT" == "rc=1 err="?* ]] && [[ "$OUT" != *secret* ]] && ok || bad "F3 an https origin with credentials: $OUT"
OUT=$(. "$SRC/bin/lib/patch-same.sh"; printf "fatal: unable to access 'https://u:secret@host/x/'\nline two\n" | _ps_redact)
[ "$OUT" = "fatal: unable to access 'https://***@host/x/'" ] && ok || bad "F3 _ps_redact: '$OUT'"
# F4
fresh "$C"; rm -f "$T/gitmode" "$T/log/fetches"
OUT=$(PATH="$T/gitbin:$PATH"; . "$SRC/bin/lib/patch-same.sh"
  patch_same_fetch "$C" "$A" "$B1" 41; a=$?; n1=$(wc -l < "$T/log/fetches")
  patch_same_fetch "$C" "$A" "$B1" 41; b=$?; n2=$(wc -l < "$T/log/fetches"); echo "$a $b $((n2 - n1))")
[ "$OUT" = "0 0 0" ] && ok || bad "F4 the second call fetched: '$OUT' (want '0 0 0')"

# ═══════════════════════════ bc_carry: B1-B5 ═══════════════════════════
ST="$T/bcstate"
# bcx <head> [approved] — one bc_carry in a fresh process on a fresh clone: "<rc> <how|why>"
bcx() {
  fresh "$C"
  ( PATH="$T/gitbin:$PATH"; . "$SRC/bin/lib/patch-same.sh"; . "$SRC/bin/lib/builder-carry.sh"
    rc=0; bc_carry "$C" example-org/demo-os 41 "${2:-$A}" "$1" "$ST" || rc=$?
    echo "$rc ${BC_HOW:-${BC_WHY:-}}" )
}
rm -f "$T/gitmode"; scratch_rm "$ST"
[ "$(bcx "$B1")" = "0 main-merge" ] && ok || bad "B1 one clean main merge: $(bcx "$B1")"
[ "$(bcx "$B2")" = "0 main-merge" ] && ok || bad "B1 two clean main merges: $(bcx "$B2")"
[ "$(bcx "$A")" = "0 identical" ] && ok || bad "B1 the same head: $(bcx "$A")"
[ "$(bcx "$BR")" = "0 patch-id" ] && ok || bad "B2 a byte-identical rebase: $(bcx "$BR")"
for c in "own:$BOWN" "hand:$BHAND" "ws:$BWS" "mode:$BMODE" "octopus:$BOCT" "not-an-ancestor:$BNA"; do
  [ "$(bcx "${c#*:}")" = "1 patch changed since $A12" ] && ok || bad "B3 ${c%%:*} was not refused: $(bcx "${c#*:}")"
done
NOSUCH=$(printf 'ab%.0s' $(seq 1 20))
OUT=$(bcx "$B1" "$NOSUCH")
[[ "$OUT" == "2 fetch of ${NOSUCH:0:12}/$B112 failed ("* ]] && ok || bad "B3 an A no fetch brings: $OUT (want rc 2)"
grep -q "$NOSUCH" "$ST/builder-carry.tsv" 2>/dev/null && bad "B4 an undecided answer was cached" || ok
[ "$(awk -F'\t' -v h="$B1" '$5 == h && $6 == "carried main-merge"' "$ST/builder-carry.tsv" | wc -l | tr -d ' ')" = 1 ] && ok \
  || bad "B4 builder-carry.tsv: $(cat "$ST/builder-carry.tsv")"
[ "$(awk -F'\t' -v h="$BOWN" '$5 == h && $6 == "refused"' "$ST/builder-carry.tsv" | wc -l | tr -d ' ')" = 1 ] && ok \
  || bad "B4 no refused row for the own-line head: $(cat "$ST/builder-carry.tsv")"
# B4: a new process, a new clone, answered from the cache with no fetch
fresh "$C"; rm -f "$T/log/fetches"
OUT=$(PATH="$T/gitbin:$PATH"; . "$SRC/bin/lib/patch-same.sh"; . "$SRC/bin/lib/builder-carry.sh"
  bc_carry "$C" example-org/demo-os 41 "$A" "$B1" "$ST"; echo "$? ${BC_HOW:-}")
[ "$OUT" = "0 main-merge" ] && [ "$(nfetch)" = 0 ] && ok || bad "B4 the cached answer: '$OUT', fetches $(nfetch)"
# B5
NOW=$(date +%s)
printf '%s\texample-org/demo-os\t9\t%s\t%s\trefused\n%s\texample-org/demo-os\t8\t%s\t%s\trefused\n' \
  $((NOW - 8 * 86400)) "$A" "$BNA" $((NOW - 86400)) "$A" "$BWS" >> "$ST/builder-carry.tsv"
( . "$SRC/bin/lib/builder-carry.sh"; bc_prune "$ST" )
[ "$(awk -F'\t' '$3 == 9' "$ST/builder-carry.tsv" | wc -l | tr -d ' ')" = 0 ] && ok || bad "B5 the 8-day-old row was kept"
awk -F'\t' '$3 == 8' "$ST/builder-carry.tsv" | grep -q . && ok || bad "B5 the 1-day-old row was dropped"
[ "$(awk -F'\t' -v h="$B1" '$5 == h' "$ST/builder-carry.tsv" | wc -l | tr -d ' ')" = 1 ] && ok || bad "B5 a fresh row was dropped"

# ════════════ bin/lead-review.sh tick: worklist gates 10 and 50 ════════════
T="$ROOT_T/disp"; mkdir -p "$T"
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
lwf_main_merge
SG=${SHA:0:12}
gc=(git -C "$W" -c user.email=t@t -c user.name=t)
"${gc[@]}" checkout -q -b own7043 "$SHA"; echo three >> "$W/a.txt"; "${gc[@]}" commit -qam "own line"; H3=$("${gc[@]}" rev-parse HEAD)
git -C "$W" push -q "$O" "$H3:refs/pull/203/head"
djobs() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
nvposts() { lwf_cnt '^POST /api/verdicts ' "$T/log/worker"; }
# wset <pr> <head> <lead word on $SHA> — one needs-review row, builder APPROVE on $SHA, CI not green
wset() {
  lwf_reset; scratch_rm "$H/state/lead-review-enqueue"
  lwf_needs_at example-org/demo-os "$2" "$1"; echo "$2" > "$FX/head.$1"
  lwf_bv "$1" APPROVE "$SHA"
  printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "Tests"\n' > "$FX/mergify.yml"
  jq -nc --arg g "$SHA" --arg w "$3" --argjson n "$1" \
    '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:$n, head_sha:$g, verdict:$w, note:"report:state/lead-reviews/x.md"}], truncated:false}' > "$FX/verdicts.json"
  printf 'tok-fixture-lead\n' > "$FX/lead-token"; chmod 600 "$FX/lead-token"
}

# ── W1: the carried APPROVE lets gate 50 replay the lead MERGE ──
wset 201 "$H1" MERGE; lwf_tick
grep -q "example-org/demo-os#201 @${H1:0:12}: builder APPROVE carried from $SG (how:main-merge)" "$L" && ok || bad "W1 no carried line: $(cat "$L")"
[ "$(nvposts)" = 1 ] && grep '^POST /api/verdicts ' "$T/log/worker" | grep -q "lead-replay:$SG how:main-merge" && ok || bad "W1 POST /api/verdicts=$(nvposts): $(cat "$L")"
[ "$(djobs 201)" = 0 ] && [ "$(lwf_agents)" = 0 ] && ok || bad "W1 jobs=$(djobs 201) agents=$(lwf_agents)"
grep -q '"source":"box"' "$T/log/worker" && bad "W1 a box verdict write" || ok

# ── W2: a lead BLOCK on $SHA: the carry does not stand, CI not green: held ──
wset 201 "$H1" BLOCK; lwf_tick
[ "$(djobs 201)" = 0 ] && [ "$(nvposts)" = 0 ] && ok || bad "W2 jobs=$(djobs 201) posts=$(nvposts)"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "W2 summary: $(lwf_summary)"
grep -q "example-org/demo-os#201 @${H1:0:12}: builder APPROVE on $SG not carried: the newest lead verdict on another head is a BLOCK" "$L" && ok || bad "W2 no not-carried line: $(cat "$L")"
grep -q "example-org/demo-os#201 @${H1:0:12}: no builder APPROVE on this head and CI not known green" "$L" && ok || bad "W2 no CI line: $(cat "$L")"

# ── W3: one own line: no carry, held as before ──
wset 203 "$H3" MERGE; lwf_tick
grep -q 'builder APPROVE carried' "$L" && bad "W3 a carried line: $(grep carried "$L")" || ok
[ "$(djobs 203)" = 0 ] && [ "$(nvposts)" = 0 ] && [[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "W3 jobs=$(djobs 203) posts=$(nvposts) summary: $(lwf_summary) log: $(cat "$L")"

# ── W4: a human row on the carried head: skipped, never replayed over ──
wset 201 "$H1" MERGE
jq --arg h "$H1" '.rows += [{id:8, source:"human", repo:"example-org/demo-os", pr:201, head_sha:$h, verdict:"MERGE", note:""}]' "$FX/verdicts.json" > "$FX/v.tmp" && mv "$FX/v.tmp" "$FX/verdicts.json"
lwf_tick
[ "$(djobs 201)" = 0 ] && [ "$(nvposts)" = 0 ] && ok || bad "W4 jobs=$(djobs 201) posts=$(nvposts) (want 0 0)"
[ "$(lwf_cnt "\[skip verdict\] example-org/demo-os#201 @${H1:0:12} " "$L")" = 1 ] && ok || bad "W4 no [skip verdict]: $(cat "$L")"

# ── W5: a truncated history on the carried head: gate 10's CI rule decides ──
wset 201 "$H1" MERGE; jq '.truncated = true' "$FX/verdicts.json" > "$FX/v.tmp" && mv "$FX/v.tmp" "$FX/verdicts.json"
lwf_ci_green "$H1"; lwf_tick
[ "$(nvposts)" = 0 ] && [ "$(djobs 201)" = 1 ] && ok || bad "W5 CI green: posts=$(nvposts) jobs=$(djobs 201) (want 0 1)"
grep -q "example-org/demo-os#201 @${H1:0:12}: verdicts read failed; full review" "$L" && ok || bad "W5 CI green: no read-failed line: $(cat "$L")"
wset 201 "$H1" MERGE; jq '.truncated = true' "$FX/verdicts.json" > "$FX/v.tmp" && mv "$FX/v.tmp" "$FX/verdicts.json"
lwf_tick
[ "$(nvposts)" = 0 ] && [ "$(djobs 201)" = 0 ] && [[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "W5 CI not green: posts=$(nvposts) jobs=$(djobs 201) summary: $(lwf_summary)"
grep -q "builder APPROVE on $SG not carried: the verdict history is unreadable" "$L" && ok || bad "W5 no not-carried line: $(cat "$L")"

# ════════════ gates 10, 50, 60 in one shell: the globals after an uncarry ════════════
U="$ROOT_T/unit"; mkdir -p "$U/h/bin" "$U/h/state/lead-review-enqueue" "$U/s"
printf '%s\n' "cromford o/r https://bh.test /api/board 1 box-u" > "$U/h/fleet.conf"
cat > "$U/h/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$U/lv"
EOF
chmod +x "$U/h/bin/lead-verdict.sh"
UA=$(printf '%040d' 701); UB=$(printf '%040d' 702)
# ucase <history json|truncated|fail> <ci rc> <approved> <carried> — prints
#   `<gate 50 rc> <LGB_APPROVED> <LGB_CARRIED> <LGB_REBOUND> <LGB_REQFOR>`; the
#   gate 60 lead-verdict calls go to $U/lv.
ucase() {
  rm -f "$U/lv" "$U/log"; printf '%s\n' "$1" > "$U/hist"
  printf '%s\to/r\t5\t%s\tlow\tdocs only\t\n' "$(date +%s)" "$UB" > "$U/h/state/lead-review-enqueue/risk.tsv"
  ( set +u
    export HARNESS="$U/h" FLEET_CONF="$U/h/fleet.conf" REPOS_ROOT="$U/repos"
    . "$SRC/bin/lib/lead-gates.d/10-builder.sh"
    . "$SRC/bin/lib/lead-gates.d/50-replay-delta.sh"
    . "$SRC/bin/lib/lead-gates.d/60-risk.sh"
    _lgt_log() { printf '%s\n' "$*" >> "$U/log"; }
    lgs_dir() { printf '%s\n' "$U/s"; }
    _jobs_req() {
      case "$(cat "$U/hist")" in
        fail) return 1 ;;
        truncated) printf '{"rows":[],"truncated":true}\n' ;;
        *) cat "$U/hist" ;;
      esac
    }
    _lgb_ci_green() { _LGB_WHY="fixture ci"; return "$UCI"; }
    UCI="$2"
    gh_rest() { printf '{"user":{"login":"cromford[bot]"}}\n'; }
    _lgr_lead_skip() { _LGR_RLEAD=""; _LGR_RLAUTH=0; }
    _lgrt_tokens() { :; }
    rt_rules_low() { return 1; }
    local_box_name() { printf 'box-u\n'; }
    ss_note() { :; }
    _LGR_TICKED=1; _lgr_mode[o/r]=enforce; _lgr_jmode[o/r]=off; _lgr_jmax[o/r]=0; _lgr_jt[o/r]=30
    LGB_KEY="o/r#5@$UB"; LGB_RSHA="$UA"; LGB_APPROVED="$3"; LGB_CARRIED="$4"; LGB_REBOUND=0; LGB_STEPDONE=0
    LGB_REQFOR=""; [ "$4" = 1 ] && LGB_REQFOR="builder APPROVE carried from ${UA:0:12} (how:main-merge)"
    rc=0; lg_gate_replay_delta o/r 5 "$UB" || rc=$?
    printf '%s %s %s %s %s\n' "$rc" "$LGB_APPROVED" "$LGB_CARRIED" "$LGB_REBOUND" "$LGB_REQFOR"
    [ "$rc" = 0 ] && { lg_gate_risk o/r 5 "$UB" >/dev/null 2>&1 || true; }
  )
}
lvn() { [ -f "$U/lv" ] && wc -l < "$U/lv" | tr -d ' ' || echo 0; }
UBLOCK=$(jq -nc --arg g "$UA" '{rows:[{id:7, source:"lead", repo:"o/r", pr:5, head_sha:$g, verdict:"BLOCK", note:""}], truncated:false}')

# ── U1: a lead BLOCK on A, CI green: unapproved, every global reset, no sign-off ──
out=$(ucase "$UBLOCK" 0 1 1)
[ "$out" = "0 0 0 0 CI green" ] && ok || bad "U1 gate 50 rc and globals: '$out' (want '0 0 0 0 CI green') log: $(cat "$U/log" 2>/dev/null)"
[ "$(lvn)" = 0 ] && ok || bad "U1 gate 60 signed off a head whose carry did not stand: $(cat "$U/lv")"
grep -q "o/r#5 @${UB:0:12}: risk tier low, but no reviewer approved this head (CI green)" "$U/log" && ok || bad "U1 no unapproved line: $(cat "$U/log" 2>/dev/null)"

# ── U2: a lead BLOCK on A, CI not green: held, every global reset ──
out=$(ucase "$UBLOCK" 1 1 1)
[ "$out" = "11 0 0 0 " ] && ok || bad "U2 gate 50 rc and globals: '$out' (want '11 0 0 0 ')"
[ "$(lvn)" = 0 ] && ok || bad "U2 a sign-off: $(cat "$U/lv")"

# ── U3: a truncated history, CI green: as U1 ──
out=$(ucase truncated 0 1 1)
[ "$out" = "0 0 0 0 CI green" ] && ok || bad "U3 gate 50 rc and globals: '$out' (want '0 0 0 0 CI green') log: $(cat "$U/log" 2>/dev/null)"
[ "$(lvn)" = 0 ] && ok || bad "U3 gate 60 signed off a head whose carry did not stand: $(cat "$U/lv")"

# ── U4: a carry that stands, no lead row: gate 60 still makes no sign-off ──
out=$(ucase '{"rows":[],"truncated":false}' 0 1 1)
[ "$out" = "0 1 1 0 builder APPROVE carried from ${UA:0:12} (how:main-merge)" ] && ok || bad "U4 globals: '$out'"
[ "$(lvn)" = 0 ] && ok || bad "U4 gate 60 signed off a carried head: $(cat "$U/lv")"

# ── U5: control: an APPROVE bound to the head is signed off ──
out=$(ucase '{"rows":[],"truncated":false}' 0 1 0)
[ "$out" = "0 1 0 0 " ] && ok || bad "U5 globals: '$out'"
[ "$(lvn)" = 1 ] && grep -q "^post o/r 5 $UB MERGE --source risk-tier --reviewer risk-tier:box-u " "$U/lv" && ok || bad "U5 no sign-off: lv=$(cat "$U/lv" 2>/dev/null) log=$(cat "$U/log" 2>/dev/null)"

echo "builder-carry-merge-only.bh-7043: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
