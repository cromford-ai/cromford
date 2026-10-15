#!/bin/bash
# tests/lead-block-fix-round.bh-3780-test.sh — BH-3780: a lead BLOCK gets a fix
# round; the same finding twice, or a `needs-human` finding, holds the ticket.
#
# THE INCIDENT (#3722). bin/lead-review-land.sh posted the lead's findings as a
# REQUEST_CHANGES review, exactly as BH-3547 designed it, but under the hub's
# default gh identity: the App, so `cromford[bot]`, user.type Bot,
# author_association NONE. The only thing that turns a lead review into a fix
# round, br_lead_pick in bin/blocked-resolver.sh, dropped every Bot row and every
# NONE association, so nothing acted on the BLOCK. BH-3479's suite was green
# because its fake gh posted as operator/OWNER (fixture luck, D4). Every fixture
# below posts as the identity prod produced.
#
#   P1-P8  the REAL br_lead_pick (lifted from bin/blocked-resolver.sh, with the
#          real bin/lib/gh-pr-list.sh trust set) on the App-authored marker
#          review and its adversarial negatives. P1_BASE=1 lifts it from
#          origin/main instead: P1 must FAIL there (the red on main).
#   L1-L6  the REAL bin/lead-review-land.sh in a scratch harness: the
#          needs-human route, its failure modes, and a protected-path PR.
#   T1-T6  the same-finding tripwire, through the same lane.
#   E1-E4  the REAL bin/blocked-resolver.sh, whole, against a real git remote:
#          one fix round per head from the App's marker review, nothing on the
#          same head again, nothing from the old review on the pushed head, and
#          nothing while the ticket waits on a human.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-block-fix-round.bh-3780-test.sh
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

BR="$DIR/bin/blocked-resolver.sh"
LRL="$DIR/bin/lead-review-land.sh"
LEAD_HDR='LEAD FINDINGS — every item must be addressed in code'
APP='cromford[bot]'

# ============================================================================
# P — br_lead_pick on the land lane's own review
# ============================================================================
PH="$T/ph"; mkdir -p "$PH/env" "$PH/logs" "$PH/state/gh-etag" "$T/pc"
if [ "${P1_BASE:-}" = 1 ]; then
  git -C "$DIR" show origin/main:bin/blocked-resolver.sh > "$T/br-src.sh" || { echo "P1_BASE: origin/main unreadable"; exit 1; }
else
  cp "$BR" "$T/br-src.sh"
fi
plift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$T/br-src.sh"; }
{ grep -E '^(BR_REVIEW_FOOTER|BR_LEAD_HDR)=' "$T/br-src.sh"; plift br_lead_merges_only; plift br_lead_pick; } > "$T/pick.sh"
grep -q '^br_lead_pick() {' "$T/pick.sh" && ok || bad "P0 br_lead_pick could not be lifted"
# gh_rest for the compare reads only, answered from $T/pc/compare-<a>-<b>.json (404 when absent).
cat > "$T/pick-stubs.sh" <<EOF
gh_rest() {
  local p="\$2" c
  case "\$p" in
    */compare/*) c=\$(printf '%s' "\${p##*/compare/}" | sed 's#\.\.\.#-#')
                 [ -f "$T/pc/compare-\$c.json" ] || return 44
                 cat "$T/pc/compare-\$c.json" ;;
    *) return 75 ;;
  esac
}
EOF
# PICK <head> <rows-json> — the real picker, the real trust set (bin/lib/gh-pr-list.sh).
PICK() {
  HARNESS="$PH" bash -c '. "$1/bin/lib/gh-pr-list.sh"; . "$2"; . "$3"; br_lead_pick o/demo "$4" "$5"' \
    _ "$DIR" "$T/pick-stubs.sh" "$T/pick.sh" "$1" "$2"
}
# PICK_RC <head> <rows-json> — rc only
PICK_RC() { PICK "$@" >/dev/null 2>&1; echo $?; }
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
# The body bin/lead-review-land.sh really posts: marker, framing line, the report.
MBODY() { # MBODY <id> <head> [extra finding line]
  printf '<!-- lead-review:%s -->\nLead review (automated lead-review lane, stub-model) of %s\n\n# Lead review lr-7 (o/demo#7 at %s)\n\nFindings\n- [BLOCK] a.sh:3: the retry loop never stops\n%s\nVERDICT: BLOCK\n' \
    "$1" "${2:0:12}" "$2" "${3:-}"
}
ROW() { # ROW <login> <type> <assoc> <commit> <state> <body> — one br_review_rows row
  jq -nc --arg l "$1" --arg t "$2" --arg a "$3" --arg c "$4" --arg s "$5" --arg b "$6" '{l:$l,t:$t,a:$a,c:$c,s:$s,b:$b}'
}
ROWS() { jq -sc . ; }

# P1: the App's CHANGES_REQUESTED marker review on the head is the brief.
R=$(ROW "$APP" Bot NONE "$H1" CHANGES_REQUESTED "$(MBODY lr-1 "$H1")" | ROWS)
OUT=$(PICK "$H1" "$R"); RC=$?
if [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | base64 -d 2>/dev/null | head -1)" = "$LEAD_HDR" ] \
   && printf '%s' "$OUT" | base64 -d 2>/dev/null | grep -qF -- '- [BLOCK] a.sh:3: the retry loop never stops'; then ok
else bad "P1 the App-authored lead BLOCK must brief a framed round (rc $RC): $(printf '%s' "$OUT" | base64 -d 2>/dev/null | head -3)"; fi
if [ "${P1_BASE:-}" = 1 ]; then
  echo "lead-block-fix-round.bh-3780 (P1_BASE, br_lead_pick from origin/main): $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# P2: the same body from the builders App, or an outsider with NONE, is never a brief.
