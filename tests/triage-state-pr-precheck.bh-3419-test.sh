#!/bin/bash
# tests/triage-state-pr-precheck.bh-3419-test.sh — BH-3419 (BH-3417 slice 2):
# the PR pre-check body. A `board prs:` key is decided before a model call:
# Mergify drafts, closed PRs stamped terminal, unchanged open PRs skipped.
#
# Everything real except the network edges, the same scaffold as
# tests/triage-state-precheck-test.sh: bin/lib/triage-state.sh and
# bin/lib/triage-state-pr.sh, bin/triage-state.py, bin/triage-state-pr.py,
# bin/triage-signal.py, bin/triage-gate.sh --thread, bin/lib/gh-rest.sh and the
# jobs-client queue module against the REAL worker route (node:sqlite). `gh` is
# a PATH stub serving fixture issues, comments, the open-PR list and
# pulls/<n>/reviews; vd_standing is a shell function; the shard loop is the real
# rt_shards (bin/lib/rt/shards.sh) with a stub bin/triage-shard.sh.
#
#   P1-P4 N5-N7  pr-hash / mergify_state: what moves the hash and what must not
#   N1 N2        pr-draft's adversarial negatives
#   K1           _ts_pr_keys
#   A1-A6 E1-E3  ts_tick + ts_unit_skip + rt_shards, shadow and enforce
#   C1 C2        the fetch cap and a low GitHub budget
#   N3 N4 N8     absence is never terminal; a failed read is the model; a
#                buildable PR row never reaches run-build.sh
#   Z1-Z3        mode off / no PR line / in-app board: no read, row or log
#   R1 R2 V2     worker down, decide failing, vd_standing unverifiable
#   G1 G2        no GraphQL; the files this slice must not touch
#
# Run from anywhere: tests/triage-state-pr-precheck.bh-3419-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1

PRPY="$DIR/bin/triage-state-pr.py"
PRLIB="$DIR/bin/lib/triage-state-pr.sh"
[ -r "$PRPY" ] && ok || bad "bin/triage-state-pr.py must exist"
[ -r "$PRLIB" ] && ok || bad "bin/lib/triage-state-pr.sh must exist"

# ═══ the Python half: pr-hash, pr-draft, mergify_state ═══════════════════════
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
# The real #3412 Mergify comment body (the ticket's shape; state varies).
mq_body() { printf '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n{"version": 1, "state": "%s"}\n-*- Mergify Payload End -*-\n-->' "$1"; }
PH="$T/ph"; mkdir -p "$PH"
jq -n --arg h "$HEAD" '{number:3381,title:"BH-3380: the fix",head:{sha:($h|ascii_upcase),ref:"ticket/bh-3380"},labels:[{name:"ai-build"}],user:{login:"operator"}}' > "$PH/pr.json"
jq -n '{kind:"gh",self_actors:"",self_identities:"",self_apps:["cromford"],
        doc:{issue:{number:3381,title:"BH-3380: the fix",state:"open",labels:[],comments:1},
             comments:[{id:10,user:{login:"operator",type:"User"},body:"please look",created_at:"2026-09-29T08:00:00Z"}]}}' > "$PH/thread.json"
echo '[]' > "$PH/reviews.json"
echo none > "$PH/lead.txt"
# phash [thread] [pr] [reviews] [lead] — pr-hash over the fixture files
phash() { python3 "$PRPY" pr-hash --thread "${1:-$PH/thread.json}" --pr "${2:-$PH/pr.json}" \
            --reviews "${3:-$PH/reviews.json}" --lead "${4:-$PH/lead.txt}" 2>/dev/null; }
# mut <src> [jq options] <jq-filter> -> a mutated copy's path
mut() { local s="$1" o; shift; o=$(mktemp "$PH/m.XXXXXX"); jq "$@" "$s" > "$o"; printf '%s' "$o"; }
BASEH=$(phash); RC=$?
[ "$RC" = 0 ] && [[ "$BASEH" =~ ^[0-9a-f]{64}$ ]] && ok || bad "(P0) pr-hash prints a full sha256 hex [rc=$RC out=$BASEH]"
[ "$(phash)" = "$BASEH" ] && ok || bad "(P0) pr-hash is deterministic"
EXP=$(python3 -c 'import hashlib,json,sys
print(hashlib.sha256(json.dumps({"v":"pr1","head":sys.argv[1],"state":"OPEN","labels":["ai-build"],"mq":None,"reviews":[],"lead":"none","last_comment":10},sort_keys=True,separators=(",",":")).encode()).hexdigest())' "$HEAD")
[ "$BASEH" = "$EXP" ] && ok || bad "(P0) the hashed document is {v,head(lowercased),state,labels,mq,reviews,lead,last_comment}"

# (P1) a label change moves it — a label we write (`triaged`) too
[ "$(phash "" "$(mut "$PH/pr.json" '.labels += [{name:"triaged"}]')")" != "$BASEH" ] && ok || bad "(P1) a label added must move the hash"
[ "$(phash "" "$(mut "$PH/pr.json" '.labels = [{name:"ai-build"},{name:"dequeued"}]')")" != "$BASEH" ] && ok || bad "(P1) self labels are NOT subtracted"
[ "$(phash "" "$(mut "$PH/pr.json" '.labels = ["ai-build"]')")" = "$BASEH" ] && ok || bad "(P1) a string label reads like {name}"
# (P2/N5) a review on the head moves it; on an old commit it does not; latest per login
RV=$(jq -c --arg h "$HEAD" '[{id:1,user:{login:"lead"},state:"APPROVED",commit_id:$h,submitted_at:"2026-09-29T09:00:00Z"}]' -n > "$PH/rv1.json"; echo "$PH/rv1.json")
HR=$(phash "" "" "$RV")
[ -n "$HR" ] && [ "$HR" != "$BASEH" ] && ok || bad "(P2) a review on the head must move the hash"
jq -n --arg h "$OLD" '[{id:2,user:{login:"lead"},state:"CHANGES_REQUESTED",commit_id:$h,submitted_at:"2026-09-29T10:00:00Z"}]' > "$PH/rv2.json"
[ "$(phash "" "" "$PH/rv2.json")" = "$BASEH" ] && ok || bad "(N5) a review on an old commit must NOT move the hash"
jq -n --arg h "$HEAD" --arg o "$OLD" '[{id:1,user:{login:"lead"},state:"APPROVED",commit_id:$h,submitted_at:"2026-09-29T09:00:00Z"},
  {id:2,user:{login:"lead"},state:"CHANGES_REQUESTED",commit_id:$o,submitted_at:"2026-09-29T10:00:00Z"}]' > "$PH/rv3.json"
