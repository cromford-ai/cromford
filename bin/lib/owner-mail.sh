# shellcheck shell=bash
# bin/lib/owner-mail.sh — one email to the project owner (BH-8894). Sourced only.
#
#   owner_mail <ttl> <key> <project> <subject> <text>
#
# Always rc 0. Prints exactly one word on stdout:
#   bad-args        key, subject or text empty. No write, no call.
#   not-configured  no sender, no recipient with an @, no API key, or no
#                   harness root. No write, no call, no key read before the
#                   sender is known.
#   suppressed      state/owner-mail.json holds <key> stamped less than <ttl>
#                   seconds ago (any status). No write, no call.
#   sent            Resend answered a non-empty string .id.
#   failed          anything else. The row records why, and one warn
#                   bin/alert-line.sh line (id owner-mail-<key>) names it.
# The row is stamped {at, status:"sending", to} BEFORE the send, under a flock,
# so a crash is a lost repeat, never a second mail. A ttl that is not a positive
# integer is 86400. NOW is the clock seam.
#
# Who and from where. The caller applies the project's rows first with
# `lib_env_apply owner-mail <project>` (in a subshell, so one project's row
# never reaches the next):
#   OWNER_MAIL_FROM  settings row lib.owner-mail[.<project>].owner_mail_from.
#                    Empty = no email (a sender must be verified in Resend).
#   OWNER_MAIL_TO    settings row lib.owner-mail[.<project>].owner_mail_to.
#                    Empty = HARNESS_GIT_EMAIL.
#   RESEND_API_KEY   the env, else the last assignment in
#                    $(harness_env_dir)/global.env. Never a settings row.
# Transport: bin/lib/vendor/resend.sh resend_send. Tests:
# tests/owner-mail.bh-8894-test.sh, tests/prod-red-owner-mail.bh-8894-test.sh.
# shellcheck source=vendor/resend.sh
. "${BASH_SOURCE[0]%/*}/vendor/resend.sh" || return 1
# shellcheck source=env-path.sh
. "${BASH_SOURCE[0]%/*}/env-path.sh" || return 1

# _om_record <state> <key> <json patch> <lock wait> — merge the patch into
# .[key] under the flock. A file that does not parse reads as {}.
_om_record() {
  local st="$1" key="$2" patch="$3" wait="$4" cur
  (
    command -v flock >/dev/null 2>&1 && flock -w "$wait" 9
    cur=$(jq -c 'if type == "object" then . else {} end' "$st" 2>/dev/null) || cur='{}'
    [ -n "$cur" ] || cur='{}'
    jq -c --arg k "$key" --argjson p "$patch" '.[$k] = ((.[$k] | objects) // {}) + $p' <<<"$cur" > "$st.tmp.$$" 2>/dev/null \
      && mv "$st.tmp.$$" "$st" 2>/dev/null
    rm -f "$st.tmp.$$" 2>/dev/null
    exit 0
  ) 9>"$st.lock"
}

owner_mail() {
  local ttl="${1:-}" key="${2:-}" proj="${3:-}" subject="${4:-}" text="${5:-}"
  local h="${HARNESS:-${H:-}}" from to now st wait chars ans rc id why
  [ -n "$key" ] && [ -n "$subject" ] && [ -n "$text" ] || { echo bad-args; return 0; }
  case "$ttl" in ''|*[!0-9]*|0*) ttl=86400 ;; esac
  # fallback "": settings row lib.owner-mail[.<project>].owner_mail_from (catalog/lanes.d/_lib.owner-mail.knobs.d/OWNER_MAIL_FROM.json)
  from="${OWNER_MAIL_FROM:-}"
  # fallback HARNESS_GIT_EMAIL: settings row lib.owner-mail[.<project>].owner_mail_to (catalog/lanes.d/_lib.owner-mail.knobs.d/OWNER_MAIL_TO.json)
  to="${OWNER_MAIL_TO:-${HARNESS_GIT_EMAIL:-}}"
  [ -n "$from" ] && [[ "$to" == ?*@?* ]] && [ -n "$h" ] || { echo not-configured; return 0; }
  # The key is local, so resend_send's ${!name} reads it and it never leaks
  # into the caller's shell.
  local RESEND_API_KEY="${RESEND_API_KEY:-}"
  if [ -z "$RESEND_API_KEY" ]; then
    RESEND_API_KEY=$(sed -n 's/^\(export \)\{0,1\}RESEND_API_KEY=//p' "$(harness_env_dir "$h")/global.env" 2>/dev/null \
      | tr -d "\"'" | tail -n 1)
  fi
  [ -n "$RESEND_API_KEY" ] || { echo not-configured; return 0; }
  # fallback 10: settings row lib.owner-mail.owner_mail_lock_wait_s (catalog/lanes.d/_lib.owner-mail.knobs.d/OWNER_MAIL_LOCK_WAIT_S.json)
  wait="${OWNER_MAIL_LOCK_WAIT_S:-10}"
  case "$wait" in ''|*[!0-9]*|0*) wait=10 ;; esac
  # fallback 200: settings row lib.owner-mail.owner_mail_err_chars (catalog/lanes.d/_lib.owner-mail.knobs.d/OWNER_MAIL_ERR_CHARS.json)
  chars="${OWNER_MAIL_ERR_CHARS:-200}"
  case "$chars" in ''|*[!0-9]*|0*) chars=200 ;; esac
  now="${NOW:-$(date +%s)}"
  st="$h/state/owner-mail.json"
  mkdir -p "${st%/*}" 2>/dev/null
  # The TTL check and the stamp: ONE read-modify-write under the flock.
  # rc 1 from the subshell = suppressed.
  (
    command -v flock >/dev/null 2>&1 && flock -w "$wait" 9
    cur=$(jq -c 'if type == "object" then . else {} end' "$st" 2>/dev/null) || cur='{}'
    [ -n "$cur" ] || cur='{}'
    last=$(jq -r --arg k "$key" '(.[$k] | objects | .at) // 0' <<<"$cur" 2>/dev/null) || last=0
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( now - last )) -lt "$ttl" ] && exit 1
    jq -c --arg k "$key" --argjson t "$now" --arg to "$to" '.[$k] = {at:$t, status:"sending", to:$to}' <<<"$cur" \
      > "$st.tmp.$$" 2>/dev/null && mv "$st.tmp.$$" "$st" 2>/dev/null
    rm -f "$st.tmp.$$" 2>/dev/null
    exit 0
  ) 9>"$st.lock" || { echo suppressed; return 0; }
  ans=$(resend_send RESEND_API_KEY "$from" "$to" "$subject" "$text" 2>&1); rc=$?
  id=""
  [ "$rc" -eq 0 ] && id=$(jq -r 'if type == "object" and (.id | type) == "string" then .id else empty end' <<<"$ans" 2>/dev/null)
  if [ -n "$id" ]; then
    _om_record "$st" "$key" "$(jq -nc --arg id "$id" '{status:"sent", id:$id}')" "$wait"
    echo sent
    return 0
  fi
  why="${ans//"$RESEND_API_KEY"/<key>}"
  why=$(printf '%s' "$why" | tr '\r\n\t' '   ')
  [ -n "$why" ] || why="rc $rc, empty answer"
  why="${why:0:$chars}"
  _om_record "$st" "$key" "$(jq -nc --arg w "$why" '{status:"failed", why:$w}')" "$wait"
  "$h/bin/alert-line.sh" --severity warn --id "owner-mail-$key" \
    "[owner-mail] ${proj:-fleet}: the owner email to $to failed: $why" >/dev/null 2>&1 || true
  echo failed
  return 0
}
