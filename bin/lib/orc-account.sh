#!/bin/bash
# bin/lib/orc-account.sh — which claude account pays for an ORCHESTRATOR turn.
#
# the operator, 2026-09-15 01:0xZ: "move your turns to the max picker too". Until then
# every orchestrator turn ran on the env/orchestrator.env setup-token (a
# operator@example.com identity, weekly meter 100% = cash extra usage) while the
# max1..7 accounts sat on full credits. This asks bin/account-pick.sh the same
# question a hub stage asks — stage "orchestrator", vendor claude, the turn's
# model — and runs the turn on the picked account.
#
# THE TOKEN FORM, NOT THE ACCOUNT FILE'S LOGIN. The hub registry
# (env/accounts.d/<name>.env) carries a CLAUDE_CONFIG_DIR login per account.
# The picker's export line for such an account would move the whole CLI config
# dir, and three things live under /root/.claude for this conversation and
# would be silently orphaned: the memory dir
# (projects/-root-orchestrator/memory), the session transcript the turn's cost
# row is priced from (claude-cost.sh -> transcript-cost.sh), and
# orchestrator-burn.sh's daily sum. So the pick is honoured by NAME: the
# account's setup-token from env/tokens.d/<name>-setup-token.env replaces
# ORC_TOKEN, and CLAUDE_CODE_OAUTH_TOKEN shadows any stored login (the same
# precedence the picker's contract relies on). Same account, same meter, same
# routing-log row; the config dir never moves.
#
# FAIL OPEN, ALWAYS. Routing off, no picker, picker exit 2 (no headroom),
# name=default, no token file, empty token — every one of these leaves
# ORC_TOKEN exactly as the caller set it. A turn is never refused and never
# silently switched to "whatever login is stored".
#
# Knobs: ACCOUNT_ROUTING=1 (the fleet flag, global.env) is the master switch —
# the orchestrator follows the hub's setting, it does not get its own default.
# ORC_ACCOUNT_ROUTING=0 or flags/orc-account-routing-off (or the
# `switch.orc-account-routing-off` settings row) turns JUST the
# orchestrator off (kill switch). ORC_ACCOUNT_PIN (default "orchestrator") is
# the sticky pin key: turns stay on one account while it has headroom, so the
# briefing's prompt cache stays warm across turns.
#
# Sets: ORC_TOKEN (in/out), ORC_ACCOUNT (name or "default"),
# ORC_ACCOUNT_REASON (picker reason, or why the default stayed), and exports
# COST_ACCT_NAME so claude-cost.sh can label the row acct:<name> when the
# token's fingerprint has no catalog label (agent-call.sh does the same).
#
# BH-996 adds the other half: what the TURN does when the picked account
# refuses. orc_fail_class names the refusal, orc_fail_keep/orc_fail_adopt carry
# the STRONGEST verdict across the models that ran on that one account,
# orc_fail_phrase says it in English, and orc_account_refuse cools the account
# down (vendor-scoped, the path the picker actually reads) and drops its pin so
# the next pick cannot hand back the account that just said no.

# _orc_root -> $HARNESS, else $H (BH-2613 rule 1). Run directly with neither,
# the lib's own install root (rule 3). Sourced with neither, nothing: no picker,
# no pin, no stamp, and the kill switch reads as absent (rule 2).
_orc_root() {
  local r="${HARNESS:-${H:-}}"
  if [ -z "$r" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
    r=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P) || r=""
  fi
  printf '%s' "$r"
}

# The fleet cooldown seam (BH-2355), guarded: without it the refusal stays box-local.
_ORC_R=$(_orc_root)
. "$(dirname "${BASH_SOURCE[0]}")/fleet-cooldown.sh" 2>/dev/null || { [ -n "$_ORC_R" ] && . "$_ORC_R/bin/lib/fleet-cooldown.sh" 2>/dev/null; } || true
unset _ORC_R
command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/lane-switch.sh" 2>/dev/null || lane_switch() { local r; r=$(_orc_root); [ -n "$r" ] && [ -e "$r/flags/$1" ]; }

