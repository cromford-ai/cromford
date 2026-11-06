#!/bin/bash
# Fleet Claude-auth monitor (the operator, 2026-07-29, after the 4-box silent logout).
# Hourly from the HUB, on every box: the credential probe (`cred_probe claude`,
# bin/lib/cred-probe.sh), plus once per account per UTC day the end-to-end
# inference probe below — the only check that proves token + account + API
# together — bought through agent-call.sh and only when cred_inference_claim
# says so (BH-2560). One alert per outage per box (state-deduped), one recovery
# line when it comes back. docs/AUTH-PROBE.md has the classification table.
set -uo pipefail
# Overridable so a fixture can drive the canaries below against a scratch tree;
# cron never sets it, so production resolves to exactly the path it always has.
H="${HARNESS:-/root/harness}"
# The credential-probe contract (BH-2558). Overridable so a suite can inject a
# stub lib; a box without it probes as the contract's stub does (see cred_lib_load).
CRED_PROBE_LIB="${CRED_PROBE_LIB:-$H/bin/lib/cred-probe.sh}"
# Library mode (tests source this file for classify_probe): define, touch
# nothing, return. Before 2026-09-15 the early return sat after the box loop,
# so sourcing still created state/locks under $H and took the flock.
if [ -n "${AUTH_CHECK_LIB:-}" ]; then _AUTH_CHECK_LIB_ONLY=1; else _AUTH_CHECK_LIB_ONLY=0; fi
STATE=$H/state/claude-auth-down.txt
[ "$_AUTH_CHECK_LIB_ONLY" = 1 ] || { mkdir -p "$H/state" "$H/locks" "$H/flags" "$H/logs" 2>/dev/null; touch "$STATE"
exec 9>$H/locks/auth-check.lock; flock -n 9 || exit 0
}
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# >>> gh default auth
# BH-470, #424. This monitor makes no `gh` call of its own — its only GitHub
# traffic is gh_visibility_canary below, and that question is PAT-only by design
# (BH-765). So the wiring here is deliberately BELOW the canary's own probe: see
# the call site. Both sources are functions-only and fail-open, so they are safe
# in library mode (a test sourcing this file for classify_probe) as well as on a
# box whose bin/lib/ predates #469.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$H/bin/lib/gh-limit-logger.sh" ] && . "$H/bin/lib/gh-limit-logger.sh"
# <<< gh default auth
# BH-1674: the runner canary below marks, clears and announces lane-down state
# through the shared contract (bin/lane-reprobe.sh uses the same one). Functions
# only, so library mode stays side-effect free; missing = the inline path.
# shellcheck source=bin/lib/lane-down.sh
[ -r "$H/bin/lib/lane-down.sh" ] && . "$H/bin/lib/lane-down.sh"
# THE BOXES COME FROM fleet.conf (2026-09-11), not from a copy of the IP table.
# The label is the box's short name (box-<label>) and the address is
# its `tailnet_ip` column; a box with no address is skipped rather than probed
# at `root@`. `hub` stays literal — it is this machine, not an ssh target.
declare -A BOXES=( [hub]=local )
while read -r _BX; do
  [ -n "$_BX" ] || continue
  _IP=$("$H/bin/fleet-conf.sh" --tailnet-ip-of-box "$_BX" 2>/dev/null) || continue
  [ -n "$_IP" ] || continue
  BOXES["${_BX#box-}"]="$_IP"
done < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null \
         | while read -r _P; do "$H/bin/box-for.sh" "$_P" 2>/dev/null; done \
         | grep -v '^local$' | sort -u)
# The probe must exercise the LADDER, not one model (2026-08-14 incident): a dry
# fable pool answers "out of usage credits", which the old single-model probe
# reported as CLAUDE AUTH DOWN — sending the operator to a re-login that fixes nothing
# while the pipelines were healthy the whole time, already degraded to opus on
# the same token. Credits-exhausted and auth-dead are different outages with
# different remedies, so probe the fallback before calling anything down.
# PROBE_BODY is the ladder itself (env already sourced by the caller). It runs
# only for this machine's accounts (hub, project-1-lane), through local_claude_probe;
# a remote box runs its own `lane-probe.sh claude --endpoint` (BH-2560).
# A KILLED PROBE IS NOT AN ANSWER (2026-08-27). The hub probe came back blank
# with rc=137 — SIGKILL, i.e. something killed the process before Claude ever
# replied — and the old classifier read "no ok in the output" as CLAUDE AUTH
# DOWN. That paged the operator to re-login an account that was healthy, and downstream
# every lane that trusts "auth is dead" starts buying the same work from another
# vendor. So the probe now reports its exit code, retries once on a kill, and
# says INCONCLUSIVE rather than letting silence masquerade as evidence.
# >>> model-route (BH-1510.2): the ladder the probe climbs is model_routes role
# `auth.canary` (M; seeded as a copy of bootstrap.smoke rung 0, a Haiku-class
# model) then role `auth.fallback` (F), resolved HERE, once, and written into the
# probe as its defaults — a box's own AUTH_CANARY_MODEL / AUTH_FALLBACK_MODEL
# still win there. TRIAGE_MODEL does not steer the canary. When the auth.canary
# route cannot be read (a hub synced before the worker schema applied), M falls
# back to role `triage`: bin/lib/model-route.sh already wrote its ALERTS line
# naming auth.canary, and the probe still runs. No route at all = rc 75 with no
# probe run (a probe of a guessed model would page on the guess). The charset
# check keeps a DB value from becoming shell text.
# Library mode (AUTH_CHECK_LIB=1: tests source this file for its functions and
# never run a probe) resolves nothing and leaves both empty.
PROBE_M=""; PROBE_F=""
if [ "${_AUTH_CHECK_LIB_ONLY:-0}" != 1 ]; then
  . "$H/bin/lib/lane-model.sh"
  { PROBE_M=$(lane_role_model auth.canary) || PROBE_M=$(lane_role_model triage); } && PROBE_F=$(lane_role_model auth.fallback) \
    || { HARNESS="$H" "$H/bin/alert-line.sh" "[auth] no model route for auth.canary (or triage)/auth.fallback — auth probe not run"; exit 75; }
  case "$PROBE_M$PROBE_F" in *[!A-Za-z0-9._/:-]*)
    HARNESS="$H" "$H/bin/alert-line.sh" "[auth] refusing model route values with shell characters: '$PROBE_M' / '$PROBE_F'"; exit 75 ;; esac
