#!/bin/bash
# tests/lead-delta-protected.bh-5582-test.sh — BH-5582: a small re-review delta
# that touches a lead protected path stays in delta mode after a lead MERGE, and
# lines a main merge brought in are never counted as the PR's own delta.
#
# The fixture is a real git repo. Base holds worker/jobs/schema.sql (40 lines,
# protected: the schema rule), f.txt (20 lines) and o.txt. G (the head the lead
# approved) adds one line near the top of each of the two files. Main then adds
# one line at the bottom of schema.sql and 300 lines at the end of f.txt.
#   H4 = G + a clean `git merge main`
#   H1 = H4 + 5 own lines in schema.sql      H2 = H4 + 30 own lines in schema.sql
#   H6 = H4 + 3 own lines in f.txt
#
#   bin/lib/lead-delta.sh ld_classify <clone> origin/main <G> <H> <slug> <word>
#     P1  G H1 MERGE                         -> delta 5 40 1 protected:worker/jobs/schema.sql
#     P2  G H2 MERGE (30 > 20)               -> full protected:worker/jobs/schema.sql
#     P3  G H1 MERGE, knob 0                 -> full protected:worker/jobs/schema.sql
#     P4  G H4 MERGE (main merge only)       -> replay main-merge, never full
#     P5  G H1 BLOCK, and an empty word      -> full protected:worker/jobs/schema.sql
#     P6  G H6 MERGE (main's 300 not counted) -> delta 3 40 1
#   P7  LEAD_DELTA_PROTECTED_MAX_LINES is registered (default 20) and ld_knob reads it.
#   bin/lead-review-enqueue.sh tick (whole, the BH-5294 scaffold)
#     P1  builder APPROVE on H1, lead MERGE on G: ONE request, scope_notes with
#         `lead-delta:<G> lines:5/40 files:1 protected:worker/jobs/schema.sql`.
#     P4  builder APPROVE on G, head H4: the MERGE is posted onto H4 with note
#         lead-replay:<G12> how:main-merge; nothing requested.
#     P8  the cached class of a protected delta carries the knob and word
#         (8th column 20:MERGE); a tick under knob 0 does not reuse it: it
#         fetches again and requests a FULL review.
#   bin/lead-review.sh tick (whole)
#     P1  the delta request: the prompt has DELTA REVIEW, a line naming
#         worker/jobs/schema.sql for full scrutiny, H1's own lines, and NOT
#         main's 300 f.txt lines.
#     P1b a protected token that does not parse: a full review, logged.
# Dispatcher section (BH-5874): gate 3's delta class with a protected path,
# bin/lib/lead-gates.d/50-replay-delta.sh, on the worklist. bin/lead-review.sh
# tick runs WHOLE over tests/lib/lead-worklist-fixture.bh-4956.sh; its repo is a
# clone of the fixture repo above (#41 = H1, #42 = H2), and the lead MERGEd G.
#   P1  H1 (5 own lines in worker/jobs/schema.sql, 5 <= 20): one delta.tsv row
#       of 8 columns, the 8th 20:MERGE; the log names the delta class and
#       LG_MODE=delta; one lead_review job.
#   P2  a second tick on H1: the cached row is reused, no fetch of G/H1.
#   P3  H2 (30 own lines, over 20): `full protected:worker/jobs/schema.sql`,
#       one lead_review job.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-delta-protected.bh-5582-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lead-review-enqueue.sh bin/lib/lead-delta.sh bin/lib/patch-same.sh catalog/lanes.d/_lib.lead-delta.json; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_DELTA_PROTECTED_MAX_LINES AGENT_CALL_FP AGENT_CALL_GUARD_STAGE

