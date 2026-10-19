# shellcheck shell=bash
# bin/lib/execute-empty.sh — BH-5911: an EXECUTE_EMPTY build says why it
# stopped, and the pool stops relaunching a key that ended empty twice.
# Sourced, never run. Defining functions is its only effect at source time.
#
# WHY. project-6-os, 2026-10-10: TK-16 ran 5 times and TK-17/18/19 2-3 times
# each, every run EXECUTE_EMPTY after 64-90 s of execute (~$0.6 a run). No
# transcript reached the build record, the RESULT line said only "no changes
# produced", and reconcile relaunched the keys every ~30 min. Nobody could see
# why the model stopped.
#
# THE FUNCTIONS
#   ee_on_empty <build-dir>   called by the `# >>> execute result` block of
#       bin/lib/rb/execute.sh on both EXECUTE_EMPTY paths. Writes the stop
#       reason (ee_reason) to <build-dir>/stop-reason.txt and the transcript to
#       <build-dir>/execute-transcript.md (ee_transcript), which shows the
#       reason at the top. Prints nothing and never fails the caller.
#       THE MODEL'S TEXT NEVER GOES ON THE RESULT LINE (lead review of #5939):
#       readers match RESULT line 1 by substring (bin/fly-pool.sh cools an
#       account on *RUNNER_EXHAUSTED*, bin/postmerge-qa.sh and
#       bin/deploy-train.sh take the first pull URL), so a final message that
#       quotes either would act on the hub. The RESULT stays fixed text, and a
#       reader that wants the reason reads stop-reason.txt.
#   ee_transcript <outfile> <dest>  the execute session, rendered
#       (bin/transcript-render.sh) when $OUT.json names a claude session whose
#       jsonl is on this machine, else the stage's own output; the LAST
#       EE_TRANSCRIPT_LINES (200) lines, scrubbed by bin/transcript-scrub.sh.
#       FAIL-CLOSED on the scrub: no scrubber, or a scrub that fails, writes no
#       file (an unscrubbed transcript in a build record the hub relays is the
#       one outcome worse than none).
#   ee_reason <outfile>       the model's final message, one line, first 200
#       chars, scrubbed. The final message is the envelope's `.result`
#       ($OUT.json) when there is one, else the last 10 non-empty lines of the
#       stage output. Prints nothing when there is none.
#   ee_stop_check <project> <key> <ticket>  the pool's spawn gate. rc 0 = the
#       key may launch; rc 1 = refused. Counts the hub build records
#       builds/pool-<project>-<key>-*/RESULT whose first line is EXECUTE_EMPTY
#       and whose RESULT is younger than POOL_EXECUTE_EMPTY_WINDOW_S (86400).
#       At POOL_EXECUTE_EMPTY_MAX (2) or more it refuses, and ONCE per episode
#       (<newest build dir>/needs-human.posted) asks a person on the ticket with
#       the last stop reason (_ee_post_human): a NEEDS_HUMAN hold through
#       bin/needs-human-hold.sh on a GitHub-Issues board, a comment through the
#       tracker contract's board adapter on an in-app board. The same body is
#       written to the newest record as needs-human.md. A hold
#       that could not be placed is one alert line and is retried next tick;
#       the key is refused either way. Both knobs are fly-pool lane knobs
#       (catalog/lanes.d/fly-pool.json), so a settings row sets them; MAX=0 is
#       off. The refusal ends when the window rolls past the older result.
# The root is ${HARNESS:-${H:-}}; with none, every function is a no-op.

_ee_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_ee_now() { if [ -n "${EE_NOW:-}" ]; then printf '%s' "$EE_NOW"; else date -u +%s; fi; }
_ee_int() { # _ee_int <value> <default> -> a non-negative integer, else the default
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac
}
_ee_scrub() { # stdin -> stdout through bin/transcript-scrub.sh; rc 1 when it cannot run
  local r; r=$(_ee_root)
  [ -n "$r" ] && [ -r "$r/bin/transcript-scrub.sh" ] || return 1
  bash "$r/bin/transcript-scrub.sh"
}

