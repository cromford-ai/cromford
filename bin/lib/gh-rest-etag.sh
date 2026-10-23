#!/bin/bash
# bin/lib/gh-rest-etag.sh — persisted ETag cache for bin/lib/gh-rest.sh's `gh_rest`
# GET reads. Sourced by gh-rest.sh, never executed.
#
# WHY A SECOND FILE (BH-1295, same reasoning as bin/lib/gh-rest-list.sh's own
# header). gh-rest.sh is a CONTRACT file: tests/gh-rest-lib-test.sh holds it
# to its contract functions on purpose (a code-line ceiling until BH-5228), so the next caller-conversion
# cannot quietly grow a contract file into a lane. Key hashing, the on-disk
# format, and the TTL/size sweep are a lane's worth of code, so they live here;
# gh_rest() calls back into a handful of small functions this file defines.
#
# THE INCIDENT (#1279/#1295, 2026-09-21). The App installation (161623167,
# 6,600 req/h, shared by every hub lane and every pool machine) hit its limit
# twice in one day. logs/gh-rate.log named `gh_rest`'s own GET reads as the
# burst: merge-conductor's steady-state PR-state reads and gh-pr-list's
# closed-PR pages, tick after tick, the vast majority answering a body that had
# not changed since the last read. `If-None-Match` turns an unchanged read into
# a 304, which GitHub does not count against the primary rate limit — but
# gh-rest.sh mapped a 304 to rc 75 (UNVERIFIABLE) before this file existed, so
# nothing benefited from asking conditionally even when a caller did.
#
# ON-DISK FORMAT. One file per key, not two: state/gh-etag/<sha1> holds the
# ETag on line 1 and the response body on every line after. A caller that hits
# needs exactly one read to answer both "is there a cached etag to send" and
# "what do I replay on a 304" — two files would mean two reads plus a way for
# them to go out of sync (an etag file with no body file, or the reverse) that
# a single file cannot represent.
#
# WHAT IS CACHED. GET only, keyed on a sha1 of method + path + every extra arg
# gh_rest was called with (accept headers, -f/-F query params — NOT identity:
# no token, no GH_TOKEN value, ever enters the hash, so the same read by two
# different identities shares one cache entry, which is correct: ETags are a
# property of the RESOURCE, not of who is asking). A 2xx with an empty body is
# never stored (gh-rest.sh already turns that into rc 75 before this file's
# store hook runs). A non-GET never reaches these functions at all — gh_rest
# only calls them when its own method check has already passed.
#
# No `set -e`, no `exit`, no side effect at source time — the same rules
# gh-rest.sh states for itself and for the same reason: sourcing this file in
# any lane must cost zero API budget and must not be able to kill the lane.
if [ -n "${GH_REST_ETAG_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_REST_ETAG_LIB=1

_gh_etag_dir() { printf '%s/state/gh-etag' "${HARNESS:-/root/harness}"; }

# BH-1322: where the reporting lanes arm their counter files (<lane>.<pid>),
# so the box's own state directory holds them and _gh_etag_counts_sweep can
# age them — not ${TMPDIR:-/tmp}, which nothing but gh_rest_etag_report ever
# cleaned and which a killed tick therefore leaked into for ever.
_gh_etag_counts_dir() { printf '%s/counts' "$(_gh_etag_dir)"; }

# Portable across the fleet's Debian boxes (sha1sum) and this Mac (shasum -a 1
# also present, but sha1sum is tried first since every box has it). A missing
# pair of tools degrades to cksum rather than dying — a low-quality key still
# caches correctly, it is only a worse hash.
_gh_etag_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 1 | awk '{print $1}'
  else cksum | tr -dc '0-9a-f' | cut -c1-16
  fi
}

# _gh_etag_key <method> <path> [args...].
#
# BH-1295 REVIEW FIX (F2, drain review): the header used to call this "identity-
# independent" and justify it as "an ETag is a property of the resource, not
# of who asked" — wrong: an ETag is a property of the REPRESENTATION, which
# can legitimately differ per viewer (permissions, private fields). It is
# still SAFE without a token in the key, for three checkable reasons: GitHub
# authorizes before evaluating If-None-Match, so a caller without access gets
# 404/403, never a replay of someone else's body; GitHub's REST ETag is a
# content hash, so a viewer-dependent body carries a different ETag and the
# worst case is a 200 that overwrites the entry, never a wrong replay; and no
# body-consuming gh_rest GET in this tree reads a viewer-dependent object.
# GH_LIMIT_IDENTITY (a LABEL like "app:owner/repo" or "pat:owner/repo" —
# bin/lib/gh-app-auth.sh sets it, never the token value) is folded in anyway
# as cheap insurance: the dominant lanes read each repo under one identity, so
# hit rate is unaffected, and a future viewer-dependent read gets its own key
# for free instead of needing this file revisited.
_gh_etag_key() {
  local m="$1" p="$2"; shift 2
  { printf '%s\0%s\0%s\0' "$m" "$p" "${GH_LIMIT_IDENTITY:-}"; for a in "$@"; do printf '%s\0' "$a"; done; } | _gh_etag_sha1
}