fi
# <<< model-route
# THE VERDICT IS THE EXIT CODE AND A SENTINEL, NEVER PROSE (V1 alert hygiene,
# 2026-09-25). The probe used to ask "say ok", keep the LAST line of the answer
# and grep it for oauth|authorization|/login. A model that answered "ok" and then
# added a note that the Vercel MCP plugin "needs authorization ... cannot run the
# OAuth flow" paged CLAUDE AUTH DOWN / AUTH PROBE INCONCLUSIVE on every box, every
# day, on healthy accounts. Now the prompt asks the model to JOIN a word and a
# per-run random code with a hyphen (AUTHPROBE-<nonce>): the token is fresh every
# run and never appears literally in the prompt, so an error that echoes the
# request back cannot pass for an answer (review of #2290).
#   rc 0 AND the token            -> PROBE_OK (the account answered; nothing else
#                                     in the text is read)
#   rc 0, no token                -> PROBE_NOSENTINEL (inconclusive, the prose is
#                                     never judged), or PROBE_CLIAUTH (AUTH DOWN)
#                                     when the CLI's own logged-out phrase is on
#                                     stderr or starts a line
#   CLI credits refusal, any rc   -> the fallback; DEGRADED if it answers (stderr / line start / rc!=0 only)
#   sentinel from ANOTHER model    -> DEGRADED: agent-call's ladder failed over
#                                     ($PF.model names who served), so the asked model did not
#   rc != 0                       -> PROBE_FAILED: the CLI itself refused, and ONLY
#                                     that CLI error text may carry auth evidence
# The marker is the first word of the one line printed; classify_probe below
# reads the marker before anything else.
# THROUGH AGENT-CALL (BH-2560): stage canary, pinned to the claude rung
# (AGENT_CALL_RUNNERS=claude, so no fallback vendor can answer for a dead login),
# lane claude-auth-check, so every probe writes a priced cost row. ACCOUNT_ROUTING=0
# keeps it on the credential this env holds. The CLI's stderr is what agent-call
# leaves in $PF.err; a refusal (rc 74..79, nothing billed) lands as PROBE_FAILED
# with its AGENT_CALL_ marker, which names no credential: inconclusive.
# ONCE PER ACCOUNT PER UTC DAY (BH-9125): local_claude_probe exports
# AUTH_CANARY_FP=canary:claude:<account fp>:<UTC day> after the day claim, and
# ask() passes it as AGENT_CALL_FP on the asked model M. A second probe of the
# day is then a ledger replay (AGENT_LEDGER_CANARY_WINDOW_S), not a second
# purchase. With that fp the nonce is 12 hex of its sha256, so a replayed answer
# carries the sentinel this run asks for. The token is still never literal in
# the prompt (the prompt names the word and the code apart). No fp = a random
# nonce and no caller fp, as before.
# llm-site: claude-auth-check
PROBE_BODY='cd /tmp
AC='"$H"'/bin/agent-call.sh
M="${AUTH_CANARY_MODEL:-'"$PROBE_M"'}"; F="${AUTH_FALLBACK_MODEL:-'"$PROBE_F"'}"
PF=$(mktemp)
if [ -n "${AUTH_CANARY_FP:-}" ]; then N=$(printf "%s" "$AUTH_CANARY_FP" | sha256sum | cut -c1-12)
else N=$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -dc 0-9a-f); [ -n "$N" ] || N=$(date +%s%N | tail -c 13); fi
S="AUTHPROBE-$N"
# Only the asked model M carries the day fp. The fallback rung F is a different
# purchase: under the same fp the ledger would replay the answer of M to it.
ask() { rm -f "$PF.model"; FPA=""; [ "$1" = "$M" ] && FPA="${AUTH_CANARY_FP:-}"
  AGENT_CALL_FP="$FPA" ACCOUNT_ROUTING=0 AGENT_CALL_RUNNERS=claude AGENT_CALL_LANE=claude-auth-check timeout 150 "$AC" canary fleet "$1" 90 "$PF" "Reply with the word AUTHPROBE and the code $N joined by a single hyphen, and nothing else." </dev/null >/dev/null 2>&1; RC=$?
  cat "$PF.err" > "$PF.e" 2>/dev/null || : > "$PF.e"
  O=$(cat "$PF" "$PF.e" | tr "\n\t" "  " | cut -c1-300); SEEN=0; [ "$RC" = 0 ] && grep -qF "$S" "$PF" && SEEN=1
  # agent-call walks its own claude ladder on a failure (credits included) and
  # names the model that actually answered in $PF.model. An answer from ANY
  # other model is not the asked model serving: SUB carries who did, and the
  # ladder below reads it as DEGRADED (BH-2560 review: a Fable box out of
  # credits was otherwise served on Opus and marked ok).
  SUB=""; SV=$(head -1 "$PF.model" 2>/dev/null)
  [ "$SEEN" = 1 ] && [ -n "$SV" ] && [ "$SV" != "$1" ] && { SEEN=0; SUB="$SV"; }
  # The CLI speaks for itself: any of its phrases on stderr, or on stdout its
  # EXACT message "<Invalid API key|Not logged in> · Please run /login" at a line start. A line merely starting "Not logged in to the X MCP server" is the model (review of #2290).
  CLIAUTH=0; { grep -qE "Invalid API key|Not logged in|Please run /login" "$PF.e" \
    || grep -qE "^[[:space:]]*(Invalid API key|Not logged in) · Please run /login" "$PF"; } && CLIAUTH=1
  # Same rule for a credits refusal: the CLI says it on stderr, at the start of
  # a line, or with a non-zero exit; mid-sentence in an exit-0 answer it is prose.
  CREDITS=0; { grep -qi "usage credits" "$PF.e" || grep -qiE "^[[:space:]]*(Claude( AI)? )?usage credits" "$PF" \
    || { [ "$RC" != 0 ] && grep -qi "usage credits" "$PF"; }; } && CREDITS=1; }
killed() { [ "$SEEN" = 0 ] && [ -z "$SUB" ] && { [ "$RC" = 137 ] || [ "$RC" = 143 ] || [ "$RC" = 124 ] || [ -z "${O//[[:space:]]/}" ]; }; }
ask "$M"
killed && ask "$M"          # one retry: a kill says nothing about the account
if [ "$SEEN" = 1 ]; then
  echo "PROBE_OK rc=$RC model=$M"
