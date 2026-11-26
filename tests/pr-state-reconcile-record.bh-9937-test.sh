#!/bin/bash
# tests/pr-state-reconcile-record.bh-9937-test.sh — BH-9937 (BH-9926 wave 5):
# lane pr-state-reconcile on the PR record through its seam
# (bin/lib/prr-shadow.d/pr-state-reconcile.sh) and the per-PR wake gate
# (bin/lib/prr-seen.sh). The production script "$DIR/bin/pr-state-reconcile.sh"
# runs WHOLE (`tick`) in a scratch harness with the real jobs client and every
# lib it sources (scratch_install_closure). Stubbed:
#   * curl — the jobs worker: the gate facts fold of
#            tests/pr-state-reconcile.bh-4950-test.sh, plus GET /api/pr-records
#            (the open list from $T/rec-list.json, absent = 404; one row from
#            $T/rec-row/<n>.json, absent = no row). Every request is logged.
#   * gh   — the open list ($T/prs.json), one PR, its thread (a 500 on
#            $T/comments500/<n>), the CI reads and rate_limit. Every call is logged.
#   * the wake feed — $H/state/pr-snapshot/<repo>/changed.tsv and wakes.state,
#            in the format _prsw_refresh (bin/lib/pr-snapshot-wakes.sh) writes,
#            read by the REAL prs_wake_seen through wb_due.
# A "GitHub call" is every gh line except the budget check (`api rate_limit`)
# and the local credential lookup (`auth token`), the rule of the 4950 suite.
#
#   P1  record, 10 open PRs from a fresh record list: tick 2 with no wake makes
#       0 GitHub calls, and the summary says quiet=10 step=record
#   P2  one `pr` wake for #3: the next tick's GitHub calls all name #3
#   P3  one `checks` wake on #4's head: the next tick's GitHub calls name #4 only
#   P4  shadow, the record gives #2 another head: exactly 1 PRR_SHADOW line, the
#       head correction carries the GitHub head, and no mark is written
#   P5  off: 0 /api/pr-records calls, and the same GitHub calls as shadow
#   P6  record, a stale record list: 1 PRR_MISS ... why=stale fallback=github
#       and 1 GitHub list read
#   P7  record, a due PR whose thread read fails: no mark, read again next tick
#   P8  record, a db PR not in the list whose record says merged: closed=1 with
#       0 pulls/<n> reads
#   P9  record, a mark older than PRR_SEEN_BACKSTOP_S: the PR is read
#   P10 record, a quiet PR whose db CI is not green: ci_green_sha from the
#       record's checks, 0 GitHub calls
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-state-reconcile-record.bh-9937-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

unset GH_TOKEN
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp"
for f in bin/pr-state-reconcile.sh bin/jobs-client.sh bin/lib/prr-shadow.sh bin/lib/prr-seen.sh \
         bin/lib/prr-shadow.d/pr-state-reconcile.sh bin/lib/prr-ci-state.sh bin/lib/wake-backstop.sh \
         bin/lib/pr-snapshot.sh bin/lib/pr-snapshot-wakes.sh; do
  [ -f "$DIR/$f" ] || { bad "$f does not exist"; continue; }
  scratch_install_closure "$f" "$H" >/dev/null || bad "scratch_install_closure $f"
done