R=$(ROW 'cromford-builders[bot]' Bot NONE "$H1" CHANGES_REQUESTED "$(MBODY lr-1 "$H1")" | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 1 ] && ok || bad "P2 the builders App's marker review must never brief"
R=$(ROW mallory User NONE "$H1" CHANGES_REQUESTED "$(MBODY lr-1 "$H1")" | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 1 ] && ok || bad "P2 an outsider (NONE) pasting the marker must never brief"
# P3: a footer review quoting the marker is the review lane's, not a lead brief.
R=$(ROW "$APP" Bot NONE "$H1" CHANGES_REQUESTED "$(MBODY lr-1 "$H1")
---
_Automated harness review (Fable) of $H1._" | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 1 ] && ok || bad "P3 a footer review quoting the marker must never be a lead brief"
# P4: a needs-human finding never briefs a round.
R=$(ROW "$APP" Bot NONE "$H1" CHANGES_REQUESTED "$(MBODY lr-1 "$H1" '- [BLOCK needs-human] cfg.sh:1: which vendor tier do we buy')" | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 1 ] && ok || bad "P4 a [BLOCK needs-human] marker review must never brief a round"
# P5: a DISMISSED marker review is not standing.
R=$( { ROW "$APP" Bot NONE "$H1" CHANGES_REQUESTED "$(MBODY lr-1 "$H1")"; ROW "$APP" Bot NONE "$H1" DISMISSED "$(MBODY lr-1 "$H1")"; } | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 1 ] && ok || bad "P5 a DISMISSED marker review must not brief"
# P6: on H1, then a real commit to H2: not a brief for H2; merge-only commits: still one.
jq -nc '{status:"ahead", commits:[{sha:"fix1", parents:[{sha:"p"}]}]}' > "$T/pc/compare-$H1-$H2.json"
jq -nc '{status:"ahead", commits:[{sha:"own1", parents:[{sha:"p"}]}, {sha:"fix1", parents:[{sha:"p"}]}]}' > "$T/pc/compare-main-$H2.json"
R=$(ROW "$APP" Bot NONE "$H1" CHANGES_REQUESTED "$(MBODY lr-1 "$H1")" | ROWS)
[ "$(PICK_RC "$H2" "$R")" = 1 ] && ok || bad "P6 a marker review on an older head followed by a real commit must not brief the new head"
jq -nc '{status:"ahead", commits:[{sha:"mergeA", parents:[{sha:"p"},{sha:"q"}]}]}' > "$T/pc/compare-$H1-$H2.json"
jq -nc '{status:"ahead", commits:[{sha:"own1", parents:[{sha:"p"}]}, {sha:"mergeA", parents:[{sha:"p"},{sha:"q"}]}]}' > "$T/pc/compare-main-$H2.json"
[ "$(PICK_RC "$H2" "$R")" = 0 ] && ok || bad "P6 a marker review followed only by a main merge still briefs"
# P7: a later App APPROVE (the review lane's footer verdict) does not lift the lead's BLOCK.
R=$( { ROW "$APP" Bot NONE "$H1" CHANGES_REQUESTED "$(MBODY lr-1 "$H1")"
       ROW "$APP" Bot NONE "$H1" APPROVED "LGTM
TIER: 1
VERDICT: APPROVE
---
_Automated harness review (Fable) of $H1._"; } | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 0 ] && ok || bad "P7 the App's review-lane APPROVE must not hide a standing lead BLOCK"
# P8: a COMMENT-state marker review (the 422 fallback) briefs nothing.
R=$(ROW "$APP" Bot NONE "$H1" COMMENTED "$(MBODY lr-1 "$H1")" | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 1 ] && ok || bad "P8 a COMMENT-state marker review must not brief"
# A person's review keeps the old path: operator/OWNER without a marker still briefs,
# a [bot] login without the marker still does not.
R=$(ROW operator User OWNER "$H1" CHANGES_REQUESTED "1. a.sh:3 fix it" | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 0 ] && ok || bad "P9 a lead's own (OWNER) review must still brief"
R=$(ROW "$APP" Bot NONE "$H1" CHANGES_REQUESTED "1. a.sh:3 fix it" | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 1 ] && ok || bad "P9 an App review without the lead marker must still never be a lead brief"
# A lifted copy with no trust set fails closed on the App's row.
R=$(ROW "$APP" Bot NONE "$H1" CHANGES_REQUESTED "$(MBODY lr-1 "$H1")" | ROWS)
NRC=$(bash -c '. "$1"; . "$2"; br_lead_pick o/demo "$3" "$4" >/dev/null 2>&1; echo $?' _ "$T/pick-stubs.sh" "$T/pick.sh" "$H1" "$R")
[ "$NRC" = 1 ] && ok || bad "P10 with no harness_verdict_author_match the App's row must be skipped (rc $NRC)"

# ============================================================================
# L / T — the real bin/lead-review-land.sh
# ============================================================================
SHA=$(printf 'a%.0s' {1..40})
SHA2=$(printf 'b%.0s' {1..40})
SHA3=$(printf 'c%.0s' {1..40})
SLUG=example-org/demo-os
mkdir -p "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/needs-human" "$H/state" "$H/logs"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/lead-verdict.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for f in env-path lead-reviews verdicts hub-box lane-gate gh-rest gh-app-auth verdict-status lead-authority needs-human; do cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"; done
cp "$DIR"/bin/lib/needs-human/*.sh "$H/bin/lib/needs-human/"
# The lead_protected_paths rows (tests/lib/lpp-stub.sh): none for $SLUG until L6
# adds one; $T/lpp-down is never created here.
LPP="$T/lpp.json"; printf '{"rows":[]}' > "$LPP"
lpp_install "$T/fakebin" "$LPP" "$T/lpp-down"
cp "$LRL" "$H/bin/lead-review-land.sh"
echo box-hub > "$H/state/box-name"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/log/alerts" > "$H/bin/lane-alert.sh"
# alert-line: every call recorded, one line each.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/log/alertline" > "$H/bin/alert-line.sh"
# The placer: argv recorded (and its place in the call order), its rc from
# $T/placer-rc; on rc 0 it sends ITS one ask through alert-line, as step 8 does.
cat > "$H/bin/needs-human-hold.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/placer"
printf 'placer\n' >> "$T/log/seq"
rc=0; [ -f "$T/placer-rc" ] && rc=\$(cat "$T/placer-rc")
[ "\$rc" = 0 ] && "\$(dirname "\$0")/alert-line.sh" --project "\$1" "[needs-human] \$1#\$2 needs a human: \$4"
exit "\$rc"
EOF
# fleet.conf: one project, demo, on example-org/demo-os; its board prefix from $T/bp (default "-").
cat > "$H/bin/fleet-conf.sh" <<EOF
#!/bin/bash
case "\$1" in
  --projects) echo demo ;;
  demo) case "\$2" in repo) echo $SLUG ;; board_prefix) cat "$T/bp" 2>/dev/null || echo - ;; *) echo - ;; esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$H/bin/"*.sh

cat > "$T/fakebin/curl" <<'EOF'
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
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"$hdrs" && lead=1
p="${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "$m" "$p" "$body" "$lead" >> "@T@/log/worker"
printf 'worker %s %s\n' "$m" "${p%%\?*}" >> "@T@/log/seq"
[ -f "@T@/vrows.json" ] || echo '[]' > "@T@/vrows.json"
[ -f "@T@/ledger.json" ] || echo '{}' > "@T@/ledger.json"
qp() { printf '%s' "${p#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
urid() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"; }
code=200; out='{}'
case "$m $p" in
  # TEST-CHANGE BH-4145: default mode is now lane; this suite pins human-mode behaviour
  "GET /api/settings/lead_authority_mode") out='{"setting":{"key":"lead_authority_mode","value":"human"}}' ;;
  "GET /api/lead-reviews"*) out=$(cat "@T@/requests.json") ;;
  *"/api/lead-protected-paths"*) lpp-answer "$m" "$url" "$body"; exit 0 ;;
  "POST /api/lead-reviews/"*/promoted)
    if [ "$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"request":{"promoted_verdict_at":"2026-09-29T00:00:00Z"}}'; fi ;;
  "GET /api/jobs/"*/artifacts)
    j="${p#/api/jobs/}"; j="${j%/artifacts}"
    if [ -f "@T@/artifacts-$j.json" ]; then out=$(cat "@T@/artifacts-$j.json")
    else out='{"artifacts":[]}'; fi ;;
  "POST /api/verdicts")
    n=$(jq length "@T@/vrows.json")
    row=$(jq -c --argjson id "$((n + 1))" '. + {id:$id, created_at:"2026-09-29T00:00:00Z"}' <<<"$body")
    jq -c --argjson r "$row" '. + [$r]' "@T@/vrows.json" > "@T@/vrows.tmp" && mv "@T@/vrows.tmp" "@T@/vrows.json"
    code=201; out=$(jq -c '{verdict:.}' <<<"$row") ;;
  "GET /api/verdicts?"*)
    out=$(jq -c --arg r "$(qp repo)" --argjson pr "$(qp pr)" --arg h "$(qp head)" '
      [.[] | select(.repo == $r and .pr == $pr)] | sort_by(-.id) as $rows
      | {repo:$r, pr:$pr, head:$h, standing:([$rows[] | select(.head_sha == $h and .source == "lead")] | first),
         rows:$rows, truncated:false}' "@T@/vrows.json") ;;
  # The D1 ledger (job_ledger_row / job_ledger_put): rows keyed "<kind>|<key>"; 500 on $T/ledger500.
  "GET /api/ledger?"*)
    if [ -e "@T@/ledger500" ]; then code=500; out='{"error":"boom"}'
    else
      k="$(urid "$(qp kind)")|$(urid "$(qp key)")"
      if jq -e --arg k "$k" 'has($k)' "@T@/ledger.json" >/dev/null; then out=$(jq -c --arg k "$k" '{ledger:.[$k]}' "@T@/ledger.json")
      else code=404; out='{"error":"not found"}'; fi
    fi ;;
  "PUT /api/ledger")
    if [ -e "@T@/ledger500" ]; then code=500; out='{"error":"boom"}'
    else
      k="$(jq -r '.kind' <<<"$body")|$(jq -r '.key' <<<"$body")"
      jq -c --arg k "$k" --argjson r "$body" '.[$k] = $r' "@T@/ledger.json" > "@T@/ledger.tmp" && mv "@T@/ledger.tmp" "@T@/ledger.json"
      out='{"ok":true}'
    fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "$out" "$code"