[ "$(phash "" "" "$PH/rv3.json")" = "$HR" ] && ok || bad "(N5) an old-commit review after a head review changes nothing"
jq -n --arg h "$HEAD" '[{id:3,user:{login:"lead"},state:"COMMENTED",commit_id:$h,submitted_at:"2026-09-29T11:00:00Z"},
  {id:1,user:{login:"lead"},state:"APPROVED",commit_id:$h,submitted_at:"2026-09-29T09:00:00Z"}]' > "$PH/rv4.json"
H4=$(phash "" "" "$PH/rv4.json")
[ -n "$H4" ] && [ "$H4" != "$HR" ] && ok || bad "(P2) only the latest review per login counts (COMMENTED after APPROVED)"
# (P4) the lead's standing verdict moves it
printf 'MERGE\tlead\t7\n' > "$PH/lead2.txt"
HL=$(phash "" "" "" "$PH/lead2.txt")
[ -n "$HL" ] && [ "$HL" != "$BASEH" ] && ok || bad "(P4) lead none -> MERGE must move the hash"
printf 'MERGE\tlead\t8\n' > "$PH/lead3.txt"
[ "$(phash "" "" "" "$PH/lead3.txt")" != "$HL" ] && ok || bad "(P4) a new verdict id moves the hash"
# (N6) our App's comment does not move it; a PAT-login (person) comment does
[ "$(phash "$(mut "$PH/thread.json" '.doc.comments += [{id:11,user:{login:"operator",type:"User"},performed_via_github_app:{slug:"cromford"},body:"triage says",created_at:"2026-09-29T09:00:00Z"}]')")" = "$BASEH" ] \
  && ok || bad "(N6) our own App's comment (performed_via_github_app) must NOT move the hash"
[ "$(phash "$(mut "$PH/thread.json" '.doc.comments += [{id:12,user:{login:"cromford[bot]",type:"Bot"},body:"bot",created_at:"2026-09-29T09:00:00Z"}]')")" = "$BASEH" ] \
  && ok || bad "(N6) our own App's bot login must NOT move the hash"
[ "$(phash "$(mut "$PH/thread.json" '.doc.comments += [{id:13,user:{login:"operator",type:"User"},body:"hand typed",created_at:"2026-09-29T09:00:00Z"}]')")" != "$BASEH" ] \
  && ok || bad "(N6) a PAT-login comment must move the hash"
[ "$(phash "$(mut "$PH/thread.json" '.doc.comments += [{id:9,user:{login:"x",type:"User"},body:"older",created_at:"2026-09-28T09:00:00Z"}]')")" = "$BASEH" ] \
  && ok || bad "(N6) last_comment is the NEWEST surviving comment by created_at, not the last in the list"
[ "$(grep -c 'performed_via_github_app' "$PRPY")" = 0 ] && ok || bad "(N6) the self-App filter is imported from triage-signal.py, not re-implemented"
# (P3/N7) the Mergify payload
mqs() { # mqs <comments-json-file> -> mergify_state() over it
  python3 -c 'import importlib.util as u, json, sys
s=u.spec_from_file_location("m", sys.argv[1]); m=u.module_from_spec(s); s.loader.exec_module(m)
print(m.mergify_state(json.load(open(sys.argv[2]))))' "$PRPY" "$1" 2>&1; }
mcom() { jq -n --arg b "$1" --argjson id "$2" --arg at "$3" --arg u "${4:-mergify[bot]}" '{id:$id,user:{login:$u,type:"Bot"},body:$b,created_at:$at}'; }
{ mcom "$(mq_body queued)" 20 2026-09-29T08:00:00Z; mcom "$(mq_body merged)" 21 2026-09-29T09:00:00Z
  mcom "Thanks, merged." 22 2026-09-29T10:00:00Z; } | jq -s . > "$PH/mq1.json"
[ "$(mqs "$PH/mq1.json")" = merged ] && ok || bad "(P3) the newest mergify[bot] comment WITH a payload -> merged: [$(mqs "$PH/mq1.json")]"
{ mcom "$(mq_body dequeued)" 30 2026-09-29T08:00:00Z; } | jq -s . > "$PH/mq2.json"
[ "$(mqs "$PH/mq2.json")" = dequeued ] && ok || bad "(P3) the dequeued variant: [$(mqs "$PH/mq2.json")]"
{ mcom "$(mq_body merged)" 40 2026-09-29T08:00:00Z someone; } | jq -s . > "$PH/mq3.json"
[ "$(mqs "$PH/mq3.json")" = None ] && ok || bad "(P3) a payload not from mergify[bot] is not the queue's word: [$(mqs "$PH/mq3.json")]"
echo '[]' > "$PH/mq4.json"
[ "$(mqs "$PH/mq4.json")" = None ] && ok || bad "(P3) no mergify comment -> None"
{ mcom "$(mq_body queued)" 51 2026-09-29T08:00:00Z; mcom "$(mq_body merged)" 50 2026-09-29T08:00:00Z; } | jq -s . > "$PH/mq5.json"
[ "$(mqs "$PH/mq5.json")" = queued ] && ok || bad "(P3) same created_at: the higher id is newer: [$(mqs "$PH/mq5.json")]"
BAD=$(printf '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n{"version": 1, "state": \n-*- Mergify Payload End -*-\n-->')
mcom "$BAD" 60 2026-09-29T08:00:00Z | jq -s . > "$PH/mq6.json"
[ "$(mqs "$PH/mq6.json")" = "unparseable:$(printf '%s' "$BAD" | sha256sum | cut -c1-16)" ] && ok || bad "(N7) an unparseable payload -> unparseable:<sha[:16]>: [$(mqs "$PH/mq6.json")]"
mcom "$(printf -- '-*- Mergify Payload -*-\n{"version": 1}\n-*- Mergify Payload End -*-')" 61 2026-09-29T08:00:00Z | jq -s . > "$PH/mq7.json"
case "$(mqs "$PH/mq7.json")" in unparseable:????????????????) ok ;; *) bad "(N7) a payload with no state is unparseable: [$(mqs "$PH/mq7.json")]" ;; esac
TQ=$(mut "$PH/thread.json" --slurpfile c "$PH/mq6.json" '.doc.comments = $c[0]')
TM=$(mut "$PH/thread.json" '.doc.comments = [{id:60,user:{login:"mergify[bot]",type:"Bot"},body:"x -*- Mergify Payload -*-{\"state\":\"merged\"}-*- Mergify Payload End -*-",created_at:"2026-09-29T08:00:00Z"}]')
[ -n "$(phash "$TQ")" ] && [ "$(phash "$TQ")" != "$(phash "$TM")" ] && ok || bad "(N7) unparseable vs merged payload on the same comment: different hashes"
# pr-hash rc 1 on every unreadable shape
python3 "$PRPY" pr-hash --thread /nonexistent --pr "$PH/pr.json" --reviews "$PH/reviews.json" --lead "$PH/lead.txt" >/dev/null 2>&1
[ "$?" = 1 ] && ok || bad "(P-rc) an unreadable thread file is rc 1"
for f in '.head.sha = null' 'del(.head)' '.head.sha = 7'; do
  python3 "$PRPY" pr-hash --thread "$PH/thread.json" --pr "$(mut "$PH/pr.json" "$f")" --reviews "$PH/reviews.json" --lead "$PH/lead.txt" >/dev/null 2>&1
  [ "$?" = 1 ] && ok || bad "(P-rc) a PR row with no string head.sha ($f) is rc 1"
