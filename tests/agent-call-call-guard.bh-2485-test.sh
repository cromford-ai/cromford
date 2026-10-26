#!/bin/bash
# tests/agent-call-call-guard.bh-2485-test.sh — BH-2485: the build call fp's
# thread signature on a GitHub-issue project reads the WHOLE comment thread,
# not its first 100 comments. The single-issue comments endpoint is oldest
# first, so a one-page read never saw comment 101+, and a new answer on a long
# thread kept the fp: the call guard could refuse a re-plan after a real reply.
#
# Drives the REAL `build call fp` / `call fp reuse` / `call fp write` blocks
# extracted from the flattened pipeline, with a page-aware gh_rest stub.
#
# Run from anywhere: tests/agent-call-call-guard.bh-2485-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

META='{"title":"long thread","body":"read all of it"}'

RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
cut_block() { awk -v n="$1" '$0=="# >>> " n{f=1;next} $0=="# <<< " n{exit} f' "$RB_ALL" > "$2"; }
cut_block "build call fp" "$T/b-fns.sh"
cut_block "call fp reuse" "$T/b-reuse.sh"
cut_block "call fp write" "$T/b-write.sh"
[ -s "$T/b-fns.sh" ] && [ -s "$T/b-reuse.sh" ] && [ -s "$T/b-write.sh" ] && ok \
  || bad "R0 could not extract the build call fp blocks from the pipeline"

HB="$T/hb"; mkdir -p "$HB/bin/lib"
cp "$DIR/bin/lib/call-guard.sh" "$HB/bin/lib/call-guard.sh"
# BH-7919: TICKET_THREAD_SIG now asks bin/lib/tracker.sh trk_gh_issue_number.
scratch_install_closure bin/lib/tracker.sh "$HB" >/dev/null || exit 1
cat > "$HB/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in
  board_prefix) printf '%s\n' "-" ;;
  repo) printf '%s\n' "example-org/cromford" ;;
esac
EOF
chmod +x "$HB/bin/fleet-conf.sh"
W="$T/wt"; mkdir -p "$W"
( cd "$W" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base \
  && git update-ref refs/remotes/origin/main HEAD ) || bad "R0 scratch repo"
W_SHA=$(git -C "$W" rev-parse HEAD)

# fixture <n> [edit-last] -> a JSON array of n comments, ids 1..n, distinct stamps
fixture() {
  jq -nc --argjson n "$1" --arg e "${2:-}" '[range(1; $n + 1) | {id: ., body: "c\(.)",
    updated_at: ("2026-09-2" + (if . == $n and $e != "" then "6" else "5" end) + "T00:00:00Z|\(.)")}]'
}
# The page-aware stub. env: GH_FIX (fixture file), GH_FOREVER=1 (a full page
# every time), GH_BAD_PAGE / GH_BAD_RC / GH_BAD_BODY (one page misbehaves).
# It prints a body EVEN on a failing rc, so only the rc check can refuse it.
drive() { # drive <build-dir> -> BUILD_CALL_FP
  local B="$1"
  ( HARNESS="$HB"; PROJECT=cromford; KEY=BH-2485; BUILD="$B"; WT="$W"; BASE=main; FP_BEFORE=""
    STAMP() { echo now; }
    gh_rest() {
      local p; echo "$*" >> "$T/gh.calls"
      p=$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<<"$2"); p=${p:-1}
      if [ "$p" = "${GH_BAD_PAGE:-}" ]; then printf '%s\n' "${GH_BAD_BODY:-[]}"; return "${GH_BAD_RC:-0}"; fi
      if [ "${GH_FOREVER:-}" = 1 ]; then jq -c --argjson p "$p" '[range(0;100) | {id: ($p*1000 + .), updated_at: "x"}]' -n; return 0; fi
      jq -c --argjson p "$p" '.[($p-1)*100 : $p*100]' "$GH_FIX"
    }
    . "$T/b-fns.sh"; . "$T/b-reuse.sh"; . "$T/b-write.sh"
    printf '%s' "${BUILD_CALL_FP:-}" )
}
newb() { local b="$T/b/$1"; scratch_rm "$b"; mkdir -p "$b"; printf '%s\n' "$META" > "$b/ticket-meta.json"; printf '%s' "$b"; }
want_fp() { # want_fp <fixture-file> -> the fp over meta + the full projection
  ( . "$DIR/bin/lib/call-guard.sh" || exit 9
    printf '%s\n%s' "$(jq -c '{title,body}' <<<"$META")" "$(jq -c '[.[] | [.id, .updated_at]]' "$1")" \
      | call_guard_build_fp BH-2485 "$W_SHA" )
}
fixture 150 > "$T/f150.json"; fixture 151 > "$T/f151.json"; fixture 150 edit > "$T/f150e.json"
fixture 100 > "$T/f100.json"; fixture 1 > "$T/f1.json"