EOF

# GitHub. A reviews POST appends a review AS THE APP (cromford[bot], Bot,
# NONE): the identity the hub's default gh posts with in prod.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
m=GET; path=""; prev=""; ev=""; cid=""; body=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    -f|-F) v="${a#*=}"; case "$v" in @*) v=$(cat "${v#@}") ;; esac
           case "${a%%=*}" in event) ev="$v" ;; commit_id) cid="$v" ;; body) body="$v" ;; esac ;;
  esac
  case "$a" in repos/*) path="$a" ;; esac
  prev="$a"
done
printf '%s %s event=%s commit_id=%s\n' "$m" "$path" "$ev" "$cid" >> "@T@/log/gh"
printf 'gh %s %s\n' "$m" "${path%%\?*}" >> "@T@/log/seq"
reply() { printf 'HTTP/1.1 %s X\r\n\r\n%s\n' "$1" "$2"; exit 0; }
n=$(printf '%s' "$path" | sed -nE 's#^repos/[^/]+/[^/]+/pulls/([0-9]+).*#\1#p')
rf="@T@/reviews-$n.json"
case "$m $path" in
  "PUT repos/"*"/pulls/"*"/reviews/"*"/dismissals")
    rid=$(printf '%s' "$path" | sed -nE 's#.*/reviews/([0-9]+)/dismissals$#\1#p')
    jq -c --argjson i "$rid" 'map(if .id == $i then .state = "DISMISSED" else . end)' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    reply 200 '{"state":"DISMISSED"}' ;;
  "POST repos/"*"/pulls/"*"/reviews")
    printf '%s' "$body" > "@T@/log/body-$n-$(wc -l < "@T@/log/gh" | tr -d ' ')"
    case "$ev" in REQUEST_CHANGES) s=CHANGES_REQUESTED ;; COMMENT) s=COMMENTED ;; APPROVE) s=APPROVED ;; *) s=PENDING ;; esac
    [ -f "$rf" ] || echo '[]' > "$rf"
    jq -c --arg c "$cid" --arg s "$s" --arg b "$body" \
      '. + [{id:(length + 1), user:{login:"cromford[bot]",type:"Bot"}, author_association:"NONE", commit_id:$c, state:$s, body:$b}]' \
      "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    reply 200 '{"id":1}' ;;
  "GET repos/"*"/pulls/"*"/reviews"*)
    case "$path" in *"page=1"|*"page=1&"*) ;; *) reply 200 '[]' ;; esac
    if [ -f "$rf" ]; then reply 200 "$(cat "$rf")"; else reply 200 '[]'; fi ;;
  "GET repos/"*"/pulls/"*"/files"*)
    case "$path" in *"page=1"|*"page=1&"*) ;; *) reply 200 '[]' ;; esac
    reply 200 "$(cat "@T@/files-$n.json" 2>/dev/null || echo '[]')" ;;
  "GET repos/"*"/pulls/"*)
    h="@SHA@"; [ -f "@T@/head-$n" ] && h=$(cat "@T@/head-$n")
    b="ticket/bh-77"; [ -f "@T@/branch-$n" ] && b=$(cat "@T@/branch-$n")
    reply 200 "{\"head\":{\"sha\":\"$h\",\"ref\":\"$b\"}}" ;;
  "POST repos/"*"/statuses/"*) reply 201 '{"id":1}' ;;