_gh_etag_file() { printf '%s/%s' "$(_gh_etag_dir)" "$1"; }

# _gh_etag_read_etag <key> — the stored ETag (line 1), or nothing. Called as a
# plain $( ) capture: it sets nothing, so the "no $( ) around a helper" rule
# (that rule is about GH_REST_STATUS/REASON) does not apply to it.
_gh_etag_read_etag() {
  local f; f=$(_gh_etag_file "${1:-}")
  [ -n "${1:-}" ] && [ -r "$f" ] && sed -n '1p' "$f"
  return 0
}

# _gh_etag_on_304 <key> — rc 0 = a cache hit: prints the cached body (byte for
# byte what the ORIGINAL 2xx read would have printed, see the store-side
# comment below) and sets GH_REST_REASON=cached in the CALLING shell, because
# this is always called as a plain statement, never inside $( ). rc 1 = a miss
# (no key, or the file is gone): the caller maps that to 75/cache-miss, never
# to an empty answer standing in for a state.
# BH-1295 REVIEW FIX (B3): the old body did `[ -r "$f" ] || return 1; ...;
# tail -n +2 "$f"` — two file operations, and the sweep's `rm -f` (which never
# touches a hit's mtime — see the fix below) can land in the gap between them,
# since a cache hit never refreshed this entry's age. When it does, `-r`
# passed on a file `tail` can no longer open, and the old code had already set
# GH_REST_REASON=cached and returned 0 with NOTHING printed — rc 0, an empty
# body, standing in for a state. That is the #768 shape the whole point of
# this library is to rule out. Fixed: the body is read FIRST, and only a
# successful read sets the reason or prints anything. The read also verifies
# line 1 still equals the etag gh_rest actually SENT (a second writer can
# replace the file between gh_rest's pre-request read and this reply landing);
# a mismatch is a cache-miss, never a reply built from two different writes.
# A hit also touches the file's mtime, so the TTL sweep ages out entries that
# stopped being asked for, not ones a lane just replayed (N2 in review).
_gh_etag_on_304() { # _gh_etag_on_304 <key> <etag gh_rest sent>
  local f cur body
  [ -n "${1:-}" ] || return 1
  f=$(_gh_etag_file "$1")
  [ -r "$f" ] || return 1
  # BH-1585 (review round 1): an entry that CANNOT answer (unreadable, no etag,
  # no body) is DELETED on the miss. Left in place, the next read sends the same
  # If-None-Match, GitHub answers the same 304, and the read fails again until
  # the 48h sweep — one torn file blinding that read for two days. Without the
  # entry the next read is a plain GET and a fresh 200. An etag that merely
  # DIFFERS from the one sent is not torn: another process rewrote the entry
  # between our read and this 304, and that entry is the fresh one — kept.
  cur=$(sed -n '1p' "$f" 2>/dev/null) || { rm -f "$f"; return 1; }
  [ -n "$cur" ] || rm -f "$f"
  [ -n "$cur" ] && [ "$cur" = "${2:-}" ] || return 1
  body=$(tail -n +2 "$f" 2>/dev/null) || { rm -f "$f"; return 1; }
  # BH-1295 REVIEW FIX (F2, round 2): a `tail` on an entry holding only the
  # ETag line (truncated by a crash mid-write, or hand-edited) succeeds with
  # an EMPTY capture — the exact "GitHub said nothing, read as a state" shape
  # the ticket names by hand ("A 304 with NO cached body is 75, never an empty
  # answer"). The atomic tmp+mv writer in _gh_etag_on_2xx cannot produce this
  # on its own, but a torn file from any other cause can, and this is the one
  # place that decides whether it is ever read as a real 200-byte answer.
  [ -n "$body" ] || rm -f "$f"
  [ -n "$body" ] || return 1
  touch "$f" 2>/dev/null
  GH_REST_REASON=cached
  printf '%s\n' "$body"
  return 0
}

