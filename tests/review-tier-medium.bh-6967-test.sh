#!/bin/bash
# tests/review-tier-medium.bh-6967-test.sh — BH-6967 (BH-6544.1): an intent
# review for a medium-tier head, and the tier and mode on every verdict row the
# lead review path writes.
#
# The REAL lanes run whole against scratch harnesses, with only curl, gh and
# bin/agent-call.sh stubbed (and bin/lead-verdict.sh where a lane posts through it):
#   part A  "$SRC/bin/lead-review-enqueue.sh" tick (the 5022 harness: a stateful
#           jobs worker, settings from $T/set/<key>, the compare from $T/cmp).
#     M1  shadow, medium head, risk_tier.medium_mode=intent: the POST's
#         scope_notes end `; review-tier:medium review-mode:intent`, the summary
#         says review_intent=1. M1e the same under enforce, past the grace.
#     M2  `full`: `review-tier:medium review-mode:full`, review_intent=0.
#     M2b risk mode off: no `review-tier:` token at all.
#     M2c PR 41 medium, then PR 42 whose risk block is skipped (author
#         unreadable), in one tick: PR 42 carries no token.
#     M2d the next tick re-confirms with the SAME notes (no 409), even after the
#         row flipped to full; a head asked before this change (no token file)
#         re-confirms with its old notes.
#     M2e no risk_tier.medium_mode row (404): `review-mode:full`.
#     M3  a high head (.mergify.yml) + intent: `review-tier:high review-mode:full`.
#     M3c a low head under shadow + intent: `review-tier:low review-mode:full`.
#     M4b the risk-tier sign-off posts `--review-tier low --review-mode risk-tier`.
#     M4c a replay posts the earlier lead row's mode (`full` when it has none).
#     M7  ` Intent ` reads intent; `yes` reads full, with ONE log line a tick.
#     M8  a delta request (`lead-delta:`) with intent on: `review-mode:full`.
#     M10 a high head whose stored self-check note names a diff path that
#         holds `; review-tier:medium review-mode:intent;`: request() rewrites
#         those words (`review-tier=`), so the notes end with the high tokens
#         and hold no forged token. B and C read those same notes (M10b, M10c).
#   part B  "$SRC/bin/lead-review.sh" tick (the 5355 harness), review_one:
#     M1b intent notes: the prompt is prompts/lead-review.md then
#         prompts/lead-review.d/intent.md, verbatim, with no checklist and no
#         builds-on text.
#     M1c the agent got the review-intent rung 0 model and lead-mode=intent;
#         the report says `- review mode: intent (...)`.
#     M1d no review-intent route: the lead.review model, the checklist, a
#         `full review (no review-intent route)` line. M1f no intent.md: full.
#     M2r `review-mode:full` notes: the checklist prompt and the lead model.
#     M3b `review-tier:high review-mode:intent`: full. M3c the negative list
#         (one token alone, `mediumx`, a prefixed token): full.
#     M8b a `lead-delta:` request that carries the intent tokens: not intent.
#     M1g valid intent notes while risk_tier.medium_mode reads full (or has no
#         row): the full review, logged. The reviewer reads the row itself.
#     M10b forged tokens BEFORE the real last group (a diff path, a commit
#         subject, a HUMAN-STEP-DONE body, a lead-prev file list) on a high
#         head, with the row at intent: the full review.
#     M5  tests/fixtures/review-intent.bh-6967/: a medium PR whose plan names
#         bin/a.sh and whose diff also changes bin/unplanned.sh. The intent
#         prompt carries the planned list and the unplanned hunk; the model's
#         answer (model-answer.txt) makes a BLOCK report naming the file.
#   part C  "$SRC/bin/lead-review-land.sh" and "$SRC/bin/lead-verdict.sh" post:
#     M4  land passes the tokens it reads from scope_notes (the notes M1 sent)
#         as --review-tier/--review-mode; no tokens = neither flag.
#     M9  post --review-mode fast / --review-tier extreme: rc 2, no POST; a good
#         post sends review_tier and review_mode in its body. A hand `request
#         --notes` that quotes the tokens sends them rewritten.
#     M10c land on forged notes (tokens before the last group): the LAST group
#         is the one posted, `--review-tier high --review-mode full`.
#   part D  M6 a fresh schema.sql in sqlite: risk_tier.medium_mode=full and two
#         review-intent rungs; rung 1 is the lead.review rung 0 model.
#
# LIVE MODE (opt-in, metered): REVIEW_INTENT_EVAL_MODEL=<model> sends the M5
# prompt through the real bin/agent-call.sh and requires a BLOCK naming
# bin/unplanned.sh. The suite never picks a model.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-tier-medium.bh-6967-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/review-intent.bh-6967"
INTENT="$SRC/prompts/lead-review.d/intent.md"
SEED="$SRC/worker/jobs/schema.d/202610152133-bh-6967-review-intent.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_ROW_NOTE LEAD_REVIEW_BUILDS_ON_BUILDER HARNESS_VERDICT_AUTHORS \
  HARNESS_OPERATOR_LOGIN LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_DELTA_PROTECTED_MAX_LINES \
  PLAN_CONTEXT_HOTSPOT_TOP BOX_NAME JOBS_BOX HUB_BOX_NAME LEAD_REVIEW_OVERDUE_MIN

[ -f "$INTENT" ] && ok || bad "T1 prompts/lead-review.d/intent.md does not exist"
for f in pr-body.md diff.patch model-answer.txt; do [ -f "$FX/$f" ] || { echo "FAIL: fixture $f missing"; exit 1; }; done

# ═══════════════════════ part A: bin/lead-review-enqueue.sh ═══════════════════
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$H/catalog/lanes.d" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg" "$T/repos"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lead-review-enqueue.sh "$H" >/dev/null || exit 1
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$H/catalog/lanes.d/"
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_install "$T/fakebin" "$LPPF" "$DOWNF"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$SRC/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
printf 'lead-test-token-fixture\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'cromford example-org/cromford https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"