esac
exit 0
EOF
sed -i "s#@T@#$T#g; s#@SHA@#$SHA#g" "$T/fakebin/curl" "$T/fakebin/gh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

req() { # req <id> <status> <verdict> [pr] [head] [job_id]
  jq -nc --arg i "$1" --arg s "$2" --arg v "$3" --argjson pr "${4:-7}" --arg h "${5:-$SHA}" --arg j "${6-j1}" \
    '{id:$i, repo:"example-org/demo-os", pr:$pr, head_sha:$h, status:$s,
      verdict:(if $v == "null" then null else $v end), reviewer_model:"stub-model",
      report_ref:("state/lead-reviews/lr-\($pr)-" + $h[0:12] + ".md"), promoted_verdict_at:null,
      job_id:(if $j == "" then null else $j end), box:"box-demo",
      detail:null, created_at:"2026-09-29T00:00:00Z", updated_at:"2026-09-29T00:00:00Z"}'
}
setreqs() { printf '%s\n' "$@" | jq -sc '{requests:., truncated:false}' > "$T/requests.json"; }
art() { # art <job> <head> <findings...> — the lead_review_report artifact for repo#7 at <head>
  local j="$1" h="$2" b; shift 2
  b="# Lead review lr-7-${h:0:12} ($SLUG#7 at $h)

Findings
$(printf '%s\n' "$@")

VERDICT: BLOCK"
  jq -nc --arg b "$b" '{body:$b, path:"state/lead-reviews/report.md", verdict:"BLOCK"}' \
    | jq -Rc '{artifacts:[{artifact_kind:"lead_review_report", artifact_ref:"state/lead-reviews/report.md", phase_id:null, detail:.}]}' \
    > "$T/artifacts-$j.json"
}
F_A='- [BLOCK] a.sh:3: the retry loop never stops when the worker answers 500'
F_A2='- [BLOCK] a.sh:41: the retry loop never stops when the worker answers 500'
F_B='- [BLOCK] b.sh:9: the cache key ignores the tenant id'
F_N='- [NOTE] c.sh:2: a clearer name would help'
F_NH='- [BLOCK needs-human] cfg/vendor.sh:12: which paid vendor tier we buy is a product call, not code'
reset() {
  scratch_rm "$T/log"
  rm -f "$T"/{vrows.json,ledger.json,ledger500,placer-rc,bp} "$T"/reviews-*.json "$T"/artifacts-*.json "$T"/head-* "$T"/branch-* "$T"/files-*.json
  mkdir -p "$T/log"; : > "$T/log/gh"; : > "$T/log/worker"; : > "$T/log/alerts"; : > "$T/log/seq"; : > "$T/log/placer"; : > "$T/log/alertline"
  rm -f "$H/logs/lead-review-land.log" "$H/logs/ALERTS.log" "$H/logs/needs-human.log"
  scratch_rm "$H/state/lead-review-land"; scratch_rm "$H/state/lead-authority"
  setreqs "$(req lr-1 done BLOCK)"
  art j1 "$SHA" "$F_A"
}
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" GH_ETAG=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME LEAD_REVIEW_SPOTCHECK_PCT NEEDS_HUMAN_TRIP_COUNT
tick() { ( cd "$T" && bash "$H/bin/lead-review-land.sh" ) > "$T/out" 2>&1; RC=$?; }
rposts() { grep -c "^POST repos/$SLUG/pulls/7/reviews " "$T/log/gh" 2>/dev/null; }
stamps() { grep -c "^POST /api/lead-reviews/${1:-lr-1}/promoted " "$T/log/worker" 2>/dev/null; }
placers() { grep -c . "$T/log/placer" 2>/dev/null; }
alines() { grep -c . "$T/log/alertline" 2>/dev/null; }
lastbody() { local f; f=$(ls -1 "$T/log" 2>/dev/null | grep '^body-7-' | sort -t- -k3 -n | tail -1); [ -n "$f" ] && cat "$T/log/$f"; }
LOGF() { cat "$H/logs/lead-review-land.log" 2>/dev/null; }
# PICKED <head> — br_lead_pick's rc on the PR's reviews as the lane left them.
PICKED() {
  local rows
  rows=$(jq -c '[ .[] | {l:(.user.login // ""), t:(.user.type // ""), a:(.author_association // ""), c:(.commit_id // ""), s:(.state // ""), b:(.body // "")} ]' "$T/reviews-7.json" 2>/dev/null)
  PICK_RC "$1" "${rows:-[]}"
}
ledger_n() { jq -r '[.[] | select(.kind == "review_block_fp")] | map(.status | tonumber) | join(",")' "$T/ledger.json" 2>/dev/null; }
ledger_keys() { jq -r '[.[] | select(.kind == "review_block_fp")] | length' "$T/ledger.json" 2>/dev/null; }
# land_head <id> <head> <findings...> — the PR moves to <head> and its lead review lands.
land_head() {
  local id="$1" h="$2"; shift 2
  echo "$h" > "$T/head-7"; art "j-$id" "$h" "$@"
  setreqs "$(req "$id" done BLOCK 7 "$h" "j-$id")"; tick
}

# ── L1: a needs-human finding -> the hold first, then the review, which briefs nothing ──
reset; art j1 "$SHA" "$F_A" "$F_NH"; tick
[ "$RC" = 0 ] && ok || bad "L1 rc=$RC out=$(cat "$T/out")"
[ "$(placers)" = 1 ] && ok || bad "L1 want one placer call, got $(placers): $(cat "$T/log/placer")"
PA=$(cat "$T/log/placer")
case "$PA" in
  "demo 77 "*" lead review of $SLUG#7 @${SHA:0:12}: cfg/vendor.sh:12: which paid vendor tier we buy is a product call, not code lead-review") ok ;;
  *) bad "L1 the placer argv is not <project> <issue> <fp> <action> lead-review: $PA" ;;
