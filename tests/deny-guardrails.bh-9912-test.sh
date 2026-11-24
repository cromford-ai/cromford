#!/bin/bash
# tests/deny-guardrails.bh-9912-test.sh — the knob-gated deny layer (BH-9912).
#
# Two halves, both DRIVEN (no source greps):
#   * bin/iron-law-guard.sh family 8 (DENY_GUARDRAILS=1, guarded lanes only):
#     `gh api` merge calls, `wrangler d1 … --remote` writes, and the
#     `pnpm|yarn|bun <bin>` runner forms. Real PreToolUse payloads on stdin; the
#     rc, the stderr reason and the findings.log row are read back off disk.
#   * bin/deny-guardrails-settings.json + bin/agent-call.sh: run for real with a
#     fake claude that dumps its argv, so what reaches the CLI's
#     --disallowedTools and --settings is read out of that file.
#
# Sections:
#   A  family 8 denies with the knob on          B  the knob: off means off
#   C  look-alikes stay allowed                  D  the deny list itself
#   E  the agent-call wiring
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/bin/lib" "$T/fakebin" "$T/repo"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

GUARD="$DIR/bin/iron-law-guard.sh"
FRAG="$DIR/bin/deny-guardrails-settings.json"
# A git repo on a ticket branch, so an agent-push deny has a HEAD to read and
# never reaches for a live hold read (no hold-push.sh in $T/bin/lib).
git -C "$T/repo" init -q -b ticket/bh-9912 2>/dev/null || { git -C "$T/repo" init -q; git -C "$T/repo" checkout -q -b ticket/bh-9912; }

payload() { # payload <command> [cwd]
  jq -nc --arg c "$1" --arg d "${2:-$T/repo}" \
    '{session_id:"s1",hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}'
}
# guard <lane|-> <knob|-> <command> — prints the rc; stderr lands in $T/err.
# `-` for the lane = an unmarked session; `-` for the knob = DENY_GUARDRAILS unset.
guard() {
  local lane="$1" knob="$2" cmd="$3"
  local -a e=(env -u HARNESS_LANE -u DENY_GUARDRAILS PATH="$PATH" HARNESS="$T"
              HARNESS_LANE_PROJECT=testproj HARNESS_TICKET=BH-9912)
  [ "$lane" = - ] || e+=(HARNESS_LANE="$lane")
  [ "$knob" = - ] || e+=(DENY_GUARDRAILS="$knob")
  payload "$cmd" | timeout 30 "${e[@]}" bash "$GUARD" >/dev/null 2>"$T/err"
  echo $?
}
frows() { grep -c "family=actguard-$1 " "$T/logs/findings.log" 2>/dev/null || true; }

# --- A. family 8 denies with the knob on ------------------------------------
A_API=$(cat <<'X'
gh api -X PUT repos/o/r/pulls/5/merge
gh api repos/o/r/pulls/5/merge --method put -f merge_method=squash
rtk gh api -XPUT /repos/o/r/pulls/5/merge
cd /tmp && gh api -X POST repos/o/r/merges -f base=main -f head=x
gh api repos/o/r/merges -f base=main -f head=x
gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:"X"}){clientMutationId}}'
gh api graphql -f query='mutation{enablePullRequestAutoMerge(input:{pullRequestId:"X"}){clientMutationId}}'
gh api --method PUT -H "Accept: application/vnd.github+json" /repos/o/r/pulls/5/merge
gh api -H "Accept: application/vnd.github+json" -X PUT repos/o/r/pulls/5/merge
gh api --method PUT -H 'Accept: application/vnd.github+json' repos/o/r/pulls/5/merge
gh api -X PUT repos/o/r/pulls/5/merge -H "X-GitHub-Api-Version: 2022-11-28"
gh api --header "Accept: application/vnd.github+json" repos/o/r/merges -f base=main -f head=x
X
)
A_D1=$(cat <<'X'
wrangler d1 execute harness-jobs --remote --command "DELETE FROM jobs WHERE id=1"
npx wrangler d1 execute db --remote --file=x.sql
wrangler d1 execute db --command "update t set a=1" --remote
wrangler d1 migrations apply db --remote
pnpm exec wrangler d1 execute db --remote --file a.sql
yarn wrangler d1 execute db --remote --command "INSERT INTO t VALUES (1)"
wrangler d1 execute db --command "DELETE FROM t WHERE id IN (1)" --remote
wrangler d1 execute db --command "SELECT 1; DROP TABLE t" --remote
wrangler d1 execute db --remote --command "SELECT 1; DELETE FROM t" && echo ok
wrangler d1 execute db --remote --command "SELECT a||b FROM t; UPDATE t SET a=1"
X
)
A_RUN=$(cat <<'X'
prisma-live-db|pnpm prisma db push
prisma-live-db|yarn prisma migrate deploy
vercel-deploy|pnpm vercel --prod
prisma-live-db|bun prisma db push
pr-merge|pnpm gh pr merge 3
X
)