R=example-org/cromford
SD="$H/state/pr-snapshot/example-org_cromford"
SEEN="$H/state/prr-seen/pr-state-reconcile/example-org_cromford.tsv"
A=$(printf 'a%.0s' {1..40}); B=$(printf 'b%.0s' {1..40}); C=$(printf 'c%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
touch "$T/events.jsonl"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1 | sed 's/%2F/\//g'; }
code=200; out='{}'
case "\$m \$p" in
  "POST /api/pr-state-events")
    if jq -e --argjson b "\$body" 'select(.repo == \$b.repo and .number == \$b.number and .since == \$b.since)' "$T/events.jsonl" 2>/dev/null | grep -q .; then
      out='{"recorded":false,"duplicate":true}'
    else
      printf '%s\n' "\$body" >> "$T/events.jsonl"; code=201; out='{"recorded":true,"duplicate":false}'
    fi ;;
  "GET /api/pr-state/gate?"*)
    r=\$(qp repo)
    out=\$(jq -sc --arg r "\$r" '[.[] | select(.repo == \$r)] | group_by(.number)
      | map(. as \$e | reduce ("head","draft","closed","held","hotfix","ci_green_sha","builder_approved_sha","lead_verdict_sha","lead_verdict_word") as \$f
          ({repo: \$r, number: \$e[0].number}; .[\$f] = ([\$e[] | .[\$f] | select(. != null)] | last)))
      | {rows: ., as_of: "now"}' "$T/events.jsonl") ;;
  "GET /api/pr-records?"*"&number="*)
    n=\$(qp number)
    if [ -f "$T/rec-row/\$n.json" ]; then out=\$(cat "$T/rec-row/\$n.json"); else out='{"row":null,"age_s":null}'; fi ;;
  "GET /api/pr-records?"*"&state=open"*)
    if [ -f "$T/rec-list.json" ]; then out=\$(cat "$T/rec-list.json"); else code=404; out='{"error":"unknown endpoint"}'; fi ;;
  "GET /api/verdict?pr="*) code=404; out='{"error":"no job for this pr"}' ;;
  "GET /api/verdicts?"*) out='{"standing":null,"rows":[],"truncated":false}' ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/$R/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/$R/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    if [ -e "$T/closed/\$n" ]; then printf 'HTTP/2 200\r\n\r\n{"state":"closed","head":{"sha":"%s"}}\n' "$C"
    elif [ -f "$T/head/\$n" ]; then printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" '{state:"open",head:{sha:\$s},base:{ref:"main"}}'
    else printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; fi ;;
  *"-X GET repos/$R/issues/"*"/comments"*)
    a="\$*"; n="\${a##*/issues/}"; n="\${n%%/*}"
    if [ -e "$T/comments500/\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    else printf 'HTTP/2 200\r\n\r\n[]\n'; fi ;;
  *"actions/runs"*)
    a="\$*"; s="\${a##*head_sha=}"; s="\${s%%&*}"
    if [ -f "$T/ci/\$s" ]; then jq -nc --arg c "\$(cat "$T/ci/\$s")" '{workflow_runs:[{name:"Harness CI",status:"completed",conclusion:\$c,run_started_at:"2026-10-07T00:00:00Z"}]}'
    else echo '{"workflow_runs":[]}'; fi ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *) exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=$R \
  PR_STATE_RECONCILE_MAX_PER_SWEEP=30 PR_SNAPSHOT_TTL_S=600 HARNESS_TEST_SANDBOX=1
unset BOX_NAME JOBS_BOX HUB_BOX_NAME PR_SNAPSHOT GH_SOURCE PRR_SEEN_BACKSTOP_S WAKE_BACKSTOP WAKE_BACKSTOP_NOW

