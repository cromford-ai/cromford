#!/bin/bash
# tests/plan-blocked-repeat.bh-7719-test.sh — BH-7719 part 4: one PLAN_BLOCKED
# notice per ticket until a person answers it.
#
# pb_notice deduped on a hash of the plan's blocked section. Each re-plan words
# the same question differently, so each re-plan was a new hash and a new
# comment: #7655 got 11 of them on 2026-10-20. pb_notice now keeps a per-ticket
# marker (`plan-blocked-last <project> <KEY>`, the epoch of the last post) and
# posts again only when a human comment was created or edited after it.
#
#   P1 two runs, new wording, nobody answered: 1 POST, the second RESULT marked
#   P2 a human comment after the marker: posts, the marker moves
#   P2b a cleared marker and no file: posts
#   P3 only bot comments, or a human comment from before the marker: no post
#   P3b a human comment EDITED after the marker: posts
#   P4 the ledger is down, the .last file holds the epoch: suppressed
#   P5 the thread read fails: no post, RESULT marked (fail closed)
#   P6 a refused POST writes no per-ticket marker: the next run posts
#
# Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/builds" "$H/flags" "$T/fakebin" "$T/srv"
export HARNESS="$H" FLEET_CONF="$DIR/fleet.conf"
for L in bin/lib/plan-blocked.sh bin/transcript-scrub.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf 'HARNESS_SECRET=fixture-secret-7719\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"

# gh: the REST wire shape. A comment POST is counted; a GET of the issue's
# comments answers $SRV/thread.json with $GH_GET_STATUS (default 200).
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  *"-X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "$*" >> "$POST_SINK"
    st="${GH_POST_STATUS:-201}"
    printf 'HTTP/2.0 %s X\r\nx-stub: 1\r\n\r\n{"id":1}\n' "$st"
    case "$st" in 2*) exit 0 ;; *) exit 1 ;; esac ;;
  *"-X GET repos/"*"/issues/"*"/comments"*)
    st="${GH_GET_STATUS:-200}"
    printf 'HTTP/2.0 %s X\r\nx-stub: 1\r\n\r\n%s\n' "$st" "$(cat "$SRV/thread.json" 2>/dev/null || echo '[]')"
    case "$st" in 2*) exit 0 ;; *) exit 1 ;; esac ;;
esac
exit 1
SH
# curl: the jobs worker's ledger, a tiny store, so the marker ROW path is real.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""; prev=""
for a in "$@"; do
  [ "$prev" = -X ] && M="$a"
  [ "$prev" = --data-binary ] && BODY="$a"
  prev="$a"
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
case "$M $URL" in
  "PUT "*/api/ledger)
    k=$(printf '%s' "$BODY" | jq -r '"kind="+(.kind|@uri)+"&key="+(.key|@uri)')
    grep -vF "$k	" "$SRV/ledger.tsv" > "$SRV/ledger.tmp" 2>/dev/null; mv -f "$SRV/ledger.tmp" "$SRV/ledger.tsv"
    printf '%s\t%s\n' "$k" "$(printf '%s' "$BODY" | jq -c '{status, detail: (.detail // "")}')" >> "$SRV/ledger.tsv"
    printf '{"ok":true}\n200' ;;
  "GET "*/api/ledger\?*)
    q="${URL#*\?}"; row=$(grep -F "$q	" "$SRV/ledger.tsv" 2>/dev/null | head -1 | cut -f2)
    if [ -n "$row" ]; then printf '{"ledger":%s}\n200' "$row"; else printf '{"error":"no row"}\n404'; fi ;;
  *) printf '{"ok":true}\n200' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH" GH_SINK="$T/gh.log" POST_SINK="$T/posts.log" SRV="$T/srv"
export GH_TOKEN_LIVE_FILE="$T/no-such-token"
unset GH_TOKEN 2>/dev/null

# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/plan-blocked.sh
. "$H/bin/lib/plan-blocked.sh" 2>/dev/null && command -v pb_notice >/dev/null 2>&1 && ok \
  || bad "bin/lib/plan-blocked.sh does not load or defines no pb_notice"

nposts() { local n; n=$(grep -c . "$POST_SINK" 2>/dev/null); echo "${n:-0}"; }
P=cromford; K=BH-7655
B="$H/builds/$P-$K-202610201400"
MKEY="plan-blocked-last $P $K"; MFILE="$H/state/plan-blocked/$P/$K.last"
seed() { # seed <plan-text>
  scratch_rm "$B"; mkdir -p "$B"
  printf 'PLAN_BLOCKED %s/plan.md\nBUILD_DIR: %s\n' "$B" "$B" > "$B/RESULT"
  printf '%s' "$1" > "$B/plan.md"
}
reset_all() { : > "$POST_SINK"; : > "$GH_SINK"; : > "$SRV/ledger.tsv"; echo '[]' > "$SRV/thread.json"
              scratch_rm "$H/state"; mkdir -p "$H/state"; }
notice() { pb_notice "$H" "$P" 7655 "$K" "$B" >> "$T/notice.log" 2>&1; }
marker_epoch() { job_ledger_row commented "$MKEY" 2>/dev/null | jq -r '.detail // ""'; }
set_marker() { # set_marker <epoch>: the row and the file, as a post leaves them
  job_ledger_put commented "$MKEY" commented "$1" >/dev/null 2>&1
  mkdir -p "${MFILE%/*}"; printf '%s\n' "$1" > "$MFILE"
}
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
comment() { # comment <type> <login> <created-epoch> <updated-epoch>
  jq -nc --arg t "$1" --arg l "$2" --arg c "$(iso "$3")" --arg u "$(iso "$4")" \
    '{user:{type:$t,login:$l},created_at:$c,updated_at:$u,body:"x"}'
}
thread() { printf '%s\n' "$@" | jq -s . > "$SRV/thread.json"; }
W1=$'BLOCKED: which column holds the fee?\nThe ticket names two fee fields.\n'
W2=$'BLOCKED: the fee column is not named.\nTwo fields could hold it.\n'
W3=$'BLOCKED: no fee field is chosen in the ticket.\n'

# ── P1 two runs, new wording, nobody answered ─────────────────────────────
reset_all; seed "$W1"; notice
[ "$(nposts)" = 1 ] && ok || bad "P1: the first notice posts (posts $(nposts)): $(tail -2 "$T/notice.log")"
E1=$(marker_epoch)
[[ "$E1" =~ ^[0-9]+$ ]] && ok || bad "P1: a post writes the per-ticket marker row (got '$E1')"
[ "$(cat "$MFILE" 2>/dev/null)" = "$E1" ] && ok || bad "P1: and the .last file: $(cat "$MFILE" 2>/dev/null)"
seed "$W2"; : > "$T/notice.log"; notice; RC=$?
[ "$(nposts)" = 1 ] && ok || bad "P1: THE POINT: new wording with nobody answering is not a second comment (posts $(nposts))"
[ "$RC" = 0 ] && ok || bad "P1: a suppressed notice answers rc 0 (rc $RC)"
L1=$(head -1 "$B/RESULT")
case "$L1" in *"CLOSED-OUT: "*"nobody has answered"*) ok ;; *) bad "P1: RESULT line 1 carries the marker and the reason: $L1" ;; esac
grep -q 'not posted' "$T/notice.log" && ok || bad "P1: the log says not posted: $(cat "$T/notice.log")"
[ "$(marker_epoch)" = "$E1" ] && ok || bad "P1: a suppressed run leaves the marker epoch alone ($E1 -> $(marker_epoch))"
grep -q -- '-X GET repos/example-org/cromford/issues/7655/comments?since=' "$GH_SINK" && ok \
  || bad "P1: the thread read is bounded by since=: $(grep GET "$GH_SINK")"

