#!/bin/bash
# tests/repo-activity.bh-8417-test.sh — BH-8417 scope F: Archie reports from
# the repo, not from log lines.
#
# WHAT IS PINNED. bin/repo-activity.sh <owner/repo> [--since <iso|Nh>] prints
# one line per GitHub event, `<iso> <kind> #<n> <sha8> <detail>`, sorted by
# time: merged, opened, closed (unmerged), push (a PR head that differs from
# the local heads file) and ci (a completed Actions run). Every read goes
# through gh_rest (bin/lib/gh-rest.sh), so a repeat read is an ETag 304. A
# failed read prints `UNREADABLE <endpoint> HTTP <code>`, exits 75 and prints
# NO event line. A page cap (REPO_ACTIVITY_MAX_PAGES, default 5) prints
# `INCOMPLETE <endpoint> pages=<n>`. bin/archie.sh's prompt carries the block
# archie_repo_activity_block (bin/lib/archie-repo-activity.sh) builds, capped
# at ARCHIE_REPO_ACTIVITY_LINES, and the soul section 25-repo-truth.md says a
# status claim cites it.
#
# Nothing touches the network. `gh` is a PATH stub that answers from fixture
# files under $T/resp and answers 304 when If-None-Match equals the fixture's
# ETag, the way GitHub does; the real gh_rest and its ETag cache run on top.
# The clock is pinned through REPO_ACTIVITY_NOW.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/repo-activity.bh-8417-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null || { echo "jq missing, skipping"; exit 0; }

RA_SRC="$DIR/bin/repo-activity.sh"
LIB_SRC="$DIR/bin/lib/archie-repo-activity.sh"
SOUL_SRC="$DIR/prompts/archie-soul.d/25-repo-truth.md"
KNOB_SRC="$DIR/catalog/lanes.d/_lib.repo-activity.json"
LINES_KNOB_SRC="$DIR/catalog/lanes.d/archie.knobs.d/ARCHIE_REPO_ACTIVITY_LINES.json"
SINCE_KNOB_SRC="$DIR/catalog/lanes.d/archie.knobs.d/ARCHIE_REPO_ACTIVITY_SINCE_H.json"
ARCHIE_SRC="$DIR/bin/archie.sh"
for f in "$RA_SRC" "$LIB_SRC" "$SOUL_SRC" "$KNOB_SRC" "$LINES_KNOB_SRC" "$SINCE_KNOB_SRC"; do
  [ -f "$f" ] || bad "F0 missing source ${f#"$DIR"/}"
done

# ── the scratch harness ─────────────────────────────────────────────────────
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/catalog" "$T/tmp" "$T/fakebin" "$T/resp"
for s in bin/repo-activity.sh bin/fleet-conf.sh bin/lib/archie-repo-activity.sh; do
  [ -f "$DIR/$s" ] && { scratch_install_closure "$s" "$T/h" >/dev/null || bad "F0 closure install $s"; }
done
cp -r "$DIR/catalog/lanes.d" "$T/h/catalog/"
export TMPDIR="$T/tmp" GH_STUB_DIR="$T" HARNESS_TEST_SANDBOX=1
unset GH_TOKEN GITHUB_TOKEN GH_ETAG REPO_ACTIVITY_MAX_PAGES ARCHIE_REPO_ACTIVITY_LINES ARCHIE_REPO_ACTIVITY_SINCE_H JOBS_URL HARNESS_SECRET
export JOBS_URL=""
NOW=$(date -u -d '2026-10-26T12:00:00Z' +%s)   # determinism: ok pinned clock
export REPO_ACTIVITY_NOW="$NOW"
export PATH="$T/fakebin:$PATH"
RA="$T/h/bin/repo-activity.sh"

# ── the gh stub ─────────────────────────────────────────────────────────────
# `gh api -i -X GET repos/<o>/<r>/<sub> [-f k=v | -F k=v ...] [-H If-None-Match: x]`.
# The fixture is resp/<o>__<r>/<pulls|runs>.<page>.json, with an optional
# .status file. No fixture = 404. One line per call in calls.txt:
# `<status> <endpoint> page=<n>`.
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
S="$GH_STUB_DIR"
ep=""; inm=""; page=1; prev=""
for a in "$@"; do
  case "$prev" in
    -H) case "$a" in If-None-Match:*) inm="${a#If-None-Match: }" ;; esac ;;
    -f|-F) case "$a" in page=*) page="${a#page=}" ;; esac ;;
    -X) ;;
    *) case "$a" in -*|api) ;; *) [ -z "$ep" ] && ep="$a" ;; esac ;;
  esac
  prev="$a"