# ───────────────────────────── the fixture repo ─────────────────────────────
OR="$T/origin/demo-os.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
mkdir -p "$WK/worker/jobs"
seq 1 40 | sed 's/^/schema line /' > "$WK/worker/jobs/schema.sql"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"; printf 'other\n' > "$WK/o.txt"
printf '# demo\n\nNo contract here.\n' > "$WK/CLAUDE.md"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr
sed -i '2a pr schema line' "$WK/worker/jobs/schema.sql"; sed -i '2a pr f line' "$WK/f.txt"
git -C "$WK" commit -qam "the pr"; G=$(git -C "$WK" rev-parse HEAD); G12=${G:0:12}
git -C "$WK" checkout -q main
echo 'main schema tail' >> "$WK/worker/jobs/schema.sql"; seq 1 300 | sed 's/^/main add /' >> "$WK/f.txt"
git -C "$WK" commit -qam "main moves"
git -C "$WK" checkout -q pr; git -C "$WK" merge -q --no-edit main || { echo "FAIL: the fixture merge conflicted"; exit 1; }
H4=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb p1 "$H4"; sed -i '20r /dev/stdin' "$WK/worker/jobs/schema.sql" < <(seq 1 5 | sed 's/^/p1 own /')
git -C "$WK" commit -qam "5 own schema lines"; H1=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb p2 "$H4"; sed -i '20r /dev/stdin' "$WK/worker/jobs/schema.sql" < <(seq 1 30 | sed 's/^/p2 own /')
git -C "$WK" commit -qam "30 own schema lines"; H2=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb p6 "$H4"; sed -i '10r /dev/stdin' "$WK/f.txt" < <(seq 1 3 | sed 's/^/p6 own /')
git -C "$WK" commit -qam "3 own f lines"; H6=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main pr p1 p2 p6
git -C "$WK" push -q "$OR" "$H1:refs/pull/41/head"
[ "$(git -C "$WK" diff --numstat "$G" "$H1" | awk '{s += $1 + $2} END {print s}')" -gt 300 ] \
  || { echo "FAIL: the fixture G..H1 does not carry main's 300 lines"; exit 1; }

# ═══════════════════════ part 1: bin/lead-review-enqueue.sh ═══════════════════
Q="$T/hq"; mkdir -p "$Q/bin/lib/jobs" "$Q/state" "$Q/logs" "$Q/catalog/lanes.d" "$T/cfg" "$T/qrepos" "$T/log" "$T/qbin"
cat > "$Q/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/post"
if [ "\$1" = post ]; then
  note=""; prev=""; for a in "\$@"; do [ "\$prev" = --note ] && note="\$a"; prev="\$a"; done
  jq -c --arg h "\$4" --arg v "\$5" --arg n "\$note" '.rows += [{id:99, head_sha:\$h, source:"lead", verdict:\$v, note:\$n}]' \
    "$T/vrows.json" > "$T/vrows.tmp" && mv "$T/vrows.tmp" "$T/vrows.json"