done
for f in '.kind = "inapp"' '.doc.comments = "x"' 'del(.doc.issue)' '.doc = []'; do
  O=$(python3 "$PRPY" pr-hash --thread "$(mut "$PH/thread.json" "$f")" --pr "$PH/pr.json" --reviews "$PH/reviews.json" --lead "$PH/lead.txt" 2>/dev/null); RC=$?
  [ "$RC" = 1 ] && [ -z "$O" ] && ok || bad "(P-rc) thread shape '$f' is rc 1 with nothing printed [rc=$RC]"
done
echo '{"x":1}' > "$PH/rvbad.json"
python3 "$PRPY" pr-hash --thread "$PH/thread.json" --pr "$PH/pr.json" --reviews "$PH/rvbad.json" --lead "$PH/lead.txt" >/dev/null 2>&1
[ "$?" = 1 ] && ok || bad "(P-rc) reviews not a list is rc 1"
python3 "$PRPY" pr-hash --thread "$PH/thread.json" --pr "$PH/pr.json" --reviews "$PH/reviews.json" --lead /nonexistent >/dev/null 2>&1
[ "$?" = 1 ] && ok || bad "(P-rc) an unreadable lead file is rc 1"

# (A4/N1/N2) pr-draft
draft() { python3 "$PRPY" pr-draft --title "$1" --head-ref "$2" >/dev/null 2>&1; echo $?; }
[ "$(draft 'merge queue: checking #3412 on main (df92116), stacked on #3414' 'mergify/merge-queue/1b657f4349')" = 0 ] && ok || bad "(A4) the #3416 draft is a draft"
[ "$(draft 'merge queue: checking #3412 on main (df92116)' 'feature/x')" = 0 ] && ok || bad "(A4) the title alone makes a draft"
[ "$(draft 'BH-1: x' 'mergify/merge-queue/abc')" = 0 ] && ok || bad "(A4) the branch alone makes a draft"
[ "$(draft 'Merge queue: fix the docs' 'fix/x')" = 1 ] && ok || bad "(N1) 'Merge queue: ' (capital M) is not a draft"
[ "$(draft 'chore: merge queue: docs' 'fix/x')" = 1 ] && ok || bad "(N1) 'merge queue: ' not at the start is not a draft"
[ "$(draft 'BH-1: x' 'fix/mergify-merge-queue-docs')" = 1 ] && ok || bad "(N2) branch fix/mergify-merge-queue-docs is not a draft"
[ "$(draft 'BH-1: x' 'mergify/merge-queue')" = 1 ] && ok || bad "(N2) branch mergify/merge-queue (no trailing slash) is not a draft"
[ "$(draft 'Bump deps' 'mergify/bp/main/pr-12')" = 1 ] && ok || bad "(N2) a mergify backport branch is not a draft"

# ═══ the shell half ══════════════════════════════════════════════════════════
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "triage-state-pr-precheck: SKIPPED the tick cases, this node has no node:sqlite"
  echo "triage-state-pr-precheck: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"

H="$T/h"; P=project-5; SLUG=example-org/project-5
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/rt" "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/env" "$H/prompts" "$H/builds" \
         "$H/catalog" "$T/gbin" "$T/fx/issues" "$T/fx/reviews" "$T/fx/lead" "$T/calls"
for s in fleet-conf.sh triage-signal.py triage-state.py; do cp "$DIR/bin/$s" "$H/bin/$s"; done
cp "$DIR/bin/triage-state-pr.py" "$H/bin/triage-state-pr.py"
cp "$DIR/bin/triage-gate.sh" "$H/bin/triage-gate.real.sh"
cp "$DIR"/bin/lib/*.sh "$H/bin/lib/"
cp "$DIR/bin/lib/triage-state-pr.sh" "$H/bin/lib/triage-state-pr.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/rt/shards.sh" "$H/bin/lib/rt/shards.sh"
cp "$DIR/catalog/lanes.json" "$H/catalog/lanes.json"
: > "$H/env/global.env"
echo "SOP. Keys are TK-<issue-number>." > "$H/prompts/$P.md"
# triage-gate.sh: the real one, except the shard loop's client-court --buildable ask
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
[ "\${2:-}" = --buildable ] && { echo OK; exit 0; }
exec bash "$H/bin/triage-gate.real.sh" "\$@"
STUB
cat > "$H/bin/triage-shard.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$2" >> "$T/calls/shard"
STUB
cat > "$H/bin/run-build.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/run-build"
STUB
chmod +x "$H/bin/"*.sh

# gh, as gh_rest calls it: `gh api -i -X GET <path> [-f/-F k=v]...`
cat > "$T/gbin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/gh"
case "\$*" in
  *rate_limit*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'; exit 0 ;;
  *repos/$SLUG/pulls/*/reviews*)
    N=\$(printf '%s\n' "\$*" | sed -nE 's#.*pulls/([0-9]+)/reviews.*#\1#p' | head -1)
    [ -e "$T/fx/reviews/\$N.fail" ] && { printf 'HTTP/2 500\r\n\r\n{}\n'; exit 1; }
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/fx/reviews/\$N.json" 2>/dev/null || echo '[]'; exit 0 ;;
  *repos/$SLUG/pulls*)
    [ -e "$T/fx/pulls.fail" ] && { printf 'HTTP/2 500\r\n\r\n{}\n'; exit 1; }
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/fx/pulls.json"; exit 0 ;;
esac
N=\$(printf '%s\n' "\$*" | sed -nE 's#.*repos/$SLUG/issues/([0-9]+).*#\1#p' | head -1)
F="$T/fx/issues/\$N.json"
[ -n "\$N" ] && [ -s "\$F" ] || { printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
case "\$*" in
  *issues/\$N/comments*) printf 'HTTP/2 200\r\n\r\n'; jq -c '.comments' "\$F"; exit 0 ;;
  *) printf 'HTTP/2 200\r\n\r\n'; jq -c '.issue' "\$F"; exit 0 ;;