done
o=$(printf '%s' "$ep" | cut -d/ -f2); r=$(printf '%s' "$ep" | cut -d/ -f3)
case "$ep" in */pulls) k=pulls ;; */actions/runs) k=runs ;; *) k=other ;; esac
f="$S/resp/${o}__${r}/$k.$page.json"
st=200
[ -f "$f" ] || st=404
[ -f "${f%.json}.status" ] && st=$(cat "${f%.json}.status")
etag=""
[ "$st" = 200 ] && etag="\"fx-$(sha1sum < "$f" | cut -c1-16)\""
[ "$st" = 200 ] && [ -n "$inm" ] && [ "$inm" = "$etag" ] && st=304
printf '%s %s page=%s\n' "$st" "$ep" "$page" >> "$S/calls.txt"
txt=OK; case "$st" in 304) txt="Not Modified" ;; 404) txt="Not Found" ;; 500) txt="Server Error" ;; esac
printf 'HTTP/2.0 %s %s\r\n' "$st" "$txt"
[ -n "$etag" ] && printf 'Etag: %s\r\n' "$etag"
printf 'Content-Type: application/json\r\n\r\n'
case "$st" in
  200) cat "$f" ;;
  304) ;;
  *) printf '{"message":"fixture error"}' ;;
esac
case "$st" in 2*|304) exit 0 ;; *) exit 1 ;; esac
STUB
chmod +x "$T/fakebin/gh"

SLUG=fixture-org/fixture-repo
FX="$T/resp/fixture-org__fixture-repo"
mkdir -p "$FX"
sha() { printf '%s' "$1" | sha1sum | cut -c1-40; }   # a fixed 40-hex sha per word
S_MERGE=$(sha merge); S_101=$(sha head101); S_102=$(sha head102); S_103=$(sha head103)
S_104=$(sha head104); S_104OLD=$(sha head104old); S_105=$(sha head105); S_RUN=$(sha run1)
pr() { # pr <n> <state> <created> <updated> <closed|null> <merged|null> <head> <merge_sha|null> <title>
  jq -n --argjson n "$1" --arg st "$2" --arg c "$3" --arg u "$4" --arg cl "$5" --arg m "$6" --arg h "$7" --arg ms "$8" --arg t "$9" \
    '{number:$n, state:$st, title:$t, created_at:$c, updated_at:$u,
      closed_at:(if $cl=="null" then null else $cl end), merged_at:(if $m=="null" then null else $m end),
      merge_commit_sha:(if $ms=="null" then null else $ms end), head:{sha:$h}}'
}
{
  pr 101 closed 2026-10-20T00:00:00Z 2026-10-26T11:00:00Z 2026-10-26T10:30:00Z 2026-10-26T10:30:00Z "$S_101" "$S_MERGE" "fixture merge"
  pr 102 open   2026-10-26T09:00:00Z 2026-10-26T09:05:00Z null null "$S_102" null "fixture open"
  pr 103 closed 2026-10-01T00:00:00Z 2026-10-26T08:00:00Z 2026-10-26T08:00:00Z null "$S_103" null "fixture close"
  pr 104 open   2026-10-10T00:00:00Z 2026-10-26T07:30:00Z null null "$S_104" null "fixture push"
  pr 105 open   2026-10-01T00:00:00Z 2026-10-25T00:00:00Z null null "$S_105" null "fixture old"
} | jq -s '.' > "$FX/pulls.1.json"
jq -n --arg h "$S_RUN" '{total_count:1, workflow_runs:[{id:9001, name:"Harness CI", status:"completed", conclusion:"failure",
  head_sha:$h, created_at:"2026-10-26T07:31:00Z", updated_at:"2026-10-26T07:45:00Z", pull_requests:[{number:104}]}]}' > "$FX/runs.1.json"
HEADS="$T/h/state/repo-activity/fixture-org_fixture-repo.heads"
mkdir -p "${HEADS%/*}"
printf '104 %s - -\n' "$S_104OLD" > "$HEADS"