elif [ -n "$SUB" ]; then
  echo "DEGRADED $M did not serve; agent-call failed over and $SUB is serving"
elif killed; then
  echo "INCONCLUSIVE probe did not answer (rc=$RC${O:+, output: $O}) — process killed or silent, no credential verdict"
elif [ "$CREDITS" = 1 ]; then
  # A credits refusal climbs the ladder whatever the exit code. If the fallback
  # also fails, the verdict is about the PRIMARY: an exit-0 primary answered, so
  # it is NOSENTINEL (never PROBE_FAILED, whose text would be keyword-read).
  P="$O"; PRC=$RC
  ask "$F"
  if [ "$SEEN" = 1 ] || [ -n "$SUB" ]; then echo "DEGRADED $M is out of usage credits; ${SUB:-$F} is serving"
  elif [ "$PRC" = 0 ]; then echo "PROBE_NOSENTINEL rc=0 model=$M: $P"
  else echo "PROBE_FAILED rc=$PRC model=$M: $P"; fi
elif [ "$RC" = 0 ] && [ "$CLIAUTH" = 1 ]; then
  echo "PROBE_CLIAUTH rc=0 model=$M: $O"
elif [ "$RC" = 0 ]; then
  echo "PROBE_NOSENTINEL rc=0 model=$M: $O"
else
  echo "PROBE_FAILED rc=$RC model=$M: $O"
fi
rm -f "$PF" "$PF".*'