# _gh_etag_on_2xx <key> <raw header file> <body> — stores a fresh ETag if the
# response carried one; REMOVES any existing entry if it did not (I2 in
# review: GitHub always sends an ETag on a REST GET today, but if it ever
# stops, the alternative — leaving a stale etag+body in place — replays a body
# a live 2xx just superseded on the very next 304). The stored body is the
# CALLER's already-computed `$body` (gh_rest's own `body=$(awk …)` capture,
# the same one its fresh-read path prints via `printf '%s\n' "$body"`), not a
# second extraction from the raw file: two independent awk passes over the
# same bytes converged everywhere this was tested EXCEPT a body ending in a
# blank line, where the raw scan keeps every original newline and a
# `$( )`-then-reprint normalises to exactly one trailing newline (I1 in
# review, 14 vs 15 bytes on that shape) — storing the SAME string the fresh
# path already emits makes a replay byte-for-byte by construction, not by
# coincidence of input shape. The header scan stops at the header/body
# boundary so a body line that happens to start with "etag:" can never be
# read as one (I2). No IGNORECASE: that is a gawk-only special variable,
# silently ignored by mawk (Debian's /usr/bin/awk) and BSD awk (macOS) alike,
# so a case-sensitive `/^etag:/` never matches the `ETag:` header gh actually
# sends — the bracket expression matches every case on every awk.
#
# BH-1295 REVIEW FIXES (drain review): F3 — a diff/patch media-type read can
# store a whole PR's diff, and GH_ETAG_MAX bounds entry COUNT, not bytes; a
# body over GH_ETAG_MAX_BYTES (default 1 MiB) is never stored, so the worst
# case per box stays entry-count x cap instead of unbounded. F5 — the tmp name
# used to be `.$key.$$`, and `$$` is the SAME in every `$( )`/`&` subshell of
# one process, so two concurrent writers of the same key in one process could
# interleave into one tmp file before the `mv -f` (a torn body fails jq/etag
# checks downstream, never a wrong replay, but the fix is one token: $BASHPID
# is a fresh pid per subshell where $$ is not).
#
# BH-1322: the cap is in BYTES, and `${#body}` counts CHARACTERS under a UTF-8
# locale — a diff with non-ASCII could be well over 1 MiB on disk and still be
# stored. `local LC_ALL=C` scopes the byte measure to this one helper (bash
# restores the caller's locale on return), and the answer comes back in a
# VARIABLE rather than a `$( )` capture so a 2xx costs no extra fork.
_gh_etag_bytes() { # _gh_etag_bytes <string> -> GH_ETAG_BYTES
  local LC_ALL=C
  GH_ETAG_BYTES=${#1}
}

_gh_etag_on_2xx() {
  local key="${1:-}" raw="${2:-}" body="${3:-}" etag dir tmp
  [ -n "$key" ] && [ -r "$raw" ] || return 0
  etag=$(awk '/^\r?$/{exit} /^[Ee][Tt][Aa][Gg]:/{sub(/^[Ee][Tt][Aa][Gg]:[ \t]*/,""); sub(/\r$/,""); print; exit}' "$raw")
  dir=$(_gh_etag_dir)
  # A stale entry for this key must not survive either "no ETag this time"
  # (I2) or "too big to store" (F3): either way the entry on disk is no
  # longer this resource's current representation, and leaving it would
  # replay superseded bytes on the next 304.
  _gh_etag_bytes "$body"
  if [ -z "$etag" ] || [ "$GH_ETAG_BYTES" -gt "${GH_ETAG_MAX_BYTES:-1048576}" ]; then
    rm -f "$dir/$key" 2>/dev/null; return 0
  fi
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$dir/.$key.${BASHPID:-$$}"
  { printf '%s\n' "$etag"; printf '%s\n' "$body"; } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$dir/$key" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# _gh_etag_sweep — TTL + size bound, at most once per hour per box (a stamp
# file next to the cache dir itself). Age is judged the portable way
# (bin/lib/merge-conductor-lib.sh's mc_mtime idiom: GNU stat, then BSD stat),
# never `find -printf`, which BSD/macOS find does not have and this suite's
# own `bash tests/*.sh` runs are exercised on. The size cap keeps the NEWEST
# GH_ETAG_MAX entries by mtime and drops the rest — `ls -1t` is newest-first on
# both GNU and BSD. An optional <dir> sweeps another cache under the same
# rules and its own stamp; bin/lib/gh-cache.sh passes state/gh-cache (BH-8066).
_gh_etag_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

_gh_etag_sweep() { # _gh_etag_sweep [dir]
  local dir stamp now last ttl_h cutoff max f n over
  dir="${1:-$(_gh_etag_dir)}"
  [ -d "$dir" ] || return 0
  stamp="$dir/.swept"
  now=$(date -u +%s 2>/dev/null) || return 0
  if [ -f "$stamp" ]; then
    last=$(_gh_etag_mtime "$stamp")
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -ge 3600 ] || return 0
  fi
  : > "$stamp" 2>/dev/null
  ttl_h="${GH_ETAG_TTL_H:-48}"
  case "$ttl_h" in ''|*[!0-9]*) ttl_h=48 ;; esac
  cutoff=$((now - ttl_h * 3600))
  for f in "$dir"/*; do
    case "${f##*/}" in .*) continue ;; esac
    [ -f "$f" ] || continue
    [ "$(_gh_etag_mtime "$f")" -lt "$cutoff" ] && rm -f "$f"
  done
  max="${GH_ETAG_MAX:-20000}"
  case "$max" in ''|*[!0-9]*) max=20000 ;; esac
  n=$(find "$dir" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  over=$((n - max))
  [ "$over" -gt 0 ] || return 0
  # BH-1322: `ls -1t` lists the `counts` DIRECTORY too (the entry count above
  # is a `find -type f`, so the two disagree by one and the directory can land
  # in the drop list). `rm -f` on a directory is a harmless error today, but
  # the `-f` test says what this loop means: only regular entries are pruned.
  ( cd "$dir" 2>/dev/null && ls -1t 2>/dev/null | grep -v '^\.' | tail -n +"$((max + 1))" ) \
    | while IFS= read -r f; do [ -f "$dir/$f" ] && rm -f "$dir/$f"; done
  return 0
}

