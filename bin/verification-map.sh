#!/bin/bash
# bin/verification-map.sh — the per-project verification map, made consumable.
#
#   verification-map.sh render <project> [--repo <path>] [--hotspots-out <path>]
#                              [--contracts-out <path>]
#   verification-map.sh orient <project> [--repo <path>]
#
# WHAT THIS FILLS. Since July, run-build.sh's PLAN prompt and run-preplan.sh have
# both told the planner: "if /root/harness/state/<project>-context.md exists,
# read it FIRST — it is the project primer". Nothing has ever written that file.
# `render` writes it, which is why this needs no prompt change to be consumed.
#
# THE RULE IT INHERITS (bin/triage-map.sh, verbatim in spirit): nothing here is
# hand-written prose about the app. A hand-maintained map goes stale and then
# LIES, which is worse than no map. Every section below is copied at render time
# out of a real file in the project's own checkout and CITES that file, or it
# reports the file missing and says so in one line that starts with the word
# every consumer greps for. There is no third state where the renderer fills a
# gap with something plausible — that is the whole point.
#
# THREE OUTCOMES, NEVER TWO, in both verbs:
#   render — a section is either sourced (cited) or reported missing. rc 0 means
#            a primer was written; rc 1 means none was (no checkout, unwritable
#            state dir) and the caller must say "no map" out loud rather than
#            silently proceeding as if one existed.
#   orient — AVAILABLE / STALE / NOT AVAILABLE, one deterministic first line for
#            prompt injection, mirroring bin/codegraph-ensure.sh's contract. It
#            always exits 0: an orientation line is never a gate.
#
# STALENESS is an mtime comparison inside the checkout (newest file under the map
# vs newest file under the route globs). It is cheap and it is a heuristic — a
# fresh clone has uniform mtimes — so the STALE line says so and asks for a
# verify rather than claiming drift it cannot prove. The mechanical enforcement
# lives where it belongs, in CI: guardrails/verification-map-freshness fails a PR
# that changes routes without touching the map.
#
# WHAT USUALLY LIES (BH-2005.1). render also copies every entry's
# `**What usually lies:**` bullets (read by vmap_lies in bin/lib/vmap-entry.sh,
# flat and entries/ layouts) under a `<map>/<entry>:<line>` citation, then one
# `ABSENT: n of m entries ...` line naming the entries without the field. The
# block is capped at VMAP_LIES_CAP_BYTES (default 4000), hits first, so the cap
# cuts names off the ABSENT line before it cuts a bullet.
#
# CONFLICT HOTSPOTS. render also prints the project's measured hotspot files
# (bin/lib/hotspot-context.sh, from the conflict_hotspots rows) and, with
# --hotspots-out <path>, writes their paths one per line for bin/plan-gate.sh.
# The file is removed whenever no measurement was read. A hotspot read never
# changes the render's rc.
#
# SHARED CONTRACTS. render also prints the repo's own catalog/shared-contracts.d/
# rows (bin/lib/shared-contracts.sh) with a citation each, and with
# --contracts-out <path> writes them for bin/plan-gate.sh (`# repo:` line, then
# one row per contract). The file is removed whenever the lib did not load. A
# contract read never changes the render's rc.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
# Relative to this script, not $HARNESS: a test points HARNESS at a scratch
# tree, and in production the two ship side by side in bin/. No exit on failure:
# a primer without this one section beats no primer, and the section says
# COULD NOT READ rather than claiming the repo has no field.
# shellcheck source=lib/vmap-entry.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/vmap-entry.sh" 2>/dev/null && VMAP_LIB=ok || VMAP_LIB=missing
# shellcheck source=lib/hotspot-context.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/hotspot-context.sh" 2>/dev/null && HC_LIB=ok || HC_LIB=missing
# shellcheck source=lib/shared-contracts.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/shared-contracts.sh" 2>/dev/null && SC_LIB=ok || SC_LIB=missing

