# shellcheck shell=bash
# bin/lib/lead-carry.sh — THE CONDUCTOR CARRIES A LEAD MERGE ACROSS A CLEAN
# MAIN MERGE (BH-6291). Sourced by bin/lib/mc-lead-ready.sh and, on demand, by
# rebind_patch_id (bin/lib/mc/settle.sh, BH-8028), never run.
#
# THE CASE. A lead MERGE stands on head A. A clean `git merge main` moves the
# head to B. On its next tick the conductor finds nothing standing on B, so
# mc_lead_ready said no, the row went to HEAD_MOVED and the conductor bought a
# head-bound re-review. The lead-review enqueue lane (gate 50,
# bin/lib/lead-gates.d/50-replay-delta.sh) replays the lead word onto B, but
# only every 5 minutes, and the conductor reached B first.
#
# THE RULE. lead_carry <key> <owner/repo> <num> <head> [reason] carries the
# newest lead MERGE / MERGE-WITH-NOTES from another head G onto <head> in the same tick,
# only when patch_same (bin/lib/patch-same.sh) proves <head> carries G's patch:
# no new non-merge commit since G and no hand-resolved merge (main-merge), or a
# byte-exact rebase (patch-id); or when restamp_same (bin/lib/schema-restamp.sh)
# proves every new commit is a clean main merge or a schema-fragment restamp
# (restamp, BH-6842). Cheapest first:
#   MC_LEAD_CARRY=0, ACTIONS!=1, or the attempts line `leadcarry <key> <head>`
#     -> rc 1, nothing read.
#   history unreadable or truncated, no clone, fetch failed, la_decide rc 2
#     -> held: rc 1, no terminal mark, said once a head, asked again next tick.
#   no lead source row -> rc 1, terminal mark, no log line.
#   newest lead row a BLOCK, patch changed, la_decide rc 1, no lead token,
#   post failed -> refused: rc 1, terminal mark, one log line.
#   bin/lead-verdict.sh post rc 0, 4 or 5 -> carried: rc 0, terminal mark.
# The row is the one gate 50 writes (source lead, note `lead-replay:<G12>
# how:<how>`) plus `ref:#<id> by:merge-conductor`, so each writer sees the
# other's row and never posts twice. An optional 5th argument <reason> (the
# rebind's `patch-id:<id>` or `same:<how>`, BH-8028) appends
# ` carried_from:#<id> reason:<reason>`; a reason with whitespace is held.
# Every carried / refused decision is one conductor log line:
#   <key> LEAD_CARRY <carried|refused|held> from=<G12> to=<H12> word=<W>
#     ref=#<id> how=<how|-> patch_old=<id12|-> patch_new=<id12|-> reason=<text>

_lc_dir="${BASH_SOURCE[0]%/*}"

# _lc_log <key> <head> <result> <from> <word> <id> <how> <pold> <pnew> <reason>
_lc_log() {
  mc_log "$1 LEAD_CARRY $3 from=${4:0:12} to=${2:0:12} word=$5 ref=#$6 how=$7 patch_old=${8:0:12} patch_new=${9:0:12} reason=${10}"
}

# _lc_held <same args as _lc_log> — no terminal mark; the line once a head.
#   Pass all 10 (the result slot is "-"; this function writes `held`). With
#   fewer, _lc_log reads an unset ${10} and dies under set -u.
_lc_held() {
  mc_attempt_has "leadcarry-held $1 $2" 2>/dev/null && return 1
  mc_attempt_put "leadcarry-held $1 $2"
  _lc_log "$1" "$2" held "${@:4}"
  return 1
}

# _lc_done <key> <head> <result> ... — the terminal mark, then the line.
_lc_done() {
  mc_attempt_put "leadcarry $1 $2"
  _lc_log "$@"
}