SHA=$(printf 'a%.0s' {1..40}); SHA12=${SHA:0:12}
S42=$(printf 'd%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
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
lead=0; grep -q '^x-lead-verdict-token: lead-test-token-fixture' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
[ -f "$T/lrrows.json" ] || echo '[]' > "$T/lrrows.json"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/settings/risk_tier.mode.example-org.cromford")
    if [ -f "$T/mode" ]; then out=\$(jq -nc --arg v "\$(cat "$T/mode")" '{setting:{key:"risk_tier.mode.example-org.cromford",value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    printf '%s\n' "\$k" >> "$T/log/settings"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
    rows='[]'
    case "\$p" in *standing_only=1*) ;; *) [ -f "$T/vrows/\$n.json" ] && rows=\$(cat "$T/vrows/\$n.json") ;; esac
    out=\$(jq -nc --argjson s "\$st" --argjson r "\$rows" '{standing:\$s, rows:\$r, truncated:false}') ;;
  "POST /api/risk-tiers") code=201; out='{"ok":true,"id":1}' ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      r=\$(jq -r .repo <<<"\$body"); pr=\$(jq -r .pr <<<"\$body"); h=\$(jq -r .head_sha <<<"\$body"); nt=\$(jq -r '.scope_notes // ""' <<<"\$body")
      have=\$(jq -c --arg r "\$r" --argjson p "\$pr" --arg h "\$h" '[.[] | select(.repo == \$r and .pr == \$p and .head_sha == \$h)] | first // empty' "$T/lrrows.json")
      if [ -n "\$have" ]; then
        if [ "\$(jq -r '.scope_notes // ""' <<<"\$have")" = "\$nt" ]; then out=\$(jq -c '{request:., existing:true}' <<<"\$have")
        else code=409; echo "409 \$r#\$pr" >> "$T/log/conflicts"; out=\$(jq -c '{error:"a request for this head exists with other notes", request:.}' <<<"\$have"); fi
      else
        n=\$(jq length "$T/lrrows.json")
        row=\$(jq -c --arg id "lr-\$((n + 1))" '. + {id:\$id, status:"requested"}' <<<"\$body")
        jq -c --argjson r "\$row" '. + [\$r]' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
        code=201; out=\$(jq -c '{request:.}' <<<"\$row")
      fi
    fi ;;
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
  *"-X GET repos/example-org/"*"/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/"*"/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" --arg u "\$(cat "$T/author/\$n" 2>/dev/null || echo "cromford[bot]")" \
      --arg n "\$n" '{head:{sha:\$s,ref:("ticket/bh-"+\$n)},base:{ref:"main"},user:{login:\$u}}' ;;
  *"-X GET repos/example-org/"*"/compare/"*)
    a="\$*"; h="\${a##*...}"; h="\${h%% *}"
    if [ -f "$T/cmp/\$h.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp/\$h.json"
    else printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: x"}}],"files":[{"filename":"bin/lib/thing.sh","additions":40,"deletions":10}]}\n'; fi ;;
  *"-X POST repos/example-org/"*"/statuses/"*)
    printf 'HTTP/2 201\r\n\r\n{"state":"success"}\n' ;;
esac
exit 0
EOF
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/lv"
exit \$(cat "$T/lvrc" 2>/dev/null || echo 0)
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/agent"
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lead-verdict.sh" "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh"

