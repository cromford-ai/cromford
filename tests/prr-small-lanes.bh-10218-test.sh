#!/bin/bash
# tests/prr-small-lanes.bh-10218-test.sh — BH-10218 (W4): four small lanes read
# their open PR list from the PR record through a prr-shadow seam.
#
# The seams under test:
#   bin/lib/prr-shadow.d/overlap-guard.sh     og_open_* (the --refresh list),
#                                             og_check_* (the launch check list)
#   bin/lib/prr-shadow.d/scheduler.sh         sched_parent_* (stack parent lookup)
#   bin/lib/prr-shadow.d/utilization-push.sh  util_heads_* (open PR heads)
#   bin/lib/prr-shadow.d/review-autopilot.sh  ra_open_* (the autopilot's open list)
#
# For each caller, the ticket's acceptance line: in step `record` with a
# trusted list a tick makes 0 GitHub `pulls` list calls and the result equals
# step `off`; with a stale list it makes the GitHub read (and one PRR_MISS
# line). Step `shadow` acts on GitHub and logs one PRR_SHADOW line when the
# record differs. Step `off` makes no jobs read. With no row, the step is
# `shadow` for each of the 4 lanes.
#
# Block OG drives the production entry point `bin/overlap-guard.sh --refresh`
# in a scratch harness. Block UP drives the production function
# util_section_tickets. SC and RA drive the seams through prr_read with the
# real lane functions (sw_parent_pr, harness_pr_list) on the GitHub side.
# Nothing touches the network: GitHub is a fixture (a fake `gh` on PATH, or a
# gh_rest function), the jobs worker is a fixture _jobs_req.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prr-small-lanes.bh-10218-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN GH_SOURCE GH_SOURCE_LANE H OVERLAP_MAIN_RECENT_MIN

SEAM_OG="$DIR/bin/lib/prr-shadow.d/overlap-guard.sh"
SEAM_SC="$DIR/bin/lib/prr-shadow.d/scheduler.sh"
SEAM_UP="$DIR/bin/lib/prr-shadow.d/utilization-push.sh"
SEAM_RA="$DIR/bin/lib/prr-shadow.d/review-autopilot.sh"
for f in "$SEAM_OG" "$SEAM_SC" "$SEAM_UP" "$SEAM_RA"; do
  [ -r "$f" ] && ok || bad "setup: $f is missing"
done

# rec_json <age_s> <rows-json> — the worker's /api/pr-records list answer.
rec_json() {
  jq -nc --argjson a "$1" --argjson r "$2" \
    '{rows: $r, truncated: false, sync: {age_s: $a, synced_at: "2026-11-26T10:00:00Z"}, missing: null, unknown: 0}'
}
ROW() { # ROW <n> <head_ref> <sha-char> [author] [created]
  jq -nc --argjson n "$1" --arg r "$2" --arg s "$(printf "%040d" 0 | tr 0 "$3")" --arg a "${4:-cromford[bot]}" \
    --arg c "${5:-2026-11-2${1: -1}T00:00:00Z}" \
    '{number: $n, title: ("t" + ($n|tostring)), head_ref: $r, head_sha: $s, base_ref: "main", author: $a,
      labels: [], body: "", mergeable_state: "clean", updated_at: $c, created_at: $c,
      url: ("https://github.com/example-org/demo/pull/" + ($n|tostring)), draft: 0}'
}
GHROW() { # GHROW <n> <head_ref> <sha-char> [author] [created] — the REST pulls shape
  jq -nc --argjson n "$1" --arg r "$2" --arg s "$(printf "%040d" 0 | tr 0 "$3")" --arg a "${4:-cromford[bot]}" \
    --arg c "${5:-2026-11-2${1: -1}T00:00:00Z}" \
    '{number: $n, title: ("t" + ($n|tostring)), state: "open", html_url: ("https://github.com/example-org/demo/pull/" + ($n|tostring)),
      draft: false, body: "", created_at: $c, updated_at: $c, merged_at: null, closed_at: null,
      user: {login: $a, type: "Bot"}, head: {ref: $r, sha: $s, repo: {full_name: "example-org/demo"}},
      base: {ref: "main", repo: {full_name: "example-org/demo", default_branch: "main"}}, labels: []}'
}