esac
STUB
chmod +x "$T/gbin/gh"

# the worker, through the real router
export NODE_OPTIONS=--no-warnings
DB="$T/d1.sqlite"
cat >"$T/drv.mjs" <<EOF
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import worker from '$DIR/worker/jobs/src/index.js';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
const db = new DatabaseSync('$DB');
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
const [method, path, body] = process.argv.slice(2);
const res = await worker.fetch(new Request('https://jobs.test' + path, {
  method, headers: { authorization: 'Bearer s', 'content-type': 'application/json' },
  body: body ? body : undefined,
}), { DB: d1(db), HARNESS_SECRET: 's' });
process.stdout.write((await res.text()) + '\n' + res.status);
EOF
WORKER_UP=1
_jobs_req() {
  local out code
  [ "$WORKER_UP" = 1 ] || return 1
  out=$(node "$T/drv.mjs" "$1" "$2" "${3:-}") || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  case "$code" in 2*) printf '%s' "$out"; return 0 ;; 409) printf '%s' "$out"; return 9 ;; 404) return 2 ;; *) return 1 ;; esac
}
sql() { node -e '
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.argv[1]);
  for (const row of db.prepare(process.argv[2]).all()) console.log(Object.values(row).join("\t"));' "$DB" "$1"; }

# ── fixtures, in the shapes GitHub and bin/gate-diff.sh produce ──────────────
echo '[]' > "$T/fx/pulls.json"
pull() { # pull <n> <title> <sha> <ref> [author] — one open PR row (upsert)
  jq --argjson n "$1" --arg t "$2" --arg s "$3" --arg r "$4" --arg u "${5:-operator}" \
    'map(select(.number != $n)) + [{number:$n,title:$t,state:"open",head:{sha:$s,ref:$r},labels:[{name:"ai-build"}],user:{login:$u}}]' \
    "$T/fx/pulls.json" > "$T/fx/p.t" && mv "$T/fx/p.t" "$T/fx/pulls.json"
}
unpull() { jq --argjson n "$1" 'map(select(.number != $n))' "$T/fx/pulls.json" > "$T/fx/p.t" && mv "$T/fx/p.t" "$T/fx/pulls.json"; }
thread() { # thread <n> <title> <state> [merged_at] — the PR's issue side
  jq -n --argjson n "$1" --arg t "$2" --arg st "$3" --arg m "${4:-}" \
    '{issue:{number:$n,title:$t,state:$st,labels:[{name:"ai-build"}],comments:0,
      pull_request:{merged_at:(if $m == "" then null else $m end)}},comments:[]}' > "$T/fx/issues/$1.json"
}
tcomment() { # tcomment <n> <id> <login> <type> <body> <created_at>
  local f="$T/fx/issues/$1.json"
  jq --argjson id "$2" --arg u "$3" --arg ty "$4" --arg b "$5" --arg at "$6" \
    '.comments += [{id:$id,user:{login:$u,type:$ty},body:$b,created_at:$at,updated_at:$at}] | .issue.comments = (.comments|length)' \
    "$f" > "$f.t" && mv "$f.t" "$f"
}
# the board fingerprint (state/<p>.gate.pending): a GitHub-Issues board
jq -n '{issues:[{number:11,state:"OPEN",title:"Fee toggle",comments:0,updatedAt:"2026-09-28T09:00:00Z"}],prs:[],meta:{}}' > "$H/state/$P.gate.pending"
SHA1=1111111111111111111111111111111111111111
pull 3381 "BH-3380: the fix" "$SHA1" ticket/bh-3380
thread 3381 "BH-3380: the fix" open
tcomment 3381 5001 operator User "please review" 2026-09-29T08:00:00Z
L3381="board prs: NEW 3381 (open PR #3381: state OPEN, head ${SHA1:0:12})"

vd_standing() { # vd_standing <slug> <n> <head> — fixtures: fx/lead/<n>(.rc)
  printf '%s\n' "$*" >> "$T/calls/vd"
  [ -e "$T/fx/lead/$2.rc" ] && return "$(cat "$T/fx/lead/$2.rc")"
  [ -s "$T/fx/lead/$2" ] || return 1
  cat "$T/fx/lead/$2"
}
triage_state_list() { echo "$*" >> "$T/calls/tsl"; return 1; }

tick_env() { # tick_env <pr-mode> <gate-reason> <tick-scope>
  export HARNESS="$H" JOBS_HARNESS="$H" HARNESS_ENV_DIR="$H/env" FLEET_CONF="$DIR/fleet.conf" \
         HARNESS_SELF_APPS=cromford PATH="$T/gbin:$PATH" TRIAGE_STATE_MODE=off PR_STATE_MODE="$1" GH_TOKEN=x \
         LANE_GATE_DISABLE=1
  PROJECT=$P; STAMP="2026-09-29 10:00:00Z"; LOG="$H/logs/$P.log"; ALERTS="$H/logs/ALERTS.log"
  GATE_DECISION="RUN $2"; GATE_REASON="$2"; SCOPE_N=1
  TICK_SCOPE="$3"; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; EW_KEYS=""; JOB_ID=""
  PROMPT_TEXT="SOP PROMPT"
}
LANE_TICK() { :; }
rt_gate_consume() { :; }
# shellcheck source=/dev/null
. "$H/bin/lib/jobs/queue.sh"
# shellcheck source=/dev/null
. "$H/bin/lib/triage-state.sh"
D="$H/state/triage-state/$P"
# tick <pr-mode> <gate> <scope> [keys...] — ts_tick, the production hook, in a
# subshell; prints READY/ENFORCING/the sets, then ts_unit_skip's rc per key
tick() {
  local m="$1" g="$2" s="$3"; shift 3
  ( tick_env "$m" "$g" "$s"; ts_tick >/dev/null 2>&1
    printf 'ready=%s enf=%s skip=[%s] drafts=[%s]\n' "$TS_PR_READY" "$TS_PR_ENFORCING" "$TS_PR_SKIPSET" "$(printf '%s' "$TS_PR_DRAFTS" | tr '\n' ' ')"
    for k in "$@"; do ts_unit_skip "" "$k"; printf '%s=%s\n' "$k" "$?"; done ) 2>/dev/null
}
# shards <pr-mode> <gate> <scope> — the real rt_shards loop (bin/lib/rt/shards.sh)
# with the shard runner stubbed: the keys it dispatches land in calls/shard
shards() {
  : > "$T/calls/shard"
  ( set +u; tick_env "$1" "$2" "$3"
    . "$H/bin/lib/triage-shards-lib.sh"
    triage_shards_on() { echo 1; }; triage_shard_gh() { echo 1; }; triage_shard_fp_ttl() { echo 0; }
    triage_shards_max() { echo 0; }; triage_caps_on() { echo 0; }
    triage_shard_rearm() { :; }; triage_throttle_record() { :; }
    lock_spawn_unheld() { "$@"; }
    TRIAGE_MODEL=m; SHARD_SOP="SOP"; EFFECTIVE_GROK_EFFORT=""
    . "$H/bin/lib/rt/shards.sh"
    rt_shards ) >/dev/null 2>&1
}
shard_calls() { sort "$T/calls/shard" 2>/dev/null | tr '\n' ' '; }
dec() { awk -F'\t' -v k="$1" '$1==k {print $3 " " $4}' "$D/pr-decisions.tsv" 2>/dev/null; }
hashof() { awk -F'\t' -v k="$1" '$1==k {print $5}' "$D/pr-decisions.tsv" 2>/dev/null; }
row() { sql "SELECT $2 FROM triage_state WHERE project='$P' AND ticket_key='$1'"; }
seed_row() { # seed_row <key> <verdict> <hash> — the model's verdict, as slice 3 will record it
  jq -n --arg k "$1" --arg v "$2" --arg h "$3" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{project:"project-5",ticket_key:$k,verdict:$v,verdict_hash:$h,input_hash:$h,triaged_at:$at,next_recheck_at:"2099-01-01T00:00:00Z",reason:"test"}' > "$T/r.json"
  triage_state_put "$T/r.json" >/dev/null || bad "could not seed the row for $1"
}
loglines() { cat "$H/logs/$P.log" 2>/dev/null | grep -c 'triage-state-pr '; }
lastlog() { grep 'triage-state-pr ' "$H/logs/$P.log" 2>/dev/null | tail -1; }
# haslog <fixed text> — the last triage-state-pr line contains it. Captured, then
# matched in bash: never a pipe into grep -q (an early exit SIGPIPEs the producer
# under pipefail).
haslog() { local l; l=$(lastlog); [[ "$l" == *"$1"* ]]; }

