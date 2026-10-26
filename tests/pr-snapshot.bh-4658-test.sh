#!/bin/bash
# tests/pr-snapshot.bh-4658-test.sh — BH-4658 (BH-4656 part 1): the shared PR
# snapshot library "$DIR/bin/lib/pr-snapshot.sh" and its registry entry
# "$DIR/catalog/lanes.d/_lib.pr-snapshot.json", sourced by a driver (drv), and
# its consumer on the worklist, gate 16 of bin/lead-review.sh (dispatcher section).
#
# A scratch harness carries the real lib closure. Stubbed:
#   * gh   — rate_limit, the open PR list ($T/prs.json; a 403 rate limit when
#            $T/list403 exists), pulls/<n> ($T/pr/<n>.json) and
#            git/ref/heads/main (sha in $T/tip). Every argv is logged.
#   * curl — logs every request to $T/log/worker and answers 404; the lib
#            cases make no worker call.
# Cache ages are set by rewriting open.meta / base-* epochs and `touch -d`,
# never by sleeping.
# Dispatcher section (BH-5874): gate 16, bin/lib/lead-gates.d/55-snapshot.sh,
# on the worklist. bin/lead-review.sh tick runs WHOLE over
# tests/lib/lead-worklist-fixture.bh-4956.sh (list rows carry updated_at and
# base.ref, the body mergeable and mergeable_state). A test gate 99-hold.sh
# logs that it ran and answers 11, so the head stays on the worklist and no
# review_one read mixes into the gh log.
#   DS1 PR_SNAPSHOT=1: tick 1 logs `PR-SNAPSHOT example-org/demo-os#101 miss`
#       and makes one pulls/101 read.
#   DS2 tick 2 logs `... hit` and makes no new pulls/101 read.
#   DS3 the body names another head than the worklist: one `names head` line,
#       and the item is HELD: the gates after it do not run (the ticket's gate
#       contract, "a failed read is a hold, never a pass"; lead BLOCK at
#       19019cf2e). TEST-CHANGE: DS3 and DS4 were added by this PR and asserted
#       the pass the review blocked.
#   DS4 the body read answers 500: one `PR body unreadable` line, held, the
#       gates after it do not run.
#   DS5 PR_SNAPSHOT=0: no open-PR list read, `miss` on each tick.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-snapshot.bh-4658-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/pr"
# The lib with the bin/lib files it sources (BH-4552).
scratch_install_closure bin/lib/pr-snapshot.sh "$H" >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/lib/pr-snapshot.sh"; exit 1; }
# The registry, composed from this checkout's catalog/lanes.d (never committed).
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; exit 1; }
jq -e '.libs[] | select(.id == "pr-snapshot")' "$T/lanes.json" >/dev/null 2>&1 \
  && ok || bad "R0 the composed registry has no pr-snapshot lib"

SLUG=example-org/demo-os
TIPA=$(printf '1%.0s' {1..40}); TIPB=$(printf '2%.0s' {1..40})
UPD=2026-10-05T10:00:00Z
sha() { printf "$1%.0s" {1..40}; }

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
p=""; prev=""
for a in "\$@"; do [ "\$prev" = GET ] && p="\$a"; prev="\$a"; done
pg=1; [[ " \$* " =~ [\&\ ]page=([0-9]+) ]] && pg="\${BASH_REMATCH[1]}"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
esac
case "\$p" in
  repos/$SLUG/pulls|repos/$SLUG/pulls\?*)
    if [ -e "$T/list403" ]; then printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\n\r\n{"message":"API rate limit exceeded"}\n'
    elif [ "\$pg" = 1 ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json"
    else printf 'HTTP/2 200\r\n\r\n[]\n'; fi ;;
  repos/$SLUG/pulls/*)
    n="\${p##*/pulls/}"
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/pr/\$n.json" ;;
  repos/$SLUG/git/ref/heads/main)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/tip")" '{ref:"refs/heads/main", object:{sha:\$s, type:"commit"}}' ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/worker"
printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404'
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

unset PR_SNAPSHOT PR_SNAPSHOT_TTL_S PR_SNAPSHOT_QUIET_TTL_S PR_SNAPSHOT_FEED_STALE_S PRS_COUNT_FILE PR_SNAPSHOT_LIB
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 LANE_REGISTRY="$T/lanes.json"
unset BOX_NAME JOBS_BOX HUB_BOX_NAME

D="$H/state/pr-snapshot/example-org_demo-os"
NOW=$(date +%s)
# pr <n> <head> <mergeable json> [mergeable_state] [body head] — one open PR in
# the list and its pulls/<n> body. updated_at comes from $T/upd/<n>, else UPD.
pr() {
  local u; u=$(cat "$T/upd/$1" 2>/dev/null || echo "$UPD")
  jq -c --argjson n "$1" --arg h "$2" --arg u "$u" '. + [{number:$n, html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)),
    title:"t", draft:false, state:"open", updated_at:$u, user:{login:"operator",type:"User"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"}}]' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  jq -nc --arg h "${5:-$2}" --argjson m "$3" --arg ms "${4:-clean}" --arg u "$u" \
    '{head:{sha:$h}, base:{ref:"main"}, mergeable:$m, mergeable_state:$ms, updated_at:$u}' > "$T/pr/$1.json"
}
reset() {
  scratch_rm "$H/state/pr-snapshot"
  rm -f "$T/log"/* "$T/count" "$T/list403" "$H/logs"/* "$H/state/settings-cache.json" "$H/bin/lib/pr-snapshot-wakes.sh"
  for d in pr upd; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  echo '[]' > "$T/prs.json"; echo "$TIPA" > "$T/tip"; : > "$T/log/gh"
}
# drv <bash code> — source the library in a fresh process and run the code.
cat > "$T/drv.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
. "$HARNESS/bin/lib/pr-snapshot.sh" || exit 99
command -v prs_pr_get >/dev/null 2>&1 || exit 98
eval "$1"
EOF
drv() { bash "$T/drv.sh" "$1" > "$T/drv.out" 2>&1; DRC=$?; }
reads() { grep -cE -- "GET repos/$SLUG/$1( |\$)" "$T/log/gh"; }
lreads() { grep -cE -- "GET repos/$SLUG/pulls( |\?)" "$T/log/gh"; }
get() { printf 'prs_pr_get %s %s %s %s main %s' "$SLUG" "$1" "$2" "$3" "$4"; }
words() { grep -c "^$1 " "$T/count" 2>/dev/null; }
# ── S4 / S4b: a mergeable that is still being computed is never stored ──
reset; pr 4 "$(sha 4)" null; pr 5 "$(sha 5)" true unknown
drv "$(get 4 "$(sha 4)" "$UPD" "$T/o1"); $(get 4 "$(sha 4)" "$UPD" "$T/o2")"
[ "$DRC" = 0 ] && ok || bad "S4 rc=$DRC $(cat "$T/drv.out")"
[ "$(reads pulls/4)" = 2 ] && ok || bad "S4 want 2 pulls/4 reads, got $(reads pulls/4)"
[ ! -e "$D/pr-4.key" ] && ok || bad "S4 a mergeable:null body was stored"
[ "$(jq -r .head.sha "$T/o2" 2>/dev/null)" = "$(sha 4)" ] && ok || bad "S4 the caller did not get the live body"
drv "$(get 5 "$(sha 5)" "$UPD" "$T/o1"); $(get 5 "$(sha 5)" "$UPD" "$T/o2")"
[ "$(reads pulls/5)" = 2 ] && ok || bad "S4b want 2 pulls/5 reads, got $(reads pulls/5)"
[ ! -e "$D/pr-5.key" ] && ok || bad "S4b a mergeable_state:unknown body was stored"

# ── S5: a new base tip is a miss ──
reset; pr 6 "$(sha 6)" true
drv "PRS_COUNT_FILE=$T/count; $(get 6 "$(sha 6)" "$UPD" "$T/o1"); $(get 6 "$(sha 6)" "$UPD" "$T/o2")"
[ "$(reads pulls/6)" = 1 ] && [ "$(words HIT)" = 1 ] && ok || bad "S5 setup: want one read then a hit, got $(reads pulls/6) reads, $(cat "$T/count" 2>/dev/null)"
[ "$(reads git/ref/heads/main)" = 1 ] && ok || bad "S5 the base tip was not cached inside its TTL ($(reads git/ref/heads/main) reads)"
echo "$TIPB" > "$T/tip"; printf '%s\t%s\n' "$((NOW - 120))" "$TIPA" > "$D/base-main"
rm -f "$T/count"
drv "PRS_COUNT_FILE=$T/count; $(get 6 "$(sha 6)" "$UPD" "$T/o3")"
[ "$(reads pulls/6)" = 2 ] && [ "$(words MISS)" = 1 ] && ok || bad "S5 a new base tip was a hit ($(reads pulls/6) reads)"
grep -q "$TIPB" "$D/pr-6.key" 2>/dev/null && ok || bad "S5 the re-stored key does not carry the new tip"

# ── S6: lock held -> read for yourself, write nothing, never wait ──
reset; pr 1 "$(sha 1)" true; pr 2 "$(sha 2)" true
mkdir -p "$D"; echo '[{"number":99}]' > "$D/open.json"; echo "$((NOW - 120))" > "$D/open.meta"
SUM=$(cksum < "$D/open.json")
( flock "$D/open.lock" -c "touch '$T/held'; sleep 5" ) & BG=$!
for _ in $(seq 50); do [ -e "$T/held" ] && break; sleep 0.1; done
[ -e "$T/held" ] && ok || bad "S6 the background lock never took hold"
timeout 2 bash "$T/drv.sh" "prs_open_list $SLUG $T/o1" > "$T/drv.out" 2>&1; DRC=$?
[ "$DRC" = 0 ] && ok || bad "S6 rc=$DRC (124 = it waited on the lock) $(cat "$T/drv.out")"
[ "$(jq -c '[.[].number]' "$T/o1" 2>/dev/null)" = '[1,2]' ] && ok || bad "S6 the caller did not get the live list: $(cat "$T/o1")"
[ "$(cksum < "$D/open.json")" = "$SUM" ] && ok || bad "S6 open.json was written while another process held the lock"
kill "$BG" 2>/dev/null; wait "$BG" 2>/dev/null; rm -f "$T/held"

# ── S7a: PR_SNAPSHOT=0 -> straight through, nothing on disk ──
reset; pr 7 "$(sha 7)" true
PR_SNAPSHOT=0 drv "PRS_COUNT_FILE=$T/count; $(get 7 "$(sha 7)" "$UPD" "$T/o1"); $(get 7 "$(sha 7)" "$UPD" "$T/o2"); prs_open_list $SLUG $T/o3; prs_open_list $SLUG $T/o4"
[ "$DRC" = 0 ] && ok || bad "S7a rc=$DRC $(cat "$T/drv.out")"
[ "$(reads pulls/7)" = 2 ] && [ "$(lreads)" = 2 ] && ok || bad "S7a want 2+2 reads, got $(reads pulls/7) + $(lreads)"
[ ! -e "$H/state/pr-snapshot" ] && ok || bad "S7a PR_SNAPSHOT=0 wrote under state/pr-snapshot: $(find "$H/state/pr-snapshot")"
[ "$(words MISS)" = 2 ] && ok || bad "S7a the live reads were not counted as MISS: $(cat "$T/count" 2>/dev/null)"
[ "$(jq length "$T/o4" 2>/dev/null)" = 1 ] && ok || bad "S7a prs_open_list did not print the live list"

# ── S7b: a settings row beats env ──
reset; pr 7 "$(sha 7)" true
mkdir -p "$H/state"
jq -nc --argjson f "$NOW" '{fetched_at:$f, values:{"lib.pr-snapshot.pr_snapshot_ttl_s":"0"}, seeded:{}}' > "$H/state/settings-cache.json"
LANE_GATE_NOW=$NOW PR_SNAPSHOT_TTL_S=60 drv "prs_open_list $SLUG $T/o1; prs_open_list $SLUG $T/o2; echo ttl=\$PR_SNAPSHOT_TTL_S"
[ "$(lreads)" = 2 ] && ok || bad "S7b the row (0) did not beat env (60): $(lreads) list reads, $(cat "$T/drv.out")"
rm -f "$H/state/settings-cache.json"
# ── S7c: env beats the registry default; 0 = no cache ──
: > "$T/log/gh"; scratch_rm "$H/state/pr-snapshot"
PR_SNAPSHOT_TTL_S=0 drv "prs_open_list $SLUG $T/o1; prs_open_list $SLUG $T/o2"
[ "$(lreads)" = 2 ] && ok || bad "S7c env TTL 0 cached: $(lreads) list reads"
: > "$T/log/gh"; scratch_rm "$H/state/pr-snapshot"
PR_SNAPSHOT_TTL_S=60 drv "prs_open_list $SLUG $T/o1; prs_open_list $SLUG $T/o2"
[ "$(lreads)" = 1 ] && ok || bad "S7c env TTL 60 did not cache: $(lreads) list reads"
# A3: TTL 0 is no cache for the per-PR store too.
: > "$T/log/gh"; scratch_rm "$H/state/pr-snapshot"
PR_SNAPSHOT_TTL_S=0 drv "$(get 7 "$(sha 7)" "$UPD" "$T/o1"); $(get 7 "$(sha 7)" "$UPD" "$T/o2")"
[ "$(reads pulls/7)" = 2 ] && [ ! -e "$D/pr-7.key" ] && ok || bad "S7c TTL 0 still cached a PR body"
# With no registry and no env, every knob is empty: off.
: > "$T/log/gh"; scratch_rm "$H/state/pr-snapshot"
LANE_REGISTRY="$T/none.json" drv "$(get 7 "$(sha 7)" "$UPD" "$T/o1"); $(get 7 "$(sha 7)" "$UPD" "$T/o2"); echo \"on=\${PR_SNAPSHOT:-empty}\""
[ "$(reads pulls/7)" = 2 ] && [ ! -e "$H/state/pr-snapshot" ] && ok || bad "S7d an unreadable registry did not mean off: $(cat "$T/drv.out")"

# ── S8: a rate-limited refresh never overwrites and never serves stale ──
reset; mkdir -p "$D"; echo '[{"number":11},{"number":12}]' > "$D/open.json"; echo "$((NOW - 120))" > "$D/open.meta"
cp "$D/open.json" "$T/open.before"; cp "$D/open.meta" "$T/meta.before"
echo '[{"number":11}]' > "$T/o1"
touch "$T/list403"
drv "prs_open_list $SLUG $T/o1"
[ "$DRC" = 75 ] && ok || bad "S8 want rc 75, got $DRC $(cat "$T/drv.out")"
cmp -s "$D/open.json" "$T/open.before" && cmp -s "$D/open.meta" "$T/meta.before" && ok || bad "S8 a rate-limited refresh rewrote the cache"
[ "$(jq length "$T/o1" 2>/dev/null)" != 2 ] && ! cmp -s "$T/o1" "$T/open.before" && ok || bad "S8 the stale list was served: $(cat "$T/o1")"

# ── N1..N6: the hit matcher's negatives ──
reset; pr 8 "$(sha 8)" true
drv "PRS_COUNT_FILE=$T/count; $(get 8 "$(sha 8)" - "$T/o1"); $(get 8 "$(sha 8)" - "$T/o2")"
[ "$(reads pulls/8)" = 2 ] && [ "$(words MISS)" = 2 ] && [ ! -e "$D/pr-8.key" ] && ok || bad "N1 updated_at '-' was a hit or was stored"
rm -f "$T/count"; : > "$T/log/gh"
drv "PRS_COUNT_FILE=$T/count; $(get 8 "$(sha 8)" "''" "$T/o1"); $(get 8 "$(sha 8)" "''" "$T/o2")"
[ "$(reads pulls/8)" = 2 ] && [ ! -e "$D/pr-8.key" ] && ok || bad "N1b an empty updated_at was a hit or was stored"
# A stored key, then a different base tip inside the key.
reset; pr 8 "$(sha 8)" true
drv "$(get 8 "$(sha 8)" "$UPD" "$T/o1")"
[ -f "$D/pr-8.key" ] && ok || bad "N2 setup: no key stored"
printf '%s\t%s\t%s' "$(sha 8)" "$UPD" "$TIPB" > "$D/pr-8.key"
drv "$(get 8 "$(sha 8)" "$UPD" "$T/o2")"
[ "$(reads pulls/8)" = 2 ] && ok || bad "N2 a key with another base tip was a hit"
# A pr wake since the key was written.
drv "$(get 8 "$(sha 8)" "$UPD" "$T/o3")"
[ "$(reads pulls/8)" = 2 ] && ok || bad "N3 setup: the re-stored key was not a hit"
drv "prs_wake_seen() { [ \"\$2\" = pr ] && return 0; return 2; }; $(get 8 "$(sha 8)" "$UPD" "$T/o4")"
[ "$(reads pulls/8)" = 3 ] && ok || bad "N3 a pr wake did not force a read"
# A cached body whose head was hand-edited.
jq -c '.head.sha = "ffffffffffffffffffffffffffffffffffffffff"' "$D/pr-8.json" > "$T/x" && mv "$T/x" "$D/pr-8.json"
drv "$(get 8 "$(sha 8)" "$UPD" "$T/o5")"
[ "$(reads pulls/8)" = 4 ] && [ "$(jq -r .head.sha "$T/o5")" = "$(sha 8)" ] && ok || bad "N4 a cached body with another head was a hit"
# The same head with another updated_at.
drv "$(get 8 "$(sha 8)" 2026-10-05T11:00:00Z "$T/o6")"
[ "$(reads pulls/8)" = 5 ] && ok || bad "N5 another updated_at was a hit"
# A body whose head is not the list head is never stored.
reset; pr 9 "$(sha 9)" true clean "$(sha a)"
drv "$(get 9 "$(sha 9)" "$UPD" "$T/o1"); $(get 9 "$(sha 9)" "$UPD" "$T/o2")"
[ "$(reads pulls/9)" = 2 ] && [ ! -e "$D/pr-9.key" ] && ok || bad "N6 a body with another head than the list was stored"

# ── O1..O3: the open list ──
reset; pr 1 "$(sha 1)" true
mkdir -p "$D"; echo '[{"number":77}]' > "$D/open.json"; echo "$NOW" > "$D/open.meta"
drv "prs_open_list $SLUG $T/o1"
[ "$DRC" = 0 ] && [ "$(lreads)" = 0 ] && cmp -s "$T/o1" "$D/open.json" && ok || bad "O1 a fresh open.json was not served ($(lreads) reads)"
echo "$((NOW - 120))" > "$D/open.meta"
drv "prs_wake_seen() { [ \"\$2\" = any ] && return 1; return 2; }; prs_open_list $SLUG $T/o2"
[ "$(lreads)" = 0 ] && cmp -s "$T/o2" "$D/open.json" && ok || bad "O2 quiet (no wake) at 120s was not served from cache"
drv "prs_open_list $SLUG $T/o3"
[ "$(lreads)" = 1 ] && [ "$(jq -c '[.[].number]' "$T/o3")" = '[1]' ] && ok || bad "O2 rc 2 at 120s did not refresh"
M=$(cat "$D/open.meta"); [ $((M - NOW)) -ge 0 ] && [ $((M - NOW)) -lt 30 ] && ok || bad "O3 open.meta was not rewritten to now ($M vs $NOW)"
[ "$(jq -c '[.[].number]' "$D/open.json")" = '[1]' ] && ok || bad "O3 open.json was not rewritten with the live list"

# ── B1: a push wake on the base re-reads the tip inside its TTL ──
reset
drv "prs_base_tip $SLUG main; prs_base_tip $SLUG main"
[ "$(reads git/ref/heads/main)" = 1 ] && [ "$(sort -u "$T/drv.out")" = "$TIPA" ] && ok || bad "B1 setup: $(reads git/ref/heads/main) reads, $(cat "$T/drv.out")"
drv "prs_wake_seen() { [ \"\$2\" = push ] && [ \"\$3\" = main ] && return 0; return 2; }; prs_base_tip $SLUG main"
[ "$(reads git/ref/heads/main)" = 2 ] && ok || bad "B1 a push wake did not re-read the tip"
echo nope > "$T/tip"; printf '%s\t%s\n' "$((NOW - 120))" "$TIPA" > "$D/base-main"
drv "prs_base_tip $SLUG main"
[ "$DRC" = 1 ] && [ ! -s "$T/drv.out" ] && ok || bad "B1 an unreadable tip printed '$(cat "$T/drv.out")' rc $DRC"

# ── G1: prs_gc ──
reset; mkdir -p "$D"; echo '{}' > "$D/pr-9.json"; echo '{}' > "$D/pr-8.json"; echo '[]' > "$D/open.json"
touch -d "@$((NOW - 4 * 86400))" "$D/pr-9.json" "$D/open.json"
drv "prs_gc"
[ ! -e "$D/pr-9.json" ] && [ -e "$D/pr-8.json" ] && [ -e "$D/open.json" ] && ok || bad "G1 prs_gc: $(ls "$D")"

# ── E1: the lock open never swallows the caller's stderr ──
# Unwrapped calls on the store path (the lock is opened), then a stderr line
# from the same process: it has to reach the caller.
reset; pr 4 "$(sha 4)" true
drv "prs_open_list $SLUG $T/o1; echo after-open >&2"
[ -e "$D/open.json" ] && ok || bad "E1 setup: prs_open_list did not take the store path ($(ls "$D" 2>/dev/null))"
grep -qx after-open "$T/drv.out" && ok || bad "E1 prs_open_list sent the caller's stderr to /dev/null"
drv "$(get 4 "$(sha 4)" "$UPD" "$T/o2"); echo after-get >&2"
[ -e "$D/pr-4.key" ] && ok || bad "E1 setup: prs_pr_get did not take the store path ($(ls "$D" 2>/dev/null))"
grep -qx after-get "$T/drv.out" && ok || bad "E1 prs_pr_get sent the caller's stderr to /dev/null"

# ── W1: the wakes sibling is sourced when present ──
reset; pr 3 "$(sha 3)" true
drv 'prs_wake_seen x pr 1 0; echo "rc=$?"'
[ "$(cat "$T/drv.out")" = rc=2 ] && ok || bad "W1 the default prs_wake_seen answered $(cat "$T/drv.out")"
printf 'prs_wake_seen() { return 0; }\n' > "$H/bin/lib/pr-snapshot-wakes.sh"
drv "$(get 3 "$(sha 3)" "$UPD" "$T/o1"); $(get 3 "$(sha 3)" "$UPD" "$T/o2")"
[ "$(reads pulls/3)" = 2 ] && ok || bad "W1 a planted wakes file was not sourced ($(reads pulls/3) reads)"

# ═══════════ dispatcher section (BH-5874): gate 16 on the worklist ═══════════
T="$T/disp"; mkdir -p "$T"
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
[ -r "$H/bin/lib/lead-gates.d/55-snapshot.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/55-snapshot.sh"
printf 'lg_gate_zz_hold() { echo "$2" >> "%s"; return 11; }\n' "$T/log/g99" > "$H/bin/lib/lead-gates.d/99-hold.sh"
pulls101() { lwf_cnt 'repos/example-org/demo-os/pulls/101' "$T/log/gh"; }
lists() { lwf_cnt 'repos/example-org/demo-os/pulls .*page=' "$T/log/gh"; }
g99() { lwf_cnt '^101$' "$T/log/g99"; }
sreset() { lwf_reset; scratch_rm "$H/state/pr-snapshot"; lwf_needs example-org/demo-os 101; }

# ── DS1 / DS2: miss, then hit ──
sreset
PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=300 PR_SNAPSHOT_QUIET_TTL_S=300 lwf_tick
grep -q 'PR-SNAPSHOT example-org/demo-os#101 miss' "$L" && ok || bad "DS1 no miss line: $(cat "$L")"
[ "$(pulls101)" = 1 ] && ok || bad "DS1 pulls/101 reads=$(pulls101) (want 1): $(cat "$T/log/gh")"
[ "$(g99)" = 1 ] && ok || bad "DS1 the gate after 55 ran $(g99) times"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "DS1 summary: $(lwf_summary)"
PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=300 PR_SNAPSHOT_QUIET_TTL_S=300 lwf_tick
[ "$(lwf_cnt 'PR-SNAPSHOT example-org/demo-os#101 hit' "$L")" = 1 ] && ok || bad "DS2 no hit line: $(grep PR-SNAPSHOT "$L")"
[ "$(pulls101)" = 1 ] && ok || bad "DS2 pulls/101 reads after 2 ticks=$(pulls101) (want 1)"

# ── DS3: the body names another head ──
sreset
SHA3=$(printf '%040d' 3)
lwf_needs_at example-org/demo-os "$SHA3" 101
PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=300 lwf_tick
grep -q "example-org/demo-os#101 @${SHA3:0:12}: the PR body names head ${SHA:0:12}, not the worklist head; held" "$L" && ok || bad "DS3 no held head line: $(cat "$L")"
[ "$(g99)" = 0 ] && ok || bad "DS3 a moved head must hold: the gates after 55 ran ($(g99))"

# ── DS4: the body read fails ──
# basefail: a gate's read in the tick itself (the fixture's ghfail fires only in
# review_one's pool worker). Gate 15 shares gate 16's one body read, so the
# failed read holds at gate 15, the first gate that needs the body.
sreset; : > "$FX/basefail.101"
PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=300 lwf_tick
grep -qE "example-org/demo-os#101 .*unreadable.*held" "$L" && ok || bad "DS4 no held unreadable line: $(cat "$L")"
[ "$(g99)" = 0 ] && ok || bad "DS4 a failed read must hold: the gates after 55 ran ($(g99))"

# ── DS5: the snapshot off: no list read, a live read each tick ──
sreset
PR_SNAPSHOT=0 lwf_tick; PR_SNAPSHOT=0 lwf_tick
[ "$(lists)" = 0 ] && ok || bad "DS5 open-PR list reads=$(lists) with the snapshot off"
[ "$(lwf_cnt 'PR-SNAPSHOT example-org/demo-os#101 miss' "$L")" = 2 ] && ok || bad "DS5 miss lines: $(grep PR-SNAPSHOT "$L")"
[ "$(pulls101)" = 2 ] && ok || bad "DS5 pulls/101 reads=$(pulls101) (want 2)"

echo "pr-snapshot: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