# ── P2 a human answered after the marker ──────────────────────────────────
NOW=$(date +%s)
set_marker $((NOW-100))
thread "$(comment User operator $((NOW-50)) $((NOW-50)))"
seed "$W3"; notice
[ "$(nposts)" = 2 ] && ok || bad "P2: a human comment after the marker lets the next notice post (posts $(nposts)): $(tail -2 "$T/notice.log")"
E2=$(marker_epoch)
[[ "$E2" =~ ^[0-9]+$ ]] && [ "$E2" -gt $((NOW-100)) ] && ok || bad "P2: the marker moves to the new post ($((NOW-100)) -> '$E2')"

# ── P2b a cleared marker and no file: posts ───────────────────────────────
reset_all; job_ledger_put commented "$MKEY" cleared - >/dev/null 2>&1
seed "$W1"; notice
[ "$(nposts)" = 1 ] && ok || bad "P2b: a cleared marker posts (posts $(nposts))"

# ── P3 only bots, or a human from before the marker: no post ──────────────
reset_all; NOW=$(date +%s); set_marker $((NOW-100))
thread "$(comment Bot 'example-org-harness[bot]' $((NOW-50)) $((NOW-50)))" \
       "$(comment User operator $((NOW-500)) $((NOW-500)))"
seed "$W2"; notice
[ "$(nposts)" = 0 ] && ok || bad "P3: bot comments and an older human comment do not lift the hold (posts $(nposts))"
grep -q 'nobody has answered' "$B/RESULT" && ok || bad "P3: the RESULT is marked: $(head -1 "$B/RESULT")"

# ── P3b a human comment EDITED after the marker: posts ────────────────────
reset_all; NOW=$(date +%s); set_marker $((NOW-100))
thread "$(comment User operator $((NOW-500)) $((NOW-20)))"
seed "$W2"; notice
[ "$(nposts)" = 1 ] && ok || bad "P3b: an edit after the marker is an answer (posts $(nposts))"

# ── P4 the ledger is down: the .last file answers ─────────────────────────
reset_all; NOW=$(date +%s); mkdir -p "${MFILE%/*}"; printf '%s\n' $((NOW-100)) > "$MFILE"
seed "$W2"
( job_ledger_row() { return 1; }; job_ledger_put() { return 1; }; notice )
[ "$(nposts)" = 0 ] && ok || bad "P4: the .last file holds the notice while the ledger is down (posts $(nposts))"
grep -q 'nobody has answered' "$B/RESULT" && ok || bad "P4: the RESULT is marked: $(head -1 "$B/RESULT")"

# ── P5 the thread read fails: fail closed ─────────────────────────────────
reset_all; NOW=$(date +%s); set_marker $((NOW-100))
thread "$(comment User operator $((NOW-50)) $((NOW-50)))"
seed "$W2"; : > "$T/notice.log"
GH_GET_STATUS=502 notice; RC=$?
[ "$(nposts)" = 0 ] && ok || bad "P5: a failed thread read posts nothing (posts $(nposts))"
[ "$RC" = 0 ] && grep -q 'CLOSED-OUT' "$B/RESULT" && ok || bad "P5: rc 0 and the RESULT is marked (rc $RC): $(head -1 "$B/RESULT")"

# ── P6 a refused POST leaves no per-ticket marker ─────────────────────────
reset_all; seed "$W1"
GH_POST_STATUS=422 notice
[ -e "$MFILE" ] && bad "P6: a refused POST wrote the .last file" || ok
[ -z "$(marker_epoch)" ] && ok || bad "P6: a refused POST wrote the marker row: $(marker_epoch)"
: > "$POST_SINK"; seed "$W2"; notice
[ "$(nposts)" = 1 ] && ok || bad "P6: the next run posts (posts $(nposts)): $(tail -2 "$T/notice.log")"

echo "plan-blocked-repeat (BH-7719): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
