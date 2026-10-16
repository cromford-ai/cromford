#!/bin/bash
# bin/nightly-ticket.sh <verdict-dir> — a red nightly run OPENS TICKETS
# (2026-09-28, the nightly tier; one issue per failing suite since BH-6838).
#
# .github/workflows/harness-nightly.yml calls this whenever the nightly run on
# main is red. A nightly red never blocks a merge: it files the red where the
# fleet's work comes from — issues on this repository.
#
# ONE ISSUE PER FAILING SUITE (BH-6838). It reads the shard logs the nightly
# shards upload next to their verdicts (`shard-<i>.log`,
# bin/test-trace-safety.sh --gate output). A `--- <suite> rc=<n> <s>s` line
# with n != 0, in the log of a shard that left its verdict (`shard-<i>.txt`),
# is a failed suite. For each one, sorted:
#   - the OPEN issues (every page; pull requests skipped) are searched for the
#     marker `<!-- harness-nightly-red:<suite> -->`. Found: one comment (sha,
#     run url, range) on the lowest-numbered match. Not found: a new issue
#     `Nightly: <suite> red on main`, labelled ai-build, whose body has the run
#     url, the sha, the range NT_LAST_GREEN..NT_SHA with its compare link, at
#     most 30 commit subjects of that range (local `git log`, NT_GIT_DIR or the
#     cwd; said when it cannot be read) and the suite's log tail.
#   - at most NT_MAX_NEW (default 10) new issues a run. A suite past the cap is
#     an `over-cap` row, listed on the run-level ticket.
#   - a search that is not a clean read is a `skipped-unreadable` row: nothing
#     is filed for that suite (no blind create, no blind comment). The suite is
#     named on the run-level ticket.
# With no NT_LAST_GREEN the range is `<sha>~20..<sha>`, and the body says so.
#
# NOT a per-suite red (the negative list): a `--- <suite> rc=0` line; a suite
# with ANY rc=0 line (it passed on a retry); a failed line in the log of a shard
# that left no verdict (cancelled, timed out: that shard is named on the
# run-level ticket instead); a trace line that is not `HIT `.
#
# THE RUN-LEVEL TICKET keeps the old marker `<!-- harness-nightly-red -->` and
# title, and is filed (an open one gets a comment) only when the run has a red
# that is not a suite: a failed plan, a shard with no verdict, a trace HIT, a
# red strict ratchet pass (strict.md, quoted whole), a red nightly lint pass
# (lints.md, quoted whole), an over-cap or unsearchable suite, or a red run
# with no failing suite to blame (never goes quiet).
#
# Every decision is one row in <verdict-dir>/ticket-requests.tsv (rewritten
# each run): `suite<TAB>range<TAB>action<TAB>url`, action one of
# new|comment|over-cap|skipped-unreadable|run-level, url `-` when none (the
# run-level row's suite is `-`). A row is written AFTER GitHub answers; a
# refused create or comment writes no row. stderr ends with
# `nightly-ticket: filed <k> new, <c> comments, <o> over cap`.
#
# Environment: NT_REPO (owner/name), NT_RUN_URL, NT_SHA, NT_LAST_GREEN (sha of
# the last green nightly; empty = none recorded), NT_MAX_NEW, NT_PLAN_RESULT,
# NT_STRICT_RESULT, NT_PLAN_N (the shard count the plan published),
# NT_GIT_DIR (the checkout for the commit subjects; default the cwd),
# NT_SERVER_URL (default https://github.com), NT_GH (the gh binary; the test
# seam), GH_TOKEN (the workflow's own token — issues: write, nothing else),
# NT_APP_TOKEN (the harness App installation token, cromford[bot]).
# The create call and its label call run as NT_APP_TOKEN when it is set, so the
# `labeled ai-build` actor is one the trigger-actor gate accepts
# (bin/lib/trigger-actor.sh); the workflow token's actor, github-actions[bot],
# is refused there. Reads and comments keep GH_TOKEN. With NT_APP_TOKEN empty
# the create runs as GH_TOKEN, as before, and stderr says so once.
# NT_MAX_NEW is a workflow env with this code default: settings rows are not
# readable inside a GitHub workflow.
# A new issue is opened labelled `ai-build` (BH-3411); a comment on an open one
# never adds or re-adds the label, so a ticket a person unlabelled stays so.
# rc 0 when every needed ticket was filed or updated, 1 when GitHub refused a
# read the run-level ticket needed or any write (including a new issue that
# could not be labelled ai-build), 2 on usage.
set -uo pipefail
VDIR="${1:-}"
[ -n "$VDIR" ] || { echo "nightly-ticket: usage: $0 <verdict-dir>" >&2; exit 2; }
REPO="${NT_REPO:-}"
[ -n "$REPO" ] || { echo "nightly-ticket: NT_REPO is not set" >&2; exit 2; }
GH="${NT_GH:-gh}"
MARK="<!-- harness-nightly-red -->"
TITLE="Nightly test tier is red on main"
SHA="${NT_SHA:-main}"
SERVER="${NT_SERVER_URL:-https://github.com}"
MAX_NEW="${NT_MAX_NEW:-10}"
case "$MAX_NEW" in
  ''|*[!0-9]*) echo "nightly-ticket: NT_MAX_NEW='$MAX_NEW' is not an integer; using the default 10" >&2; MAX_NEW=10 ;;