esac
[[ "$(cut -d' ' -f3 <<<"$PA")" =~ ^[0-9a-f]{12}$ ]] && ok || bad "L1 the fp is not 12 hex: $PA"
order=$(awk '/^placer$/{print "hold"} /^gh POST .*\/reviews$/{print "review"} /^worker POST \/api\/lead-reviews\/lr-1\/promoted$/{print "stamp"}' "$T/log/seq" | paste -sd' ')
[ "$order" = "hold review stamp" ] && ok || bad "L1 order '$order' (want hold review stamp)"
[ "$(rposts)" = 1 ] && [ "$(stamps)" = 1 ] && ok || bad "L1 posts=$(rposts) stamps=$(stamps)"
[ "$(PICKED "$SHA")" = 1 ] && ok || bad "L1 the posted needs-human review must not brief a round"
LOGF | grep -q 'needs-human hold placed on demo#77' && ok || bad "L1 not logged: $(LOGF | tail -2)"
grep -q 'tripwire' <(LOGF) && bad "L1 a needs-human route must skip the tripwire: $(LOGF | grep tripwire)" || ok
# rerun with the findings flag gone: the marker dedupes, and the nh flag keeps the placer quiet
rm -f "$H/state/lead-review-land/findings-lr-1"; : > "$T/log/placer"; setreqs "$(req lr-1 done BLOCK)"; tick
[ "$(placers)" = 0 ] && ok || bad "L1 a rerun called the placer again ($(placers))"

# ── L2: the placer cannot read the thread (75) -> nothing posted, nothing stamped; then heals ──
reset; art j1 "$SHA" "$F_NH"; echo 75 > "$T/placer-rc"; tick
[ "$(rposts)" = 0 ] && [ "$(stamps)" = 0 ] && ok || bad "L2 posted/stamped past a placer rc 75 (posts=$(rposts) stamps=$(stamps))"
[ -e "$H/state/lead-review-land/nh-lr-1" ] && bad "L2 flagged nh after rc 75" || ok
LOGF | grep -q 'placer rc 75); findings not posted, not stamped' && ok || bad "L2 not logged: $(LOGF | tail -2)"
rm -f "$T/placer-rc"; tick
[ "$(rposts)" = 1 ] && [ "$(stamps)" = 1 ] && [ "$(placers)" = 2 ] && ok || bad "L2 the retry did not place+post+stamp (posts=$(rposts) stamps=$(stamps) placers=$(placers))"
# ...and a placer that could not place (rc 1, it alerted) still lets the review post
reset; art j1 "$SHA" "$F_NH"; echo 1 > "$T/placer-rc"; tick
[ "$(rposts)" = 1 ] && [ "$(stamps)" = 1 ] && ok || bad "L2 placer rc 1 must still post (posts=$(rposts))"
[ "$(PICKED "$SHA")" = 1 ] && ok || bad "L2 a needs-human review posted after a failed hold must still brief nothing"

# ── L3: no ticket in the branch -> ONE warn alert-line, the review is posted ──
reset; art j1 "$SHA" "$F_NH"; echo feature/x > "$T/branch-7"; tick
[ "$(placers)" = 0 ] && ok || bad "L3 called the placer with no ticket"
[ "$(alines)" = 1 ] && grep -q -- "--severity warn --id lead-nh-lr-1 --project demo \[lead-review-land\] $SLUG#7 @${SHA:0:12}: a lead BLOCK is marked needs-human but no hold can be placed (branch 'feature/x' names no ticket); no fix round will run" "$T/log/alertline" \
  && ok || bad "L3 want one lead-nh warn: $(cat "$T/log/alertline")"
grep -qF "https://github.com/$SLUG/pull/7" "$T/log/alertline" && ok || bad "L3 the warn has no PR link"
[ "$(rposts)" = 1 ] && [ "$(stamps)" = 1 ] && ok || bad "L3 posts=$(rposts) stamps=$(stamps)"
rm -f "$H/state/lead-review-land/findings-lr-1"; setreqs "$(req lr-1 done BLOCK)"; tick
[ "$(alines)" = 1 ] && ok || bad "L3 a rerun alerted again ($(alines))"

# ── L4: no needs-human lib on the box -> logged, posted, and still no round ──
reset; art j1 "$SHA" "$F_NH"; mv "$H/bin/lib/needs-human.sh" "$T/nh.sh.away"; tick
mv "$T/nh.sh.away" "$H/bin/lib/needs-human.sh"
LOGF | grep -q 'needs-human lib missing; findings posted with no hold route' && ok || bad "L4 not logged: $(LOGF | tail -2)"
[ "$(rposts)" = 1 ] && [ "$(placers)" = 0 ] && ok || bad "L4 posts=$(rposts) placers=$(placers)"
[ "$(PICKED "$SHA")" = 1 ] && ok || bad "L4 with no lib a needs-human review must still brief nothing"

# ── L5: a product board (not an issues board) -> no placer, one warn ──
reset; art j1 "$SHA" "$F_NH"; echo BH > "$T/bp"; tick
[ "$(placers)" = 0 ] && ok || bad "L5 called the placer on a non-issues board"
[ "$(alines)" = 1 ] && grep -q 'demo is not an issues board' "$T/log/alertline" && ok || bad "L5 want one warn naming the board: $(cat "$T/log/alertline")"
[ "$(rposts)" = 1 ] && ok || bad "L5 the review must still be posted"

# ── L5r: a rebuild branch (ticket/bh-77-r2, the rebuild ladder's shape) still
#        names ticket 77 -> the hold is placed, no warn (lead review of #3819) ──
reset; art j1 "$SHA" "$F_NH"; echo ticket/bh-77-r2 > "$T/branch-7"; tick
[ "$(placers)" = 1 ] && ok || bad "L5r a rebuild branch placed no hold ($(placers)): $(cat "$T/log/alertline" 2>/dev/null)"
case "$(cat "$T/log/placer")" in "demo 77 "*) ok ;; *) bad "L5r the placer was not called for issue 77: $(cat "$T/log/placer")" ;; esac
grep -q 'names no ticket' "$T/log/alertline" 2>/dev/null && bad "L5r warned that ticket/bh-77-r2 names no ticket" || ok