ee_reason() { # ee_reason <outfile>
  local f="${1:-}" line raw=""
  [ -s "$f.json" ] && raw=$(jq -r '.result // empty | strings' "$f.json" 2>/dev/null)
  [ -n "$raw" ] || { [ -s "$f" ] && raw=$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -n 10); }
  [ -n "$raw" ] || return 0
  line=$(printf '%s' "$raw" | tr '\r\n\t' '   ' | sed -E 's/  +/ /g; s/^ //; s/ $//' | _ee_scrub 2>/dev/null) || return 0
  [ -n "$line" ] || return 0
  printf '%s' "${line:0:200}"
}

ee_transcript() { # ee_transcript <outfile> <dest> [stop-reason]
  local out="${1:-}" dest="${2:-}" why="${3:-}" r sid jsonl src="" tmp n
  r=$(_ee_root); [ -n "$r" ] && [ -n "$dest" ] || return 0
  n=$(_ee_int "${EE_TRANSCRIPT_LINES:-}" 200)
  tmp=$(mktemp "${TMPDIR:-/tmp}/ee-transcript.XXXXXX") || return 0
  if [ -s "$out.json" ]; then
    sid=$(jq -r '.session_id // empty' "$out.json" 2>/dev/null)
    case "$sid" in ''|*[!A-Za-z0-9._-]*) sid="" ;; esac
    if [ -n "$sid" ]; then
      jsonl=$(find "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}" -maxdepth 2 -name "$sid.jsonl" -print -quit 2>/dev/null)
      [ -n "$jsonl" ] && [ -s "$jsonl" ] && bash "$r/bin/transcript-render.sh" "$jsonl" > "$tmp" 2>/dev/null && [ -s "$tmp" ] \
        && src=session_jsonl
    fi
  fi
  if [ -z "$src" ] && [ -s "$out" ]; then cp "$out" "$tmp" 2>/dev/null && src=stage_output; fi
  if [ -z "$src" ]; then rm -f "$tmp"; return 0; fi
  {
    echo "# execute transcript (EXECUTE_EMPTY)"
    echo "source: $src${sid:+   session: $sid}   last $n lines, scrubbed (bin/transcript-scrub.sh)"
    [ "$src" = stage_output ] && echo "NOTE: no claude session file was found for this attempt, so this is the stage's final OUTPUT, not the turn-by-turn session."
    [ -n "$why" ] && echo "stop reason: $why"
    echo
    tail -n "$n" "$tmp"
  } | _ee_scrub > "$dest.tmp.$$" 2>/dev/null
  if [ "${PIPESTATUS[1]:-1}" = 0 ] && [ -s "$dest.tmp.$$" ]; then mv -f "$dest.tmp.$$" "$dest"
  else rm -f "$dest.tmp.$$"; fi
  rm -f "$tmp"
  return 0
}

ee_on_empty() { # ee_on_empty <build-dir>
  local b="${1:-}" why
  [ -n "$b" ] && [ -d "$b" ] || return 0
  why=$(ee_reason "$b/execute-run.txt") || why=""
  [ -n "$why" ] && printf '%s\n' "$why" > "$b/stop-reason.txt" 2>/dev/null
  ee_transcript "$b/execute-run.txt" "$b/execute-transcript.md" "$why" || true
  return 0
}

