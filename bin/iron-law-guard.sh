#!/bin/bash
# alert-writer: by-design — a PreToolUse hook whose exit status is the verdict: its LOUD path must write with PATH broken (alert-line drops the line without tr), and a network beat before exit 2 risks a hook timeout the CLI reads as allow.
# bin/iron-law-guard.sh — the act-time iron-law guard (SDLC item 1, 2026-08-29).
#
# A PreToolUse hook on Bash for harness build/triage sessions. It mechanically
# DENIES the six irreversible families the machine-wide rules already forbid in
# prose — merging a PR, pushing (main, and since BH-2741 any branch), pointing
# prisma at a live DB, writing a prod DB with a raw client, deploying/promoting
# on Vercel, and pointing a destructive filesystem verb at the harness's own
# state — at the moment the agent tries them, instead of finding them in a
# review or a post-mortem.
#
# FAMILY 2 HAS TWO RULES. `push-main` is judged first and keeps its name.
# `agent-push` (BH-2741) is every other `git push` from a guarded lane: the
# harness pushes the branch after the session, through bin/lib/hold-push.sh,
# which re-reads the ticket's HOLD at the push; an agent pushing its own branch
# walked past that read. After the deny is decided, the guard does ONE bounded
# hold read (hold_push_verdict, `timeout 6`) so its one findings line ends in
# ` :: hold=held|clear|unreadable|unchecked …`. The read can change that wording
# and nothing else.
#
# WHY AT ACT TIME. Every one of these is already written down (CLAUDE.md iron
# guardrails 1 and 2, the remediator's --disallowedTools list, three prompt
# files). Prose stops an agent that reads carefully; it does not stop one that
# is nine hours into a build and reaching for the obvious next command. The
# review lens catches it AFTER the merge already happened, which is exactly the
# case where catching it is worth nothing.
#
# HOOK CONTRACT (Claude Code PreToolUse):
#   exit 0  — allow. Nothing is printed on an allowed command.
#   exit 2  — BLOCK, and stderr is fed back into the model's context as the
#             reason. That is the same contract bin/edit-feedback-hook.sh uses
#             for its PostToolUse feedback.
#   any other nonzero — a non-blocking hook error; the tool call proceeds. This
#             script must therefore never end on one, and since #409 it cannot:
#             every exit is routed to a verdict.
# FOUR VERDICTS, and a crash is one of them (#409):
#   allow        exit 0, silent.
#   deny         exit 2 + the reason on stderr + a findings.log row.
#   LOUD/INERT   exit 0 + one ALERTS line. A SELF-DIAGNOSED degrade — no jq on
#                PATH, an empty or non-JSON payload, a child killed by its own
#                bound — denies nothing. That is a stated trade: a misconfigured
#                box is visible in ALERTS.log within one tick, whereas failing
#                closed on it takes the whole fleet's build lanes down.
#   CRASH-BLOCK  exit 2 + the same refusal shape + one ALERTS line. A guard that
#                ends WITHOUT deciding — a signal, a `set -u` abort, a syntax
#                error from a later edit, any exit before a verdict — refuses.
# The difference between the last two is who noticed. A guard that knows what is
# wrong with it can say so and step aside; a guard that was killed mid-thought
# knows nothing about the command it was judging, and every family it exists to
# stop is irreversible. It fails closed.
#
# THE ONE REMAINING FAIL-OPEN is the CLI's own hook budget: bin/agent-call.sh
# wires this hook with `timeout:30`, and a hook the CLI has ABANDONED is ignored
# whatever it prints, so no exit code can answer it. The defence is staying under
# it, which is why every child spawned below carries a `timeout 5` (read 3s +
# jq 5s + awk 5s + git 5s is ~18s worst case; an agent-push deny adds its 6s
# hold read, ~24s). SIGKILL is the same shape and is untrappable by construction.
#
# WHO SENDS THE SIGTERM, the two senders that actually reach this hook:
#   1. The STAGE WINDOW. Every runner in bin/agent-call.sh runs under
#      `timeout --kill-after=120 "$TO"`. GNU timeout puts itself and its child in
#      their own process group and signals the WHOLE group on expiry, so a hook
#      in flight when a stage deadline lands is killed alongside `claude`. The
#      session is dying either way, but the verdict must still be a block and the
#      ALERTS line must stop claiming an unguarded call ran.
#   2. The CLI's PreToolUse hook budget above — abandonment, not a signal this
#      script can answer. See the bound.
#
# LANE FENCE, IN TWO TIERS. A session with NO HARNESS_LANE marker is not a
# harness session and this hook has no opinion on it at all.
#   Families 1-5 are about AUTHORITY this box's build stages do not have, so they
#   stay fenced to the guarded stages: HARNESS_LANE must name one of
#   plan/execute/review/fix/qa/triage (bin/agent-call.sh exports the marker and
#   wires this hook in for exactly those). Marked lanes that legitimately keep
#   merge/deploy authority — the orchestrator conversation, box-chat, greenfield
#   — are not judged by them, and neither are the merge-lane scripts
#   (merge-sweep.sh, merge-queue.sh, poll-commands.sh, run-build.sh's own gated
#   tier-1 step), which are plain bash with no hook at all.
#   Family 6 fires on EVERY marked lane, those three included: nobody on this box
#   has authority to delete the harness's env/state/logs/builds/flags/locks, the
#   repo checkouts or the key material, and an `rm -rf` typed in a chat lane
#   destroys exactly as much as one typed in a build lane.
#   Family 7 (BH-8103) fires only on the review lane on a LIVE harness box (the
#   deploy checkout exists, or HARNESS_LIVE=1): a review there is static, so it
#   moves no shared checkout and runs no suite. See the family 7 section below.
# The fence is checked here as well as at the wiring point on purpose: a settings
# file that leaks into another session must still be inert.
#
# NOT A SANDBOX — THIS IS A TRIPWIRE. It reads the command string the agent asked
# to run, so a determined session can still reach every one of these verbs
# through a path this matcher does not model. The WALL for the filesystem family
# is filesystem-level immutability (`chattr +i`, ticket #388); family 6 here is
# the tripwire that catches the reach-for-the-obvious-command failure, which is
# the one that actually happens, and files it where somebody reads it in a tick.
#
# HONEST LIMITS of family 6 — all of these get through, by construction:
#   - `xargs rm`, or any rm fed its targets on stdin or from a file
#   - `$(...)` and backtick targets: a computed path is unresolvable, so allowed
#   - `..` walks, if coreutils `realpath` is missing from the box (it is used for
#     lexical normalization and there is no hand-rolled fallback)
#   - a NAME assigned anywhere in the same command line, before the verb or after
#     it (`rm -rf "$X/env"; X=1`): the assignment makes the name unresolvable
#     rather than empty, which is an allow
#   - variables the agent exported INSIDE its own shell mid-session: this hook is
#     a separate process and only sees the environment it was launched with, so
#     such a variable reads as unset — and an unset variable in a target is
#     refused as its own rule, with the literal-path hint in the message
#   - `dd of=/root/harness/env/x`, `cp /dev/null <file>`, `mv` over a file
#   - python/node doing os.remove / fs.rmSync, or any script the session writes
#   - shell aliases and functions defined in the session
set -uo pipefail

HARNESS="${HARNESS:-/root/harness}"
LANE="${HARNESS_LANE:-}"
# Same default list as agent-call.sh's wiring. Override in env only for tests.
GUARDED_LANES="${IRON_LAW_LANES:-plan execute review fix qa triage}"
# date, with a builtin fallback: the degraded paths below have to be able to
# stamp their ALERTS line even when PATH itself is what is broken.
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || TZ=UTC printf '%(%Y-%m-%d %H:%M:%SZ)T\n' -1; }