# ── L6: a protected-path PR. The BLOCK findings go to the PR and brief a round
#        (a BLOCK is never withheld, bin/lead-verdict.sh); the human verdict stays
#        required on the MERGE that follows (BH-3683: withheld, one beat). ──
reset
"$T/fakebin/lpp-answer" PUT http://lpp.stub/api/lead-protected-paths "{\"repo\":\"$SLUG\",\"glob\":\"bin/protected.sh\",\"op\":\"add\",\"added_by\":\"t\"}" >/dev/null
echo '[{"filename":"bin/protected.sh"}]' > "$T/files-7.json"
tick
[ "$(grep -c "^POST repos/$SLUG/pulls/7/reviews event=REQUEST_CHANGES commit_id=$SHA\$" "$T/log/gh")" = 1 ] && ok || bad "L6 the protected BLOCK was not posted as REQUEST_CHANGES: $(grep reviews "$T/log/gh")"
[ "$(PICKED "$SHA")" = 0 ] && ok || bad "L6 the protected PR's lead BLOCK must brief a fix round"
[ "$(placers)" = 0 ] && ok || bad "L6 a protected BLOCK with no needs-human line placed a hold"
echo '[{"filename":"bin/protected.sh"},{"filename":"a.sh"}]' > "$T/files-7.json"
echo "$SHA2" > "$T/head-7"; setreqs "$(req lr-2 done MERGE 7 "$SHA2")"; tick
grep -q -- "--id lead-human-needed-example-org_demo-os-7-${SHA2:0:12} " "$T/log/alerts" && ok || bad "L6 the MERGE after the fix must ask for the human verdict: $(cat "$T/log/alerts")"
LOGF | grep -q "lead review lr-2: MERGE recorded as advice; lead-verdict status withheld" && ok || bad "L6 the MERGE was not withheld: $(LOGF | tail -3)"
grep -q "^POST repos/$SLUG/statuses/$SHA2 " "$T/log/gh" && bad "L6 a lead status was published on the protected PR" || ok
"$T/fakebin/lpp-answer" PUT http://lpp.stub/api/lead-protected-paths "{\"repo\":\"$SLUG\",\"glob\":\"bin/protected.sh\",\"op\":\"remove\"}" >/dev/null
scratch_rm "$H/state/lead-authority"

# ── T1/T2: the same findings on two heads -> counted 1 then 2, the hold on the second ──
reset
land_head lr-1 "$SHA" "$F_A" "$F_N"
[ "$(ledger_n)" = 1 ] && ok || bad "T1 head 1 must count 1, ledger: $(cat "$T/ledger.json" 2>/dev/null)"
[ "$(placers)" = 0 ] && [ "$(rposts)" = 1 ] && ok || bad "T1 head 1 must post and not trip (placers=$(placers) posts=$(rposts))"
[ "$(PICKED "$SHA")" = 0 ] && ok || bad "T1 head 1's review must brief the fix round"
land_head lr-2 "$SHA2" "$F_A2" '- [NOTE] c.sh:7: another note entirely'
[ "$(ledger_n)" = 2 ] && [ "$(ledger_keys)" = 1 ] && ok || bad "T1 the reworded line numbers must count 2 on ONE key: $(cat "$T/ledger.json")"
[ "$(placers)" = 1 ] && ok || bad "T2 want exactly one placer call on the second head, got $(placers)"
grep -qE "^demo 77 [0-9a-f]{12} pause-and-diagnose: the same lead finding blocked 2 heads of $SLUG#7: a\.sh:41: the retry loop never stops when the worker answers 500 lead-review\$" "$T/log/placer" \
  && ok || bad "T2 the placer argv: $(cat "$T/log/placer")"
[ "$(alines)" = 1 ] && grep -qF 'a.sh:41: the retry loop never stops' "$T/log/alertline" && ok || bad "T2 want ONE alert line carrying the finding, got $(alines): $(cat "$T/log/alertline")"
[ "$(rposts)" = 2 ] && ok || bad "T2 the second head's review must still be posted ($(rposts))"
order=$(awk '/^placer$/{print "hold"} /^gh POST .*\/reviews$/{print "review"}' "$T/log/seq" | paste -sd' ')
[ "$order" = "review hold review" ] && ok || bad "T2 the hold must precede the second review: '$order'"
LOGF | grep -q 'tripwire TRIPPED' && ok || bad "T2 not logged: $(LOGF | tail -2)"

# ── T4: re-landing the second head's request (stamp-only retry) -> no recount, no second placer call ──
rm -f "$H/state/lead-review-land/findings-lr-2"
jq -c 'map(if .commit_id == "'"$SHA2"'" then .body = "x" else . end)' "$T/reviews-7.json" > "$T/r.tmp" && mv "$T/r.tmp" "$T/reviews-7.json"
setreqs "$(req lr-2 done BLOCK 7 "$SHA2" j-lr-2)"; tick
[ "$(ledger_n)" = 2 ] && ok || bad "T4 a retry of the same head recounted: $(ledger_n)"
[ "$(placers)" = 1 ] && [ "$(alines)" = 1 ] && ok || bad "T4 a retry called the placer/alerted again (placers=$(placers) alines=$(alines))"

# ── T3: rules-pack BLOCKs (deterministic lines) on two heads trip ──
reset
land_head lr-1 "$SHA" '- [BLOCK] tests/x-test.sh: bash -n failed' '- [BLOCK] bin/y.sh: shellcheck SC2086'
land_head lr-2 "$SHA2" '- [BLOCK] tests/x-test.sh: bash -n failed' '- [BLOCK] bin/y.sh: shellcheck SC2086'
[ "$(placers)" = 1 ] && ok || bad "T3 identical rules-pack lines on two heads must trip ($(placers))"

# ── T5: different findings on the next head -> two keys, no trip ──
reset
land_head lr-1 "$SHA" "$F_A"
land_head lr-2 "$SHA2" "$F_B"
[ "$(ledger_keys)" = 2 ] && [ "$(ledger_n)" = "1,1" ] && ok || bad "T5 want 2 keys at 1, ledger: $(cat "$T/ledger.json")"
[ "$(placers)" = 0 ] && ok || bad "T5 different findings tripped ($(placers))"
# ...a NOTE-only difference is the same finding set
reset
land_head lr-1 "$SHA" "$F_A" "$F_N"
land_head lr-2 "$SHA2" "$F_A"
[ "$(placers)" = 1 ] && ok || bad "T5 a NOTE-only difference must not split the fingerprint ($(placers))"
# ...and a `Full report:` fallback (no artifact) has no fingerprint at all
reset
echo "$SHA" > "$T/head-7"; setreqs "$(req lr-1 done BLOCK 7 "$SHA" "")"; tick
echo "$SHA2" > "$T/head-7"; setreqs "$(req lr-2 done BLOCK 7 "$SHA2" "")"; tick
[ "$(ledger_keys)" = 0 ] && [ "$(placers)" = 0 ] && ok || bad "T5 a Full-report fallback was counted (keys=$(ledger_keys) placers=$(placers))"
LOGF | grep -q 'fp:none; tripwire not counted' && ok || bad "T5 fp:none not logged"
[ "$(rposts)" = 2 ] && ok || bad "T5 the fallback reviews must still post ($(rposts))"