VERB="${1:-}"; PROJECT="${2:-}"
case "$VERB" in render|orient) ;; *) echo "usage: verification-map.sh <render|orient> <project> [--repo <path>]" >&2; exit 2 ;; esac
[ -n "$PROJECT" ] || { echo "usage: verification-map.sh $VERB <project> [--repo <path>]" >&2; exit 2; }
shift 2
REPO=""; HOTSPOTS_OUT=""; CONTRACTS_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --hotspots-out) HOTSPOTS_OUT="${2:-}"; shift 2 ;;
    --contracts-out) CONTRACTS_OUT="${2:-}"; shift 2 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
done
# Same resolution run-build.sh uses for a project's checkout; --repo is how a
# test (or a worktree-scoped build) points it somewhere real instead.
REPO="${REPO:-${VMAP_REPO:-/root/repos/$PROJECT}}"
MAP_REL="${VMAP_MAP_PREFIX:-docs/verification-map}"
MAP_REL="${MAP_REL%/}"
MAPDIR="$REPO/$MAP_REL"
ROUTE_GLOBS="${VMAP_ROUTE_GLOBS:-src/app/* app/* pages/* src/pages/*}"
CAP="${VMAP_CAP_BYTES:-12000}"
LIES_CAP="${VMAP_LIES_CAP_BYTES:-4000}"
case "$LIES_CAP" in ''|*[!0-9]*) LIES_CAP=4000 ;; esac
STATE="$HARNESS/state/$PROJECT-context.md"

# ── derivation helpers ──────────────────────────────────────────────────────
# Feature entries: every .md under the map that is not the index or the template.
# Bare filenames, one per line — the index file itself carries the descriptions,
# and listing README.md here as if it were a feature would make every entry count
# quoted downstream wrong by one.
entries() {
  [ -d "$MAPDIR" ] || return 0
  find "$MAPDIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
    | sed 's|.*/||' \
    | grep -vxE 'README\.md|TEMPLATE\.md' \
    | LC_ALL=C sort
}
entry_count() { entries | grep -c . ; }

# Every entry file the WHAT USUALLY LIES section reads, repo-relative to
# $MAPDIR: the flat entries above plus the entries/ layout. entries() itself
# stays flat-only, because the FEATURE ENTRIES list and its count quote it.
lies_entries() {
  [ -d "$MAPDIR" ] || return 0
  { entries
    [ -d "$MAPDIR/entries" ] && find "$MAPDIR/entries" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sed 's|.*/|entries/|'
  } | LC_ALL=C sort
}

# head -c with an honest tail when it bites. A silently truncated primer would
# be a map that lies by omission.  cap_file <file> [cap bytes, default $CAP]
cap_file() {
  local f="$1" cap="${2:-$CAP}" size
  size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  head -c "$cap" "$f"
  if [ -n "$size" ] && [ "$size" -gt "$cap" ]; then
    printf '\n[TRUNCATED at %s of %s bytes by bin/verification-map.sh — open the file itself for the rest]\n' "$cap" "$size"
  fi
}