REC2=$(jq -nc --argjson a "$(ROW 12 ticket/bh-12 b)" --argjson b "$(ROW 11 ticket/bh-11 a)" '[$a, $b]')
REC1=$(jq -nc --argjson a "$(ROW 12 ticket/bh-12 b)" '[$a]')

pulls_calls() { grep -cE '(^| )repos/[^ ]+/pulls(\?[^ ]*)?( |$)' "$T/gh.log" 2>/dev/null || true; }
rec_calls() { grep -c '/api/pr-records' "$T/jobs.log" 2>/dev/null || true; }

# ══ OG: bin/overlap-guard.sh --refresh, the production entry point ═══════════
H="$T/og"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/plans" "$H/env" "$H/builds" "$H/state/prr-default-branch" "$T/fakebin" "$T/gh"
: > "$H/env/global.env"
printf 'demo example-org/demo https://demo.example /api/board 0 local -\n' > "$H/fleet.conf"
printf '#!/bin/bash\nwhile [ "${1#--}" != "$1" ]; do shift 2; done\necho "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$H" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/alert-line.sh"
# The jobs worker: the record list from $T/rec.json, every call logged.
cat > "$H/bin/jobs-client.sh" <<JC
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/jobs.log"
  case "\$2" in
    /api/pr-records\?*) [ -s "$T/rec.json" ] || return 1; cat "$T/rec.json" ;;
    *) echo '{"jobs":[]}' ;;
  esac
}
JC
for L in bin/overlap-guard.sh bin/sibling-serial.sh bin/fleet-conf.sh bin/lib/gh-rest-list.sh \
         bin/lib/prr-shadow.sh bin/lib/prr-shadow.d/overlap-guard.sh bin/lib/pr-record.sh; do
  [ -r "$DIR/$L" ] || continue
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
rm -f "$H/bin/lib/gh-repo-token.sh"
cat > "$T/fakebin/gh" <<FGH
echo "\$*" >> "$T/gh.log"
path=""; page=1
for a in "\$@"; do case "\$a" in repos/*) path="\${a%%\?*}" ;; page=*) page="\${a#page=}" ;; esac; done
case "\$path" in
  repos/*/*/pulls) f="$T/gh/pulls.\$page" ;;
  repos/*/*/pulls/*/files) n="\${path%/files}"; n="\${n##*/}"; f="$T/gh/files.\$n" ;;
  *) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
printf 'HTTP/1.1 200 OK\r\n\r\n'
if [ -s "\$f" ]; then cat "\$f"; else echo '[]'; fi
exit 0
FGH
chmod +x "$T/fakebin/gh"
printf 'main\n' > "$H/state/prr-default-branch/example-org_demo"
printf '[{"filename":"src/a.ts"}]\n' > "$T/gh/files.11"
printf '[{"filename":"src/b.ts"}]\n' > "$T/gh/files.12"
jq -nc --argjson a "$(GHROW 12 ticket/bh-12 b)" --argjson b "$(GHROW 11 ticket/bh-11 a)" '[$a, $b]' > "$T/gh/pulls.1"
CF="$H/state/overlap-guard/demo-prs.json"
PLOG="$H/logs/prr-shadow.log"
og_run() { # og_run <step|UNSET> — one refresh; OUT, the snapshot in $T/cf.<tag>
  : > "$T/gh.log"; : > "$T/jobs.log"; : > "$PLOG"
  if [ "$1" = UNSET ]; then
    OUT=$(env -u GH_SOURCE PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_ETAG=0 OVERLAP_MAIN_RECENT_MIN=0 \
      "$H/bin/overlap-guard.sh" --refresh demo 2>/dev/null)
  else
    OUT=$(env PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_ETAG=0 OVERLAP_MAIN_RECENT_MIN=0 GH_SOURCE="$1" \
      "$H/bin/overlap-guard.sh" --refresh demo 2>/dev/null)
  fi
}