orc_pick_account() { # orc_pick_account <model>
  local model="${1:-}" pick n r lbl tf t h
  ORC_ACCOUNT="default"; ORC_ACCOUNT_REASON="routing-off"
  [ "${ACCOUNT_ROUTING:-0}" = "1" ] || return 0
  h=$(_orc_root)
  if [ "${ORC_ACCOUNT_ROUTING:-1}" != "1" ] || { [ -n "$h" ] && HARNESS="$h" lane_switch orc-account-routing-off file; }; then
    ORC_ACCOUNT_REASON="orc-routing-off"; return 0
  fi
  [ -n "$h" ] && [ -x "$h/bin/account-pick.sh" ] || { ORC_ACCOUNT_REASON="no-picker"; return 0; }
  pick=$(ACCOUNT_PIN_KEY="${ORC_ACCOUNT_PIN:-orchestrator}" PROJECT="${COST_PROJECT:-fleet}" \
         "$h/bin/account-pick.sh" orchestrator claude "$model" 2>/dev/null) || pick=""
  n=$(printf '%s\n' "$pick" | sed -n 's/^name=//p' | head -1)
  r=$(printf '%s\n' "$pick" | sed -n 's/^reason=//p' | head -1)
  lbl=$(printf '%s\n' "$pick" | sed -n 's/^label=//p' | head -1)
  if [ -z "$n" ] || [ "$n" = default ]; then ORC_ACCOUNT_REASON="${r:-no-pick}"; return 0; fi
  tf="$h/env/tokens.d/$n-setup-token.env"
  [ -r "$tf" ] || { ORC_ACCOUNT_REASON="no-token-file:$n"; return 0; }
  t=$(grep -m1 '^CLAUDE_CODE_OAUTH_TOKEN=' "$tf" | cut -d= -f2-)
  [ -n "$t" ] || { ORC_ACCOUNT_REASON="empty-token:$n"; return 0; }
  ORC_TOKEN="$t"; ORC_ACCOUNT="$n"; ORC_ACCOUNT_REASON="${r:-picked}"
  export COST_ACCT_NAME="$n"
  [ -n "$lbl" ] && export ORC_ACCOUNT_LABEL="$lbl"
  return 0
}

# --- What a refusal MEANS (BH-996) ------------------------------------------
# The turn used to read every non-zero rc the same way: fable failed, opus
# failed, cross to codex under the banner "Claude is out of credits". That
# sentence was never measured — a 529, an expired setup-token and a real agent
# error all rendered as an empty wallet — and the turn never tried a second
# account, so a session limit on the pinned max account took the channel to a
# survival lane while six accounts and the orchestrator.env token sat idle.
#
# The three knobs below are agent-call.sh's LADDER_*_REGEX defaults VERBATIM
# (grep them by key name — line numbers there move every week), same names and
# same defaults, so a box that overrides one for the build ladders gets the
# same override on the turn — and no new env var enters the fleet. They are
# duplicated rather than shared because BH-996 forbids touching agent-call.sh;
# tests/orc-turn-ladder.bh-996-test.sh compares the two files line for line, so
# drift fails loudly instead of quietly classifying differently.
#
# ACCOUNT_EXHAUST_REGEX IS ADDITIVE ON THIS SIDE TOO (BH-1090). agent-call.sh
# now ORs the box's knob with the built-in vocabulary instead of replacing it,
# because a box that set ACCOUNT_EXHAUST_REGEX to WIDEN what counts as
# exhaustion was silently NARROWING the ladder to that one phrase. The turn
# ladder classifies the same text with the same knob, so it takes the same
# composition — byte for byte, which is what the BH-996 comparison pins.
_LADDER_EXHAUST_BUILTIN="${LADDER_EXHAUST_REGEX:-usage credits|usage limit|session limit|weekly limit|out of credits|credit balance|spend limit|hit your [a-z0-9 -]*limit|quota exceeded|limit reached}"
LADDER_EXHAUST_REGEX="${ACCOUNT_EXHAUST_REGEX:-}${ACCOUNT_EXHAUST_REGEX:+|}${_LADDER_EXHAUST_BUILTIN}"
LADDER_TRANSIENT_REGEX="${LADDER_TRANSIENT_REGEX:-rate_limit_error|rate.?limit(ed)? (exceeded|reached|hit)|too many requests|\b429\b|\b529\b|overloaded|internal server error|bad gateway|service unavailable|gateway time|(http|status|code|error)[ :]*5[0-9][0-9]\b|temporarily unavailable|timed out|connection (reset|refused|closed)|socket hang up|network error|ECONNRESET|ETIMEDOUT|EAI_AGAIN}"
LADDER_AUTH_REGEX="${LADDER_AUTH_REGEX:-\b401\b|\b403\b|unauthorized|forbidden|authentication_error|invalid api key|invalid [a-z ]*token|on hold|suspended|not logged in|please (re-?)?login|setup-token}"
# A strict SUBSET of the exhaust default: the wordings that really are an empty
# wallet, as opposed to a rolling session/weekly window. This is the only thing
# that may print "out of credits".
ORC_CREDITS_REGEX='usage credits|out of credits|credit balance|spend limit'