# Extract one section out of a markdown file: prints the 1-based line number of
# the section's first line, then the section body. rc 1 = no such section.
#   $1 file, $2 ERE matched case-insensitively against a heading/bold section head
#
# rc 0 = section found and printed.
# rc 1 = the file was READ and holds no such section — a fact about the repo.
# rc 2 = the tool could not read it (missing/unreadable file, or any unexpected
#        failure in here). NOT the same claim, and it must never be rendered as
#        one: "this repo does not state its test contract" is an assertion about
#        someone's repo, and a chmod or a crash never established it. Anything
#        other than 0/1 from this function — including a 127 from a missing
#        python3 — is treated by the caller as could-not-read.
section() {
  python3 - "$1" "$2" <<'PY'
import re, sys
try:
    path, pat = sys.argv[1], sys.argv[2]
    try:
        lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
    except FileNotFoundError:
        # The file is genuinely not there. That IS a fact about the repo, and
        # the honest render for it is ABSENT — not a tool failure.
        sys.exit(1)
    except OSError:
        # Unreadable for some other reason: permissions, a directory in its
        # place, an I/O error. We learned nothing about the repo's contents.
        sys.exit(2)
    rx = re.compile(pat, re.I)
    start = kind = None
    level = 6
    for i, l in enumerate(lines):
        # a markdown heading ...
        m = re.match(r'^(#{1,6})\s+(.*)$', l)
        if m and rx.search(m.group(2)):
            start, kind, level = i, 'heading', len(m.group(1)); break
        # ... or a **bold** section head, which is the shape project-2's
        # CLAUDE.md really uses. Matching only headings would render "missing"
        # on a repo that plainly has the block — a lie in the harmful direction.
        m = re.match(r'^\*\*([^*]+)\*\*', l)
        if m and rx.search(m.group(1)):
            start, kind = i, 'bold'; break
    if start is None:
        sys.exit(1)
    out = [lines[start]]
    for l in lines[start + 1:]:
        m = re.match(r'^(#{1,6})\s', l)
        # A SUBSECTION IS PART OF ITS SECTION. Breaking at any heading level
        # amputated a `## Verification Contract` at its first `### Commands` —
        # dropping the actual test commands, with no marker, under a banner
        # that tells the reader not to re-derive any of this. Only a heading at
        # the same level or higher ends the section.
        if m and (kind == 'bold' or len(m.group(1)) <= level):
            break
        if kind == 'bold' and re.match(r'^\*\*[^*]+\*\*', l):
            break
        if len(out) >= 80:
            out.append('[section truncated at 80 lines by bin/verification-map.sh]')
            break
        out.append(l)
    print(start + 1)
    print('\n'.join(out).strip())
except SystemExit:
    raise
except Exception:
    # An unexpected failure is a tool failure, never an absence claim.
    sys.exit(2)
PY
}

# stale_reason -> "<route file> (<how the comparison was made>)" or nothing.
#
# WHY NOT MTIME FIRST. A build runs in a `git worktree add` checkout, where every
# file is written at checkout time and the mtime ordering between the map and a
# route file is arbitrary — an mtime-only check renders STALE at random there,
# and a warning that fires at random is one the reader learns to ignore. So the
# primary signal is the LAST COMMIT that touched each side, which is a fact about
# the history rather than about when this checkout happened to be made. mtime is
# the fallback for a tree that is not a git repo at all.
stale_reason() {
  local mt rt dirs newer ref
  dirs=$(route_dirs)
  if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
     && [ "$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null)" != true ]; then
    mt=$(git -C "$REPO" log -1 --format=%ct -- "$MAP_REL" 2>/dev/null)
    # shellcheck disable=SC2086  # $dirs is a pathspec list on purpose
    rt=$(git -C "$REPO" log -1 --format=%ct -- $dirs 2>/dev/null)
    if [ -n "$mt" ] && [ -n "$rt" ]; then
      if [ "$rt" -gt "$mt" ]; then
        # shellcheck disable=SC2086
        newer=$(git -C "$REPO" log -1 --name-only --format= -- $dirs 2>/dev/null | grep -v '^$' | head -1)
        echo "${newer:-a route file} (last commit touching a route is newer than the last commit touching $MAP_REL/)"
      fi
      return 0
    fi
  fi
  # Fallback: an untracked map, a tree that is not a git repo, or a SHALLOW
  # clone — depth-1 history gives every file the same single commit, so the
  # commit-time comparison there can only ever answer "fresh". An unfalsifiable
  # AVAILABLE is the failure this whole file exists to avoid, so a truncated
  # history degrades to mtimes and the line says which signal it used.
  ref=$(newest_map_file)
  [ -n "$ref" ] || return 0
  newer=$(newer_route_than "$ref")
  [ -n "$newer" ] && echo "$newer (mtime: newer than every file under $MAP_REL/)"
  return 0
}

# route_dirs — the configured globs' parent directories, as a git pathspec list.
#
# GLOBBING IS OFF HERE ON PURPOSE (live bug, found in review). `for g in
# $ROUTE_GLOBS` word-splits AND pathname-expands in whatever directory the
# CALLER happens to be in — and run-build.sh cd's into the checkout before this
# runs. `src/app/*` therefore expanded to the route files that exist right now,
# the `${g%/\*}` strip found no trailing `/*` to remove, and the git pathspec
# silently became "currently-present top-level route files". A commit that
# DELETES a route matched none of them, so the same repo read AVAILABLE from
# inside and STALE from outside — and production is the inside caller.
# `set -f` around the loop keeps the globs as globs, which is what a pathspec
# wants anyway.
route_dirs() {
  local g d out=""
  set -f
  for g in $ROUTE_GLOBS; do d="${g%/\*}"; [ -n "$d" ] && out="$out $d"; done
  set +f
  echo "$out"
}