# auth_evidence <probe-output>: does this output actually SAY the credential is
# bad? AUTH DOWN is only ever claimed on positive evidence. Anything else that
# is not "ok" is an inconclusive probe, not a dead account.
auth_evidence() {
  grep -qiE "not logged in|invalid api key|authentication|unauthorized|401|oauth|setup-token|token .*expired|please run /login|/login" <<<"$1"
}
# classify_probe <probe-output>: ok | degraded | inconclusive | authdown.
# Split out so tests/auth-probe-classify-test.sh can drive it directly.
# The PROBE_* markers are judged first and alone: PROBE_OK is ok, PROBE_NOSENTINEL
# (rc 0, the model's own words) is inconclusive WHATEVER those words say, and
# only PROBE_FAILED (the CLI exited non-zero) is searched for credential
# evidence. Unmarked text is the legacy shape and keeps its old reading.
classify_probe() {
  local O="$1"
  grep -q "^DEGRADED " <<<"$O" && { echo degraded; return; }
  grep -q "^INCONCLUSIVE " <<<"$O" && { echo inconclusive; return; }
  grep -q "^PROBE_OK " <<<"$O" && { echo ok; return; }
  # rc 0 without the token is the model talking — EXCEPT the CLI's own fixed
  # logged-out phrases, which the CLI prints itself (review of #2290): those are
  # AUTH DOWN whatever the exit code. Exact CLI strings, not a prose keyword grep.
  # PROBE_CLIAUTH: exit 0, but the CLI's own logged-out phrase on stderr or at
  # the start of a line — the CLI talking, not the model. AUTH DOWN.
  grep -q "^PROBE_CLIAUTH " <<<"$O" && { echo authdown; return; }
  grep -q "^PROBE_NOSENTINEL " <<<"$O" && { echo inconclusive; return; }
  if grep -q "^PROBE_FAILED " <<<"$O"; then
    if auth_evidence "${O#* model=* }"; then echo authdown; else echo inconclusive; fi
    return
  fi
  if grep -qiE "\bok\b" <<<"$O" && ! grep -qi "not logged in" <<<"$O"; then echo ok; return; fi
  if auth_evidence "$O"; then echo authdown; return; fi
  echo inconclusive
}
# inconclusive_note <box> <probe-output>: the probe never got a verdict. Never
# touches auth-down state (so a real outage still alerts once it produces real
# evidence), never tells anyone to re-login, and nags at most once per box per
# day. Killed probes are a box-health question, not a credentials question.
inconclusive_note() {
  local BOX="$1" OUT="$2" IFLAG="$H/flags/authprobe-inconclusive-$1-$(date -u +%Y%m%d)"
  [ -f "$IFLAG" ] && return 0
  touch "$IFLAG"
  HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $BOX AUTH PROBE INCONCLUSIVE: $OUT"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "authprobe:$BOX" --arg id "authprobe-$BOX" \
    --arg l "AUTH PROBE INCONCLUSIVE on $BOX box: $OUT. This is NOT an auth failure and NOT a credits failure — the probe got no verdict: killed or silent twice (check the box: OOM, load, a stray killer), a model answer without the sentinel token (PROBE_NOSENTINEL), or a CLI error that names no credential (PROBE_FAILED). Do not re-login on this alone; pipelines are untouched." \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,line:$l}')" >/dev/null 2>&1
}
# gh_visibility_canary: can the DEFAULT gh PAT see every repo the fleet works?
# (2026-09-12, the 10-hour project-5 loss.) The hub's default token 404s on
# example-org/project-5; every hub lane that listed PRs there ran an empty loop
# for days and nothing said so. This asks the question on purpose, every 6h,
# for every fleet.conf repo (issue-driven ones included — they are rows too).
#
# A STATUS, NOT A DAILY ALERT (BH-2337: 18 alert rows a day for repos the admin
# token covers). Every repo's answer is a ledger row — kind gh_visibility, key
# <slug>, status "default_token_visible=0|1 admin_token_visible=0|1", detail the
# project — which the console reads. A repo the admin token (env/github-admin.env,
# read by name only) covers is that row plus an ALERTS.log audit line when it
# first goes invisible: routed lanes keep working, so it never pages. A repo NO
# token can see is the 2026-09-12 empty loop: ONE critical alert on the
# transition into blind, never repeated, and its recovery resolves it.
# "Already paged" is the row saying blind OR the state file's ghblind-<slug>
# latch, so a ledger outage cannot re-page. Fail-open: no fleet-conf.sh, no gh
# — nothing is claimed; no ledger — the latch still holds it to one page.
GHVIS_KIND=gh_visibility
GHVIS_BLIND="default_token_visible=0 admin_token_visible=0"
# ghvis_db — the ledger verbs from jobs-client, with the caller's shell options
# kept (it sets -uo pipefail at its top level).
ghvis_db() {
  command -v job_ledger_put >/dev/null 2>&1 && return 0
  local o; o=$(set +o)
  # shellcheck source=bin/jobs-client.sh
  [ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" >/dev/null 2>&1
  eval "$o" 2>/dev/null
  return 0
}
# ghvis_was_blind <slug> <latch-id> — rc 0 when this repo has already paged.
ghvis_was_blind() {
  local s
  if command -v job_ledger_get >/dev/null 2>&1; then
    s=$(job_ledger_get "$GHVIS_KIND" "$1" 2>/dev/null) && [ "$s" = "$GHVIS_BLIND" ] && return 0
  fi
  grep -qxF "$2" "$STATE" 2>/dev/null
}
# ghvis_latch <id> on|off — the state file's line for <id>. Under the lane-down
# state lock when bin/lib/lane-down.sh is loaded (BH-2381); a lock timeout is
# not a canary failure, the next run retries. No lib = the unlocked edit.
ghvis_latch() {
  if command -v _ld_state_edit >/dev/null 2>&1; then
    if [ "$2" = on ]; then _ld_state_edit "$H" add "$1"; else _ld_state_edit "$H" del "$1"; fi
    return 0
  fi
  if [ "$2" = on ]; then grep -qxF "$1" "$STATE" 2>/dev/null || echo "$1" >> "$STATE"; return 0; fi
  grep -qxF "$1" "$STATE" 2>/dev/null || return 0
  { grep -vxF "$1" "$STATE" > "$STATE.tmp" || true; } && mv "$STATE.tmp" "$STATE"
}
# ghvis_resolve <slug> <project> <id> — close the blind page (same akey it
# opened, resolved:true, like auth_recovered) and the state machine's record.
ghvis_resolve() {
  [ -r "$H/bin/lib/alert-state.sh" ] && . "$H/bin/lib/alert-state.sh" 2>/dev/null \
    && command -v alert_state_resolve >/dev/null 2>&1 && alert_state_resolve "$3" >/dev/null 2>&1
  "$H/bin/beat.sh" "$(jq -nc --arg akey "ghinvisible:$1" --arg id "$3" \
    --arg l "DEFAULT GH TOKEN blindness on $1 ($2) RECOVERED: a token can see it again." \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,alertstate:"resolve",resolved:true,triaged:true,line:$l}')" >/dev/null 2>&1 || true
}
# ghvis_page <slug> <project> <id> — the one page for a repo no token sees.
ghvis_page() {
  local who="the admin token cannot see it either (or is absent) — every gh consumer is blind to this repo"
  HARNESS="$H" "$H/bin/alert-line.sh" "[auth] DEFAULT GH TOKEN CANNOT SEE $1 ($2) (new): $who"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "ghinvisible:$1" --arg id "$3" \
    --arg l "DEFAULT GH TOKEN CANNOT SEE $1 ($2) (new): $who. Grant the default PAT access or keep the admin token current — an invisible repo is the silent empty loop of 2026-09-12." \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,severity:"critical",line:$l}')" >/dev/null 2>&1 || true
}
gh_visibility_canary() {
  command -v gh >/dev/null 2>&1 || return 0
  [ -x "$H/bin/fleet-conf.sh" ] || return 0
  # shellcheck source=bin/lib/gh-repo-token.sh
  [ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
  # The PAT-ONLY question, deliberately (BH-765). Every sentence this canary
  # writes is about the DEFAULT gh PAT, so it asks gh_repo_pat_for and not the
  # app -> default -> admin ladder: fed the merged verdict it would read `app`
  # for every App-covered repo and either go silent about a blind default PAT or
  # page "every gh consumer is blind to this repo" while an App token saw it fine.
  command -v gh_repo_pat_for >/dev/null 2>&1 || return 0
  local P SLUG HOW ID BID NOW WASBLIND
  ghvis_db
  while read -r P; do
    [ -n "$P" ] || continue
    SLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null); [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || continue
    HOW=$(gh_repo_pat_for "$SLUG"); ID="ghdefault-${SLUG//\//_}"
    # >>> gh default auth
    # AFTER the probe, never before it (BH-470). gh_repo_pat_for pins GH_TOKEN to
    # the process default for its own request, so arming above it would change
    # nothing about the answer — but #469's logger would then tag a rate-limited
    # probe `app:<slug>` for a call that went out on the PAT, and a tag that lies
    # is worse than no tag. Everything after this line in this loop iteration
    # (and nothing today) runs on the project's installation token.
    command -v gh_default_auth_for_project >/dev/null 2>&1 && { gh_default_auth_for_project "$P" || true; }
    # <<< gh default auth
    BID="ghblind-${SLUG//\//_}"
    case "$HOW" in
      default) NOW="default_token_visible=1" ;;
      admin)   NOW="default_token_visible=0 admin_token_visible=1" ;;
      *)       NOW="$GHVIS_BLIND" ;;
    esac
    WASBLIND=""; ghvis_was_blind "$SLUG" "$BID" && WASBLIND=1
    command -v job_ledger_put >/dev/null 2>&1 && { job_ledger_put "$GHVIS_KIND" "$SLUG" "$NOW" "$P" >/dev/null 2>&1 || true; }
    if [ "$NOW" = "$GHVIS_BLIND" ]; then
      ghvis_latch "$ID" on
      [ -n "$WASBLIND" ] && continue
      ghvis_latch "$BID" on
      ghvis_page "$SLUG" "$P" "$ID"
      continue
    fi
    [ -n "$WASBLIND" ] && { ghvis_resolve "$SLUG" "$P" "$ID"; ghvis_latch "$BID" off; }
    if [ "$HOW" = default ]; then
      if grep -qxF "$ID" "$STATE" 2>/dev/null; then
        ghvis_latch "$ID" off
        HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $ID RECOVERED — the default gh token sees $SLUG again"
      fi
      continue
    fi
    # Admin-covered: the row is the status; the audit line marks the change.
    grep -qxF "$ID" "$STATE" 2>/dev/null && [ -z "$WASBLIND" ] && continue
    ghvis_latch "$ID" on
    HARNESS="$H" "$H/bin/alert-line.sh" "[auth] DEFAULT GH TOKEN CANNOT SEE $SLUG ($P) (new): the admin token CAN see it, so lanes routed through bin/lib/gh-repo-token.sh keep working"
  done < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
  # >>> gh default auth reset
  # The last repo's identity must not outlive the canary: everything after this
  # function is the box probe loop, which is not GitHub's business at all.
  command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset
  # <<< gh default auth reset
  # `return 0` because the guard above is now the function's last command and a
  # box without #469 would otherwise make this canary answer rc 1.
  return 0
}
# auth_recovered <box> <project> — the closing edge of an auth outage (review of
# #2290). It resolves the console row the outage OPENED — same akey
# `authdown:<box>`, `resolved:true` — so the row closes and the next outage is a
# re-fire after resolve, which pages. It never opens a row of its own (the old
# `lane-alert.sh --resolve` sent `orclane:authdown-<box>`, a different akey, so
# the outage row stayed open and a second outage inside 48h paged nobody).
# `triaged:true`: a retraction decided by this canary is not an alert for the
# triage lane to investigate. The state machine's record is closed too.
auth_recovered() {
  local box="$1" project="${2:-fleet}"
  [ -r "$H/bin/lib/alert-state.sh" ] && . "$H/bin/lib/alert-state.sh" 2>/dev/null \
    && command -v alert_state_resolve >/dev/null 2>&1 && alert_state_resolve "authdown-$box" >/dev/null 2>&1
  "$H/bin/beat.sh" "$(jq -nc --arg p "$project" --arg akey "authdown:$box" --arg id "authdown-$box" \
    --arg l "Claude auth RECOVERED on $box box." \
    '{kind:"fleet_alert",project:$p,akey:$akey,alertid:$id,alertstate:"resolve",resolved:true,triaged:true,line:$l}')" >/dev/null 2>&1
  return 0
}
# --- the credential probe (BH-2560, BH-2549.2) -----------------------------------
# A box's answer is the `cred_probe claude` line, then — only when that day's
# inference was claimed and bought — an `INFERENCE` line and the inference's own
# output below it. The endpoint verdict decides the hour; an inference answer,
# when there is one, is end-to-end evidence and overrides it.
#
# cred_lib_load: the contract lib, or — on a box mid-sync that does not have it
# yet — the contract's own stub behaviour (NO_ENDPOINT, claim 0), so that box
# probes exactly as it did before the lib existed.
cred_lib_load() {
  # shellcheck source=bin/lib/cred-probe.sh
  . "$CRED_PROBE_LIB" 2>/dev/null && command -v cred_probe >/dev/null 2>&1 && return 0
  cred_probe() { echo NO_ENDPOINT; return 4; }
  cred_account_fp() { return 1; }
  cred_inference_claim() { return 0; }
  cred_inference_record() { return 0; }
}
# endpoint_word <answer>: line 1's verdict word, empty when line 1 is not one
# (an old box's legacy answer, an ssh error, nothing at all).
endpoint_word() {
  local w; w=$(head -1 <<<"$1"); w=${w%% *}
  case "$w" in ALIVE|DEAD|INCONCLUSIVE|DEGRADED|NO_ENDPOINT) echo "$w" ;; esac
}
# inference_part <answer>: what the inference said — the lines under
# `INFERENCE`, nothing when none ran, and the whole text for a legacy answer
# (that answer IS an inference, as it always was).
inference_part() {
  if [ -z "$(endpoint_word "$1")" ]; then printf '%s\n' "$1"; return; fi
  grep -qx INFERENCE <<<"$1" || return 0
  sed '1,/^INFERENCE$/d' <<<"$1"
}
# box_verdict <answer>: ok | authdown | degraded | inconclusive | none.
#   ALIVE ok, DEAD authdown, DEGRADED degraded, INCONCLUSIVE inconclusive,
#   NO_ENDPOINT none (nothing to say this hour: the daily inference speaks).
#   An inference classified ok/degraded/authdown overrides the endpoint; an
#   inconclusive one leaves it (none becomes inconclusive). Legacy text is
#   classify_probe of the whole, exactly as before.
box_verdict() {
  local ep base ic
  ep=$(endpoint_word "$1")
  [ -n "$ep" ] || { classify_probe "$1"; return; }
  case "$ep" in
    ALIVE) base=ok ;; DEAD) base=authdown ;; DEGRADED) base=degraded ;;
    INCONCLUSIVE) base=inconclusive ;; *) base=none ;;
  esac
  if grep -qx INFERENCE <<<"$1"; then
    ic=$(classify_probe "$(inference_part "$1")")
    case "$ic" in
      ok|degraded|authdown) echo "$ic"; return ;;
      *) [ "$base" = none ] && base=inconclusive ;;
    esac
  fi
  echo "$base"
}
# lane_verdict <answer>: up | down | skip, for the 6-hourly runner loop. Only
# ALIVE and DEAD (or, with no endpoint, the day's inference) mark or clear; an
# INCONCLUSIVE/DEGRADED endpoint, NO_ENDPOINT without an inference, and an
# inference agent-call refused (nothing called) mark nothing. Legacy text keeps
# its old reading: an `ok` anywhere is up.
lane_verdict() {
  local inf
  case "$(endpoint_word "$1")" in
    ALIVE) echo up ;;
    DEAD) echo down ;;
    INCONCLUSIVE|DEGRADED) echo skip ;;
    NO_ENDPOINT)
      grep -qx INFERENCE <<<"$1" || { echo skip; return; }
      inf=$(inference_part "$1")
      if grep -q 'AGENT_CALL_REFUSED\|AGENT_CALL_NO_MODEL_ROUTE' <<<"$inf"; then echo skip
      elif grep -qiE '\bok\b' <<<"$(grep -v '^codex-cli-version=' <<<"$inf")"; then echo up
      else echo down; fi ;;
    *) if grep -qiE '\bok\b' <<<"$1"; then echo up; else echo down; fi ;;
  esac
}
# local_claude_probe [extra-env-file]: this machine's claude credential, in the
# env the pipeline sources (global.env, then e.g. project-1.env). Claim before
# spend; the record follows the spend and names what it bought. A refused
# inference (AGENT_CALL_ marker: nothing was called) is not recorded.
local_claude_probe() {
  (
    . /root/harness/bin/lib/env-path.sh 2>/dev/null || harness_env_dir() { printf "%s\n" /root/harness/env; }
    E=$(harness_env_dir)
    set -a; . "$E/global.env" 2>/dev/null; [ -z "${1:-}" ] || . "$E/$1" 2>/dev/null; set +a
    cred_lib_load
    EP=$(cred_probe claude 2>/dev/null | head -1)
    echo "${EP:-INCONCLUSIVE cred_probe printed nothing}"
    FP=$(cred_account_fp claude 2>/dev/null) || FP=""
    cred_inference_claim claude "$FP" || exit 0
    # The day fp (BH-9125) needs an account fp. A box without the lib (the stub
    # claim answers 0 and there is no fp) keeps the computed fp.
    [ -n "$FP" ] && export AUTH_CANARY_FP="canary:claude:$FP:$(date -u +%F)"
    echo INFERENCE
    ANS=$(bash -c "$PROBE_BODY")
    printf '%s\n' "$ANS"
    grep -q 'AGENT_CALL_REFUSED\|AGENT_CALL_NO_MODEL_ROUTE' <<<"$ANS" && exit 0
    case "$(classify_probe "$ANS")" in
      ok) V=ok ;; authdown) V=down ;; degraded) V=degraded ;; *) V=empty ;;
    esac
    cred_inference_record claude "$FP" "$V" >/dev/null 2>&1 || true
    exit 0
  )
}
# account_pin_sweep: BH-3559. A project pinned to its own Claude account
# (settings account.<project>, bin/lib/project-account.sh) is only as good as
# the boxes that can resolve that label, and on 2026-09-28 three owning boxes
# could not for 32 hours. Once an hour, after the auth loop: the hub probes every
# pinned project (the hub's lanes and the pool bundle both read the hub's
# accounts.d), and each pinned project's owning box is asked over ssh, one call
# per box. The probe itself raises the deduped account-pin-<box>-<project> warn
# alert from the box that cannot resolve. An ssh failure, a timeout, or a box
# without the probe yet (rc 127) is `could-not-probe` in the log and no alert:
# absent is not unresolvable, and box-down paging is the loop above.
account_pin_sweep() {
  local lib="$H/bin/lib/project-account.sh" probe="$H/bin/account-pin-probe.sh" log="$H/logs/account-pin-probe.log"
  local pinned p b ip rc
  [ -r "$lib" ] && [ -x "$probe" ] && [ -x "$H/bin/fleet-conf.sh" ] || return 0
  pinned=$( . "$lib" >/dev/null 2>&1 || exit 0
            "$H/bin/fleet-conf.sh" --projects 2>/dev/null | while read -r p; do
              [ -n "$p" ] && [ -n "$(account_label_for_project "$p" 2>/dev/null)" ] && printf '%s\n' "$p"
            done )
  [ -n "$pinned" ] || return 0
  # shellcheck disable=SC2086 # project names are [A-Za-z0-9._-], one word each
  timeout 120 "$probe" --alert $pinned >/dev/null 2>&1
  local -A byb=()
  for p in $pinned; do
    b=$("$H/bin/box-for.sh" "$p" 2>/dev/null) || continue
    b="${b#box-}"
    [ -n "$b" ] && [ "$b" != local ] || continue
    ip="${BOXES[$b]:-}"
    [ -n "$ip" ] && [ "$ip" != local ] || continue
    byb[$b]="${byb[$b]:-} $p"
  done
  for b in "${!byb[@]}"; do
    rc=0
    timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=15 "root@${BOXES[$b]}" \
      "/root/harness/bin/account-pin-probe.sh --alert${byb[$b]}" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0|1) : ;;
      *) printf '%s could-not-probe %s rc=%s:%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$b" "$rc" "${byb[$b]}" >> "$log" 2>/dev/null ;;
    esac
  done
  return 0
}

