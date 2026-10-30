# >>> App-token rotation (the operator, 2026-09-14)
# The hub already walks every live machine once a tick and already knows each
# one's id — so the tick is where a token that is about to die gets replaced, with
# no new loop, no new lock and no extra GitHub call for machines that are fine:
# the machine record carries the expiry the spawn shipped, so "is this one due"
# is a date comparison against a local file.
#
# NEVER FATAL, by construction. Every path returns 0 and every failure leaves the
# machine with the token it already has — which is the state this function exists
# to improve, never to break. A machine whose record has no expiry (it shipped the
# PAT, or it was spawned before this change) is left alone entirely.
#
# THE PUSHED TOKEN MUST BE NEWER THAN THE ONE IT REPLACES, and that test is the
# one that keeps a PAT off the machine: bin/gh-token.sh prints the fleet PAT rather
# than nothing when a mint fails, and a PAT carries no cache expiry, so an expiry
# that did not move forward means no mint happened and nothing is shipped.
rotate_gh_token() { # rotate_gh_token <machine-id> <machine-json>
  local mid="$1" mf="$2" expat exp now left rotat tok newexp nexp tf ghe gapp=hub ninst
  gh_rotate_armed || return 0
  [ -n "$POOL_SLUG" ] || return 0
  expat=$(jq -r '.gh_token_expires_at // ""' "$mf" 2>/dev/null)
  [ -n "$expat" ] || return 0
  exp=$(date -u -d "$expat" +%s 2>/dev/null) || return 0
  now=$(date -u +%s); left=$((exp - now))
  [ "$left" -le "$POOL_GH_TOKEN_ROTATE_BEFORE" ] || return 0
  # Once per 30 min per machine. Without this a machine whose push keeps failing
  # would buy a token every two minutes for the rest of its life.
  rotat=$(jq -r '.gh_token_rotated_at // ""' "$mf" 2>/dev/null)
  if [ -n "$rotat" ]; then
    rotat=$(date -u -d "$rotat" +%s 2>/dev/null) || rotat=0
    [ "$((now - rotat))" -ge "$POOL_GH_TOKEN_ROTATE_EVERY" ] || return 0
  fi
  # The expiry is asked with the SAME --min-life as the token, so both answers
  # come from the same cache row: a stale profile row is never the expiry of a
  # token the hub App answered (#1590 review B2 — rotation stalled on it).
  ghe=$(mktemp 2>/dev/null) || ghe=""
  tok=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$POOL_SLUG" 2>"${ghe:-/dev/null}") || tok=""
  gapp=$(pool_gh_answered "${ghe:-/dev/null}"); [ -z "$ghe" ] || rm -f "$ghe"
  newexp=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" --expires-at "$POOL_SLUG" 2>/dev/null) || newexp=""
  nexp=0; [ -n "$newexp" ] && nexp=$(date -u -d "$newexp" +%s 2>/dev/null) || nexp=0
  if [ -z "$tok" ] || [ "$nexp" -le "$exp" ]; then
    say "$mid: no fresher App token for $POOL_SLUG — it keeps the one it has (expires $expat)"
    return 0
  fi
  # The installation that minted it, from the same cache row (same --min-life).
  ninst=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" --installation-id "$POOL_SLUG" 2>/dev/null) || ninst=""
  case "$ninst" in *[!0-9]*) ninst="" ;; esac
  tf=$(mktemp /dev/shm/ghtok.XXXX 2>/dev/null) || tf=$(mktemp) || return 0
  ( umask 077; printf '%s\n' "$tok" > "$tf" )
  if mput "$mid" "$tf" /run/harness-env/gh-token; then
    rotate_gh_hint "$mid" "$ninst"
    # BH-5025: the next job on $mid sources global.env, so its GH_TOKEN= follows the file just pushed.
    mexec "$mid" "HARNESS=/data/harness bash -c '. /data/harness/bin/lib/gh-token-live.sh && gh_token_live_sync_env /run/harness-env/global.env'" >/dev/null \
      || say "$mid: pushed a fresh App token but could not sync GH_TOKEN in its global.env — new jobs on it sync at load_env"
    # The record is what carries the 30-minute floor, so a record that did not
    # update says so rather than being reported as a clean rotation: without the
    # stamp the next tick rotates this machine again.
    if jq --arg e "$newexp" --arg r "$(STAMP)" '.gh_token_expires_at=$e | .gh_token_rotated_at=$r' \
         "$mf" > "$mf.tmp" 2>/dev/null && mv "$mf.tmp" "$mf"; then
      say "rotated App token on $mid for $POOL_SLUG (expires $(date -u -d "$newexp" '+%H:%MZ' 2>/dev/null || echo "$newexp")) from the $gapp App, installation ${ninst:-unknown}"  # determinism: ok date-empty-stamp only reached when nexp>exp, which needs a non-empty newexp
    else
      say "$mid: pushed a fresh App token but could not stamp its machine record — the next tick will rotate it again"
    fi
  else
    say "$mid: could not push the rotated App token — it keeps the one it has (expires $expat)"
  fi
  rm -f "$tf" "$mf.tmp"; tok=""
  return 0
}
# rotate_gh_hint <machine-id> <installation-id|""> — THE BUCKET TRAVELS WITH THE
# ROTATED TOKEN TOO (BH-1602). The spawn wrote GH_TOKEN_INSTALLATION_ID into the
# bundle once; a rotation that changed App (builders -> hub retry, or back) left
# the builder's ledger naming the spawn-time installation. The id goes to a file
# of its own, which bin/lib/gh-token-live.sh reads with the token. Not named
# gh-token.*: that prefix is the token. An unknown id ships an EMPTY file, which
# unsets the hint on the builder (flat `app`), never a guessed id. Called only
# after the token itself was pushed, and a failure here is said, never fatal.
rotate_gh_hint() {
  local hf
  hf=$(mktemp /dev/shm/ghinst.XXXX 2>/dev/null) || hf=$(mktemp) || return 0
  ( umask 077; printf '%s\n' "$2" > "$hf" )
  mput "$1" "$hf" /run/harness-env/gh-installation-id \
    || say "$1: pushed a fresh App token but not its installation hint — ledger lines on $1 may name the previous installation"
  rm -f "$hf"
  return 0
}
# <<< App-token rotation

# mq_touch <box> <project> <pr>
#   The merge-queue hand-off over ssh, for a tier-1 APPROVE whose merge_queue
#   row failed. Tried at most twice (one retry) and the last rc returned
#   (BH-1957): this was `2>/dev/null || true`, so an unreachable box swallowed
#   the APPROVE, the log said "sent", and it sat queued nowhere.
mq_touch() {
  local box="$1" p="$2" pr="$3" try rc=1
  for try in 1 2; do
    ssh -n -o BatchMode=yes -o ConnectTimeout=15 "root@$box" \
      "mkdir -p /root/harness/state/merge-queue/$p; touch /root/harness/state/merge-queue/$p/$pr" \
      2>/dev/null && return 0
    rc=$?
  done
  return "$rc"
}

