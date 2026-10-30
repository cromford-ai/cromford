# >>> build-note relay (policy, the operator 2026-09-24)
# The same reason again: bin/blocked-resolver.sh carries a note to the NEXT build
# of a ticket in state/build-notes/<project>/<key>.md (an adjudication ruling,
# or, since the CI-repair park, the failing-CI evidence of an automatic narrower
# re-plan), and a pool machine has no hub state. Relayed beside the job to
# build-note-<project>-<key>.md in the relay dir, where bin/run-build.sh's plan
# stage looks first. CONSUMED ON A GOOD PUSH (renamed .relayed-<epoch>), so a
# later, unrelated build of the key never inherits it — the same read-once rule
# the hub build applies with its mv. Never fatal: a failed push costs the brief,
# never the build, and the note stays for the next machine.
#
# BH-5003: the note is also the ledger row build_note/"$P $k"
# (bin/lib/build-note-db.sh), which a watcher box consumes directly. A row a
# box already used (`consumed`/`relayed`, and its detail is THIS file: bn_used)
# retires the hub file without a push;
# a good push marks a still-`pending` row `relayed`. Fail-open: no lib, the
# knob at 0, or an outage relays exactly as before.
# shellcheck source=bin/lib/build-note-db.sh
{ [ -r "$HARNESS/bin/lib/build-note-db.sh" ] && . "$HARNESS/bin/lib/build-note-db.sh"; } || true
# push_build_note_file <machine-id> <key> -> the hub note to relay, or nothing.
# A note the ledger says was already used is retired here, never relayed.
# build_note_relayed <machine-id> <key> <file> consumes it after a good relay.
# Split out for the seed (BH-7430): a seeded note is consumed only after
# `fly machine run` answers, so a launch that fails keeps it for the next one.
push_build_note_file() {
  local mid="${1:-}" k="${2:-}" f st=""
  f="$HARNESS/state/build-notes/$P/$k.md"
  [ -s "$f" ] || return 0
  command -v bn_used >/dev/null 2>&1 && st=$(bn_used "$P" "$k" "$f" 2>/dev/null)
  case "$st" in
    consumed|relayed)
      mv -f "$f" "$f.relayed-$(date +%s)" 2>/dev/null || rm -f "$f"
      say "the carried build note for $k was already used on another box (ledger row $st) — retired, not relayed to $mid"
      return 0 ;;
  esac
  printf '%s\n' "$f"
}
build_note_relayed() {
  local mid="${1:-}" k="${2:-}" f="${3:-}"
  mv -f "$f" "$f.relayed-$(date +%s)" 2>/dev/null || rm -f "$f"
  say "relayed the carried build note for $k to $mid"
  if command -v bn_mark >/dev/null 2>&1; then bn_mark "$P" "$k" relayed >/dev/null 2>&1 || true; fi
}
push_build_note() { # push_build_note <machine-id> <key>
  local mid="${1:-}" k="${2:-}" f
  [ -n "$mid" ] && [ -n "$k" ] || return 0
  f=$(push_build_note_file "$mid" "$k")
  [ -n "$f" ] || return 0
  if mput "$mid" "$f" "/run/harness/build-note-$P-$k.md"; then
    build_note_relayed "$mid" "$k" "$f"
  else
    say "$mid: build-note push for $k FAILED — kept for the next machine; this build plans without it"
  fi
  return 0
}
# <<< build-note relay
