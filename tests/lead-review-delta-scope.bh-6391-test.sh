#!/bin/bash
# tests/lead-review-delta-scope.bh-6391-test.sh — BH-6391: a lead re-review
# carries the earlier review and the delta since it, a finding on a line that did
# not change since an approved head is a NOTE, and the land lane logs a verdict
# flip with no own commit. bin/lib/lead-prev.sh, and three production entry
# points run WHOLE against scratch harnesses (scratch_install_closure), with real
# git fixture repos and stubs for curl (the jobs worker), gh, bin/lead-verdict.sh
# (enqueue only) and bin/agent-call.sh (it writes the case's answer file).
#
# Fixture: base f.txt (20 lines), p.txt (10 lines), o.txt. G (the PR) appends to
# f.txt and edits p.txt line 5. main then changes f.txt line 1 and o.txt.
# HM = G + a merge of main. HO = HM + one own commit on p.txt line 3. HDL = HO +
# one own commit that deletes p.txt line 9. HBIN = HO + a new binary file. HX =
# HO + one own commit on bin/x.sh line 12 (bin/x.sh is in base). GX is a commit
# no remote holds.
#   lib (sourced in a subshell)
#     U1  lpv_note (G, HO) -> lpv_fit 4000 -> lpv_parse round trip
#     U2  lpv_fit on 30 own files: the list becomes +30, G and word survive
#     U3  lpv_delta_files (G, HM): commits 0, no own file, main f.txt only
#     U4  lpv_downgrade: an unchanged range is a NOTE, a range over a changed
#         line stays, a line beside a pure deletion stays, a binary file stays
#     U5  lpv_parse refuses a 12-char G and an unknown word
#     U6  lpv_flip: the six D4 inputs as pure calls
#     U7  lpv_downgrade (G, HX): a path that is not a file at H (x.sh:12,
#         ./bin/x.sh:12, bin/nope.sh:3) stays BLOCK, bin/x.sh:12 stays,
#         bin/x.sh:3 is a NOTE; own-cause: bin/x.sh (an own file) stays,
#         own-cause: o.txt and own-cause with no own-files file are NOTEs
#   bin/lead-review-enqueue.sh tick
#     D1a lead MERGE on G, builder APPROVE on HO: the request carries
#         lead-prev:G word:MERGE report:... own-commits:1 own-files:p.txt
#         main-files:f.txt, and the log names the re-review
#     D1b LEAD_DELTA_REVIEW_MAX_LINES=0 (full): no lead-delta:, the same group
#     D1c the earlier head GX is on no remote: the group carries ? lists
#     D1d a newer lead-replay: row on HM: lead-prev still names G
#     D1e lead BLOCK on G, builder gate off: word:BLOCK
#   bin/lead-review.sh tick (the notes are the ones D1a-D1c posted)
#     D2a BLOCK on f.txt:5 (unchanged since G) -> MERGE-WITH-NOTES, NOTE tag,
#         the re-review header line, one agent call
#     D2b BLOCK on p.txt:3 (own change) -> BLOCK, no re-review line
#     D2c [BLOCK needs-human] f.txt:5 -> BLOCK
#     D2d a BLOCK with no path:line -> BLOCK
#     D2e the D2a answer with word:BLOCK in the token -> BLOCK
#     D2f GX not in the reviewer's clone -> BLOCK, logged
#     D3a main-cause: f.txt (a main file of the delta) -> BLOCK
#     D3b f.txt:1 on HM (main changed it) -> BLOCK
#     D3c main-cause: o.txt (not a main file of the delta) -> MERGE-WITH-NOTES
#     D3d own-cause: p.txt (an own file of the delta) on f.txt:5 -> BLOCK
#     D3e own-cause: f.txt (not an own file of the delta) -> MERGE-WITH-NOTES
#     P1  the prompt's ## Re-review section sits after ## Rules pack and before
#         ## Host suite, names G, its word, the own commit, the files and G's
#         report, and the prompt rules carry main-cause:, own-cause: and
#         missed-because:
#   bin/lead-review-land.sh
#     D4a word MERGE, verdict BLOCK, own-commits:0: one flip line, the post and
#         the stamp still happen; a second tick logs no second line
#     D4b word BLOCK, verdict MERGE: one flip line
#     D4c MERGE -> MERGE-WITH-NOTES: none   D4d own-commits:1: none
#     D4e own-commits:?: none                D4f no lead-prev group: none
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-delta-scope.bh-6391-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# BH-7123: this suite pins the re-review scope mechanics (lpv_downgrade) with
# classless fixture findings and a `[BLOCK needs-human] f.txt:5` that is not a
# go-live step. The review level cap (bin/lib/review-level.sh) would read that
# human ask as a verification note; it has its own suite
# (tests/review-level-cap.bh-7123-test.sh), so here it is inert.
export REVIEW_LEVEL_MODE=strict
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_DELTA_PROTECTED_MAX_LINES AGENT_CALL_FP AGENT_CALL_GUARD_STAGE