fi
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
cp "$SRC/catalog/lead-protected-paths.tsv" "$Q/catalog/"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$Q/fleet.conf"
git clone -q "$OR" "$T/qrepos/demo-os"
mkdir -p "$T/gitbin"; REALGIT=$(command -v git)
cat > "$T/gitbin/git" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = fetch ] && { echo x >> "$T/log/fetches"; break; }; done
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/gitbin/git"
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
# reset <head> <builder-approved sha> <lead word on G>
reset() {
  rm -f "$T/log"/q* "$T/log/post" "$T/log/fetches" "$QLOG"
  scratch_rm "$Q/state"; mkdir -p "$Q/state"; echo box-hub > "$Q/state/box-name"
  scratch_rm "$T/jv"; mkdir -p "$T/jv"
  echo "$1" > "$T/qhead"
  jq -nc --arg s "$2" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  jq -nc --arg g "$G" --arg w "$3" '{rows:[{id:4,repo:"example-org/demo-os",pr:41,head_sha:$g,source:"box",verdict:"APPROVE",note:""},
    {id:5,repo:"example-org/demo-os",pr:41,head_sha:$g,source:"lead",verdict:$w,note:"lead-review:lr-3"}],truncated:false}' > "$T/vrows.json"
}
tick() {
  ( cd "$T" && PATH="$T/qbin:$T/gitbin:$PATH" HARNESS="$Q" REPOS_ROOT="$T/qrepos" FLEET_CONF="$Q/fleet.conf" \
      LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 JOBS_URL=https://jobs.test \
      HARNESS_SECRET=test-secret JOBS_RETRIES=0 GH_ETAG=0 \
      bash "$Q/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?
}
reqs() { grep -c '^POST /api/lead-reviews ' "$T/log/qworker" 2>/dev/null || true; }
reqbody() { grep '^POST /api/lead-reviews ' "$T/log/qworker" | head -1 | sed 's/^POST \/api\/lead-reviews //; s/ lead=[01]$//'; }
postn() { [ -f "$T/log/post" ] && wc -l < "$T/log/post" | tr -d ' ' || echo 0; }
fetches() { [ -f "$T/log/fetches" ] && wc -l < "$T/log/fetches" | tr -d ' ' || echo 0; }
summ() { grep ' tick repos=' "$QLOG" 2>/dev/null | tail -1; }
hasw() { summ | grep -qw -- "$1"; }

# ── the lib on its own: ld_classify on a clone of the fixture ──
LC="$T/lclone"; git clone -q "$OR" "$LC"; git -C "$LC" fetch -q origin "$H1" "$H2" "$H6" 2>/dev/null
# cls <G> <H> [word] — ld_classify with example-org/cromford, the TSV as the protected list
cls() {
  ( HARNESS="$Q"; . "$Q/bin/lib/lead-authority.sh"; . "$Q/bin/lib/patch-same.sh"; . "$Q/bin/lib/lead-delta.sh"
    setting_get() { return 2; }
    ld_classify "$LC" origin/main "$1" "$2" example-org/cromford "${3:-}" ) 2>/dev/null
}
V=$(cls "$G" "$H1" MERGE)
[ "$V" = "delta 5 40 1 protected:worker/jobs/schema.sql" ] && ok || bad "P1 (lib) G..H1 after MERGE: '$V'"
V=$(cls "$G" "$H2" MERGE)
[ "$V" = "full protected:worker/jobs/schema.sql" ] && ok || bad "P2 (lib) a 30-line protected delta: '$V'"
V=$(LEAD_DELTA_PROTECTED_MAX_LINES=0; export LEAD_DELTA_PROTECTED_MAX_LINES; cls "$G" "$H1" MERGE)
[ "$V" = "full protected:worker/jobs/schema.sql" ] && ok || bad "P3 (lib) knob 0: '$V'"
V=$(cls "$G" "$H4" MERGE)
case "$V" in "replay "*|"delta "*) ok ;; *) bad "P4 (lib) a main-merge-only head: '$V'" ;; esac
[ "$V" = "replay main-merge" ] && ok || bad "P4 (lib) want 'replay main-merge', got '$V'"
V=$(cls "$G" "$H1" BLOCK)
[ "$V" = "full protected:worker/jobs/schema.sql" ] && ok || bad "P5 (lib) after a BLOCK: '$V'"
V=$(cls "$G" "$H1")
[ "$V" = "full protected:worker/jobs/schema.sql" ] && ok || bad "P5 (lib) with no prior word: '$V'"
V=$(cls "$G" "$H6" MERGE)
[ "$V" = "delta 3 40 1" ] && ok || bad "P6 (lib) main's 300 lines counted as the PR's own: '$V'"