# A1/A2: rc 2, the model's reason, and exactly ONE findings row per block.
for pair in "dg-api-merge:A_API" "dg-d1-remote:A_D1"; do
  rule="${pair%%:*}"; var="${pair#*:}"
  while IFS= read -r CMD; do
    [ -n "$CMD" ] || continue
    before=$(frows "$rule")
    RC=$(guard execute 1 "$CMD")
    [ "$RC" = 2 ] && ok || { bad "A $rule: NOT DENIED (rc=$RC): $CMD"; continue; }
    grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" \
      && ok || bad "A $rule: denied with no reason for the model: $CMD"
    after=$(frows "$rule")
    [ "$((after - before))" = 1 ] && ok || bad "A $rule: want exactly 1 new family=actguard-$rule row, got $((after - before)): $CMD"
  done <<<"${!var}"
done
# A3: the runner forms reach families 1/3/5 one level down.
while IFS='|' read -r rule CMD; do
  [ -n "$CMD" ] || continue
  RC=$(guard execute 1 "$CMD")
  [ "$RC" = 2 ] && grep -q "family=actguard-$rule .*$CMD" "$T/logs/findings.log" \
    && ok || bad "A3 runner form not denied as $rule (rc=$RC): $CMD"
done <<<"$A_RUN"
# No family-8 block is an ALERT: these are authority families like 1-5.
grep -q 'actguard-dg\|wrangler\|gh api' "$T/logs/ALERTS.log" 2>/dev/null \
  && bad "a family-8 block wrote an ALERTS line" || ok

# Family 8 is fenced to the guarded lanes: orchestrator, greenfield (marked,
# FULL=0) and an unmarked session are not judged by it.
for lane in orchestrator greenfield -; do
  while IFS= read -r CMD; do
    [ -n "$CMD" ] || continue
    RC=$(guard "$lane" 1 "$CMD")
    [ "$RC" = 0 ] && ok || bad "A fence: lane '$lane' was judged by family 8 (rc=$RC): $CMD"
  done <<<"$A_API
$A_D1"
done

# --- B. the knob: only the literal 1 turns family 8 on ----------------------
: > "$T/logs/findings.log"
for knob in - 0 yes 2 ""; do
  while IFS= read -r CMD; do
    [ -n "$CMD" ] || continue
    RC=$(guard execute "$knob" "$CMD")
    [ "$RC" = 0 ] && ok || bad "B1 knob='$knob' (off) still denied (rc=$RC): $CMD"
  done <<<"$A_API
$A_D1
$(cut -d'|' -f2 <<<"$A_RUN")"
done
[ "$(frows 'dg-api-merge')$(frows 'dg-d1-remote')" = "00" ] \
  && ok || bad "B1 the knob off still wrote family-8 findings rows"
# B2: families 1-5 judge the same with the knob off and on.
for knob in - 1; do
  for CMD in "gh pr merge 1" "git push origin HEAD:main" "git push -f origin ticket/x" "prisma db push"; do
    RC=$(guard execute "$knob" "$CMD")
    [ "$RC" = 2 ] && grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" \
      && ok || bad "B2 knob='$knob' changed an existing family: rc=$RC for $CMD"
  done
done

