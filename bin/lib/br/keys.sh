#!/bin/bash
# shellcheck shell=bash
# module: keys
# bin/lib/br/keys.sh — BH-6461: the resolver's TICKET-KEY family: the key a PR
# belongs to, read off its build record, branch, title or build dir; the phrase
# that names where it came from; the give-up alert when nothing carries one; and
# the --only scope check on a conductor key. Sourced by bin/blocked-resolver.sh,
# never run. It reads $ST, $H and $ONLY at CALL time and nothing at source time.
#
# This is the ONLY definition of the 9 key functions. The driver keeps the
# globals they set (BR_TICKET_KEY, BR_KEY_SOURCE) and br_key_in_only's memo
# (_BR_ONLY_REPO): a module defines nothing at source time.
# ---------------------------------------------------------------------------

# br_key_shape <text> — the ticket key that <text> STARTS with, or nothing.
# Every board in this fleet keys the same way and always has: letters, a dash,
# digits (TK-775, TK-1617, TK-88, TK-131, TK-472). Whatever follows the number
# is decoration somebody else added — a rebuild's -r2, a branch slug, a build
# dir's timestamp, a title's ": " — and is dropped. The key comes back
# UPPER-CASED because bin/run-build.sh lower-cases it into the branch name and
# the queue, the board and the cap counter all want it back the way it was.
#
# The shape is the whole guard. A branch like `fix/report-nav-anchors` carries
# no key and must answer NOTHING rather than a guess: an enqueue with an
# invented key buys a quarantine (bin/fly-pool.sh) or builds the wrong ticket.
br_key_shape() {
  local k
  k=$(printf '%s' "${1:-}" | sed -nE 's/^([A-Za-z]{2,8})-([0-9]{1,6})($|[^0-9].*$)/\1-\2/p' | head -1)
  [ -n "$k" ] || return 1
  printf '%s' "$k" | tr '[:lower:]' '[:upper:]'
}

# br_key_from_branch <branch> — the key a harness branch name carries.
# bin/run-build.sh names every branch it cuts `ticket/<key lower-cased>`, plus
# an -rN suffix when the remote already holds that name; the other shapes here
# (TK-775-something, TK-775, feat/TK-775-slug) are what a hand-cut or
# fix-round branch looks like. Only the segment after the last slash is read,
# so the prefix (ticket/, feat/, fix/) never has to be enumerated.
br_key_from_branch() {
  local br="${1:-}"
  case "$br" in ''|-) return 1 ;; esac
  br_key_shape "${br##*/}"
}

# br_key_from_title <title> — "TK-775: what it does", "[TK-1617] what it does".
# The key is read at the FRONT of the title only, because that is where
# bin/run-build.sh puts it; a key mentioned mid-sentence is usually a reference
# to a different ticket ("supersedes TK-700") and must not be built.
br_key_from_title() {
  local t="${1:-}"
  case "$t" in ''|-) return 1 ;; esac
  case "$t" in '['*|'('*) t="${t:1}" ;; esac
  br_key_shape "$t"
}

# br_key_from_dir <project> <record-dir> — the key the pipeline itself wrote
# into the build dir name: pool-<project>-<KEY>-<stamp> or <project>-<KEY>-<stamp>.
br_key_from_dir() {
  local p="$1" rec="${2:--}" bn core
  case "$rec" in ''|-) return 1 ;; esac
  bn=$(basename "$rec"); core="${bn#pool-}"
  case "$core" in "$p"-*) br_key_shape "${core#"$p"-}" ;; *) return 1 ;; esac
}

# br_ticket_key <project> <record> <branch> [title] — THE ONE DERIVATION of the
# TICKET key (TK-510), which is what an enqueue needs. Prints
# "<KEY><TAB><source>"; rc 1 when nothing anywhere carries a key.
#
# ONE ORDER, NAMED OUT LOUD (BH-488). There used to be two: discovery read
# record -> branch, the rebuild rung read branch -> title -> record, and neither
# said which source had won — so "derived TK-9 from the PR/record" left an
# operator with three places to go looking. The order is the pipeline's own
# ledger first (the build record's ticket-meta.json, then the directory name the
# pipeline itself wrote, and only ever a record THIS project's pipeline wrote),
# then the PR head branch, then the PR title prefix. The record is first because
# it is the one artifact written by the process that knows which ticket this is;
# a branch and a title are names somebody chose.
#
# The -rN suffix a previous rebuild added is stripped by the parsers below, so
# every attempt enqueues the SAME ticket rather than inventing keys.
#
# The source words are `record`, `branch`, `title` — br_key_source_phrase turns
# them into the words a log line uses.
br_ticket_key() {
  local p="$1" rec="${2:--}" br="${3:-}" title="${4:-}" k dk
  # WHOSE RECORD IS THIS? Asked FIRST, before the file is read. br_key_from_dir
  # is the prefix test that says the pipeline wrote this record for THIS
  # project, and a record belonging to another one must not hand this project a
  # key out of a ticket-meta.json this project never wrote — a foreign key here
  # enqueues somebody else's ticket on this board.
  if dk=$(br_key_from_dir "$p" "$rec"); then
    if [ -s "$rec/ticket-meta.json" ]; then
      k=$(jq -r '(.key // .ticket_key // "")' "$rec/ticket-meta.json" 2>/dev/null)
      k=$(br_key_shape "$k") && { printf '%s\t%s' "$k" record; return 0; }
    fi
    printf '%s\t%s' "$dk" record; return 0
  fi
  k=$(br_key_from_branch "$br")     && { printf '%s\t%s' "$k" branch; return 0; }
  k=$(br_key_from_title "$title")   && { printf '%s\t%s' "$k" title;  return 0; }
  return 1
}