# sha <n> — a distinct 40-hex head for PR <n>
sha() { printf '%040x' "$1"; }
# pr <n> <head> — an open PR on GitHub at <head>
pr() {
  jq -c --argjson n "$1" --arg h "$2" '. + [{number:$n, html_url:("https://github.com/'"$R"'/pull/"+($n|tostring)),
    title:"t", draft:false, state:"open", user:{login:"operator",type:"User"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"},
    updated_at:"2026-10-07T00:00:00Z"}]' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"
}
# rec <n> <head> — the same PR in the record's open list
rec() {
  jq -c --argjson n "$1" --arg h "$2" '.rows += [{number:$n, head_sha:$h, base_ref:"main", draft:0,
    url:("https://github.com/'"$R"'/pull/"+($n|tostring)), updated_at:"2026-10-07T00:00:00Z"}]' "$T/rec-list.json" > "$T/rec.tmp" \
    && mv "$T/rec.tmp" "$T/rec-list.json"
}
rec_age() { jq -c --argjson a "$1" '.sync.age_s = $a' "$T/rec-list.json" > "$T/rec.tmp" && mv "$T/rec.tmp" "$T/rec-list.json"; }
# rec_row <n> <state> <head> [green] — one record row (pr_record_peek)
rec_row() {
  jq -nc --argjson n "$1" --arg s "$2" --arg h "$3" --arg g "${4:-}" '{row:({repo:"example-org/cromford", number:$n, state:$s, head_sha:$h}
    + (if $g == "" then {} else {checks:{"Harness CI":{status:"completed", conclusion:"success", sha:$h, at:"2026-10-07T00:00:00Z"}}} end)), age_s:5}' > "$T/rec-row/$1.json"
}
green() { echo success > "$T/ci/$1"; }
SEEDN=0
seed() { SEEDN=$((SEEDN + 1)); jq -nc --arg r "$R" --argjson n "$1" --argjson f "$2" --arg s "seed-$SEEDN" \
  '{repo:$r, number:$n, state:"gate", since:$s, reason:"seed"} + $f' >> "$T/events.jsonl"; }