# --- C. look-alikes stay allowed, knob on, lane execute ---------------------
C_ALLOW=$(cat <<'X'
gh api repos/o/r/pulls/5/merge
gh api repos/o/r/pulls/5/merge -X GET
gh api repos/o/r/pulls/5 --jq .mergeable
gh api repos/o/r/git/refs/heads/merge-queue
gh api graphql -f query='{repository(owner:"o",name:"r"){pullRequest(number:5){merged mergeable}}}'
gh pr view 5 --json mergeable
git commit -m "gh api -X PUT repos/o/r/pulls/5/merge"
grep -rn "pulls/5/merge" bin/
gh api -H "Accept: application/vnd.github+json" repos/o/r/pulls/5/merge
gh api -H "Accept: application/vnd.github+json" repos/o/r/pulls/5/merge -X GET
gh api -X PUT -H "X-Note: pulls/5/merge" repos/o/r/pulls/5/reviews/1/dismissals
wrangler d1 execute db --local --command "DELETE FROM t"
wrangler d1 execute db --command "DELETE FROM t"
wrangler d1 execute db --remote --command "SELECT count(*) FROM jobs"
wrangler d1 execute db --remote --command "SELECT * FROM last_update"
wrangler d1 execute db --remote --command "SELECT 1" && echo "update done"
wrangler d1 list
wrangler d1 export db --remote --output x.sql
wrangler d1 migrations list db --remote
grep -n "wrangler d1 execute --remote" docs/x.md
pnpm install
yarn build
pnpm test
pnpm prisma generate
npm run prisma:push
pnpm exec tsc --noEmit
bin/archie-merge.sh 9914
/root/harness/bin/archie-merge.sh 9914 --sha abc
X
)
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  RC=$(guard execute 1 "$CMD")
  [ "$RC" = 0 ] && ok || bad "C look-alike denied (rc=$RC): $CMD :: $(head -c 200 "$T/err")"
done <<<"$C_ALLOW"
# C4: the harness's own push (unmarked) and a non-guarded lane push a ticket branch.
[ "$(guard - 1 'git push origin ticket/bh-9912')" = 0 ] && ok || bad "C4 an unmarked session's ticket push was denied"
[ "$(guard greenfield 1 'git push origin ticket/bh-9912')" = 0 ] && ok || bad "C4 greenfield's ticket push was denied"
# The near-miss that stays denied by design (BH-2741 agent-push).
[ "$(guard execute 1 'git push origin ticket/x')" = 2 ] && ok || bad "C4 agent-push in lane execute stopped being denied"

# --- D. the deny list --------------------------------------------------------
jq -e '.permissions.deny | length > 0 and all(test("^Bash\\(.+:\\*\\)$"))' "$FRAG" >/dev/null 2>&1 \
  && ok || bad "D1 $FRAG is missing, empty, or carries a spec not shaped Bash(<prefix>:*)"
mapfile -t SPECS < <(jq -r '.permissions.deny[]' "$FRAG" 2>/dev/null)
mapfile -t PFX < <(printf '%s\n' "${SPECS[@]}" | sed -E 's/^Bash\((.*):\*\)$/\1/')
NB=0
for p in "${PFX[@]}"; do
  case "$p" in rtk\ *) continue ;; esac
  NB=$((NB+1))
  grep -qxF "rtk $p" < <(printf '%s\n' "${PFX[@]}") && ok || bad "D1 spec '$p' has no rtk twin"
  for s in "$p x" "rtk $p x"; do
    RC=$(guard execute 1 "$s")
    [ "$RC" = 2 ] && ok || bad "D1 the deny list names '$p' but the guard allows '$s' (rc=$RC)"
  done
done
for want in "git push origin main" "git push origin master" "git push origin HEAD:main" "gh pr merge" \
            "prisma db push" "prisma migrate deploy" "vercel deploy --prod"; do
  grep -qxF "$want" < <(printf '%s\n' "${PFX[@]}") && ok || bad "D1 the deny list lacks the ticket's '$want'"
done
[ "$NB" -gt 0 ] && ok || bad "D1 no spec was checked"
# D2: no spec prefix-matches an allowed look-alike.
for L in "git push origin ticket/bh-9912" "git push -u origin ticket/x" "bin/archie-merge.sh 1" "gh pr view 1" \
         "wrangler d1 execute db --local --command x" "pnpm prisma generate"; do
  hit=""
  for p in "${PFX[@]}"; do case "$L" in "$p"|"$p "*) hit="$p" ;; esac; done
  [ -z "$hit" ] && ok || bad "D2 deny spec '$hit' would block the look-alike '$L'"
done

