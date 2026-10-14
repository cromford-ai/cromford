#!/bin/bash
# tests/docs-anchor-drift-test.sh — a file:line citation in prose is a fact with
# no owner, and this is the owner.
# Run from anywhere: bash tests/docs-anchor-drift-test.sh   (exit 0 = all pass)
#
# BH-661. bin/run-build.sh:78 was cited three times — in this repo's
# docs/BUILD-CONCURRENCY.md, in bin/concurrency-plan.sh and in
# bin/lib/build-caps.sh — as the line that answers QUEUED_FLY. It had not been
# that line for weeks; the enqueue block alone had grown by ~150 lines, and by
# the time the ticket was written even the ticket's own corrected numbers
# (112/215/220/470) had drifted again. Seventeen numeric citations across three
# files, all copied from one another, all wrong, and nothing anywhere could
# notice.
#
# So the rule this test enforces is: cite a MARKER, not a number.
#
#   anchor        `bin/run-build.sh` answers `RESULT "QUEUED_FLY $KEY"`
#   guarded       bin/run-build.sh:224 ("QUEUED_FLY")   <- resolved here, every run
#   unanchored    bin/run-build.sh:224                  <- a FAIL
#
# Two halves:
#   (1) the citation scan — every path.ext:N in the scanned files must carry a
#       quoted marker on the same line, and sed -n Np must actually contain it.
#       A bare (:N) or `:N` continuation is a FAIL on sight.
#   (2) the anchor table — the markers the prose leans on must still exist in
#       the scripts they name. This is the half that fires when someone renames
#       QUEUED_FLY or moves the pool stand-down, which is what made the numbers
#       wrong in the first place.
#
# Self-contained on purpose: it creates no files, runs no rm, sets no trap and
# never cd's, so it needs no scratch tree (checks/tests-scratch-only R1). No
# network, no clock, no randomness, no LLM.
set -uo pipefail
ROOT=$(readlink -f "$(dirname "$0")/..")

PASS=0; FAIL=0; CHECKS=0
ok()  { PASS=$((PASS+1)); CHECKS=$((CHECKS+1)); }
bad() { FAIL=$((FAIL+1)); CHECKS=$((CHECKS+1)); echo "FAIL: $1"; }

# ── the scanned set: the ticket's three files ────────────────────────────────
SCANNED=(
  docs/BUILD-CONCURRENCY.md
  bin/concurrency-plan.sh
  bin/lib/build-caps.sh
)

# ── the positive anchor table: marker<TAB>file ───────────────────────────────
# Every marker the prose in the scanned set now leans on instead of a number.
# If one of these disappears, the prose has drifted even though it holds no
# number at all — that is the whole point of trading numbers for markers.
# Since the BH-572 cut the build gates live in bin/lib/rb/gates.sh; only the
# per-key dedupe lock stayed in the driver itself.
ANCHORS=(
  'bin/lib/rb/gates.sh	RESULT "QUEUED_FLY $KEY"'
  'bin/lib/rb/gates.sh	flags/builder-fly-$PROJECT'
  'bin/lib/rb/gates.sh	flags/wip-limit-$PROJECT'
  'bin/lib/rb/gates.sh	locks/build-slot-$S.lock'
  'bin/run-build.sh	locks/build-key-$PROJECT-$KEY.lock'
  'bin/lib/rb/gates.sh	JOB_CLAIM=$(job_open'
  'bin/fly-dispatch.sh	flag_on fly-pool "$p" && return 0'
  'bin/fly-envbundle.sh	for v in CLAUDE_CODE_OAUTH_TOKEN'
  'bin/fly-envbundle.sh	die "bundle missing CLAUDE_CODE_OAUTH_TOKEN"'
  'bin/fly-envbundle.sh	die "bundle missing GH_TOKEN'
  'fly/builder-runner.sh	BUILDER_EXEC=1 BUILDER_NO_MERGE=1'
)

# ── the scanner ──────────────────────────────────────────────────────────────
# A citation is <path>.<ext>:<N> for an extension this repo actually writes.
# The extension list is what keeps dates (2026-09-13), issue refs (#368), cron
# fields (*/2) and ticket keys (TK-493) out of the match.
CITE_RE='([A-Za-z0-9_][A-Za-z0-9_./-]*\.(sh|md|js|ts|conf|cron|sql)):([0-9]+)'
# A continuation is the shorthand a second citation on the same line uses:
# (:171) in a shell comment, `:171` in markdown. It names no file, so it can
# never be resolved and is a FAIL on sight.
CONT_RE='[(`]:([0-9]+)[)`]'