# ═════ E: one of each event ══════════════════════════════════════════════════
: > "$T/calls.txt"
rc=0; "$RA" "$SLUG" --since 6h > "$T/e.out" 2> "$T/e.err" || rc=$?
check "E1 rc 0 (got $rc: $(head -c 300 "$T/e.err"))" '[ "$rc" = 0 ]'
check "E2 five event lines" '[ "$(wc -l < "$T/e.out")" = 5 ]'
check "E3 kinds in time order" '[ "$(awk "{print \$2}" "$T/e.out" | tr "\n" " ")" = "push ci closed opened merged " ]'
check "E4 PR numbers in time order" '[ "$(awk "{print \$3}" "$T/e.out" | tr "\n" " ")" = "#104 #104 #103 #102 #101 " ]'
check "E5 merged line names the merge sha and time" 'grep -qx "2026-10-26T10:30:00Z merged #101 ${S_MERGE:0:8} fixture merge" "$T/e.out"'
check "E6 opened line" 'grep -qx "2026-10-26T09:00:00Z opened #102 ${S_102:0:8} fixture open" "$T/e.out"'
check "E7 closed line is the unmerged close" 'grep -qx "2026-10-26T08:00:00Z closed #103 ${S_103:0:8} fixture close" "$T/e.out"'
check "E8 push line names old and new head" 'grep -q "^2026-10-26T07:30:00Z push #104 ${S_104:0:8} .*${S_104OLD:0:8}" "$T/e.out"'
check "E9 ci line names workflow and conclusion" 'grep -qx "2026-10-26T07:45:00Z ci #104 ${S_RUN:0:8} Harness CI failure" "$T/e.out"'
check "E10 the old PR #105 is not an event" '! grep -q "#105" "$T/e.out"'
check "E11 heads file records the new head" 'grep -q "^104 $S_104 " "$HEADS"'
check "E12 pulls read with state=all sort=updated" 'grep -q "^200 repos/$SLUG/pulls page=1" "$T/calls.txt"'
check "E13 one runs read" '[ "$(grep -c "actions/runs" "$T/calls.txt")" = 1 ]'
check "E14 no tmp file left in heads dir" '[ "$(ls "${HEADS%/*}" | grep -vc "\.heads$")" = 0 ]'

# ═════ C: the second run is served by the ETag cache ═════════════════════════
: > "$T/calls.txt"
rc=0; "$RA" "$SLUG" --since 6h > "$T/c.out" 2>/dev/null || rc=$?
check "C1 rc 0 on the cached run" '[ "$rc" = 0 ]'
check "C2 same lines as the first run" 'cmp -s "$T/e.out" "$T/c.out"'
check "C3 zero body downloads (no 200)" '[ "$(grep -c "^200 " "$T/calls.txt")" = 0 ]'
check "C4 every read answered 304" '[ "$(grep -c "^304 " "$T/calls.txt")" = 2 ]'

# ═════ S: --since forms ══════════════════════════════════════════════════════
rc=0; "$RA" "$SLUG" --since 2026-10-26T06:00:00Z > "$T/s1.out" 2>/dev/null || rc=$?
check "S1 ISO --since rc 0 and equal to 6h" '[ "$rc" = 0 ] && cmp -s "$T/e.out" "$T/s1.out"'
rc=0; "$RA" "$SLUG" > "$T/s0.out" 2>/dev/null || rc=$?
check "S2 default --since is 6h" '[ "$rc" = 0 ] && cmp -s "$T/e.out" "$T/s0.out"'
rc=0; "$RA" "$SLUG" --since 2h > "$T/s2.out" 2>/dev/null || rc=$?
check "S3 --since 2h keeps only the 10:30 merge" '[ "$rc" = 0 ] && [ "$(awk "{print \$2}" "$T/s2.out" | tr "\n" " ")" = "merged " ]'
rc=0; "$RA" "$SLUG" --since yesterday > /dev/null 2>&1 || rc=$?
check "S4 a bad --since is a usage error (rc 2), not an empty list" '[ "$rc" = 2 ]'
rc=0; "$RA" "not a slug" > /dev/null 2>&1 || rc=$?
check "S5 a bad slug is rc 2" '[ "$rc" = 2 ]'