# --- E. the agent-call wiring ------------------------------------------------
scratch_install_closure bin/iron-law-guard.sh "$T" >/dev/null || bad "E could not install the guard closure"
cp "$FRAG" "$T/bin/"   # a JSON fragment, not a lib: it has no closure
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$T_SENTINEL_DIR/argv.txt"
env > "$T_SENTINEL_DIR/env.txt"
echo '{"result":"ok","usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0.01}'
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
chmod +x "$T/fakebin/"* "$T/bin/beat.sh" "$T/bin/iron-law-guard.sh"
call() { # call <stage> [env assignments...]
  local stage="$1"; shift
  rm -f "$T/argv.txt" "$T/env.txt"
  ( export T_SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env -u HARNESS_LANE -u HARNESS_LANE_PROJECT -u HARNESS_LANE_WT -u HARNESS_LANE_BUILD_DIR \
        -u DENY_GUARDRAILS -u AGENT_DISALLOWED_TOOLS -u AGENT_SETTINGS \
        "$@" bash "$DIR/bin/agent-call.sh" "$stage" testproj claude-opus-5 600 "$T/out.txt" "hi" >/dev/null 2>&1 )
}
settings_arg() { grep -A1 -x -- '--settings' "$T/argv.txt" 2>/dev/null | tail -1; }
# The specs after --disallowedTools (one variadic flag: every later argv entry
# up to the next flag).
dt_specs() { awk 'f && /^--/ {exit} f {print} $0=="--disallowedTools" {f=1}' "$T/argv.txt" 2>/dev/null; }
WANT=$(jq -r '.permissions.deny[]' "$FRAG" | sort)

# E1: execute + knob on.
call execute DENY_GUARDRAILS=1
[ "$(dt_specs | sort)" = "$WANT" ] && ok || bad "E1 --disallowedTools does not carry exactly the fragment's specs: $(dt_specs | head -3)"
[ "$(grep -c -x -- '--disallowedTools' "$T/argv.txt" 2>/dev/null)" = 1 ] && ok || bad "E1 want exactly one --disallowedTools flag"
S=$(settings_arg)
[ "$(jq -r '.permissions.deny[]' "$S" 2>/dev/null | sort)" = "$WANT" ] \
  && ok || bad "E1 the --settings file's .permissions.deny is not the fragment's: $(cat "$S" 2>/dev/null | head -c 300)"
[ "$(jq -r '.hooks.PreToolUse[-1].hooks[0].command' "$S" 2>/dev/null)" = "$T/bin/iron-law-guard.sh" ] \
  && ok || bad "E1 the guard is not the last PreToolUse hook in the merged settings"
grep -qx 'DENY_GUARDRAILS=1' "$T/env.txt" 2>/dev/null && ok || bad "E1 the knob never reached the claude process, so the hook cannot see it"
grep -q '^-p$' "$T/argv.txt" && ok || bad "E1 claude did not run"

# E2: knob off (unset and 0): neither layer.
for k in "" DENY_GUARDRAILS=0; do
  call execute ${k:+"$k"}
  ! grep -qx -- '--disallowedTools' "$T/argv.txt" && ok || bad "E2 knob '${k:-unset}' still passed --disallowedTools"
  S=$(settings_arg)
  [ -n "$S" ] && [ "$(jq -r 'has("permissions")' "$S" 2>/dev/null)" = false ] \
    && ok || bad "E2 knob '${k:-unset}' still put a permissions key in --settings"
done

# E3: a non-guarded stage gets no specs; the remediate stage keeps its own list.
call orchestrator DENY_GUARDRAILS=1
! grep -q '^Bash(' "$T/argv.txt" && ok || bad "E3 the orchestrator stage got deny specs"
call remediate DENY_GUARDRAILS=1 AGENT_DISALLOWED_TOOLS='Bash(own-spec:*)'
[ "$(dt_specs)" = 'Bash(own-spec:*)' ] && ok || bad "E3 remediate's AGENT_DISALLOWED_TOOLS list changed: $(dt_specs | tr '\n' ' ')"

# E4: knob on + fragment missing: ONE ALERTS line per call, and the call runs.
rm -f "$T/bin/deny-guardrails-settings.json"
: > "$T/logs/ALERTS.log"
call execute DENY_GUARDRAILS=1
[ "$(grep -c 'deny layer MISSING' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "E4 want exactly 1 'deny layer MISSING' ALERTS line, got: $(cat "$T/logs/ALERTS.log")"
grep -q '^-p$' "$T/argv.txt" && ok || bad "E4 a missing deny fragment stopped the stage from running"
[ "$(jq -r '.hooks.PreToolUse[-1].hooks[0].command' "$(settings_arg)" 2>/dev/null)" = "$T/bin/iron-law-guard.sh" ] \
  && ok || bad "E4 the hook guard was lost when the deny fragment was missing"

echo "deny-guardrails: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