[ -n "${AUTH_CHECK_LIB:-}" ] && return 0

# BELOW THE LIBRARY RETURN ON PURPOSE: tests source this file with AUTH_CHECK_LIB=1 for
# classify_probe, and a gate above that line would EXIT the test process the first time
# somebody stopped this lane.
# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-claude-auth-check
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off claude-auth-check.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit claude-auth-check
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    claude-auth-check

# auth_lane_row <put|clear> <box> [snip]: BH-2359, the fleet row `lane claude
# <box>` beside the box's STATE line (bin/lib/fleet-cooldown.sh, through the
# lane-down lib). No contract = no-op. The project-1-lane block below never
# puts one: it is an account, not a box.
auth_lane_row() {
  command -v fcd_put >/dev/null 2>&1 || return 0
  local now r ttl=7200
  if [ "$1" = put ]; then
    now=$(date +%s); ! command -v _ld_ttl >/dev/null 2>&1 || ttl=$(_ld_ttl)
    r=${3:-}; r=${r%"${r##*[! ]}"}
    fcd_put lane claude "$2" "$((now + ttl))" "$now" "$r"
  else
    fcd_clear lane claude "$2" >/dev/null 2>&1 || true
  fi
  return 0
}

# degraded_note <box> <probe-output>: auth is FINE, one pool is dry and the
# ladder already routed around it. Clear any auth-down state, then say so once
# per box per day — the remedy is credits/limits, never a re-login.
degraded_note() {
  local BOX="$1" OUT="$2" DFLAG="$H/flags/degraded-$1-$(date -u +%Y%m%d)"
  if grep -q "^$BOX$" "$STATE"; then
    { grep -v "^$BOX$" "$STATE" > "$STATE.tmp" || true; } && mv "$STATE.tmp" "$STATE"
    auth_lane_row clear "$BOX"
    HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $BOX RECOVERED (auth OK; running degraded)"
  fi
  [ -f "$DFLAG" ] && return 0
  touch "$DFLAG"
  HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $BOX MODEL POOL EXHAUSTED — auth is fine, ladder degraded: $OUT"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "pooldry:$BOX" --arg id "pooldry-$BOX" \
    --arg l "MODEL POOL EXHAUSTED on $BOX box: $OUT. Auth is healthy and the fallback model is serving, so pipelines keep running — no re-login needed. Fix is credits/limits at claude.ai/settings/usage." \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,line:$l}')" >/dev/null 2>&1
}