lead_carry() {
  local key="$1" slug="$2" num="$3" head resp ph pw pid project repo how pold="-" pnew="-" tok box prc out note
  local reason="${5:-}"
  head=$(printf '%s' "${4:-}" | tr 'A-F' 'a-f')
  [ "${MC_LEAD_CARRY:-1}" != 0 ] || return 1
  [ "${ACTIONS:-0}" = 1 ] || return 1
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  mc_attempt_has "leadcarry $key $head" 2>/dev/null && return 1
  case "$reason" in *[[:space:]]*)
    _lc_held "$key" "$head" - - - - - - - "the carry reason has whitespace"; return 1 ;;
  esac
  command -v _vd_get >/dev/null 2>&1 || { [ -r "$_lc_dir/verdicts.sh" ] && . "$_lc_dir/verdicts.sh"; }
  command -v patch_same >/dev/null 2>&1 || { [ -r "$_lc_dir/patch-same.sh" ] && . "$_lc_dir/patch-same.sh"; }
  command -v _vd_get >/dev/null 2>&1 && command -v patch_same >/dev/null 2>&1 && command -v la_decide >/dev/null 2>&1 \
    || { _lc_held "$key" "$head" - - - - - - - "a reader is not loaded (verdicts.sh, patch-same.sh or lead-authority.sh)"; return 1; }

  # A truncated history cannot prove which lead row is newest: unreadable.
  if ! resp=$(_vd_get "$slug#$num ${head:0:8}" "/api/verdicts?repo=$slug&pr=$num") \
     || ! jq -e '(.rows | type) == "array" and .truncated != true' >/dev/null 2>&1 <<<"$resp"; then
    _lc_held "$key" "$head" - - - - - - - "verdicts history unreadable or truncated"; return 1
  fi
  # Gate 50's source rule: the newest lead word on another head that is not
  # itself a replay.
  IFS=$'\t' read -r ph pw pid < <(jq -r --arg h "$head" '[.rows[] | select(.source == "lead"
      and ((.head_sha // "") | ascii_downcase) != $h
      and ((.verdict // "") | IN("MERGE", "MERGE-WITH-NOTES", "BLOCK"))
      and (((.note // "") | contains("lead-replay:")) | not))]
    | max_by(.id) // empty | "\(.head_sha | ascii_downcase)\t\(.verdict)\t\(.id)"' <<<"$resp" 2>/dev/null)
  if [[ ! "$ph" =~ ^[0-9a-f]{40}$ ]]; then mc_attempt_put "leadcarry $key $head"; return 1; fi
  if [ "$pw" = BLOCK ]; then
    _lc_done "$key" "$head" refused "$ph" "$pw" "$pid" - - - "newest lead verdict is a BLOCK"; return 1
  fi

  # D43: never a path from an empty root. No FLEET_CONF, HARNESS or H: held.
  local fc="${FLEET_CONF:-}" root="${HARNESS:-${H:-}}"
  [ -n "$fc" ] || { [ -n "$root" ] && fc="$root/fleet.conf"; }
  if [ -z "$fc" ]; then
    _lc_held "$key" "$head" - "$ph" "$pw" "$pid" - - - "no fleet.conf (FLEET_CONF, HARNESS and H are empty)"; return 1
  fi
  project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "$fc" 2>/dev/null)
  repo="${REPOS_ROOT:-/root/repos}/$project"
  if [ -z "$project" ] || [ ! -d "$repo/.git" ]; then
    _lc_held "$key" "$head" - "$ph" "$pw" "$pid" - - - "no clone for $slug at $repo"; return 1
  fi
  if ! patch_same_fetch "$repo" "$ph" "$head" "$num"; then
    _lc_held "$key" "$head" - "$ph" "$pw" "$pid" - - - "fetch of ${ph:0:12}/${head:0:12} failed ($PS_FETCH_ERR)"; return 1
  fi
  pold=$(_ps_patch_id "$repo" origin/main "$ph") || pold="-"
  pnew=$(_ps_patch_id "$repo" origin/main "$head") || pnew="-"
  if ! how=$(patch_same "$repo" origin/main "$ph" "$head"); then
    # BH-6842: the conductor's restamp commit (renames + reference rewrites
    # only, bin/lib/schema-restamp.sh), alone or with clean main merges.
    command -v restamp_same >/dev/null 2>&1 || { [ -r "$_lc_dir/schema-restamp.sh" ] && . "$_lc_dir/schema-restamp.sh"; }
    if ! { command -v restamp_same >/dev/null 2>&1 && how=$(restamp_same "$repo" origin/main "$ph" "$head"); }; then
      _lc_done "$key" "$head" refused "$ph" "$pw" "$pid" - "$pold" "$pnew" "patch changed (a new commit or a resolved conflict)"; return 1
    fi
  fi

  # The authority says yes before any row is written.
  la_decide "$slug" "$num" "$head" conductor; prc=$?
  case "$prc" in
    0) ;;
    1) _lc_done "$key" "$head" refused "$ph" "$pw" "$pid" "$how" "$pold" "$pnew" "${LA_REASON:-la_decide rc 1}"; return 1 ;;
    *) _lc_held "$key" "$head" - "$ph" "$pw" "$pid" "$how" "$pold" "$pnew" "la_decide rc $prc: ${LA_REASON:-undecidable}"; return 1 ;;
  esac
  tok="${LEAD_VERDICT_TOKEN_FILE:-${HOME:-}/.config/cromford/lead-verdict-token}"
  if [ ! -r "$tok" ]; then
    _lc_done "$key" "$head" refused "$ph" "$pw" "$pid" "$how" "$pold" "$pnew" "no lead token on this box"; return 1
  fi
  box="${JOBS_BOX:-}"; [ -n "$box" ] || box=$(local_box_name 2>/dev/null)
  note="lead-replay:${ph:0:12} how:$how ref:#$pid by:merge-conductor"
  [ -z "$reason" ] || note="$note carried_from:#$pid reason:$reason"
  prc=0; out=$("${LEAD_VERDICT_BIN:-$_lc_dir/../lead-verdict.sh}" post "$slug" "$num" "$head" "$pw" --source lead \
    --reviewer "box:${box:-unknown}" --note "$note" 2>&1) || prc=$?
  case "$prc" in
    0|4|5)
      _lc_done "$key" "$head" carried "$ph" "$pw" "$pid" "$how" "$pold" "$pnew" "lead $pw recorded on the new head (post rc $prc)"
      return 0 ;;
  esac
  _lc_done "$key" "$head" refused "$ph" "$pw" "$pid" "$how" "$pold" "$pnew" "post rc $prc: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
  return 1
}