# ═════ B: first run, no heads file: baseline, no push claim ══════════════════
FB="$T/resp/fixture-org__fixture-base"; mkdir -p "$FB"
cp "$FX/pulls.1.json" "$FX/runs.1.json" "$FB/"
rc=0; "$RA" fixture-org/fixture-base --since 6h > "$T/b.out" 2>/dev/null || rc=$?
check "B1 rc 0" '[ "$rc" = 0 ]'
check "B2 no push line without a baseline" '! grep -q " push " "$T/b.out"'
check "B3 four other events" '[ "$(wc -l < "$T/b.out")" = 4 ]'
check "B4 the baseline is written" 'grep -q "^104 $S_104 " "$T/h/state/repo-activity/fixture-org_fixture-base.heads"'

# ═════ U: unreadable is never empty ══════════════════════════════════════════
FU="$T/resp/fixture-org__fixture-down"; mkdir -p "$FU"
cp "$FX/pulls.1.json" "$FX/runs.1.json" "$FU/"
echo 500 > "$FU/pulls.1.status"
rc=0; "$RA" fixture-org/fixture-down --since 6h > "$T/u.out" 2>/dev/null || rc=$?
check "U1 a 500 on pulls is rc 75 (got $rc)" '[ "$rc" = 75 ]'
check "U2 the UNREADABLE line names endpoint and status" 'grep -qx "UNREADABLE repos/fixture-org/fixture-down/pulls HTTP 500" "$T/u.out"'
check "U3 no event line on an unreadable read" '[ "$(grep -vc "^UNREADABLE " "$T/u.out")" = 0 ]'
check "U4 no heads state written on a failed run" '[ ! -e "$T/h/state/repo-activity/fixture-org_fixture-down.heads" ]'
rm -f "$FU/pulls.1.status"; echo 500 > "$FU/runs.1.status"
rc=0; "$RA" fixture-org/fixture-down --since 6h > "$T/u2.out" 2>/dev/null || rc=$?
check "U5 a 500 on runs after good pulls is rc 75" '[ "$rc" = 75 ]'
check "U6 runs UNREADABLE line" 'grep -qx "UNREADABLE repos/fixture-org/fixture-down/actions/runs HTTP 500" "$T/u2.out"'
check "U7 no partial PR events printed" '[ "$(grep -vc "^UNREADABLE " "$T/u2.out")" = 0 ]'

# ═════ P: the page cap ═══════════════════════════════════════════════════════
FP="$T/resp/fixture-org__fixture-busy"; mkdir -p "$FP"
for p in 1 2 3 4 5 6; do
  jq -n --argjson p "$p" --arg h "$S_105" '[range(0;100) | {number: (($p*1000)+.), state:"open", title:"fixture busy",
     created_at:"2026-10-01T00:00:00Z", updated_at:"2026-10-26T11:00:00Z", closed_at:null, merged_at:null,
     merge_commit_sha:null, head:{sha:$h}}]' > "$FP/pulls.$p.json"
done
echo '{"total_count":0,"workflow_runs":[]}' > "$FP/runs.1.json"
: > "$T/calls.txt"
rc=0; REPO_ACTIVITY_MAX_PAGES=1 "$RA" fixture-org/fixture-busy --since 6h > "$T/p1.out" 2>/dev/null || rc=$?
check "P1 cap 1 with 2+ pages: rc 0" '[ "$rc" = 0 ]'
check "P2 INCOMPLETE pages=1 line" 'grep -qx "INCOMPLETE repos/fixture-org/fixture-busy/pulls pages=1" "$T/p1.out"'
check "P3 cap 1 read one pulls page" '[ "$(grep -c "fixture-busy/pulls" "$T/calls.txt")" = 1 ]'
: > "$T/calls.txt"
rc=0; "$RA" fixture-org/fixture-busy --since 6h > "$T/p5.out" 2>/dev/null || rc=$?
check "P4 no knob row: default cap 5 -> INCOMPLETE pages=5" '[ "$rc" = 0 ] && grep -qx "INCOMPLETE repos/fixture-org/fixture-busy/pulls pages=5" "$T/p5.out"'
check "P5 default cap read exactly 5 pulls pages" '[ "$(grep -c "fixture-busy/pulls" "$T/calls.txt")" = 5 ]'
check "P6 the registry default is 5" '[ "$(jq "[.libs[].knobs[] | select(.env==\"REPO_ACTIVITY_MAX_PAGES\") | .default][0]" "$KNOB_SRC")" = 5 ]'
rc=0; REPO_ACTIVITY_MAX_PAGES=abc "$RA" fixture-org/fixture-busy --since 6h > "$T/p7.out" 2>/dev/null || rc=$?
check "P7 a non-integer knob uses the default 5" 'grep -qx "INCOMPLETE repos/fixture-org/fixture-busy/pulls pages=5" "$T/p7.out"'