# R1 a 151st comment on a 150-comment thread moves the fp (the bug)
: > "$T/gh.calls"; B150=$(newb r1a)
fp150=$(GH_FIX="$T/f150.json" drive "$B150")
B151=$(newb r1b)
fp151=$(GH_FIX="$T/f151.json" drive "$B151")
[ -n "$fp150" ] && [ -n "$fp151" ] && [ "$fp150" != "$fp151" ] && ok \
  || bad "R1 150 -> 151 comments: fp '$fp150' vs '$fp151', want two different fps"
[ "$(cat "$B150/call-fp" 2>/dev/null)" = "$fp150" ] && [ "$(cat "$B151/call-fp" 2>/dev/null)" = "$fp151" ] && ok \
  || bad "R1 call-fp files do not carry the fps"

# R2 every page is read, and the fp is over ALL 150 pairs in order
: > "$T/gh.calls"; B=$(newb r2)
got=$(GH_FIX="$T/f150.json" drive "$B")
grep -q 'comments?per_page=100&page=1$' "$T/gh.calls" && grep -q 'comments?per_page=100&page=2$' "$T/gh.calls" \
  && ! grep -q 'page=3' "$T/gh.calls" && ok || bad "R2 page calls: $(tr '\n' ' ' < "$T/gh.calls")"
want=$(want_fp "$T/f150.json")
[ -n "$want" ] && [ "$got" = "$want" ] && ok || bad "R2 fp '$got' want '$want' (full projection)"

# R3 an edit to comment #150 (page 2) moves the fp
B=$(newb r3)
got=$(GH_FIX="$T/f150e.json" drive "$B")
[ -n "$got" ] && [ "$got" != "$fp150" ] && ok || bad "R3 an edit to comment 150 kept the fp '$got'"

# R4 <= 100 comments: byte-identical to the one-page signature
: > "$T/gh.calls"; B=$(newb r4)
got=$(GH_FIX="$T/f100.json" drive "$B")
want=$(want_fp "$T/f100.json")
[ -n "$want" ] && [ "$got" = "$want" ] && ok || bad "R4 100 comments: fp '$got' want '$want'"
grep -q 'page=2$' "$T/gh.calls" && ok || bad "R4 a full page 1 did not ask for page 2: $(tr '\n' ' ' < "$T/gh.calls")"
: > "$T/gh.calls"; B=$(newb r4b)
got=$(GH_FIX="$T/f1.json" drive "$B")
[ -n "$got" ] && [ "$got" = "$(want_fp "$T/f1.json")" ] && ok || bad "R4b 1 comment: fp '$got'"
[ "$(wc -l < "$T/gh.calls")" = 1 ] && grep -q 'page=1$' "$T/gh.calls" && ok \
  || bad "R4b 1 comment made calls: $(tr '\n' ' ' < "$T/gh.calls")"

# R5 more than 1000 comments: no fp at all, never a truncated one
: > "$T/gh.calls"; B=$(newb r5)
got=$(GH_FOREVER=1 drive "$B")
[ -z "$got" ] && [ ! -e "$B/call-fp" ] && grep -q 'no stable call fp (no thread signal)' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "R5 >1000 comments: fp '$got' log '$(cat "$B/pipeline.log" 2>/dev/null)'"
[ "$(wc -l < "$T/gh.calls")" = 10 ] && ok || bad "R5 made $(wc -l < "$T/gh.calls") calls, want 10"

# R6 a failed page 2 (rc 75, body printed anyway) is no signal, never a partial fp
B=$(newb r6)
got=$(GH_FIX="$T/f150.json" GH_BAD_PAGE=2 GH_BAD_RC=75 GH_BAD_BODY='[{"id":1,"updated_at":"x"}]' drive "$B")
[ -z "$got" ] && [ ! -e "$B/call-fp" ] && grep -q 'no stable call fp (no thread signal)' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "R6 page 2 rc 75: fp '$got' log '$(cat "$B/pipeline.log" 2>/dev/null)'"
B=$(newb r6b)
got=$(GH_FIX="$T/f150.json" GH_BAD_PAGE=2 GH_BAD_RC=0 GH_BAD_BODY='{"message":"nope"}' drive "$B")
[ -z "$got" ] && [ ! -e "$B/call-fp" ] && grep -q 'no stable call fp (no thread signal)' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "R6b page 2 non-array: fp '$got' log '$(cat "$B/pipeline.log" 2>/dev/null)'"

echo "agent-call-call-guard.bh-2485: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