# ───────────────────────────── the fixture repo ─────────────────────────────
OR="$T/origin/demo-os.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"; seq 1 10 | sed 's/^/p line /' > "$WK/p.txt"; printf 'other\n' > "$WK/o.txt"
printf '# demo\n\nNo contract here.\n' > "$WK/CLAUDE.md"
mkdir -p "$WK/bin"; seq 1 20 | sed 's/^/x line /' > "$WK/bin/x.sh"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb gone; echo 'never pushed' >> "$WK/o.txt"; git -C "$WK" commit -qam "a head no remote holds"
GX=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -q main; git -C "$WK" checkout -qb pr
echo 'pr line' >> "$WK/f.txt"; sed -i 's/^p line 5$/p line 5 by the pr/' "$WK/p.txt"; git -C "$WK" commit -qam "the pr"
G=$(git -C "$WK" rev-parse HEAD); G12=${G:0:12}
git -C "$WK" checkout -q main; sed -i 's/^base line 1$/main line 1/' "$WK/f.txt"; echo 'main moved' >> "$WK/o.txt"; git -C "$WK" commit -qam "main moves"
git -C "$WK" checkout -q pr; git -C "$WK" merge -q --no-edit main; HM=$(git -C "$WK" rev-parse HEAD)
sed -i 's/^p line 3$/p line 3 fixed/' "$WK/p.txt"; git -C "$WK" commit -qam "fix p three"; HO=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb del; sed -i '/^p line 9$/d' "$WK/p.txt"; git -C "$WK" commit -qam "drop p nine"; HDL=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb binf "$HO"; printf 'bin\000ary\n' > "$WK/img.bin"; git -C "$WK" add img.bin; git -C "$WK" commit -qm "add a binary"
HBIN=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb subx "$HO"; sed -i 's/^x line 12$/x line 12 renamed/' "$WK/bin/x.sh"; git -C "$WK" commit -qam "rename in x"
HX=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main pr del binf subx
git -C "$WK" push -q "$OR" "$HO:refs/pull/41/head"
git -C "$OR" cat-file -e "$GX^{commit}" 2>/dev/null && { echo "FAIL: setup: GX reached the origin"; exit 1; }

# ═══════════════════════ part 1: bin/lead-review-enqueue.sh ═══════════════════
Q="$T/hq"; mkdir -p "$Q/bin/lib/jobs" "$Q/state" "$Q/logs" "$Q/catalog/lanes.d" "$T/cfg" "$T/qrepos" "$T/log" "$T/qbin"
cat > "$Q/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/post"
exit 0
EOF
cat > "$Q/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/qalerts"
EOF
cat > "$Q/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"
exit 1
EOF
chmod +x "$Q/bin/lead-verdict.sh" "$Q/bin/lane-alert.sh" "$Q/bin/agent-call.sh"
scratch_install_closure bin/lead-review-enqueue.sh "$Q" >/dev/null || bad "closure of bin/lead-review-enqueue.sh"
scratch_install_closure bin/jobs-client.sh "$Q" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$Q/catalog/lanes.d/"
cp "$SRC/catalog/lead-protected-paths.seed.tsv" "$Q/catalog/"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$Q/fleet.conf"
git clone -q "$OR" "$T/qrepos/demo-os"