esac
MAX_NEW=$((10#$MAX_NEW))
if [ -n "${NT_LAST_GREEN:-}" ]; then FROM="$NT_LAST_GREEN"; FALLBACK=0
else FROM="$SHA~20"; FALLBACK=1
fi
RANGE="$FROM..$SHA"
COMPARE="$SERVER/$REPO/compare/$FROM...$SHA"
REQ="$VDIR/ticket-requests.tsv"
mkdir -p "$VDIR" 2>/dev/null; : > "$REQ" 2>/dev/null || { echo "nightly-ticket: cannot write $REQ" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nightly-ticket.XXXXXX") || { echo "nightly-ticket: no temp dir" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
RC=0
row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:--}" >> "$REQ"; }

# ── read the shard logs ─────────────────────────────────────────────────────
# $WORK/lines: <suite> <rc> <shard> <finished 1|0>, one per `--- ` line.
: > "$WORK/lines"
for f in "$VDIR"/shard-*.log; do
  [ -e "$f" ] || continue
  i="${f##*/shard-}"; i="${i%.log}"
  fin=0; [ -r "$VDIR/shard-$i.txt" ] && fin=1
  sed -n 's/^--- \(tests\/[A-Za-z0-9._/-]*\) rc=\([0-9][0-9]*\)\( .*\)\{0,1\}$/\1 \2/p' "$f" \
    | while read -r s r; do printf '%s %s %s %s\n' "$s" "$r" "$i" "$fin"; done >> "$WORK/lines"
done
PASSED=$(awk '$2 == 0 { print $1 }' "$WORK/lines" | LC_ALL=C sort -u)
notpassed() { awk 'NR == FNR { p[$1] = 1; next } !($1 in p)' <(printf '%s\n' "$PASSED") -; }
# A failed suite: nonzero in a finished shard, never green. First shard wins.
awk '$2 != 0 && $4 == 1' "$WORK/lines" | notpassed | LC_ALL=C sort -k1,1 -s | awk '!seen[$1]++' > "$WORK/failed"
# Nonzero only in a shard that did not finish: named on the run-level ticket.
awk '$2 != 0 && $4 == 0' "$WORK/lines" | notpassed \
  | awk 'NR == FNR { f[$1] = 1; next } !($1 in f)' "$WORK/failed" - | LC_ALL=C sort -u -k1,1 > "$WORK/unfinished"
HITS=$(cat "$VDIR"/shard-*.log 2>/dev/null | sed -n 's/^HIT \([^ ]*\) .*/\1/p' | LC_ALL=C sort -u)
MISSING=""
N="${NT_PLAN_N:-0}"; case "$N" in ''|*[!0-9]*) N=0 ;; esac
for ((i = 0; i < N; i++)); do
  [ -r "$VDIR/shard-$i.txt" ] || MISSING="$MISSING $i"
done
for f in "$VDIR"/shard-*.log; do
  [ -e "$f" ] || continue
  i="${f##*/shard-}"; i="${i%.log}"
  [ -r "$VDIR/shard-$i.txt" ] && continue
  case " $MISSING " in *" $i "*) ;; *) MISSING="$MISSING $i" ;; esac
done