# ═══ K1: _ts_pr_keys ═════════════════════════════════════════════════════════
K1=$( tick_env shadow board-changed "$L3381
board prs: REMOVED 3414 (PR #3414 is no longer open — merged or closed; check the issue it was built for and its Blocked-by children)
board issues: CHANGED TK-12 (title)
[HOTFIX] board prs: CHANGED 3390 (open PR #3390: head moved)
board prs: NEW 3414 (open PR #3414: state OPEN, head abc)"
      BOARD_SEC=$'board changes since the last tick:\nboard prs: CHANGED 3381 (open PR #3381: labels)'
      _ts_libs; _ts_pr_keys 2>&1 )
[ "$K1" = $'pr-3381\tCHANGED\npr-3414\tNEW\npr-3390\tCHANGED' ] && ok || bad "(K1) the pr keys, last verb wins, ticket lines dropped: [$K1]"

# ═══ Z1-Z3: nothing read, written or logged ══════════════════════════════════
: > "$T/calls/gh"
Z=$(tick off board-changed "$L3381" pr-3381)
[ "$Z" = $'ready=0 enf=0 skip=[ ] drafts=[]\npr-3381=1' ] && ok || bad "(Z1) mode off: defaults [$Z]"
Z=$(tick shadow board-changed "board issues: CHANGED TK-11 (title)" pr-3381)
[ "$Z" = $'ready=0 enf=0 skip=[ ] drafts=[]\npr-3381=1' ] && ok || bad "(Z2) no PR line: defaults [$Z]"
mv "$H/state/$P.gate.pending" "$T/gp"; echo '{"tickets":[],"meta":{}}' > "$H/state/$P.gate.pending"
Z=$(tick enforce board-changed "$L3381" pr-3381)
[ "$Z" = $'ready=0 enf=0 skip=[ ] drafts=[]\npr-3381=1' ] && ok || bad "(Z3) in-app world: defaults [$Z]"
mv "$T/gp" "$H/state/$P.gate.pending"
[ ! -s "$T/calls/gh" ] && ok || bad "(Z1-3) no GitHub read: $(cat "$T/calls/gh")"
[ "$(loglines)" = 0 ] && ok || bad "(Z1-3) no log line: $(lastlog)"
[ -z "$(sql "SELECT ticket_key FROM triage_state")" ] && ok || bad "(Z1-3) no row"
[ ! -e "$D/pr-decisions.tsv" ] && ok || bad "(Z1-3) no pr-decisions.tsv"

# ═══ A1 / A6 / E1-E3: an unchanged open PR ═══════════════════════════════════
: > "$T/calls/gh"
O=$(tick shadow board-changed "$L3381" pr-3381)
[ "$(dec pr-3381)" = "llm new" ] && ok || bad "(A1) first sight: llm new [$(dec pr-3381)]"
H81=$(hashof pr-3381)
[[ "$H81" =~ ^[0-9a-f]{64}$ ]] && ok || bad "(A1) an open PR is hashed [$H81]"
[ "$(row pr-3381 input_hash)" = "$H81" ] && [ "$(row pr-3381 last_mode)" = shadow ] && ok || bad "(A1) the row is observed with its input hash"
grep -qE "repos/$SLUG/issues/3381\$" "$T/calls/gh" && grep -q "repos/$SLUG/pulls/3381/reviews" "$T/calls/gh" && ok \
  || bad "(A1) one thread read and one reviews read: $(cat "$T/calls/gh")"
grep -q "example-org/project-5 3381 $SHA1" "$T/calls/vd" && ok || bad "(A1) vd_standing asked on the head: $(cat "$T/calls/vd" 2>/dev/null)"
[ "$(sort -u "$D/pr-hashes.tsv" | wc -l | tr -d ' ')" = 1 ] && [ "$(awk -F'\t' '{print NF}' "$D/pr-hashes.tsv")" = 8 ] && ok || bad "(A1) hashes.tsv carries 8 columns"
seed_row pr-3381 triaged "$H81"
O=$(tick enforce board-changed "$L3381" pr-3381)
[ "$(dec pr-3381)" = "skip unchanged:triaged" ] && ok || bad "(A1) unchanged: skip unchanged:triaged [$(dec pr-3381)]"
[ "$O" = $'ready=1 enf=1 skip=[ pr-3381 ] drafts=[]\npr-3381=0' ] && ok || bad "(A1) enforce: ts_unit_skip rc 0 [$O]"
haslog 'triage-state-pr enforce: 1 PR(s), 0 to the model, 1 unchanged, 0 stamped terminal, skipped 0 mergify draft(s) [reads=1]' && ok \
  || bad "(A1) the one log line: $(lastlog)"
shards enforce board-changed "$L3381"
[ "$(shard_calls)" = "" ] && ok || bad "(A1) rt_shards in enforce dispatches no pr-3381: [$(shard_calls)]"
grep -q 'triage-state unchanged: pr-3381' "$H/logs/$P.log" && ok || bad "(A1) the dispatch line names pr-3381 as triage-state unchanged"
# (A6) shadow: decided and recorded, never acted on
shards shadow board-changed "$L3381"
[ "$(shard_calls)" = "pr-3381 " ] && ok || bad "(A6) rt_shards in shadow dispatches pr-3381 as today: [$(shard_calls)]"
[ "$(row pr-3381 last_mode)	$(row pr-3381 last_decision)" = "shadow	skip unchanged:triaged" ] && ok \
  || bad "(A6) the shadow row: [$(row pr-3381 last_mode) / $(row pr-3381 last_decision)]"
O=$(tick shadow board-changed "$L3381" pr-3381)
[ "$O" = $'ready=1 enf=0 skip=[ pr-3381 ] drafts=[]\npr-3381=1' ] && ok || bad "(A6) shadow: ts_unit_skip rc 1 [$O]"
[ "$(row pr-3381 verdict_hash)" = "$H81" ] && ok || bad "(A6) the pre-check never writes a verdict of its own"
# (E1-E3) the enforce reasons
O=$(tick enforce event-wake "$L3381" pr-3381)
[ "${O##*$'\n'}" = pr-3381=0 ] && ok || bad "(E2) event-wake enforces [$O]"
O=$(tick enforce forced "$L3381" pr-3381)
[ "$O" = $'ready=1 enf=0 skip=[ pr-3381 ] drafts=[]\npr-3381=1' ] && ok || bad "(E3) a forced tick never skips [$O]"
shards enforce forced "$L3381"
[ "$(shard_calls)" = "pr-3381 " ] && ok || bad "(E3) a forced tick dispatches pr-3381: [$(shard_calls)]"
shards enforce board-changed "$L3381"
[ "$(shard_calls)" = "" ] && ok || bad "(E1) board-changed enforces in the shard loop: [$(shard_calls)]"

# ═══ N8: a stored `buildable` on a PR is never a launch ══════════════════════
seed_row pr-3381 buildable "$H81"; : > "$T/calls/run-build"
O=$(tick enforce board-changed "$L3381" pr-3381)
[ "$(dec pr-3381)" = "skip unchanged:buildable" ] && ok || bad "(N8) candidate -> skip unchanged:buildable [$(dec pr-3381)]"
sleep 0.5
[ ! -s "$T/calls/run-build" ] && ok || bad "(N8) run-build.sh never runs for a PR key: $(cat "$T/calls/run-build")"
( tick_env enforce board-changed "$L3381"; ts_tick >/dev/null 2>&1; printf '%s' "$TS_ENQ" ) > "$T/enq" 2>/dev/null
[ ! -s "$T/enq" ] && ok || bad "(N8) TS_ENQ never carries a PR key: $(cat "$T/enq")"
seed_row pr-3381 triaged "$H81"

# ═══ A2 / A3: what moves an open PR back to the model ════════════════════════
SHA2=2222222222222222222222222222222222222222
pull 3381 "BH-3380: the fix" "$SHA2" ticket/bh-3380
O=$(tick enforce board-changed "board prs: CHANGED 3381 (open PR #3381: head moved)" pr-3381)
[ "$(dec pr-3381)" = "llm changed" ] && ok || bad "(A2) a new head.sha -> llm changed [$(dec pr-3381)]"
[ "${O##*$'\n'}" = pr-3381=1 ] && ok || bad "(A2) and it is dispatched [$O]"
H82=$(hashof pr-3381); seed_row pr-3381 triaged "$H82"
tcomment 3381 5002 mergify[bot] Bot "$(mq_body queued)" 2026-09-29T09:00:00Z
O=$(tick enforce board-changed "$L3381" pr-3381)
H83=$(hashof pr-3381); seed_row pr-3381 triaged "$H83"
O=$(tick enforce board-changed "$L3381" pr-3381)
[ "$(dec pr-3381)" = "skip unchanged:triaged" ] && ok || bad "(A3) queued, unchanged: skip [$(dec pr-3381)]"
# Mergify edits its own comment in place: same id, same created_at, new state
F="$T/fx/issues/3381.json"; jq --arg b "$(mq_body dequeued)" '(.comments[] | select(.id == 5002) | .body) = $b' "$F" > "$F.t" && mv "$F.t" "$F"
O=$(tick enforce board-changed "$L3381" pr-3381)
[ "$(dec pr-3381)" = "llm changed" ] && ok || bad "(A3) payload queued -> dequeued: llm changed [$(dec pr-3381)]"
H84=$(hashof pr-3381); seed_row pr-3381 triaged "$H84"
# (P4 through the tick) the lead's standing verdict
printf 'MERGE\tlead\t7\t2026-09-29T09:30:00Z\t-\tlead\n' > "$T/fx/lead/3381"
O=$(tick enforce board-changed "$L3381" pr-3381)
[ "$(dec pr-3381)" = "llm changed" ] && ok || bad "(P4) a lead verdict on the head: llm changed [$(dec pr-3381)]"
H85=$(hashof pr-3381); seed_row pr-3381 triaged "$H85"
printf 'MERGE\tlead\t7\t2026-09-29T09:31:00Z\t-\tother\n' > "$T/fx/lead/3381"
O=$(tick enforce board-changed "$L3381" pr-3381)
[ "$(dec pr-3381)" = "skip unchanged:triaged" ] && ok || bad "(P4) only verdict/source/id are hashed [$(dec pr-3381)]"
# (V2) vd_standing cannot answer: unhashable
echo 2 > "$T/fx/lead/3381.rc"
O=$(tick enforce board-changed "$L3381" pr-3381)
[ "$(dec pr-3381)" = "llm unhashable" ] && ok || bad "(V2) vd_standing rc 2: llm unhashable [$(dec pr-3381)]"
[ "${O##*$'\n'}" = pr-3381=1 ] && ok || bad "(V2) and dispatched [$O]"
rm -f "$T/fx/lead/3381.rc"
# a failed reviews read: unhashable
touch "$T/fx/reviews/3381.fail"
O=$(tick enforce board-changed "$L3381" pr-3381)
[ "$(dec pr-3381)" = "llm unhashable" ] && ok || bad "(D9) a failed reviews read: llm unhashable [$(dec pr-3381)]"
rm -f "$T/fx/reviews/3381.fail"

# ═══ A4: the Mergify draft ═══════════════════════════════════════════════════
pull 3416 "merge queue: checking #3412 on main (df92116), stacked on #3414" 3416341634163416341634163416341634163416 mergify/merge-queue/1b657f4349 "mergify[bot]"
L3416="board prs: NEW 3416 (open PR #3416: state OPEN, head 341634163416)"
: > "$T/calls/gh"
O=$(tick enforce board-changed "$L3416" pr-3416)
[ "$(dec pr-3416)" = "draft -" ] && ok || bad "(A4) the #3416 draft: draft [$(dec pr-3416)]"
[ "$O" = $'ready=1 enf=1 skip=[ pr-3416 ] drafts=[pr-3416]\npr-3416=0' ] && ok || bad "(A4) enforce: in the skip set and TS_PR_DRAFTS [$O]"
triage_state_get "$P" pr-3416 >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "(A4) no row for a draft: triage_state_get rc 2 [$RC]"
! grep -q 'issues/3416' "$T/calls/gh" && ok || bad "(A4) a draft costs no thread read"
haslog 'skipped 1 mergify draft(s): pr-3416 [reads=0]' && ok || bad "(A4) enforce log: $(lastlog)"
shards enforce board-changed "$L3416"
[ "$(shard_calls)" = "" ] && ok || bad "(A4) enforce: no shard for the draft [$(shard_calls)]"
shards shadow board-changed "$L3416"
[ "$(shard_calls)" = "pr-3416 " ] && ok || bad "(A4) shadow: the draft is still dispatched [$(shard_calls)]"
SL=$(grep 'triage-state-pr shadow' "$H/logs/$P.log" | tail -1); [[ "$SL" == *'would skip 1 mergify draft(s): pr-3416'* ]] && ok || bad "(A4) shadow log: $(lastlog)"
# (N1) a capital-M title through the tick is an ordinary PR
pull 3417 "Merge queue: fix the docs" 3417341734173417341734173417341734173417 fix/mergify-merge-queue-docs
thread 3417 "Merge queue: fix the docs" open
O=$(tick enforce board-changed "board prs: NEW 3417 (open PR #3417: state OPEN, head 341734173417)" pr-3417)
[ "$(dec pr-3417)" = "llm new" ] && ok || bad "(N1/N2) 'Merge queue:' on fix/mergify-merge-queue-docs is not a draft [$(dec pr-3417)]"
unpull 3416; unpull 3417

# ═══ A5: a merged PR is stamped terminal ═════════════════════════════════════
SHA4=4444444444444444444444444444444444444444
pull 3414 "BH-3413: the parent" "$SHA4" ticket/bh-3413
thread 3414 "BH-3413: the parent" open
O=$(tick shadow board-changed "board prs: NEW 3414 (open PR #3414: state OPEN, head ${SHA4:0:12})" pr-3414)
PREV=$(row pr-3414 input_hash)
[[ "$PREV" =~ ^[0-9a-f]{64}$ ]] && ok || bad "(A5) the open PR was observed first [$PREV]"
unpull 3414; thread 3414 "BH-3413: the parent" closed 2026-09-29T09:40:00Z
L3414R="board prs: REMOVED 3414 (PR #3414 is no longer open — merged or closed; check the issue it was built for and its Blocked-by children)"
O=$(tick enforce board-changed "$L3414R" pr-3414)
[ "$(dec pr-3414)" = "stamp closed-on-board" ] && ok || bad "(A5) REMOVED + closed thread: stamp closed-on-board [$(dec pr-3414)]"
WANT=$(python3 -c 'import importlib.util as u, sys
s=u.spec_from_file_location("ts", sys.argv[1]); m=u.module_from_spec(s); s.loader.exec_module(m); print(m.closed_stamp(sys.argv[2]))' "$DIR/bin/triage-state.py" "$PREV")
[ "$(row pr-3414 verdict)" = closed ] && [ "$(row pr-3414 verdict_hash)" = "$WANT" ] && ok \
  || bad "(A5) verdict closed, verdict_hash = closed_stamp(prev input_hash) [$(row pr-3414 verdict) $(row pr-3414 verdict_hash)]"
[ "${O##*$'\n'}" = pr-3414=0 ] && ok || bad "(A5) enforce skips the stamped key [$O]"
haslog '1 stamped terminal: pr-3414' && ok || bad "(A5) the log names the stamp: $(lastlog)"
shards enforce board-changed "$L3414R"
[ "$(shard_calls)" = "" ] && ok || bad "(A5) no shard for the stamped key [$(shard_calls)]"
# (A5b) the same REMOVED line next tick: already terminal
O=$(tick enforce board-changed "$L3414R" pr-3414)
[ "$(dec pr-3414)" = "skip terminal" ] && ok || bad "(A5b) next tick: skip terminal [$(dec pr-3414)]"
[ "${O##*$'\n'}" = pr-3414=0 ] && [ "$(row pr-3414 verdict_hash)" = "$WANT" ] && ok || bad "(A5b) skipped, the stamp unchanged [$O]"
# (A5c) reopened
pull 3414 "BH-3413: the parent" "$SHA4" ticket/bh-3413; thread 3414 "BH-3413: the parent" open
O=$(tick enforce board-changed "board prs: NEW 3414 (open PR #3414: state OPEN, head ${SHA4:0:12})" pr-3414)
[ "$(dec pr-3414)" = "llm changed" ] && ok || bad "(A5c) reopened: llm changed [$(dec pr-3414)]"
[ "${O##*$'\n'}" = pr-3414=1 ] && ok || bad "(A5c) and dispatched [$O]"
unpull 3414

# ═══ N3 / N4: absence and a failed read are never terminal ═══════════════════
thread 3395 "BH-3394: beyond the 100" open
O=$(tick enforce board-changed "board prs: CHANGED 3395 (open PR #3395: labels)" pr-3395)
[ "$(dec pr-3395)" = "llm unhashable" ] && ok || bad "(N3) not in the open list, thread open: llm, never terminal [$(dec pr-3395)]"
[ "$(row pr-3395 verdict)" = "" ] && ok || bad "(N3) no verdict stamped"
O=$(tick enforce board-changed "board prs: CHANGED 3396 (open PR #3396: labels)" pr-3396)
[ "$(dec pr-3396)" = "llm unhashable" ] && [ "${O##*$'\n'}" = pr-3396=1 ] && ok || bad "(N3) not in the list, thread 404: llm [$(dec pr-3396) $O]"
O=$(tick enforce board-changed "board prs: REMOVED 3399 (PR #3399 is no longer open — merged or closed)" pr-3399)
[ "$(dec pr-3399)" = "llm unhashable" ] && [ "${O##*$'\n'}" = pr-3399=1 ] && ok || bad "(N4) REMOVED with a failed read: llm [$(dec pr-3399) $O]"
thread 3398 "BH-3397: merged" closed 2026-09-29T09:00:00Z
O=$( TRIAGE_STATE_MAX_FETCH=0 tick enforce board-changed "board prs: REMOVED 3398 (PR #3398 is no longer open)" pr-3398 )
[ "$(dec pr-3398)" = "llm unhashable" ] && [ "$(row pr-3398 verdict)" = "" ] && ok || bad "(N4) REMOVED with the cap spent: llm, never stamped [$(dec pr-3398)]"
thread 3414 "BH-3413: the parent" closed 2026-09-29T09:50:00Z
touch "$T/fx/pulls.fail"
O=$(tick enforce board-changed "$L3381" pr-3381)
[ "$(dec pr-3381)" = "llm unhashable" ] && ok || bad "(N3) the open list unreadable: NEW/CHANGED -> llm unhashable [$(dec pr-3381)]"
O=$(tick enforce board-changed "$L3414R" pr-3414)
[ "$(dec pr-3414)" = "skip terminal" ] && ok || bad "(N3) the open list unreadable: a REMOVED key still reads its thread [$(dec pr-3414)]"
rm -f "$T/fx/pulls.fail"

# ═══ C1 / C2: the fetch cap, one count per PR ════════════════════════════════
pull 3390 "BH-3389: other" 3390339033903390339033903390339033903390 ticket/bh-3389
thread 3390 "BH-3389: other" open
: > "$T/calls/gh"
O=$( TRIAGE_STATE_MAX_FETCH=1 tick enforce board-changed "$L3381
board prs: NEW 3390 (open PR #3390: state OPEN, head 339033903390)" pr-3381 pr-3390 )
[ "$(dec pr-3381)" != "llm unhashable" ] && [ "$(dec pr-3390)" = "llm unhashable" ] && ok || bad "(C1) the second PR over the cap: llm unhashable [$(dec pr-3381) / $(dec pr-3390)]"
NS=$(grep -oE "repos/$SLUG/(issues|pulls)/[0-9]+" "$T/calls/gh" | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ')
[ "$NS" = "3381 " ] && grep -q "pulls/3381/reviews" "$T/calls/gh" && ok || bad "(C1) one PR's thread + reviews reads only: [$NS]"
haslog '[reads=1]' && ok || bad "(C1) reads=1 in the log: $(lastlog)"
: > "$T/calls/gh"
O=$( _ts_gh_budget_low() { return 0; }; tick enforce board-changed "$L3381" pr-3381 )
[ "$(dec pr-3381)" = "llm unhashable" ] && ok || bad "(C2) a low budget: llm unhashable [$(dec pr-3381)]"
! grep -qE "issues/|pulls/[0-9]" "$T/calls/gh" && ok || bad "(C2) a low budget: no thread or reviews read: $(cat "$T/calls/gh")"
unpull 3390

# ═══ R1 / R2: the worker down, the decision pass failing ═════════════════════
WORKER_UP=0
O=$(tick enforce board-changed "$L3381
$L3414R" pr-3381 pr-3414)
[ "$(dec pr-3381)" = "llm rows-unreadable" ] && [ "$(dec pr-3414)" = "llm rows-unreadable" ] && ok \
  || bad "(R1) worker down: llm rows-unreadable [$(dec pr-3381) / $(dec pr-3414)]"
[ "$O" = $'ready=1 enf=1 skip=[ ] drafts=[]\npr-3381=1\npr-3414=1' ] && ok || bad "(R1) nothing skipped [$O]"
haslog '(rows unreadable: every PR to the model)' && ok || bad "(R1) the log says so: $(lastlog)"
WORKER_UP=1
[ ! -s "$T/calls/tsl" ] && ok || bad "(R1) rows are read per key, never with triage_state_list: $(cat "$T/calls/tsl")"
cp "$H/bin/triage-state.py" "$T/ts.py.orig"; printf 'import sys\nsys.exit(3)\n' > "$H/bin/triage-state.py"
O=$(tick enforce board-changed "$L3381" pr-3381)
[ "$O" = $'ready=0 enf=0 skip=[ ] drafts=[]\npr-3381=1' ] && ok || bad "(R2) decide fails: READY 0, nothing skipped [$O]"
haslog 'the decision pass failed' && ok || bad "(R2) one log line: $(lastlog)"
cp "$T/ts.py.orig" "$H/bin/triage-state.py"

# ═══ G1 / G2: what this slice must not touch ═════════════════════════════════
# Checked on this ticket's own branch only: in a merge-queue batch the range
# carries other PRs' commits, which may touch these files legitimately.
if [ "$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)" = ticket/bh-3419 ] \
   && git -C "$DIR" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  # This slice's own changes: every commit past origin/main except the #3418
  # contract commits this branch is stacked on (they edit triage-state.sh),
  # plus the working tree.
  # pr-scoped: ok branch-gated: runs only on ticket/bh-3419, never on main or a batch
  G=$( for c in $(git -C "$DIR" log --format=%H --invert-grep --grep='BH-3418' origin/main..HEAD); do
         git -C "$DIR" show --format= "$c" -- bin/; done; git -C "$DIR" diff HEAD -- bin/ )
  [ "$(printf '%s\n' "$G" | grep -ci '^+.*graphql')" = 0 ] && ok || bad "(G1) no new graphql in bin/"
  G2=$( { for c in $(git -C "$DIR" log --format=%H --invert-grep --grep='BH-3418' origin/main..HEAD); do
            git -C "$DIR" diff-tree --no-commit-id --name-only -r "$c"; done
          git -C "$DIR" diff --name-only HEAD; } | grep -E '^(bin/triage-state\.py|bin/lib/triage-state\.sh|bin/lib/rt/shards\.sh|worker/|bin/gate-diff\.sh)' | sort -u )
  [ -z "$G2" ] && ok || bad "(G2) forbidden files edited by BH-3419: $G2"
else
  echo "triage-state-pr-precheck: (G1/G2) not on ticket/bh-3419 or no origin/main, the branch diff checks skipped"
fi
[ "$(cat "$PRLIB" "$PRPY" | grep -ci graphql)" = 0 ] && ok || bad "(G1) no GraphQL in the PR files"
! grep -n '/root/harness' "$PRLIB" >/dev/null && ok || bad "(D43) no /root/harness literal in the lib"
! grep -nE 'ts_enqueue|run-build' "$PRLIB" | grep -v '^[0-9]*:#' >/dev/null && ok || bad "(N8) the PR lib never enqueues or launches"

echo "triage-state-pr-precheck: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