for BOX in "${!BOXES[@]}"; do
  # RAW is the whole answer; OUT is what the inference said (empty when none ran).
  # ssh gets 180 s, as the 6-hourly loop does: the remote side runs the credential probe AND a 120 s agent-call inference.
  if [ "${BOXES[$BOX]}" = local ]; then RAW=$(local_claude_probe); else RAW=$(timeout 180 ssh -o BatchMode=yes -o ConnectTimeout=15 "root@${BOXES[$BOX]}" "/root/harness/bin/lane-probe.sh claude --endpoint" 2>&1); fi
  OUT=$(inference_part "$RAW")
  V=$(box_verdict "$RAW")
  case "$V" in
    none)         continue ;;
    degraded)     degraded_note "$BOX" "$(tr '\n' ' ' <<<"$RAW")"; continue ;;
    inconclusive) inconclusive_note "$BOX" "$(head -c 160 <<<"$RAW" | tr '\n' ' ')"; continue ;;
  esac
  if [ "$V" = ok ]; then
    # Only an INFERENCE answer of ok is a Claude answer: an endpoint ALIVE proves
    # the token, not that the lane serves, so it never clears the marker (BH-2560).
    if [ -n "$OUT" ] && [ "$(classify_probe "$OUT")" = ok ]; then
      # >>> conductor lane marker (BH-1019/BH-1090)
      # THE CANARY IS THE RECOVERY EVENT FOR THE OUTAGE CLASS THIS FILE DOES NOT
      # RECORD. A quota 429 / spend limit is classified `inconclusive` above and
      # deliberately never reaches $STATE, so the merge conductor keeps its own
      # `state/merge-conductor/lane-down` marker for it (mc_lane_down_note, from
      # the reason a refused re-review came back with) and buys no read while it
      # stands. A Claude answer anywhere clears that marker — but during a quota
      # outage the conductor buys no reads, so this end-to-end probe is the one
      # thing on the box that still asks the vendor every hour. When it answers,
      # the lane IS up, whatever $STATE says, and the marker goes.
      #
      # This box only: the marker belongs to the conductor that runs here, and a
      # remote box answering says nothing about this one's account.
      # BH-1090: per-account markers live in state/merge-conductor/lane-down.d/;
      # the hourly canary only exercises the default account, so it only clears
      # the default marker. Routed-account cooldowns survive until a claude answer
      # on that account (mc_lane_up) clears them.
      [ "${BOXES[$BOX]}" = local ] && rm -f "$H/state/merge-conductor/lane-down" 2>/dev/null
      # <<< conductor lane marker
    fi
    if grep -q "^$BOX$" "$STATE"; then
      { grep -v "^$BOX$" "$STATE" > "$STATE.tmp" || true; } && mv "$STATE.tmp" "$STATE"
      auth_lane_row clear "$BOX"
      HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $BOX RECOVERED"
      # The closing edge of the outage row itself (same akey). Not a new row.
      auth_recovered "$BOX" fleet
    fi
  else
    SNIP=$(head -c 120 <<<"$RAW" | tr '\n' ' ')
    # Every down pass refreshes the row's until, so the TTL cannot lapse under
    # a standing outage; the contract keeps the first since.
    auth_lane_row put "$BOX" "$SNIP"
    grep -q "^$BOX$" "$STATE" && continue   # already alerted this outage
    echo "$BOX" >> "$STATE"
    HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $BOX CLAUDE AUTH DOWN: $SNIP"
    "$H/bin/beat.sh" "$(jq -nc --arg b "$BOX" --arg akey "authdown:$BOX" --arg id "authdown-$BOX" \
      --arg l "CLAUDE AUTH DOWN on $BOX box: \"$SNIP\" — its triage/builds/reviews are dead until re-login (claude setup-token flow)." \
      '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,line:$l}')" >/dev/null 2>&1
  fi