rec_json 30 "$REC2" > "$T/rec.json"
og_run off
eq "OG off: refresh ok" "$OUT" "REFRESH demo ok prs=2 main=0"
eq "OG off: one GitHub pulls list read" "$(pulls_calls)" 1
eq "OG off: no record read" "$(rec_calls)" 0
cp "$CF" "$T/cf.off" 2>/dev/null

og_run record
eq "OG record+trusted: refresh ok" "$OUT" "REFRESH demo ok prs=2 main=0"
eq "OG record+trusted: 0 GitHub pulls list calls" "$(pulls_calls)" 0
eq "OG record+trusted: one record read" "$(rec_calls)" 1
cmp -s "$CF" "$T/cf.off" && ok || bad "OG record+trusted: snapshot must equal step off byte for byte: $(cat "$CF") vs $(cat "$T/cf.off")"

rec_json 99999 "$REC2" > "$T/rec.json"
og_run record
eq "OG record+stale: one GitHub pulls list read" "$(pulls_calls)" 1
eq "OG record+stale: one PRR_MISS stale line" "$(grep -c 'PRR_MISS lane=overlap-guard key=example-org/demo#open why=stale fallback=github' "$PLOG" 2>/dev/null || true)" 1
cmp -s "$CF" "$T/cf.off" && ok || bad "OG record+stale: snapshot from GitHub equals step off"

rec_json 30 "$REC1" > "$T/rec.json"
og_run shadow
eq "OG shadow+differs: one GitHub pulls list read" "$(pulls_calls)" 1
eq "OG shadow+differs: one PRR_SHADOW line" "$(grep -c 'PRR_SHADOW lane=overlap-guard key=example-org/demo#open record=1 github=2' "$PLOG" 2>/dev/null || true)" 1
cmp -s "$CF" "$T/cf.off" && ok || bad "OG shadow: the lane acts on GitHub (snapshot equals step off)"

rec_json 30 "$REC2" > "$T/rec.json"
og_run UNSET
eq "OG no row: step shadow reads GitHub" "$(pulls_calls)" 1
eq "OG no row: step shadow reads the record too" "$(rec_calls)" 1
eq "OG no row: shadow match writes no line" "$(grep -c 'PRR_' "$PLOG" 2>/dev/null || true)" 0

# Fail open: without the seam file, record step reads GitHub as today.
mv "$H/bin/lib/prr-shadow.d/overlap-guard.sh" "$T/og-seam.sh"
og_run record
eq "OG no seam: refresh still ok" "$OUT" "REFRESH demo ok prs=2 main=0"
eq "OG no seam: today's GitHub read" "$(pulls_calls)" 1
mv "$T/og-seam.sh" "$H/bin/lib/prr-shadow.d/overlap-guard.sh"

# ══ lib-level blocks: the seams through prr_read ═════════════════════════════
export HARNESS="$T/lib"; mkdir -p "$HARNESS/logs" "$HARNESS/state/prr-default-branch" "$T/tmp"
export TMPDIR="$T/tmp"
LOG="$HARNESS/logs/prr-shadow.log"
printf 'main\n' > "$HARNESS/state/prr-default-branch/example-org_demo"
. "$DIR/bin/lib/prr-shadow.sh" || { echo "FAIL: prr-shadow.sh did not source"; exit 1; }
. "$DIR/bin/lib/pr-record.sh" || { echo "FAIL: pr-record.sh did not source"; exit 1; }
# The real REST lib first (its arg checks), then the fixture gh_rest over it.
. "$DIR/bin/lib/gh-rest.sh" || { echo "FAIL: gh-rest.sh did not source"; exit 1; }
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$T/jobs.log"
  case "$2" in
    /api/pr-records\?*) [ -s "$T/rec.json" ] || return 1; cat "$T/rec.json" ;;
    /api/jobs\?*) echo '{"jobs":[]}' ;;
    *) return 1 ;;
  esac
}
# gh_rest: a fixture by path ($T/rest/<path with /?&= as _>), every call logged.
gh_rest() {
  local f
  printf 'REST %s %s\n' "$1" "$2" >> "$T/gh.log"
  f="$T/rest/$(printf '%s' "$2" | tr '/?&=' '____')"
  [ "$1" = GET ] && [ -r "$f" ] || { GH_REST_STATUS=500; return 75; }
  GH_REST_STATUS=200; cat "$f"
}
rest() { mkdir -p "$T/rest"; cat > "$T/rest/$(printf '%s' "$1" | tr '/?&=' '____')"; }
lreset() { : > "$T/gh.log"; : > "$T/jobs.log"; : > "$LOG"; rm -f "$T/out"; }
rest_calls() { grep -c "^REST GET $1" "$T/gh.log" 2>/dev/null || true; }
lines() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }

for lane in overlap-guard scheduler utilization-push review-autopilot; do
  eq "step: no row gives shadow for $lane" "$(unset GH_SOURCE GH_SOURCE_LANE; prr_step "$lane")" shadow
done

# ── OG check path (the launch check list) ────────────────────────────────────
prr_seam_load overlap-guard || bad "OGC: prr_seam_load overlap-guard failed"
harness_pr_list() { printf 'HPL %s %s %s %s\n' "$@" >> "$T/gh.log"; printf '[{"number":12,"url":"u","headRefName":"ticket/bh-12","isDraft":false,"files":[{"path":"a","additions":1,"deletions":0}]}]\n'; }
lreset; rec_json 30 "$REC2" > "$T/rec.json"
GH_SOURCE=off prr_read overlap-guard 'example-org/demo#check' "$T/out" og_check_record og_check_github og_check_norm example-org/demo 30; RC=$?
cp "$T/out" "$T/ogc.off"
eq "OGC off: rc" "$RC" 0
eq "OGC off: one list read" "$(grep -c '^HPL example-org/demo open number,url,headRefName,isDraft,files 30' "$T/gh.log" || true)" 1
lreset
GH_SOURCE=record prr_read overlap-guard 'example-org/demo#check' "$T/out" og_check_record og_check_github og_check_norm example-org/demo 30; RC=$?
# The record list holds no per-PR files with additions/deletions: the check
# list is a field miss, and record reads GitHub (fail open) with the same answer.
eq "OGC record: miss field:files" "$(lines 'PRR_MISS lane=overlap-guard key=example-org/demo#check why=field:files fallback=github')" 1
cmp -s "$T/out" "$T/ogc.off" && ok || bad "OGC record: the GitHub fallback equals step off"
eq "OGC record: no jobs read for an answer it cannot give" "$(rec_calls)" 0

# ── SC: scheduler's stack parent lookup ─────────────────────────────────────
. "$DIR/bin/lib/stack-wait.sh" || bad "SC: stack-wait.sh did not source"
prr_seam_load scheduler || bad "SC: prr_seam_load scheduler failed"
SCP='repos/example-org/demo/pulls?state=all&head=example-org:ticket/bh-12&per_page=100'
GHROW 12 ticket/bh-12 b | jq -sc . | rest "$SCP"
sc() { lreset; GH_SOURCE="$1" prr_read scheduler "example-org/demo#ticket/bh-12" "$T/out" sched_parent_record sched_parent_github sched_parent_norm example-org/demo ticket/bh-12; RC=$?; OUTV=$(cat "$T/out" 2>/dev/null); }
rec_json 30 "$REC2" > "$T/rec.json"
sc off;    OFFV="$OUTV"
eq "SC off: answer" "$OFFV" "open 12 https://github.com/example-org/demo/pull/12"
eq "SC off: one GitHub read" "$(rest_calls "$SCP")" 1
eq "SC off: no jobs read" "$(rec_calls)" 0
sc record
eq "SC record+trusted: 0 GitHub pulls calls" "$(grep -c pulls "$T/gh.log" || true)" 0
eq "SC record+trusted: equals off" "$OUTV" "$OFFV"
eq "SC record+trusted: rc" "$RC" 0
rec_json 99999 "$REC2" > "$T/rec.json"
sc record
eq "SC record+stale: one GitHub read" "$(rest_calls "$SCP")" 1
eq "SC record+stale: PRR_MISS stale" "$(lines 'PRR_MISS lane=scheduler key=example-org/demo#ticket/bh-12 why=stale fallback=github')" 1
eq "SC record+stale: equals off" "$OUTV" "$OFFV"
rec_json 30 "$REC1" > "$T/rec.json"
sc record   # bh-12 is in REC1: hit
eq "SC record: hit on the branch row" "$(grep -c pulls "$T/gh.log" || true)" 0
rec_json 30 "$(jq -nc --argjson a "$(ROW 11 ticket/bh-11 a)" '[$a]')" > "$T/rec.json"
sc record   # bh-12 not in the open list: merged/closed/absent is GitHub's to say
eq "SC record: a branch not in the open list is miss field:head" "$(lines 'why=field:head fallback=github')" 1
eq "SC record: field:head reads GitHub" "$(rest_calls "$SCP")" 1
rec_json 30 "$(jq -nc --argjson a "$(ROW 13 ticket/bh-12 c)" '[$a]')" > "$T/rec.json"
sc shadow
eq "SC shadow+differs: acts on GitHub" "$OUTV" "$OFFV"
eq "SC shadow+differs: one PRR_SHADOW line" "$(lines 'PRR_SHADOW lane=scheduler key=example-org/demo#ticket/bh-12')" 1

