# >>> pool listing retry and saved list (BH-9407)
# ONE FAILED `machines list` CALL USED TO DARKEN THE WHOLE SWEEP (alert 61289,
# pool-project-6-os): no retry, no fallback, and an alert with no error class.
# These functions are called by the listing block (3400) and the sweep (3500).
#
# - pool_list_fetch retries a failed call, but only for the classes a retry can
#   fix (timeout, api, other with rc != 126/127). auth and app-not-found are
#   config; a rc-0 answer that is not an array, and `[]` beside tracked files,
#   are not call failures. The 16 pool suites whose flyctl stub prints nothing
#   must not wait 22 s per tick.
# - The last usable list is kept in state/fly-pool-listing/<p>.json, minus
#   every machine this tick destroyed (destroy_machine writes
#   $LISTING.destroyed). Its mtime is the time Fly gave that answer: dropping a
#   machine keeps it. It is a cache of a Fly answer (catalog/state-paths.d/
#   9407-fly-pool-listing.json), not a pool record, so it lives outside
#   state/fly-pool/<p>/.
# - When every try fails, a saved list younger than POOL_LIST_SAVED_MAX_AGE_S
#   drives the SWEEP only. LIST_OK stays 0: the REAP asks `machine status`, no
#   observe is sent, nothing is requeued, and the orphan pass does not run.

# pool_list_backoff — print the retry waits, one per retry.
# Lane knob POOL_LIST_RETRY_BACKOFF_S (catalog/lanes.d/fly-pool.knobs.d/);
# "2 5 15" is the code fallback named by that knob. "" = no retry.
pool_list_backoff() {
  local v="${POOL_LIST_RETRY_BACKOFF_S-2 5 15}" w
  for w in $v; do
    case "$w" in
      *[!0-9]*) say "ignoring unusable POOL_LIST_RETRY_BACKOFF_S='$v' (not a list of seconds) — falling back to 2 5 15"
                printf '2 5 15\n'; return 0 ;;
    esac
  done
  printf '%s\n' "$v"
}

# pool_list_max_age — print POOL_LIST_SAVED_MAX_AGE_S (lane knob; 600 is the
# code fallback named by that knob; 0 = never use a saved list).
pool_list_max_age() {
  local v="${POOL_LIST_SAVED_MAX_AGE_S:-}"
  case "$v" in
    '') printf '600\n' ;;
    *[!0-9]*) say "ignoring unusable POOL_LIST_SAVED_MAX_AGE_S='$v' (not a number) — falling back to 600"
              printf '600\n' ;;
    *) printf '%s\n' "$v" ;;
  esac
}

# pool_list_class <rc> <errfile> <outfile> — print one class word:
# auth | app-not-found | timeout | api | other.
pool_list_class() {
  local rc="${1:-1}" ef="${2:-}" of="${3:-}" t
  [ "$rc" = 124 ] && { echo timeout; return 0; }
  t=$(head -c 2000 "$ef" 2>/dev/null | tr 'A-Z' 'a-z')
  if [ "$rc" = 0 ]; then
    # The call answered. Not an array is a bad API answer; an array here is
    # the empty-beside-tracked case, which is not a call failure.
    jq -e 'type=="array"' "$of" >/dev/null 2>&1 && { echo other; return 0; }
    echo api; return 0
  fi
  if grep -Eq 'unauthori[sz]ed|(^|[^0-9])40[13]([^0-9]|$)|forbidden|not authenticated|token .* (invalid|expired)' <<<"$t"; then
    echo auth
  elif grep -Eq 'could not find app|app .* not found|no such app' <<<"$t"; then
    echo app-not-found
  elif grep -Eq 'timed out|deadline exceeded|i/o timeout' <<<"$t"; then
    echo timeout
  elif grep -Eq '(^|[^0-9])5[0-9][0-9]([^0-9]|$)|internal server error|bad gateway|service unavailable|rate limit|too many requests|(^|[^0-9])429([^0-9]|$)' <<<"$t"; then
    echo api
  else
    echo other
  fi
}