done

# Hub runs TWO lanes (2026-07-29): global.env token = orchestrator/fleet overhead
# (operator@example.com), project-1.env token = the dedicated project-1 pipeline account.
# Probe the project-1 lane the way the pipeline sources env.
BOX=project-1-lane
RAW=$(local_claude_probe project-1.env)
MCLASS=$(box_verdict "$RAW")
if [ "$MCLASS" = none ]; then :
elif [ "$MCLASS" = degraded ]; then degraded_note "$BOX" "$(tr '\n' ' ' <<<"$RAW")"
elif [ "$MCLASS" = inconclusive ]; then inconclusive_note "$BOX" "$(head -c 160 <<<"$RAW" | tr '\n' ' ')"
elif [ "$MCLASS" = ok ]; then
  if grep -q "^$BOX$" "$STATE"; then
    { grep -v "^$BOX$" "$STATE" > "$STATE.tmp" || true; } && mv "$STATE.tmp" "$STATE"
    HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $BOX RECOVERED"
    # The project-1-lane outage row is closed too (review of #2290): it fired
    # under authdown:project-1-lane and would otherwise stay open 48h.
    auth_recovered "$BOX" project-1
  fi
else
  if ! grep -q "^$BOX$" "$STATE"; then
    echo "$BOX" >> "$STATE"
    SNIP=$(head -c 120 <<<"$RAW" | tr '\n' ' ')
    HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $BOX CLAUDE AUTH DOWN: $SNIP"
    "$H/bin/beat.sh" "$(jq -nc --arg akey "authdown:$BOX" --arg id "authdown-$BOX" \
      --arg l "CLAUDE AUTH DOWN on the dedicated project-1 account (hub project-1 lane): \"$SNIP\" — project-1 triage/builds/reviews stalled until re-auth." \
      '{kind:"fleet_alert",project:"project-1",akey:$akey,alertid:$id,line:$l}')" >/dev/null 2>&1
  fi
