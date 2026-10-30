# >>> mput error note (BH-7174)
# A failed push used to log "FAILED" with no reason: mexec sent flyctl's stderr
# to /dev/null. mexec still does that for every caller but mput (many read its
# stdout as data, so stderr must never join it); mput alone sets _mexec_err to
# a temp file and, on a non-zero rc, writes ONE line per machine with flyctl's
# last stderr line. Lowercase on purpose: it is a per-call local, not a knob.
mexec() { # mexec <machine-id> <cmd>
  timeout 90 "$FLY" ssh console -a "$APP" --machine "$1" -C "/bin/sh -c $(printf '%q' "$2")" 2>"${_mexec_err:-/dev/null}"
}
mput() { # mput <machine-id> <local-file> <remote-path>  (base64 through console)
  # Seed mode (BH-7430): the file goes to the machine's --file-local seed.
  if [ -n "${POOL_SEED_DIR:-}" ]; then pool_seed_put "$2" "$3"; return; fi
  local B64 rc _mexec_err; B64=$(base64 -w0 "$2")
  _mexec_err=$(mktemp "${TMPDIR:-/tmp}/mput-err.XXXXXX" 2>/dev/null) || _mexec_err=""
  mexec "$1" "mkdir -p $(dirname "$3") && echo $B64 | base64 -d > $3 && chmod 600 $3" >/dev/null
  rc=$?
  [ "$rc" = 0 ] || mput_fail_note "$1" "$3" "$rc" "$_mexec_err"
  [ -n "$_mexec_err" ] && rm -f "$_mexec_err"
  return "$rc"
}
# >>> seed put (BH-7430)
# pool_seed_put <local-file> <remote-path>: in seed mode ($POOL_SEED_DIR set by
# pool_pull_decide), mput copies the file to $POOL_SEED_DIR/<remote-path>, and
# `fly machine run --file-local /run/harness-seed/<remote-path>=<copy>` writes
# it on the machine before boot. fly/entrypoint.sh moves it to <remote-path>.
# Only the three trees the push path writes are allowed, so a bad path in a
# relay can never place a file anywhere else on the machine.
pool_seed_put() {
  case "${2:-}" in
    /run/harness/*|/run/harness-env/*|/data/harness/state/*) ;;
    *) return 1 ;;
  esac
  case "$2" in *..*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  [ -r "${1:-}" ] || return 1
  ( umask 077; mkdir -p "$POOL_SEED_DIR$(dirname "$2")" && cp "$1" "$POOL_SEED_DIR$2" ) 2>/dev/null
}
# <<< seed put
# mput_fail_note <mid> <remote-path> <rc> <errfile> -> one `push of <path>
# FAILED rc=<n>: <text>` line, the first time a machine fails a push. The marker
# $POOL/.<mid>.puterr goes with the machine's other state. The command line
# carries the base64 of the env bundle, so if flyctl echoes it, every run of 40+
# base64 characters is withheld, and a credential shape withholds the text.
mput_fail_note() {
  local why
  ( set -C; : > "$POOL/.$1.puterr" ) 2>/dev/null || return 0
  if [ -z "${4:-}" ] || [ ! -r "$4" ]; then
    why="(stderr not captured)"
  else
    why=$(grep -v '^[[:space:]]*$' "$4" | tail -n 1 | tr -d '\000-\037' \
          | sed -E 's#[A-Za-z0-9+/=]{40,}#<base64 withheld>#g' | cut -c1-240)
    [ -n "$why" ] || why="(flyctl printed nothing)"
    if grep -Eq 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_|sk-ant-|sk-or-|=[A-Za-z0-9_./+-]{32,}' <<<"$why"; then
      why="reason withheld: flyctl output looked like a credential"
    fi
  fi
  [ "$3" = 124 ] && why="$why (timeout 90s)"
  say "$1: push of $2 FAILED rc=$3: $why"
  return 0
}
# <<< mput error note
# >>> fly error reason (hotfix pool-fly-stderr)
# fly_err_reason <errfile> -> prints " :: <reason>" for a say line, or nothing.
# A failed `machine run` or harness sftp used to log no reason: flyctl's stderr
# went to /dev/null (project-6-os, 2026-10-29 20:13Z-20:51Z, 33-100% of launches
# failed and nobody could say why). The reason is the last non-empty stderr
# line, control characters removed, redacted, at most 200 characters. Redacted
# to <redacted>: everything after "FlyV1 ", the word after "Bearer ", a GitHub
# token shape, and any run of 40+ base64/hex characters.
fly_err_reason() {
  local why
  [ -n "${1:-}" ] && [ -f "$1" ] && [ -r "$1" ] || return 0
  why=$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | tr -d '\000-\037' \
        | sed -E -e 's#FlyV1 .*#FlyV1 <redacted>#' \
                 -e 's#([Bb]earer) [^[:space:]]+#\1 <redacted>#g' \
                 -e 's#gh[pousr]_[A-Za-z0-9_.-]{20,}#<redacted>#g' \
                 -e 's#github_pat_[A-Za-z0-9_]{22,}#<redacted>#g' \
                 -e 's#[A-Za-z0-9+/=_-]{40,}#<redacted>#g' \
        | cut -c1-200)
  [ -n "$why" ] || why="(flyctl printed nothing)"
  printf ' :: %s' "$why"
}
# <<< fly error reason