# ── UP: utilization-push's open PR heads, through util_section_tickets ──────
U="$T/up"; mkdir -p "$U/bin" "$U/logs"
cat > "$U/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${1:-} ${2:-}" in
  "demo board_prefix") echo - ;;
  "demo repo") echo example-org/demo ;;
  *) exit 1 ;;
esac
SH
chmod +x "$U/bin/fleet-conf.sh"
hold_classify() { return 0; }
. "$DIR/bin/lib/utilization/section-tickets.sh" || bad "UP: section-tickets.sh did not source"
jq -nc '[{number: 5, title: "a", body: "", labels: [{name: "ai-build"}]}, {number: 6, title: "b", body: "", labels: [{name: "ai-build"}]}]' \
  | rest 'repos/example-org/demo/issues?labels=ai-build&state=open&per_page=100&page=1'
echo '[]' | rest 'repos/example-org/demo/issues/6/comments?per_page=100&page=1'
echo '[]' | rest 'repos/example-org/demo/issues/5/comments?per_page=100&page=1'
GHROW 12 ticket/bh-5 b | jq -sc . | rest 'repos/example-org/demo/pulls?state=open&per_page=100&page=1'
UPP='repos/example-org/demo/pulls?state=open'
up() { lreset; : > "$U/logs/prr-shadow.log"; OUTV=$(HARNESS="$U" GH_SOURCE="$1" util_section_tickets demo); }
rec_json 30 "$(jq -nc --argjson a "$(ROW 12 ticket/bh-5 b)" '[$a]')" > "$T/rec.json"
up off; OFFV="$OUTV"
eq "UP off: issue 5 is claimed by the open PR head ticket/bh-5" "$(jq -c .tickets.ready <<<"$OFFV" 2>/dev/null)" 1
eq "UP off: one GitHub pulls read" "$(rest_calls "$UPP")" 1
eq "UP off: no record read" "$(rec_calls)" 0
up record
eq "UP record+trusted: 0 GitHub pulls calls" "$(rest_calls "$UPP")" 0
eq "UP record+trusted: equals off" "$OUTV" "$OFFV"
rec_json 99999 "$(jq -nc --argjson a "$(ROW 12 ticket/bh-5 b)" '[$a]')" > "$T/rec.json"
up record
eq "UP record+stale: one GitHub pulls read" "$(rest_calls "$UPP")" 1
eq "UP record+stale: PRR_MISS stale" "$(grep -c 'PRR_MISS lane=utilization-push key=example-org/demo#open why=stale fallback=github' "$U/logs/prr-shadow.log" || true)" 1
eq "UP record+stale: equals off" "$OUTV" "$OFFV"
rec_json 30 '[]' > "$T/rec.json"
up shadow
eq "UP shadow+differs: acts on GitHub" "$OUTV" "$OFFV"
eq "UP shadow+differs: one PRR_SHADOW line" "$(grep -c 'PRR_SHADOW lane=utilization-push key=example-org/demo#open' "$U/logs/prr-shadow.log" || true)" 1