pr() {
  jq -c --argjson n "$1" --arg h "$2" '[.[] | select(.number != $n)] + [{number:$n, html_url:("https://github.com/example-org/cromford/pull/"+($n|tostring)),
    title:"t", draft:false, state:"open", user:{login:"cromford[bot]",type:"Bot"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"}}]' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"
}
approve() {
  jq -nc --arg s "$2" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s, job:{id:"job-1", kind:"build", status:"running"},
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
cmpx() {
  jq -nc --argjson f "$2" '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat: x"}}],
    files:[$f[] | {filename:.[0], additions:.[1], deletions:.[2]}]}' > "$T/cmp/$1.json"
}
reset() {
  rm -f "$T/log"/* "$T"/{lrrows.json,mode,lvrc} "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv standing head cmp set author vrows; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  printf 'operator' > "$T/set/lead_pr_authors"
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/prs.json"
}
MEDIUM='[["bin/lib/thing.sh",40,10]]'; HIGH='[[".mergify.yml",2,1]]'; DOCS='[["docs/a.md",30,12]]'
# one <mode> <medium_mode or -> <diff> — PR 41 at $SHA, builder-approved.
one() {
  reset; [ "$1" = off ] || echo "$1" > "$T/mode"
  [ "$2" = - ] || printf '%s' "$2" > "$T/set/risk_tier.medium_mode"
  pr 41 "$SHA"; approve 41 "$SHA"; cmpx "$SHA" "$3"
}
tick() { ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/cromford \
  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=8 REPOS_ROOT="${QREPOS:-$T/repos}" "$@" \
  bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
posts() { wlog | grep -c '^POST /api/lead-reviews ' ; }
# notes [<pr>] — the scope_notes of the newest POST for that PR (default 41)
notes() { wlog | sed -n 's#^POST /api/lead-reviews \(.*\) lead=.$#\1#p' | jq -r --argjson p "${1:-41}" 'select(.pr == $p) | .scope_notes' 2>/dev/null | tail -1; }
LOGF="$H/logs/lead-review-enqueue.log"
summ() { grep ' tick repos=' "$LOGF" 2>/dev/null | tail -1; }
has() { summ | grep -qw -- "$1"; }
TOKF="$H/state/lead-review-enqueue/review-tier-example-org_cromford-41-$SHA12"

# ── M1: shadow + medium + intent -> the intent tokens end the notes ──
one shadow intent "$MEDIUM"; tick
[ "$RC" -eq 0 ] && ok || bad "M1 rc=$RC out=$(cat "$T/out")"
[ "$(posts)" = 1 ] && ok || bad "M1 want one request, got $(posts): $(summ)"
N1=$(notes)
case "$N1" in *"; review-tier:medium review-mode:intent") ok ;; *) bad "M1 scope_notes do not end with the intent tokens: '$N1'" ;; esac
has review_intent=1 && ok || bad "M1 summary lacks review_intent=1: $(summ)"
[ "$(cat "$TOKF" 2>/dev/null)" = "review-tier:medium review-mode:intent" ] && ok || bad "M1 the per-head token file: '$(cat "$TOKF" 2>/dev/null)'"
M1NOTES="$N1"

# ── M2d: the next tick re-confirms with the same notes, even after a flip to full ──
printf 'full' > "$T/set/risk_tier.medium_mode"; rm -f "$T/log/worker"; tick
[ "$(notes)" = "$N1" ] && ok || bad "M2d re-confirm notes changed: '$(notes)' (first ask '$N1')"
[ -s "$T/log/conflicts" ] && bad "M2d the re-confirm got a 409: $(cat "$T/log/conflicts")" || ok
has existing=1 && has review_intent=0 && ok || bad "M2d summary: $(summ)"
# ...and a head first asked before this change (no token file, notes with no token) keeps its old notes
OLDN="${N1%; review-tier:medium review-mode:intent}"
jq -c --arg n "$OLDN" 'map(.scope_notes = $n)' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
rm -f "$TOKF" "$T/log/worker"; printf 'intent' > "$T/set/risk_tier.medium_mode"; tick
[ "$(notes)" = "$OLDN" ] && ok || bad "M2d a pre-change head re-confirmed with new notes: '$(notes)' (want '$OLDN')"
[ -s "$T/log/conflicts" ] && bad "M2d the pre-change re-confirm got a 409" || ok

# ── M1e: enforce + medium + intent, once the in-build grace is spent ──
one enforce intent "$MEDIUM"; tick
[ "$(posts)" = 0 ] && ok || bad "M1e a medium head was requested inside the in-build grace"
touch -d '-2 hours' "$H/state/lead-review-enqueue/inbuild-wait-example-org_cromford-41-$SHA12"; tick
case "$(notes)" in *"; review-tier:medium review-mode:intent") ok ;; *) bad "M1e enforce notes: '$(notes)'" ;; esac

# ── M2: full -> the full tokens, no intent ──
one shadow full "$MEDIUM"; tick
case "$(notes)" in *"; review-tier:medium review-mode:full") ok ;; *) bad "M2 scope_notes: '$(notes)'" ;; esac
has review_intent=0 && ok || bad "M2 summary lacks review_intent=0: $(summ)"

# ── M2e: no risk_tier.medium_mode row -> full ──
one shadow - "$MEDIUM"; tick
case "$(notes)" in *"; review-tier:medium review-mode:full") ok ;; *) bad "M2e scope_notes with no row: '$(notes)'" ;; esac

# ── M2b: risk mode off -> no tier at all, no tokens ──
one off intent "$MEDIUM"; tick
[ "$(posts)" = 1 ] && ok || bad "M2b want one request, got $(posts)"
case "$(notes)" in *review-tier:*|*review-mode:*) bad "M2b risk mode off, yet tokens: '$(notes)'" ;; *) ok ;; esac

# ── M2c: PR 41 medium, then PR 42 whose risk block is skipped: no stale token ──
one shadow intent "$MEDIUM"; pr 42 "$S42"; approve 42 "$S42"; cmpx "$S42" "$MEDIUM"; : > "$T/author/42"; tick
[ "$(posts)" = 2 ] && ok || bad "M2c want two requests, got $(posts): $(summ)"
FIRST=$(wlog | sed -n 's#^POST /api/lead-reviews \(.*\) lead=.$#\1#p' | head -1 | jq -r .pr 2>/dev/null)
[ "$FIRST" = 41 ] && ok || bad "M2c setup: PR 41 must be asked first, got PR $FIRST"
case "$(notes 41)" in *"review-mode:intent") ok ;; *) bad "M2c PR 41 notes: '$(notes 41)'" ;; esac
case "$(notes 42)" in *review-tier:*|*review-mode:*) bad "M2c PR 42 (risk block skipped) got PR 41's token: '$(notes 42)'" ;; *) ok ;; esac
grep -q 'example-org/cromford#42 .*risk tier skipped (PR author unreadable)' "$LOGF" && ok || bad "M2c setup: PR 42's risk block was not skipped: $(grep '#42' "$LOGF")"

# ── M3: a high head with intent on keeps the full mode ──
one shadow intent "$HIGH"; tick
case "$(notes)" in *"; review-tier:high review-mode:full") ok ;; *) bad "M3 high scope_notes: '$(notes)'" ;; esac
has review_intent=0 && ok || bad "M3 summary: $(summ)"

# ── M3c: a low head under shadow (requested) with intent on is full ──
one shadow intent "$DOCS"; tick
case "$(notes)" in *"; review-tier:low review-mode:full") ok ;; *) bad "M3c low scope_notes: '$(notes)'" ;; esac

# ── M4b: the risk-tier sign-off carries low / risk-tier ──
one enforce intent "$DOCS"; tick
LV=$(head -1 "$T/log/lv" 2>/dev/null)
case "$LV" in "post example-org/cromford 41 $SHA MERGE --source risk-tier "*) ok ;; *) bad "M4b no risk-tier post: '$LV'" ;; esac
case " $LV " in *" --review-tier low --review-mode risk-tier "*) ok ;; *) bad "M4b the sign-off lacks --review-tier low --review-mode risk-tier: '$LV'" ;; esac

# ── M7: ' Intent ' reads intent; 'yes' reads full with one log line a tick ──
one shadow ' Intent ' "$MEDIUM"; tick
case "$(notes)" in *"review-mode:intent") ok ;; *) bad "M7 ' Intent ' did not read intent: '$(notes)'" ;; esac
one shadow yes "$MEDIUM"; pr 42 "$S42"; approve 42 "$S42"; cmpx "$S42" "$MEDIUM"; tick
case "$(notes 41)$(notes 42)" in *review-mode:intent*) bad "M7 'yes' read intent: $(notes 41) | $(notes 42)" ;; *) ok ;; esac
case "$(notes 42)" in *"; review-tier:medium review-mode:full") ok ;; *) bad "M7 'yes' notes: '$(notes 42)'" ;; esac
[ "$(grep -c "risk_tier.medium_mode reads 'yes'" "$LOGF")" = 1 ] && ok || bad "M7 want one bad-value line in a tick with two medium heads: $(grep -c "medium_mode" "$LOGF")"
[ "$(grep -c '^risk_tier.medium_mode$' "$T/log/settings" 2>/dev/null)" = 1 ] && ok || bad "M7 the row was read $(grep -c '^risk_tier.medium_mode$' "$T/log/settings" 2>/dev/null) times in one tick (want once)"

# ── M8 / M4c: the delta and replay paths on a real origin ──
OR="$T/origin/cromford.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"; printf 'other\n' > "$WK/o.txt"; printf '# demo\n' > "$WK/CLAUDE.md"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr; echo 'pr line' >> "$WK/f.txt"; git -C "$WK" commit -qam "the pr"; G=$(git -C "$WK" rev-parse HEAD)
sed -i 's/^base line 3$/base line 3 fixed/' "$WK/f.txt"; git -C "$WK" commit -qam "fix three"; HO=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -q main; echo 'main moved' >> "$WK/o.txt"; git -C "$WK" commit -qam "main moves"
git -C "$WK" checkout -qb merged "$G"; git -C "$WK" merge -q --no-edit main; HM=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main pr merged
mkdir -p "$T/repos8"; git clone -q "$OR" "$T/repos8/cromford"
leadrow() { jq -nc --arg g "$G" --arg m "${2:-}" '[{id:5,repo:"example-org/cromford",pr:41,head_sha:$g,source:"lead",verdict:"MERGE",note:"lead-review:lr-3"}
  + (if $m == "" then {} else {review_mode:$m} end)]' > "$T/vrows/$1.json"; }
one shadow intent "$MEDIUM"; pr 41 "$HO"; approve 41 "$HO"; cmpx "$HO" "$MEDIUM"; leadrow 41
QREPOS="$T/repos8" tick PR_SELF_CHECK=0 LEAD_REVIEW_REBASE_HOLD=0
N8=$(notes)
case "$N8" in *"lead-delta:$G "*) ok ;; *) bad "M8 setup: no delta request: '$N8' $(grep -i 'since\|delta' "$LOGF" | tail -3)" ;; esac
case "$N8" in *review-mode:intent*) bad "M8 a delta request carries the intent mode: '$N8'" ;; *) ok ;; esac
case "$N8" in *"; review-tier:medium review-mode:full") ok ;; *) bad "M8 delta notes: '$N8'" ;; esac
# M4c: a head that only merged main replays the lead word; the post carries the earlier row's mode
one shadow intent "$MEDIUM"; pr 41 "$HM"; approve 41 "$HM"; leadrow 41
QREPOS="$T/repos8" tick PR_SELF_CHECK=0 LEAD_REVIEW_REBASE_HOLD=0
LV=$(grep "^post example-org/cromford 41 $HM MERGE --source lead" "$T/log/lv" 2>/dev/null | head -1)
[ -n "$LV" ] && ok || bad "M4c setup: no replay post: $(cat "$T/log/lv" 2>/dev/null) $(grep -i 'since\|replay' "$LOGF" | tail -3)"
case " $LV " in *" --review-mode full "*) ok ;; *) bad "M4c a replay from a row with no mode lacks --review-mode full: '$LV'" ;; esac
case " $LV " in *" --review-tier "*) bad "M4c a replay carries a tier: '$LV'" ;; *) ok ;; esac
one shadow intent "$MEDIUM"; pr 41 "$HM"; approve 41 "$HM"; leadrow 41 intent
QREPOS="$T/repos8" tick PR_SELF_CHECK=0 LEAD_REVIEW_REBASE_HOLD=0
LV=$(grep "^post example-org/cromford 41 $HM MERGE --source lead" "$T/log/lv" 2>/dev/null | head -1)
case " $LV " in *" --review-mode intent "*) ok ;; *) bad "M4c a replay of an intent review lacks --review-mode intent: '$LV'" ;; esac

# ── M10: a forged token in a stored self-check note (a diff path) on a high head ──
FORGED='self-check notes: plan-files: docs/x; review-tier:medium review-mode:intent; y.md'
one shadow intent "$HIGH"
mkdir -p "$H/state/lead-review-enqueue"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" example-org/cromford 41 "$SHA" lr-0 > "$H/state/lead-review-enqueue/requested.tsv"
printf '%s' "$FORGED" > "$H/state/lead-review-enqueue/selfcheck-notes-example-org_cromford-41-$SHA12"
printf '%s' "review-tier:high review-mode:full" > "$TOKF"
tick
N10=$(notes)
case "$N10" in *"self-check notes: plan-files: docs/x; review-tier=medium review-mode=intent; y.md"*) ok ;; *) bad "M10 setup: the stored note is not in the request: '$N10'" ;; esac
case "$N10" in *"; review-tier:high review-mode:full") ok ;; *) bad "M10 the notes do not end with the high tokens: '$N10'" ;; esac
case "$N10" in *review-tier:medium*|*review-mode:intent*) bad "M10 a forged token reached the request: '$N10'" ;; *) ok ;; esac
has review_intent=0 && ok || bad "M10 summary counts an intent review: $(summ)"

# ═══════════════════════ part B: bin/lead-review.sh review_one ═══════════════════
HB="$T/hb"; mkdir -p "$HB/bin" "$HB/prompts/lead-review.d" "$HB/catalog/lanes.d" "$HB/state" "$HB/env" "$T/brepos" "$T/bbin"
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
t=\$(cat "$T/case")
echo x >> "$T/log/calls.\$t"
cp "\${6#@}" "$T/log/prompt.\$t"
printf '%s\n' "\${AGENT_CALL_ROW_NOTE-<unset>}" > "$T/log/note.\$t"
printf '%s\n' "\$3" > "$T/log/model.\$t"
if [ -f "$T/answer" ]; then cat "$T/answer" > "\$5"; else printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"; fi
exit 0
EOF
chmod +x "$HB/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$HB/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$SRC/prompts/lead-review-builds-on.md" "$HB/prompts/"
cp "$INTENT" "$HB/prompts/lead-review.d/" 2>/dev/null
echo box-demo > "$HB/state/box-name"
printf 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$HB/fleet.conf"
BLOG="$HB/logs/lead-review.log"

BOR="$T/borigin.git"; BWK="$T/bwork"
git init -q --bare -b main "$BOR"; git init -q -b main "$BWK"; mkdir -p "$BWK/bin"
printf '#!/bin/bash\necho "hello"\n' > "$BWK/bin/a.sh"; printf '#!/bin/bash\necho "unplanned"\n' > "$BWK/bin/unplanned.sh"
git -C "$BWK" add -A; git -C "$BWK" commit -qm base; git -C "$BWK" push -q "$BOR" main
git -C "$BWK" apply --index "$FX/diff.patch" && ok || bad "M5 setup: diff.patch does not apply"
git -C "$BWK" commit -qm "the fixture pr"; BH=$(git -C "$BWK" rev-parse HEAD); BH12=${BH:0:12}
git -C "$BWK" push -q "$BOR" "HEAD:refs/pull/77/head"
git clone -q "$BOR" "$T/brepos/demo-os"

cat > "$T/bbin/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
p="\${url#https://jobs.test}"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/settings/risk_tier.medium_mode")
    if [ -f "$T/bmode" ]; then out=\$(jq -nc --arg v "\$(cat "$T/bmode")" '{setting:{key:"risk_tier.medium_mode",value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/model-routes/review-intent"*)
    if [ -e "$T/no-intent-route" ]; then out='{"ladder":[],"source":"none"}'
    else out='{"ladder":[{"position":0,"model":"fixture-intent-model","runner":"claude"},{"position":1,"model":"fixture-lead-model","runner":"claude"}],"source":"hub"}'; fi ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"fixture-lead-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/bbin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/pulls/"*"/reviews"*) echo "\$*" >> "$T/log/reviews-reads"; printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$BH" --rawfile b "$FX/pr-body.md" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"BH-9001: fixture greeting",body:\$b}' ;;
esac
exit 0
EOF
chmod +x "$T/bbin/curl" "$T/bbin/gh"

# compose <tag> <scope notes> [VAR=value ...] — one review_one of PR 77 at $BH.
compose() {
  local tag="$1" sn="$2"; shift 2
  echo "$tag" > "$T/case"
  rm -f "$T/log/calls.$tag" "$T/log/prompt.$tag" "$T/log/note.$tag" "$T/log/model.$tag" "$BLOG" "$T/log/reviews-reads"
  scratch_rm "$HB/state/lead-reviews"; scratch_rm "$HB/state/lead-review"; scratch_rm "$HB/state/model-routes"; mkdir -p "$HB/state/lead-reviews"
  jq -nc --arg s "$BH" --arg n "$sn" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:77,head_sha:$s,
    scope_notes:$n,prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
  ( cd "$T" && env PATH="$T/bbin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/brepos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 "$@" bash "$HB/bin/lead-review.sh" tick ) > "$T/out.$tag" 2>&1
  cp "$HB/state/lead-reviews/lr-77-$BH12.md" "$T/log/report.$tag" 2>/dev/null || : > "$T/log/report.$tag"
  cp "$BLOG" "$T/log/lane.$tag" 2>/dev/null || : > "$T/log/lane.$tag"
}
calls() { [ -f "$T/log/calls.$1" ] && wc -l < "$T/log/calls.$1" | tr -d ' ' || echo 0; }
lineof() { grep -nxF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }
CKL1=$(sed -n 1p "$SRC/prompts/lead-review-checklist.md")
BOL1=$(sed -n 1p "$SRC/prompts/lead-review-builds-on.md")
# full_check <tag> <case> — a full review: the checklist prompt, the lead model, no intent text
full_check() {
  [ "$(calls "$1")" = 1 ] || { bad "$2 agent called $(calls "$1") time(s): $(cat "$T/out.$1") $(cat "$T/log/lane.$1")"; return; }
  grep -qxF -- "$CKL1" "$T/log/prompt.$1" && ok || bad "$2 a full review without the checklist"
  [ "$(cat "$T/log/model.$1")" = fixture-lead-model ] && ok || bad "$2 model '$(cat "$T/log/model.$1")', want the lead.review model"
  grep -qxF -- "$(sed -n 1p "$INTENT")" "$T/log/prompt.$1" && bad "$2 a full review carries the intent text" || ok
  grep -q '^- review mode: intent' "$T/log/report.$1" && bad "$2 the report claims intent mode" || ok
  [ "$(cat "$T/log/note.$1")" = lead-mode=intent ] && bad "$2 the cost row says lead-mode=intent" || ok
}
INOTES="auto: builder APPROVE on $BH12; review-tier:medium review-mode:intent"
printf ' Intent ' > "$T/bmode"

# ── M1b / M1c: intent notes -> lead-review.md + intent.md, the review-intent model ──
compose m1 "$INOTES"
P="$T/log/prompt.m1"
[ "$(calls m1)" = 1 ] && ok || bad "M1b agent called $(calls m1) time(s): $(cat "$T/out.m1") $(cat "$T/log/lane.m1")"
n=$(wc -l < "$SRC/prompts/lead-review.md")
head -n "$n" "$P" | cmp -s - "$SRC/prompts/lead-review.md" && ok || bad "M1b the prompt does not start with prompts/lead-review.md verbatim"
s=$(lineof "$P" "$(sed -n 1p "$INTENT")"); ni=$(wc -l < "$INTENT")
if [ -n "$s" ]; then
  sed -n "${s},$((s + ni - 1))p" "$P" | cmp -s - "$INTENT" && ok || bad "M1b intent.md is not in the prompt verbatim"
  [ "$s" -le $((n + 2)) ] && ok || bad "M1b intent.md starts at line $s, not right after lead-review.md ($n lines)"
  prl=$(lineof "$P" '## PR'); [ -n "$prl" ] && [ "$s" -lt "$prl" ] && ok || bad "M1b intent.md is not before ## PR"
else
  bad "M1b the prompt lacks intent.md"
fi
grep -q 'Checklist-Version' "$P" && bad "M1b the intent prompt carries the checklist" || ok
grep -qxF -- "$BOL1" "$P" && bad "M1b the intent prompt carries the builds-on text" || ok
grep -qxF '## Builder review (same head)' "$P" && bad "M1b the intent prompt carries a builder section" || ok
[ -s "$T/log/reviews-reads" ] && bad "M1b intent mode read the builder reviews" || ok
grep -qxF '## Diff' "$P" && grep -qxF '## Scope notes' "$P" && ok || bad "M1b the later sections are missing"
[ "$(cat "$T/log/model.m1")" = fixture-intent-model ] && ok || bad "M1c model '$(cat "$T/log/model.m1")', want the review-intent rung 0"
[ "$(cat "$T/log/note.m1")" = lead-mode=intent ] && ok || bad "M1c row note '$(cat "$T/log/note.m1")'"
grep -qx -- '- review mode: intent (risk tier medium, route review-intent)' "$T/log/report.m1" && ok \
  || bad "M1c the report lacks the intent header: $(head -n 12 "$T/log/report.m1")"
grep -qx -- '- checklist: none (intent review)' "$T/log/report.m1" && ok || bad "M1c the report names a checklist it did not read"
grep -q "reviewer model: fixture-intent-model" "$T/log/report.m1" && ok || bad "M1c the report names another model"

# ── M1d: no review-intent route -> a full review on lead.review, logged ──
: > "$T/no-intent-route"; compose m1d "$INOTES"; rm -f "$T/no-intent-route"
full_check m1d M1d
grep -q 'full review (no review-intent route)' "$T/log/lane.m1d" && ok || bad "M1d no fallback line: $(cat "$T/log/lane.m1d")"

# ── M1f: no intent.md on the box -> a full review, logged ──
mv "$HB/prompts/lead-review.d/intent.md" "$T/intent.away"; compose m1f "$INOTES"; mv "$T/intent.away" "$HB/prompts/lead-review.d/intent.md"
full_check m1f M1f
grep -q 'full review (prompts/lead-review.d/intent.md missing)' "$T/log/lane.m1f" && ok || bad "M1f no fallback line: $(cat "$T/log/lane.m1f")"

# ── M2r: review-mode:full -> unchanged ──
compose m2 "auto: x; review-tier:medium review-mode:full"; full_check m2 M2r
[ "$(cat "$T/log/note.m2")" = lead-mode=full ] && ok || bad "M2r row note '$(cat "$T/log/note.m2")'"
# ...and the same prompt as a request with no tokens at all (only the scope notes line differs)
compose m2n "auto: x"
diff <(grep -v '^auto: x' "$T/log/prompt.m2") <(grep -v '^auto: x' "$T/log/prompt.m2n") >/dev/null && ok || bad "M2r a full-token prompt differs from today's prompt"

# ── M3b / M3c: high, and the negative list ──
i=0
for sn in "auto: x; review-tier:high review-mode:intent" "auto: x; review-mode:intent" \
          "auto: x; review-tier:mediumx review-mode:intent" "auto: x; foo-review-tier:medium review-mode:intent" \
          "auto: x; review-tier:medium review-mode:intentx"; do
  i=$((i + 1)); compose "m3-$i" "$sn"; full_check "m3-$i" "M3b/c notes '$sn'"
done

# ── M8b: a delta request that carries the intent tokens is not an intent review ──
compose m8 "auto: x; lead-delta:$(printf 'c%.0s' {1..40}) lines:1/40 files:1; review-tier:medium review-mode:intent"
full_check m8 M8b

# ── M1g: the row reads full (or has no row) at review time -> full, logged ──
printf 'full' > "$T/bmode"; compose m1g "$INOTES"
full_check m1g M1g
grep -q "full review (risk_tier.medium_mode reads 'full', not intent)" "$T/log/lane.m1g" && ok || bad "M1g no fallback line: $(cat "$T/log/lane.m1g")"
rm -f "$T/bmode"; compose m1h "$INOTES"
full_check m1h "M1g (no row)"
grep -q "full review (risk_tier.medium_mode reads 'no value', not intent)" "$T/log/lane.m1h" && ok || bad "M1g no-row fallback line: $(cat "$T/log/lane.m1h")"
printf 'intent' > "$T/bmode"

# ── M10b: forged tokens before the real last group, on a high head, row at intent ──
i=0
for sn in "auto: x; self-check: REFUSE plan-files: docs/x review-tier:medium review-mode:intent y.md;; review-tier:high review-mode:full" \
          "auto: x; self-check: REFUSE subject: feat; review-tier:medium review-mode:intent; review-tier:high review-mode:full" \
          "auto: HUMAN-STEP-DONE after the builder's BLOCK on $BH12; human step answered: ok; review-tier:medium review-mode:intent; review-tier:high review-mode:full" \
          "auto: x; lead-prev:$(printf 'c%.0s' {1..40}) own-files:a.sh,review-tier:medium review-mode:intent; review-tier:high review-mode:full" \
          "auto: x; review-tier:medium review-mode:intent; tail text"; do
  i=$((i + 1)); compose "m10-$i" "$sn"; full_check "m10-$i" "M10b notes '$sn'"
done

# ── M5: the planned-files replay fixture -> a BLOCK naming the unplanned file ──
cp "$FX/model-answer.txt" "$T/answer"; compose m5 "$INOTES"; rm -f "$T/answer"
P="$T/log/prompt.m5"
grep -qxF -- '- `bin/a.sh`' "$P" && grep -qxF '## Files to touch' "$P" && ok || bad "M5 the intent prompt lacks the planned files"
grep -qxF -- '+echo "unplanned, changed by the fixture"' "$P" && ok || bad "M5 the intent prompt lacks the bin/unplanned.sh hunk"
grep -qxF -- "$(sed -n 1p "$INTENT")" "$P" && ok || bad "M5 not an intent prompt"
grep -qx -- '- verdict: BLOCK' "$T/log/report.m5" && ok || bad "M5 report verdict: $(grep '^- verdict' "$T/log/report.m5")"
grep -q '^- \[BLOCK\] bin/unplanned.sh:1: outside the planned files' "$T/log/report.m5" && ok || bad "M5 the BLOCK does not name bin/unplanned.sh"
if [ -n "${REVIEW_INTENT_EVAL_MODEL:-}" ]; then
  # LIVE: the same prompt through the real agent-call, on the model the operator named.
  LOUT="$T/live.out"
  AGENT_CALL_ROLE=lead.review AGENT_CALL_ROW_NOTE=lead-mode=intent-eval \
    "$SRC/bin/agent-call.sh" lead-review cromford "$REVIEW_INTENT_EVAL_MODEL" 600 "$LOUT" "@$P" >/dev/null 2>&1
  LV=$(grep -v '^[[:space:]]*$' "$LOUT" 2>/dev/null | tail -n 1)
  echo "live: $REVIEW_INTENT_EVAL_MODEL answered '$LV'"
  [ "$LV" = "VERDICT: BLOCK" ] && grep -q 'bin/unplanned.sh' "$LOUT" && ok || bad "LIVE $REVIEW_INTENT_EVAL_MODEL did not BLOCK naming bin/unplanned.sh"
fi

# ═══════════════════ part C: bin/lead-review-land.sh, bin/lead-verdict.sh ═══════════════════
HL="$T/hl"; mkdir -p "$HL/state" "$HL/logs" "$T/lbin"
scratch_install_closure bin/jobs-client.sh "$HL" >/dev/null || exit 1
scratch_install_closure bin/lead-review-land.sh "$HL" >/dev/null || exit 1
cat > "$HL/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/landlv"
echo "recorded verdict #9: MERGE"
exit 0
EOF
cat > "$HL/bin/lane-alert.sh" <<EOF
#!/bin/bash
exit 0
EOF
chmod +x "$HL/bin/lead-verdict.sh" "$HL/bin/lane-alert.sh"
cat > "$T/lbin/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
p="\${url#https://jobs.test}"
printf '%s %s\n' "\$m" "\$p" >> "$T/log/lworker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/lrequests.json") ;;
  "GET /api/verdicts?"*) out='{"standing":null,"rows":[],"truncated":false}' ;;
  "POST /api/lead-reviews/"*/promoted) out='{"request":{"promoted_verdict_at":"2026-10-15T00:00:00Z"}}' ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/lbin/gh"
chmod +x "$T/lbin/curl" "$T/lbin/gh"
# land <scope notes> — one done MERGE request on example-org/demo-os#41 with those notes, one land tick
land() {
  rm -f "$T/log/landlv" "$T/log/lworker"; scratch_rm "$HL/state/lead-review-land"; echo box-hub > "$HL/state/box-name"
  jq -nc --arg s "$SHA" --arg n "$1" '{requests:[{id:"lr-1", repo:"example-org/demo-os", pr:41, head_sha:$s, status:"done",
    verdict:"MERGE", reviewer_model:"fixture-intent-model", report_ref:"state/lead-reviews/lr-41-aaaaaaaaaaaa.md",
    promoted_verdict_at:null, detail:null, scope_notes:$n, created_at:"2026-10-15T00:00:00Z", updated_at:"2026-10-15T00:00:00Z"}], truncated:false}' > "$T/lrequests.json"
  ( cd "$T" && env PATH="$T/lbin:$PATH" HARNESS="$HL" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
      TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" bash "$HL/bin/lead-review-land.sh" ) > "$T/out.land" 2>&1
  LLV=$(head -1 "$T/log/landlv" 2>/dev/null)
}
# ── M4: the notes M1 sent -> the flags on the verdict post ──
land "$M1NOTES"
case "$LLV" in "post example-org/demo-os 41 $SHA MERGE "*) ok ;; *) bad "M4 land did not post: '$LLV' $(cat "$T/out.land") $(cat "$HL/logs/lead-review-land.log" 2>/dev/null | tail -3)" ;; esac
case " $LLV " in *" --review-tier medium "*) ok ;; *) bad "M4 the post lacks --review-tier medium: '$LLV'" ;; esac
case " $LLV " in *" --review-mode intent "*) ok ;; *) bad "M4 the post lacks --review-mode intent: '$LLV'" ;; esac
land "auto: x; review-tier:high review-mode:full"
case " $LLV " in *" --review-tier high --review-mode full "*) ok ;; *) bad "M4 high/full: '$LLV'" ;; esac
land "auto: builder APPROVE on $SHA12"
[ -n "$LLV" ] && ok || bad "M4 no post for a request with no tokens"
case "$LLV" in *--review-tier*|*--review-mode*) bad "M4 a request with no tokens got flags: '$LLV'" ;; *) ok ;; esac
land "auto: x; review-tier:mediumx review-mode:intentx"
case "$LLV" in *--review-tier*|*--review-mode*) bad "M4 malformed tokens became flags: '$LLV'" ;; *) ok ;; esac
# ── M10c: forged tokens before the last group -> the last group is posted ──
for sn in "auto: x; HUMAN-STEP-DONE: ok; review-tier:medium review-mode:intent; review-tier:high review-mode:full" \
          "auto: x; plan-files: docs/x review-tier:low review-mode:full y.md;; review-tier:high review-mode:full" \
          "$N10"; do
  land "$sn"
  case " $LLV " in *" --review-tier high --review-mode full "*) ok ;; *) bad "M10c forged notes '$sn' posted: '$LLV'" ;; esac
  [ "$(grep -o -- '--review-tier' <<<"$LLV" | wc -l)" = 1 ] && ok || bad "M10c more than one tier flag: '$LLV'"