# ── T6: an unreadable ledger is not counted and not tripped; the review still posts ──
reset
land_head lr-1 "$SHA" "$F_A"
: > "$T/ledger500"
land_head lr-2 "$SHA2" "$F_A"
[ "$(placers)" = 0 ] && ok || bad "T6 an unreadable ledger tripped"
[ "$(rposts)" = 2 ] && [ "$(stamps lr-2)" = 1 ] && ok || bad "T6 the review must post and stamp (posts=$(rposts) stamps=$(stamps lr-2))"
LOGF | grep -q 'tripwire ledger unreadable; not counted, not tripped' && ok || bad "T6 not logged: $(LOGF | tail -2)"
# ...and no dollar cap rides in: the lane's diff reads no usd/cost knob.
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  git -C "$DIR" diff origin/main -- bin/lead-review-land.sh | grep -Ei '^\+.*(usd|cost)' >/dev/null && bad "T6 the lane diff adds a usd/cost read" || ok
fi
# ...and a non-issues board never counts.
reset; echo BH > "$T/bp"
land_head lr-1 "$SHA" "$F_A"; land_head lr-2 "$SHA2" "$F_A"
[ "$(ledger_keys)" = 0 ] && [ "$(placers)" = 0 ] && ok || bad "T6 a product board was counted (keys=$(ledger_keys))"

# ============================================================================
# E — the real bin/blocked-resolver.sh, whole, against a real git remote
# ============================================================================
unset HARNESS JOBS_URL HARNESS_SECRET LANE_GATE_DISABLE GH_ETAG
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }
E="$T/e"; EH="$E/h"
mkdir -p "$EH/bin/lib" "$EH/logs" "$EH/state" "$EH/flags" "$EH/locks" "$EH/env" "$EH/builds" \
         "$EH/state/merge-conductor" "$EH/state/build-queue/tproj" "$E/fakebin" "$E/repos"
cp "$BR" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$DIR/bin/alert-line.sh" "$EH/bin/"
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$EH" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/rebuild-ledger.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/git-identity.sh" "$EH/bin/lib/"
mkdir -p "$EH/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$EH/bin/lib/mc/"
export GIT_CONFIG_GLOBAL="$E/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$EH/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$EH" tproj
: > "$EH/env/global.env"
for f in run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do printf '#!/bin/bash\nexit 0\n' > "$EH/bin/$f"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beats.txt"\nexit 0\n' "$E" > "$EH/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$E" > "$EH/bin/lane-alert.sh"
cat > "$EH/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$E/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
chmod +x "$EH/bin/"*.sh
touch "$EH/flags/fly-pool-tproj"

ORIGIN="$E/origin.git"; SEED="$E/seed"
git init -q --bare "$ORIGIN"; git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"; git -C "$SEED" remote add origin "$ORIGIN"
printf '#!/bin/bash\n# a\nretry\n' > "$SEED/a.sh"
git -C "$SEED" add -A; git -C "$SEED" commit -qm base
git -C "$SEED" branch -M main; git -C "$SEED" push -q origin main
mkbranch() {
  git -C "$SEED" checkout -q main; git -C "$SEED" checkout -q -b "$1"
  printf '%s\n' "$1" > "$SEED/f-${1##*/}.txt"
  git -C "$SEED" add -A; git -C "$SEED" commit -qm "work on $1"; git -C "$SEED" push -q origin "$1"
}
mkbranch ticket/TK-71
mkbranch ticket/TK-72
git clone -q "$ORIGIN" "$E/repos/tproj"
osha() { git -C "$ORIGIN" rev-parse "$1"; }

PRWRITE() { jq -s . "$E/prrows" > "$E/openprs"; cp "$E/openprs" "$E/prlist.json"; }
PRRESET() { : > "$E/prrows"; PRWRITE; rm -f "$E/reviews-"*.json "$E/revrows-"* "$E/pr-"*.json 2>/dev/null; }
PRADD() { # PRADD <num> <head> <branch>
  jq -nc --argjson n "$1" --arg h "$2" --arg b "$3" --arg u "$(ISO 600)" --arg url "https://github.com/o/tproj/pull/$1" \
    '{number:$n, html_url:$url, title:("TK-"+($n|tostring)+": the work"), body:"body",
      head:{sha:$h, ref:$b}, base:{ref:"main"}, draft:false,
      user:{login:"operator", type:"User"}, created_at:$u, updated_at:$u,
      merged_at:null, closed_at:null, labels:[], state:"open"}' > "$E/pr-$1.json"
  cat "$E/pr-$1.json" >> "$E/prrows"; PRWRITE
}
APPREV() { # APPREV <num> <id> <commit> — the land lane's review, as the App posts it
  jq -nc --argjson i "$2" --arg c "$3" --arg b "<!-- lead-review:lr-$1 -->
Lead review (automated lead-review lane, stub-model) of ${3:0:12}

# Lead review lr-$1 (o/tproj#$1 at $3)

Findings
- [BLOCK] a.sh:3: the retry loop never stops

VERDICT: BLOCK" \
    '{id:$i, state:"CHANGES_REQUESTED", commit_id:$c, user:{login:"cromford[bot]", type:"Bot"}, author_association:"NONE", body:$b}' >> "$E/revrows-$1"
  jq -s . "$E/revrows-$1" > "$E/reviews-$1.json"
}
RL='{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'
export GH_BUDGET_TTL_S=0
# GitHub: the shared REST stub, plus compare answered from the REAL remote's history.
cat > "$E/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$E/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X GET"*"/compare/"*)
    c=\$(printf '%s' "\$*" | sed -nE 's#.*/compare/([^ ?]+).*#\1#p'); a=\${c%%...*}; b=\${c#*...}
    git -C "$ORIGIN" cat-file -e "\$a^{commit}" 2>/dev/null || { printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}'; exit 0; }
    out=\$(git -C "$ORIGIN" rev-list --reverse --parents "\$a..\$b" | jq -Rsc 'split("\n") | map(select(. != "") | split(" ")) | map({sha:.[0], parents:(.[1:] | map({sha:.}))}) | {status:(if length > 0 then "ahead" else "identical" end), commits:.}')
    printf 'HTTP/2 200\r\n\r\n%s' "\$out"; exit 0 ;;
  *"-i -X "*)
    GHT="$E"
    jq -r '.head.sha // ""' "$E/pr-\$N.json" 2>/dev/null > "$E/prhead"
    jq -r '.head.ref // ""' "$E/pr-\$N.json" 2>/dev/null > "$E/prbranch"
    jq -r '.title // ""'    "$E/pr-\$N.json" 2>/dev/null > "$E/prtitle"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"api rate_limit"*) printf '%s\n' '$RL' ;;
  *"pr comment"*) printf 'pr comment %s\n' "\$2" >> "$E/comments.txt"; exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)
    JQX=""; PREV=""
    for A in "\$@"; do case "\$PREV" in --jq|-q) JQX="\$A" ;; esac; PREV="\$A"; done
    if [ -n "\$JQX" ]; then jq -r "\$JQX" "$E/pr-\$N.json" 2>/dev/null; else cat "$E/pr-\$N.json" 2>/dev/null; fi ;;
  *"--json headRefName"*) echo "ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$E/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$E/fakebin/flock"; chmod +x "$E/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$E/fakebin/br-ssh"; chmod +x "$E/fakebin/br-ssh"