# ── P7: the knob is registered and resolves to its default ──
jq -e '.libs[] | select(.id == "lead-delta") | .knobs[] | select(.env == "LEAD_DELTA_PROTECTED_MAX_LINES")
       | .default == 20 and .min == 0 and .zero_means == "off" and ((.note // "") | length > 0)' \
  "$SRC/catalog/lanes.d/_lib.lead-delta.json" >/dev/null 2>&1 && ok || bad "P7 LEAD_DELTA_PROTECTED_MAX_LINES is not registered as specified"
V=$( ( HARNESS="$Q"; . "$Q/bin/lib/lead-delta.sh"; ld_knob LEAD_DELTA_PROTECTED_MAX_LINES ) 2>/dev/null )
[ "$V" = 20 ] && ok || bad "P7 ld_knob LEAD_DELTA_PROTECTED_MAX_LINES: '$V'"

# ── P1 (enqueue): builder approved H1: one delta request naming the protected file ──
reset "$H1" "$H1" MERGE; tick
[ "$RC" -eq 0 ] && ok || bad "P1 (enqueue) rc=$RC out=$(cat "$T/out")"
[ "$(reqs)" = 1 ] && ok || bad "P1 (enqueue) want one request, got $(reqs)"
# TEST-CHANGE (BH-6391): the delta note is now followed by the lead-prev: group.
case "$(jq -r .scope_notes <<<"$(reqbody)" 2>/dev/null)" in
  *"lead-delta:$G lines:5/40 files:1 protected:worker/jobs/schema.sql; lead-prev:$G word:MERGE "*) ok ;;
  *) bad "P1 (enqueue) scope_notes: $(reqbody) log: $(cat "$QLOG")" ;;
esac
hasw delta=1 && hasw full=0 && ok || bad "P1 (enqueue) summary: $(summ)"

# ── P4 (enqueue): only main merged in, builder APPROVE on G: the MERGE is replayed ──
reset "$H4" "$G" MERGE; tick
WANT="post example-org/demo-os 41 $H4 MERGE --source lead --reviewer box:box-hub --note lead-replay:$G12 how:main-merge"
[ "$(cat "$T/log/post" 2>/dev/null)" = "$WANT" ] && ok || bad "P4 (enqueue) lead-verdict argv: '$(cat "$T/log/post" 2>/dev/null)' log: $(cat "$QLOG")"
[ "$(reqs)" = 0 ] && ok || bad "P4 (enqueue) a review was requested: $(reqbody)"

# ── P8: the cache keys a protected class on the knob and the word ──
reset "$H1" "$G" MERGE; tick
[ "$(reqs)" = 0 ] && ok || bad "P8 an unapproved head was requested"
grep -q "	$G	$H1	40	delta 5 40 1 protected:worker/jobs/schema.sql	20:MERGE$" "$Q/state/lead-review-enqueue/delta.tsv" && ok \
  || bad "P8 cached row: $(cat "$Q/state/lead-review-enqueue/delta.tsv")"
F1=$(fetches)
jq -c --arg s "$H1" '.reviewed_sha = $s' "$T/jv/41.json" > "$T/jv/x" && mv "$T/jv/x" "$T/jv/41.json"
rm -f "$T/log/qworker"
LEAD_DELTA_PROTECTED_MAX_LINES=0 tick
[ "$(fetches)" -gt "$F1" ] && ok || bad "P8 the knob-0 tick reused the cached protected class (fetches $(fetches) vs $F1)"
[ "$(reqs)" = 1 ] && ok || bad "P8 want one request under knob 0, got $(reqs)"
case "$(jq -r .scope_notes <<<"$(reqbody)" 2>/dev/null)" in *lead-delta*) bad "P8 delta mode under knob 0: $(reqbody)" ;; *) ok ;; esac

# ═════════════════════════ part 2: bin/lead-review.sh ═════════════════════════
B2="$T/hb"; mkdir -p "$B2/bin/lib/jobs" "$B2/prompts" "$B2/catalog/lanes.d" "$B2/state/lead-reviews" "$T/repos" "$T/tmp" "$T/fakebin"
cat > "$B2/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/lr-agent-count"
cp "\${6#@}" "$T/log/prompt.\$(wc -l < "$T/log/lr-agent-count" | tr -d ' ')"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
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
    jq -nc --arg s "$H1" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