# _ee_board_comment <project> <ticket-id> <bodyfile> — the NEEDS_HUMAN body as a
# comment on an IN-APP board ticket, through the tracker contract's board
# adapter (bin/lib/tracker.sh, trk_board_comment). The context is resolved the
# way every board caller resolves it (bin/deploy-rollback-board.sh's
# tracker_context): <app base><board prefix> from env/<project>.env and
# fleet.conf, and the project's internal token. The board adapter has no label
# verb (trk_board_label_add answers 3), so on a board the comment IS the ask
# and this gate's count of EXECUTE_EMPTY records keeps the key from relaunching.
# rc 0 posted; anything else not posted.
# _ee_board_ctx <project> — sets TRK_BOARD_BASE / TRK_BOARD_TOKEN /
# TRK_BOARD_TOKEN_VAR / TRK_LOG / TRK_ERR in the CALLER's scope (the caller
# declares them local) and loads the board adapter. rc 0 ready, 1 not.
_ee_board_ctx() {
  local p="$1" r envf prefix bvar base=""
  r=$(_ee_root)
  command -v harness_env_dir >/dev/null 2>&1 || . "$r/bin/lib/env-path.sh" 2>/dev/null \
    || harness_env_dir() { printf '%s\n' "${1:-$r}/env"; }
  command -v board_base_var >/dev/null 2>&1 || . "$r/bin/lib/board-creds.sh" 2>/dev/null || true
  command -v internal_token_var >/dev/null 2>&1 || . "$r/bin/lib/internal-token.sh" 2>/dev/null || true
  envf="$(harness_env_dir "$r")/$p.env"
  prefix=$("$r/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || prefix=""
  if [ -n "$prefix" ] && [ "$prefix" != "-" ] && command -v board_base_var >/dev/null 2>&1 \
     && bvar=$(board_base_var "$p" "$envf" execute-empty 2>/dev/null); then
    base=$(board_env_value "$bvar" "$envf" 2>/dev/null)
    while [ "${base%/}" != "$base" ]; do base="${base%/}"; done
  fi
  [ -n "$base" ] || return 1
  TRK_BOARD_BASE="$base$prefix"
  TRK_BOARD_TOKEN_VAR=$(internal_token_var "$envf" 2>/dev/null) || TRK_BOARD_TOKEN_VAR=""
  TRK_BOARD_TOKEN=$("$r/bin/internal-token-for.sh" "$p" 2>/dev/null) || TRK_BOARD_TOKEN=""
  [ -n "$TRK_BOARD_TOKEN" ] || return 1
  TRK_LOG="$r/logs/execute-empty.log"; TRK_ERR="$TRK_LOG"
  tracker_load board 2>/dev/null
}
_ee_board_comment() {
  local p="$1" id="$2" f="$3"
  local TRK_BOARD_BASE="" TRK_BOARD_TOKEN="" TRK_BOARD_TOKEN_VAR="" TRK_LOG="" TRK_ERR="" TRK_DRY=0 TRK_REQ_FILE=""
  _ee_board_ctx "$p" || return 1
  tracker_comment "$id" "$f" >/dev/null 2>&1
}

# _ee_post_human <project> <ticket> <fp> <body> <bodyfile> — the one NEEDS_HUMAN
# ask, on whatever tracker the project uses. rc 0 posted.
#   github-issues: bin/needs-human-hold.sh (the `hold` label + the marker
#     comment, which the pool's HOLD gate then reads too).
#   board (in-app): a comment through the board adapter (_ee_board_comment).
#   anything else, or no answer: not posted (rc 1), so the caller alerts.
_ee_post_human() {
  local p="$1" ticket="$2" fp="$3" body="$4" f="$5" r adapter
  r=$(_ee_root)
  command -v tracker_adapter >/dev/null 2>&1 || . "$r/bin/lib/tracker.sh" 2>/dev/null || return 1
  adapter=$(tracker_adapter "$p" 2>/dev/null) || return 1
  case "$adapter" in
    github-issues)
      case "$ticket" in ''|*[!0-9]*) return 1 ;; esac
      [ -x "$r/bin/needs-human-hold.sh" ] || return 1
      "$r/bin/needs-human-hold.sh" "$p" "$ticket" "$fp" "$body" execute-empty >/dev/null 2>&1 ;;
    board)
      [[ "$ticket" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
      _ee_board_comment "$p" "$ticket" "$f" ;;
    *) return 1 ;;
  esac
}

# _ee_defang — stdin -> stdout. The model's stop reason rides in the ask, and the
# ask must never read as an instruction to bin/lib/hold.sh by itself (lead
# review of #5939): every word of its vocabulary (HOLD_WORD_RE, HOLD_LIFT_RE and
# HOLD_LIFT_LEAD_RE, ABANDON / CLOSE-PR, the NEEDS-HUMAN / HUMAN-STEP-DONE /
# Taken by / [human-fix] markers) gets an underscore after its first letter.
_ee_defang() {
  sed -E 's/(r)(esume)/\1_\2/Ig; s/(h)(old)/\1_\2/Ig; s/(a)(bandon)/\1_\2/Ig; s/(c)(lose-pr)/\1_\2/Ig;
          s/(p)(roceed)/\1_\2/Ig; s/(n)(eeds-human)/\1_\2/Ig; s/(h)(uman-step-done)/\1_\2/Ig;
          s/(t)(aken by)/\1_\2/Ig; s/(h)(uman-fix)/\1_\2/Ig'
}

