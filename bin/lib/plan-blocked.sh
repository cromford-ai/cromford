#!/bin/bash
# shellcheck shell=bash
# bin/lib/plan-blocked.sh — BH-7116: a PLAN_BLOCKED build says WHY on its
# ticket, and the stranded watch stops re-offering it until somebody answers.
# Sourced, never run; defines functions only.
#
# On 2026-10-16 eight tickets went PLAN_BLOCKED 2-4 times each. The stranded
# watch re-offered every one of them each idle window, the planner blocked it
# again, and no reason ever reached a ticket: plan.md lived only on the reaped
# pool machine, and bin/board-closeout.sh refuses every non-PR result (exit 4).
#
#   pb_excerpt <plan-file>                          the blocked section, trimmed
#   pb_notice <harness> <project> <ticket> <key> <build-dir>
#                                                   the builder's one comment
#   pb_hub_copy <harness> <project> <local-dir>     plan.md into the hub record
#   pb_stranded_skip <project> <key> <thread-json> <comment-count>
#                                                   the stranded watch's skip
#
# Callers: bin/lib/rb/gates.sh `# >>> plan-blocked notice` (pb_notice, inside
# _job_finish on a builder), bin/fly-pool.sh's reap (pb_hub_copy) and
# bin/orphan-reconcile.sh --stranded (pb_stranded_skip). Every dependency is
# sourced inside the function that needs it, so loading this file costs nothing.