LLOG="$B2/logs/lead-review.log"
GREPORT="$B2/state/lead-reviews/lr-41-$G12.md"
setup2() {
  rm -f "$T/log"/lr-* "$T/log"/prompt.* "$T/log/worker" "$LLOG"
  scratch_rm "$B2/state/lead-reviews"; mkdir -p "$B2/state/lead-reviews"
  printf '# Lead review lr-41-%s (example-org/demo-os#41 at %s)\n\n- verdict: MERGE\n- reviewer model: stub-model\n\nFindings\n- [NOTE] f.txt:3: the earlier finding\n\nVERDICT: MERGE\n' \
    "$G12" "$G" > "$GREPORT"
  jq -nc --arg s "$H1" --arg n "$1" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:41,head_sha:$s,scope_notes:$n,
    prior_verdict_ref:"v",status:"requested",requested_by:"lead-review-enqueue:box-hub"}],truncated:false}' > "$T/requests.json"
}
tick2() {
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$B2" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$B2/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$B2/bin/lead-review.sh" tick ) > "$T/out2" 2>&1; RC=$?
}
lragents() { [ -f "$T/log/lr-agent-count" ] && wc -l < "$T/log/lr-agent-count" | tr -d ' ' || echo 0; }

# ── P1 (prompt): the delta names the protected file and carries only the PR's own lines ──
setup2 "auto: builder APPROVE on ${H1:0:12}; lead-delta:$G lines:5/40 files:1 protected:worker/jobs/schema.sql"; tick2
[ "$RC" -eq 0 ] && ok || bad "P1 (prompt) rc=$RC out=$(cat "$T/out2")"
[ "$(lragents)" = 1 ] && ok || bad "P1 (prompt) agent called $(lragents) time(s): $(cat "$LLOG" 2>/dev/null)"
PR1="$T/log/prompt.1"
grep -q '^DELTA REVIEW' "$PR1" 2>/dev/null && ok || bad "P1 (prompt) no delta header"
grep -Eq 'worker/jobs/schema\.sql.*full scrutiny' "$PR1" 2>/dev/null && ok || bad "P1 (prompt) no line names worker/jobs/schema.sql for full scrutiny"
grep -q '^+p1 own 5$' "$PR1" 2>/dev/null && ok || bad "P1 (prompt) H1's own lines are not in the prompt"
grep -q '^+main add ' "$PR1" 2>/dev/null && bad "P1 (prompt) main's f.txt lines are in the delta ($(grep -c '^+main add ' "$PR1") lines)" || ok

# ── P1b: a protected token that does not parse is a full review, logged ──
setup2 "auto: builder APPROVE on ${H1:0:12}; lead-delta:$G lines:5/40 files:1 protected:worker/jobs/sch\$ema.sql"; tick2
[ "$(lragents)" = 1 ] && ok || bad "P1b agent called $(lragents) time(s)"
grep -q '^DELTA REVIEW' "$T/log/prompt.1" 2>/dev/null && bad "P1b an unreadable protected list was reviewed in delta mode" || ok
grep -q 'protected list unreadable' "$LLOG" 2>/dev/null && ok || bad "P1b no 'protected list unreadable' log line: $(cat "$LLOG" 2>/dev/null)"

# ═══════════ dispatcher section (BH-5874): the protected delta on the worklist ═══════════
OR_DISP="$OR"
git -C "$WK" push -q "$OR" "$H2:refs/pull/42/head"
T="$T/disp"; mkdir -p "$T"
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
scratch_rm "$T/repos/demo-os"; git clone -q "$OR_DISP" "$T/repos/demo-os"
DREALGIT=$(command -v git)
cat > "$T/fakebin/git" <<GIT
#!/bin/bash
for a in "\$@"; do [ "\$a" = fetch ] && { printf '%s\n' "\$*" >> "$T/log/git-fetch"; break; }; done
exec "$DREALGIT" "\$@"
GIT
chmod +x "$T/fakebin/git"
DELTA="$H/state/lead-review-enqueue/delta.tsv"
djobs() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
# pset <pr> <head> — the worklist item, the lead MERGE on G
pset() {
  lwf_reset; scratch_rm "$H/state/lead-review-enqueue"
  lwf_needs_at example-org/demo-os "$2" "$1"; echo "$2" > "$FX/head.$1"
  jq -nc --arg g "$G" --argjson p "$1" '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:$p, head_sha:$g, verdict:"MERGE", note:""}], truncated:false}' > "$FX/verdicts.json"
}