# _ee_lift_epoch <project> <ticket> <asked-epoch> — prints the epoch at which a
# person lifted this episode's NEEDS_HUMAN ask, or nothing. The ticket thread is
# read the way bin/lib/hold.sh reads it (hold_check / hold_classify: the newest
# decisive PERSON comment wins). A lift is the clear verdicts:
#   lifted-by-comment <at>     RESUME / UNHOLD / "hold lifted" (HOLD_LIFT_RE)
#   lifted-by-human-step <at>  a HUMAN-STEP-DONE: line over the marker
#   no-hold                    GitHub only: the NEEDS-HUMAN marker is gone (the
#                              hold was removed); the lift is "now"
# and the lift must be NEWER than the ask. The placer's own comment can never
# lift: on GitHub it is the App's (a bot), which hold_classify hears only as the
# tagged NEEDS-HUMAN marker; on a board it carries <!-- ee-ask:<fp> --> and is
# dropped before the classifier runs. An unreadable thread is no lift.
_ee_lift_epoch() {
  local p="$1" ticket="$2" asked="$3" r adapter slug v at ep tj ij cj fp
  r=$(_ee_root)
  command -v tracker_adapter >/dev/null 2>&1 || . "$r/bin/lib/tracker.sh" 2>/dev/null || return 0
  adapter=$(tracker_adapter "$p" 2>/dev/null) || return 0
  case "$adapter" in
    github-issues)
      case "$ticket" in ''|*[!0-9]*) return 0 ;; esac
      command -v hold_check >/dev/null 2>&1 || . "$r/bin/lib/hold.sh" 2>/dev/null || return 0
      slug=$("$r/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || return 0
      v=$(hold_check "$slug" "$ticket" 2>/dev/null) || { [ $? = 0 ] || return 0; } ;;
    board)
      [[ "$ticket" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 0
      command -v hold_classify >/dev/null 2>&1 || . "$r/bin/lib/hold.sh" 2>/dev/null || return 0
      local TRK_BOARD_BASE="" TRK_BOARD_TOKEN="" TRK_BOARD_TOKEN_VAR="" TRK_LOG="" TRK_ERR="" TRK_DRY=0 TRK_REQ_FILE=""
      _ee_board_ctx "$p" || return 0
      tj=$(tracker_read "$ticket" 2>/dev/null) || return 0
      # The board ticket in hold_classify's REST shape. A board has no labels,
      # so the ticket reads as open and labelled; the placer's own ask is dropped.
      ij=$(printf '%s' "$tj" | jq -c '{state:"open", labels:[{name:"ai-build"}], title:(.title // ""), body:(.body // "")}' 2>/dev/null) || return 0
      cj=$(printf '%s' "$tj" | jq -c '[.comments[]? | select((.body // "") | test("<!--[ \t]*ee-ask:") | not)
            | {body:(.body // ""), created_at:(.createdAt // ""), user:{type:"User"}}]' 2>/dev/null) || return 0
      v=$(hold_classify "$ij" "$cj" 2>/dev/null) || { [ $? = 0 ] || return 0; } ;;
    *) return 0 ;;
  esac
  case "$v" in
    "clear	lifted-by-comment "*|"clear	lifted-by-human-step "*)
      at="${v##* }"
      # An empty or non-ISO stamp is no lift (GNU date -d "" would answer today 00:00Z).
      [ -n "$at" ] || return 0
      [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || return 0
      ep=$(date -u -d "$at" +%s 2>/dev/null) || return 0 ;;
    "clear	no-hold")
      [ "$adapter" = github-issues ] || return 0
      ep=$(_ee_now) ;;
    *) return 0 ;;
  esac
  [ "$ep" -gt "$asked" ] 2>/dev/null || return 0
  printf '%s' "$ep"
}

ee_stop_check() { # ee_stop_check <project> <key> <ticket>
  local p="${1:-}" key="${2:-}" ticket="${3:-}" r max win now n=0 d f mt newest="" nt=0 reason marker body fp hrc
  r=$(_ee_root); [ -n "$r" ] && [ -n "$p" ] && [ -n "$key" ] || return 0
  max=$(_ee_int "${POOL_EXECUTE_EMPTY_MAX:-}" 2)
  [ "$max" -gt 0 ] || return 0
  win=$(_ee_int "${POOL_EXECUTE_EMPTY_WINDOW_S:-}" 86400)
  now=$(_ee_now)
  # A LIFT RESETS THE COUNT (lead review of #5939): the newest
  # needs-human.lifted among the key's records is an epoch, and only results
  # NEWER than it count. A person's RESUME after the fix is what lets the key
  # launch again, not only the window.
  local lifted=0 lf le
  for lf in "$r/builds/pool-$p-$key-"*/needs-human.lifted; do
    [ -f "$lf" ] || continue
    le=$(head -1 "$lf" 2>/dev/null); case "$le" in ''|*[!0-9]*) continue ;; esac
    [ "$le" -gt "$lifted" ] && lifted=$le
  done
  for d in "$r/builds/pool-$p-$key-"*; do
    f="$d/RESULT"; [ -f "$f" ] || continue
    case "$(head -1 "$f" 2>/dev/null)" in EXECUTE_EMPTY*) ;; *) continue ;; esac
    mt=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ $((now - mt)) -le "$win" ] || continue
    [ "$mt" -gt "$lifted" ] || continue
    n=$((n + 1))
    [ "$mt" -ge "$nt" ] && { nt=$mt; newest=$d; }
  done
  [ "$n" -ge "$max" ] || return 0
  # The episode's record is the NEWEST EXECUTE_EMPTY build dir itself, not a
  # state/ file: state/pool is the pool_state rows' path (catalog/state-paths.json,
  # BH-5001), and a file beside a row is a second spelling that drifts.
  marker="$newest/needs-human.posted"
  declare -F say >/dev/null 2>&1 && say "skipping $key: EXECUTE_EMPTY $n time(s) in ${win}s (cap $max) — not relaunched; a person must look (NEEDS_HUMAN)"
  if [ -e "$marker" ]; then
    # Asked already: has a person answered since? (_ee_lift_epoch)
    local asked lep
    asked=$(head -1 "$marker" 2>/dev/null); case "$asked" in ''|*[!0-9]*) asked=$(stat -c %Y "$marker" 2>/dev/null || echo 0) ;; esac
    lep=$(_ee_lift_epoch "$p" "$ticket" "$asked")
    [ -n "$lep" ] || return 1
    printf '%s\n' "$lep" > "$newest/needs-human.lifted" 2>/dev/null
    declare -F say >/dev/null 2>&1 && say "$key: the NEEDS_HUMAN ask on ticket ${ticket:-?} was answered — the EXECUTE_EMPTY count is reset and the key may launch"
    return 0
  fi
  reason=$(head -c 300 "$newest/stop-reason.txt" 2>/dev/null | head -1 | _ee_defang)
  [ -n "$reason" ] || reason="(no stop-reason.txt in the record; see the transcript)"
  # NO LIFT VOCABULARY IN THE ASK (lead review of #5939): the body never says
  # the words bin/lib/hold.sh acts on, so the placer's own comment can never
  # read as a lift or a hold.
  body="NEEDS_HUMAN: the execute stage of $key committed nothing $n times in the last $((win / 3600)) h, so the pool stops relaunching it. Last stop reason: $reason. Evidence: ${newest##*/}/execute-transcript.md in the hub's builds/ dir. Fix the cause (a missing branch, a plan that cannot be built). After the fix, comment the word resume in capital letters on this ticket, and the pool launches the key again."
  printf '%s\n\n<!-- ee-ask:%s -->\n' "$body" "$(printf '%s' "execute-empty:$p:$key" | sha1sum 2>/dev/null | cut -c1-12)" > "$newest/needs-human.md" 2>/dev/null
  fp=$(printf '%s' "execute-empty:$p:$key" | sha1sum 2>/dev/null | cut -c1-12)
  hrc=0; _ee_post_human "$p" "$ticket" "$fp" "$body" "$newest/needs-human.md" || hrc=$?
  if [ "$hrc" = 0 ]; then
    printf '%s\n' "$now" > "$marker"; rm -f "$marker.alerted" 2>/dev/null
  elif [ ! -e "$marker.alerted" ]; then
    # One alert per episode; the hold itself is retried every tick.
    [ -x "$r/bin/alert-line.sh" ] && HARNESS="$r" "$r/bin/alert-line.sh" \
      "[pool/$p] $key: NEEDS_HUMAN — EXECUTE_EMPTY $n times in ${win}s; the hold on ticket ${ticket:-?} could not be placed (rc $hrc), the key is still not relaunched. $body" >/dev/null 2>&1
    : > "$marker.alerted"
  fi
  return 1
}