fi
# --- All-runner canary (the operator, 2026-08-02): deterministic (cron+bash, no AI in
# the control loop) verification that EVERY lane works BEFORE it's needed —
# codex and openrouter probed every 6h (cost: fractions of a cent), claude
# hourly above. Failures beat via plain curl; same state-dedup as claude lanes.
HOUR=$(date -u +%H)
if [ $((10#$HOUR % 6)) -eq 0 ]; then
  gh_visibility_canary
  NOW=$(date -u +%s)
  for BOX in "${!BOXES[@]}"; do
    for LANE in codex openrouter fireworks grok; do
      ID="$BOX-$LANE"
      # BH-2560: lane first, so a box still on the old lane-probe.sh ignores the
      # flag and answers its legacy probe, which lane_verdict reads as before.
      LPROBE="/root/harness/bin/lane-probe.sh $LANE --endpoint"
      if [ "${BOXES[$BOX]}" = local ]; then LOUT=$(bash -c "$H/bin/lane-probe.sh $LANE --endpoint"); else LOUT=$(timeout 180 ssh -o BatchMode=yes -o ConnectTimeout=15 "root@${BOXES[$BOX]}" "$LPROBE" 2>&1); fi
      LV=$(lane_verdict "$LOUT")
      # BH-4153: the lanedown marks below are rows, so the client is loaded
      # once here (ghvis_db keeps this script's shell options).
      command -v flag_set >/dev/null 2>&1 || ghvis_db
      [ "$LV" = skip ] && continue
      # >>> lane-down lib (BH-1674): one mark per lane, cleared the pass it
      # answers. No daily re-nag: the day-1 line and beat fire once, and the
      # standing alert in bin/lane-reprobe.sh owns a lane that stays down. The
      # akey has no date so a lane is one alert family; a recovery resolves
      # lanedown-<ID>, so the next outage is a new incident. ld_mark failing
      # (bad ID, lock timeout) falls through to the inline write below, so a
      # failing lane is never left unmarked.
      if command -v ld_mark >/dev/null 2>&1; then
        if [ "$LV" = up ]; then
          if grep -qxF "$ID" "$STATE" || [ -e "$(ld_record_path "$H" "$ID")" ] || ld_flag_on "$H" "$ID" "$(date -u +%Y%m%d)"; then
            ld_recovered "$H" "$ID" "$NOW" || true
          fi
          continue
        fi
        if grep -qxF "$ID" "$STATE"; then
          ld_mark "$H" "$ID" "${BOXES[$BOX]}" "$LOUT" "$NOW" && continue
        elif ld_mark "$H" "$ID" "${BOXES[$BOX]}" "$LOUT" "$NOW"; then
          HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $ID LANE DOWN (new)"
          "$H/bin/beat.sh" "$(jq -nc --arg akey "lanedown:$ID" --arg id "lanedown-$ID" \
            --arg l "RUNNER LANE DOWN (new): $LANE on $BOX box failed its canary — that fallback tier is NOT available if primaries fail there. $(head -c 80 <<<"$LOUT")" \
            '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,severity:"warn",line:$l}')" >/dev/null 2>&1
          continue
        fi
      fi
      # <<< lane-down lib
      if [ "$LV" = up ]; then
        if grep -q "^$ID$" "$STATE"; then
          { grep -v "^$ID$" "$STATE" > "$STATE.tmp" || true; } && mv "$STATE.tmp" "$STATE"
          HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $ID RECOVERED"
          # Close the lane's alert id, so the recovery is stated ONCE and the
          # next failure fires as a new incident rather than as a repeat of the
          # one that already ended. Silent if the lane was never reported down.
          [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --resolve --id "lanedown-$ID" \
            auth "RUNNER LANE $ID is answering its canary again." >/dev/null 2>&1
        fi
      else
        # Inline fallback (no lane-down lib, or ld_mark failed) — today's code:
        # Re-nag DAILY while a lane stays down instead of alerting once and going
        # quiet forever (2026-08-14): project-3's codex lane died 08-10 and was never
        # mentioned again, so the box ran four days with no tier-2 at all and we
        # only found it while debugging something else. A safety net that is down
        # and silent is worse than no safety net — you think you have one.
        # BH-4153: the day's mark is a row when the client is loaded and a
        # worker configured (rc 2, unreadable, counts as nagged so an outage
        # does not re-beat every pass), else flags/lanedown-<ID>-<day>.
        RDAY=$(date -u +%Y%m%d); RFLAG="$H/flags/lanedown-$ID-$RDAY"
        DAY1=""
        if grep -q "^$ID$" "$STATE"; then
          # Rows only with a box scope too, as bin/lib/lane-down.sh `_ld_db` checks:
          # an empty JOBS_BOX would make every write fail and every read rc 2.
          if command -v flag_has >/dev/null 2>&1 && _flag_db_configured && _flag_default_scope lanedown-x >/dev/null 2>&1; then
            flag_has --scope "$JOBS_BOX" "lanedown-$ID-$RDAY" >/dev/null 2>&1; RF_RC=$?
            [ "$RF_RC" = 2 ] && echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [auth] lanedown-$ID-$RDAY unknown (worker unreachable, no cache): read as already nagged" >> "$H/logs/claude-auth-check.log"
            [ "$RF_RC" != 1 ] && continue      # already nagged today
          else
            [ -f "$RFLAG" ] && continue          # already nagged today
          fi
        else
          echo "$ID" >> "$STATE"; DAY1=1
        fi
        if command -v flag_set >/dev/null 2>&1 && _flag_db_configured && _flag_default_scope lanedown-x >/dev/null 2>&1; then
          flag_set --scope "$JOBS_BOX" --hold-local "lanedown-$ID-$RDAY" on "lane down" >/dev/null 2>&1 || true
        else
          touch "$RFLAG"
        fi
        HARNESS="$H" "$H/bin/alert-line.sh" "[auth] $ID LANE DOWN${DAY1:+ (new)}"
        # ALERT ID + SEVERITY (2026-09-15). A fallback tier being down is a
        # safety-net gap, not an outage — primaries are serving — so it is a
        # `warn`: batched into the digest instead of paging four lanes x every
        # canary. The id is the lane, so the daily re-nag below counts against
        # one condition rather than minting a page per canary pass. And a box
        # that is deliberately PARKED (flags/paused-<box>, or a `parked` line in
        # flags/alerts.conf) is downgraded to info by bin/lib/alert-state.sh:
        # the project-10 box has been parked since 2026-08-25 and its four
        # canaries have failed on purpose, five lines at a time, ever since.
        "$H/bin/beat.sh" "$(jq -nc --arg akey "lanedown:$ID" --arg id "lanedown-$ID" \
          --arg l "RUNNER LANE DOWN${DAY1:+ (new)}: $LANE on $BOX box failed its canary — that fallback tier is NOT available if primaries fail there. $(head -c 80 <<<"$LOUT")" \
          '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,severity:"warn",line:$l}')" >/dev/null 2>&1
      fi
    done
  done
fi
account_pin_sweep
exit 0