# A route/screen file newer than $1 (repo-relative), or nothing. Positional
# params rather than an array: the fleet's macOS side runs bash 3.2, where an
# empty array under `set -u` is itself an error.
newer_route_than() {
  local ref="$1"
  ( cd "$REPO" 2>/dev/null || exit 0
    [ -e "$ref" ] || exit 0
    set --
    # Only the INNER loop expands, and it expands here inside the repo, which is
    # the point of the cd. Splitting the configured list is not the same
    # operation as globbing it — see route_dirs() for what conflating them cost.
    set -f
    for g in $ROUTE_GLOBS; do
      set +f
      for p in $g; do [ -e "$p" ] && set -- "$@" "$p"; done
      set -f
    done
    set +f
    [ $# -gt 0 ] || exit 0
    find "$@" -type f -newer "$ref" -print 2>/dev/null | head -1 ) 2>/dev/null
}

# newest_map_file — path (repo-relative) of the most recently modified map file.
newest_map_file() {
  ( cd "$REPO" 2>/dev/null || exit 0
    find "$MAP_REL" -type f -name '*.md' -exec ls -t {} + 2>/dev/null | head -1 )
}

# ensure_index — build the map index if the repo GENERATES it and this checkout
#   has not got one yet.
#
#   WHY (BH-1175). The index became a generated, git-ignored file. This script
#   is run with `--repo "$WT"` — the BUILD WORKTREE that bin/run-build.sh cuts
#   with `git worktree add --detach`, which by definition carries no ignored
#   files. bin/harness-sync.sh regenerates the HARNESS checkout, not that
#   worktree, so without this line every cromford build from the first one
#   after that merge planned against "this repo has not adopted the verification
#   map" — for a map with 113 entries describing the very lanes it was about to
#   change. The primer's own preamble tells the model not to go looking for the
#   file elsewhere, so the model had no way back from the lie.
#
#   Best-effort and silent: the output is git-ignored, so this stages nothing
#   and dirties nothing. A repo with no generator (every target repo today) is
#   untouched, and a generator that fails leaves the honest ABSENT branches
#   below to say so.
ensure_index() {
  [ -d "$MAPDIR" ] || return 0
  [ -f "$MAPDIR/README.md" ] && return 0
  [ -x "$REPO/bin/verification-map-build.sh" ] || return 0
  "$REPO/bin/verification-map-build.sh" --repo "$REPO" >/dev/null 2>&1 || true
  return 0
}

# ── render ──────────────────────────────────────────────────────────────────
render() {
  [ -d "$REPO" ] || { echo "verification-map: no checkout at $REPO — no primer written" >&2; return 1; }
  ensure_index
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || { echo "verification-map: cannot create $(dirname "$STATE") — no primer written" >&2; return 1; }

  # The temp file lives in the STATE dir, not $TMPDIR: mv is only atomic within
  # a filesystem, and /tmp is a different one often enough (tmpfs, a separate
  # volume) that "compose then move" would silently degrade into a copy — which
  # is exactly the half-written primer the move exists to prevent.
  local tmp; tmp=$(mktemp "$(dirname "$STATE")/.vmap.XXXXXX") || { echo "verification-map: mktemp failed — no primer written" >&2; return 1; }
  # CONFLICT HOTSPOTS, composed before the block below: the Sources: line
  # carries its state (yes/none/never/off/unknown), and a bad-knob line must
  # reach stderr, which the block sends to /dev/null.
  local HC_BLK has_hot=unknown
  HC_BLK=$(mktemp "$(dirname "$STATE")/.vmap-hot.XXXXXX") || HC_BLK=""
  if [ "$HC_LIB" = ok ] && [ -n "$HC_BLK" ]; then
    hc_section "$PROJECT" "$HOTSPOTS_OUT" > "$HC_BLK" || true
    has_hot="${HC_STATE:-unknown}"
  else
    # hc_section did not run: no list was read, so none from an earlier render
    # may pass as current (lib missing OR the mktemp above failed).
    [ -n "$HOTSPOTS_OUT" ] && rm -f "$HOTSPOTS_OUT"
  fi
  # SHARED CONTRACTS, composed up front for the same reason: the Sources:
  # line carries its state (yes/no/bad/unknown).
  local SC_BLK has_sc=unknown
  SC_BLK=$(mktemp "$(dirname "$STATE")/.vmap-sc.XXXXXX") || SC_BLK=""
  if [ "$SC_LIB" = ok ] && [ -n "$SC_BLK" ]; then
    sc_section "$REPO" > "$SC_BLK" 2>/dev/null || true
    has_sc="${SC_STATE:-unknown}"
    if [ -n "$CONTRACTS_OUT" ] && ! sc_write "$REPO" "$CONTRACTS_OUT"; then
      rm -f "$CONTRACTS_OUT"
      echo "verification-map: could not write $CONTRACTS_OUT — the plan gate checks no shared contract" >&2
    fi
  else
    # No contract was read, so no file from an earlier render may pass as
    # current (lib missing OR the mktemp above failed).
    [ -n "$CONTRACTS_OUT" ] && rm -f "$CONTRACTS_OUT"
  fi
  # Composed into a temp file and moved into place: a planner reading a
  # half-written primer is a worse failure than reading none.
  {
    local sha branch n has_map has_conv has_vc has_arch has_lies
    sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
    branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
    n=$(entry_count)
    [ -d "$MAPDIR" ] && [ "$n" -gt 0 ] && has_map=yes || has_map=no
    has_conv=no; has_vc=no; has_arch=no
    [ -f "$REPO/AGENT_ARCHITECTURE.md" ] && has_arch=yes
    # Three states per extracted section: yes (sourced) / no (read it, not there)
    # / unknown (could not read it). Collapsing the third into the second turns a
    # chmod or a crash into a claim about someone's repo.
    local CONV_OUT VC_OUT CONV_RC VC_RC
    CONV_OUT=$(section "$MAPDIR/README.md" 'conventions' 2>/dev/null); CONV_RC=$?
    case "$CONV_RC" in 0) has_conv=yes ;; 1) has_conv=no ;; *) has_conv=unknown ;; esac
    VC_OUT=$(section "$REPO/CLAUDE.md" 'verification' 2>/dev/null); VC_RC=$?
    case "$VC_RC" in 0) has_vc=yes ;; 1) has_vc=no ;; *) has_vc=unknown ;; esac

    # WHAT USUALLY LIES is composed up front because the Sources: line needs
    # to know whether it found anything. yes = at least one entry's bullets
    # are cited / no = read, none found / unknown = the lib did not load.
    local LIES_BLK LIES_M=0 LIES_HITS=0 LIES_ABSENT="" rel body line
    LIES_BLK=$(mktemp "$(dirname "$STATE")/.vmap-lies.XXXXXX") || LIES_BLK=""
    if [ "$VMAP_LIB" != ok ] || [ -z "$LIES_BLK" ]; then
      has_lies=unknown
    else
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        LIES_M=$((LIES_M+1))
        body=$(vmap_lies "$MAPDIR/$rel")
        if [ -n "$body" ]; then
          line=$(awk -v h="**${VMAP_LIES_HEADING}:**" 'index($0,h)==1{print NR; exit}' "$MAPDIR/$rel")
          { echo "$MAP_REL/$rel:$line"; printf '%s\n' "$body"; } >> "$LIES_BLK"
          LIES_HITS=$((LIES_HITS+1))
        else
          LIES_ABSENT="$LIES_ABSENT $rel"
        fi
      done < <(lies_entries)
      if [ -n "$LIES_ABSENT" ]; then
        echo "ABSENT: $((LIES_M-LIES_HITS)) of $LIES_M entries carry no \"$VMAP_LIES_HEADING\" field:$LIES_ABSENT" >> "$LIES_BLK"
      fi
      [ "$LIES_HITS" -gt 0 ] && has_lies=yes || has_lies=no
    fi

    echo "=== PROJECT PRIMER: $PROJECT (deterministically rendered — do NOT re-derive any of this) ==="
    echo "Rendered $(date -u '+%Y-%m-%d %H:%M:%SZ') by bin/verification-map.sh from files in $REPO @ $branch $sha."
    echo "Every section below is copied out of a real file in that checkout and names it. A section that"
    echo "reports its source missing is stating a fact about this repo — it is not a gap to fill in with"
    echo "something plausible, and it is not an invitation to go hunting for the file elsewhere."
    echo "Sources: verification-map=$has_map driving-conventions=$has_conv claude-md-verification=$has_vc what-usually-lies=$has_lies agent-architecture=$has_arch shared-contracts=$has_sc conflict-hotspots=$has_hot"

    # ---- the map index -----------------------------------------------------
    echo
    if [ "$has_map" = yes ] && [ -f "$MAPDIR/README.md" ]; then
      echo "--- VERIFICATION MAP (source: $MAP_REL/README.md) ---"
      cap_file "$MAPDIR/README.md"
      echo
      echo "FEATURE ENTRIES ($n files under $MAP_REL/, listed by bin/verification-map.sh at render time):"
      entries | sed 's/^/  /'
      echo "Read the entry for the feature you are touching BEFORE discovering its screens yourself."
      echo "A change to a route or screen updates that entry in the SAME diff — the guardrail"
      echo "verification-map-freshness fails the PR otherwise."
    elif [ -d "$MAPDIR" ] && [ "$n" -gt 0 ]; then
      # ENTRIES BUT NO INDEX. The map IS adopted; only the generated index is
      # missing from this checkout, and ensure_index above could not build it.
      # Saying "not adopted" here (BH-1175) would tell every build to discover
      # the screens itself while 113 entries sit unread beside it.
      echo "--- VERIFICATION MAP (source: $MAP_REL/entries/ — the generated index is not in this checkout) ---"
      echo "$MAP_REL/README.md is a GENERATED index and is not committed; this checkout has not built one,"
      echo "so the table below is the entry list rather than the index."
      echo
      echo "FEATURE ENTRIES ($n files under $MAP_REL/, listed by bin/verification-map.sh at render time):"
      entries | sed 's/^/  /'
      echo "Read the entry for the feature you are touching BEFORE discovering its screens yourself."
    elif [ -d "$MAPDIR" ]; then
      echo "--- VERIFICATION MAP ---"
      echo "ABSENT: $MAP_REL/ exists in $REPO but holds no feature entries yet (adoption started, not finished)."
      echo "Discover the screens you need the usual way, and add the entry for the feature you touch."
    else
      echo "--- VERIFICATION MAP ---"
      echo "ABSENT: no $MAP_REL/ in $REPO. This repo has not adopted the verification map."
      echo "There is no map to consult and none to update: discover routes/screens the usual way and say"
      echo "so in the plan. Backfilling one is its own ticket (cromford docs/VMAP-BACKFILL-TICKET.md)."
    fi

    # ---- driving conventions ----------------------------------------------
    echo
    if [ "$has_conv" = yes ]; then
      echo "--- DRIVING CONVENTIONS (source: $MAP_REL/README.md:$(head -1 <<<"$CONV_OUT")) ---"
      tail -n +2 <<<"$CONV_OUT"
    elif [ "$has_conv" = unknown ]; then
      echo "--- DRIVING CONVENTIONS ---"
      echo "COULD NOT READ $MAP_REL/README.md (tool failure, not a statement about the repo)."
      echo "Whether this map states driving conventions is UNKNOWN — open the file yourself before"
      echo "concluding anything either way."
    else
      echo "--- DRIVING CONVENTIONS ---"
      if [ -f "$MAPDIR/README.md" ]; then
        echo "ABSENT: $MAP_REL/README.md carries no driving-conventions section in this repo."
      else
        echo "ABSENT: no driving-conventions section, because there is no $MAP_REL/README.md to carry one."
      fi
      echo "The harness template (cromford docs/verification-map/TEMPLATE.md) carries the conventions a"
      echo "map is expected to state; they are not copied in here, because a convention this repo never"
      echo "agreed to is exactly the kind of confident-sounding fiction this primer exists to avoid."
    fi

    # ---- what usually lies (BH-2005.1) ----------------------------------------
    echo
    if [ "$has_lies" = yes ]; then
      echo "--- WHAT USUALLY LIES (source: $MAP_REL/<entry>:<line>, one citation per entry below) ---"
      cap_file "$LIES_BLK" "$LIES_CAP"
    elif [ "$has_lies" = unknown ]; then
      echo "--- WHAT USUALLY LIES ---"
      echo "COULD NOT READ bin/lib/vmap-entry.sh (tool failure, not a statement about the repo)."
      echo "Whether this map's entries say what usually lies is UNKNOWN: read that field in the entry"
      echo "you touch yourself. (VMAP_LIES_HEADING lives in the lib, so it is not named here.)"
    elif [ "$LIES_M" -gt 0 ]; then
      echo "--- WHAT USUALLY LIES ---"
      cap_file "$LIES_BLK" "$LIES_CAP"
    else
      echo "--- WHAT USUALLY LIES ---"
      if [ -d "$MAPDIR" ]; then
        echo "ABSENT: no \"$VMAP_LIES_HEADING\" field to read, because $MAP_REL/ in $REPO holds no entries."
      else
        echo "ABSENT: no \"$VMAP_LIES_HEADING\" field to read, because there is no $MAP_REL/ entry in $REPO."
      fi
    fi
    [ -n "$LIES_BLK" ] && rm -f "$LIES_BLK"

    # ---- the repo's own verification contract ------------------------------
    echo
    if [ "$has_vc" = yes ]; then
      echo "--- VERIFICATION CONTRACT (source: CLAUDE.md:$(head -1 <<<"$VC_OUT")) ---"
      tail -n +2 <<<"$VC_OUT"
    elif [ "$has_vc" = unknown ]; then
      echo "--- VERIFICATION CONTRACT ---"
      echo "COULD NOT READ $REPO/CLAUDE.md (tool failure, not a statement about the repo)."
      echo "Whether this repo states a test contract is UNKNOWN. Read CLAUDE.md yourself before you"
      echo "decide what proves a change here — do not treat this as 'there is no contract'."
    else
      echo "--- VERIFICATION CONTRACT ---"
      if [ -f "$REPO/CLAUDE.md" ]; then
        echo "ABSENT: no Verification section in $REPO/CLAUDE.md — this repo does not state its test contract."
      else
        echo "ABSENT: no Verification contract, because there is no CLAUDE.md in $REPO at all."
      fi
      echo "Establish what proves a change here from the repo itself (its scripts, its CI) and say in the"
      echo "plan which suites you ran; do not assume another project's commands work in this one."
    fi

    # ---- agent-architecture contract (Wave C writes these) -----------------
    echo
    if [ "$has_arch" = yes ]; then
      echo "--- AGENT ARCHITECTURE (source: AGENT_ARCHITECTURE.md) ---"
      echo "Present ($(wc -l < "$REPO/AGENT_ARCHITECTURE.md" | tr -d ' ') lines). Sections:"
      grep -E '^#{1,6} ' "$REPO/AGENT_ARCHITECTURE.md" | head -20 | sed 's/^/  /'
      echo "Read it in full before a change that crosses module boundaries or adds a writer to shared state."
    else
      echo "--- AGENT ARCHITECTURE ---"
      echo "ABSENT: no AGENT_ARCHITECTURE.md in $REPO (the architecture-contract audit has not run here yet)."
    fi

    # ---- shared contracts (bin/lib/shared-contracts.sh) --------------------
    echo
    if [ "$SC_LIB" = ok ] && [ -n "$SC_BLK" ] && [ -s "$SC_BLK" ]; then
      cap_file "$SC_BLK"
    else
      echo "--- SHARED CONTRACTS ---"
      if [ "$SC_LIB" != ok ]; then
        echo "COULD NOT READ: bin/lib/shared-contracts.sh is not beside this script (tool failure, not \"no contracts\")."
      else
        echo "COULD NOT READ: the shared-contracts section came back empty (tool failure, not \"no contracts\")."
      fi
    fi
    [ -n "$SC_BLK" ] && rm -f "$SC_BLK"

    # ---- conflict hotspots (bin/lib/hotspot-context.sh) --------------------
    echo
    if [ "$HC_LIB" = ok ] && [ -n "$HC_BLK" ] && [ -s "$HC_BLK" ]; then
      cat "$HC_BLK"
    else
      echo "--- CONFLICT HOTSPOTS ---"
      if [ "$HC_LIB" != ok ]; then
        echo "COULD NOT READ: bin/lib/hotspot-context.sh is not beside this script (tool failure, not \"no hotspots\")."
      elif [ -z "$HC_BLK" ]; then
        echo "COULD NOT READ: mktemp failed for the hotspot section (tool failure, not \"no hotspots\")."
      else
        echo "COULD NOT READ: the hotspot section came back empty (tool failure, not \"no hotspots\")."
      fi
    fi
    [ -n "$HC_BLK" ] && rm -f "$HC_BLK"

    echo
    echo "=== END PROJECT PRIMER ==="
  } > "$tmp" 2>/dev/null

  [ -s "$tmp" ] || { rm -f "$tmp"; echo "verification-map: rendered nothing for $PROJECT — no primer written" >&2; return 1; }
  mv "$tmp" "$STATE" 2>/dev/null || { rm -f "$tmp"; echo "verification-map: cannot write $STATE — no primer written" >&2; return 1; }
  echo "verification-map: wrote $STATE ($(wc -c < "$STATE" | tr -d ' ') bytes, map entries: $(entry_count))"
  return 0
}