# orc_fail_class <rc> <text> — sets ORC_FAIL_CLASS/ORC_FAIL_DETAIL/
# ORC_FAIL_MATCH/ORC_FAIL_RC. Same order agent-call.sh classifies in: a timeout
# is a timeout before it is anything else, exhaustion beats auth, auth beats
# transient, and ANYTHING unrecognised is real-failure — never quota, because
# quota is what makes the turn buy another account.
orc_fail_class() { # orc_fail_class <rc> <text>
  local rc="${1:-0}" text="${2:-}" m
  ORC_FAIL_CLASS=ok; ORC_FAIL_DETAIL=""; ORC_FAIL_MATCH=""; ORC_FAIL_RC="$rc"
  [ "$rc" = 0 ] && return 0
  case "$rc" in
    124|137|143) ORC_FAIL_CLASS=transient; ORC_FAIL_DETAIL=timeout; return 0 ;;
  esac
  m=$(grep -m1 -oiE "$LADDER_EXHAUST_REGEX" 2>/dev/null <<<"$text" | head -1)
  if [ -n "$m" ]; then
    ORC_FAIL_CLASS=account-exhausted; ORC_FAIL_MATCH=$(printf '%s' "$m" | tr 'A-Z' 'a-z')
    if grep -qiE "$ORC_CREDITS_REGEX" 2>/dev/null <<<"$text"; then
      ORC_FAIL_DETAIL=credits
    else
      ORC_FAIL_DETAIL=quota
    fi
    return 0
  fi
  m=$(grep -m1 -oiE "$LADDER_AUTH_REGEX" 2>/dev/null <<<"$text" | head -1)
  if [ -n "$m" ]; then
    ORC_FAIL_CLASS=auth; ORC_FAIL_DETAIL=credential; ORC_FAIL_MATCH=$(printf '%s' "$m" | tr 'A-Z' 'a-z')
    return 0
  fi
  m=$(grep -m1 -oiE "$LADDER_TRANSIENT_REGEX" 2>/dev/null <<<"$text" | head -1)
  if [ -n "$m" ]; then
    ORC_FAIL_CLASS=transient; ORC_FAIL_DETAIL=vendor; ORC_FAIL_MATCH=$(printf '%s' "$m" | tr 'A-Z' 'a-z')
    return 0
  fi
  ORC_FAIL_CLASS=real-failure; ORC_FAIL_DETAIL=agent
  return 0
}

# orc_fail_phrase — the last classification, in the words the operator reads on his
# phone. The vendor phrase that actually matched is quoted rather than
# paraphrased, so the banner can be checked against last-error.txt.
orc_fail_phrase() {
  case "${ORC_FAIL_DETAIL:-}" in
    credits)    echo "out of credits" ;;
    quota)      echo "${ORC_FAIL_MATCH:-quota limit}" ;;
    credential) echo "auth error: ${ORC_FAIL_MATCH:-not authenticated}" ;;
    timeout)    echo "timed out" ;;
    vendor)     echo "transient vendor error: ${ORC_FAIL_MATCH:-unknown}" ;;
    *)          echo "rc=${ORC_FAIL_RC:-?}, unclassified failure" ;;
  esac
}

# orc_class_rank <class> — how much a verdict OUTRANKS another, in the exact
# order orc_fail_class itself decides in: exhaustion beats auth, auth beats
# transient, anything unrecognised is the floor. One account runs two models,
# so two verdicts can come back from one account; this says which one the
# account ladder acts on.
orc_class_rank() { # orc_class_rank <class> -> 3..0
  case "${1:-}" in
    account-exhausted) echo 3 ;;
    auth)              echo 2 ;;
    transient)         echo 1 ;;
    *)                 echo 0 ;;
  esac
}