# log_tail <shard> <suite> — the suite's own output: the lines after its `---`
# line up to the next suite or the scan's summary, last 40, 300 chars a line.
log_tail() {
  awk -v s="$2" '
    index($0, "--- " s " rc=") == 1 { on = 1; next }
    on && (/^--- tests\// || /^TRACE: / || /^GATE: /) { on = 0 }
    on { print }' "$VDIR/shard-$1.log" 2>/dev/null | tail -n 40 | cut -c1-300 | sed 's/```/'"'''"'/g'
}

# The commit subjects of the range, read once.
COMMITS=""; COMMITS_OK=0; TOTAL=""
GITDIR="${NT_GIT_DIR:-.}"
if COMMITS=$(git -C "$GITDIR" log --format='%h %s' -n 30 --end-of-options "$RANGE" -- 2>/dev/null); then
  COMMITS_OK=1
  TOTAL=$(git -C "$GITDIR" rev-list --count --end-of-options "$RANGE" -- 2>/dev/null) || TOTAL=""
fi

range_text() {
  printf 'Range: `%s` (%s)\n' "$RANGE" "$COMPARE"
  [ "$FALLBACK" = 0 ] || printf 'No green nightly is recorded (NT_LAST_GREEN is empty), so the range is the 20 commits before `%s`.\n' "$SHA"
}

# search <marker> — open issue numbers carrying <marker>, every page. rc 1 on
# a read that is not clean (gh failed, or an answer that is not numbers).
search() {
  local out
  out=$("$GH" api --paginate "repos/$REPO/issues?state=open&per_page=100" \
          --jq ".[] | select(.pull_request == null) | select((.body // \"\") | contains(\"$1\")) | .number" 2>/dev/null) || return 1
  grep -qvE '^([0-9]+)?$' <<<"$out" && return 1
  printf '%s\n' "$out" | grep -E '^[0-9]+$' | sort -n | head -1
  return 0
}

# create <title> <body-file> — open an issue labelled ai-build; prints the
# number. GitHub drops labels on create, silently, for a caller without push
# access, so the answer is read back and a dropped label is added once.
# rc 1 no issue; rc 3 issue opened (number printed) but not labelled.
create() {
  local resp num
  resp=$(wgh api -X POST "repos/$REPO/issues" -f "title=$1" -F "body=@$2" -f 'labels[]=ai-build' \
           --jq '"\(.number) \([.labels[]?.name] | index("ai-build") != null)"') || return 1
  num="${resp%% *}"
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$num"
  if [ "${resp##* }" != true ]; then
    wgh api -X POST "repos/$REPO/issues/$num/labels" -f 'labels[]=ai-build' >/dev/null || return 3
  fi
  return 0
}

# wgh <gh args> — the two writes that set the label actor: as the App when
# NT_APP_TOKEN is set. Without it, the workflow token, and one warning per run
# (a marker file, because create runs in a command substitution). A refused App
# call is not retried as the workflow token: that is the label the gate refuses.
wgh() {
  if [ -n "${NT_APP_TOKEN:-}" ]; then GH_TOKEN="$NT_APP_TOKEN" "$GH" "$@"; return; fi
  if [ ! -e "$WORK/app-token-warned" ]; then
    : > "$WORK/app-token-warned"
    echo "nightly-ticket: NT_APP_TOKEN not set; filing as the workflow token, and the trigger-actor gate refuses that label" >&2
    [ "${GITHUB_ACTIONS:-}" = true ] && echo "::warning::nightly-ticket: NT_APP_TOKEN not set; the ai-build label is added by github-actions[bot], which the trigger-actor gate refuses" >&2
  fi
  "$GH" "$@"
}

# ── one issue per failing suite ─────────────────────────────────────────────
NEWN=0; COMN=0; OVER=0
: > "$WORK/overcap"; : > "$WORK/unreadable"; : > "$WORK/done"
while read -r SUITE SRC SHARD _; do
  [ -n "$SUITE" ] || continue
  SMARK="<!-- harness-nightly-red:$SUITE -->"
  if ! NUM=$(search "$SMARK"); then
    echo "nightly-ticket: the open-issue search for $SUITE did not read cleanly; nothing filed for it" >&2
    row "$SUITE" "$RANGE" skipped-unreadable -
    printf '%s (rc %s)\n' "$SUITE" "$SRC" >> "$WORK/unreadable"
    continue
  fi
  if [ -n "$NUM" ]; then
    {
      printf 'Still red on `%s`: `%s` (rc %s).\n\n' "$SHA" "$SUITE" "$SRC"
      printf 'Run: %s\n' "${NT_RUN_URL:-(no run url)}"
      range_text
    } > "$WORK/comment.md"
    if "$GH" api -X POST "repos/$REPO/issues/$NUM/comments" -F "body=@$WORK/comment.md" >/dev/null; then
      row "$SUITE" "$RANGE" comment "$SERVER/$REPO/issues/$NUM"
      COMN=$((COMN + 1))
      echo "nightly-ticket: updated #$NUM"
      printf '%s (rc %s): comment on %s\n' "$SUITE" "$SRC" "$SERVER/$REPO/issues/$NUM" >> "$WORK/done"
    else
      echo "nightly-ticket: could not comment on #$NUM for $SUITE" >&2; RC=1
    fi
    continue
  fi
  if [ "$NEWN" -ge "$MAX_NEW" ]; then
    printf '%s (rc %s)\n' "$SUITE" "$SRC" >> "$WORK/overcap"
    continue
  fi
  {
    printf '%s\n' "$SMARK"
    printf 'The nightly run on main is red for `%s` (rc %s) on `%s`.\n\n' "$SUITE" "$SRC" "$SHA"
    printf 'Run: %s\n' "${NT_RUN_URL:-(no run url)}"
    range_text
    printf '\n'
    if [ "$COMMITS_OK" = 1 ] && [ -n "$COMMITS" ]; then
      if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 30 ] 2>/dev/null; then printf 'Commits in the range (the newest 30 of %s):\n' "$TOTAL"
      else printf 'Commits in the range:\n'
      fi
      printf '%s\n' "$COMMITS" | sed 's/^/- /'
    else
      printf 'The commit subjects of `%s` could not be read from the checkout (shallow clone or unknown sha); open the compare link.\n' "$RANGE"
    fi
    printf '\nLog tail (shard %s):\n```\n' "$SHARD"
    log_tail "$SHARD" "$SUITE"
    printf '```\n\nFix the suite or the code. A nightly red never blocks a merge; this issue is the only place it shows up.\n'
  } > "$WORK/suite.md"
  NUM=$(create "Nightly: $SUITE red on main" "$WORK/suite.md"); CRC=$?
  if [ "$CRC" = 1 ]; then
    echo "nightly-ticket: could not open an issue on $REPO for $SUITE" >&2; RC=1; continue
  fi
  row "$SUITE" "$RANGE" new "$SERVER/$REPO/issues/$NUM"
  NEWN=$((NEWN + 1))
  printf '%s (rc %s): new %s\n' "$SUITE" "$SRC" "$SERVER/$REPO/issues/$NUM" >> "$WORK/done"
  if [ "$CRC" = 3 ]; then
    echo "nightly-ticket: opened #$NUM but could not label it ai-build" >&2; RC=1
  else
    echo "nightly-ticket: opened #$NUM"
  fi
done < "$WORK/failed"
OVER=$(grep -c . "$WORK/overcap")

# ── the run-level ticket ────────────────────────────────────────────────────
PLAN_OK=1; [ "${NT_PLAN_RESULT:-success}" = success ] || PLAN_OK=0
STRICT_RED=0; { [ -s "$VDIR/strict.md" ] || [ "${NT_STRICT_RESULT:-success}" != success ]; } && STRICT_RED=1
NEED=0
{ [ "$PLAN_OK" = 0 ] || [ -n "$MISSING$HITS" ] || [ "$STRICT_RED" = 1 ] || [ -s "$VDIR/lints.md" ] \
  || [ -s "$WORK/overcap" ] || [ -s "$WORK/unreadable" ] || [ ! -s "$WORK/failed" ]; } && NEED=1

if [ "$NEED" = 1 ]; then
  BODY_FILE="$WORK/run.md"
  {
    printf '%s\n' "$MARK"
    printf 'The nightly run on main failed on `%s`.\n\n' "$SHA"
    printf 'Run: %s\n' "${NT_RUN_URL:-(no run url)}"
    range_text
    printf '\n'
    if [ -s "$WORK/done" ]; then
      printf 'Failing suites with their own issue:\n'; sed 's/^\([^ ]*\) (rc/- `\1` (rc/' "$WORK/done"; printf '\n'
    fi
    if [ -s "$WORK/overcap" ]; then
      printf 'Failing suites over the cap of %s new issues a run (NT_MAX_NEW), not filed tonight:\n' "$MAX_NEW"
      sed 's/^\([^ ]*\) (rc/- `\1` (rc/' "$WORK/overcap"; printf '\n'
    fi
    if [ -s "$WORK/unreadable" ]; then
      printf 'Failing suites whose open-issue search did not read cleanly, so nothing was filed for them:\n'
      sed 's/^\([^ ]*\) (rc/- `\1` (rc/' "$WORK/unreadable"; printf '\n'
    fi
    if [ -s "$WORK/unfinished" ]; then
      printf 'Failed in a shard that did not finish (not filed per suite):\n'
      awk '{ printf "- `%s` (rc %s, shard %s)\n", $1, $2, $3 }' "$WORK/unfinished"; printf '\n'
    fi
    if [ -n "$HITS" ]; then
      printf 'Trace hits (a test deleted or redirected outside a temp root):\n'; printf '%s\n' "$HITS" | sed 's/^/- `/; s/$/`/'; printf '\n'
    fi
    if [ -s "$VDIR/strict.md" ]; then
      printf 'Strict ratchets (the whole tree against its baseline; catalog/nightly-strict.txt):\n\n'; cat "$VDIR/strict.md"; printf '\n'
    elif [ "${NT_STRICT_RESULT:-success}" != success ]; then
      printf 'The strict ratchet pass did not succeed (%s) and left no summary.\n\n' "${NT_STRICT_RESULT:-}"
    fi
    if [ -s "$VDIR/lints.md" ]; then
      printf 'Nightly lints (the strict lints that no longer block a PR):\n\n'; cat "$VDIR/lints.md"; printf '\n'
    fi
    [ "$PLAN_OK" = 1 ] || printf 'The plan job did not succeed (%s), so no suite ran.\n\n' "${NT_PLAN_RESULT:-}"
    [ -z "$MISSING" ] || printf 'Shard(s)%s left no verdict: the job died, timed out or was cancelled before its scan finished.\n\n' "$MISSING"
    if [ ! -s "$WORK/failed" ] && [ -z "$HITS$MISSING" ] && [ "$PLAN_OK" = 1 ] \
       && [ "$STRICT_RED" = 0 ] && [ ! -s "$VDIR/lints.md" ]; then
      printf 'No failing suite could be read from the shard logs; open the run.\n\n'
    fi
    printf 'A nightly red never blocks a merge, so this ticket is the only place this red shows up. Fix the suite or the code.\n'
  } > "$BODY_FILE"

  # EVERY page of the open items, not the first: issues?state=open lists pull
  # requests too, and a repo with 100+ newer open items would push the ticket
  # off page 1 and open a duplicate every night. gh applies --jq to each page.
  RURL=""
  if ! OPEN=$("$GH" api --paginate "repos/$REPO/issues?state=open&per_page=100" \
           --jq ".[] | select(.pull_request == null) | select((.body // \"\") | contains(\"$MARK\")) | .number" 2>/dev/null); then
    echo "nightly-ticket: could not list the open issues of $REPO" >&2; RC=1
  else
    RNUM=$(printf '%s\n' "$OPEN" | grep -E '^[0-9]+$' | head -1)
    if [ -n "$RNUM" ]; then
      if "$GH" api -X POST "repos/$REPO/issues/$RNUM/comments" -F "body=@$BODY_FILE" >/dev/null; then
        RURL="$SERVER/$REPO/issues/$RNUM"; echo "nightly-ticket: updated #$RNUM"
      else
        echo "nightly-ticket: could not comment on #$RNUM" >&2; RC=1
      fi
    else
      RNUM=$(create "$TITLE" "$BODY_FILE"); CRC=$?
      if [ "$CRC" = 1 ]; then
        echo "nightly-ticket: could not open an issue on $REPO" >&2; RC=1
      else
        RURL="$SERVER/$REPO/issues/$RNUM"
        if [ "$CRC" = 3 ]; then echo "nightly-ticket: opened #$RNUM but could not label it ai-build" >&2; RC=1
        else echo "nightly-ticket: opened #$RNUM"
        fi
      fi
    fi
  fi
  [ -z "$RURL" ] || row - "$RANGE" run-level "$RURL"
  # Over-cap rows point at the run-level ticket that lists them, written after
  # GitHub answered for it (`-` when it refused).
  while read -r s _; do [ -n "$s" ] && row "$s" "$RANGE" over-cap "${RURL:--}"; done < "$WORK/overcap"
fi

echo "nightly-ticket: filed $NEWN new, $COMN comments, $OVER over cap" >&2
exit "$RC"