# Every path out of this script is one of four DECISIONS: allow (0), block (2),
# degrade-loudly (LOUD -> an ALERTS line, then 0), or CRASH-BLOCK (2). The
# fourth is the one #409 added. Anything that ends this script without a verdict
# — an unbound variable under `set -u`, a syntax error introduced by a later
# edit, a signal — used to exit with the shell's own status, and the CLI reads
# any status other than 2 as a non-blocking hook error and runs the command
# anyway. A guard that stops guarding at the exact moment it is killed is not a
# guard, so an undecided exit is now a REFUSAL, announced once in ALERTS.
#
# This is not hypothetical: the first live run of this guard against the real
# CLI read stdin as `< /dev/stdin`, which the hook environment cannot open ("No
# such device or address"), and the script died on the unbound $IN before a
# single line of ALERTS. It looked exactly like a working guard. #409 is the
# recurrence: a stage window expiring mid-build SIGTERMs the hook (the 09-07 and
# 09-10 execute lanes), and the guard filed "that Bash call ran UNGUARDED" with
# rc=0 — because on an untrapped fatal signal bash runs the EXIT trap with $? of
# the last COMPLETED command, and then dies with the signal's own status.
DECIDED=0

CRASH_BLOCK() { # crashed guard: block, say where, exactly once
  local why="${1:-unknown}"
  [ "$DECIDED" = 1 ] && return 0          # a verdict already stands; a late signal changes nothing
  DECIDED=1
  # An UNMARKED session gets no opinion from the crash path either — same fence
  # as the normal path, so a leaked settings file stays inert.
  [ -n "$LANE" ] || exit 0
  mkdir -p "$HARNESS/logs" 2>/dev/null
  # $why is a signal name or an rc, NEVER the command string: a crash must not
  # become a new path for a connection string into ALERTS.log (iron law 3).
  echo "$(STAMP) [${HARNESS_LANE_PROJECT:-unknown}] [iron-law] guard crashed: $why — lane $LANE, that Bash call was BLOCKED (fail closed). Fix $HARNESS/bin/iron-law-guard.sh." \
    >> "$HARNESS/logs/ALERTS.log" 2>/dev/null
  printf '{"decision":"block","reason":"guard crashed: %s"}\n' "$why"
  printf 'BLOCKED by the harness act-time iron-law guard: the guard crashed (%s) before reaching a verdict in lane %s. It fails closed, so this call did not run. Retry it once; if it blocks again, stop and say so in your output.\n' "$why" "$LANE" >&2
  exit 2
}

# The rc is passed IN, not read off $? inside the function: by the time the
# trap body has called into a function, $? is the status of the trap's own
# first command, so `local rc=$?` logged rc=0 for every crash — an audit line
# that says the guard exited cleanly is exactly as useless as no audit line.
_exit_audit() {
  local rc="${1:-0}"
  [ "$DECIDED" = 1 ] && return 0
  CRASH_BLOCK "exited rc=$rc before a verdict"
}
# CRASH_BLOCK is defined ABOVE the traps on purpose: bash reads this file top
# down, and a signal landing between the trap and the definition would call a
# name that does not exist yet. `exit 2` inside a trap sets the script's status,
# which is what turns a 143 into a refusal the CLI honours.
trap '_exit_audit $?' EXIT
trap 'CRASH_BLOCK SIGTERM' TERM
trap 'CRASH_BLOCK SIGINT' INT
trap 'CRASH_BLOCK SIGHUP' HUP
# SIGKILL is absent because it is untrappable: it is the second stage of the
# stage window's `timeout --kill-after=120`, 120s after the SIGTERM above.

ALLOW() { DECIDED=1; exit 0; }

LOUD() { # broken guard: deny nothing, but say so where somebody reads it
  DECIDED=1
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(STAMP) [${HARNESS_LANE_PROJECT:-unknown}] act-time iron-law guard INERT in lane $LANE: $1 — Bash calls in this session are running UNGUARDED (merge/push/deploy/prod-write are prompt-only here). Fix $HARNESS/bin/iron-law-guard.sh." \
    >> "$HARNESS/logs/ALERTS.log" 2>/dev/null
  exit 0
}

# read, not cat: a builtin cannot itself be the missing dependency, so a broken
# PATH is reported as the missing jq below rather than as unreadable stdin. NO
# `< /dev/stdin` REDIRECT — the CLI hands a hook a pipe that cannot be reopened
# through /dev/stdin, and that redirect is what silently disarmed the first live
# run of this guard. Initialized first so a failed read degrades loudly instead
# of tripping `set -u`.
# BOUNDED. The CLI hands the hook a pipe it does not always close: a payload
# with no NUL terminator leaves this read blocked until the PreToolUse budget
# abandons the whole hook — the one case no exit code can answer, so the defence
# is never reaching it. TMOUT bounds the read builtin (it is only honoured by
# `read` in a non-interactive shell) so the guard reaches a verdict — or degrades
# loudly — on its own schedule instead of the caller's.
IN=""
TMOUT=3
IFS= read -r -d "" IN || true
unset TMOUT
# Drained BEFORE the lane fence so an unguarded session never leaves the caller
# writing into a closed pipe (SIGPIPE).

# Not a harness build/triage session -> this hook has no opinion at all.
[ -n "$LANE" ] || ALLOW
# FULL=1 -> the lane is one of the guarded build stages, so families 1-5 are
# judged too. FULL=0 -> a marked lane that keeps its merge/deploy authority, and
# only family 6 applies there.
FULL=0
case " $GUARDED_LANES " in *" $LANE "*) FULL=1 ;; esac
# LIVE_REVIEW=1 -> the review lane on a live harness box, and family 7 is
# judged too (BH-8103). A box is live when it carries the deploy checkout
# (the hub and every Orgo box do; Fly pool machines and CI runners do not).
# HARNESS_LIVE=1/0 is the operator's override; any other value falls back to
# the checkout test.
ILG_CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
case "${HARNESS_LIVE:-}" in
  1) LIVE=1 ;;
  0) LIVE=0 ;;
  *) LIVE=0; [ -e "$ILG_CHECKOUT/.git" ] && LIVE=1 ;;
esac
LIVE_REVIEW=0
[ "$LANE" = review ] && [ "$LIVE" = 1 ] && LIVE_REVIEW=1

[ -n "$IN" ] && [ "${IN#\{}" != "$IN" ] || LOUD "the hook payload was empty, unreadable on stdin, or not JSON"
command -v jq >/dev/null 2>&1 || LOUD "jq is not on PATH, so the hook payload cannot be parsed"

# ONE jq spawn, not three: this runs before EVERY Bash call in every build and
# triage session on the fleet, so its own cost is part of the design. The
# command is flattened to one line here because the fields are read back by line.
# BOUNDED, like every other child this script spawns. The CLI abandons a hook at
# 30s (agent-call.sh's `timeout:30`) and ignores whatever it prints afterwards,
# so that is the one deadline the guard cannot fail closed against. Staying under
# it is the whole defence: read 3s + jq 5s + awk 5s + git 5s is ~18s worst case.
# A child killed by its bound yields no output, which lands on LOUD below.
mapfile -t J < <(timeout 5 jq -r '(.tool_name // ""), ((.tool_input.command // "") | gsub("[\n\r\t]"; " ")), (.cwd // "")' <<<"$IN" 2>/dev/null)
[ "${#J[@]}" -ge 2 ] || LOUD "jq could not read tool_name/tool_input out of the hook payload"
TOOL="${J[0]:-}"; CMD="${J[1]:-}"; CWD="${J[2]:-}"
[ "$TOOL" = "Bash" ] || ALLOW
[ -n "$CMD" ] || ALLOW