# feed [kind:key:age-s]... — the wake mirror, complete and fresh, read now
feed() {
  local r k y a now i=100
  now=$(date +%s)  # determinism: ok the real prs_wake_seen bounds its window on the box clock
  mkdir -p "$SD"
  printf '%s\t1\t1\t%s\n' "$now" "$((now - 7200))" > "$SD/wakes.state"
  echo 500 > "$SD/wakes.wm"; : > "$SD/changed.tsv"
  for r in "$@"; do
    IFS=: read -r k y a <<<"$r"; i=$((i + 1))
    printf '%s\t%s\t%s\t%s\n' "$k" "$y" "$i" "$((now - a))" >> "$SD/changed.tsv"
  done
}
# backdate <age-s> [n] — every mark (or the mark of <n>) moved <age-s> into the past
backdate() {
  local now; now=$(date +%s)  # determinism: ok the marks hold the lane's own clock
  awk -F'\t' -v OFS='\t' -v e="$((now - $1))" -v n="${2:-}" '(n == "" || $1 == n) { $2 = e } { print }' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
}
reset() {
  rm -f "$T/log"/* "$T/events.jsonl" "$H/logs"/* "$T/rec-list.json"
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in head closed comments500 ci rec-row; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/prs.json"; : > "$T/events.jsonl"
  echo '{"rows":[],"truncated":false,"sync":{"age_s":5,"synced_at":"2026-11-25T00:00:00Z"},"missing":null,"unknown":0}' > "$T/rec-list.json"
  feed
}
tick() { ( cd "$T" && bash "$H/bin/pr-state-reconcile.sh" tick ) > "$T/out" 2>&1; RC=$?; }
quietlogs() { rm -f "$T/log/gh" "$T/log/worker"; }
LOGF="$H/logs/pr-state-reconcile.log"
SHADOW="$H/logs/prr-shadow.log"
summ() { grep ' checked=' "$LOGF" 2>/dev/null | tail -1; }
num() { summ | sed -n "s/.* $1=\([0-9]*\).*/\1/p"; }
recon_rows() { jq -sc '[.[] | select(.reason == "reconcile") | del(.repo, .state, .actor)]' "$T/events.jsonl"; }
GH_NOT_READS='api rate_limit|^auth token$'
ghlines() { grep -vE "$GH_NOT_READS" "$T/log/gh" 2>/dev/null; }
ghreads() { ghlines | grep -c . ; }
prrecs() { grep -c ' /api/pr-records' "$T/log/worker" 2>/dev/null; }

# ── P1: record, 10 unchanged PRs: tick 2 makes 0 GitHub calls ──
reset
for n in 1 2 3 4 5 6 7 8 9 10; do pr "$n" "$(sha "$n")"; rec "$n" "$(sha "$n")"; green "$(sha "$n")"; done
GH_SOURCE=record tick
[ "$RC" = 0 ] && ok || bad "P1 tick 1 rc=$RC $(cat "$T/out")"
[ "$(wc -l < "$SEEN" 2>/dev/null)" = 10 ] && ok || bad "P1 tick 1 must mark the 10 PRs it read: $(cat "$SEEN" 2>/dev/null)"
grep -q 'pulls?' <<<"$(ghlines)" && bad "P1 tick 1 read the GitHub list on a fresh record list" || ok
backdate 600; quietlogs; GH_SOURCE=record tick
[ "$(ghreads)" = 0 ] && ok || bad "P1 tick 2 want 0 GitHub calls, got $(ghreads): $(ghlines | head -5)"
summ | grep -q ' quiet=10 step=record$' && ok || bad "P1 summary: $(summ)"
[ "$(num checked)" = 10 ] && [ "$(num corrected)" = 0 ] && ok || bad "P1 tick 2 summary: $(summ)"

# ── P2: one pr wake for #3: the tick reads only #3 ──
feed "pr:3:300"; quietlogs; GH_SOURCE=record tick
[ "$(ghreads)" -ge 1 ] && ok || bad "P2 the woken PR was not read: $(summ)"
[ "$(ghlines | grep -vcE "/(pulls|issues)/3([/ ?]|$)")" = 0 ] && ok || bad "P2 a call names another PR: $(ghlines)"
summ | grep -q ' quiet=9 step=record$' && ok || bad "P2 summary: $(summ)"

# ── P3: one checks wake on #4's head: the tick reads only #4 ──
feed "pr:3:300" "checks:$(sha 4):300"; quietlogs; GH_SOURCE=record tick
[ "$(ghreads)" -ge 1 ] && ok || bad "P3 the woken PR was not read: $(summ)"
[ "$(ghlines | grep -vcE "/(pulls|issues)/4([/ ?]|$)")" = 0 ] && ok || bad "P3 a call names another PR: $(ghlines)"

# ── P4: shadow, a forced mismatch: 1 PRR_SHADOW line, the lane acts on GitHub ──
reset; pr 1 "$(sha 1)"; rec 1 "$(sha 1)"; pr 2 "$B"; rec 2 "$C"; seed 2 "{\"head\":\"$A\"}"
GH_SOURCE=shadow tick
[ "$RC" = 0 ] && ok || bad "P4 rc=$RC $(cat "$T/out")"
[ "$(grep -c 'PRR_SHADOW lane=pr-state-reconcile' "$SHADOW" 2>/dev/null)" = 1 ] && ok || bad "P4 want exactly 1 PRR_SHADOW line: $(cat "$SHADOW" 2>/dev/null)"
grep -q "PRR_SHADOW lane=pr-state-reconcile key=$R#open .* changed=1" "$SHADOW" 2>/dev/null && ok || bad "P4 the line must name the list key and 1 changed PR: $(cat "$SHADOW" 2>/dev/null)"
[ "$(recon_rows | jq -r '[.[] | select(.number == 2 and .head != null) | .head] | join(",")')" = "$B" ] && ok || bad "P4 the head correction must carry the GitHub head: $(recon_rows)"
[ ! -e "$SEEN" ] && ok || bad "P4 shadow must write no mark: $(cat "$SEEN")"
cp "$T/log/gh" "$T/gh.shadow"; SHADOW_RECS=$(prrecs)

# ── P5: off: 0 record calls, and the GitHub calls of shadow ──
reset; pr 1 "$(sha 1)"; rec 1 "$(sha 1)"; pr 2 "$B"; rec 2 "$C"; seed 2 "{\"head\":\"$A\"}"
GH_SOURCE=off tick
[ "$(prrecs)" = 0 ] && ok || bad "P5 off made $(prrecs) /api/pr-records calls"
[ "${SHADOW_RECS:-0}" -ge 1 ] && ok || bad "P5 control: shadow made no /api/pr-records call"
[ "$(grep -vE "$GH_NOT_READS" "$T/log/gh" | sort)" = "$(grep -vE "$GH_NOT_READS" "$T/gh.shadow" | sort)" ] && ok \
  || bad "P5 off and shadow must make the same GitHub calls: off=$(ghlines | tr '\n' '|') shadow=$(grep -vE "$GH_NOT_READS" "$T/gh.shadow" | tr '\n' '|')"
[ ! -s "$SHADOW" ] && ok || bad "P5 off must log no PRR line: $(cat "$SHADOW")"

# ── P6: record, a stale record list: PRR_MISS and one GitHub list read ──
reset; pr 1 "$(sha 1)"; rec 1 "$(sha 1)"; rec_age 99999
GH_SOURCE=record tick
grep -q "PRR_MISS lane=pr-state-reconcile key=$R#open why=stale fallback=github" "$SHADOW" 2>/dev/null && ok || bad "P6 no PRR_MISS stale line: $(cat "$SHADOW" 2>/dev/null)"
[ "$(ghlines | grep -c 'pulls?')" = 1 ] && ok || bad "P6 want 1 GitHub list read: $(ghlines)"

# ── P7: record, a due PR whose thread read fails: no mark, read again ──
reset; pr 5 "$(sha 5)"; rec 5 "$(sha 5)"; touch "$T/comments500/5"
GH_SOURCE=record tick
ghlines | grep -q "/pulls/5" && ok || bad "P7 tick 1 did not read #5: $(ghlines)"
grep -q '^5	' "$SEEN" 2>/dev/null && bad "P7 an unread thread wrote a mark: $(cat "$SEEN")" || ok
[ "$(num skipped)" -ge 1 ] 2>/dev/null && ok || bad "P7 want skipped>=1: $(summ)"
quietlogs; GH_SOURCE=record tick
ghlines | grep -q "/pulls/5" && ok || bad "P7 tick 2 must read #5 again: $(ghlines)"

# ── P8: record, a db PR not in the list whose record says merged ──
reset; pr 7 "$(sha 7)"; rec 7 "$(sha 7)"; seed 9 "{\"head\":\"$C\",\"closed\":0}"; rec_row 9 merged "$C"
GH_SOURCE=record tick
[ "$(recon_rows | jq -c '[.[] | select(.number == 9) | .closed]')" = "[1]" ] && ok || bad "P8 want closed=1 on 9: $(recon_rows)"
grep -q '/pulls/9' <<<"$(ghlines)" && bad "P8 read pulls/9 on GitHub: $(ghlines)" || ok

# ── P9: record, a mark older than the backstop: the PR is read ──
reset; pr 6 "$(sha 6)"; rec 6 "$(sha 6)"; green "$(sha 6)"
GH_SOURCE=record tick
backdate 600; quietlogs; GH_SOURCE=record tick
[ "$(ghreads)" = 0 ] && ok || bad "P9 control: a 600 s mark must be quiet: $(ghlines)"
backdate 2000; quietlogs; GH_SOURCE=record tick
ghlines | grep -q '/pulls/6' && ok || bad "P9 a mark older than 1800 s must read #6: $(ghlines)"

# ── P10: record, a quiet PR whose db CI is not green: CI from the record ──
reset; pr 4 "$(sha 4)"; rec 4 "$(sha 4)"
GH_SOURCE=record tick
[ "$(recon_rows | jq -c '[.[] | select(.ci_green_sha != null)] | length')" = 0 ] && ok || bad "P10 tick 1 must not see green CI: $(recon_rows)"
rec_row 4 open "$(sha 4)" green
backdate 600; quietlogs; GH_SOURCE=record tick
[ "$(ghreads)" = 0 ] && ok || bad "P10 a quiet PR made GitHub calls: $(ghlines)"
[ "$(recon_rows | jq -r '[.[] | select(.number == 4 and .ci_green_sha != null) | .ci_green_sha] | join(",")')" = "$(sha 4)" ] \
  && ok || bad "P10 ci_green_sha must come from the record's checks: $(recon_rows)"

echo "pr-state-reconcile-record.bh-9937: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