# br_key_source_phrase <source-word> — how a log line says where the key came
# from. Kept next to the resolver so the vocabulary has one home.
br_key_source_phrase() {
  case "${1:-}" in
    record) printf 'the build record' ;;
    branch) printf 'the PR branch' ;;
    title)  printf 'the PR title' ;;
    *)      printf 'an unnamed source' ;;
  esac
}

# br_derive_ticket_key <project> <pr-url> <record> — the SECOND ask, made where
# the first one could not have worked.
#
# 2026-09-15: project-5 #1124 (TK-775) at 06:14Z and #1136 (TK-1109) at 07:34Z
# were both closed by the rebuild rung and then NOT re-enqueued — "no ticket
# key — cannot enqueue a fresh build" — so neither ticket had an owner until the
# box happened to relaunch it. The key was never missing: it was on the branch
# (ticket/TK-775) the whole time. br_conductor_emit asks gh for that branch at
# DISCOVERY, which runs before br_one installs the repo's own installation token
# (br_use_token), and gh with the wrong token answers "Could not resolve to a
# Repository" — an empty branch, silently. Their build records were no help
# either: mc_record_for only matches a RESULT whose first line STARTS with
# `PR_CREATED`, and both of these read `RESULT_UNVERIFIED PR_CREATED ...`.
#
# So the ask is repeated here, inside the token — but through br_ticket_key,
# which is the one resolver (BH-488). This function's job is only to FETCH what
# that resolver reads: the head branch and the title, from a PR gh can now
# actually see. rc 1 only when every source genuinely carries no key, and the
# caller alerts on that rather than giving up quietly.
#
# IT PRINTS THE BARE KEY and leaves the source in BR_KEY_SOURCE (and the key in
# BR_TICKET_KEY), because a caller that wants both must NOT use `$( )`: a global
# set inside a command substitution dies with the subshell, the same lesson
# br_pr_ref documents. br_one calls it with stdout redirected and reads the
# globals.
br_derive_ticket_key() {
  local p="$1" url="${2:--}" rec="${3:--}" br="" title="" out
  BR_TICKET_KEY=""; BR_KEY_SOURCE=""
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    # A read that did not answer leaves both empty and falls through exactly as
    # an empty branch and an empty title do today; the 75 is in the log, and
    # br_nokey_alert is still the give-up said out loud.
    br=$(br_pr_field "$url" .head.ref 'head branch')
    title=$(br_pr_field "$url" .title 'pr title')
  fi
  out=$(br_ticket_key "$p" "$rec" "$br" "$title") || return 1
  BR_TICKET_KEY="${out%%	*}"; BR_KEY_SOURCE="${out##*	}"
  printf '%s' "$BR_TICKET_KEY"
}

# br_nokey_alert <project> <rkey> <pr-url> <record> — the give-up, said out loud.
# ONCE per key: this lane re-offers the same park every ten minutes, and an
# alert that repeats 144 times a day is an alert nobody reads.
br_nokey_alert() {
  local p="$1" rkey="$2" url="${3:--}" rec="${4:--}" f
  f="$ST/$p/$rkey.nokey-alerted"; mkdir -p "$(dirname "$f")" 2>/dev/null
  [ -e "$f" ] && return 0
  : > "$f"
  "$H/bin/lane-alert.sh" blocked-resolver "$p/$rkey: a fresh rebuild was refused because NO ticket key could be derived — not from the PR branch, not from its title, not from the build record. The stale PR (${url:--no url}) is already closed, so nothing owns this ticket until somebody names it. Record: ${rec:--none}. Fix: re-enqueue the ticket by key." >/dev/null 2>&1 || true
}

# br_key_in_only <owner/repo#n> — rc 0 when this run may look at the key: a
# whole-fleet scan looks at every key, a project run only at its project's.
# Asked BEFORE any GitHub read or claim on a conductor key (BH-5913 audit): the
# hand-off loop read every repo's PRs, on whatever credential the run held, and
# only br_conductor_emit dropped the other projects afterwards. Memoised per repo.
br_key_in_only() {
  local slug="${1%%#*}" p
  [ -n "$ONLY" ] || return 0
  if [ -z "${_BR_ONLY_REPO[$slug]+x}" ]; then
    p=$("$H/bin/project-of.sh" --repo "$slug" 2>/dev/null) || p=""
    _BR_ONLY_REPO[$slug]="$p"
  fi
  [ "${_BR_ONLY_REPO[$slug]}" = "$ONLY" ]
}