# _gh_etag_counts_sweep — BH-1322. The counter files under state/gh-etag/counts
# are named <lane>.<pid> by their arming lane, and the lane's own EXIT trap
# removes its file on any normal exit or SIGTERM. SIGKILL (OOM, kill -9, a
# tick deadline that hard-kills) runs no trap, so this is the backstop: a file
# goes when its pid suffix is not a number (never a counter this library
# wrote), when that pid is no longer alive, or when it is older than the same
# GH_ETAG_TTL_H cutoff the entry sweep uses — the last rule is what bounds a
# file whose pid was recycled by an unrelated live process.
#
# /proc is tested BEFORE `kill -0` on purpose: `kill -0` on a live process
# owned by another user answers EPERM, which a non-root run would otherwise
# read as "dead". `kill -0` stays as the fallback for boxes without /proc.
# No hourly stamp: the directory holds one file per live reporting lane (a
# dozen at most), so the walk is cheap enough to run on every report.
_gh_etag_counts_sweep() {
  local dir now ttl_h cutoff f base pid
  dir=$(_gh_etag_counts_dir)
  [ -d "$dir" ] || return 0
  now=$(date -u +%s 2>/dev/null) || return 0
  ttl_h="${GH_ETAG_TTL_H:-48}"
  case "$ttl_h" in ''|*[!0-9]*) ttl_h=48 ;; esac
  cutoff=$((now - ttl_h * 3600))
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    base=${f##*/}
    pid=${base##*.}
    case "$pid" in ''|*[!0-9]*) rm -f "$f"; continue ;; esac
    if [ -d "/proc/$pid" ] || kill -0 "$pid" 2>/dev/null; then
      [ "$(_gh_etag_mtime "$f")" -lt "$cutoff" ] && rm -f "$f"
      continue
    fi
    rm -f "$f"
  done
  return 0
}