# ═════ A: the Archie briefing block ══════════════════════════════════════════
FS="$T/resp/fixture-org__fixture-self"; mkdir -p "$FS"
cp "$FX/pulls.1.json" "$FX/runs.1.json" "$FS/"
cat > "$T/fleet.conf" <<'CONF'
# fixture fleet.conf
fixture-one   fixture-org/fixture-repo   https://app.example.invalid  /api/board  2 fixture-box 192.0.2.10
fixture-two   fixture-org/fixture-gone   https://two.example.invalid  -           3 fixture-box 192.0.2.10
fixture-self  fixture-org/fixture-self   -                            -           4 fixture-box 192.0.2.10
CONF
export FLEET_CONF="$T/fleet.conf" HARNESS_REPO=fixture-org/fixture-self
# shellcheck source=/dev/null
. "$T/h/bin/lib/archie-repo-activity.sh" 2>/dev/null || bad "A0 cannot source bin/lib/archie-repo-activity.sh"
if command -v archie_repo_activity_block >/dev/null 2>&1; then
  ARCHIE_REPO_ACTIVITY_SANDBOX=1 ARCHIE_REPO_ACTIVITY_LINES=3 archie_repo_activity_block > "$T/a.out" 2>/dev/null
  check "A1 block header" 'grep -qx "## Repo activity (last 6h)" "$T/a.out"'
  check "A2 the stub merge line is in the block" 'grep -q "fixture-org/fixture-repo 2026-10-26T10:30:00Z merged #101 ${S_MERGE:0:8}" "$T/a.out"'
  check "A3 cap 3: three event lines" '[ "$(grep -cE "^[^ ]+ 20[0-9-]+T" "$T/a.out")" = 3 ]'
  check "A4 the UNREADABLE line of the absent repo is kept past the cap" 'grep -q "^fixture-org/fixture-gone UNREADABLE repos/fixture-org/fixture-gone/pulls HTTP 404" "$T/a.out"'
  check "A5 the cut is said, never silent" 'grep -q "ARCHIE_REPO_ACTIVITY_LINES=3" "$T/a.out"'
  check "A6 the self repo is read once, not twice" '[ "$(grep -c "fixture-self/pulls" "$T/calls.txt")" -ge 1 ] && [ "$(grep -c "^fixture-org/fixture-self 2026-10-26T10:30:00Z merged" "$T/a.out")" = 1 ]'
  ARCHIE_REPO_ACTIVITY_SANDBOX=1 archie_repo_activity_block > "$T/a40.out" 2>/dev/null
  # 5 events of fixture-repo (its push re-reads from the heads file) + 4 of
  # fixture-self (baseline taken on the A1 run, so no push).
  check "A7 default cap 40 keeps all 9 events" '[ "$(grep -cE "^[^ ]+ 20[0-9-]+T" "$T/a40.out")" = 9 ] && ! grep -q "ARCHIE_REPO_ACTIVITY_LINES=" "$T/a40.out"'
  : > "$T/calls.txt"
  archie_repo_activity_block > "$T/asb.out" 2>/dev/null
  check "A8 in a sandbox without the opt-in it makes no read" '[ ! -s "$T/calls.txt" ] && grep -qx "## Repo activity (last 6h)" "$T/asb.out"'
  # BH-8417 lead review [BLOCK hardcoded-knob]: the window is the knob
  # ARCHIE_REPO_ACTIVITY_SINCE_H, not a literal 6h. A 1h window (NOW 12:00)
  # leaves out the 10:30 merge; the header names the window it read.
  ARCHIE_REPO_ACTIVITY_SANDBOX=1 ARCHIE_REPO_ACTIVITY_SINCE_H=1 archie_repo_activity_block > "$T/a1h.out" 2>/dev/null
  check "A12 knob 1h: the header says last 1h" 'grep -qx "## Repo activity (last 1h)" "$T/a1h.out"'
  check "A13 knob 1h: the 10:30 merge is outside the window" '! grep -q "merged #101" "$T/a1h.out"'
  check "A14 the knob is the default 6 with no env" '[ "$(archie_repo_activity_since_h)" = 6 ]'
  check "A15 knob 12 resolves to 12" '[ "$(ARCHIE_REPO_ACTIVITY_SINCE_H=12 archie_repo_activity_since_h)" = 12 ]'
  check "A16 knob outside 1..168 is the default" '[ "$(ARCHIE_REPO_ACTIVITY_SINCE_H=0 archie_repo_activity_since_h)" = 6 ] && [ "$(ARCHIE_REPO_ACTIVITY_SINCE_H=169 archie_repo_activity_since_h)" = 6 ] && [ "$(ARCHIE_REPO_ACTIVITY_SINCE_H=abc archie_repo_activity_since_h)" = 6 ]'