# HEREDOC BODIES ARE DATA. `cat > file <<'EOF' ... EOF` writes a file; the text
# between the launcher and the closing delimiter is content, not commands. A
# large one (a migration, a prompt file, a doc) that happens to CONTAIN one of
# the guarded verbs missed the fast path and spent ten seconds in the classifier
# below — long enough to approach the CLI's hook budget, which is the one
# deadline this script cannot fail closed against. Only
# QUOTED delimiters (<<'EOF' / <<"EOF") are stripped: those are the ones the
# shell never expands, so nothing in the body can become a command. The launcher
# before `<<` is kept (a `psql prod <<'SQL'` is still judged), the body is
# dropped, and what follows the closing delimiter is kept behind a `;` — the
# newlines are already flattened to spaces by then, so without that separator
# the next real command would be read as arguments to the launcher.
_strip_quoted_heredocs() { # <command-string> -> same string, bodies removed
  # awk, not bash string ops: `${s#*" $delim "}` is quadratic in bash (3.4s on an
  # 80KB body, worse the bigger the file being written), which is the same
  # timeout this is here to prevent. One awk pass is linear and costs ~15ms on
  # 400KB. It is spawned ONLY for a command that contains `<<`.
  printf '%s' "$1" | timeout 5 awk -v q="'" '
    {
      re = "<<-?[ \t]*(\"[A-Za-z_][A-Za-z0-9_-]*\"|" q "[A-Za-z_][A-Za-z0-9_-]*" q ")"
      line = $0; out = ""
      while (match(line, re)) {
        d = substr(line, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", d); gsub(/"/, "", d); gsub(q, "", d)
        out = out substr(line, 1, RSTART - 1) " ; "
        line = substr(line, RSTART + RLENGTH) " "
        i = index(line, " " d " ")
        line = (i > 0) ? substr(line, i + length(d) + 2) : ""
      }
      printf "%s", out line
    }'
}
# Left alone if awk is missing or the pass produces nothing: classifying the
# whole payload is slow, but it is the fail-CLOSED direction.
case "$CMD" in
  *"<<"*)
    if command -v awk >/dev/null 2>&1; then
      _STRIPPED=$(_strip_quoted_heredocs "$CMD")
      [ -n "$_STRIPPED" ] && CMD="$_STRIPPED"
    fi ;;
esac