# ── RA: review-autopilot's open list ────────────────────────────────────────
export HARNESS_PR_AUTHORS="app/cromford"
. "$DIR/bin/lib/gh-pr-list.sh" || bad "RA: gh-pr-list.sh did not source"
prr_seam_load review-autopilot || bad "RA: prr_seam_load review-autopilot failed"
RAF=number,createdAt,headRefOid,title,isDraft,baseRefName
jq -nc --argjson a "$(GHROW 12 ticket/bh-12 b)" --argjson b "$(GHROW 11 ticket/bh-11 a)" \
       --argjson c "$(GHROW 10 feat/x c someone-else)" '[$a, $b, $c]' \
  | rest 'repos/example-org/demo/pulls?state=open&per_page=100&sort=created&direction=desc&page=1'
RAREC=$(jq -nc --argjson a "$(ROW 11 ticket/bh-11 a)" --argjson b "$(ROW 12 ticket/bh-12 b)" \
       --argjson c "$(ROW 10 feat/x c someone-else)" '[$a, $b, $c]')
ra() { lreset; GH_SOURCE="$1" prr_read review-autopilot 'example-org/demo#open' "$T/out" ra_open_record ra_open_github ra_open_norm example-org/demo "$RAF" 100; RC=$?; OUTV=$(cat "$T/out" 2>/dev/null); }
rec_json 30 "$RAREC" > "$T/rec.json"
ra off; OFFV="$OUTV"
eq "RA off: the two harness PRs, newest first" "$(jq -c '[.[].number]' <<<"$OFFV" 2>/dev/null)" "[12,11]"
eq "RA off: one GitHub pulls read" "$(grep -c '^REST GET repos/example-org/demo/pulls' "$T/gh.log" || true)" 1
eq "RA off: no record read" "$(rec_calls)" 0
ra record
eq "RA record+trusted: 0 GitHub pulls calls" "$(grep -c pulls "$T/gh.log" || true)" 0
eq "RA record+trusted: byte-equal to off" "$OUTV" "$OFFV"
rec_json 99999 "$RAREC" > "$T/rec.json"
ra record
eq "RA record+stale: one GitHub pulls read" "$(grep -c '^REST GET repos/example-org/demo/pulls' "$T/gh.log" || true)" 1
eq "RA record+stale: PRR_MISS stale" "$(lines 'PRR_MISS lane=review-autopilot key=example-org/demo#open why=stale fallback=github')" 1
eq "RA record+stale: equals off" "$OUTV" "$OFFV"
rec_json 30 "$(jq -c 'map(if .number == 11 then .draft = null else . end)' <<<"$RAREC")" > "$T/rec.json"
ra record
eq "RA record: a null draft is a field miss, never 'not a draft'" "$(lines 'why=field:draft fallback=github')" 1
rec_json 30 "$(jq -c 'map(select(.number != 11))' <<<"$RAREC")" > "$T/rec.json"
ra shadow
eq "RA shadow+differs: acts on GitHub" "$OUTV" "$OFFV"
eq "RA shadow+differs: one PRR_SHADOW line" "$(lines 'PRR_SHADOW lane=review-autopilot key=example-org/demo#open record=1 github=2')" 1

# ── blast radius: one tick over 3 repos writes at most 3 PRR_MISS lines, 0 ALERTS
lreset; rec_json 99999 "$REC2" > "$T/rec.json"
for r in example-org/demo example-org/demo2 example-org/demo3; do
  GH_SOURCE=record prr_read utilization-push "$r#open" "$T/out" util_heads_record util_heads_github util_heads_norm "$r" >/dev/null 2>&1
done
eq "blast: 3 repos, 3 PRR_MISS lines" "$(lines PRR_MISS)" 3
[ ! -s "$HARNESS/logs/ALERTS.log" ] && ok || bad "blast: no ALERTS line: $(cat "$HARNESS/logs/ALERTS.log")"

echo "prr-small-lanes (BH-10218): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