echo OPEN > "$E/prstate"
# The agent answers the finding in a.sh (the file it names) and commits.
cat > "$EH/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'agent-call %s\n' "\$1" >> "$E/agent.txt"
printf '%s' "\$6" > "$E/prompt.txt"
printf 'retry with a cap\n' >> a.sh
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -q -m "fix round: cap the retry" >/dev/null 2>&1
exit 0
EOF
chmod +x "$EH/bin/agent-call.sh"
OLDPATH="$PATH"; export PATH="$E/fakebin:$OLDPATH" GH_TOKEN=""
RUN() { ( HARNESS="$EH" FLEET_CONF="$EH/fleet.conf" REPOS_ROOT="$E/repos" BR_SSH="$E/fakebin/br-ssh" \
          bash "$EH/bin/blocked-resolver.sh" >>"$E/run.log" 2>&1 ) || true; }
ERESET() { : > "$E/agent.txt"; : > "$E/prompt.txt"; : > "$EH/logs/blocked-resolver.log"; scratch_rm "$EH/state/gh-budget"; }
NAGENT() { grep -c . "$E/agent.txt" 2>/dev/null || true; }
CAND() { # the reviews source's candidate rows
  awk '/^DONE_KEYS=/{exit} {print}' "$EH/bin/blocked-resolver.sh" > "$E/br-lib.sh"
  ( HARNESS="$EH" FLEET_CONF="$EH/fleet.conf" REPOS_ROOT="$E/repos" BRLIB="$E/br-lib.sh" \
    bash -c 'L="$BRLIB"; set --; . "$L" 2>/dev/null; ONLY=""; br_from_reviews' 2>/dev/null ) | grep -F $'\treview-changes-requested\t' || true
}

# ── E1: the App's marker review on the head -> one candidate, one round, the findings in its brief ──
S71=$(osha ticket/TK-71)
PRRESET; PRADD 71 "$S71" ticket/TK-71; APPREV 71 11 "$S71"
C=$(CAND)
[ "$(grep -c . <<<"$C")" = 1 ] && [ "$(cut -f1 <<<"$C")" = reviews ] && ok || bad "E1 want one reviews candidate, got: $C"
ERESET; RUN
[ "$(NAGENT)" = 1 ] && ok || bad "E1 want exactly one fix round, got $(NAGENT) (log: $(tail -5 "$EH/logs/blocked-resolver.log"))"
grep -qF "$LEAD_HDR" "$E/prompt.txt" && grep -qF -- '- [BLOCK] a.sh:3: the retry loop never stops' "$E/prompt.txt" \
  && ok || bad "E1 the brief must carry LEAD FINDINGS and the BLOCK line: $(head -c 600 "$E/prompt.txt")"
S71B=$(osha ticket/TK-71)
[ "$S71B" != "$S71" ] && ok || bad "E1 the fix round did not push (log: $(tail -5 "$EH/logs/blocked-resolver.log"))"

# ── E2: the same head again -> no second round ──
ERESET; RUN
[ "$(NAGENT)" = 0 ] && ok || bad "E2 the same head bought a second round ($(NAGENT))"
grep -q "fix round already ran on ${S71:0:8}" "$EH/logs/blocked-resolver.log" && ok || bad "E2 the dedupe was not said: $(tail -4 "$EH/logs/blocked-resolver.log")"

# ── E3: the PR is on the pushed head (a real commit) -> the old review is no candidate ──
PRRESET; PRADD 71 "$S71B" ticket/TK-71; APPREV 71 11 "$S71"
[ -z "$(CAND)" ] && ok || bad "E3 the old head's review was offered for the pushed head: $(CAND)"
ERESET; RUN
[ "$(NAGENT)" = 0 ] && ok || bad "E3 a round ran from the old head's review ($(NAGENT))"

# ── E4: a ticket waiting on a human -> no round, even with a fresh BLOCK on its head ──
S72=$(osha ticket/TK-72)
PRRESET; PRADD 72 "$S72" ticket/TK-72; APPREV 72 21 "$S72"
jq -nc '[{id:1, user:{login:"cromford[bot]", type:"Bot"}, author_association:"NONE", created_at:"2026-10-01T00:00:00Z",
          body:"NEEDS-HUMAN: pause-and-diagnose: the same lead finding blocked 2 heads\n\nBuilds of this ticket are paused.\n<!-- nh-fp:abcdef012345 -->"}]' > "$E/comments-72.json"
[ "$(grep -c . <<<"$(CAND)")" = 1 ] && ok || bad "E4 control: the held PR's review is still a candidate (the hold, not the picker, stops it)"
ERESET; RUN
[ "$(NAGENT)" = 0 ] && ok || bad "E4 a held ticket bought a round ($(NAGENT)) (log: $(tail -5 "$EH/logs/blocked-resolver.log"))"
[ "$(osha ticket/TK-72)" = "$S72" ] && ok || bad "E4 a held ticket's branch moved"
grep -q 'waiting-on-human' "$EH/logs/blocked-resolver.log" && ok || bad "E4 the hold was not named: $(tail -4 "$EH/logs/blocked-resolver.log")"
export PATH="$OLDPATH"

echo "lead-block-fix-round.bh-3780: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