# FAST PATH. A command that names none of the guarded binaries and none of the
# destructive filesystem verbs cannot be one of the six families, and that is the
# overwhelming majority of what a build runs (npm, ls, cat, sed, the repo's own
# test scripts). Everything below this line only ever runs for the handful that
# could matter. `rm` is matched as a WORD (`rm ` or at end) so `npm run format`
# stays on the fast path; `>` is here because pure truncation is family 6, and
# the classifier is what decides an ordinary `cmd > file` write is not.
# Family 7 adds the suite words, on the review lane on a live box only
# (`git` and `gh` are already on the slow path).
_SUITE_WORD=0
if [ "$LIVE_REVIEW" = 1 ]; then
  case "$CMD" in *tests/*|*test-impact-gate*|*fast-lints*) _SUITE_WORD=1 ;; esac
fi
if [ "$_SUITE_WORD" = 0 ]; then
  case "$CMD" in
    *gh*|*git*|*prisma*|*psql*|*mysql*|*mariadb*|*mongo*|*vercel*|*vc\ *|*merge-*) ;;
    *rm\ *|*rm|*find\ *|*truncate*|*shred*|*rsync*|*">"*) ;;
    *) ALLOW ;;
  esac
fi
# On a lane where only family 6 applies, a command naming a families-1-5 binary
# but no filesystem verb has nothing left to judge. `git` still goes through,
# because `git clean` and `git worktree remove` are family 6.
if [ "$FULL" = 0 ] && [ "$LIVE_REVIEW" = 0 ]; then
  case "$CMD" in
    *rm\ *|*rm|*find\ *|*truncate*|*shred*|*rsync*|*">"*|*git*) ;;
    *) ALLOW ;;
  esac
fi

# --- normalization ----------------------------------------------------------
# One line, single-spaced. rtk is stripped because the fleet-wide rtk PreToolUse
# hook rewrites `git push` into `rtk git push`; hook order is not guaranteed, so
# this must match the command in either shape.
NORM=$(printf '%s' "$CMD" | tr '\n\t\r' '   ' | tr -s ' ')
NORM=$(printf '%s' "$NORM" | sed -E 's/(^|[;&|(] *)rtk +(proxy +)?/\1/g')

# Segments: a command line is many commands. Split on the shell's separators
# AND on command-substitution boundaries so `x && gh pr merge 1` and
# `$(gh pr merge 1)` are both seen as a segment whose FIRST word is `gh`.
# First-word matching is what keeps `git commit -m "no gh pr merge here"` out of
# the deny path: the verb has to be in command position, not inside an argument.
SPLIT=$(printf '%s' "$NORM" | sed -E 's/\$\(/\n/g; s/`/\n/g; s/\|\|/\n/g; s/&&/\n/g; s/[;|)]/\n/g')

RULE=""; WHY=""; PUSH_BR=""

# Peel the wrappers that sit in front of the real command word, then report
# that word (basename'd), the rest of the segment, and the word as written
# (before basename; family 7 reads it), one per line.
cmd_word() {
  local -a toks=(); local i=0 n t w
  read -r -a toks <<<"$1"
  n=${#toks[@]}
  while [ "$i" -lt "$n" ]; do
    t="${toks[i]}"
    case "$t" in
      *=*|sudo|nohup|command|time|nice|setsid|exec|builtin|env|bunx)
        i=$((i+1)) ;;
      timeout|flock)
        i=$((i+1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[i]}" in
            -w|-E|--timeout|--wait|--conflict-exit-code|--kill-after|--signal|-s|-k) i=$((i+2)) ;;
            -*) i=$((i+1)) ;;
            *) i=$((i+1)); break ;;          # the duration / the lockfile
          esac
        done ;;
      npx)
        i=$((i+1))
        case "${toks[i]:-}" in --yes|-y|--no-install) i=$((i+1)) ;; esac ;;
      pnpm|npm|yarn|bun)
        case "${toks[i+1]:-}" in exec|dlx) i=$((i+2)) ;; *) break ;; esac ;;
      bash|sh|zsh|dash)
        # `bash script.sh` -> judge the script. `bash -c "..."` keeps `bash` as
        # the command word, because the caller re-classifies what is inside.
        case "${toks[i+1]:-}" in -*|"") break ;; *) i=$((i+1)) ;; esac ;;
      *) break ;;
    esac
  done
  w="${toks[i]:-}"
  # `\rm` is the standard bypass for an alias, and it is still rm. basename does
  # not strip the backslash, so the command word has to.
  w="${w#\\}"
  if [ -n "$w" ]; then printf '%s\n' "$(basename -- "$w" 2>/dev/null || printf '%s' "$w")"
  else printf '\n'; fi
  printf '%s\n' "${toks[*]:i+1}"
  printf '%s\n' "$w"
}

# Is this host/URL fragment a LOCAL database? Anything else is treated as prod:
# the guard cannot resolve $DATABASE_URL, and a connection string it cannot read
# is exactly the one worth refusing.
is_local_db() {
  case "$1" in
    *localhost*|*127.0.0.1*|*"[::1]"*|*"@db:"*|*"@postgres:"*|*file:*|*":memory:"*) return 0 ;;
  esac
  return 1
}

deny() { RULE="$1"; WHY="$2"; }

# --- family 6: destructive filesystem verbs ---------------------------------
# WHAT IS PROTECTED: the harness's own state on this box, plus the checkouts and
# the key material. These are box-layout facts derived from $HARNESS, not tunable
# policy — losing any of them costs a rebuild of the box, and none of them is
# something a session has a reason to delete.
# Both spellings of the harness dirs: $HARNESS is /root/harness on a real box and
# a scratch tree under TMPDIR in the suites, and neither one stops being state.
PROTECTED=(/root/orchestrator /root/repos /root/harness-checkout /etc/harness /root/.ssh)
for _d in env state logs builds flags locks; do
  PROTECTED+=("$HARNESS/$_d" "/root/harness/$_d")
done
# WHAT IS EXPLICITLY THE LANE'S OWN. A build legitimately blows away its own
# node_modules, its own worktree and its own scratch space, and $HARNESS/builds
# being protected must not stop it from cleaning the build dir it owns. Filled
# lazily: the printenv reads and the glob only happen once a destructive verb is
# actually being judged.
ALLOWED=(/tmp "${TMPDIR:-/tmp}")
_ROOTS_READY=0
_init_roots() {
  [ "$_ROOTS_READY" = 1 ] && return 0
  _ROOTS_READY=1
  local v d
  for v in WT BUILD_DIR HARNESS_LANE_WT HARNESS_LANE_BUILD_DIR; do
    d=$(printenv "$v" 2>/dev/null) || d=""
    [ -n "$d" ] && ALLOWED+=("$d")
  done
  local proj="${HARNESS_LANE_PROJECT:-}" tick="${HARNESS_TICKET:-}" off=0
  if [ -n "$proj" ] && [ -n "$tick" ]; then
    shopt -q nullglob || off=1
    shopt -s nullglob
    for d in "$HARNESS/builds/$proj-$tick"-*; do ALLOWED+=("$d"); done
    [ "$off" = 1 ] && shopt -u nullglob
  fi
  return 0
}

# Is <path> equal to <root> or inside it? Reports the root's length in $_UL (a
# global, not stdout: this runs once per root per target and a fork each would
# cost more than the whole rest of the classifier). The caller picks the MOST
# SPECIFIC root, which is what lets $HARNESS/builds be protected while the lane's
# own build dir under it is allowed, and $HARNESS itself sit under /tmp on a test
# box. Longest root wins; an allow-list root wins a tie.
_UL=0
_under() { # _under <path> <root>
  local pth="$1" root="$2"
  [ -n "$root" ] || return 1
  [ "$root" = / ] || root="${root%/}"
  # `/` is its own prefix and stripping its slash would leave nothing to match.
  # Without this the ancestor test in check_fs_targets answers "no" for `rm -rf /`.
  if [ "$root" = / ]; then
    case "$pth" in /*) _UL=1; return 0 ;; *) return 1 ;; esac
  fi
  [ "$pth" = "$root" ] || [ "${pth#"$root"/}" != "$pth" ] || return 1
  _UL=${#root}
  return 0
}

# Was NAME assigned somewhere in this same command line? `X=/tmp/a; rm -rf $X/b`
# is a set variable as far as the agent is concerned, even though this hook's own
# environment has never heard of it. Treated as unresolvable (allowed), never as
# empty.
_assigned_in_cmd() { # _assigned_in_cmd <name>
  local n="$1"
  case "$NORM" in "$n="*) return 0 ;; esac
  case " $NORM " in
    *" $n="*|*";$n="*|*"export $n="*|*"export $n "*|*"local $n="*|*"local $n "*|\
    *"read $n "*|*"read -r $n "*|*" $n in "*) return 0 ;;
  esac
  return 1
}

# Resolve one target word to an absolute path.
#   rc 0 + path on stdout — resolved
#   rc 1                  — unresolvable, and unresolvable means ALLOW: a
#                           computed path is not something this matcher gets to
#                           guess about
#   rc 2                  — the word contains an UNSET/EMPTY variable, which is
#                           its own refusal: `rm -rf "$X/env"` with X unset is
#                           `rm -rf /env`
# Variables are read from this hook's own process environment with printenv,
# never ${!name} — the hook must not evaluate a name the agent chose. Every
# ${NAME<operator>...} form is unresolvable on purpose (A8): the value cannot be
# known, and a guessed placeholder could fabricate a refusal.
resolve_target() { # resolve_target <word> <segcwd>
  local w="$1" segcwd="$2" out="" rest name val chunk inner body empty=0 norm
  [ -n "$w" ] || return 1
  case "$w" in *'$('*|*'`'*) return 1 ;; esac
  w="${w//\"/}"; w="${w//\'/}"
  [ -n "$w" ] || return 1
  case "$w" in '~'*) out="${HOME:-/root}"; w="${w#\~}" ;; esac
  rest="$w"
  while [ -n "$rest" ]; do
    case "$rest" in
      '$'*)
        rest="${rest#\$}"
        case "$rest" in
          '{'*)
            body="${rest#\{}"
            case "$body" in *'}'*) ;; *) return 1 ;; esac
            inner="${body%%\}*}"; rest="${body#*\}}"
            # Only a bare ${NAME} resolves. Anything else — an operator form, a
            # positional, $@/$*/$#/$?/$! — carries a non-word character here.
            case "$inner" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;; esac
            name="$inner" ;;
          [A-Za-z_]*)
            name="${rest%%[!A-Za-z0-9_]*}"
            rest="${rest#"$name"}" ;;
          *) return 1 ;;
        esac
        val=$(printenv "$name" 2>/dev/null) || val=""
        if [ -n "$val" ]; then out="$out$val"
        elif _assigned_in_cmd "$name"; then return 1
        else empty=1
        fi ;;
      *)
        chunk="${rest%%\$*}"
        [ -n "$chunk" ] || return 1
        out="$out$chunk"
        rest="${rest#"$chunk"}" ;;
    esac
  done
  [ "$empty" = 0 ] || return 2
  case "$out" in
    /*) ;;
    *) [ -n "$segcwd" ] || return 1
       out="$segcwd/$out" ;;
  esac
  # A TRAILING GLOB IS THE DIRECTORY IT EXPANDS IN. The shell expands `rm -rf
  # /root/harness/*` before rm runs; this hook only ever sees the unexpanded
  # word, and that command deletes exactly what `rm -rf /root/harness` deletes.
  # Only TRAILING components are folded away — a glob in the middle
  # (`/root/repos/*/node_modules`) already prefix-matches its protected root.
  while :; do
    case "${out##*/}" in *'*'*|*'?'*|*'['*) ;; *) break ;; esac
    case "$out" in */*) out="${out%/*}" ;; *) break ;; esac
    [ -n "$out" ] || { out=/; break; }
  done
  # -m -s: lexical only. The target may not exist yet, and a symlink this box
  # happens to have is not what the command text says. If realpath is missing the
  # joined path is judged as is (named in the honest-limits list above).
  norm=$(realpath -m -s -- "$out" 2>/dev/null) || norm=""
  [ -n "$norm" ] || norm="$out"
  norm="${norm%/}"; [ -n "$norm" ] || norm=/
  printf '%s' "$norm"
  return 0
}

# Judge a list of target words for one verb. First deny wins.
check_fs_targets() { # check_fs_targets <verb-label> <segcwd> <target>...
  local label="$1" segcwd="$2"; shift 2
  local t pth rc r rs root prot allow anc a
  _init_roots
  for t in "$@"; do
    [ -n "$t" ] || continue
    pth=$(resolve_target "$t" "$segcwd"); rc=$?
    if [ "$rc" = 2 ]; then
      deny fs-empty-expansion "\`$label\` with an unset or empty \$VARIABLE in its target \`$t\` — an empty expansion turns \`rm -rf \"\$X/env\"\` into \`rm -rf /env\`, so it is refused before it runs, not after"
      return 0
    fi
    [ "$rc" = 0 ] || continue
    prot=0; allow=0; root=""; anc=0
    # BOTH DIRECTIONS. "Is the target under a protected root" on its own answers
    # no to `rm -rf /root/harness`, because the roots are that directory's
    # CHILDREN — and `/root/harness/{env,bin,logs,builds,...}` gone is precisely
    # the footprint of the #388 wipe this family exists for. A target that a
    # protected root sits under takes that root with it, so it is judged by it,
    # at the ROOT's own length either way: the longest-root rule and the
    # allow-list tiebreak below are unchanged.
    for r in "${PROTECTED[@]}"; do
      rs="${r%/}"; [ -n "$rs" ] || rs="$r"
      if _under "$pth" "$rs"; then a=0
      elif _under "$rs" "$pth"; then a=1
      else continue; fi
      [ "${#rs}" -gt "$prot" ] && { prot="${#rs}"; root="$rs"; anc="$a"; }
    done
    [ "$prot" -gt 0 ] || continue
    for r in "${ALLOWED[@]}"; do
      _under "$pth" "$r" || continue
      [ "$_UL" -gt "$allow" ] && allow="$_UL"
    done
    # The most specific root decides, and the lane's own space wins a tie.
    [ "$allow" -ge "$prot" ] && continue
    if [ "$anc" = 1 ]; then
      deny fs-destroy "\`$label\` pointed at $pth — $root sits under that, and it is the harness's own state on this box and is not a session's to delete"
    else
      deny fs-destroy "\`$label\` pointed at $pth — that is under $root, which is the harness's own state on this box and is not a session's to delete"
    fi
    return 0
  done
  return 0
}

# Every token that is neither a flag nor the VALUE of one of the flags named in
# $1 (a space-separated list), honouring `--`. One collector for all the verbs:
# the only thing that differs between them is that list.
_positionals() { # _positionals "<value-taking flags>" <token>...
  local vf=" $1 "; shift
  local skip=0 dd=0 t
  for t in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    if [ "$dd" = 1 ]; then printf '%s\n' "$t"; continue; fi
    case "$t" in
      --) dd=1 ;;
      -*) case "$vf" in *" $t "*) skip=1 ;; esac ;;
      *) printf '%s\n' "$t" ;;
    esac
  done
}

# The redirect target of a segment, when the segment is a PURE TRUNCATION
# (`: > f`, `true > f`, `cat /dev/null > f`, a bare `> f`). `>>` is an append,
# `>&`/`2>&1` is a descriptor dup, and `cmd > f` is a write whose CONTENT is the
# point — the triage prompt's own `run-build.sh … > logs/<p>.<k>-build.out` and
# `… > state/<p>.json` idioms are exactly that, so none of those is family 6.
_redirect_target() { # _redirect_target <segment>
  local -a rt=(); local i=0 t
  read -r -a rt <<<"$1"
  while [ "$i" -lt "${#rt[@]}" ]; do
    t="${rt[i]}"
    case "$t" in
      '>>'*|'>&'*|'1>>'*|'1>&'*|'2>'*|'&>>'*|':>>'*) ;;
      '>'|'1>'|'&>'|':>') printf '%s' "${rt[i+1]:-}"; return 0 ;;
      ':>'*) printf '%s' "${t#:>}"; return 0 ;;
      '>'*)  printf '%s' "${t#>}";  return 0 ;;
      '1>'*) printf '%s' "${t#1>}"; return 0 ;;
      '&>'*) printf '%s' "${t#&>}"; return 0 ;;
    esac
    i=$((i+1))
  done
  return 1
}

# Per-verb target extraction. Anything that is not a target — a flag, a flag's
# value, a remote rsync spec — is stepped over rather than guessed at.
fs_family() { # fs_family <cmd-word> <rest-of-segment> <segment> <segcwd>
  local cw="$1" rest="$2" seg="$3" segcwd="$4"
  local -a tk=() tg=()
  local i n sub="" gdir="" gres="" grc=0 tgt="" label="$cw"
  read -r -a tk <<<"$rest"
  n=${#tk[@]}

  case "$cw" in
    rm) # any rm, flags or not (A1): one protected FILE is still gone
      mapfile -t tg < <(_positionals "" "${tk[@]}") ;;

    find) # only a find that DELETES; `find … -name '*.log'` is a read
      case " $rest " in *" -delete "*|*" -delete") ;; *) return 0 ;; esac
      label="find -delete"
      # Targets are the leading paths, before the first predicate.
      i=0
      while [ "$i" -lt "$n" ]; do
        case "${tk[i]}" in
          -H|-L|-P|-O*) i=$((i+1)); continue ;;
          -D) i=$((i+2)); continue ;;
          -*|'('|'!') break ;;
          *) tg+=("${tk[i]}"); i=$((i+1)) ;;
        esac
      done
      [ "${#tg[@]}" -gt 0 ] || tg=(".") ;;

    git)
      i=0
      while [ "$i" -lt "$n" ]; do
        case "${tk[i]}" in
          -C) gdir="${tk[i+1]:-}"; i=$((i+2)) ;;
          -c|--git-dir|--work-tree|--namespace|--exec-path) i=$((i+2)) ;;
          -*) i=$((i+1)) ;;
          *) sub="${tk[i]}"; break ;;
        esac
      done
      case "$sub" in
        clean) # deletes in the repo it runs in: the -C dir, else the segment's
               # cwd. Pathspecs narrow it, so they count too — and they are
               # relative to THAT repo, not to the caller's cwd. Resolving them
               # against the cwd refuses `git -C $WT clean -fd dist` run from a
               # protected directory over a path the command never touches.
          label="git clean"
          mapfile -t tg < <(_positionals "-e --exclude" "${tk[@]:i+1}")
          if [ -n "$gdir" ]; then
            gres=$(resolve_target "$gdir" "$segcwd"); grc=$?
            tg+=("$gdir")        # the -C dir itself is what gets cleaned
            # An unresolvable -C dir makes its pathspecs unresolvable too; an
            # empty expansion in it is still caught, on the raw word above.
            if [ "$grc" = 0 ]; then segcwd="$gres"; else segcwd=""; fi
          else
            tg+=("$segcwd")
          fi ;;
        worktree) # the REMOVED path counts, never the -C dir (A11: prune too)
          case "${tk[i+1]:-}" in remove|prune) ;; *) return 0 ;; esac
          label="git worktree ${tk[i+1]}"
          mapfile -t tg < <(_positionals "" "${tk[@]:i+2}") ;;
        *) return 0 ;;
      esac ;;

    rsync) # --delete* makes rsync a deleting verb on its destination; the source
           # is only read, but both are judged. A remote spec is not ours.
      case "$rest" in *--delete*) ;; *) return 0 ;; esac
      label="rsync --delete"
      local p
      while IFS= read -r p; do
        case "$p" in *://*|*:*) continue ;; esac
        tg+=("$p")
      done < <(_positionals "-e --rsh -f --filter --exclude --include --exclude-from --include-from --files-from --log-file --temp-dir -T" "${tk[@]}") ;;

    truncate)
      mapfile -t tg < <(_positionals "-s -r --size --reference" "${tk[@]}") ;;

    shred)
      mapfile -t tg < <(_positionals "-n -s --iterations --size" "${tk[@]}") ;;

    *) # pure truncation through a redirect, and nothing else
      local trunc=0
      case "$cw" in :|true) trunc=1 ;; esac
      # The RAW first token, not $cw: cmd_word basenames it, so a JOINED bare
      # redirect (`>/root/harness/env/x`) arrives here as the command word `x`
      # and matched nothing. _redirect_target below is still the real gate — it
      # is what tells a truncation from a `>>` append or a `>&` dup.
      case "${seg%% *}" in ':>'*|'>'*|'1>'*|'&>'*) trunc=1 ;; esac
      case "$seg" in *"/dev/null >"*) trunc=1 ;; esac
      [ "$trunc" = 1 ] || return 0
      tgt=$(_redirect_target "$seg") || return 0
      [ -n "$tgt" ] || return 0
      check_fs_targets "truncating redirect" "$segcwd" "$tgt"
      return 0 ;;
  esac

  [ "${#tg[@]}" -gt 0 ] && check_fs_targets "$label" "$segcwd" "${tg[@]}"
  return 0
}

# --- family 7: the review lane on a live harness box (BH-8103) -------------
# On 2026-10-23 00:18Z the merge conductor's re-review agent ran `git checkout
# -q pr8069` in the hub's deploy checkout and then ran a test suite there as
# root. A review on a live box is static: it reads the diff and the files. Two
# rules, judged only when LIVE_REVIEW=1:
#   review-checkout  a git verb that moves HEAD or the work tree (or `gh pr
#                    checkout`) in a shared checkout, or in a dir this guard
#                    cannot resolve. A lane's own clone or worktree elsewhere,
#                    and every read-only git verb, stay allowed.
#   review-suite     a run of a shell suite (any `tests/**/*.sh`,
#                    bin/test-impact-gate.sh, bin/fast-lints.sh), directly, through
#                    bash/sh, or as the body of a `for` over suite paths.
#                    `bash -n` (syntax only) is allowed.
# HONEST LIMITS: `find -exec`, `xargs`, `while read` loops, `source`, and a
# suite reached through a script the session writes all get through. On a
# codex/gemini/grok lane the PATH shims send only the shimmed binaries (`git`,
# `gh`) here, so review-suite is a PreToolUse (claude) rule there.
#
# The shared roots: the deploy checkout, the harness, the repo checkouts and
# the orchestrator, each also through `readlink -f` (/root/harness is a symlink
# to /data/harness on the boxes). Filled lazily, once.
SHARED=()
_SHARED_READY=0
_init_shared() {
  [ "$_SHARED_READY" = 1 ] && return 0
  _SHARED_READY=1
  local r l
  for r in "$ILG_CHECKOUT" "$HARNESS" /root/harness /root/repos /root/orchestrator; do
    [ -n "$r" ] || continue
    [ "$r" = / ] || r="${r%/}"
    SHARED+=("$r")
    l=$(timeout 5 readlink -f -- "$r" 2>/dev/null) || l=""
    [ -n "$l" ] && [ "$l" != "$r" ] && SHARED+=("$l")
  done
  return 0
}