# ── orient ──────────────────────────────────────────────────────────────────
# ONE line for prompt injection, plus the two lines that make it actionable —
# the shape bin/codegraph-ensure.sh established and CC() already knows how to
# carry. Never a gate: every path exits 0.
orient() {
  local n
  ensure_index
  if [ ! -d "$REPO" ]; then
    echo "VERIFICATION MAP NOT AVAILABLE (no checkout at $REPO to read a map from)"
    echo "  Work from the repo you do have and say in the plan that no map was consulted."
    return 0
  fi
  if [ ! -d "$MAPDIR" ]; then
    echo "VERIFICATION MAP NOT AVAILABLE (no $MAP_REL/ in $REPO — this repo has not adopted the map)"
    echo "  Discover routes/screens the usual way; do not hunt for a map that is not there, and do not"
    echo "  invent one in passing. Backfilling it is its own ticket (docs/VMAP-BACKFILL-TICKET.md)."
    return 0
  fi
  n=$(entry_count)
  if [ "$n" = 0 ]; then
    echo "VERIFICATION MAP NOT AVAILABLE ($MAP_REL/ exists in $REPO but holds no feature entries)"
    echo "  Adoption started and did not finish. Add the entry for the feature you touch as part of this work."
    return 0
  fi

  local newer
  newer=$(stale_reason)
  if [ -n "$newer" ]; then
    echo "VERIFICATION MAP STALE ($n entries in $MAP_REL/ of $REPO; $newer — entries may lag the app)"
    echo "  Use it for orientation, then VERIFY each route and selector against the code before trusting it,"
    echo "  and update the entry you touch in this same change."
    echo "  (This compares last-commit times, falling back to mtimes off git: STALE is a prompt to check"
    echo "  rather than proof of drift. CI's verification-map-freshness guardrail is the real gate.)"
    return 0
  fi
  echo "VERIFICATION MAP AVAILABLE ($n entries in $MAP_REL/ of $REPO, index $MAP_REL/README.md)"
  echo "  Read the entry for the feature you touch BEFORE discovering its screens yourself: it carries the"
  echo "  nav path, routes, selectors and preconditions someone already established."
  [ -f "$STATE" ] && echo "  The same content plus this repo's verification contract is in the primer at $STATE."
  echo "  A change to a route or screen updates its entry in the SAME diff — CI's verification-map-freshness"
  echo "  guardrail fails the PR otherwise, and a map that lags the app is driven as if it were true."
  return 0
}

case "$VERB" in
  render) render ;;
  orient) orient ;;
esac