# BH-4148: the lead reads protected paths from the jobs route. demo-os has no
# rows, so it is not governed, as it was under the old catalog file.
. "$SRC/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$T/lpp.json" example-org/demo-os
mkdir -p "$T/qbin"; lpp_install "$T/qbin" "$T/lpp.json" "$T/lpp-down"
cat > "$T/qbin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
case "\$url" in *"/api/lead-protected-paths"*) "\$(dirname "\$0")/lpp-answer" "\$m" "\$url"; exit 0 ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/qworker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*standing_only=1*)
    h=\$(printf '%s' "\$p" | tr '&?' '\n\n' | sed -n 's/^head_sha=//p')
    out=\$(jq -c --arg h "\$h" '{standing:([.rows[] | select(.head_sha == \$h and (.source == "lead" or .source == "human"))] | last // null),
      rows:[], truncated:false}' "$T/vrows.json") ;;
  "GET /api/verdicts?"*) out=\$(cat "$T/vrows.json") ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else code=201; out=\$(jq -c '{request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body"); fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/qbin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$(cat "$T/qhead")" '[{number:41, html_url:"https://github.com/example-org/demo-os/pull/41", title:"t", draft:false, state:"open",
      user:{login:"operator",type:"User"}, head:{sha:\$h,ref:"ticket/bh-41"}, base:{ref:"main"}}]' ;;
  *"-X GET repos/example-org/demo-os/pulls/41"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/qhead")" '{head:{sha:\$s},base:{ref:"main"},user:{login:"operator"}}' ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: the thing"}}],"files":[]}\n' ;;
esac
exit 0
EOF
chmod +x "$T/qbin/curl" "$T/qbin/gh"

QLOG="$Q/logs/lead-review-enqueue.log"
# reset <head> <builder-approved sha> <lead word> [<earlier head>] — one lead row on the earlier head (default G)
reset() {
  rm -f "$T/log"/q* "$T/log/post" "$QLOG"
  scratch_rm "$Q/state"; mkdir -p "$Q/state"; echo box-hub > "$Q/state/box-name"
  scratch_rm "$T/jv"; mkdir -p "$T/jv"
  echo "$1" > "$T/qhead"
  jq -nc --arg s "$2" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  jq -nc --arg g "${4:-$G}" --arg w "$3" '{rows:[{id:4,repo:"example-org/demo-os",pr:41,head_sha:$g,source:"box",verdict:"APPROVE",note:""},
    {id:5,repo:"example-org/demo-os",pr:41,head_sha:$g,source:"lead",verdict:$w,note:"lead-review:lr-3"}],truncated:false}' > "$T/vrows.json"
}
tick() {
  ( cd "$T" && PATH="$T/qbin:$PATH" HARNESS="$Q" REPOS_ROOT="$T/qrepos" FLEET_CONF="$Q/fleet.conf" \
      LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 JOBS_URL=https://jobs.test \
      HARNESS_SECRET=test-secret JOBS_RETRIES=0 GH_ETAG=0 \
      bash "$Q/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?
}
reqs() { grep -c '^POST /api/lead-reviews ' "$T/log/qworker" 2>/dev/null || true; }
notes() { grep '^POST /api/lead-reviews ' "$T/log/qworker" 2>/dev/null | head -1 | sed 's/^POST \/api\/lead-reviews //; s/ lead=[01]$//' | jq -r .scope_notes 2>/dev/null; }
PREVG="lead-prev:$G word:MERGE report:state/lead-reviews/lr-41-$G12.md"

# ═══════════════════════════ lib unit cases U1-U6 ═══════════════════════════
LIB="$Q/bin/lib/lead-prev.sh"
QR="$T/qrepos/demo-os"
git -C "$QR" fetch -q origin main pr del binf

# ── U1: note -> fit -> parse round trip ──
U1=$( HARNESS="$Q"; . "$LIB" || exit 9
  n=$(lpv_note "$QR" origin/main "$G" MERGE "$HO" 41) || exit 8
  n=$(lpv_fit "auto: x; $n" 4000)
  lpv_parse "$n" || exit 7
  printf '%s|%s|%s|%s|%s|%s' "$LPV_PREV" "$LPV_WORD" "$LPV_REPORT" "$LPV_OWNC" "$LPV_OWN" "$LPV_MAIN" ) || true
[ "$U1" = "$G|MERGE|state/lead-reviews/lr-41-$G12.md|1|p.txt|f.txt" ] && ok || bad "U1 round trip: '$U1'"
NOTE_HM=$( HARNESS="$Q"; . "$LIB" && lpv_note "$QR" origin/main "$G" MERGE "$HM" 41 ) || true
[ "$NOTE_HM" = "$PREVG own-commits:0 own-files:- main-files:f.txt" ] && ok || bad "U1 the HM group: '$NOTE_HM'"

# ── U2: lpv_fit turns a long list into its count, never cuts G or the word ──
U2=$( HARNESS="$Q"; . "$LIB" || exit 9
  l=$(seq 1 30 | sed 's#^#some/long/dir/file-#; s#$#.txt#' | paste -sd,)
  n="$PREVG own-commits:3 own-files:$l main-files:f.txt"
  f=$(lpv_fit "$n" 160)
  [ "${#f}" -le 160 ] || exit 6
  lpv_parse "$f" || exit 5
  printf '%s|%s|%s|%s' "$LPV_PREV" "$LPV_WORD" "$LPV_OWN" "$LPV_MAIN"
  f2=$(lpv_fit "$n" 4000); [ "$f2" = "$n" ] || exit 4 ); U2RC=$?
[ "$U2RC" = 0 ] && [ "$U2" = "$G|MERGE|+30|f.txt" ] && ok || bad "U2 fit: rc $U2RC '$U2'"

# ── U3: a head that only merged main ──
U3=$( HARNESS="$Q"; . "$LIB" && lpv_delta_files "$QR" origin/main "$G" "$HM" | paste -sd'|' ) || true
[ "$U3" = "commits	0|main	f.txt" ] && ok || bad "U3 delta files: '$U3'"
U3B=$( HARNESS="$Q"; . "$LIB" && lpv_delta_files "$QR" origin/main "$GX" "$HO"; echo "rc=$?" ) || true
[ "$U3B" = "rc=1" ] && ok || bad "U3 an unknown G: '$U3B'"

# ── U4: the NOTE pass on its own ──
printf 'f.txt\n' > "$T/mainf"
u4() { # <G> <H> <answer> -> "<rc>|<k>|<file>"
  printf '%b' "$3" > "$T/u4.md"
  ( HARNESS="$Q"; . "$LIB" || exit 9; k=$(lpv_downgrade "$QR" "$1" "$2" "$T/u4.md" "$T/mainf"); r=$?; printf '%s|%s|' "$r" "$k"; cat "$T/u4.md" )
}
U4=$(u4 "$G" "$HO" 'Findings\n- [BLOCK] `f.txt:5-8`: old range\n\nVERDICT: BLOCK\n')
[ "$U4" = "0|1|Findings
- [NOTE unchanged-since $G12] \`f.txt:5-8\`: old range

VERDICT: MERGE-WITH-NOTES" ] && ok || bad "U4 unchanged range: '$U4'"
U4=$(u4 "$G" "$HO" 'Findings\n- [BLOCK] p.txt:2-4: crosses the fix\n\nVERDICT: BLOCK\n')
[ "$U4" = "1||Findings
- [BLOCK] p.txt:2-4: crosses the fix

VERDICT: BLOCK" ] && ok || bad "U4 range over a changed line: '$U4'"
U4=$(u4 "$G" "$HDL" 'Findings\n- [BLOCK] p.txt:8: next to the deletion\n- [BLOCK] f.txt:5: old\n\nVERDICT: BLOCK\n')
case "$U4" in "0|1|"*"- [BLOCK] p.txt:8: next to the deletion"*"- [NOTE unchanged-since $G12] f.txt:5: old"*"VERDICT: BLOCK") ok ;;
  *) bad "U4 a line beside a pure deletion: '$U4'" ;; esac
U4=$(u4 "$G" "$HBIN" 'Findings\n- [BLOCK] img.bin:1: a binary change\n\nVERDICT: BLOCK\n')
case "$U4" in "1||"*"- [BLOCK] img.bin:1: a binary change"*) ok ;; *) bad "U4 a binary file is not all changed: '$U4'" ;; esac
U4=$(u4 "$GX" "$HO" 'Findings\n- [BLOCK] f.txt:5: x\n\nVERDICT: BLOCK\n')
case "$U4" in "2||"*"- [BLOCK] f.txt:5: x"*) ok ;; *) bad "U4 git cannot read GX: '$U4'" ;; esac

# ── U5: lpv_parse refuses what it cannot trust ──
U5=$( HARNESS="$Q"; . "$LIB" || exit 9
  lpv_parse "lead-prev:$G12 word:MERGE report:x own-commits:0 own-files:- main-files:-" && exit 1
  lpv_parse "lead-prev:$G word:APPROVE report:x own-commits:0 own-files:- main-files:-" && exit 2
  lpv_parse "auto: x; lead-delta:$G lines:1/40 files:1" && exit 3
  [ -z "$LPV_PREV$LPV_WORD" ] || exit 4
  exit 0 ); U5RC=$?
[ "$U5RC" = 0 ] && ok || bad "U5 lpv_parse accepted a bad group (exit $U5RC)"

# ── U6: lpv_flip ──
u6() { ( HARNESS="$Q"; . "$LIB" || exit 9; o=$(lpv_flip "$1" "$2"); r=$?; printf '%s|%s' "$r" "$o" ); }
FLIPG() { printf 'auto: x; lead-prev:%s word:%s report:r own-commits:%s own-files:- main-files:f.txt' "$G" "$1" "$2"; }
[ "$(u6 "$(FLIPG MERGE 0)" BLOCK)" = "0|$G12 MERGE own-commits:0" ] && ok || bad "U6 MERGE->BLOCK: $(u6 "$(FLIPG MERGE 0)" BLOCK)"
[ "$(u6 "$(FLIPG BLOCK 0)" MERGE)" = "0|$G12 BLOCK own-commits:0" ] && ok || bad "U6 BLOCK->MERGE: $(u6 "$(FLIPG BLOCK 0)" MERGE)"
[ "$(u6 "$(FLIPG MERGE 0)" MERGE-WITH-NOTES)" = "1|" ] && ok || bad "U6 MERGE->MWN: $(u6 "$(FLIPG MERGE 0)" MERGE-WITH-NOTES)"
[ "$(u6 "$(FLIPG MERGE 1)" BLOCK)" = "1|" ] && ok || bad "U6 own-commits:1: $(u6 "$(FLIPG MERGE 1)" BLOCK)"
[ "$(u6 "$(FLIPG MERGE '?')" BLOCK)" = "1|" ] && ok || bad "U6 own-commits:?: $(u6 "$(FLIPG MERGE '?')" BLOCK)"
[ "$(u6 "auto: x" BLOCK)" = "2|" ] && ok || bad "U6 no group: $(u6 "auto: x" BLOCK)"

# ── U7: a path git does not hold at H is an unknown; own-cause keeps a BLOCK ──
printf 'bin/x.sh\np.txt\n' > "$T/ownf"
u7() { # <answer> [own-files-file] -> "<rc>|<k>|<file>"
  printf '%b' "$1" > "$T/u7.md"
  ( HARNESS="$Q"; . "$LIB" || exit 9; k=$(lpv_downgrade "$QR" "$G" "$HX" "$T/u7.md" "$T/mainf" "${2:-}"); r=$?; printf '%s|%s|' "$r" "$k"; cat "$T/u7.md" )
}
for f in 'x.sh:12' './bin/x.sh:12' 'bin/nope.sh:3' 'bin/x.sh:12' '`x.sh:12`'; do
  U7=$(u7 "Findings\n- [BLOCK] $f: broken\n\nVERDICT: BLOCK\n")
  [ "$U7" = "1||Findings
- [BLOCK] $f: broken

VERDICT: BLOCK" ] && ok || bad "U7 '$f' lost its BLOCK: '$U7'"
done
U7=$(u7 'Findings\n- [BLOCK] bin/x.sh:3: old\n\nVERDICT: BLOCK\n')
[ "$U7" = "0|1|Findings
- [NOTE unchanged-since $G12] bin/x.sh:3: old

VERDICT: MERGE-WITH-NOTES" ] && ok || bad "U7 an unchanged line in a subdir file: '$U7'"
U7=$(u7 'Findings\n- [BLOCK] f.txt:5: calls the renamed name; own-cause: bin/x.sh\n\nVERDICT: BLOCK\n' "$T/ownf")
case "$U7" in "1||"*"- [BLOCK] f.txt:5: calls the renamed name; own-cause: bin/x.sh"*"VERDICT: BLOCK") ok ;;
  *) bad "U7 own-cause on an own file: '$U7'" ;; esac
U7=$(u7 'Findings\n- [BLOCK] f.txt:5: x; own-cause: `o.txt`\n\nVERDICT: BLOCK\n' "$T/ownf")
case "$U7" in "0|1|"*"VERDICT: MERGE-WITH-NOTES") ok ;; *) bad "U7 own-cause on a file that is not own: '$U7'" ;; esac
U7=$(u7 'Findings\n- [BLOCK] f.txt:5: x; own-cause: bin/x.sh\n\nVERDICT: BLOCK\n')
case "$U7" in "0|1|"*"VERDICT: MERGE-WITH-NOTES") ok ;; *) bad "U7 own-cause with no own-files file: '$U7'" ;; esac

# ═══════════════════════════ enqueue cases D1a-D1e ═══════════════════════════
# ── D1a: lead MERGE on G, builder APPROVE on HO ──
reset "$HO" "$HO" MERGE; tick
[ "$RC" -eq 0 ] && ok || bad "D1a rc=$RC out=$(cat "$T/out")"
[ "$(reqs)" = 1 ] && ok || bad "D1a want one request, got $(reqs): $(cat "$QLOG")"
N1A=$(notes)
case "$N1A" in *"; $PREVG own-commits:1 own-files:p.txt main-files:f.txt"*) ok ;; *) bad "D1a scope_notes: '$N1A'" ;; esac
grep -q "example-org/demo-os#41 @${HO:0:12}: re-review of $G12 (MERGE): own-commits:1" "$QLOG" && ok || bad "D1a no re-review log line: $(cat "$QLOG")"

# ── D1b: delta mode off: a full request still carries the group ──
reset "$HO" "$HO" MERGE; LEAD_DELTA_REVIEW_MAX_LINES=0 tick
N1B=$(notes)
case "$N1B" in *lead-delta:*) bad "D1b a delta note with the knob off: '$N1B'" ;; *) ok ;; esac
case "$N1B" in *"; $PREVG own-commits:1 own-files:p.txt main-files:f.txt"*) ok ;; *) bad "D1b scope_notes: '$N1B'" ;; esac

# ── D1c: the earlier head is on no remote: ? lists, the request still goes ──
reset "$HO" "$HO" MERGE "$GX"; tick
[ "$(reqs)" = 1 ] && ok || bad "D1c want one request, got $(reqs)"
N1C=$(notes)
case "$N1C" in *"lead-prev:$GX word:MERGE report:state/lead-reviews/lr-41-${GX:0:12}.md own-commits:? own-files:? main-files:?"*) ok ;;
  *) bad "D1c scope_notes: '$N1C'" ;; esac

# ── D1d: a newer replay row on HM is not the earlier review ──
reset "$HO" "$HO" MERGE
jq --arg h "$HM" '.rows += [{id:6,repo:"example-org/demo-os",pr:41,head_sha:$h,source:"lead",verdict:"MERGE",note:"lead-replay:aaaaaaaaaaaa how:main-merge"}]' \
  "$T/vrows.json" > "$T/v.tmp" && mv "$T/v.tmp" "$T/vrows.json"
tick
N1D=$(notes)
case "$N1D" in *"; $PREVG "*) ok ;; *) bad "D1d lead-prev does not name G: '$N1D'" ;; esac
case "$N1D" in *"lead-prev:$HM"*) bad "D1d lead-prev names the replay head: '$N1D'" ;; *) ok ;; esac

# ── D1e: lead BLOCK on G, builder gate off ──
reset "$HO" "$HO" BLOCK; LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=0 tick
[ "$(reqs)" = 1 ] && ok || bad "D1e want one request, got $(reqs)"
case "$(notes)" in *"lead-prev:$G word:BLOCK report:"*) ok ;; *) bad "D1e scope_notes: '$(notes)'" ;; esac

# ═══════════════════════════ part 2: bin/lead-review.sh ═══════════════════════
B2="$T/hb"; mkdir -p "$B2/bin/lib/jobs" "$B2/prompts" "$B2/catalog/lanes.d" "$B2/state/lead-reviews" "$T/repos" "$T/tmp" "$T/fakebin"
cat > "$B2/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/lr-agent-count"
cp "\${6#@}" "$T/log/prompt.\$(wc -l < "$T/log/lr-agent-count" | tr -d ' ')"
cp "$T/answer" "\$5"
exit 0
EOF
chmod +x "$B2/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$B2" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$B2" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$B2/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$B2/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$B2/prompts/"
echo box-demo > "$B2/state/box-name"
printf 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$B2/fleet.conf"
git clone -q "$OR" "$T/repos/demo-os"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
case "\$url" in *"/api/lead-protected-paths"*) "\$(dirname "\$0")/lpp-answer" "\$m" "\$url"; exit 0 ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/lrhead")" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
lpp_install "$T/fakebin" "$T/lpp.json" "$T/lpp-down"
LLOG="$B2/logs/lead-review.log"
# setup2 <head> <scope notes> <answer> — one request; G's report is on the box
setup2() {
  rm -f "$T/log"/lr-* "$T/log"/prompt.* "$T/log/worker" "$LLOG"
  scratch_rm "$B2/state/lead-reviews"; mkdir -p "$B2/state/lead-reviews"
  # Each case is a fresh review: the per-PR day count (lead-worklist.sh) starts at 0.
  rm -f "$B2/state/lead-review/started.tsv"
  printf '# Lead review lr-41-%s (example-org/demo-os#41 at %s)\n\n- verdict: MERGE\n- reviewer model: stub-model\n\nFindings\n- [NOTE] f.txt:21: the earlier finding\n\nVERDICT: MERGE\n' \
    "$G12" "$G" > "$B2/state/lead-reviews/lr-41-$G12.md"
  echo "$1" > "$T/lrhead"
  printf '%b' "$3" > "$T/answer"
  jq -nc --arg s "$1" --arg n "$2" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:41,head_sha:$s,scope_notes:$n,
    prior_verdict_ref:"v",status:"requested",requested_by:"lead-review-enqueue:box-hub"}],truncated:false}' > "$T/requests.json"
  RKEY="lr-41-${1:0:12}"; RREP="$B2/state/lead-reviews/$RKEY.md"
}
tick2() {
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$B2" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$B2/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$B2/bin/lead-review.sh" tick ) > "$T/out2" 2>&1; RC=$?
}
lragents() { [ -f "$T/log/lr-agent-count" ] && wc -l < "$T/log/lr-agent-count" | tr -d ' ' || echo 0; }
rverdict() { grep '^POST /api/lead-reviews/lr-1/result ' "$T/log/worker" 2>/dev/null | tail -1 | sed 's/^POST \/api\/lead-reviews\/lr-1\/result //' | jq -r .verdict 2>/dev/null; }
BLK5='Findings\n- [BLOCK] f.txt:5: reads p line 5 the wrong way\n\nVERDICT: BLOCK\n'

# ── D2a: a new BLOCK on a line unchanged since the approved head: MERGE-WITH-NOTES ──
setup2 "$HO" "$N1A" "$BLK5"; tick2
[ "$RC" -eq 0 ] && ok || bad "D2a rc=$RC out=$(cat "$T/out2")"
[ "$(rverdict)" = MERGE-WITH-NOTES ] && ok || bad "D2a posted verdict '$(rverdict)': $(cat "$LLOG")"
grep -qF -- "- [NOTE unchanged-since $G12] f.txt:5: reads p line 5 the wrong way" "$RREP" 2>/dev/null && ok || bad "D2a the report: $(cat "$RREP" 2>/dev/null)"
grep -qx -- "- re-review: from $G12 (MERGE); 1 BLOCK finding(s) on lines unchanged since then kept as NOTE" "$RREP" 2>/dev/null && ok || bad "D2a no re-review header line"
grep -qx -- "- verdict: MERGE-WITH-NOTES" "$RREP" 2>/dev/null && ok || bad "D2a the report verdict line"
grep -q '^- \[BLOCK' "$RREP" 2>/dev/null && bad "D2a a BLOCK line is left in the report" || ok
[ "$(lragents)" = 1 ] && ok || bad "D2a agent calls $(lragents)"
grep -q "$RKEY: 1 BLOCK finding(s) on lines unchanged since $G12 kept as NOTE; verdict MERGE-WITH-NOTES" "$LLOG" && ok || bad "D2a no log line: $(cat "$LLOG")"
# The report still reads as a review with findings: bin/lead-review.sh's own
# lr_has_findings, cut from the script (an absent function is a failure here).
LHF=$(sed -n '/^lr_has_findings() {$/,/^}$/p' "$B2/bin/lead-review.sh")
[ -n "$LHF" ] && ( . <(printf '%s\n' "$LHF"); lr_has_findings "$RREP" ) && ok || bad "D2a the rewritten report has no findings block (lr_has_findings found: ${LHF:+yes})"

# ── D2b: the finding is on the own change: BLOCK stays ──
setup2 "$HO" "$N1A" 'Findings\n- [BLOCK] p.txt:3: the fix is wrong\n\nVERDICT: BLOCK\n'; tick2
[ "$(rverdict)" = BLOCK ] && ok || bad "D2b posted verdict '$(rverdict)'"
grep -qF -- "- [BLOCK] p.txt:3: the fix is wrong" "$RREP" 2>/dev/null && ok || bad "D2b the BLOCK line changed"
grep -q -- '^- re-review:' "$RREP" 2>/dev/null && bad "D2b a re-review line with nothing kept as NOTE" || ok

# ── D2c: needs-human is never rewritten ──
setup2 "$HO" "$N1A" 'Findings\n- [BLOCK needs-human] f.txt:5: a product call\n\nVERDICT: BLOCK\n'; tick2
[ "$(rverdict)" = BLOCK ] && ok || bad "D2c posted verdict '$(rverdict)'"

# ── D2d: no path:line: BLOCK stays ──
setup2 "$HO" "$N1A" 'Findings\n- [BLOCK] the diff could not be read\n\nVERDICT: BLOCK\n'; tick2
[ "$(rverdict)" = BLOCK ] && ok || bad "D2d posted verdict '$(rverdict)'"

# ── D2e: the earlier word was BLOCK: no NOTE pass ──
setup2 "$HO" "${N1A/word:MERGE/word:BLOCK}" "$BLK5"; tick2
[ "$(rverdict)" = BLOCK ] && ok || bad "D2e posted verdict '$(rverdict)'"

# ── D2f: the reviewer's git cannot read the earlier head: BLOCK stays ──
setup2 "$HO" "$N1C" "$BLK5"; tick2
[ "$(rverdict)" = BLOCK ] && ok || bad "D2f posted verdict '$(rverdict)'"
grep -q "$RKEY: re-review check could not read git; the model's BLOCK stands" "$LLOG" && ok || bad "D2f no log line: $(cat "$LLOG")"

# ── D3a: main-cause names a main file of the delta: BLOCK stays ──
setup2 "$HO" "$N1A" 'Findings\n- [BLOCK] p.txt:7: calls what main changed; main-cause: f.txt\n\nVERDICT: BLOCK\n'; tick2
[ "$(rverdict)" = BLOCK ] && ok || bad "D3a posted verdict '$(rverdict)'"

# ── D3b: main changed the line between G and the head: BLOCK stays ──
setup2 "$HM" "auto: CI green on ${HM:0:12}; $NOTE_HM" 'Findings\n- [BLOCK] f.txt:1: main broke the header\n\nVERDICT: BLOCK\n'; tick2
[ "$(rverdict)" = BLOCK ] && ok || bad "D3b posted verdict '$(rverdict)': $(cat "$LLOG")"

# ── D3c: main-cause names a file that is not a main file of the delta ──
setup2 "$HO" "$N1A" 'Findings\n- [BLOCK] p.txt:7: something; main-cause: o.txt\n\nVERDICT: BLOCK\n'; tick2
[ "$(rverdict)" = MERGE-WITH-NOTES ] && ok || bad "D3c posted verdict '$(rverdict)'"

# ── D3d: own-cause names an own file of the delta: BLOCK stays ──
setup2 "$HO" "$N1A" 'Findings\n- [BLOCK] f.txt:5: calls what the own fix changed; own-cause: p.txt\n\nVERDICT: BLOCK\n'; tick2
[ "$(rverdict)" = BLOCK ] && ok || bad "D3d posted verdict '$(rverdict)': $(cat "$LLOG")"
grep -qF -- "- [BLOCK] f.txt:5: calls what the own fix changed; own-cause: p.txt" "$RREP" 2>/dev/null && ok || bad "D3d the BLOCK line changed"

# ── D3e: own-cause names a file that is not an own file of the delta ──
setup2 "$HO" "$N1A" 'Findings\n- [BLOCK] p.txt:7: something; own-cause: f.txt\n\nVERDICT: BLOCK\n'; tick2
[ "$(rverdict)" = MERGE-WITH-NOTES ] && ok || bad "D3e posted verdict '$(rverdict)'"

# ── P1: the prompt section, full mode (D1b's notes) ──
setup2 "$HO" "$N1B" 'Findings\n- none\n\nVERDICT: MERGE\n'; tick2
PF="$T/log/prompt.1"
rp=$(grep -n '^## Rules pack$' "$PF" 2>/dev/null | tail -1 | cut -d: -f1)
rr=$(grep -n '^## Re-review$' "$PF" 2>/dev/null | tail -1 | cut -d: -f1)
hs=$(grep -n '^## Host suite$' "$PF" 2>/dev/null | tail -1 | cut -d: -f1)
[ -n "$rp" ] && [ -n "$rr" ] && [ -n "$hs" ] && [ "$rp" -lt "$rr" ] && [ "$rr" -lt "$hs" ] && ok || bad "P1 section order: rules pack=$rp re-review=$rr host suite=$hs"
SEC=$(sed -n "${rr:-1},${hs:-1}p" "$PF" 2>/dev/null)
for w in "$G12" MERGE "fix p three" p.txt f.txt "the earlier finding"; do
  case "$SEC" in *"$w"*) ok ;; *) bad "P1 the Re-review section lacks '$w': $SEC" ;; esac
done
grep -q 'main-cause:' "$PF" && grep -q 'own-cause:' "$PF" && grep -q 'missed-because:' "$PF" && ok || bad "P1 the prompt rules lack main-cause:, own-cause: or missed-because:"
grep -q "lr-41-${HO:0:12}: re-review of $G12 (MERGE)" "$LLOG" && ok || bad "P1 no re-review log line: $(cat "$LLOG")"
# In delta mode the prior report is already in the diff: not shown twice.
setup2 "$HO" "$N1A" 'Findings\n- none\n\nVERDICT: MERGE\n'; tick2
[ "$(grep -c '^- \[NOTE\] f.txt:21: the earlier finding$' "$T/log/prompt.1" 2>/dev/null)" = 1 ] && ok || bad "P1 delta mode shows the prior report $(grep -c '^- \[NOTE\] f.txt:21: the earlier finding$' "$T/log/prompt.1" 2>/dev/null) times"

# ═══════════════════════════ part 3: bin/lead-review-land.sh ═════════════════
L="$T/hl"; mkdir -p "$L/state" "$L/logs" "$L/catalog" "$T/lbin" "$T/llog" "$T/ltmp"
scratch_install_closure bin/lead-review-land.sh "$L" >/dev/null || bad "closure of bin/lead-review-land.sh"
scratch_install_closure bin/lead-verdict.sh "$L" >/dev/null || bad "closure of bin/lead-verdict.sh"
scratch_install_closure bin/jobs-client.sh "$L" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/catalog/lead-protected-paths.seed.tsv" "$L/catalog/"
SHA=$(printf 'a%.0s' {1..40})
cat > "$T/lbin/curl" <<'EOF'
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    --data-binary) body="$a" ;;
    -H) case "$a" in @*) hdrs="$hdrs$(cat "${a#@}")"$'\n' ;; *) hdrs="$hdrs$a"$'\n' ;; esac ;;
  esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
case "$url" in *"/api/lead-protected-paths"*) "$(dirname "$0")/lpp-answer" "$m" "$url"; exit 0 ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"$hdrs" && lead=1
p="${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "$m" "$p" "$body" "$lead" >> "@T@/llog/worker"
[ -f "@T@/lvrows.json" ] || echo '[]' > "@T@/lvrows.json"
qp() { printf '%s' "${p#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
code=200; out='{}'
case "$m $p" in
  "GET /api/lead-reviews"*) out=$(cat "@T@/lrequests.json") ;;
  "POST /api/lead-reviews/"*/promoted) out='{"request":{"promoted_verdict_at":"2026-10-13T00:00:00Z"}}' ;;
  "POST /api/verdicts")
    n=$(jq length "@T@/lvrows.json")
    row=$(jq -c --argjson id "$((n + 1))" '. + {id:$id, created_at:"2026-10-13T00:00:00Z"}' <<<"$body")
    jq -c --argjson r "$row" '. + [$r]' "@T@/lvrows.json" > "@T@/lvrows.tmp" && mv "@T@/lvrows.tmp" "@T@/lvrows.json"
    code=201; out=$(jq -c '{verdict:.}' <<<"$row") ;;
  "GET /api/verdicts?"*)
    out=$(jq -c --arg r "$(qp repo)" --argjson pr "$(qp pr)" --arg h "$(qp head)" '
      [.[] | select(.repo == $r and .pr == $pr)] | sort_by(-.id) as $rows
      | {repo:$r, pr:$pr, head:(if $h == "" then null else $h end),
         standing:([$rows[] | select(.head_sha == $h and (.source == "lead" or .source == "human"))] | first),
         rows:$rows, truncated:false}' "@T@/lvrows.json") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "$out" "$code"
EOF
sed -i "s#@T@#$T#g" "$T/lbin/curl"
cat > "$T/lbin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/reviews"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"-X POST repos/"*"/reviews"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"id":1}\n' ;;
  *"-X GET repos/"*"/pulls/"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"head":{"sha":"$SHA"}}\n' ;;
  *"-X POST repos/"*"/statuses/"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
esac
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$L/bin/lane-alert.sh"
chmod +x "$T/lbin/curl" "$T/lbin/gh" "$L/bin/lane-alert.sh"
lpp_install "$T/lbin" "$T/lpp.json" "$T/lpp-down"
LANDLOG="$L/logs/lead-review-land.log"
# lreset <verdict> <scope notes>
lreset() {
  rm -f "$T/llog"/* "$T/lvrows.json" "$LANDLOG"
  scratch_rm "$L/state/lead-review-land"; echo box-hub > "$L/state/box-name"
  jq -nc --arg v "$1" --arg n "$2" --arg h "$SHA" '{requests:[{id:"lr-1", repo:"example-org/demo-os", pr:41, head_sha:$h, status:"done",
    verdict:$v, reviewer_model:"stub-model", report_ref:"state/lead-reviews/lr-41-aaaaaaaaaaaa.md", scope_notes:$n,
    requested_by:"lead-review-enqueue:box-hub", promoted_verdict_at:null, detail:null,
    created_at:"2026-10-13T00:00:00Z", updated_at:"2026-10-13T00:00:00Z"}], truncated:false}' > "$T/lrequests.json"
}
ltick() {
  ( cd "$T" && PATH="$T/lbin:$PATH" HARNESS="$L" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 TMPDIR="$T/ltmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
      bash "$L/bin/lead-review-land.sh" ) > "$T/lout" 2>&1; RC=$?
}
flips() { grep -c ' flip ' "$LANDLOG" 2>/dev/null || true; }
lnote() { printf 'auto: builder APPROVE on %s; lead-prev:%s word:%s report:state/lead-reviews/lr-41-%s.md own-commits:%s own-files:- main-files:f.txt' "${SHA:0:12}" "$G" "$1" "$G12" "$2"; }

# ── D4a: MERGE on G, BLOCK now, no own commit: one flip line ──
lreset BLOCK "auto: builder APPROVE on ${SHA:0:12}; $NOTE_HM"; ltick
[ "$RC" -eq 0 ] && ok || bad "D4a rc=$RC out=$(cat "$T/lout")"
[ "$(flips)" = 1 ] && ok || bad "D4a want one flip line, got $(flips): $(cat "$LANDLOG" 2>/dev/null)"
grep -q " flip example-org/demo-os#41 $G12 MERGE -> ${SHA:0:12} BLOCK own-commits:0 request:lr-1$" "$LANDLOG" 2>/dev/null && ok || bad "D4a the flip line: $(grep flip "$LANDLOG" 2>/dev/null)"
[ "$(grep -c '^POST /api/verdicts ' "$T/llog/worker" 2>/dev/null)" = 1 ] && ok || bad "D4a the verdict post: $(cat "$T/llog/worker")"
[ "$(grep -c '^POST /api/lead-reviews/lr-1/promoted ' "$T/llog/worker" 2>/dev/null)" = 1 ] && ok || bad "D4a the stamp"
ltick
[ "$(flips)" = 1 ] && ok || bad "D4a a rerun logged $(flips) flip lines"

# ── D4b: BLOCK on G, MERGE now ──
lreset MERGE "$(lnote BLOCK 0)"; ltick
[ "$(flips)" = 1 ] && ok || bad "D4b want one flip line, got $(flips): $(cat "$LANDLOG" 2>/dev/null)"
grep -q " flip example-org/demo-os#41 $G12 BLOCK -> ${SHA:0:12} MERGE own-commits:0 request:lr-1$" "$LANDLOG" 2>/dev/null && ok || bad "D4b the flip line"
# ── D4c-D4f: no flip ──
lreset MERGE-WITH-NOTES "$(lnote MERGE 0)"; ltick
[ "$(flips)" = 0 ] && ok || bad "D4c MERGE -> MERGE-WITH-NOTES logged a flip"
lreset BLOCK "$(lnote MERGE 1)"; ltick
[ "$(flips)" = 0 ] && ok || bad "D4d own-commits:1 logged a flip"
lreset BLOCK "$(lnote MERGE '?')"; ltick
[ "$(flips)" = 0 ] && ok || bad "D4e own-commits:? logged a flip"
lreset BLOCK "auto: builder APPROVE on ${SHA:0:12}"; ltick
[ "$(flips)" = 0 ] && ok || bad "D4f no group logged a flip"
[ "$(grep -c '^POST /api/lead-reviews/lr-1/promoted ' "$T/llog/worker" 2>/dev/null)" = 1 ] && ok || bad "D4f the stamp"

echo "lead-review-delta-scope.bh-6391: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