# scan_line <lineno> <text> -> one "verdict<TAB>detail" per citation found
#   verdicts: resolves | drifted | drifted-missing-file | unanchored
scan_line() {
  local ln="$1" text="$2"
  local s="$text" cite path num rest window marker body

  while [[ $s =~ $CITE_RE ]]; do
    cite="${BASH_REMATCH[0]}"
    path="${BASH_REMATCH[1]}"
    num="${BASH_REMATCH[3]}"
    rest="${s#*"$cite"}"
    s="$rest"

    # The marker must sit between this citation and the next one on the line,
    # so a line with two citations cannot borrow the second one's marker.
    window="$rest"
    if [[ $rest =~ $CITE_RE ]]; then window="${rest%%"${BASH_REMATCH[0]}"*}"; fi

    marker=""
    if [[ $window =~ \(\"([^\"]+)\"\) ]]; then marker="${BASH_REMATCH[1]}"
    elif [[ $window =~ \(\`([^\`]+)\`\) ]]; then marker="${BASH_REMATCH[1]}"; fi

    if [ -z "$marker" ]; then
      printf 'unanchored\t%s\t%s\t%s\n' "$ln" "$cite" ""
      continue
    fi
    if [ ! -f "$ROOT/$path" ]; then
      printf 'drifted-missing-file\t%s\t%s\t%s\n' "$ln" "$cite" "$marker"
      continue
    fi
    body=$(sed -n "${num}p" "$ROOT/$path")
    if [ -n "$body" ] && grep -qF -- "$marker" <<<"$body"; then
      printf 'resolves\t%s\t%s\t%s\n' "$ln" "$cite" "$marker"
    else
      printf 'drifted\t%s\t%s\t%s\n' "$ln" "$cite" "$marker"
    fi
  done

  s="$text"
  while [[ $s =~ $CONT_RE ]]; do
    cite="${BASH_REMATCH[0]}"
    printf 'unanchored\t%s\t%s\t%s\n' "$ln" "$cite" ""
    s="${s#*"$cite"}"
  done
}

# ── (1) the citation scan over the scanned set ───────────────────────────────
for rel in "${SCANNED[@]}"; do
  if [ ! -r "$ROOT/$rel" ]; then
    bad "$rel:0 scanned file is missing or unreadable — the scan cannot be clean"
    continue
  fi
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    [[ "$line" == *:[0-9]* ]] || continue
    while IFS=$'\t' read -r verdict ln cite marker; do
      [ -n "$verdict" ] || continue
      case "$verdict" in
        resolves)
          ok ;;
        unanchored)
          bad "$rel:$ln unanchored line number (cite a marker instead): $cite" ;;
        drifted-missing-file)
          bad "$rel:$ln drifted (file missing): $cite (\"$marker\")" ;;
        drifted)
          bad "$rel:$ln drifted: $cite does not contain \"$marker\"" ;;
      esac
    done < <(scan_line "$n" "$line")
  done < "$ROOT/$rel"
done

# ── (2) the positive anchor table ────────────────────────────────────────────
for row in "${ANCHORS[@]}"; do
  f="${row%%$'\t'*}"; m="${row#*$'\t'}"
  if [ ! -r "$ROOT/$f" ]; then
    bad "$f:0 anchor gone (file missing): \"$m\""
  elif grep -qF -- "$m" "$ROOT/$f"; then
    ok
  else
    bad "$f:0 anchor gone: \"$m\" is no longer in the file"
  fi
done

# ── (3) the scanner's own self-check ─────────────────────────────────────────
# Each verdict must be reachable, and the resolve branch must be exercised by a
# line the scanner really parses — otherwise a scanner that matched nothing
# would report a clean tree (D1/D4). Fixtures are here-strings, never files.
verdict_of() { scan_line 1 "$1" | head -1 | cut -f1; }

fixture() { # fixture <expected-verdict> <line>
  local want="$1" got
  got=$(verdict_of "$2")
  if [ "$got" = "$want" ]; then ok
  else bad "self-check: expected '$want', got '${got:-<nothing>}' for: $2"; fi
}
fixture resolves             'bin/run-build.sh:1 ("#!/bin/bash")'
fixture drifted              'bin/run-build.sh:1 ("QUEUED_FLY")'
fixture unanchored           'bin/run-build.sh:1'
fixture drifted-missing-file 'bin/no-such-script.sh:1 ("x")'
fixture unanchored           'and above the wip gate (:171), which is a continuation'

# A run that performed no checks at all is not a clean tree.
if [ "$CHECKS" -eq 0 ]; then
  echo "FAIL: scanner matched nothing — no citation, no anchor, no fixture was checked"
  FAIL=$((FAIL+1))
fi

echo "PASS $PASS / FAIL $FAIL"
[ "$FAIL" -eq 0 ]