# pool_list_scrub — stdin to stdout with every Fly token form removed.
pool_list_scrub() {
  local s
  s=$(cat)
  if [ "${#FLY_TOKEN_VAL}" -ge 8 ] 2>/dev/null; then s=${s//"$FLY_TOKEN_VAL"/<redacted>}; fi
  s=$(printf '%s' "$s" | sed -E 's/FlyV1 [^ ]*/<redacted:fly-token>/g; s/fm[12][a-z]?_[A-Za-z0-9_+\/=.-]+/<redacted:fly-token>/g')
  if command -v token_redact >/dev/null 2>&1; then s=$(printf '%s' "$s" | token_redact 2>/dev/null || printf '%s' "$s"); fi
  printf '%s' "$s"
}

# pool_list_fetch — fill $LISTING. Sets LIST_OK, LIST_WHY (scrubbed),
# LIST_CLASS and LIST_TRIES.
pool_list_fetch() {
  local rc waits w i=0 k
  LIST_OK=0; LIST_WHY=""; LIST_CLASS=""; LIST_TRIES=0
  waits=$(pool_list_backoff)
  k=$(wc -w <<<"$waits" | tr -d ' ')
  set -- $waits
  while :; do
    LIST_TRIES=$((LIST_TRIES+1))
    timeout 30 "$FLY" machines list -a "$APP" --json > "$LISTING" 2>"$LISTING.err"; rc=$?
    if [ "$rc" = 0 ] && jq -e 'type=="array"' "$LISTING" >/dev/null 2>&1; then
      LIST_OK=1; LIST_WHY=""; LIST_CLASS=""
      if [ "$(jq -r 'length' "$LISTING" 2>/dev/null)" = 0 ] && ls "$POOL"/*.json >/dev/null 2>&1; then
        LIST_OK=0; LIST_WHY=empty-with-tracked; LIST_CLASS=other
      fi
      return 0
    fi
    LIST_CLASS=$(pool_list_class "$rc" "$LISTING.err" "$LISTING")
    if [ "$rc" = 0 ]; then
      LIST_WHY="flyctl did not print a machine array: $(head -c 120 "$LISTING" 2>/dev/null | tr '\n\r\t' '   ')"
    elif [ "$rc" = 124 ]; then
      LIST_WHY="machines list timed out after 30s"
    else
      LIST_WHY=$(head -1 "$LISTING.err" 2>/dev/null | cut -c1-120)
      [ -n "$LIST_WHY" ] || LIST_WHY="machines list exited non-zero with no error text"
    fi
    LIST_WHY=$(printf '%s' "$LIST_WHY" | pool_list_scrub)
    # Not retried: config (auth, app-not-found), a missing binary (126/127)
    # and an answer that came back rc 0.
    [ "$rc" = 0 ] && return 0
    case "$rc" in 126|127) return 0 ;; esac
    case "$LIST_CLASS" in auth|app-not-found) return 0 ;; esac
    [ "$i" -lt "$k" ] || return 0
    i=$((i+1)); w=${!i}
    say "machines list try $LIST_TRIES failed ($LIST_CLASS) — retry $i of $k in $w s"
    sleep "$w"
  done
}

# pool_list_save_good — keep this tick's usable list, minus the machines this
# tick destroyed. On a saved-list tick it rewrites the saved file the same way
# and keeps its mtime, so a destroyed machine is not destroyed twice and the
# file never looks younger than Fly's answer. tmp + mv: a reader never sees a
# half-written file.
pool_list_save_good() {
  local _plg_src _plg_good="$HARNESS/state/fly-pool-listing/$P.json" _plg_part
  if [ "${LIST_OK:-0}" = 1 ]; then _plg_src="$LISTING"
  elif [ -n "${LIST_SAVED:-}" ]; then _plg_src="$LIST_SAVED"
  else return 0; fi
  mkdir -p "$HARNESS/state/fly-pool-listing" 2>/dev/null || return 0
  _plg_part="$HARNESS/state/fly-pool-listing/$P.json.part.$$"
  jq -c --rawfile d "$LISTING.destroyed" \
     '($d | split("\n") | map(select(length>0))) as $gone | map(select((.id // "") as $i | ($gone | index($i)) | not))' \
     "$_plg_src" > "$_plg_part" 2>/dev/null \
    || jq -c '.' "$_plg_src" > "$_plg_part" 2>/dev/null || { rm -f "$_plg_part"; return 0; }
  [ "${LIST_OK:-0}" = 1 ] || touch -r "$_plg_good" "$_plg_part" 2>/dev/null
  mv -f "$_plg_part" "$_plg_good" 2>/dev/null || rm -f "$_plg_part"
}

# pool_list_saved_pick — on a failed listing, set LIST_SAVED (path) and
# LIST_SAVED_AGE (s) when the saved list is a non-empty JSON array younger than
# POOL_LIST_SAVED_MAX_AGE_S. An empty saved list has nothing to destroy, so the
# tick reports a dark sweep as before. Otherwise both stay empty.
pool_list_saved_pick() {
  local good="$HARNESS/state/fly-pool-listing/$P.json" max mt age
  LIST_SAVED=""; LIST_SAVED_AGE=""
  [ "${LIST_OK:-0}" = 1 ] && return 0
  [ -f "$good" ] || return 0
  max=$(pool_list_max_age)
  [ "$max" -gt 0 ] 2>/dev/null || return 0
  jq -e 'type=="array" and length>0' "$good" >/dev/null 2>&1 || return 0
  mt=$(stat -c %Y "$good" 2>/dev/null) || return 0
  case "$mt" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( $(date -u +%s) - mt ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$max" ] || return 0
  LIST_SAVED="$good"; LIST_SAVED_AGE="$age"
}
# <<< pool listing retry and saved list