# Is <dir> a shared checkout? rc 0 + the root in $_SC_ROOT. A lane's own tree
# (HARNESS_LANE_WT, WT, BUILD_DIR, HARNESS_LANE_BUILD_DIR) wins only when it is
# STRICTLY inside the shared root: agent-call.sh sets HARNESS_LANE_WT to its own
# cwd, and a call started in the deploy checkout does not make it the lane's.
_SC_ROOT=""
_in_shared() { # _in_shared <dir>
  local d="$1" p r v w best=0 own=0
  local -a cands=("$d")
  _init_shared
  p=$(timeout 5 readlink -f -- "$d" 2>/dev/null) || p=""
  [ -n "$p" ] && [ "$p" != "$d" ] && cands+=("$p")
  for p in "${cands[@]}"; do
    for r in "${SHARED[@]}"; do
      _under "$p" "$r" || continue
      [ "$_UL" -gt "$best" ] && { best="$_UL"; _SC_ROOT="$r"; }
    done
    for v in HARNESS_LANE_WT WT BUILD_DIR HARNESS_LANE_BUILD_DIR; do
      w=$(printenv "$v" 2>/dev/null) || continue
      [ -n "$w" ] || continue
      _under "$p" "$w" && [ "$_UL" -gt "$own" ] && own="$_UL"
    done
  done
  [ "$best" -gt 0 ] && [ "$own" -le "$best" ]
}