# orc_fail_keep <class> <detail> <match> <rc> — remember the STRONGEST verdict
# seen so far on this account, in ORC_KEPT_*. Called once per model attempt.
orc_fail_keep() {
  if [ -z "${ORC_KEPT_CLASS:-}" ] || [ "$(orc_class_rank "${1:-}")" -gt "$(orc_class_rank "${ORC_KEPT_CLASS:-}")" ]; then
    ORC_KEPT_CLASS="${1:-}"; ORC_KEPT_DETAIL="${2:-}"; ORC_KEPT_MATCH="${3:-}"; ORC_KEPT_RC="${4:-}"
  fi
  return 0
}

# orc_fail_adopt — publish the kept verdict as THE verdict for this account.
#
# BH-996 round 2: the account loop used to re-run orc_fail_class on the tail
# $OUT, which is whatever the LAST model printed. fable refusing on "session
# limit" and opus then returning a 529 read as `transient` — so the account was
# never cooled, never rotated away from, and the banner went on to claim "the
# default token was not tried (transient on max7 is not an account refusal)"
# about an account that had refused on quota one call earlier. The ladder keeps
# every attempt's class now and this adopts the strongest.
orc_fail_adopt() {
  if [ -n "${ORC_KEPT_CLASS:-}" ]; then
    ORC_FAIL_CLASS="$ORC_KEPT_CLASS"; ORC_FAIL_DETAIL="$ORC_KEPT_DETAIL"
    ORC_FAIL_MATCH="$ORC_KEPT_MATCH"; ORC_FAIL_RC="$ORC_KEPT_RC"
  fi
  return 0
}

# orc_pin_clear — drop the sticky pin. account-pick.sh REWRITES the pin to
# whatever it picked (its "(5) refresh the pin" block), so after a refusal the
# pin is the one file still naming the account that said no.
orc_pin_clear() {
  local k h
  h=$(_orc_root); [ -n "$h" ] || return 0
  k=$(printf '%s' "${ORC_ACCOUNT_PIN:-orchestrator}" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)
  [ -n "$k" ] && rm -f "$h/state/quota/pins/$k" 2>/dev/null
  return 0
}

# orc_account_refuse <account> — this account just refused the turn. Stamp the
# cooldown agent-call.sh stamps, so the hub's build stages skip the account
# too, and clear the pin so the next pick ranks by headroom. "default" is not
# an account: cooling it down would only make the picker fail open to it
# anyway, and it owns no pin.
#
# KEYED BY VENDOR (BH-940, #956). The stamp is
# state/quota/cooldown/<vendor>/<account>, the path bin/account-pick.sh reads
# (account_cooldown_file) and bin/agent-call.sh writes. A bare
# state/quota/cooldown/<account> is the pre-BH-940 shape: account-pick.sh sweeps
# any such file to cooldown/.legacy/ and NEVER reads it, so a turn that stamped
# there cooled nothing — the re-pick could hand the refused account straight
# back, the tried-set guard would force `default`, every other max account
# would be skipped, and each refusal would log a spurious
# `legacy_cooldown_ignored` row. The turn is a claude lane, so the vendor is
# claude, exactly as orc_pick_account asks the picker for claude.
# The file comes first; the fleet row (BH-2355) then tells every other box.
orc_account_refuse() { # orc_account_refuse <account>
  local a="${1:-}" h now win
  [ -n "$a" ] && [ "$a" != default ] || return 0
  h=$(_orc_root)
  now=$(date +%s)
  # No root, no stamp: the fleet row below still tells every other box.
  [ -n "$h" ] && mkdir -p "$h/state/quota/cooldown/claude" 2>/dev/null && printf '%s\n' "$now" > "$h/state/quota/cooldown/claude/$a"
  # The window account_cooling reads the file against (account-pick.sh's own resolution).
  win="${ACCOUNT_COOLDOWN_SECS:-${MODEL_COOLDOWN_SECS:-}}"; case "$win" in ''|*[!0-9]*) win=21600 ;; esac
  command -v fcd_put >/dev/null 2>&1 && fcd_put account claude "$a" "$(( now + win ))" "$now" orc-refuse
  orc_pin_clear
  return 0
}