# pb_excerpt <plan-file> -> the plan's blocked section, scrubbed, at most 40
# lines and 3000 bytes, cut on a line end. Prints NOTHING when there is no
# plan, no scrubber, or the scrubber fails: an unscrubbed plan never reaches a
# ticket (fail closed). First match wins:
#   (a) line 1 is a BLOCKED marker with text after it: that text, plus the
#       lines after it up to the first `#`/`##` heading;
#   (b) the first `#`/`##` heading (line 1 aside) naming BLOCKED, Open
#       questions or Questions: its body, up to the next heading of the same or
#       a higher level;
#   (c) the top of the plan, with a marker-only line 1 dropped.
pb_excerpt() {
  local f="${1:-}" root="${HARNESS:-${H:-}}" src out
  [ -n "$root" ] && [ -x "$root/bin/transcript-scrub.sh" ] || return 0
  [ -n "$f" ] && [ -s "$f" ] || return 0
  src=$("$root/bin/transcript-scrub.sh" < "$f" 2>/dev/null) || return 0
  [ -n "$src" ] || return 0
  out=$(printf '%s\n' "$src" | awk '
    function lvl(s) { if (match(s, /^#+[[:space:]]/)) return RLENGTH - 1; return 0 }
    { L[NR] = $0 }
    END {
      n = NR; m = "^[[:space:]]*([#*]+[[:space:]]*)*(PLAN[_ -])?BLOCKED(-NEEDS-CLARIFICATION)?[*]*"
      first = L[1]; markonly = 0; rest = ""
      if (match(first, m) && substr(first, RSTART + RLENGTH, 1) !~ /[_[:alnum:]]/) {
        rest = substr(first, RLENGTH + 1)
        sub(/^[[:space:]]*(:|::|-|—|–|\.)*[[:space:]]*/, "", rest); sub(/[[:space:]]+$/, "", rest)
        if (rest == "") markonly = 1
      }
      # (a)
      if (rest != "") {
        print rest
        for (i = 2; i <= n; i++) { if (L[i] ~ /^##?[[:space:]]/) break; print L[i] }
        exit
      }
      # (b)
      for (i = 2; i <= n; i++) {
        h = lvl(L[i]); if (h < 1 || h > 2) continue
        t = tolower(L[i])
        if (t ~ /blocked/ || t ~ /questions/) {
          got = 0
          for (j = i + 1; j <= n; j++) { k = lvl(L[j]); if (k >= 1 && k <= h) break; B[++got] = L[j] }
          body = 0; for (j = 1; j <= got; j++) if (B[j] ~ /[^[:space:]]/) body = 1
          if (body) { for (j = 1; j <= got; j++) print B[j]; exit }
        }
      }
      # (c)
      for (i = (markonly ? 2 : 1); i <= n; i++) print L[i]
    }' | awk '!seen && /^[[:space:]]*$/ { next } { seen = 1; print }' | head -40)
  # Trailing blank lines carry nothing into a quote.
  out=$(printf '%s\n' "$out" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')
  if [ "$(printf '%s' "$out" | LC_ALL=C wc -c)" -gt 3000 ]; then
    out=$(printf '%s' "$out" | LC_ALL=C head -c 3000 | sed '$d')
  fi
  printf '%s' "$out"
}

_pb_say() { printf '%s [plan-blocked/%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${_PB_WHO:-?}" "$*"; }

# _pb_mark <build-dir> <note> — append <note> to RESULT line 1 (temp file + mv,
# the shape bin/lib/rb/result.sh rb_close_out step 3 uses). rc of the move.
_pb_mark() {
  local b="$1" note="$2" line
  line=$(head -1 "$b/RESULT" 2>/dev/null)
  printf '%s%s\n' "$line" "$note" > "$b/RESULT.pb" \
    && tail -n +2 "$b/RESULT" >> "$b/RESULT.pb" \
    && mv -f "$b/RESULT.pb" "$b/RESULT"
}

# _pb_last_epoch <harness> <project> <key> — the epoch of the last notice
# posted on this ticket, or nothing. The `plan-blocked-last` ledger row first
# (status `cleared` = no marker), the state file when there is no row or the
# ledger does not answer.
_pb_last_epoch() {
  local h="$1" p="$2" key="$3" row rc st det
  if command -v job_ledger_row >/dev/null 2>&1; then
    row=$(job_ledger_row commented "plan-blocked-last $p $key" 2>/dev/null </dev/null); rc=$?
    if [ "$rc" = 0 ]; then
      st=$(printf '%s' "$row" | jq -r '.status // ""' 2>/dev/null)
      det=$(printf '%s' "$row" | jq -r '.detail // ""' 2>/dev/null)
      [ "$st" = cleared ] && return 0
      if [ "$st" = commented ] && [[ "$det" =~ ^[0-9]+$ ]]; then printf '%s' "$det"; return 0; fi
    fi
  fi
  det=$(head -1 "$h/state/plan-blocked/$p/$key.last" 2>/dev/null)
  [[ "$det" =~ ^[0-9]+$ ]] && printf '%s' "$det"
  return 0
}

# _pb_answers_since <repo> <num> <epoch> — prints how many HUMAN comments on
# the issue were created or edited after <epoch> (the pb_stranded_skip rule).
# rc non-zero when the thread could not be read.
_pb_answers_since() {
  local repo="$1" num="$2" ep="$3" since def apps
  since=$(date -u -d "@$ep" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 75
  [ -n "${HARNESS_SELF_JQ_DEF:-}" ] || . "${BASH_SOURCE[0]%/*}/harness-self.sh" 2>/dev/null
  def="${HARNESS_SELF_JQ_DEF:-def hs_ours(\$apps): false;}"
  apps='[]'; command -v harness_self_apps_json >/dev/null 2>&1 && apps=$(harness_self_apps_json)
  _gh_rest_field "repos/$repo/issues/$num/comments?since=$since&per_page=100" "$def"'
    def ts: (. // "") | tostring | sub("\\.[0-9]+"; "") | (try fromdateiso8601 catch 0);
    if type != "array" then error("not an array") else . end
    | [ .[] | select(((.user.type // "") | tostring | ascii_downcase) != "bot" and (hs_ours('"${apps:-[]}"') | not))
            | select(([(.created_at | ts), (.updated_at | ts)] | max) > '"$ep"') ] | length'
}

# pb_notice <harness> <project> <ticket> <key> <build-dir>
#   ONE ticket comment per distinct block reason, and none at all while the
#   last one is unanswered (BH-7719), posted by the builder from inside its own
#   run, and the builder-direct marker on RESULT line 1 so the owning box's
#   sweep does not post a second one (bin/lib/builder-direct.sh).
#   rc 0 posted, or this exact reason is already on the ticket, or an earlier
#        notice has no human answer yet (marked every way)
#   rc 1 nothing to quote, or the POST failed: no marker, the sweep carries it
#   rc 4 not this lane's: not PLAN_BLOCKED, already closed out, an in-app board,
#        or no repo / issue number
#   Log lines go to stdout; the caller sends them to pipeline.log.
pb_notice() {
  local h="${1:-}" p="${2:-}" t="${3:-}" key="${4:-}" b="${5:-}" line bp repo num ex tok mkey mfile bf last ans why now
  local _PB_WHO="$p/$key"
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$key" ] && [ -n "$b" ] && [ -s "$b/RESULT" ] || return 4
  line=$(head -1 "$b/RESULT" 2>/dev/null)
  case "$line" in "PLAN_BLOCKED "*|PLAN_BLOCKED) ;; *) return 4 ;; esac
  command -v bd_closed_out >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/builder-direct.sh" 2>/dev/null
  command -v bd_note >/dev/null 2>&1 || return 4
  bd_closed_out "$line" && return 4
  bp=$("$h/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || bp=""
  [ "$bp" = "-" ] || return 4
  repo=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || repo=""
  # The issue is the ticket id on a GitHub-Issues board (a decompose child's key
  # does not carry it); the key's number only when no id came in.
  case "$t" in ''|*[!0-9]*) num=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$key") ;; *) num="$t" ;; esac
  [ -n "$repo" ] && [ "$repo" != "-" ] && [ -n "$num" ] || return 4
  ex=$(HARNESS="$h" pb_excerpt "$b/plan.md")
  if [ -z "$ex" ]; then
    _pb_say "no plan-blocked notice: no blocked section to quote (missing plan.md, or no scrubber) — the RESULT is unmarked, so the owning box's sweep carries it"
    return 1
  fi
  tok=$(printf '%s' "$ex" | sha256sum | cut -c1-16)
  mkey="plan-blocked $p $key"; mfile="$h/state/plan-blocked/$p/$key.$tok"
  command -v cm_has >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/comment-mark.sh" 2>/dev/null
  command -v cm_has >/dev/null 2>&1 || return 4
  if HARNESS="$h" cm_has "$mkey" "$tok" "$mfile"; then
    _pb_mark "$b" "$(bd_note "$repo#$num") (the same block reason is already on $repo#$num)" || return 1
    _pb_say "plan-blocked notice not posted: the same block reason ($tok) is already on $repo#$num; RESULT marked"
    return 0
  fi
  command -v gh_rest_comment >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/gh-rest.sh" 2>/dev/null
  # ONE NOTICE PER TICKET UNTIL A PERSON ANSWERS (BH-7719). A re-plan words the
  # same question anew, so the token above differs each time (#7655: 11
  # comments). After a notice, the next one waits for a human comment created
  # or edited since. A thread that cannot be read holds it too (BH-2317).
  last=$(_pb_last_epoch "$h" "$p" "$key")
  if [ -n "$last" ]; then
    ans=""
    command -v _gh_rest_field >/dev/null 2>&1 && { ans=$(HARNESS="$h" _pb_answers_since "$repo" "$num" "$last") || ans=""; }
    case "$ans" in ''|*[!0-9]*|0)
      why="nobody has answered it"
      [ -n "$ans" ] || why="nobody has answered it, as far as we know: the thread could not be read"
      _pb_mark "$b" "$(bd_note "$repo#$num") (a plan-blocked notice is already on $repo#$num and $why)" || return 1
      _pb_say "plan-blocked notice not posted: the last notice on $repo#$num (epoch $last) has no human answer (${ans:-thread unreadable}); RESULT marked"
      return 0 ;;
    esac
  fi
  # THE MARK BEFORE THE SEND (BH-2317): a client ticket commented twice is the
  # worse failure, so a POST that fails after this is not retried by this lane.
  HARNESS="$h" cm_put "$mkey" "$tok" "$mfile" || true
  command -v gh_token_live >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/gh-token-live.sh" 2>/dev/null
  command -v gh_token_live >/dev/null 2>&1 && HARNESS="$h" gh_token_live "$repo"
  command -v gh_rest_comment >/dev/null 2>&1 || { _pb_say "no plan-blocked notice: bin/lib/gh-rest.sh is missing — the sweep carries it"; return 1; }
  bf=$(mktemp "${TMPDIR:-/tmp}/plan-blocked-body.XXXXXX") || { _pb_say "no plan-blocked notice: no temp file for the body"; return 1; }
  {
    printf 'We stopped before building this one. The plan needs an answer the ticket does not give yet:\n\n'
    printf '%s\n' "$ex" | sed 's/^/> /; s/^> $/>/'
    printf '\nReply here with the answer and we will plan it again.\n'
  } > "$bf"
  if ! gh_rest_comment "$repo" "$num" "$bf"; then
    rm -f "$bf"
    _pb_say "plan-blocked notice NOT posted on $repo#$num (HTTP ${GH_REST_STATUS:-000}) — the RESULT is unmarked, so the owning box's sweep carries it"
    return 1
  fi
  rm -f "$bf"
  # The per-ticket marker AFTER the send: a POST that failed must not hold the
  # ticket's first notice back.
  now=$(date -u +%s)
  command -v job_ledger_put >/dev/null 2>&1 \
    && job_ledger_put commented "plan-blocked-last $p $key" commented "$now" >/dev/null 2>&1 </dev/null
  mkdir -p "$h/state/plan-blocked/$p" 2>/dev/null && printf '%s\n' "$now" > "$h/state/plan-blocked/$p/$key.last" 2>/dev/null
  _pb_mark "$b" "$(bd_note "$repo#$num")" || { _pb_say "plan-blocked notice posted on $repo#$num but the RESULT could not be marked"; return 1; }
  _pb_say "plan-blocked notice posted on $repo#$num (reason $tok); RESULT marked"
  return 0
}

# pb_hub_copy <harness> <project> <local-dir> — the hub's build record of a
# PLAN_BLOCKED pool result gets plan.md from the ledger (the body the builder
# pushed as a plan_md transcript, BH-531) when the reap could not fetch it from
# the machine: the RESULT came from the pool-result row and the machine is gone.
# Never rewrites the RESULT (the hub dir is a custody copy). Prints one line
# for the caller's log when it did something or could not; rc 0 copied or not
# needed, rc 1 could not.
pb_hub_copy() {
  local h="${1:-}" p="${2:-}" l="${3:-}" line rec job
  [ -n "$p" ] && [ -n "$l" ] && [ -s "$l/RESULT" ] || return 0
  line=$(head -1 "$l/RESULT" 2>/dev/null)
  case "$line" in "PLAN_BLOCKED "*|PLAN_BLOCKED) ;; *) return 0 ;; esac
  [ -s "$l/plan.md" ] && return 0
  if ! command -v job_for_record >/dev/null 2>&1 || ! command -v job_transcript_get_source >/dev/null 2>&1; then
    printf 'plan-blocked: %s has no plan.md and no jobs client is loaded to fetch it\n' "$(basename "$l")"; return 1
  fi
  # The builder's own dir name: BUILD_DIR:, else the plan.md path on line 1.
  rec=$(sed -n 's/^BUILD_DIR: //p' "$l/RESULT" | head -1); rec="${rec%/}"; rec="${rec##*/}"
  if [ -z "$rec" ]; then
    rec=$(grep -oE '[^ ]*/plan\.md( |$)' <<<"$line" | head -1); rec="${rec% }"; rec="${rec%/plan.md}"; rec="${rec##*/}"
  fi
  [ -n "$rec" ] || rec=$(basename "$l")
  job=$(job_for_record "$p" "$rec" 2>/dev/null) || job=""
  if [ -z "$job" ]; then printf 'plan-blocked: no ledger job names %s; %s keeps no plan.md\n' "$rec" "$(basename "$l")"; return 1; fi
  if job_transcript_get_source "$job" plan_md > "$l/plan.md.tmp" 2>/dev/null && [ -s "$l/plan.md.tmp" ]; then
    mv -f "$l/plan.md.tmp" "$l/plan.md"
    printf 'plan-blocked: plan.md for %s copied from the ledger (job %s)\n' "$rec" "$job"; return 0
  fi
  rm -f "$l/plan.md.tmp"
  printf 'plan-blocked: job %s has no plan_md body; %s keeps no plan.md\n' "$job" "$(basename "$l")"
  return 1
}

# pb_stranded_skip <project> <key> <thread-json-file-or-empty> <comment-count>
#   Must the stranded watch skip this ticket? One queue point read (build_queue
#   is keyed by project + ticket_key) and the thread pass 1 already fetched.
#   rc 0 SKIP (prints the block's updated_at): the row is not queued/claimed, its
#        reason's first word is exactly PLAN_BLOCKED, and no HUMAN comment was
#        created or edited after the row's updated_at
#   rc 1 RE-OFFER: the last reason is something else, or a human answered since
#   rc 2 UNKNOWN (the caller re-offers, today's behaviour): the queue did not
#        answer or has no row, updated_at does not parse, or comments were
#        counted and the thread is missing or is not an array
#   A HUMAN comment: user.type is not Bot and hs_ours (bin/lib/harness-self.sh)
#   is false. The PAT login counts as human, as in bin/lib/plan-thread.sh.
pb_stranded_skip() {
  local p="${1:-}" k="${2:-}" th="${3:-}" cnt="${4:-0}" resp row st why upd w1 tb apps def n
  [ -n "$p" ] && [ -n "$k" ] || return 2
  command -v _jobs_req >/dev/null 2>&1 || return 2
  resp=$(_jobs_req GET "/api/queue?project=$p&key=$k&limit=1" 2>/dev/null) || return 2
  row=$(printf '%s' "$resp" | jq -c '.queue[0] // empty' 2>/dev/null)
  [ -n "$row" ] || return 2
  st=$(jq -r '.status // ""' <<<"$row"); why=$(jq -r '.reason // ""' <<<"$row"); upd=$(jq -r '.updated_at // ""' <<<"$row")
  case "$st" in queued|claimed) return 1 ;; esac
  read -r w1 _ <<<"$why"
  [ "$w1" = PLAN_BLOCKED ] || return 1
  tb=$(jq -rn --arg u "$upd" 'try ($u | sub("\\.[0-9]+"; "") | sub(" "; "T") | (if endswith("Z") then . else . + "Z" end) | fromdateiso8601) catch empty' 2>/dev/null)
  case "$tb" in ''|*[!0-9]*) return 2 ;; esac
  case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
  if [ -z "$th" ] || [ ! -s "$th" ]; then
    [ "$cnt" = 0 ] && { printf '%s' "$upd"; return 0; }
    return 2
  fi
  jq -e 'type == "array"' "$th" >/dev/null 2>&1 || return 2
  [ -n "${HARNESS_SELF_JQ_DEF:-}" ] || . "${BASH_SOURCE[0]%/*}/harness-self.sh" 2>/dev/null
  def="${HARNESS_SELF_JQ_DEF:-def hs_ours(\$apps): false;}"
  apps='[]'; command -v harness_self_apps_json >/dev/null 2>&1 && apps=$(harness_self_apps_json)
  n=$(jq --argjson tb "$tb" --argjson apps "${apps:-[]}" "$def"'
    def ts: (. // "") | tostring | sub("\\.[0-9]+"; "") | (try fromdateiso8601 catch 0);
    [ .[] | select(((.user.type // "") | tostring | ascii_downcase) != "bot" and (hs_ours($apps) | not))
          | select(([(.created_at | ts), (.updated_at | ts)] | max) > $tb) ] | length' "$th" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) return 2 ;; esac
  [ "$n" = 0 ] || return 1
  printf '%s' "$upd"
  return 0
}