# The file a segment executes: the peeled word, or, when cmd_word kept the
# shell as the word (a flag follows it), the shell's first positional. rc 1
# when there is none, and for `-c` (the bash -c recursion judges the string)
# and `-n` / `--noexec` (syntax only, runs nothing).
_run_target() { # _run_target <cw> <rest> <raw>
  local cw="$1" rest="$2" raw="$3" t i=0
  local -a a=()
  case "$cw" in
    bash|sh|zsh|dash) ;;
    *) [ -n "$raw" ] || return 1; printf '%s' "$raw"; return 0 ;;
  esac
  read -r -a a <<<"$rest"
  while [ "$i" -lt "${#a[@]}" ]; do
    t="${a[i]}"
    case "$t" in
      --noexec) return 1 ;;
      --rcfile|--init-file) i=$((i+2)); continue ;;
      --) i=$((i+1)); break ;;
      --*) ;;
      [-+]o|[-+]O) i=$((i+2)); continue ;;
      [-+]*) case "${t#?}" in *c*|*n*) return 1 ;; esac ;;
      *) break ;;
    esac
    i=$((i+1))
  done
  [ "$i" -lt "${#a[@]}" ] || return 1
  printf '%s' "${a[i]}"
}

# `for <v> in <words>` whose words name suites -> prints <v>.
_suite_loop_var() { # _suite_loop_var <segment>
  local -a w=()
  read -r -a w <<<"$1"
  [ "${w[0]:-}" = for ] && [ "${w[2]:-}" = in ] || return 0
  case "${w[1]:-}" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 0 ;; esac
  case " ${w[*]:3} " in
    *tests/*.sh*|*test-impact-gate*|*fast-lints*) printf '%s' "${w[1]}" ;;
  esac
  return 0
}

review_family() { # review_family <segment> <segcwd> <suite-loop-var>
  local seg="$1" segcwd="$2" lv="$3" cw rest raw tgt sub="" gdir gi=0
  local -a C7=() gt=()
  # A loop or if body: the command word follows the keyword.
  while :; do
    case "$seg" in
      do\ *|then\ *|else\ *|'{ '*) seg="${seg#* }"; seg="${seg#"${seg%%[![:space:]]*}"}" ;;
      *) break ;;
    esac
  done
  mapfile -t C7 < <(cmd_word "$seg")
  cw="${C7[0]:-}"; rest="${C7[1]:-}"; raw="${C7[2]:-}"
  [ -n "$cw" ] || return 0

  # --- review-checkout ---
  case "$cw" in
    git)
      gdir="$segcwd"
      read -r -a gt <<<"$rest"
      while [ "$gi" -lt "${#gt[@]}" ]; do
        case "${gt[gi]}" in
          -C) gdir=$(resolve_target "${gt[gi+1]:-}" "$segcwd") || gdir=""; gi=$((gi+2)) ;;
          -c|--git-dir|--work-tree|--namespace|--exec-path) gi=$((gi+2)) ;;
          -*) gi=$((gi+1)) ;;
          *) sub="${gt[gi]}"; break ;;
        esac
      done
      case "$sub" in
        checkout|switch|reset|pull|merge|rebase|restore|cherry-pick|am) ;;
        stash) case "${gt[gi+1]:-}" in list|show) sub="" ;; esac ;;
        *) sub="" ;;
      esac
      [ -n "$sub" ] && sub="git $sub" ;;
    gh)
      gdir="$segcwd"
      case " $rest " in *" pr checkout "*) sub="gh pr checkout" ;; esac ;;
  esac
  if [ -n "$sub" ]; then
    if [ -z "$gdir" ]; then
      deny review-checkout "\`$sub\` in a directory this guard cannot resolve — on a live harness box a review moves no checkout it cannot prove is its own, and a shared checkout must stay where the deploy left it"
    elif _in_shared "$gdir"; then
      deny review-checkout "\`$sub\` in $gdir — that is a shared checkout on a live harness box (under $_SC_ROOT), and a review never moves its HEAD or work tree"
    fi
    return 0
  fi

  # --- review-suite ---
  tgt=$(_run_target "$cw" "$rest" "$raw") || return 0
  tgt="${tgt//\"/}"; tgt="${tgt//\'/}"
  if [ -n "$lv" ]; then
    case "$tgt" in
      "\$$lv"|"\${$lv}") deny review-suite "a \`for $lv in\` loop over test suites that runs each one — suites are not run here, on a live harness box"; return 0 ;;
    esac
  fi
  case "$tgt" in
    tests/*.sh|*/tests/*.sh|*test-impact-gate.sh|*fast-lints.sh)
      deny review-suite "\`$tgt\` runs a test suite — suites are not run here, on a live harness box" ;;
  esac
  return 0
}

classify() { # classify <command-string> [segment-cwd]  (sets RULE/WHY on the
             # first match). The cwd is passed IN so the `bash -c` recursion
             # below keeps what an outer `cd` set; unset, not empty, falls back
             # to the payload cwd — an unresolvable cd is a real empty.
  local line seg cw rest tok inner cdto lv=""
  local segcwd="${2-$CWD}"
  local -a CW=()
  while IFS= read -r line; do
    seg="${line#"${line%%[![:space:]]*}"}"
    [ -n "$seg" ] || continue
    [ -n "$RULE" ] && return 0
    CW=(); mapfile -t CW < <(cmd_word "$seg")
    cw="${CW[0]:-}"; rest="${CW[1]:-}"
    [ -n "$cw" ] || continue

    # `bash -c "<command>"` — judge what is inside, one level down.
    case "$cw" in
      bash|sh|zsh|dash)
        case "$rest" in
          *-c\ *) inner=$(printf '%s' "${rest#*-c }" | sed -E 's/^ *["'"'"']//; s/["'"'"'] *$//')
                  classify "$(printf '%s' "$inner" | sed -E 's/\$\(/\n/g; s/`/\n/g; s/\|\|/\n/g; s/&&/\n/g; s/[;|)]/\n/g')" "$segcwd"
                  [ -n "$RULE" ] && return 0 ;;
        esac ;;
    esac

    # `cd X && rm -rf logs` arrives as two segments (the split is on `&&`), so
    # the cd has to move the cwd the LATER segments resolve relative targets
    # against. Anything it cannot resolve leaves the cwd unknown, which makes
    # relative targets unresolvable — allowed, never guessed.
    if [ "$cw" = "cd" ]; then
      cdto="${rest%% *}"
      [ -n "$cdto" ] && { segcwd=$(resolve_target "$cdto" "$segcwd") || segcwd=""; }
      continue
    fi

    # --- 6. a destructive filesystem verb pointed at harness state --------
    # Judged on EVERY marked lane (see the LANE FENCE note in the header): this
    # family is not about authority, and no lane on this box owns the harness's
    # env/state/logs/builds/flags/locks, the checkouts or the key material.
    fs_family "$cw" "$rest" "$seg" "$segcwd"
    [ -n "$RULE" ] && return 0

    # --- 7. the review lane on a live harness box (BH-8103) -------------
    if [ "$LIVE_REVIEW" = 1 ]; then
      case "$seg" in "for "*) lv=$(_suite_loop_var "$seg") ;; esac
      review_family "$seg" "$segcwd" "$lv"
      [ -n "$RULE" ] && return 0
    fi

    # Families 1-5 are authority laws, fenced to the guarded build stages.
    [ "$FULL" = 1 ] || continue

    case "$cw" in
      # --- 1. merging a PR ------------------------------------------------
      gh)
        case " $rest " in
          *" pr merge "*|*" pr merge") deny pr-merge "\`gh pr merge\` — merging is never an agent's call on this box" ;;
        esac ;;
      merge-sweep.sh|merge-queue.sh)
        deny pr-merge "\`$cw\` — the merge lanes run from cron with merge authority; a build/triage session invoking one is the same iron law by another route" ;;

      # --- 2. pushing main/master (including force), then ANY push ----------
      git)
        # `push` has to be the SUBCOMMAND, not a word inside an argument:
        # `git log --grep push` is not a push. Git's own global flags (-C, -c)
        # carry a value, so they are stepped over rather than merely skipped.
        local -a gt=(); local gi=0 sub="" gdir="$segcwd"
        read -r -a gt <<<"$rest"
        while [ "$gi" -lt "${#gt[@]}" ]; do
          case "${gt[gi]}" in
            -C) gdir=$(resolve_target "${gt[gi+1]:-}" "$segcwd") || gdir=""; gi=$((gi+2)) ;;
            -c|--git-dir|--work-tree|--namespace|--exec-path) gi=$((gi+2)) ;;
            -*) gi=$((gi+1)) ;;
            *) sub="${gt[gi]}"; break ;;
          esac
        done
        [ "$sub" = "push" ] || continue
        local broad=0
        local -a pos=()
        for tok in "${gt[@]:gi+1}"; do
          case "$tok" in
            --all|--mirror) broad=1 ;;
            -*) ;;
            *) pos+=("$tok") ;;
          esac
        done
        # pos[0] is the remote; everything after it is a refspec.
        for tok in "${pos[@]:1}"; do
          case "${tok#+}" in
            main|master|refs/heads/main|refs/heads/master) deny push-main "\`git push\` targeting ${tok#+} — main is moved by the merge lane, never by a build session"; break ;;
          esac
          case "${tok##*:}" in
            main|master|refs/heads/main|refs/heads/master) deny push-main "\`git push\` with the refspec $tok — main is moved by the merge lane, never by a build session"; break ;;
          esac
        done
        [ -n "$RULE" ] && return 0
        if [ "$broad" = 1 ]; then
          deny push-main "\`git push --all/--mirror\` — it carries main with it"; return 0
        fi
        # The branch the push lands on, for the hold read after the verdict:
        # the first refspec's destination, or — with no refspec, or `HEAD` —
        # the branch the session is standing on (`cd X &&` and `git -C X`
        # included), which then also decides whether it is main.
        PUSH_BR="${pos[1]:-}"; PUSH_BR="${PUSH_BR#+}"; PUSH_BR="${PUSH_BR##*:}"; PUSH_BR="${PUSH_BR#refs/heads/}"
        if { [ -z "$PUSH_BR" ] || [ "$PUSH_BR" = HEAD ]; } && [ -n "$gdir" ] && [ -d "$gdir" ]; then
          PUSH_BR=$(timeout 5 git -C "$gdir" symbolic-ref --quiet --short HEAD 2>/dev/null)
          case "$PUSH_BR" in
            main|master) deny push-main "a \`git push\` of HEAD while checked out on $PUSH_BR — main is moved by the merge lane, never by a build session"; return 0 ;;
          esac
        fi
        # ANY other push (BH-2741). An agent that pushes its own branch walks
        # past bin/lib/hold-push.sh, the one place that re-reads the ticket's
        # HOLD at the push, so a lead's HOLD could lose the race to the agent.
        # The guarded lanes commit; the harness pushes after the session.
        deny agent-push "\`git push\` from the $LANE lane — the harness pushes this branch after your session, through bin/lib/hold-push.sh (it re-reads the ticket's HOLD first). Commit your work and stop"
        return 0
        ;;

      # --- 3. prisma pointed at a live database ----------------------------
      prisma)
        case " $rest " in
          *" db push"*|*" migrate deploy"*|*" migrate dev"*|*" migrate reset"*)
            # The guard cannot see the ambient DATABASE_URL, so it denies unless
            # the segment itself proves the target is local. Repo law is
            # "NEVER db push from this repo" anyway; migrations ship as SQL.
            if [[ "$seg" =~ DATABASE_URL=[^[:space:]]+ ]] && is_local_db "${BASH_REMATCH[0]}"; then
              continue
            fi
            deny prisma-live-db "\`prisma ${rest%% -*}\` with no provably local DATABASE_URL — schema changes ship as an idempotent SQL migration, applied by the project's own apply mechanism" ;;
        esac ;;

      # --- 4. a raw client writing a prod database -------------------------
      psql|mysql|mariadb|mongosh|mongo)
        if is_local_db "$seg"; then continue; fi
        # A read is fine; a write, a script file, or an interactive session
        # (whose statements this guard can never see) is not.
        local writes=0
        shopt -s nocasematch
        [[ "$seg" =~ (insert|update|delete|drop|alter|truncate|create|grant|revoke|copy)[[:space:]] ]] && writes=1
        shopt -u nocasematch
        case " $rest " in *" -f "*|*" --file"*|*" < "*) writes=1 ;; esac
        case " $rest " in *" -c "*|*" --command"*|*" -e "*|*" --eval"*|*" --execute"*) ;; *) writes=1 ;; esac
        [ "$writes" = 1 ] && deny prod-db-write "\`$cw\` running a write (or an unreadable script/interactive session) against a non-local database — the only prod writes this box makes are through an app's own API" ;;

      # --- 5. deploying / promoting on Vercel ------------------------------
      vercel|vc)
        local sub="" reads=0
        for tok in $rest; do
          case "$tok" in
            deploy|promote|rollback|redeploy|alias) sub="$tok"; break ;;
            --prod|--prebuilt) sub="--prod"; break ;;
            env|ls|list|inspect|logs|whoami|link|login|logout|projects|project|teams|team|domains|certs|dns|secrets|pull|build|git|bisect|help|--help|-h|--version|integration|firewall|target|blob|microfrontends)
              reads=1; break ;;
          esac
        done
        if [ -n "$sub" ]; then
          deny vercel-deploy "\`$cw $sub\` — deploys are the deploy train's, and production is promoted by a human"
        elif [ "$reads" = 0 ]; then
          deny vercel-deploy "a bare \`$cw\` — with no subcommand the CLI DEPLOYS, and deploys are the deploy train's"
        fi ;;
    esac
    [ -n "$RULE" ] && return 0
  done <<<"$1"
  return 0
}

classify "$SPLIT"
[ -n "$RULE" ] || ALLOW
DECIDED=1   # from here the verdict is BLOCK, whatever the logging below does

# --- agent-push: name the hold (BH-2741) ------------------------------------
# The deny above is already final; this only decides what the ONE finding line
# and the model's reason say about the ticket's hold. Read through the same
# hold_push_verdict the harness push uses, bounded at 6 s (read 3 + jq 5 + awk
# 5 + git 5 + this 6 = 24 s, under the CLI's 30 s hook budget), and paid only on
# this deny path. A slow, failed or missing read changes the wording, never the
# verdict. HARNESS_LANE is dropped for the read so the lane shims on a codex
# lane's PATH do not send its `gh` back through this guard.
HOLD=""
if [ "$RULE" = agent-push ]; then
  _hl=""
  for _c in "$(dirname "$0")/lib/hold-push.sh" "$HARNESS/bin/lib/hold-push.sh"; do
    [ -r "$_c" ] && { _hl="$_c"; break; }
  done
  if [ -z "$_hl" ]; then
    HOLD="unchecked (bin/lib/hold-push.sh not beside the guard)"
  else
    HOLD=$(timeout 6 env -u HARNESS_LANE bash -c '. "$1" && hold_push_verdict "$2" - "$3"' _ "$_hl" "${HARNESS_LANE_PROJECT:-}" "$PUSH_BR" 2>/dev/null)
    _hrc=$?
    { [ "$_hrc" = 124 ] || [ -z "$HOLD" ]; } && HOLD="unchecked (hold read exceeded 6s)"
    HOLD=$(printf '%s' "$HOLD" | tr '\t\n' '  ' | cut -c1-200)
  fi
  case "$HOLD" in
    held*) WHY="$WHY. The ticket is on HOLD (${HOLD#held }): stop working this branch" ;;
  esac
fi

# --- the attempt is a finding ------------------------------------------------
# One line into logs/findings.log, the shape bin/findings-log.sh writes and
# bin/rule-miner.sh reads (source (e)): the field walk stops at `::`, keys on
# the `family=` prefix, and reads the first [bracketed] token as the project.
# family= is a stable per-rule string rather than an alert_family hash so the
# same iron law reached for on two boxes counts as ONE recurring family — and
# a hash would cost a python spawn on every Bash call in every build session.
# Logging is best-effort and happens AFTER the verdict is decided: a full disk
# must not turn into a permitted merge.
{
  P="${HARNESS_LANE_PROJECT:-unknown}"
  T="${HARNESS_TICKET:-}"; [ -n "$T" ] || T="-"
  SHORT=$(printf '%s' "$NORM" | cut -c1-200)
  mkdir -p "$HARNESS/logs" 2>/dev/null
  # IRON_LAW_MECHANISM names WHICH fence caught it (SDLC item 8): this hook is
  # `PreToolUse`, and bin/lane-shims/_fence.sh — the same classifier reached
  # through a PATH shim on the codex/gemini/grok lanes — passes its own label.
  # It sits AFTER the first `::`, so rule-miner's field walk keys the two
  # mechanisms as the one family on purpose: the same iron law reached for by
  # two runners is one recurrence, not two.
  # agent-push carries the hold it read as a trailing ` :: hold=` field: after
  # the first `::`, so rule-miner's keying is unchanged.
  printf '%s [%s] ticket=%s lens=act-guard verdict=BLOCK rule=- family=actguard-%s :: %s DENIED in lane %s :: %s%s\n' \
    "$(STAMP)" "$P" "$T" "$RULE" "${IRON_LAW_MECHANISM:-PreToolUse}" "$LANE" "$SHORT" "${HOLD:+ :: hold=$HOLD}" >> "$HARNESS/logs/findings.log"
  # Family 6 ALSO alerts (A3). Families 1-5 are refusals of authority the lane
  # was never going to have, and a finding is the right weight for those. A
  # reached-for `rm -rf` on harness state is a different thing: it says a session
  # was one keystroke from costing this box its state, and that belongs where
  # somebody reads it within a tick, not only in a file the rule miner walks.
  case "$RULE" in
    fs-*)
      echo "$(STAMP) [$P] act-time iron-law guard REFUSED a destructive filesystem verb in lane $LANE ticket=$T: $SHORT :: $WHY. Tripwire only — the wall is the chattr ticket (#388)." \
        >> "$HARNESS/logs/ALERTS.log" ;;
  esac
} 2>/dev/null

case "$RULE" in
  fs-*) CLOSING="If this deletion is genuinely needed, say so in your reply and stop; a person runs
it from the console. The guard cannot see variables you set inside your own shell,
so use the literal path if the refusal was an empty expansion." ;;
  agent-push) CLOSING="This is the $LANE lane. It commits; it does not push. The harness pushes the
branch after your session ends, and it re-reads the ticket's HOLD before it does.
Commit your work, say in your output what is left, and stop." ;;
  review-*) CLOSING="This is the review lane on a live harness box. A review here is static: read the
diff and the files, do not check out a branch in a shared checkout and do not
run suites. If you wanted a suite result, say in your review that it was not run
here (CI and the Fly test host run them). (BH-8103)" ;;
  *) CLOSING="This is the $LANE lane on a builder box. It has no merge, push-to-main, deploy or
prod-write authority — that is a machine-wide iron law, not a preference of this
ticket, and the gated merge/deploy lanes exist precisely so an agent never needs
it. Do the buildable part, open or update the PR, and stop; say plainly in your
output what you could not do and who has to do it." ;;
esac

cat >&2 <<EOF
BLOCKED by the harness act-time iron-law guard: $WHY

The command was: $NORM

$CLOSING

Do not work around this (no alias, no helper script, no wrapper). Every blocked
attempt is filed as a finding in logs/findings.log and is mined for recurrence.
EOF
exit 2