# ── P1: a small protected delta after a lead MERGE ──
pset 41 "$H1"
lwf_tick
[ "$(wc -l < "$DELTA" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "P1 delta.tsv rows: $(cat "$DELTA" 2>/dev/null) / $(cat "$L")"
[ "$(awk -F'\t' '{print NF}' "$DELTA" 2>/dev/null)" = 8 ] && ok || bad "P1 the row is not 8 columns: $(cat "$DELTA" 2>/dev/null)"
[ "$(awk -F'\t' '{print $2 " " $3 " " $4 " " $5 " " $6 " " $8}' "$DELTA" 2>/dev/null)" = "example-org/demo-os 41 $G $H1 40 20:MERGE" ] && ok || bad "P1 row keys: $(cat "$DELTA" 2>/dev/null)"
[ "$(awk -F'\t' '{print $7}' "$DELTA" 2>/dev/null)" = "delta 5 40 1 protected:worker/jobs/schema.sql" ] && ok || bad "P1 class: $(cat "$DELTA" 2>/dev/null)"
grep -q "example-org/demo-os#41 @${H1:0:12}: since $G12: delta 5 40 1 protected:worker/jobs/schema.sql; LG_MODE=delta" "$L" && ok || bad "P1 no delta line: $(cat "$L")"
[ "$(djobs 41)" = 1 ] && ok || bad "P1 jobs for 41=$(djobs 41) (want 1)"
[ -s "$H/state/lead-review-enqueue/modes.tsv" ] && bad "P1 a modes.tsv row for a review that is not a delta review: $(cat "$H/state/lead-review-enqueue/modes.tsv")" || ok
f1=$(lwf_cnt "fetch -q origin main $H1" "$T/log/git-fetch")
[ "$f1" -ge 1 ] && ok || bad "P1 the gate made no fetch (P2 would prove nothing): $(cat "$T/log/git-fetch" 2>/dev/null)"

# ── P2: the second tick reuses the cached class ──
lwf_tick
[ "$(lwf_cnt "fetch -q origin main $H1" "$T/log/git-fetch")" = "$f1" ] && ok || bad "P2 the cached class was not reused: $(cat "$T/log/git-fetch")"
[ "$(wc -l < "$DELTA" | tr -d ' ')" = 1 ] && ok || bad "P2 delta.tsv rows after 2 ticks: $(cat "$DELTA")"
[ "$(lwf_cnt "since $G12: delta 5 40 1 protected:worker/jobs/schema.sql; LG_MODE=delta" "$L")" = 2 ] && ok || bad "P2 the cached class was not used: $(cat "$L")"

# ── P3: over the protected allowance: a full review ──
pset 42 "$H2"
lwf_tick
[ "$(awk -F'\t' '{print $7 " " $8}' "$DELTA" 2>/dev/null)" = "full protected:worker/jobs/schema.sql 20:MERGE" ] && ok || bad "P3 delta.tsv: $(cat "$DELTA" 2>/dev/null)"
grep -q "example-org/demo-os#42 @${H2:0:12}: since $G12: full protected:worker/jobs/schema.sql; a full lead review" "$L" && ok || bad "P3 no full line: $(cat "$L")"
[ "$(djobs 42)" = 1 ] && ok || bad "P3 jobs for 42=$(djobs 42) (want 1)"

echo "lead-delta-protected.bh-5582: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