else
  bad "A0 archie_repo_activity_block is not defined"
fi
check "A9 the registry default for ARCHIE_REPO_ACTIVITY_LINES is 40" '[ "$(jq .default "$LINES_KNOB_SRC" 2>/dev/null)" = 40 ]'
check "A9b the registry default for ARCHIE_REPO_ACTIVITY_SINCE_H is 6" '[ "$(jq .default "$SINCE_KNOB_SRC" 2>/dev/null)" = 6 ]'
check "A9c the lib passes no literal --since 6h" '! grep -qE -- "^[^#]*--since 6h" "$LIB_SRC"'
# D2: the production call site. bin/archie.sh sources the lib and puts the
# block in the check prompt; deleting either line turns this red.
check "A10 bin/archie.sh sources the lib" '[ "$(grep -v "^[[:space:]]*#" "$ARCHIE_SRC" | grep -c "lib/archie-repo-activity.sh")" -ge 1 ]'
check "A11 bin/archie.sh puts the block in the prompt" '[ "$(grep -v "^[[:space:]]*#" "$ARCHIE_SRC" | grep -c "archie_repo_activity_block")" -ge 1 ]'

# B1-B2: the operator's chat turn. bin/orchestrate.sh's compose_v2_prompt, the real
# function text, carries the block between the facts and the conversation.
FN=$(sed -n '/^compose_v2_prompt() {/,/^}/p' "$DIR/bin/orchestrate.sh")
mkdir -p "$T/orc"
V2=$(env HARNESS="$T/h" ARCHIE_ORC_DIR="$T/orc" ORC_TURN_STATE="$T/orc/STATE.md" TEXT=hi META_TRANSPORT=telegram ORIGIN="" \
  ARCHIE_REPO_ACTIVITY_SANDBOX=1 bash -c "$FN"$'\n''compose_v2_prompt' 2>/dev/null)
BL=$(grep -n '^=== REPO ACTIVITY (last 6h, GitHub REST) ===$' <<<"$V2" | cut -d: -f1)
RL=$(grep -n '^=== RECENT CONVERSATION' <<<"$V2" | cut -d: -f1)
check "B1 the chat-turn briefing carries the block before the conversation ($BL/$RL)" '[ -n "$BL" ] && [ -n "$RL" ] && [ "$BL" -lt "$RL" ]'
check "B2 the stub merge line is in the chat-turn briefing" 'grep -q "fixture-org/fixture-repo 2026-10-26T10:30:00Z merged #101" <<<"$V2"'

# ═════ O: the soul section ═══════════════════════════════════════════════════
SOUL=$(cat "$DIR"/prompts/archie-soul.d/*.md 2>/dev/null)
check "O1 the soul glob carries repo-activity" 'grep -q "repo-activity" <<<"$SOUL"'
check "O2 the soul names the github: facts string" 'grep -qF "github:" "$SOUL_SRC"'
check "O3 never a log line alone" 'grep -qi "log line" "$SOUL_SRC"'
check "O4 no em or en dash in the section" '! grep -qP "[\x{2013}\x{2014}]" "$SOUL_SRC"'

# ═════ K: the registry renders ═══════════════════════════════════════════════
check "K1 the lanes registry builds with both knobs" 'HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --check >/dev/null 2>&1'

echo "repo-activity.bh-8417: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