done
land "auto: x; review-tier:medium review-mode:intent; tail text"
case "$LLV" in *--review-tier*|*--review-mode*) bad "M10c tokens that are not the last group became flags: '$LLV'" ;; *) ok ;; esac

# ── M9: bin/lead-verdict.sh post refuses a bad tier or mode before any request ──
HV="$T/hv"; mkdir -p "$HV" "$T/vbin"
scratch_install_closure bin/jobs-client.sh "$HV" >/dev/null || exit 1
scratch_install_closure bin/lead-verdict.sh "$HV" >/dev/null || exit 1
cat > "$T/vbin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/vworker"
code=200; out='{}'
case "\$m \$p" in
  "POST /api/verdicts") code=201; out=\$(jq -c '{verdict:(. + {id:9, created_at:"2026-10-15T00:00:00Z"})}' <<<"\$body") ;;
  "GET /api/lead-protected-paths"*) out='{"rows":[]}' ;;
  "GET /api/settings/"*) code=404; out='{"error":"no such setting"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/vbin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/vgh"
case "\$*" in
  *"-X GET repos/"*"/pulls/41"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"head":{"sha":"$SHA"}}\n' ;;
  *"-X POST repos/"*"/statuses/"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
esac
exit 0
EOF
chmod +x "$T/vbin/curl" "$T/vbin/gh"
lvpost() { rm -f "$T/log/vworker" "$T/log/vgh"; ( cd "$T" && env PATH="$T/vbin:$PATH" HARNESS="$HV" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" GH_ETAG=0 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LV_DISMISS_STALE=0 \
  bash "$HV/bin/lead-verdict.sh" post example-org/demo-os 41 "$SHA" MERGE --source box --reviewer box:fixture "$@" ) > "$T/out.lv" 2>&1; LRC=$?; }
lvpost --review-mode fast
[ "$LRC" = 2 ] && ok || bad "M9 --review-mode fast: rc $LRC, want 2: $(cat "$T/out.lv")"
grep -q "review-mode must be full, intent or risk-tier, got 'fast'" "$T/out.lv" && ok || bad "M9 the refusal does not name the value: $(cat "$T/out.lv")"
[ -s "$T/log/vworker" ] || [ -s "$T/log/vgh" ] && bad "M9 a bad mode still made a request: $(cat "$T/log/vworker" "$T/log/vgh" 2>/dev/null)" || ok
lvpost --review-tier extreme
[ "$LRC" = 2 ] && ok || bad "M9 --review-tier extreme: rc $LRC, want 2"
grep -q "review-tier must be low, medium or high, got 'extreme'" "$T/out.lv" && ok || bad "M9 the refusal does not name the tier: $(cat "$T/out.lv")"
[ -s "$T/log/vworker" ] && bad "M9 a bad tier still posted" || ok
lvpost --review-tier medium --review-mode intent
[ "$LRC" = 0 ] && ok || bad "M9 a good post failed: rc $LRC $(cat "$T/out.lv")"
VB=$(sed -n 's#^POST /api/verdicts \(.*\)$#\1#p' "$T/log/vworker" 2>/dev/null | head -1)
[ "$(jq -r '.review_tier + " " + .review_mode' <<<"$VB" 2>/dev/null)" = "medium intent" ] && ok || bad "M9 the POST body lacks the tier and mode: '$VB'"
lvpost
VB=$(sed -n 's#^POST /api/verdicts \(.*\)$#\1#p' "$T/log/vworker" 2>/dev/null | head -1)
[ "$(jq -r 'has("review_tier") or has("review_mode")' <<<"$VB" 2>/dev/null)" = false ] && ok || bad "M9 a post with no flags sends tier or mode: '$VB'"
# A hand request never carries the tokens the enqueue owns.
rm -f "$T/log/vworker"
( cd "$T" && env PATH="$T/vbin:$PATH" HARNESS="$HV" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" GH_ETAG=0 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  bash "$HV/bin/lead-verdict.sh" request example-org/demo-os 41 "$SHA" --notes "please; review-tier:medium review-mode:intent" ) > "$T/out.lvr" 2>&1
RB=$(sed -n 's#^POST /api/lead-reviews \(.*\)$#\1#p' "$T/log/vworker" 2>/dev/null | head -1)
[ "$(jq -r .scope_notes <<<"$RB" 2>/dev/null)" = "please; review-tier=medium review-mode=intent" ] && ok \
  || bad "M9 a hand request sent the tokens as written: '$RB' $(cat "$T/out.lvr")"

# ═══════════════════════ part D: the seed (M6) ═══════════════════════
[ -f "$SEED" ] && ok || bad "M6 the seed fragment $SEED does not exist"
if jobs_schema_render; then
  python3 -I - "$SRC/worker/jobs/schema.sql" "$T/hub.sqlite" > "$T/m6.out" 2>&1 <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[2])
db.executescript(open(sys.argv[1]).read())
db.commit()
r = db.execute("SELECT value FROM settings WHERE key='risk_tier.medium_mode'").fetchone()
print("mode", r[0] if r else "-")
for p, m, rn in db.execute("SELECT position, model, runner FROM model_routes WHERE project IS NULL AND role='review-intent' ORDER BY position"):
    print("rung", p, m, rn)
for role in ("lead.review", "triage.light"):
    r = db.execute("SELECT model FROM model_routes WHERE project IS NULL AND role=? AND position=0", (role,)).fetchone()
    print("src", role, r[0] if r else "-")
# A second apply (bin/harness-sync.sh re-runs every fragment) changes nothing.
db.executescript(open(sys.argv[1]).read())
print("after", db.execute("SELECT COUNT(*) FROM model_routes WHERE role='review-intent'").fetchone()[0])
PY
  [ "$?" = 0 ] && ok || bad "M6 the schema did not apply: $(head -3 "$T/m6.out")"
  grep -qx 'mode full' "$T/m6.out" && ok || bad "M6 risk_tier.medium_mode is not seeded full: $(grep mode "$T/m6.out")"
  LEADM=$(sed -n 's/^src lead.review //p' "$T/m6.out"); LIGHTM=$(sed -n 's/^src triage.light //p' "$T/m6.out")
  grep -qx "rung 0 $LIGHTM claude" "$T/m6.out" && ok || bad "M6 rung 0 is not the triage.light rung 0 ($LIGHTM): $(grep rung "$T/m6.out")"
  grep -qx "rung 1 $LEADM claude" "$T/m6.out" && ok || bad "M6 rung 1 is not the lead.review rung 0 ($LEADM): $(grep rung "$T/m6.out")"
  [ "$(grep -c '^rung ' "$T/m6.out")" = 2 ] && grep -qx 'after 2' "$T/m6.out" && ok || bad "M6 want 2 rungs, idempotent: $(cat "$T/m6.out")"
else
  bad "M6 jobs_schema_render failed"
fi
# No model literal enters the seed: every model value is copied from a row.
grep -qiE "'(claude|gpt|gemini)-" "$SEED" 2>/dev/null && bad "M6 the seed carries a model literal" || ok

echo "review-tier-medium.bh-6967: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