# BH-1295 REVIEW FIX (B2): a shell VARIABLE cannot count gh_rest's dominant
# caller. mc_pr_view's return value is its whole point, so every real call
# site is `X=$(mc_pr_view …)` — a `$( )` subshell — and merge-conductor.sh
# additionally backgrounds one subshell PER PROJECT. `$$` is the same value in
# every one of those (bash never resets it for `$( )`, `( )` or `&`), so a
# counter keyed on it would sum every project into one number; `$BASHPID`
# changes on EVERY `$( )`, including two sequential ones in the same subshell,
# so it cannot accumulate across more than one read either. Neither shell
# state survives the way this needs.
#
# The counter is a FILE instead — a real write, which (unlike a variable
# assignment) is visible to whatever shell next opens the same path, forked
# or not. Its name comes from GH_ETAG_COUNT_FILE, which the four reporting
# lanes export (merge-conductor.sh sets a fresh one per project, so parallel
# projects never share a file; reconcile-prs.sh/merge-sweep.sh/pr-url-
# reconcile.sh set one plain value each, since each is one process, one tick,
# no backgrounding of the reads).
#
# BH-1295 REVIEW FIX (F1, round 2): _gh_etag_count used to fall back to
# `gh-etag-count.$$` when no GH_ETAG_COUNT_FILE was set, so EVERY gh_rest GET
# in EVERY process wrote a file — and only gh_rest_etag_report ever deletes
# one. 14 of the 17 bin/*.sh scripts that read through gh_rest/mc_pr_view
# never call the report (gh-pr-state.sh, triage-gate.sh, dep-verify.sh,
# review-prs.sh, blocked-resolver.sh, batch-resolve.sh, orphan-reconcile.sh,
# fly-pool.sh, merge-queue.sh, hotfix-seen.sh, preplan-
# candidates.sh, review-autopilot.sh, verification-map-retrofit.sh), so each
# tick of each left a new /tmp/gh-etag-count.<pid> forever — unbounded, on a
# box whose /tmp is cleaned at boot only. Counting is now opt-in: no counter
# file is ever created unless a caller has explicitly armed one.
#
# BH-1322: WHERE an armed file lives changed. The three reporting lanes now arm
# `$HARNESS/state/gh-etag/counts/<lane>.<pid>` (merge-conductor's per-project
# subshells key on `$BASHPID`, the parent on `$$`) and each installs
# `trap 'rm -f "$GH_ETAG_COUNT_FILE"' EXIT`, which covers every normal exit and
# SIGTERM. SIGKILL runs no trap, so _gh_etag_counts_sweep — run from
# gh_rest_etag_report, i.e. from whichever lane reports next — is the backstop
# that removes a dead pid's file. The `$TMPDIR` DEFAULT below stays: it is the
# path the report reads when nothing is armed, where it finds no file and
# reports 0/0, and no code ever writes it (F1 above).
_gh_etag_count_file() { printf '%s' "${GH_ETAG_COUNT_FILE:-${TMPDIR:-/tmp}/gh-etag-count.$$}"; }

# BH-1322: the armed path now lives under state/gh-etag/counts/, which does not
# exist on a box until the first counted GET, and no arming site is made to
# pre-create it (one mkdir per lane, four places to forget). The append is
# tried first — the steady state, where the directory is already there, costs
# exactly what it did before — and only a FAILED append pays for a mkdir and
# one retry.
_gh_etag_count() { # _gh_etag_count fetched|cached
  local cf
  [ -n "${GH_ETAG_COUNT_FILE:-}" ] || return 0
  cf=$(_gh_etag_count_file)
  # `2>/dev/null` BEFORE the append, not after: redirections are applied left
  # to right, so with the usual order the shell's own "No such file or
  # directory" for the failed open is written to the lane's log before stderr
  # is silenced — a scary line in merge-conductor.log for what is the expected
  # first-write-of-the-day path.
  printf '%s\n' "$1" 2>/dev/null >> "$cf" && return 0
  case "$cf" in */*) mkdir -p "${cf%/*}" 2>/dev/null || return 0 ;; *) return 0 ;; esac
  printf '%s\n' "$1" 2>/dev/null >> "$cf"
  return 0
}

# gh_rest_etag_report <lane> — one gh-rate.log line for this counter file's
# GET reads since the last report, then clears the file and runs both sweeps:
# the counts sweep (BH-1322, every call — it walks a directory holding one file
# per live reporting lane, and it is what removes a SIGKILLed lane's file) and
# the entry sweep (which self-limits to once an hour, so calling this every
# tick costs nothing extra). Callers: bin/merge-conductor.sh (once per project,
# inside that project's own subshell, plus once more for the parent's own
# sequential work) and the three */10 sweeps (reconcile-prs.sh, merge-sweep.sh,
# pr-url-reconcile.sh), once per tick.
gh_rest_etag_report() {
  local f="${HARNESS:-/root/harness}/logs/gh-rate.log" cf fetched=0 cached=0
  cf=$(_gh_etag_count_file)
  if [ -r "$cf" ]; then
    fetched=$(grep -c '^fetched$' "$cf" 2>/dev/null) || fetched=0
    cached=$(grep -c '^cached$' "$cf" 2>/dev/null) || cached=0
  fi
  mkdir -p "${f%/*}" 2>/dev/null
  printf 'gh-etag lane=%s fetched=%s cached=%s\n' "${1:-?}" "$fetched" "$cached" >> "$f" 2>/dev/null
  rm -f "$cf" 2>/dev/null
  _gh_etag_counts_sweep
  _gh_etag_sweep
}
